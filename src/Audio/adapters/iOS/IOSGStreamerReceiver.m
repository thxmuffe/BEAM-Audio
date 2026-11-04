#import "IOSGStreamerReceiver.h"
#if !__has_feature(objc_arc)
#error "IOSGStreamerReceiver requires -fobjc-arc for callback and meter ownership"
#endif
#include <gst/gst.h>
#include <gst/sdp/sdp.h>
#define GST_USE_UNSTABLE_API
#include <gst/webrtc/webrtc.h>
#include <mach/mach_time.h>

// Link only the plugins used by the receiver, not the SDK's complete plugin set.
GST_PLUGIN_STATIC_DECLARE(coreelements);
GST_PLUGIN_STATIC_DECLARE(audioconvert);
GST_PLUGIN_STATIC_DECLARE(audioresample);
GST_PLUGIN_STATIC_DECLARE(volume);
GST_PLUGIN_STATIC_DECLARE(level);
GST_PLUGIN_STATIC_DECLARE(opus);
GST_PLUGIN_STATIC_DECLARE(rtp);
GST_PLUGIN_STATIC_DECLARE(rtpmanager);
GST_PLUGIN_STATIC_DECLARE(webrtc);
GST_PLUGIN_STATIC_DECLARE(nice);
GST_PLUGIN_STATIC_DECLARE(dtls);
GST_PLUGIN_STATIC_DECLARE(srtp);
GST_PLUGIN_STATIC_DECLARE(sctp);
GST_PLUGIN_STATIC_DECLARE(osxaudio);

static GMainContext *mediaContext;
static gpointer runMediaLoop(gpointer loop) {
    g_main_context_push_thread_default(mediaContext);
    g_main_loop_run(loop);
    return NULL;
}
static void releaseObject(gpointer object) { (void)CFBridgingRelease(object); }
static void releaseSignalObject(gpointer object, GClosure *closure) { releaseObject(object); }
static gboolean runBlock(gpointer object) {
    @autoreleasepool { ((__bridge dispatch_block_t)object)(); }
    return G_SOURCE_REMOVE;
}
static void enqueue(dispatch_block_t block) {
    GSource *source = g_idle_source_new();
    g_source_set_callback(source, runBlock, (void *)CFBridgingRetain([block copy]), releaseObject);
    g_source_attach(source, mediaContext);
    g_source_unref(source);
}
static guint64 hostNS(void) {
    mach_timebase_info_data_t scale; mach_timebase_info(&scale);
    guint64 ticks = mach_absolute_time();
    return ticks / scale.denom * scale.numer + ticks % scale.denom * scale.numer / scale.denom;
}

@interface IOSGStreamerReceiver () {
@public // File-local C callbacks use these; none appear in the public header.
    GstElement *_pipeline, *_peer, *_volume, *_output;
    GSource *_busSource;
    BOOL _closed, _playing, _remoteReady, _offered;
    NSMutableArray<NSDictionary *> *_candidates;
    id _minimumDelay;
    NSDictionary *_levels;
    guint64 _levelHostNS;
    void (^_events)(NSDictionary *);
}
- (void)send:(NSDictionary *)event;
- (void)fail:(NSString *)message;
- (void)prepare:(NSDictionary *)command;
- (void)offer;
- (void)statistics;
@end

