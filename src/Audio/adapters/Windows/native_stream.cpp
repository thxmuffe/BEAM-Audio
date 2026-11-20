// Windows native AAC stream host (ba_native_stream.exe): the Windows port of
// Apple/GStreamerStreamHost.mm plus a WASAPI loopback capture. Only control and
// signalling cross the local TCP socket and the OTP port; RTP, capture and
// output stay native. Profile gst_aac_rtp_v2: AAC-LC 320 kb/s stereo.
//
//   ba_native_stream.exe [--exclude-pid PID]   ON AIR: system audio capture + host
//   ba_native_stream.exe --host                receiving host (BA_NATIVE_STREAM_PORT)
//   ba_native_stream.exe --protocol-test       host with test-only controls
//
// OTP port protocol ({packet,4}, little-endian payloads), as on macOS:
//   in:  "h" heartbeat (every 250 ms), "s" stop
//   out: <<9,Port:16/big>> endpoint, <<1,Rate:32,Channels:32>> capture format,
//        <<3,Code:32/signed,Text/binary>> error, <<6>> stopped
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <fcntl.h>
#include <io.h>
#include <gst/gst.h>
#include <gst/app/gstappsink.h>
#include <gst/app/gstappsrc.h>
#include <gst/base/gstbasesink.h>
#include <gst/rtp/gstrtcpbuffer.h>
#include <gst/sdp/sdp.h>
#define GST_USE_UNSTABLE_API
#include <gst/webrtc/webrtc.h>
#include <json-glib/json-glib.h>
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

static constexpr uint64_t NtpUnixOffset=2208988800ULL*GST_SECOND;
static std::atomic<bool> testing{false};

static uint64_t monotonicMS() {
    return std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count();
}
// Capture timestamps and every peer clock share GstSystemClock's monotonic base.
static GstClock *systemClock;
static uint64_t hostNS() { return gst_clock_get_internal_time(systemClock); }

static GMainContext *mediaContext;
static void enqueue(std::function<void()> work) {
    GSource *source=g_idle_source_new();
    g_source_set_callback(source,[](gpointer p)->gboolean {
        (*static_cast<std::function<void()> *>(p))();return G_SOURCE_REMOVE;
    },new std::function<void()>(std::move(work)),[](gpointer p) { delete static_cast<std::function<void()> *>(p); });
    g_source_attach(source,mediaContext);g_source_unref(source);
}

// ---- JSON control messages -------------------------------------------------
static JsonNode *member(JsonObject *o,const char *name) { return o && json_object_has_member(o,name) ? json_object_get_member(o,name) : nullptr; }
static const char *text(JsonObject *o,const char *name) {
    JsonNode *n=member(o,name);
    return n && JSON_NODE_HOLDS_VALUE(n) && json_node_get_value_type(n)==G_TYPE_STRING ? json_node_get_string(n) : nullptr;
}
static bool number(JsonObject *o,const char *name,double &value) {
    JsonNode *n=member(o,name);if(!n || !JSON_NODE_HOLDS_VALUE(n))return false;
    GType t=json_node_get_value_type(n);
    if(t==G_TYPE_INT64){value=(double)json_node_get_int(n);return true;}
    if(t==G_TYPE_DOUBLE){value=json_node_get_double(n);return true;}
    return false;
}
static double numberOr(JsonObject *o,const char *name,double fallback) { double v;return number(o,name,v) ? v : fallback; }
static bool flag(JsonObject *o,const char *name) {
    JsonNode *n=member(o,name);
    return n && JSON_NODE_HOLDS_VALUE(n) && json_node_get_value_type(n)==G_TYPE_BOOLEAN && json_node_get_boolean(n);
}
static bool equals(JsonObject *o,const char *name,const char *value) { const char *t=text(o,name);return t && !strcmp(t,value); }
static bool readNS(JsonObject *o,const char *name,uint64_t &n) {
    const char *p=text(o,name);if(!p || !*p)return false;n=0;
    for(;*p;++p){if(*p<'0' || *p>'9' || n>(UINT64_MAX-(*p-'0'))/10)return false;n=n*10+(*p-'0');}
    return true;
}
static std::string decimal(uint64_t n) { return std::to_string((unsigned long long)n); }

struct Event {
    JsonObject *object=json_object_new();
    Event(const char *kind) { json_object_set_string_member(object,"event",kind); }
    Event(const Event &)=delete;
    ~Event() { json_object_unref(object); }
    Event &s(const char *k,const std::string &v) { json_object_set_string_member(object,k,v.c_str());return *this; }
    Event &i(const char *k,int64_t v) { json_object_set_int_member(object,k,v);return *this; }
    Event &d(const char *k,double v) { json_object_set_double_member(object,k,v);return *this; }
    Event &b(const char *k,bool v) { json_object_set_boolean_member(object,k,v);return *this; }
    Event &null(const char *k) { json_object_set_null_member(object,k);return *this; }
    Event &node(const char *k,JsonNode *v) { json_object_set_member(object,k,json_node_copy(v));return *this; }
};
static bool exactRead(SOCKET fd,void *bytes,size_t count) {
    char *p=static_cast<char *>(bytes);
    while(count) { int n=recv(fd,p,(int)std::min<size_t>(count,1<<20),0);if(n<=0)return false;p+=n;count-=n; }
    return true;
}

// ---- One stream peer, owned by one OTP media session -------------------------
class Peer : public std::enable_shared_from_this<Peer> {
public:
    SOCKET fd;
    std::mutex writeLock,inputLock;
    std::atomic<bool> stopping{false},finished{false};
    std::atomic<uint64_t> lastControl,stopAt{0},frames{0},dropped{0};
    GstElement *pipeline=nullptr,*peer=nullptr,*input=nullptr,*volume=nullptr,*output=nullptr,*rtpbin=nullptr;
    GstClock *clock;
    GSource *rtcpTimer=nullptr,*bus=nullptr;
    std::atomic<uint64_t> clockExpires{0},clockUpdates{0},mappedPackets{0},unmappedPackets{0},senderReports{0},renderedFrames{0},maxScheduleError{0};
    std::atomic<uint64_t> connectedAt{0},firstMappedAt{0};
    uint64_t clockRevision=0,responseNS=0,sourceAnchorTime=0,sourceAnchorHost=0;
    std::atomic<int64_t> captureClockSkew{0};
    std::atomic<double> correctionPPM{0};
    int64_t sourceAnchorPosition=0;
    bool sourceAnchored=false,rtcpObserved=false;
    std::string timeline,generation;
    struct Candidate { int line;std::string candidate; };
    std::vector<Candidate> candidates;
    bool prepared=false,remoteReady=false,provider=false,synthetic=false,offered=false;
    uint32_t rate=0,channels=0,jitterLatencyMS=0;

