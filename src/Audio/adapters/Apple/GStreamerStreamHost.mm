#import "GStreamerStreamHost.h"
#import <TargetConditionals.h>
#if TARGET_OS_IPHONE
#import <AVFAudio/AVFAudio.h>
#import "../iOS/IOSGStreamerRuntime.h"
extern "C" void *ba_native_stream_audio_acquire(void);
extern "C" void ba_native_stream_audio_release(void *);
#endif
#include <gst/gst.h>
#include <gst/app/gstappsrc.h>
#include <gst/base/gstbasesink.h>
#include <gst/rtp/gstrtcpbuffer.h>
#include <mach/mach_time.h>
#include <cmath>
#include <gst/sdp/sdp.h>
#define GST_USE_UNSTABLE_API
#include <gst/webrtc/webrtc.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <unistd.h>
#include <atomic>
#include <thread>
#include <mutex>
#include <vector>
#include <chrono>
#include <cstring>

static constexpr uint64_t NtpUnixOffset=2208988800ULL*GST_SECOND;
static NSString *nsText(uint64_t n) { return [NSString stringWithFormat:@"%llu",(unsigned long long)n]; }
static bool readNS(id value,uint64_t &n) {
    if(![value isKindOfClass:NSString.class])return false;
    const char *p=[value UTF8String];if(!*p)return false;n=0;
    for(;*p;++p){if(*p<'0' || *p>'9' || n>(UINT64_MAX-(*p-'0'))/10)return false;n=n*10+(*p-'0');}
    return true;
}
static uint64_t hostNS() {
    mach_timebase_info_data_t t;mach_timebase_info(&t);uint64_t n=mach_absolute_time();
    return n/t.denom*t.numer+n%t.denom*t.numer/t.denom;
}
static uint64_t monotonicMS() {
    return std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count();
}
static bool exactRead(int fd,void *bytes,size_t count) {
    char *p=static_cast<char *>(bytes);
    while(count) { ssize_t n=recv(fd,p,count,0);if(n<0 && errno==EINTR)continue;
        if(n<=0)return false;p+=n;count-=n; } return true;
}
static GMainContext *mediaContext;
static void enqueue(dispatch_block_t block) {
    GSource *source=g_idle_source_new();
    g_source_set_callback(source,[](gpointer p)->gboolean {
        @autoreleasepool { ((__bridge dispatch_block_t)p)(); } return G_SOURCE_REMOVE;
    },(__bridge_retained void *)[block copy],[](gpointer p) { (void)CFBridgingRelease(p); });
    g_source_attach(source,mediaContext);g_source_unref(source);
}

@interface BANativePeer : NSObject {
@public
    int _fd;
    std::mutex _writeLock,_inputLock;
    std::atomic<bool> _stopping,_finished;
    std::atomic<uint64_t> _lastControl,_stopAt,_frames,_dropped;
    GstElement *_pipeline,*_peer,*_input,*_volume,*_output,*_rtpbin;
    GstClock *_clock;
    GSource *_rtcpTimer;
    std::atomic<uint64_t> _clockExpires,_clockUpdates,_mappedPackets,_unmappedPackets,_senderReports,_renderedFrames,_maxScheduleError;
    std::atomic<uint64_t> _connectedAt,_firstMappedAt;
    uint64_t _clockRevision,_responseNS,_sourceAnchorTime,_sourceAnchorHost;
    std::atomic<int64_t> _captureClockSkew;
    std::atomic<double> _correctionPPM;
    int64_t _sourceAnchorPosition;
    bool _sourceAnchored,_rtcpObserved;
    NSString *_timeline;
    GSource *_bus;
    NSMutableArray<NSDictionary *> *_candidates;
    bool _prepared,_remoteReady,_provider,_synthetic,_offered;
    NSString *_generation;
    uint32_t _rate,_channels,_jitterLatencyMS;
#if TARGET_OS_IPHONE
    void *_audioSessionToken;
#endif
}
- (instancetype)initWithSocket:(int)fd;
- (void)serve;
- (void)send:(NSDictionary *)event;
- (void)command:(NSDictionary *)command;
- (void)shutdownWithRequest:(nullable NSNumber *)request;
- (BOOL)applyClock:(NSDictionary *)command;
- (void)capture:(NSData *)pcm frames:(uint32_t)frames rate:(uint32_t)rate channels:(uint32_t)channels position:(int64_t)position host:(uint64_t)host;
@end

