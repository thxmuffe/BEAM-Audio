#import "GStreamerStreamHost.h"
#import <TargetConditionals.h>
#if TARGET_OS_IPHONE
#import <AVFAudio/AVFAudio.h>
#import "../iOS/IOSGStreamerReceiver.h"
extern "C" void *ba_native_stream_audio_acquire(void);
extern "C" void ba_native_stream_audio_release(void *);
#endif
#include <gst/gst.h>
#include <gst/app/gstappsrc.h>
#include <gst/sdp/sdp.h>
#define GST_USE_UNSTABLE_API
#include <gst/webrtc/webrtc.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <unistd.h>
#include <atomic>
#include <thread>
#include <mutex>
#include <vector>
#include <chrono>
#include <cstring>

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
    GstElement *_pipeline,*_peer,*_input,*_volume;
    GSource *_bus;
    NSMutableArray<NSDictionary *> *_candidates;
    bool _prepared,_remoteReady,_provider,_synthetic,_offered;
    NSString *_generation;
    uint32_t _rate,_channels;
    uint64_t _capturePosition;
#if TARGET_OS_IPHONE
    void *_audioSessionToken;
#endif
}
- (instancetype)initWithSocket:(int)fd;
- (void)serve;
- (void)send:(NSDictionary *)event;
- (void)command:(NSDictionary *)command;
- (void)shutdownWithRequest:(nullable NSNumber *)request;
- (void)capture:(NSData *)pcm frames:(uint32_t)frames rate:(uint32_t)rate channels:(uint32_t)channels;
@end

static void fail(BANativePeer *self,NSString *reason) {
    [self send:@{@"event":@"error",@"error":reason}];[self shutdownWithRequest:nil];
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
        _frames=0;_dropped=0;_candidates=[NSMutableArray array];
        int yes=1;setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&yes,sizeof(yes));
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
        if(self->_bus){g_source_destroy(self->_bus);g_source_unref(self->_bus);self->_bus=NULL;}
        if(self->_volume){gst_object_unref(self->_volume);self->_volume=NULL;}
        if(self->_peer){gst_object_unref(self->_peer);self->_peer=NULL;}
        if(self->_pipeline){gst_object_unref(self->_pipeline);self->_pipeline=NULL;}
#if TARGET_OS_IPHONE
        if(self->_audioSessionToken){ba_native_stream_audio_release(self->_audioSessionToken);self->_audioSessionToken=NULL;}