    explicit Peer(SOCKET socket) : fd(socket),lastControl(monotonicMS()) {
        clock=(GstClock *)g_object_new(GST_TYPE_SYSTEM_CLOCK,NULL);
        BOOL yes=TRUE;setsockopt(fd,IPPROTO_TCP,TCP_NODELAY,(const char *)&yes,sizeof(yes));
        DWORD timeout=1000;setsockopt(fd,SOL_SOCKET,SO_SNDTIMEO,(const char *)&timeout,sizeof(timeout));
    }
    void send(Event &event) {
        if(!generation.empty())json_object_set_string_member(event.object,"generation",generation.c_str());
        JsonNode *root=json_node_new(JSON_NODE_OBJECT);json_node_set_object(root,event.object);
        JsonGenerator *g=json_generator_new();json_generator_set_root(g,root);
        gsize length=0;gchar *data=json_generator_to_data(g,&length);
        g_object_unref(g);json_node_unref(root);
        uint32_t size=htonl((uint32_t)length);
        std::lock_guard<std::mutex> lock(writeLock);
        if(!finished) {
            auto write=[&](const void *p,size_t n) {
                const char *b=(const char *)p;
                while(n) { int sent=::send(fd,b,(int)n,0);if(sent<=0){::shutdown(fd,SD_BOTH);return false;}b+=sent;n-=sent; }
                return true;
            };
            if(write(&size,4))write(data,length);
        }
        g_free(data);
    }
    void fail(const char *reason) { Event e("error");e.s("error",reason);send(e);shutdownWithRequest(nullptr); }
    // request: the stop command's request_id, echoed in "stopped"; owned here.
    void shutdownWithRequest(JsonNode *request) {
        if(stopping.exchange(true)){if(request)json_node_unref(request);return;}
        stopAt=monotonicMS();
        auto self=shared_from_this();
        enqueue([self,request] {
            if(self->pipeline && gst_element_set_state(self->pipeline,GST_STATE_NULL)==GST_STATE_CHANGE_FAILURE)_Exit(70);
            { std::lock_guard<std::mutex> lock(self->inputLock);
              if(self->input){gst_object_unref(self->input);self->input=nullptr;} }
            if(self->rtcpTimer){g_source_destroy(self->rtcpTimer);g_source_unref(self->rtcpTimer);self->rtcpTimer=nullptr;}
            if(self->rtpbin){gst_object_unref(self->rtpbin);self->rtpbin=nullptr;}
            if(self->output){gst_object_unref(self->output);self->output=nullptr;}
            if(self->bus){g_source_destroy(self->bus);g_source_unref(self->bus);self->bus=nullptr;}
            if(self->volume){gst_object_unref(self->volume);self->volume=nullptr;}
            if(self->peer){gst_object_unref(self->peer);self->peer=nullptr;}
            if(self->pipeline){gst_object_unref(self->pipeline);self->pipeline=nullptr;}
            if(request){Event e("stopped");e.node("request_id",request);self->send(e);json_node_unref(request);}
            if(self->clock){gst_object_unref(self->clock);self->clock=nullptr;}
            self->finished=true;::shutdown(self->fd,SD_BOTH);
        });
    }
    void serve() {
        auto self=shared_from_this();
        // Independent of the media context, callbacks and Erlang's terminate callback.
        std::thread watchdog([self] {
            while(!self->finished) {
                uint64_t expires=self->clockExpires.load();
                if(!self->stopping && (monotonicMS()-self->lastControl.load()>2000 || (expires && monotonicMS()>expires)))
                    self->shutdownWithRequest(nullptr);
                uint64_t stop=self->stopAt.load();
                if(self->stopping && stop && monotonicMS()-stop>1500)_Exit(70);
                std::this_thread::sleep_for(std::chrono::milliseconds(20));
            }
        });
        std::vector<char> data;
        while(!stopping) {
            uint32_t size;if(!exactRead(fd,&size,4))break;
            size=ntohl(size);if(!size || size>131072)break;
            data.resize(size);if(!exactRead(fd,data.data(),size))break;
            JsonParser *parser=json_parser_new();
            if(!json_parser_load_from_data(parser,data.data(),(gssize)size,NULL) || !JSON_NODE_HOLDS_OBJECT(json_parser_get_root(parser))){
                g_object_unref(parser);break;}
            JsonNode *root=json_node_copy(json_parser_get_root(parser));g_object_unref(parser);
            JsonObject *c=json_node_get_object(root);
            const char *op=text(c,"op");bool keep=true,handled=true;
            if(generation.empty()) {
                const char *g=text(c,"generation");double version;
                if(!op || strcmp(op,"hello") || !number(c,"version",version) || version!=2 || !g || strlen(g)!=32)keep=false;
                else {
                    generation=g;
                    Event e("hello");e.i("version",2).s("profile","gst_aac_rtp_v2").b("owner_loss_stop",true).b("stop_ack",true).b("schedule",true);
                    send(e);
                }
            } else if(!equals(c,"generation",generation.c_str()))keep=false;
            else {
                lastControl=monotonicMS();
                if(op && !strcmp(op,"heartbeat")){}
                else if(op && !strcmp(op,"stop")){JsonNode *id=member(c,"request_id");shutdownWithRequest(id?json_node_copy(id):nullptr);keep=false;}
                else{handled=false;enqueue([self,root]{if(!self->stopping)self->command(json_node_get_object(root));json_node_unref(root);});}
            }
            if(handled)json_node_unref(root);
            if(!keep)break;
        }
        shutdownWithRequest(nullptr);
        watchdog.join();closesocket(fd);
    }
    bool applyClock(JsonObject *c) {
        uint64_t internal,session;double revisionValue,ppm,limit;
        const char *line=text(c,"timeline");
        if(!number(c,"revision",revisionValue) || revisionValue<0 || !readNS(c,"internal_ns",internal) || !readNS(c,"session_ns",session) ||
            session>UINT64_MAX-NtpUnixOffset || !number(c,"correction_ppm",ppm) || !number(c,"max_absolute_ppm",limit) || !line || !*line)return false;
        uint64_t revision=(uint64_t)revisionValue;
        if(revision<=clockRevision || !std::isfinite(ppm) || !std::isfinite(limit) || limit<0 || limit>500 || std::fabs(ppm)>limit ||
            (!timeline.empty() && timeline!=line))return false;
        if(!clockUpdates.load())gst_clock_set_calibration(clock,internal,session+NtpUnixOffset,1,1);
        else {
            GstClockTime now=gst_clock_get_internal_time(clock),i,e,n,d;gst_clock_get_calibration(clock,&i,&e,&n,&d);
            GstClockTime external=gst_clock_adjust_with_calibration(clock,now,i,e,n,d);
            gst_clock_set_calibration(clock,now,external,1000000000LL+llround(ppm*1000),1000000000);
        }
        correctionPPM=ppm;
        timeline=line;clockRevision=revision;clockExpires=monotonicMS()+12000;++clockUpdates;
        Event ev("clock_mapped");ev.i("revision",(int64_t)revision);send(ev);return true;
    }
    void command(JsonObject *c);
    void capture(const std::vector<uint8_t> &pcm,uint32_t frameCount,uint32_t captureRate,uint32_t captureChannels,int64_t position,uint64_t host);
};