static void fail(BANativePeer *self,NSString *reason) {
    [self send:@{@"event":@"error",@"error":reason}];[self shutdownWithRequest:nil];
}
// The Session reference is a calibrated, private GstClock. RTP/RTCP remains native.
static void sinkSchedule(BANativePeer *self) {
    if(!self->_output)return;
    GstClockTime latency=gst_base_sink_get_latency(GST_BASE_SINK(self->_output));
    if(!GST_CLOCK_TIME_IS_VALID(latency))return;
    // Response time is the whole capture-to-presentation budget. Reserve the
    // downstream latency reported by GStreamer before budgeting RTP buffering.
    GstClockTime jitter=(GstClockTime)self->_jitterLatencyMS*GST_MSECOND;
    GstClockTime downstream=latency>jitter?latency-jitter:0;
    guint budget=(guint)((self->_responseNS>downstream?self->_responseNS-downstream:0)/GST_MSECOND);
    if(budget!=self->_jitterLatencyMS){
        self->_jitterLatencyMS=budget;g_object_set(self->_peer,"latency",budget,NULL);
        gst_bin_recalculate_latency(GST_BIN(self->_pipeline));
        latency=gst_base_sink_get_latency(GST_BASE_SINK(self->_output));
        if(!GST_CLOCK_TIME_IS_VALID(latency))return;
    }
    // BaseSink already submits early by render-delay. Adding that delay here
    // would make physical presentation late by the same amount.
    g_object_set(self->_output,"ts-offset",(gint64)self->_responseNS-(gint64)latency,NULL);
}
static void requestReport(BANativePeer *self) {
    if(!self->_rtpbin || !self->_provider || self->_stopping)return;
    GObject *session=NULL;g_signal_emit_by_name(self->_rtpbin,"get-internal-session",0,&session);
    if(session){gboolean accepted=FALSE;g_signal_emit_by_name(session,"send-rtcp-full",(guint64)(100*GST_MSECOND),&accepted);g_object_unref(session);}
}
static void setupReports(BANativePeer *self) {
    if(!self->_rtpbin || !self->_provider || self->_rtcpObserved)return;
    GObject *session=NULL;g_signal_emit_by_name(self->_rtpbin,"get-internal-session",0,&session);
    if(!session)return;self->_rtcpObserved=true;
    // A short initial burst covers reports received before RTP state exists.
    // Afterwards use ordinary reports and explicit 5s refreshes.
    g_object_set(session,"rtcp-min-interval",(guint64)(100*GST_MSECOND),NULL);
    g_signal_connect(session,"on-sending-rtcp",G_CALLBACK((+[](GObject *session,GstBuffer *buffer,gboolean,gpointer data)->gboolean {
        BANativePeer *self=(__bridge BANativePeer *)data;GstRTCPBuffer rtcp=GST_RTCP_BUFFER_INIT;GstRTCPPacket packet;
        if(gst_rtcp_buffer_map(buffer,GST_MAP_READ,&rtcp)){
            if(gst_rtcp_buffer_get_first_packet(&rtcp,&packet))do{
                if(gst_rtcp_packet_get_type(&packet)==GST_RTCP_TYPE_SR){
                    ++self->_senderReports;
                    uint64_t connected=self->_connectedAt.load();
                    if(connected && monotonicMS()-connected>=1000){
                        (void)g_object_ref(session);enqueue(^{g_object_set(session,"rtcp-min-interval",(guint64)(5*GST_SECOND),NULL);g_object_unref(session);});
                    }
                }
            }while(gst_rtcp_packet_move_to_next(&packet));
            gst_rtcp_buffer_unmap(&rtcp);
        }
        return FALSE;
    })),(__bridge void *)self);
    g_object_unref(session);
}
static GstPadProbeReturn mappedRTP(GstPad *,GstPadProbeInfo *info,gpointer data) {
    BANativePeer *self=(__bridge BANativePeer *)data;GstBuffer *buffer=GST_PAD_PROBE_INFO_BUFFER(info);
    if(!buffer || self->_stopping)return GST_PAD_PROBE_DROP;
    GstReferenceTimestampMeta *meta=gst_buffer_get_reference_timestamp_meta(buffer,NULL);
    if(!meta || !gst_structure_has_name(gst_caps_get_structure(meta->reference,0),"timestamp/x-ntp") || meta->timestamp<NtpUnixOffset){
        ++self->_unmappedPackets;return GST_PAD_PROBE_DROP;
    }
    // Use RTP sample time reconstructed by GStreamer from RTCP, never arrival time.
    GstClockTime time=meta->timestamp;buffer=gst_buffer_make_writable(buffer);GST_PAD_PROBE_INFO_DATA(info)=buffer;
    GST_BUFFER_PTS(buffer)=time;GST_BUFFER_DTS(buffer)=GST_CLOCK_TIME_NONE;
    if(self->_mappedPackets.fetch_add(1)==0)self->_firstMappedAt=monotonicMS();
    return GST_PAD_PROBE_OK;
}
static void rendered(GstElement *,GstBuffer *buffer,GstPad *,gpointer data) {
    BANativePeer *self=(__bridge BANativePeer *)data;
    if(!GST_BUFFER_PTS_IS_VALID(buffer))return;
    uint64_t target=GST_BUFFER_PTS(buffer)+self->_responseNS;
    // The silent sink simulates output latency: compare its presentation time,
    // not the earlier handoff at which a real device needs the buffer.
    uint64_t now=gst_clock_get_time(self->_clock)+gst_base_sink_get_render_delay(GST_BASE_SINK(self->_output));
    uint64_t error=now>target?now-target:target-now,old=self->_maxScheduleError.load();
    while(error>old && !self->_maxScheduleError.compare_exchange_weak(old,error)){}
    self->_renderedFrames+=gst_buffer_get_size(buffer)/(4*self->_channels);
}
static GstPadProbeReturn countBuffer(GstPad *,GstPadProbeInfo *info,gpointer data) {
    BANativePeer *self=(__bridge BANativePeer *)data;
    GstBuffer *buffer=GST_PAD_PROBE_INFO_BUFFER(info);
    if(buffer)self->_frames+=gst_buffer_get_size(buffer)/(4*self->_channels);
    return GST_PAD_PROBE_OK;
}
static void releasePeer(gpointer data) { (void)CFBridgingRelease(data); }
static void descriptionCreated(GstPromise *promise,gpointer data) {
    BANativePeer *self=(__bridge BANativePeer *)data;
    enqueue(^{
        if(!self->_stopping) {
            const GstStructure *reply=gst_promise_get_reply(promise);
            GstWebRTCSessionDescription *description=NULL;
            const char *kind=self->_provider ? "offer" : "answer";
            if(reply)gst_structure_get(reply,kind,GST_TYPE_WEBRTC_SESSION_DESCRIPTION,&description,NULL);
            if(description) {
                g_signal_emit_by_name(self->_peer,"set-local-description",description,NULL);
                gchar *sdp=gst_sdp_message_as_text(description->sdp);
                [self send:@{@"event":@(kind),@"sdp":@(sdp)}];g_free(sdp);
                gst_webrtc_session_description_free(description);
            } else fail(self,@"native_description_failed");
        }
        gst_promise_unref(promise);
    });
}
static GstPromise *descriptionPromise(BANativePeer *self) {
    return gst_promise_new_with_change_func(descriptionCreated,(__bridge_retained void *)self,releasePeer);
}
static void remoteApplied(GstPromise *promise,gpointer data) {
    BANativePeer *self=(__bridge BANativePeer *)data;
    enqueue(^{
        if(!self->_stopping) {
            const GstStructure *reply=gst_promise_get_reply(promise);
            if(reply && gst_structure_has_field(reply,"error"))fail(self,@"native_remote_description_failed");
            else {
                self->_remoteReady=true;
                for(NSDictionary *c in self->_candidates)
                    g_signal_emit_by_name(self->_peer,"add-ice-candidate",[c[@"line"] intValue],[c[@"candidate"] UTF8String]);
                [self->_candidates removeAllObjects];
                if(!self->_provider)g_signal_emit_by_name(self->_peer,"create-answer",NULL,descriptionPromise(self));
            }
        }
        gst_promise_unref(promise);
    });
}

