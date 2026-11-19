"""Load the pinned, private macOS SDK for the retained media experiments."""
import os
import sys


def load_runtime(runtime):
    if sys.platform != 'darwin' or sys.version_info[:2] != (3, 9):
        raise RuntimeError('Use macOS /usr/bin/python3 (3.9) and --runtime; see README.')
    runtime = runtime.resolve()
    sys.path.insert(0, str(runtime / 'lib/python3.9/site-packages'))
    os.environ['GI_TYPELIB_PATH'] = str(runtime / 'lib/girepository-1.0')
    os.environ['GST_PLUGIN_SYSTEM_PATH_1_0'] = str(runtime.parent / 'plugins')
    os.environ['GST_REGISTRY_1_0'] = str(runtime.parent / 'experiment-registry.bin')
    import gi
    gi.require_version('GIRepository', '2.0')
    from gi.repository import GIRepository
    GIRepository.Repository.prepend_library_path(str(runtime / 'lib'))
    for namespace in ['Gst', 'GstRtp', 'GstWebRTC', 'GstSdp']:
        gi.require_version(namespace, '1.0')
    from gi.repository import GLib, Gst, GstRtp
    Gst.init(None)
    return GLib, Gst, GstRtp