static void fail(Peer *self,const char *reason) { self->fail(reason); }
// The Session reference is a calibrated, private GstClock. RTP/RTCP remains native.
static void sinkSchedule(Peer *self) {
    if(!self->output)return;
    GstClockTime latency=gst_base_sink_get_latency(GST_BASE_SINK(self->output));
    if(!GST_CLOCK_TIME_IS_VALID(latency))return;
    // Response time is the whole capture-to-presentation budget. Reserve the
    // downstream latency reported by GStreamer before budgeting RTP buffering.
    GstClockTime jitter=(GstClockTime)self->jitterLatencyMS*GST_MSECOND;
    GstClockTime downstream=latency>jitter?latency-jitter:0;
    guint budget=(guint)((self->responseNS>downstream?self->responseNS-downstream:0)/GST_MSECOND);
    if(budget!=self->jitterLatencyMS){
        self->jitterLatencyMS=budget;g_object_set(self->peer,"latency",budget,NULL);
        gst_bin_recalculate_latency(GST_BIN(self->pipeline));
        latency=gst_base_sink_get_latency(GST_BASE_SINK(self->output));
        if(!GST_CLOCK_TIME_IS_VALID(latency))return;
    }
    // BaseSink already submits early by render-delay. Adding that delay here
    // would make physical presentation late by the same amount.
    g_object_set(self->output,"ts-offset",(gint64)self->responseNS-(gint64)latency,NULL);
}
static void requestReport(Peer *self) {
    if(!self->rtpbin || !self->provider || self->stopping)return;
    GObject *session=NULL;g_signal_emit_by_name(self->rtpbin,"get-internal-session",0,&session);
    if(session){gboolean accepted=FALSE;g_signal_emit_by_name(session,"send-rtcp-full",(guint64)(100*GST_MSECOND),&accepted);g_object_unref(session);}
}
static gboolean sendingRTCP(GObject *session,GstBuffer *buffer,gboolean,gpointer data) {
    Peer *self=static_cast<Peer *>(data);GstRTCPBuffer rtcp=GST_RTCP_BUFFER_INIT;GstRTCPPacket packet;
    if(gst_rtcp_buffer_map(buffer,GST_MAP_READ,&rtcp)){
        if(gst_rtcp_buffer_get_first_packet(&rtcp,&packet))do{
            if(gst_rtcp_packet_get_type(&packet)==GST_RTCP_TYPE_SR){
                ++self->senderReports;
                uint64_t connected=self->connectedAt.load();
                if(connected && monotonicMS()-connected>=1000){
                    g_object_ref(session);
                    enqueue([session]{g_object_set(session,"rtcp-min-interval",(guint64)(5*GST_SECOND),NULL);g_object_unref(session);});
                }
            }
        }while(gst_rtcp_packet_move_to_next(&packet));
        gst_rtcp_buffer_unmap(&rtcp);
    }
    return FALSE;
}
static void setupReports(Peer *self) {
    if(!self->rtpbin || !self->provider || self->rtcpObserved)return;
    GObject *session=NULL;g_signal_emit_by_name(self->rtpbin,"get-internal-session",0,&session);
    if(!session)return;self->rtcpObserved=true;
    // A short initial burst covers reports received before RTP state exists.
    // Afterwards use ordinary reports and explicit 5s refreshes.
    g_object_set(session,"rtcp-min-interval",(guint64)(100*GST_MSECOND),NULL);
    g_signal_connect(session,"on-sending-rtcp",G_CALLBACK(sendingRTCP),self);
    g_object_unref(session);
}
static GstPadProbeReturn mappedRTP(GstPad *,GstPadProbeInfo *info,gpointer data) {
    Peer *self=static_cast<Peer *>(data);GstBuffer *buffer=GST_PAD_PROBE_INFO_BUFFER(info);
    if(!buffer || self->stopping)return GST_PAD_PROBE_DROP;
    GstReferenceTimestampMeta *meta=gst_buffer_get_reference_timestamp_meta(buffer,NULL);
    if(!meta || !gst_structure_has_name(gst_caps_get_structure(meta->reference,0),"timestamp/x-ntp") || meta->timestamp<NtpUnixOffset){
        ++self->unmappedPackets;return GST_PAD_PROBE_DROP;
    }
    // Use RTP sample time reconstructed by GStreamer from RTCP, never arrival time.
    GstClockTime time=meta->timestamp;buffer=gst_buffer_make_writable(buffer);GST_PAD_PROBE_INFO_DATA(info)=buffer;
    GST_BUFFER_PTS(buffer)=time;GST_BUFFER_DTS(buffer)=GST_CLOCK_TIME_NONE;
    if(self->mappedPackets.fetch_add(1)==0)self->firstMappedAt=monotonicMS();
    return GST_PAD_PROBE_OK;
}
static void rendered(GstElement *,GstBuffer *buffer,GstPad *,gpointer data) {
    Peer *self=static_cast<Peer *>(data);
    if(!GST_BUFFER_PTS_IS_VALID(buffer))return;
    uint64_t target=GST_BUFFER_PTS(buffer)+self->responseNS;
    // The silent sink simulates output latency: compare its presentation time,
    // not the earlier handoff at which a real device needs the buffer.
    uint64_t now=gst_clock_get_time(self->clock)+gst_base_sink_get_render_delay(GST_BASE_SINK(self->output));
    uint64_t error=now>target?now-target:target-now,old=self->maxScheduleError.load();
    while(error>old && !self->maxScheduleError.compare_exchange_weak(old,error)){}
    self->renderedFrames+=gst_buffer_get_size(buffer)/(4*self->channels);
}
static GstPadProbeReturn countBuffer(GstPad *,GstPadProbeInfo *info,gpointer data) {
    Peer *self=static_cast<Peer *>(data);GstBuffer *buffer=GST_PAD_PROBE_INFO_BUFFER(info);
    if(buffer)self->frames+=gst_buffer_get_size(buffer)/(4*self->channels);
    return GST_PAD_PROBE_OK;
}
static void releasePeer(gpointer data) { delete static_cast<std::shared_ptr<Peer> *>(data); }
static void descriptionCreated(GstPromise *promise,gpointer data) {
    std::shared_ptr<Peer> self=*static_cast<std::shared_ptr<Peer> *>(data);
    enqueue([self,promise] {
        if(!self->stopping) {
            const GstStructure *reply=gst_promise_get_reply(promise);
            GstWebRTCSessionDescription *description=NULL;
            const char *kind=self->provider ? "offer" : "answer";
            if(reply)gst_structure_get(reply,kind,GST_TYPE_WEBRTC_SESSION_DESCRIPTION,&description,NULL);
            if(description) {
                g_signal_emit_by_name(self->peer,"set-local-description",description,NULL);
                gchar *sdp=gst_sdp_message_as_text(description->sdp);
                Event e(kind);e.s("sdp",sdp);self->send(e);g_free(sdp);
                gst_webrtc_session_description_free(description);
            } else fail(self.get(),"native_description_failed");
        }
        gst_promise_unref(promise);
    });
}
static GstPromise *descriptionPromise(Peer *self) {
    return gst_promise_new_with_change_func(descriptionCreated,new std::shared_ptr<Peer>(self->shared_from_this()),releasePeer);
}
static void remoteApplied(GstPromise *promise,gpointer data) {
    std::shared_ptr<Peer> self=*static_cast<std::shared_ptr<Peer> *>(data);
    enqueue([self,promise] {
        if(!self->stopping) {
            const GstStructure *reply=gst_promise_get_reply(promise);
            if(reply && gst_structure_has_field(reply,"error"))fail(self.get(),"native_remote_description_failed");
            else {
                self->remoteReady=true;
                for(auto &c:self->candidates)g_signal_emit_by_name(self->peer,"add-ice-candidate",(guint)c.line,c.candidate.c_str());
                self->candidates.clear();
                if(!self->provider)g_signal_emit_by_name(self->peer,"create-answer",NULL,descriptionPromise(self.get()));
            }
        }
        gst_promise_unref(promise);
    });
}
static void padAdded(GstElement *,GstPad *pad,gpointer data) {
    Peer *self=static_cast<Peer *>(data);
    if(GST_PAD_DIRECTION(pad)!=GST_PAD_SRC)return;
    gst_pad_add_probe(pad,GST_PAD_PROBE_TYPE_BUFFER,mappedRTP,self,NULL);
    GstElement *queue=gst_bin_get_by_name(GST_BIN(self->pipeline),"received");GstPad *sink=gst_element_get_static_pad(queue,"sink");
    if(!gst_pad_is_linked(sink) && gst_pad_link(pad,sink)!=GST_PAD_LINK_OK)fail(self,"native_track_link_failed");
    gst_object_unref(sink);gst_object_unref(queue);
}
static void iceCandidate(GstElement *,guint line,gchar *candidate,gpointer data) {
    Event e("candidate");e.s("candidate",candidate).s("mid","audio0").i("line",line);static_cast<Peer *>(data)->send(e);
}
static void negotiationNeeded(GstElement *,gpointer data) {
    auto self=static_cast<Peer *>(data)->shared_from_this();
    enqueue([self]{if(self->provider && !self->offered && !self->stopping){self->offered=true;g_signal_emit_by_name(self->peer,"create-offer",NULL,descriptionPromise(self.get()));}});
}
static void connectionState(GObject *peer,GParamSpec *,gpointer data) {
    Peer *self=static_cast<Peer *>(data);GstWebRTCPeerConnectionState state;
    g_object_get(peer,"connection-state",&state,NULL);
    if(state==GST_WEBRTC_PEER_CONNECTION_STATE_CONNECTED){
        self->connectedAt=monotonicMS();
        Event e("connected");e.b("synchronized",false);self->send(e);
        auto shared=self->shared_from_this();
        enqueue([shared]{if(!shared->stopping){setupReports(shared.get());requestReport(shared.get());}});
    }
    if(state==GST_WEBRTC_PEER_CONNECTION_STATE_FAILED)fail(self,"native_transport_failed");
}
static gboolean busMessage(GstBus *,GstMessage *message,gpointer data) {
    Peer *self=static_cast<Peer *>(data);
    if(GST_MESSAGE_TYPE(message)==GST_MESSAGE_LATENCY){gst_bin_recalculate_latency(GST_BIN(self->pipeline));sinkSchedule(self);}
    if(GST_MESSAGE_TYPE(message)==GST_MESSAGE_ERROR){GError *error=NULL;gchar *debug=NULL;gst_message_parse_error(message,&error,&debug);
        fprintf(stderr,"Native media: %s\n",error->message);g_error_free(error);g_free(debug);fail(self,"native_pipeline_failed");}
    return G_SOURCE_CONTINUE;
}
static gboolean rtcpRefresh(gpointer data) { Peer *self=static_cast<Peer *>(data);setupReports(self);requestReport(self);return G_SOURCE_CONTINUE; }

