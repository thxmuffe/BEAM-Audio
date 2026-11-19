#import "IOSGStreamerRuntime.h"
#include <gst/gst.h>

GST_PLUGIN_STATIC_DECLARE(coreelements);
GST_PLUGIN_STATIC_DECLARE(app);
GST_PLUGIN_STATIC_DECLARE(audioparsers);
GST_PLUGIN_STATIC_DECLARE(audioconvert);
GST_PLUGIN_STATIC_DECLARE(audioresample);
GST_PLUGIN_STATIC_DECLARE(volume);
GST_PLUGIN_STATIC_DECLARE(rtp);
GST_PLUGIN_STATIC_DECLARE(rtpmanager);
GST_PLUGIN_STATIC_DECLARE(webrtc);
GST_PLUGIN_STATIC_DECLARE(nice);
GST_PLUGIN_STATIC_DECLARE(dtls);
GST_PLUGIN_STATIC_DECLARE(srtp);
GST_PLUGIN_STATIC_DECLARE(sctp);
GST_PLUGIN_STATIC_DECLARE(osxaudio);

BOOL ba_gstreamer_initialize(NSError **error) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        g_setenv("GST_PLUGIN_SYSTEM_PATH", "", TRUE);
        // iOS device processes cannot allocate ORC executable code pages.
        g_setenv("ORC_CODE", "backup", TRUE);
        gst_init(NULL, NULL);
        GST_PLUGIN_STATIC_REGISTER(coreelements);
        GST_PLUGIN_STATIC_REGISTER(app);
        GST_PLUGIN_STATIC_REGISTER(audioparsers);
        GST_PLUGIN_STATIC_REGISTER(audioconvert);
        GST_PLUGIN_STATIC_REGISTER(audioresample);
        GST_PLUGIN_STATIC_REGISTER(volume);
        GST_PLUGIN_STATIC_REGISTER(rtp);
        GST_PLUGIN_STATIC_REGISTER(rtpmanager);
        GST_PLUGIN_STATIC_REGISTER(webrtc);
        GST_PLUGIN_STATIC_REGISTER(nice);
        GST_PLUGIN_STATIC_REGISTER(dtls);
        GST_PLUGIN_STATIC_REGISTER(srtp);
        GST_PLUGIN_STATIC_REGISTER(sctp);
        GST_PLUGIN_STATIC_REGISTER(osxaudio);
    });
    for (NSString *name in @[@"webrtcbin", @"nicesrc", @"dtlsdec", @"srtpdec", @"appsrc",
                             @"rtpmp4gpay", @"rtpmp4gdepay", @"aacparse", @"atenc", @"atdec", @"osxaudiosink"]) {
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