static GstPromise *promiseFor(GstPromiseChangeFunc callback, IOSGStreamerReceiver *self) {
    return gst_promise_new_with_change_func(callback, (void *)CFBridgingRetain(self), releaseObject);
}
static void offerCreated(GstPromise *promise, gpointer data) {
    @autoreleasepool {
        IOSGStreamerReceiver *self = (__bridge id)data;
        GstWebRTCSessionDescription *offer = NULL;
        if (gst_promise_wait(promise) == GST_PROMISE_RESULT_REPLIED) {
            const GstStructure *reply = gst_promise_get_reply(promise);
            if (reply) gst_structure_get(reply, "offer", GST_TYPE_WEBRTC_SESSION_DESCRIPTION, &offer, NULL);
        }
        enqueue(^{
            if (!self->_closed && offer) {
                g_signal_emit_by_name(self->_peer, "set-local-description", offer, NULL);
                gchar *text = gst_sdp_message_as_text(offer->sdp);
                [self send:@{@"event": @"offer", @"sdp": @(text)}]; g_free(text);
            } else if (!self->_closed) [self fail:@"Cannot create GStreamer audio offer"];
            if (offer) gst_webrtc_session_description_free(offer);
        });
        gst_promise_unref(promise);
    }
}
static void answerApplied(GstPromise *promise, gpointer data) {
    @autoreleasepool {
        IOSGStreamerReceiver *self = (__bridge id)data;
        BOOL replied = gst_promise_wait(promise) == GST_PROMISE_RESULT_REPLIED;
        const GstStructure *reply = replied ? gst_promise_get_reply(promise) : NULL;
        const GValue *value = reply ? gst_structure_get_value(reply, "error") : NULL;
        NSString *error = value ? @(((GError *)g_value_get_boxed(value))->message) : nil;
        enqueue(^{
            if (self->_closed) return;
            if (!replied || error) { [self fail:error ?: @"Cannot apply GStreamer audio answer"]; return; }
            self->_remoteReady = YES;
            for (NSDictionary *candidate in self->_candidates)
                g_signal_emit_by_name(self->_peer, "add-ice-candidate",
                    [candidate[@"sdpMLineIndex"] unsignedIntValue], [candidate[@"candidate"] UTF8String]);
            [self->_candidates removeAllObjects];
        });
        gst_promise_unref(promise);
    }
}
static void negotiationNeeded(GstElement *peer, gpointer data) {
    @autoreleasepool {
        IOSGStreamerReceiver *self = (__bridge id)data;
        enqueue(^{ [self offer]; });
    }
}
static void iceCandidate(GstElement *peer, guint index, gchar *candidate, gpointer data) {
    @autoreleasepool {
        IOSGStreamerReceiver *self = (__bridge id)data;
        if (!candidate || !*candidate) return;
        NSDictionary *value = @{@"candidate": @(candidate), @"sdpMLineIndex": @(index), @"sdpMid": @"audio0"};
        enqueue(^{ [self send:@{@"event": @"candidate", @"candidate": value}]; });
    }
}
static void connectionChanged(GObject *peer, GParamSpec *spec, gpointer data) {
    @autoreleasepool {
        IOSGStreamerReceiver *self = (__bridge id)data;
        GstWebRTCPeerConnectionState state;
        g_object_get(peer, "connection-state", &state, NULL);
        enqueue(^{
            if (state == GST_WEBRTC_PEER_CONNECTION_STATE_CONNECTED) [self send:@{@"event": @"connected"}];
            else if (state == GST_WEBRTC_PEER_CONNECTION_STATE_FAILED) [self fail:@"GStreamer audio connection failed"];
        });
    }
}
static void padAdded(GstElement *peer, GstPad *pad, gpointer data) {
    @autoreleasepool {
        IOSGStreamerReceiver *self = (__bridge id)data;
        if (GST_PAD_DIRECTION(pad) != GST_PAD_SRC) return;
        GstElement *queue = gst_bin_get_by_name(GST_BIN(self->_pipeline), "audio_queue");
        GstPad *sink = gst_element_get_static_pad(queue, "sink");
        if (!gst_pad_is_linked(sink) && gst_pad_link(pad, sink) != GST_PAD_LINK_OK)
            enqueue(^{ [self fail:@"Cannot link GStreamer received audio"]; });
        gst_object_unref(sink); gst_object_unref(queue);
    }
}
// The level plugin reports per-channel GValueArray dB values in this pinned SDK.
// Summarize the loudest channel; this is a digital sample meter, not true peak.
static double channelMaximum(const GstStructure *message, const char *field) {
    const GValue *value = gst_structure_get_value(message, field);
    if (!value) return -96.0;
    GValueArray *array = g_value_get_boxed(value);
    double maximum = -96.0;
    if (array) for (guint i = 0; i < array->n_values; i++) {
        double db = g_value_get_double(&array->values[i]);
        if (isfinite(db)) maximum = MAX(maximum, db);
    }
    return maximum;
}
static gboolean busMessage(GstBus *bus, GstMessage *message, gpointer data) {
    @autoreleasepool {
        IOSGStreamerReceiver *self = (__bridge id)data;
        if (GST_MESSAGE_TYPE(message) == GST_MESSAGE_ERROR) {
            GError *error = NULL; gchar *debug = NULL;
            gst_message_parse_error(message, &error, &debug);
            [self fail:@(error->message)]; g_clear_error(&error); g_free(debug);
        } else if (GST_MESSAGE_TYPE(message) == GST_MESSAGE_ELEMENT) {
            const GstStructure *levels = gst_message_get_structure(message);
            if (levels && gst_structure_has_name(levels, "level")) {
                double peak = channelMaximum(levels, "peak");
                // Keep a peak hold until the next statistics reply.
                double held = [self->_levels[@"samplePeakDb"] doubleValue];
                self->_levels = @{@"samplePeakDb": @(self->_levels ? MAX(held, peak) : peak),
                                  @"sampleRmsDb": @(channelMaximum(levels, "rms"))};
                self->_levelHostNS = hostNS();
            }
        } else if (GST_MESSAGE_TYPE(message) == GST_MESSAGE_LATENCY) {
            gst_bin_recalculate_latency(GST_BIN(self->_pipeline));
        }
        return G_SOURCE_CONTINUE;
    }
}
static void statsReceived(GstPromise *promise, gpointer data) {
    @autoreleasepool {
        IOSGStreamerReceiver *self = (__bridge id)data;
        NSMutableDictionary *stats = [NSMutableDictionary dictionary];
        const GstStructure *reply = gst_promise_wait(promise) == GST_PROMISE_RESULT_REPLIED
            ? gst_promise_get_reply(promise) : NULL;
        if (reply) for (int i = 0; i < gst_structure_n_fields(reply); i++) {
            const GValue *value = gst_structure_get_value(reply, gst_structure_nth_field_name(reply, i));
            if (!GST_VALUE_HOLDS_STRUCTURE(value)) continue;
            const GstStructure *row = gst_value_get_structure(value);
            const GValue *type = gst_structure_get_value(row, "type");
            if (!type || g_value_get_enum(type) != GST_WEBRTC_STATS_INBOUND_RTP) continue;
            NSDictionary *keys = @{@"packets-received": @"packetsReceived", @"bytes-received": @"bytesReceived",
                @"packets-lost": @"packetsLost", @"jitter": @"jitter"};
            for (NSString *key in keys) {
                const GValue *v = gst_structure_get_value(row, key.UTF8String);
                if (!v) continue;
                if (G_VALUE_HOLDS_UINT64(v)) stats[keys[key]] = @(g_value_get_uint64(v));
                else if (G_VALUE_HOLDS_INT64(v)) stats[keys[key]] = @(g_value_get_int64(v));
                else if (G_VALUE_HOLDS_UINT(v)) stats[keys[key]] = @(g_value_get_uint(v));
                else if (G_VALUE_HOLDS_DOUBLE(v)) stats[keys[key]] = @(g_value_get_double(v));
            }
        }
        enqueue(^{
            if (self->_closed) return;
            if (self->_levels && hostNS() - self->_levelHostNS < GST_SECOND) {
                [stats addEntriesFromDictionary:self->_levels];
                self->_levels = nil;
            }
            stats[@"event"] = @"stats"; stats[@"backend"] = @"gstreamer_webrtc";
            stats[@"outputTrackEnabled"] = @(self->_playing);
            stats[@"outputSourceSampleMappingAvailable"] = @NO;
            stats[@"estimatedPlayoutTimestampAvailable"] = @NO;
            stats[@"minimumDelayControlAvailable"] = @YES;
            stats[@"requestedMinimumDelayMs"] = self->_minimumDelay;
            GstStructure *output = NULL; g_object_get(self->_output, "stats", &output, NULL);
            if (output) {
                guint64 rendered = 0, dropped = 0;
                gst_structure_get_uint64(output, "rendered", &rendered);
                gst_structure_get_uint64(output, "dropped", &dropped);
                stats[@"outputRenderedBuffers"] = @(rendered); stats[@"outputDroppedBuffers"] = @(dropped);
                gst_structure_free(output);
            }
            [self send:stats];
        });
        gst_promise_unref(promise);
    }
}

