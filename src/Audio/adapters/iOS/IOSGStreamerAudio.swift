import Foundation
import AVFAudio
import Darwin

/// Same local packet-4 control protocol as libwebrtc; media stays in GStreamer.
final class IOSGStreamerAudio {
    private var listener: Int32 = -1
    private var client: Int32 = -1
    private let lock = NSLock()

    func start() throws -> UInt16 {
        try IOSGStreamerReceiver.initializeEngine()
        var port: UInt16 = 0
        listener = parvi_bridge_listen(&port)
        guard listener >= 0 else { throw NSError(domain: "GStreamer audio", code: 1) }
        setenv("PARVI_AUDIO_ENGINE", "gstreamer", 1)
        NSLog("Audio receiver: GStreamer 1.28.8")
        let fd = listener
        DispatchQueue.global(qos: .userInitiated).async {
            while true {
                let accepted = parvi_bridge_accept(fd)
                guard accepted >= 0 else { return }
                self.lock.lock()
                guard self.listener == fd else { self.lock.unlock(); close(accepted); return }
                self.client = accepted; self.lock.unlock()
                GStreamerAudioConnection(socket: accepted).serve()
                self.lock.lock(); self.client = -1; self.lock.unlock()
            }
        }
        return port
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        if client >= 0 { shutdown(client, SHUT_RDWR) }
        if listener >= 0 { shutdown(listener, SHUT_RDWR); close(listener); listener = -1 }
    }
}

private final class GStreamerAudioConnection {
    private let socket: Int32
    private let writeLock = NSLock()
    private var closed = false
    private var receiver: IOSGStreamerReceiver?
    private var observers: [NSObjectProtocol] = []

    init(socket: Int32) {
        self.socket = socket
        var noSignal: Int32 = 1
        setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
    }

    func serve() {
        receiver = IOSGStreamerReceiver(events: { [weak self] event in self?.send(event) })
        defer {
            observers.forEach(NotificationCenter.default.removeObserver)
            receiver?.close(); receiver = nil
            writeLock.lock(); closed = true; shutdown(socket, SHUT_RDWR); close(socket); writeLock.unlock()
        }
        do {
            while true {
                let size = try read(4).reduce(0) { ($0 << 8) | Int($1) }
                guard size > 0 && size <= 131072,
                      let command = try JSONSerialization.jsonObject(with: read(size)) as? [String: Any]
                else { throw NSError(domain: "GStreamer audio", code: 2) }
                if command["op"] as? String == "prepare" {
                    let session = AVAudioSession.sharedInstance()
                    try session.setCategory(.playback, mode: .default)
                    try session.setPreferredSampleRate(48000)
                    try session.setActive(true)
                    if observers.isEmpty {
                        for name in [AVAudioSession.routeChangeNotification, AVAudioSession.interruptionNotification] {
                            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] notification in
                                if name == AVAudioSession.routeChangeNotification,
                                   let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                                   AVAudioSession.RouteChangeReason(rawValue: raw) == .categoryChange { return }
                                self?.send(["event": "error", "error": "Audio route changed; stop and subscribe again"])
                            })
                        }
                    }
                }
                receiver?.handleCommand(command)
            }
        } catch {
            send(["event": "error", "error": error.localizedDescription])
        }
    }

    private func send(_ event: [AnyHashable: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: event) else { return }
        var count = UInt32(data.count).bigEndian
        let packet = withUnsafeBytes(of: &count) { Data($0) } + data
        writeLock.lock(); defer { writeLock.unlock() }
        guard !closed else { return }
        packet.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let sent = Darwin.send(socket, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
                if sent < 0 && errno == EINTR { continue }
                guard sent > 0 else { shutdown(socket, SHUT_RDWR); return }
                offset += sent
            }
        }
    }

    private func read(_ size: Int) throws -> Data {
        var data = Data(count: size)
        try data.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < size {
                let received = recv(socket, bytes.baseAddress!.advanced(by: offset), size - offset, 0)
                if received < 0 && errno == EINTR { continue }
                guard received > 0 else { throw NSError(domain: "GStreamer audio connection closed", code: 3) }
                offset += received
            }
        }
        return data
    }
}