void Peer::command(JsonObject *c) {
    const char *op=text(c,"op");if(!op){fail("unsupported_native_control");return;}
    if(!strcmp(op,"clock")){
        GstClockTime internal=gst_clock_get_internal_time(clock),i,e,n,d;gst_clock_get_calibration(clock,&i,&e,&n,&d);
        Event ev("clock");
        if(JsonNode *sent=member(c,"sent_ns"))ev.node("sent_ns",sent);else ev.null("sent_ns");
        ev.s("internal_ns",decimal(internal));
        if(clockUpdates.load())ev.s("session_ns",decimal(gst_clock_adjust_with_calibration(clock,internal,i,e,n,d)-NtpUnixOffset));
        else ev.null("session_ns");
        send(ev);return;
    }
    if(!strcmp(op,"clock_map")){if(!applyClock(c))fail("invalid_native_clock_mapping");return;}
    if(!strcmp(op,"prepare")) {
        if(prepared){fail("native_already_prepared");return;}
        if(!clockUpdates.load()){fail("native_clock_mapping_required");return;}
        provider=equals(c,"role","provider");synthetic=flag(c,"synthetic");
        rate=(uint32_t)numberOr(c,"rate",0);channels=(uint32_t)numberOr(c,"channels",0);
        int delay=(int)numberOr(c,"buffer_ms",-1);
        if((rate!=44100 && rate!=48000) || channels!=2 || delay<0 || delay>10000){fail("unsupported_native_format_or_buffer");return;}
        responseNS=(uint64_t)delay*GST_MSECOND;jitterLatencyMS=(uint32_t)delay;
        const char *source=synthetic ? "audiotestsrc name=generator is-live=true wave=sine volume=0.02 samplesperbuffer=1024"
                                     : "appsrc name=capture is-live=true format=time block=false max-bytes=4194304";
        const bool silent=flag(c,"silent");
        gchar *graph=provider
            // FFmpeg's AAC encoder (LGPL) keeps the approved 320 kb/s AAC-LC profile.
            ? g_strdup_printf("webrtcbin name=peer bundle-policy=max-bundle %s ! audio/x-raw,format=F32LE,layout=interleaved,rate=%u,channels=2 ! "
                "audioconvert ! avenc_aac bitrate=320000 ! aacparse ! audio/mpeg,mpegversion=4,stream-format=raw ! "
                "rtpmp4gpay pt=96 ! application/x-rtp,media=audio,encoding-name=MPEG4-GENERIC ! peer.",source,rate)
            : g_strdup_printf("webrtcbin name=peer latency=%d bundle-policy=max-bundle queue name=received max-size-buffers=0 "
                "max-size-bytes=16777216 max-size-time=10000000000 ! rtpmp4gdepay ! aacparse ! avdec_aac ! audioconvert ! "
                "audio/x-raw,format=F32LE,layout=interleaved,channels=2 ! identity name=count ! audioresample ! volume name=volume mute=true ! %s",delay,
                silent ? "fakesink name=output sync=true async=false signal-handoffs=true render-delay=200000000 max-lateness=20000000"
                       : "wasapi2sink name=output sync=true provide-clock=false slave-method=resample");
        GError *error=NULL;pipeline=gst_parse_launch(graph,&error);g_free(graph);
        if(error || !pipeline){if(error){fprintf(stderr,"Native media: %s\n",error->message);g_error_free(error);}fail("native_pipeline_prepare_failed");return;}
        gst_pipeline_use_clock(GST_PIPELINE(pipeline),clock);
        gst_element_set_start_time(pipeline,GST_CLOCK_TIME_NONE);gst_element_set_base_time(pipeline,0);
        if(synthetic){GstElement *generator=gst_bin_get_by_name(GST_BIN(pipeline),"generator");g_object_set(generator,"timestamp-offset",(gint64)gst_clock_get_time(clock),NULL);gst_object_unref(generator);}
        peer=gst_bin_get_by_name(GST_BIN(pipeline),"peer");volume=gst_bin_get_by_name(GST_BIN(pipeline),"volume");
        {std::lock_guard<std::mutex> lock(inputLock);input=gst_bin_get_by_name(GST_BIN(pipeline),"capture");}
        rtpbin=gst_bin_get_by_name(GST_BIN(peer),"rtpbin");
        if(!rtpbin){fail("native_rtpbin_unavailable");return;}
        g_object_set(rtpbin,"ntp-time-source",3,"rtcp-sync-send-time",FALSE,"ntp-sync",TRUE,
            "add-reference-timestamp-meta",TRUE,"buffer-mode",0,NULL);
        output=gst_bin_get_by_name(GST_BIN(pipeline),"output");
        if(!provider){
            sinkSchedule(this);
            if(silent)g_signal_connect(output,"handoff",G_CALLBACK(rendered),this);
            GstElement *counter=gst_bin_get_by_name(GST_BIN(pipeline),"count");GstPad *pad=gst_element_get_static_pad(counter,"sink");
            gst_pad_add_probe(pad,GST_PAD_PROBE_TYPE_BUFFER,countBuffer,this,NULL);gst_object_unref(pad);gst_object_unref(counter);
            g_signal_connect(peer,"pad-added",G_CALLBACK(padAdded),this);
        }
        JsonNode *servers=member(c,"ice_servers");
        if(servers && JSON_NODE_HOLDS_ARRAY(servers)){
            JsonArray *list=json_node_get_array(servers);
            for(guint s=0;s<json_array_get_length(list);++s){
                JsonNode *server=json_array_get_element(list,s);if(!JSON_NODE_HOLDS_OBJECT(server))continue;
                JsonNode *urls=member(json_node_get_object(server),"urls");std::vector<std::string> values;
                if(urls && JSON_NODE_HOLDS_ARRAY(urls)){JsonArray *a=json_node_get_array(urls);
                    for(guint u=0;u<json_array_get_length(a);++u){JsonNode *v=json_array_get_element(a,u);
                        if(JSON_NODE_HOLDS_VALUE(v) && json_node_get_value_type(v)==G_TYPE_STRING)values.push_back(json_node_get_string(v));}}
                else if(const char *one=text(json_node_get_object(server),"urls"))values.push_back(one);
                for(auto &url:values){
                    if(!url.compare(0,5,"stun:"))g_object_set(peer,"stun-server",("stun://"+url.substr(5)).c_str(),NULL);
                    if(!url.compare(0,5,"turn:") || !url.compare(0,6,"turns:")){fail("native_turn_configuration_not_implemented");return;}
                }
            }
        }
        g_signal_connect(peer,"on-ice-candidate",G_CALLBACK(iceCandidate),this);
        g_signal_connect(peer,"on-negotiation-needed",G_CALLBACK(negotiationNeeded),this);
        g_signal_connect(peer,"notify::connection-state",G_CALLBACK(connectionState),this);
        GstBus *b=gst_element_get_bus(pipeline);bus=gst_bus_create_watch(b);gst_object_unref(b);
        g_source_set_callback(bus,(GSourceFunc)(void *)busMessage,this,NULL);g_source_attach(bus,mediaContext);
        if(provider){
            setupReports(this);rtcpTimer=g_timeout_source_new(5000);
            g_source_set_callback(rtcpTimer,rtcpRefresh,this,NULL);g_source_attach(rtcpTimer,mediaContext);
        }
        prepared=true;
        if(gst_element_set_state(pipeline,GST_STATE_PLAYING)==GST_STATE_CHANGE_FAILURE){fail("native_pipeline_start_failed");return;}
        Event e("prepared");e.s("codec","aac_lc").i("bitrate",320000);send(e);return;
    }
    if(!strcmp(op,"test_block_media") && testing){std::this_thread::sleep_for(std::chrono::seconds(10));return;}
    if(!prepared){fail("native_not_prepared");return;}
    if(!strcmp(op,"offer") || !strcmp(op,"answer")){
        GstSDPMessage *sdp=NULL;gst_sdp_message_new(&sdp);const char *value=text(c,"sdp");
        if(!value || remoteReady || gst_sdp_message_parse_buffer((const guint8 *)value,(guint)strlen(value),sdp)!=GST_SDP_OK){
            gst_sdp_message_free(sdp);fail("invalid_native_description");return;}
        auto kind=!strcmp(op,"offer") ? GST_WEBRTC_SDP_TYPE_OFFER : GST_WEBRTC_SDP_TYPE_ANSWER;
        GstWebRTCSessionDescription *description=gst_webrtc_session_description_new(kind,sdp);
        g_signal_emit_by_name(peer,"set-remote-description",description,
            gst_promise_new_with_change_func(remoteApplied,new std::shared_ptr<Peer>(shared_from_this()),releasePeer));
        gst_webrtc_session_description_free(description);
    } else if(!strcmp(op,"candidate")){
        const char *candidate=text(c,"candidate");int line=(int)numberOr(c,"line",0);
        if(!candidate){fail("invalid_native_candidate");return;}
        if(remoteReady)g_signal_emit_by_name(peer,"add-ice-candidate",(guint)line,candidate);
        else if(candidates.size()<32)candidates.push_back({line,candidate});else fail("native_candidates_full");
    } else if(!strcmp(op,"play") || !strcmp(op,"pause")){
        if(volume)g_object_set(volume,"mute",(gboolean)!strcmp(op,"pause"),NULL);
        Event e(!strcmp(op,"play") ? "playing" : "paused");send(e);
    } else if(!strcmp(op,"stats")){
        guint64 renderedBuffers=0,droppedBuffers=0;
        if(output){GstStructure *stats=gst_base_sink_get_stats(GST_BASE_SINK(output));
            gst_structure_get_uint64(stats,"rendered",&renderedBuffers);gst_structure_get_uint64(stats,"dropped",&droppedBuffers);gst_structure_free(stats);}
        Event e("stats");
        e.i("frames",(int64_t)frames.load()).i("dropped",(int64_t)dropped.load()).b("synchronized",false)
         .i("sink_rendered_buffers",(int64_t)renderedBuffers).i("sink_dropped_buffers",(int64_t)droppedBuffers).i("jitter_buffer_ms",jitterLatencyMS)
         .s("render_delay_ns",output?decimal(gst_base_sink_get_render_delay(GST_BASE_SINK(output))):std::string("0"))
         .s("capture_clock_skew_ns",std::to_string((long long)captureClockSkew.load())).d("correction_ppm",correctionPPM.load())
         .i("clock_updates",(int64_t)clockUpdates.load()).i("rtcp_mapped_packets",(int64_t)mappedPackets.load()).i("unmapped_packets",(int64_t)unmappedPackets.load())
         .i("sender_reports",(int64_t)senderReports.load()).i("rendered_frames",(int64_t)renderedFrames.load()).s("max_schedule_error_ns",decimal(maxScheduleError.load()))
         .b("presentation_schedule_execution",mappedPackets.load()>0);
        if(firstMappedAt.load())e.i("mapping_acquired_ms",std::max<int64_t>((int64_t)firstMappedAt.load()-(int64_t)connectedAt.load(),0));
        else e.null("mapping_acquired_ms");
        send(e);
    } else fail("unsupported_native_control");
}
void Peer::capture(const std::vector<uint8_t> &pcm,uint32_t frameCount,uint32_t captureRate,uint32_t captureChannels,int64_t position,uint64_t host) {
    if(stopping)return;
    std::lock_guard<std::mutex> lock(inputLock);
    if(!input)return;
    if(captureRate!=rate || captureChannels!=channels){++dropped;return;}
    if(gst_app_src_get_current_level_bytes(GST_APP_SRC(input))+pcm.size()>4*1024*1024){++dropped;return;}
    GstBuffer *buffer=gst_buffer_new_allocate(NULL,pcm.size(),NULL);gst_buffer_fill(buffer,0,pcm.data(),pcm.size());
    if(!sourceAnchored){
        uint64_t nativeNow=hostNS(),clockNow=gst_clock_get_time(clock);
        sourceAnchorTime=host<=nativeNow?clockNow-(nativeNow-host):clockNow+(host-nativeNow);
        sourceAnchorPosition=position;sourceAnchorHost=host;sourceAnchored=true;
    }
    if(position<sourceAnchorPosition){gst_buffer_unref(buffer);fail("native_capture_discontinuity");return;}
    uint64_t sampleElapsed=gst_util_uint64_scale(position-sourceAnchorPosition,GST_SECOND,rate);
    captureClockSkew=(int64_t)sampleElapsed-((int64_t)host-(int64_t)sourceAnchorHost);
    GST_BUFFER_PTS(buffer)=sourceAnchorTime+sampleElapsed;
    GST_BUFFER_DURATION(buffer)=gst_util_uint64_scale(frameCount,GST_SECOND,rate);
    gst_app_src_push_buffer(GST_APP_SRC(input),buffer);
}