#endif
        if(request)[self send:@{@"event":@"stopped",@"request_id":request}];
        self->_finished=true;::shutdown(self->_fd,SHUT_RDWR);
    });
}
- (void)serve {
    // Independent of the media context, callbacks and Erlang's terminate callback.
    std::thread watchdog([self] {
        while(!_finished) {
            if(!_stopping && monotonicMS()-_lastControl.load()>2000)[self shutdownWithRequest:nil];
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
                [self send:@{@"event":@"hello",@"version":@2,@"profile":@"gst_aac_rtp_v1",
                    @"owner_loss_stop":@YES,@"stop_ack":@YES,@"schedule":@NO}];continue;
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
- (void)command:(NSDictionary *)c {
    NSString *op=c[@"op"];
    if([op isEqual:@"prepare"]) {
        if(_prepared || ![c[@"diagnostic_unsynchronized"] isEqual:@YES]){fail(self,@"native_schedule_not_implemented");return;}
        _provider=[c[@"role"] isEqual:@"provider"];_synthetic=[c[@"synthetic"] isEqual:@YES];
        _rate=[c[@"rate"] unsignedIntValue];_channels=[c[@"channels"] unsignedIntValue];
        int delay=[c[@"buffer_ms"] intValue];
        if((_rate!=44100 && _rate!=48000) || _channels!=2 || delay<0 || delay>10000){fail(self,@"unsupported_native_format_or_buffer");return;}
        NSString *source=_synthetic ? @"audiotestsrc is-live=true wave=sine volume=0.02 samplesperbuffer=1024" : @"appsrc name=capture is-live=true format=time block=false max-bytes=4194304";
        NSString *graph;
        if(_provider)graph=[NSString stringWithFormat:
            @"webrtcbin name=peer bundle-policy=max-bundle %@ ! audio/x-raw,format=F32LE,layout=interleaved,rate=%u,channels=2 ! audioconvert ! atenc bitrate=320000 ! audio/mpeg,mpegversion=4,stream-format=raw,profile=lc ! rtpmp4gpay pt=96 ! application/x-rtp,media=audio,encoding-name=MPEG4-GENERIC ! peer.",source,_rate];
        else graph=[NSString stringWithFormat:
            @"webrtcbin name=peer latency=%d bundle-policy=max-bundle queue name=received max-size-buffers=0 max-size-bytes=16777216 max-size-time=10000000000 ! rtpmp4gdepay ! aacparse ! atdec ! audioconvert ! audio/x-raw,format=F32LE,channels=2 ! identity name=count ! audioresample ! volume name=volume mute=true ! %@",delay,
#if TARGET_OS_IPHONE
            @"osxaudiosink sync=true"
#else
            [c[@"silent"] isEqual:@YES] ? @"fakesink sync=true async=false" : @"osxaudiosink sync=true"
#endif
        ];
#if TARGET_OS_IPHONE
        if(!_provider && !(_audioSessionToken=ba_native_stream_audio_acquire())){fail(self,@"native_audio_session_failed");return;}
#endif
        GError *error=NULL;_pipeline=gst_parse_launch(graph.UTF8String,&error);
        if(error || !_pipeline){if(error)g_error_free(error);fail(self,@"native_pipeline_prepare_failed");return;}
        _peer=gst_bin_get_by_name(GST_BIN(_pipeline),"peer");_volume=gst_bin_get_by_name(GST_BIN(_pipeline),"volume");
        {std::lock_guard<std::mutex> lock(_inputLock);_input=gst_bin_get_by_name(GST_BIN(_pipeline),"capture");}
        if(!_provider){
            GstElement *counter=gst_bin_get_by_name(GST_BIN(_pipeline),"count");GstPad *pad=gst_element_get_static_pad(counter,"sink");
            gst_pad_add_probe(pad,GST_PAD_PROBE_TYPE_BUFFER,countBuffer,(__bridge void *)self,NULL);gst_object_unref(pad);gst_object_unref(counter);
            g_signal_connect(_peer,"pad-added",G_CALLBACK((+[](GstElement *,GstPad *pad,gpointer p){
                BANativePeer *self=(__bridge BANativePeer *)p;
                if(GST_PAD_DIRECTION(pad)!=GST_PAD_SRC)return;
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
            if(state==GST_WEBRTC_PEER_CONNECTION_STATE_CONNECTED)[self send:@{@"event":@"connected",@"synchronized":@NO}];
            if(state==GST_WEBRTC_PEER_CONNECTION_STATE_FAILED)fail(self,@"native_transport_failed");
        })),(__bridge void *)self);
        GstBus *bus=gst_element_get_bus(_pipeline);_bus=gst_bus_create_watch(bus);gst_object_unref(bus);
        g_source_set_callback(_bus,(GSourceFunc)(void *)+[](GstBus *,GstMessage *message,gpointer p)->gboolean{
            if(GST_MESSAGE_TYPE(message)==GST_MESSAGE_ERROR){GError *error=NULL;gchar *debug=NULL;gst_message_parse_error(message,&error,&debug);
                NSLog(@"Native media: %s",error->message);g_error_free(error);g_free(debug);fail((__bridge BANativePeer *)p,@"native_pipeline_failed");}return G_SOURCE_CONTINUE;
        },(__bridge void *)self,NULL);g_source_attach(_bus,mediaContext);
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
    } else if([op isEqual:@"stats"]){[self send:@{@"event":@"stats",@"frames":@(_frames.load()),@"dropped":@(_dropped.load()),@"synchronized":@NO}];
    } else fail(self,@"unsupported_native_control");
}
- (void)capture:(NSData *)pcm frames:(uint32_t)frames rate:(uint32_t)rate channels:(uint32_t)channels {
    if(_stopping)return;
    std::lock_guard<std::mutex> lock(_inputLock);
    if(!_input)return;
    if(rate!=_rate || channels!=_channels){++_dropped;return;}
    if(gst_app_src_get_current_level_bytes(GST_APP_SRC(_input))+pcm.length>4*1024*1024){++_dropped;_capturePosition+=frames;return;}
    GstBuffer *buffer=gst_buffer_new_allocate(NULL,pcm.length,NULL);gst_buffer_fill(buffer,0,pcm.bytes,pcm.length);
    GST_BUFFER_PTS(buffer)=gst_util_uint64_scale(_capturePosition,GST_SECOND,_rate);
    GST_BUFFER_DURATION(buffer)=gst_util_uint64_scale(frames,GST_SECOND,_rate);_capturePosition+=frames;
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
    static dispatch_once_t once;
    dispatch_once(&once,^{
#if TARGET_OS_IPHONE
        [IOSGStreamerReceiver initializeEngine:nil];
#endif
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
    for(BANativePeer *peer in _peers)[peer capture:pcm frames:frames rate:_rate channels:_channels];
}
@end