@implementation IOSGStreamerReceiver
+ (BOOL)initializeEngine:(NSError **)error {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        g_setenv("GST_PLUGIN_SYSTEM_PATH", "", TRUE);
        // iOS device processes cannot allocate ORC executable code pages.
        g_setenv("ORC_CODE", "backup", TRUE);
        gst_init(NULL, NULL);
        GST_PLUGIN_STATIC_REGISTER(coreelements);
        GST_PLUGIN_STATIC_REGISTER(audioconvert); GST_PLUGIN_STATIC_REGISTER(audioresample);
        GST_PLUGIN_STATIC_REGISTER(volume); GST_PLUGIN_STATIC_REGISTER(level); GST_PLUGIN_STATIC_REGISTER(opus);
        GST_PLUGIN_STATIC_REGISTER(rtp); GST_PLUGIN_STATIC_REGISTER(rtpmanager);
        GST_PLUGIN_STATIC_REGISTER(webrtc); GST_PLUGIN_STATIC_REGISTER(nice);
        GST_PLUGIN_STATIC_REGISTER(dtls); GST_PLUGIN_STATIC_REGISTER(srtp);
        GST_PLUGIN_STATIC_REGISTER(sctp); GST_PLUGIN_STATIC_REGISTER(osxaudio);
        mediaContext = g_main_context_new();
        GMainLoop *loop = g_main_loop_new(mediaContext, FALSE);
        g_thread_unref(g_thread_new("opensound-media", runMediaLoop, loop));
    });
    for (NSString *name in @[@"webrtcbin", @"nicesrc", @"dtlsdec", @"srtpdec", @"rtpopusdepay", @"opusdec", @"level", @"osxaudiosink"]) {
        GstElementFactory *factory = gst_element_factory_find(name.UTF8String);
        if (!factory) {
            if (error) *error = [NSError errorWithDomain:@"GStreamer" code:1 userInfo:
                @{NSLocalizedDescriptionKey: [@"Missing GStreamer element: " stringByAppendingString:name]}];
            return NO;
        }
        gst_object_unref(factory);
    }
    return YES;
}
- (instancetype)initWithEvents:(void (^)(NSDictionary *))events {
    if ((self = [super init])) { _events = [events copy]; _candidates = [NSMutableArray array]; _minimumDelay = NSNull.null; }
    return self;
}
- (void)send:(NSDictionary *)event { if (!_closed) _events(event); }
- (void)fail:(NSString *)message { [self send:@{@"event": @"error", @"error": message}]; }
- (void)prepare:(NSDictionary *)command {
    if (_pipeline) return;
    GError *error = NULL;
    _pipeline = gst_parse_launch("webrtcbin name=peer bundle-policy=max-bundle latency=200 "
        "queue name=audio_queue ! rtpopusdepay ! opusdec plc=true ! audioconvert ! audioresample ! "
        "audio/x-raw,format=F32LE,rate=48000,channels=2 ! volume name=volume mute=true ! "
        "level name=meter interval=100000000 post-messages=true ! "
        "osxaudiosink name=output sync=true async=false enable-last-sample=false", &error);
    if (error) { [self fail:@(error->message)]; g_clear_error(&error); return; }
    _peer = gst_bin_get_by_name(GST_BIN(_pipeline), "peer");
    _volume = gst_bin_get_by_name(GST_BIN(_pipeline), "volume");
    _output = gst_bin_get_by_name(GST_BIN(_pipeline), "output");
    for (NSDictionary *server in command[@"ice_servers"]) {
        id urls = server[@"urls"]; if ([urls isKindOfClass:NSString.class]) urls = @[urls];
        for (NSString *url in urls) if ([url hasPrefix:@"stun:"]) {
            NSString *host = [url substringFromIndex:5];
            if ([host hasPrefix:@"//"]) host = [host substringFromIndex:2];
            g_object_set(_peer, "stun-server", [@"stun://" stringByAppendingString:host].UTF8String, NULL);
        }
    }
    g_signal_connect_data(_peer, "on-negotiation-needed", G_CALLBACK(negotiationNeeded),
        (void *)CFBridgingRetain(self), releaseSignalObject, 0);
    g_signal_connect_data(_peer, "on-ice-candidate", G_CALLBACK(iceCandidate),
        (void *)CFBridgingRetain(self), releaseSignalObject, 0);
    g_signal_connect_data(_peer, "pad-added", G_CALLBACK(padAdded),
        (void *)CFBridgingRetain(self), releaseSignalObject, 0);
    g_signal_connect_data(_peer, "notify::connection-state", G_CALLBACK(connectionChanged),
        (void *)CFBridgingRetain(self), releaseSignalObject, 0);
    GstBus *bus = gst_element_get_bus(_pipeline); _busSource = gst_bus_create_watch(bus);
    g_source_set_callback(_busSource, (GSourceFunc)busMessage, (void *)CFBridgingRetain(self), releaseObject);
    g_source_attach(_busSource, mediaContext); gst_object_unref(bus);
    GstCaps *caps = gst_caps_from_string("application/x-rtp,media=audio,encoding-name=OPUS,clock-rate=48000,"
        "encoding-params=(string)2,payload=111,stereo=(string)1,sprop-stereo=(string)1,useinbandfec=(string)1");
    GstWebRTCRTPTransceiver *transceiver = NULL;
    g_signal_emit_by_name(_peer, "add-transceiver", GST_WEBRTC_RTP_TRANSCEIVER_DIRECTION_RECVONLY, caps, &transceiver);
    if (transceiver) gst_object_unref(transceiver); gst_caps_unref(caps);
    if (gst_element_set_state(_pipeline, GST_STATE_PLAYING) == GST_STATE_CHANGE_FAILURE)
        [self fail:@"Cannot start GStreamer audio output"];
}
- (void)offer {
    if (_closed || !_peer || _offered) return;
    _offered = YES;
    g_signal_emit_by_name(_peer, "create-offer", NULL, promiseFor(offerCreated, self));
}
- (void)statistics { if (_peer) g_signal_emit_by_name(_peer, "get-stats", NULL, promiseFor(statsReceived, self)); }
- (void)handleCommand:(NSDictionary *)command {
    enqueue(^{
        if (self->_closed) return;
        NSString *op = command[@"op"];
        if ([op isEqual:@"prepare"]) { [self prepare:command]; return; }
        if (!self->_pipeline) { [self fail:@"GStreamer receiver is not prepared"]; return; }
        if ([op isEqual:@"answer"]) {
            GstSDPMessage *sdp = NULL;
            if (gst_sdp_message_new_from_text([command[@"sdp"] UTF8String], &sdp) != GST_SDP_OK) {
                [self fail:@"Invalid SDP answer"]; return;
            }
            GstWebRTCSessionDescription *answer = gst_webrtc_session_description_new(GST_WEBRTC_SDP_TYPE_ANSWER, sdp);
            g_signal_emit_by_name(self->_peer, "set-remote-description", answer, promiseFor(answerApplied, self));
            gst_webrtc_session_description_free(answer);
        } else if ([op isEqual:@"candidate"]) {
            NSDictionary *c = command[@"candidate"];
            if (![c[@"candidate"] length]) return;
            if (self->_remoteReady) g_signal_emit_by_name(self->_peer, "add-ice-candidate",
                [c[@"sdpMLineIndex"] unsignedIntValue], [c[@"candidate"] UTF8String]);
            else [self->_candidates addObject:c];
        } else if ([op isEqual:@"play"] || [op isEqual:@"pause"]) {
            self->_playing = [op isEqual:@"play"];
            g_object_set(self->_volume, "mute", !self->_playing, NULL);
            [self send:@{@"event": self->_playing ? @"playing" : @"paused"}];
        } else if ([op isEqual:@"minimum_delay"]) {
            id value = command[@"delay_ms"];
            BOOL valid = value == NSNull.null || ([value isKindOfClass:NSNumber.class]
                && CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID()
                && isfinite([value doubleValue]) && [value doubleValue] >= 0 && [value doubleValue] <= 10000);
            if (valid) {
                self->_minimumDelay = value;
                g_object_set(self->_peer, "latency", value == NSNull.null ? 200u : (guint)llround([value doubleValue]), NULL);
            }
            [self send:@{@"event": @"minimum_delay", @"configured": @(valid), @"request_id": command[@"request_id"] ?: NSNull.null}];
        } else if ([op isEqual:@"clock"]) {
            [self send:@{@"event": @"clock", @"sent_ns": command[@"sent_ns"], @"host_ns": @(hostNS())}];
        } else if ([op isEqual:@"stats"]) [self statistics];
    });
}
- (void)close {
    enqueue(^{
        if (self->_closed) return;
        self->_closed = YES;
        if (self->_busSource) { g_source_destroy(self->_busSource); g_source_unref(self->_busSource); self->_busSource = NULL; }
        if (self->_pipeline) {
            gst_element_set_state(self->_pipeline, GST_STATE_NULL);
            if (self->_peer) gst_object_unref(self->_peer);
            if (self->_volume) gst_object_unref(self->_volume);
            if (self->_output) gst_object_unref(self->_output);
            gst_object_unref(self->_pipeline);
            self->_pipeline = self->_peer = self->_volume = self->_output = NULL;
        }
        self->_events = nil;
    });
}
@end