// ---- Local control listener --------------------------------------------------
class Host {
    SOCKET listener=INVALID_SOCKET;
    std::mutex peersLock;
    std::vector<std::shared_ptr<Peer>> peers;
public:
    uint16_t start() {
        static std::once_flag once;
        std::call_once(once,[]{
            gst_init(NULL,NULL);systemClock=gst_system_clock_obtain();mediaContext=g_main_context_new();
            std::thread([]{g_main_context_push_thread_default(mediaContext);g_main_loop_run(g_main_loop_new(mediaContext,FALSE));}).detach();
        });
        listener=socket(AF_INET,SOCK_STREAM,IPPROTO_TCP);
        sockaddr_in address={};address.sin_family=AF_INET;address.sin_addr.s_addr=htonl(INADDR_LOOPBACK);int size=sizeof(address);
        if(listener==INVALID_SOCKET || bind(listener,(sockaddr *)&address,size) || listen(listener,16) || getsockname(listener,(sockaddr *)&address,&size)){
            if(listener!=INVALID_SOCKET)closesocket(listener);listener=INVALID_SOCKET;return 0;}
        SOCKET l=listener;
        std::thread([this,l]{for(;;){SOCKET fd=accept(l,NULL,NULL);if(fd==INVALID_SOCKET)break;
            auto peer=std::make_shared<Peer>(fd);
            {std::lock_guard<std::mutex> lock(peersLock);peers.push_back(peer);}
            std::thread([this,peer]{peer->serve();std::lock_guard<std::mutex> lock(peersLock);
                peers.erase(std::remove(peers.begin(),peers.end(),peer),peers.end());}).detach();
        }}).detach();
        return ntohs(address.sin_port);
    }
    void stop() {
        if(listener!=INVALID_SOCKET){closesocket(listener);listener=INVALID_SOCKET;}
        std::vector<std::shared_ptr<Peer>> current;{std::lock_guard<std::mutex> lock(peersLock);current=peers;}
        for(auto &peer:current)peer->shutdownWithRequest(nullptr);uint64_t start=monotonicMS();
        for(auto &peer:current)while(!peer->finished){if(monotonicMS()-start>1500)_Exit(70);std::this_thread::sleep_for(std::chrono::milliseconds(10));}
    }
    void capture(const std::vector<uint8_t> &pcm,uint32_t frames,uint32_t rate,uint32_t channels,int64_t position,uint64_t host) {
        std::lock_guard<std::mutex> lock(peersLock);
        for(auto &peer:peers)peer->capture(pcm,frames,rate,channels,position,host);
    }
};