@implementation BANativePeer
- (instancetype)initWithSocket:(int)fd {
    if((self=[super init])) {
        _fd=fd;_lastControl=monotonicMS();_stopping=false;_finished=false;_stopAt=0;
        _clock=(GstClock *)g_object_new(GST_TYPE_SYSTEM_CLOCK,NULL);
        _clockExpires=0;_clockUpdates=0;_mappedPackets=0;_unmappedPackets=0;_senderReports=0;_renderedFrames=0;_maxScheduleError=0;
        _connectedAt=0;_firstMappedAt=0;
        _frames=0;_dropped=0;_captureClockSkew=0;_correctionPPM=0;_candidates=[NSMutableArray array];
        int yes=1;setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&yes,sizeof(yes));
        setsockopt(fd,IPPROTO_TCP,TCP_NODELAY,&yes,sizeof(yes));
        timeval timeout={1,0};setsockopt(fd,SOL_SOCKET,SO_SNDTIMEO,&timeout,sizeof(timeout));
    } return self;
}
- (void)send:(NSDictionary *)event {
    NSMutableDictionary *message=[event mutableCopy];if(_generation)message[@"generation"]=_generation;
    NSData *data=[NSJSONSerialization dataWithJSONObject:message options:0 error:nil];
    uint32_t size=htonl((uint32_t)data.length);std::lock_guard<std::mutex> lock(_writeLock);
    if(_finished)return;
    auto write=[&](const void *p,size_t n) {
        const char *b=(const char *)p;
        while(n) { ssize_t sent=::send(_fd,b,n,0);if(sent<0 && errno==EINTR)continue;
            if(sent<=0){::shutdown(_fd,SHUT_RDWR);return false;}b+=sent;n-=sent; } return true;
    };
    if(write(&size,4))write(data.bytes,data.length);
}
- (void)shutdownWithRequest:(NSNumber *)request {
    if(_stopping.exchange(true))return;
    _stopAt=monotonicMS();
    enqueue(^{
        if(self->_pipeline && gst_element_set_state(self->_pipeline,GST_STATE_NULL)==GST_STATE_CHANGE_FAILURE)_Exit(70);
        { std::lock_guard<std::mutex> lock(self->_inputLock);
          if(self->_input){gst_object_unref(self->_input);self->_input=NULL;} }
        if(self->_rtcpTimer){g_source_destroy(self->_rtcpTimer);g_source_unref(self->_rtcpTimer);self->_rtcpTimer=NULL;}
        if(self->_rtpbin){gst_object_unref(self->_rtpbin);self->_rtpbin=NULL;}
        if(self->_output){gst_object_unref(self->_output);self->_output=NULL;}
        if(self->_bus){g_source_destroy(self->_bus);g_source_unref(self->_bus);self->_bus=NULL;}
        if(self->_volume){gst_object_unref(self->_volume);self->_volume=NULL;}
        if(self->_peer){gst_object_unref(self->_peer);self->_peer=NULL;}
        if(self->_pipeline){gst_object_unref(self->_pipeline);self->_pipeline=NULL;}
#if TARGET_OS_IPHONE
        if(self->_audioSessionToken){ba_native_stream_audio_release(self->_audioSessionToken);self->_audioSessionToken=NULL;}
#endif
        if(request)[self send:@{@"event":@"stopped",@"request_id":request}];
        if(self->_clock){gst_object_unref(self->_clock);self->_clock=NULL;}
        self->_finished=true;::shutdown(self->_fd,SHUT_RDWR);
    });
}
- (void)serve {
    // Independent of the media context, callbacks and Erlang's terminate callback.
    std::thread watchdog([self] {
        while(!_finished) {
            if(!_stopping && (monotonicMS()-_lastControl.load()>2000 || (_clockExpires.load() && monotonicMS()>_clockExpires.load())))[self shutdownWithRequest:nil];
            uint64_t stop=_stopAt.load();
            if(_stopping && stop && monotonicMS()-stop>1500)_Exit(70);
            std::this_thread::sleep_for(std::chrono::milliseconds(20));
        }
    });
    @autoreleasepool {
        while(!_stopping) {
            uint32_t size;if(!exactRead(_fd,&size,4))break;
            size=ntohl(size);if(!size || size>131072)break;
            NSMutableData *data=[NSMutableData dataWithLength:size];if(!exactRead(_fd,data.mutableBytes,size))break;
            NSDictionary *c=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if(![c isKindOfClass:NSDictionary.class])break;
            NSString *op=c[@"op"];
            if(!_generation) {
                if(![op isEqual:@"hello"] || ![c[@"version"] isEqual:@2] ||
                    ![c[@"generation"] isKindOfClass:NSString.class] || [c[@"generation"] length]!=32)break;
                _generation=[c[@"generation"] copy];
                [self send:@{@"event":@"hello",@"version":@2,@"profile":@"gst_aac_rtp_v2",
                    @"owner_loss_stop":@YES,@"stop_ack":@YES,@"schedule":@YES}];continue;
            }
            if(![c[@"generation"] isEqual:_generation])break;
            _lastControl=monotonicMS();
            if([op isEqual:@"heartbeat"])continue;
            if([op isEqual:@"stop"]){[self shutdownWithRequest:c[@"request_id"]];break;}
            enqueue(^{if(!self->_stopping)[self command:c];});
        }
        [self shutdownWithRequest:nil];
    }
    watchdog.join();close(_fd);
}
- (BOOL)applyClock:(NSDictionary *)c {
    uint64_t internal,session,revision=[c[@"revision"] unsignedLongLongValue];
    double ppm=[c[@"correction_ppm"] doubleValue],limit=[c[@"max_absolute_ppm"] doubleValue];
    NSString *timeline=c[@"timeline"];
    if(!readNS(c[@"internal_ns"],internal) || !readNS(c[@"session_ns"],session) || session>UINT64_MAX-NtpUnixOffset ||
        ![timeline isKindOfClass:NSString.class] || !timeline.length || revision<=_clockRevision ||
        !std::isfinite(ppm) || !std::isfinite(limit) || limit<0 || limit>500 || fabs(ppm)>limit ||
        (_timeline && ![_timeline isEqual:timeline]))return NO;
    if(!_clockUpdates.load())gst_clock_set_calibration(_clock,internal,session+NtpUnixOffset,1,1);
    else {
        uint64_t now=gst_clock_get_internal_time(_clock),i,e,n,d;gst_clock_get_calibration(_clock,&i,&e,&n,&d);
        uint64_t external=gst_clock_adjust_with_calibration(_clock,now,i,e,n,d);
        gst_clock_set_calibration(_clock,now,external,1000000000LL+llround(ppm*1000),1000000000);
    }
    _correctionPPM=ppm;
    _timeline=[timeline copy];_clockRevision=revision;_clockExpires=monotonicMS()+12000;++_clockUpdates;
    [self send:@{@"event":@"clock_mapped",@"revision":@(revision)}];return YES;
}
- (void)command:(NSDictionary *)c {
    if([c[@"op"] isEqual:@"clock"]){
        uint64_t internal=gst_clock_get_internal_time(_clock),i,e,n,d;gst_clock_get_calibration(_clock,&i,&e,&n,&d);
        id mapped=_clockUpdates.load()?nsText(gst_clock_adjust_with_calibration(_clock,internal,i,e,n,d)-NtpUnixOffset):(id)NSNull.null;
        [self send:@{@"event":@"clock",@"sent_ns":c[@"sent_ns"],@"internal_ns":nsText(internal),@"session_ns":mapped}];return;
    }
    if([c[@"op"] isEqual:@"clock_map"]){if(![self applyClock:c])fail(self,@"invalid_native_clock_mapping");return;}

    NSString *op=c[@"op"];
    if([op isEqual:@"prepare"]) {
        if(_prepared){fail(self,@"native_already_prepared");return;}
        if(!_clockUpdates.load()){fail(self,@"native_clock_mapping_required");return;}
        _provider=[c[@"role"] isEqual:@"provider"];_synthetic=[c[@"synthetic"] isEqual:@YES];
        _rate=[c[@"rate"] unsignedIntValue];_channels=[c[@"channels"] unsignedIntValue];
        int delay=[c[@"buffer_ms"] intValue];
        if((_rate!=44100 && _rate!=48000) || _channels!=2 || delay<0 || delay>10000){fail(self,@"unsupported_native_format_or_buffer");return;}
        _responseNS=(uint64_t)delay*GST_MSECOND;_jitterLatencyMS=(uint32_t)delay;
        NSString *source=_synthetic ? @"audiotestsrc name=generator is-live=true wave=sine volume=0.02 samplesperbuffer=1024" : @"appsrc name=capture is-live=true format=time block=false max-bytes=4194304";
        NSString *graph;
        if(_provider)graph=[NSString stringWithFormat:
            @"webrtcbin name=peer bundle-policy=max-bundle %@ ! audio/x-raw,format=F32LE,layout=interleaved,rate=%u,channels=2 ! audioconvert ! atenc bitrate=320000 ! audio/mpeg,mpegversion=4,stream-format=raw,profile=lc ! rtpmp4gpay pt=96 ! application/x-rtp,media=audio,encoding-name=MPEG4-GENERIC ! peer.",source,_rate];
        else graph=[NSString stringWithFormat:
            @"webrtcbin name=peer latency=%d bundle-policy=max-bundle queue name=received max-size-buffers=0 max-size-bytes=16777216 max-size-time=10000000000 ! rtpmp4gdepay ! aacparse ! atdec ! audioconvert ! audio/x-raw,format=F32LE,channels=2 ! identity name=count ! audioresample ! volume name=volume mute=true ! %@",delay,
#if TARGET_OS_IPHONE
            @"osxaudiosink name=output sync=true provide-clock=false slave-method=resample"
#else
            [c[@"silent"] isEqual:@YES] ? @"fakesink name=output sync=true async=false signal-handoffs=true render-delay=200000000 max-lateness=20000000" : @"osxaudiosink name=output sync=true provide-clock=false slave-method=resample"
#endif
        ];
#if TARGET_OS_IPHONE
        if(!_provider && !(_audioSessionToken=ba_native_stream_audio_acquire())){fail(self,@"native_audio_session_failed");return;}
#endif
        GError *error=NULL;_pipeline=gst_parse_launch(graph.UTF8String,&error);
        if(error || !_pipeline){if(error)g_error_free(error);fail(self,@"native_pipeline_prepare_failed");return;}
        gst_pipeline_use_clock(GST_PIPELINE(_pipeline),_clock);
        gst_element_set_start_time(_pipeline,GST_CLOCK_TIME_NONE);gst_element_set_base_time(_pipeline,0);
        if(_synthetic){GstElement *generator=gst_bin_get_by_name(GST_BIN(_pipeline),"generator");g_object_set(generator,"timestamp-offset",(gint64)gst_clock_get_time(_clock),NULL);gst_object_unref(generator);}
        _peer=gst_bin_get_by_name(GST_BIN(_pipeline),"peer");_volume=gst_bin_get_by_name(GST_BIN(_pipeline),"volume");
        {std::lock_guard<std::mutex> lock(_inputLock);_input=gst_bin_get_by_name(GST_BIN(_pipeline),"capture");}
        _rtpbin=gst_bin_get_by_name(GST_BIN(_peer),"rtpbin");
        if(!_rtpbin){fail(self,@"native_rtpbin_unavailable");return;}
        g_object_set(_rtpbin,"ntp-time-source",3,"rtcp-sync-send-time",FALSE,"ntp-sync",TRUE,
            "add-reference-timestamp-meta",TRUE,"buffer-mode",0,NULL);
        _output=gst_bin_get_by_name(GST_BIN(_pipeline),"output");
        if(!_provider){
            sinkSchedule(self);
#if !TARGET_OS_IPHONE
            if([c[@"silent"] isEqual:@YES])g_signal_connect(_output,"handoff",G_CALLBACK(rendered),(__bridge void *)self);
#endif
            GstElement *counter=gst_bin_get_by_name(GST_BIN(_pipeline),"count");GstPad *pad=gst_element_get_static_pad(counter,"sink");
            gst_pad_add_probe(pad,GST_PAD_PROBE_TYPE_BUFFER,countBuffer,(__bridge void *)self,NULL);gst_object_unref(pad);gst_object_unref(counter);
            g_signal_connect(_peer,"pad-added",G_CALLBACK((+[](GstElement *,GstPad *pad,gpointer p){
                BANativePeer *self=(__bridge BANativePeer *)p;
                if(GST_PAD_DIRECTION(pad)!=GST_PAD_SRC)return;
                gst_pad_add_probe(pad,GST_PAD_PROBE_TYPE_BUFFER,mappedRTP,(__bridge void *)self,NULL);
                GstElement *queue=gst_bin_get_by_name(GST_BIN(self->_pipeline),"received");GstPad *sink=gst_element_get_static_pad(queue,"sink");
                if(!gst_pad_is_linked(sink) && gst_pad_link(pad,sink)!=GST_PAD_LINK_OK)fail(self,@"native_track_link_failed");
                gst_object_unref(sink);gst_object_unref(queue);
            })),(__bridge void *)self);
        }
        for(NSDictionary *server in c[@"ice_servers"])for(NSString *url in server[@"urls"]){
            if([url hasPrefix:@"stun:"])g_object_set(_peer,"stun-server",[[url stringByReplacingCharactersInRange:NSMakeRange(0,5) withString:@"stun://"] UTF8String],NULL);
            if([url hasPrefix:@"turn:"] || [url hasPrefix:@"turns:"]){fail(self,@"native_turn_configuration_not_implemented");return;}
        }
        g_signal_connect(_peer,"on-ice-candidate",G_CALLBACK((+[](GstElement *,guint line,gchar *candidate,gpointer p){
            [(__bridge BANativePeer *)p send:@{@"event":@"candidate",@"candidate":@(candidate),@"mid":@"audio0",@"line":@(line)}];
        })),(__bridge void *)self);
        g_signal_connect(_peer,"on-negotiation-needed",G_CALLBACK((+[](GstElement *,gpointer p){
            BANativePeer *self=(__bridge BANativePeer *)p;
            enqueue(^{if(self->_provider && !self->_offered && !self->_stopping){self->_offered=true;g_signal_emit_by_name(self->_peer,"create-offer",NULL,descriptionPromise(self));}});
        })),(__bridge void *)self);
        g_signal_connect(_peer,"notify::connection-state",G_CALLBACK((+[](GObject *peer,GParamSpec *,gpointer p){
            BANativePeer *self=(__bridge BANativePeer *)p;GstWebRTCPeerConnectionState state;
            g_object_get(peer,"connection-state",&state,NULL);
            if(state==GST_WEBRTC_PEER_CONNECTION_STATE_CONNECTED){
                self->_connectedAt=monotonicMS();
                [self send:@{@"event":@"connected",@"synchronized":@NO}];
                enqueue(^{if(!self->_stopping){setupReports(self);requestReport(self);}});
            }
            if(state==GST_WEBRTC_PEER_CONNECTION_STATE_FAILED)fail(self,@"native_transport_failed");
        })),(__bridge void *)self);
        GstBus *bus=gst_element_get_bus(_pipeline);_bus=gst_bus_create_watch(bus);gst_object_unref(bus);
        g_source_set_callback(_bus,(GSourceFunc)(void *)+[](GstBus *,GstMessage *message,gpointer p)->gboolean{
            BANativePeer *self=(__bridge BANativePeer *)p;
            if(GST_MESSAGE_TYPE(message)==GST_MESSAGE_LATENCY){gst_bin_recalculate_latency(GST_BIN(self->_pipeline));sinkSchedule(self);}
            if(GST_MESSAGE_TYPE(message)==GST_MESSAGE_ERROR){GError *error=NULL;gchar *debug=NULL;gst_message_parse_error(message,&error,&debug);
                NSLog(@"Native media: %s",error->message);g_error_free(error);g_free(debug);fail((__bridge BANativePeer *)p,@"native_pipeline_failed");}return G_SOURCE_CONTINUE;
        },(__bridge void *)self,NULL);g_source_attach(_bus,mediaContext);
        if(_provider){
            setupReports(self);_rtcpTimer=g_timeout_source_new(5000);
            g_source_set_callback(_rtcpTimer,[](gpointer p)->gboolean{BANativePeer *self=(__bridge BANativePeer *)p;setupReports(self);requestReport(self);return G_SOURCE_CONTINUE;},(__bridge void *)self,NULL);
            g_source_attach(_rtcpTimer,mediaContext);
        }
        _prepared=true;
        if(gst_element_set_state(_pipeline,GST_STATE_PLAYING)==GST_STATE_CHANGE_FAILURE){fail(self,@"native_pipeline_start_failed");return;}
        [self send:@{@"event":@"prepared",@"codec":@"aac_lc",@"bitrate":@320000}];return;
    }
#if !TARGET_OS_IPHONE
    if([op isEqual:@"test_block_media"] && getenv("BA_NATIVE_STREAM_TESTING")){
        std::this_thread::sleep_for(std::chrono::seconds(10));return;
    }
#endif
    if(!_prepared){fail(self,@"native_not_prepared");return;}
    if([op isEqual:@"offer"] || [op isEqual:@"answer"]){
        GstSDPMessage *sdp=NULL;gst_sdp_message_new(&sdp);NSString *text=c[@"sdp"];
        if(![text isKindOfClass:NSString.class] || _remoteReady ||
            gst_sdp_message_parse_buffer((const guint8 *)text.UTF8String,(guint)strlen(text.UTF8String),sdp)!=GST_SDP_OK){
            gst_sdp_message_free(sdp);fail(self,@"invalid_native_description");return;}
        auto kind=[op isEqual:@"offer"] ? GST_WEBRTC_SDP_TYPE_OFFER : GST_WEBRTC_SDP_TYPE_ANSWER;
        GstWebRTCSessionDescription *description=gst_webrtc_session_description_new(kind,sdp);
        g_signal_emit_by_name(_peer,"set-remote-description",description,gst_promise_new_with_change_func(remoteApplied,(__bridge_retained void *)self,releasePeer));
        gst_webrtc_session_description_free(description);
    } else if([op isEqual:@"candidate"]){
        if(_remoteReady)g_signal_emit_by_name(_peer,"add-ice-candidate",[c[@"line"] intValue],[c[@"candidate"] UTF8String]);
        else if(_candidates.count<32)[_candidates addObject:c];else fail(self,@"native_candidates_full");
    } else if([op isEqual:@"play"] || [op isEqual:@"pause"]){

        if(_volume)g_object_set(_volume,"mute",[op isEqual:@"pause"],NULL);
        [self send:@{@"event":[op isEqual:@"play"] ? @"playing" : @"paused"}];
    } else if([op isEqual:@"gain"]){double gain=[c[@"gain"] doubleValue];if(gain>=0 && gain<=1 && _volume)g_object_set(_volume,"volume",gain,NULL);
    } else if([op isEqual:@"stats"]){
        guint64 rendered=0,dropped=0;
        if(_output){GstStructure *stats=gst_base_sink_get_stats(GST_BASE_SINK(_output));
            gst_structure_get_uint64(stats,"rendered",&rendered);gst_structure_get_uint64(stats,"dropped",&dropped);gst_structure_free(stats);}
        [self send:@{@"event":@"stats",@"frames":@(_frames.load()),@"dropped":@(_dropped.load()),@"synchronized":@NO,
        @"sink_rendered_buffers":@(rendered),@"sink_dropped_buffers":@(dropped),@"jitter_buffer_ms":@(_jitterLatencyMS),
        @"render_delay_ns":_output?nsText(gst_base_sink_get_render_delay(GST_BASE_SINK(_output))):@"0",
        @"capture_clock_skew_ns":[NSString stringWithFormat:@"%lld",(long long)_captureClockSkew.load()],@"correction_ppm":@(_correctionPPM.load()),
        @"clock_updates":@(_clockUpdates.load()),@"rtcp_mapped_packets":@(_mappedPackets.load()),@"unmapped_packets":@(_unmappedPackets.load()),
        @"sender_reports":@(_senderReports.load()),@"rendered_frames":@(_renderedFrames.load()),@"max_schedule_error_ns":nsText(_maxScheduleError.load()),
        @"mapping_acquired_ms":_firstMappedAt.load()?@(MAX((int64_t)_firstMappedAt.load()-(int64_t)_connectedAt.load(),0)):(id)NSNull.null,
        @"presentation_schedule_execution":@(_mappedPackets.load()>0)}];
    } else fail(self,@"unsupported_native_control");
}
- (void)capture:(NSData *)pcm frames:(uint32_t)frames rate:(uint32_t)rate channels:(uint32_t)channels position:(int64_t)position host:(uint64_t)host {
    if(_stopping)return;
    std::lock_guard<std::mutex> lock(_inputLock);
    if(!_input)return;
    if(rate!=_rate || channels!=_channels){++_dropped;return;}
    if(gst_app_src_get_current_level_bytes(GST_APP_SRC(_input))+pcm.length>4*1024*1024){++_dropped;return;}
    GstBuffer *buffer=gst_buffer_new_allocate(NULL,pcm.length,NULL);gst_buffer_fill(buffer,0,pcm.bytes,pcm.length);
    if(!_sourceAnchored){
        uint64_t nativeNow=hostNS(),clockNow=gst_clock_get_time(_clock);
        _sourceAnchorTime=host<=nativeNow?clockNow-(nativeNow-host):clockNow+(host-nativeNow);
        _sourceAnchorPosition=position;_sourceAnchorHost=host;_sourceAnchored=true;
    }
    if(position<_sourceAnchorPosition){gst_buffer_unref(buffer);fail(self,@"native_capture_discontinuity");return;}
    uint64_t sampleElapsed=gst_util_uint64_scale(position-_sourceAnchorPosition,GST_SECOND,_rate);
    _captureClockSkew=(int64_t)sampleElapsed-((int64_t)host-(int64_t)_sourceAnchorHost);
    GST_BUFFER_PTS(buffer)=_sourceAnchorTime+sampleElapsed;
    GST_BUFFER_DURATION(buffer)=gst_util_uint64_scale(frames,GST_SECOND,_rate);
    gst_app_src_push_buffer(GST_APP_SRC(_input),buffer);
}
@end