// ---- OTP port ----------------------------------------------------------------
static std::mutex stdoutLock;
static void wirePacket(uint8_t type,const void *data,uint32_t bytes) {
    std::lock_guard<std::mutex> lock(stdoutLock);
    uint32_t size=htonl(bytes+1);
    if(fwrite(&size,4,1,stdout)!=1 || fwrite(&type,1,1,stdout)!=1 || (bytes && fwrite(data,bytes,1,stdout)!=1))_Exit(70);
    fflush(stdout);
}
static void wireError(int32_t code,const std::string &message) {
    std::vector<uint8_t> payload(4+message.size());memcpy(payload.data(),&code,4);memcpy(payload.data()+4,message.data(),message.size());
    wirePacket(3,payload.data(),(uint32_t)payload.size());
}
static std::atomic<uint64_t> ownerContact{0},stopAt{0};
static std::atomic<bool> stopRequested{false};
static void ownerLifetime() {
    ownerContact=monotonicMS();
    std::thread([] {
        uint8_t command[5];
        while(fread(command,1,5,stdin)==5){
            if(!memcmp(command,"\0\0\0\1h",5))ownerContact=monotonicMS();
            else if(!memcmp(command,"\0\0\0\1s",5)){stopAt=monotonicMS();stopRequested=true;return;}
            else _Exit(65);
        }
        _Exit(70);
    }).detach();
    std::thread([] {
        // Process exit is the hard boundary: no media outlives a lost owner.
        for(;;) {
            if(monotonicMS()-ownerContact.load()>2000 || (stopRequested && monotonicMS()-stopAt.load()>1500))_Exit(70);
            std::this_thread::sleep_for(std::chrono::milliseconds(20));
        }
    }).detach();
}

// ---- System audio capture (WASAPI loopback) ----------------------------------
// One capture feeds every provider peer. Samples are resampled to 48 kHz stereo
// float; GStreamer's sample-counted timestamps give each block its host time.
static constexpr uint32_t CaptureRate=48000,CaptureChannels=2;
static bool runCapture(Host &host,long excludePid) {
    GError *error=NULL;
    GstElement *pipeline=gst_parse_launch(
        "wasapi2src name=source loopback=true ! audioconvert ! audioresample ! "
        "audio/x-raw,format=F32LE,layout=interleaved,rate=48000,channels=2 ! appsink name=sink sync=false max-buffers=64",&error);
    if(error || !pipeline){std::string m=error?error->message:"Create system audio capture";if(error)g_error_free(error);wireError(-1,m);return false;}
    GstElement *source=gst_bin_get_by_name(GST_BIN(pipeline),"source");
    // Exclude this Device's own playback (the receiving host is a child of BEAM).
    if(excludePid>0 && g_object_class_find_property(G_OBJECT_GET_CLASS(source),"loopback-mode")){
        gst_util_set_object_arg(G_OBJECT(source),"loopback-mode","exclude-process-tree");
        g_object_set(source,"loopback-target-pid",(guint)excludePid,NULL);
    }
    gst_object_unref(source);
    gst_pipeline_use_clock(GST_PIPELINE(pipeline),systemClock);
    gst_element_set_start_time(pipeline,GST_CLOCK_TIME_NONE);gst_element_set_base_time(pipeline,0);
    GstElement *sink=gst_bin_get_by_name(GST_BIN(pipeline),"sink");
    GstBus *bus=gst_element_get_bus(pipeline);
    bool ok=gst_element_set_state(pipeline,GST_STATE_PLAYING)!=GST_STATE_CHANGE_FAILURE &&
        gst_element_get_state(pipeline,NULL,NULL,5*GST_SECOND)!=GST_STATE_CHANGE_FAILURE;
    std::string failure="Start system audio capture";
    if(ok){uint32_t format[2]={CaptureRate,CaptureChannels};wirePacket(1,format,sizeof(format));}
    bool first=true;int64_t position=0;GstClockTime firstTime=0;std::vector<uint8_t> pcm;
    while(ok && !stopRequested) {
        if(GstMessage *m=gst_bus_pop_filtered(bus,(GstMessageType)(GST_MESSAGE_ERROR|GST_MESSAGE_EOS))){
            if(GST_MESSAGE_TYPE(m)==GST_MESSAGE_ERROR){GError *e=NULL;gst_message_parse_error(m,&e,NULL);failure=e->message;g_error_free(e);}
            else failure="System audio capture ended";
            gst_message_unref(m);ok=false;break;
        }
        GstSample *sample=gst_app_sink_try_pull_sample(GST_APP_SINK(sink),100*GST_MSECOND);if(!sample)continue;
        GstBuffer *buffer=gst_sample_get_buffer(sample);GstMapInfo map;
        if(buffer && GST_BUFFER_PTS_IS_VALID(buffer) && gst_buffer_map(buffer,&map,GST_MAP_READ)){
            uint32_t frames=(uint32_t)(map.size/(4*CaptureChannels));GstClockTime time=GST_BUFFER_PTS(buffer);
            if(first){first=false;firstTime=time;position=0;}
            else if(GST_BUFFER_IS_DISCONT(buffer)){
                // Skipped device samples advance the sample position; never rewind it.
                int64_t expected=(int64_t)gst_util_uint64_scale_round(time>firstTime?time-firstTime:0,CaptureRate,GST_SECOND);
                position=std::max(position,expected);
            }
            pcm.assign(map.data,map.data+(size_t)frames*4*CaptureChannels);gst_buffer_unmap(buffer,&map);
            if(frames)host.capture(pcm,frames,CaptureRate,CaptureChannels,position,time);
            position+=frames;
        }
        gst_sample_unref(sample);
    }
    gst_element_set_state(pipeline,GST_STATE_NULL);
    gst_object_unref(bus);gst_object_unref(sink);gst_object_unref(pipeline);
    if(!ok && !stopRequested){wireError(-1,failure);return false;}
    return true;
}