@implementation BAGStreamerStreamHost {
    int _listener;
    std::mutex _peersLock;
    NSMutableArray<BANativePeer *> *_peers;
    uint32_t _rate,_channels,_bytesPerFrame,_flags;
}
- (uint16_t)start:(NSError **)error {
#if TARGET_OS_IPHONE
    if(!ba_gstreamer_initialize(error))return 0;
#endif
    static dispatch_once_t once;
    dispatch_once(&once,^{
        gst_init(NULL,NULL);mediaContext=g_main_context_new();
        std::thread([]{g_main_context_push_thread_default(mediaContext);g_main_loop_run(g_main_loop_new(mediaContext,FALSE));}).detach();
    });
    _peers=[NSMutableArray array];_listener=socket(AF_INET,SOCK_STREAM,0);
    sockaddr_in address={};address.sin_family=AF_INET;address.sin_addr.s_addr=htonl(INADDR_LOOPBACK);socklen_t size=sizeof(address);
    if(_listener<0 || bind(_listener,(sockaddr *)&address,size) || listen(_listener,16) || getsockname(_listener,(sockaddr *)&address,&size)){
        if(error)*error=[NSError errorWithDomain:@"Native stream listener" code:errno userInfo:nil];
        if(_listener>=0)close(_listener);_listener=-1;return 0;}
    int listener=_listener;
    std::thread([self,listener]{for(;;){int fd=accept(listener,NULL,NULL);if(fd<0)break;
        BANativePeer *peer=[[BANativePeer alloc]initWithSocket:fd];
        {std::lock_guard<std::mutex> lock(_peersLock);[_peers addObject:peer];}
        std::thread([self,peer]{[peer serve];std::lock_guard<std::mutex> lock(_peersLock);[_peers removeObject:peer];}).detach();
    }}).detach();return ntohs(address.sin_port);
}
- (void)stop {
    if(_listener>=0){::shutdown(_listener,SHUT_RDWR);close(_listener);_listener=-1;}
    NSArray *peers;{std::lock_guard<std::mutex> lock(_peersLock);peers=[_peers copy];}
    for(BANativePeer *peer in peers)[peer shutdownWithRequest:nil];uint64_t start=monotonicMS();
    for(BANativePeer *peer in peers)while(!peer->_finished){if(monotonicMS()-start>1500)_Exit(70);std::this_thread::sleep_for(std::chrono::milliseconds(10));}
}
- (void)captureFormat:(const void *)metadata size:(uint32_t)size {
    if(size!=44)_Exit(65);const uint8_t *p=(const uint8_t *)metadata;double rate;memcpy(&rate,p,8);
    memcpy(&_flags,p+12,4);memcpy(&_bytesPerFrame,p+24,4);memcpy(&_channels,p+28,4);
    uint32_t bits;memcpy(&bits,p+32,4);_rate=(uint32_t)rate;
    if(!(_flags&1) || (_flags&2) || bits!=32 || _channels!=2 || (_rate!=44100 && _rate!=48000))_Exit(65);
}
- (void)captureBlock:(const void *)block size:(uint32_t)size {
    if(size<32 || !_channels)return;const uint8_t *p=(const uint8_t *)block,*end=p+size;
    uint64_t hostTicks;double samplePosition;uint32_t flags;
    memcpy(&hostTicks,p,8);memcpy(&samplePosition,p+8,8);memcpy(&flags,p+24,4);
    if((flags&3)!=3 || !std::isfinite(samplePosition) || fabs(samplePosition)>9007199254740991.0)return;
    mach_timebase_info_data_t scale;mach_timebase_info(&scale);
    uint64_t captureHost=hostTicks/scale.denom*scale.numer+hostTicks%scale.denom*scale.numer/scale.denom;
    uint32_t count;memcpy(&count,p+28,4);p+=32;std::vector<const uint8_t *> planes;std::vector<uint32_t> lengths;
    for(uint32_t i=0;i<count;++i){if(end-p<8)return;uint32_t channels,bytes;memcpy(&channels,p,4);memcpy(&bytes,p+4,4);p+=8;
        if((uint64_t)(end-p)<bytes || channels!=((_flags&32)?1:_channels))return;
        planes.push_back(p);lengths.push_back(bytes);p+=bytes;}
    if(p!=end || count!=((_flags&32)?_channels:1))return;uint32_t frames=lengths[0]/_bytesPerFrame;
    for(auto length:lengths)if(length!=lengths[0])return;
    NSMutableData *pcm=[NSMutableData dataWithLength:(size_t)frames*_channels*4];
    if(_flags&32)for(uint32_t f=0;f<frames;++f)for(uint32_t c=0;c<_channels;++c)
        memcpy((uint8_t *)pcm.mutableBytes+((size_t)f*_channels+c)*4,planes[c]+f*4,4);
    else memcpy(pcm.mutableBytes,planes[0],pcm.length);
    std::lock_guard<std::mutex> lock(_peersLock);
    for(BANativePeer *peer in _peers)[peer capture:pcm frames:frames rate:_rate channels:_channels position:(int64_t)llround(samplePosition) host:captureHost];
}
@end