int main(int argc,char **argv) {
    _setmode(_fileno(stdin),_O_BINARY);_setmode(_fileno(stdout),_O_BINARY);
    WSADATA wsa;if(WSAStartup(MAKEWORD(2,2),&wsa)){wireError(-1,"Start Windows sockets");return 1;}
    // DLLs ship beside the helper and plugins in its plugins folder. Plugins load
    // their own dependencies through PATH, not from the helper's folder.
    wchar_t path[MAX_PATH];DWORD n=GetModuleFileNameW(NULL,path,MAX_PATH);
    if(n && n<MAX_PATH){
        gchar *exe=g_utf16_to_utf8((const gunichar2 *)path,-1,NULL,NULL,NULL);gchar *dir=g_path_get_dirname(exe);
        const gchar *old=g_getenv("PATH");gchar *search=g_strconcat(dir,";",old?old:"",NULL);g_setenv("PATH",search,TRUE);g_free(search);
        if(!g_getenv("GST_PLUGIN_SYSTEM_PATH_1_0")){gchar *plugins=g_build_filename(dir,"plugins",NULL);g_setenv("GST_PLUGIN_SYSTEM_PATH_1_0",plugins,TRUE);g_free(plugins);}
        g_free(dir);g_free(exe);
    }
    std::string mode=argc>1?argv[1]:"";long excludePid=0;
    if(mode=="--exclude-pid" && argc>2)excludePid=strtol(argv[2],NULL,10);
    Host host;uint16_t port=host.start();
    if(!port){wireError(-1,"Start native stream service");return 1;}
    uint16_t networkPort=htons(port);wirePacket(9,&networkPort,2);
    ownerLifetime();
    if(mode=="--protocol-test" || mode=="--host"){
        testing=mode=="--protocol-test";
        while(!stopRequested)std::this_thread::sleep_for(std::chrono::milliseconds(10));
        host.stop();wirePacket(6,nullptr,0);return 0;
    }
    bool captured=runCapture(host,excludePid);
    host.stop();
    if(!captured)return 1;
    wirePacket(6,nullptr,0);return 0;
}
