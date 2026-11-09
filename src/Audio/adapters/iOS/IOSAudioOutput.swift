import AVFAudio
import Foundation
import Darwin

/// Thin local buffer binding. BEAM owns PCM conversion, packet order and deadlines.
final class IOSAudioOutput {
    private let queue = DispatchQueue(label: "org.beam-audio.audio-output")
    private let lock = NSLock()
    private var listener: Int32 = -1
    private var connection: Int32 = -1

    func start() throws -> UInt16 {
        var port: UInt16 = 0
        let fd = ba_bridge_listen(&port)
        guard fd >= 0 else { throw OutputError.failed }
        lock.lock(); listener = fd; lock.unlock()
        queue.async { [self] in
            while true {
                let client = ba_bridge_accept(fd)
                guard client >= 0 else { break }
                var noSignal: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
                lock.lock()
                guard listener == fd else { lock.unlock(); close(client); break }
                connection = client
                lock.unlock()
                serve(client)
                lock.lock(); connection = -1; lock.unlock()
                close(client)
            }
        }
        return port
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        if connection >= 0 { shutdown(connection, SHUT_RDWR) }
        if listener >= 0 { shutdown(listener, SHUT_RDWR); close(listener); listener = -1 }
    }

    private func serve(_ fd: Int32) {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        var sessionToken: UUID?
        let scheduled = IOSOutputQueue()
        var observers: [NSObjectProtocol] = []
        defer {
            observers.forEach(NotificationCenter.default.removeObserver)
            player.stop(); engine.stop()
            IOSAudioSession.shared.release(sessionToken)
        }
        do {
            let config = try readPacket(fd)
            guard config.count == 7, config[0] == 1 else { throw OutputError.failed }
            let rate = Int(integer(config, 1, 4)), channels = Int(integer(config, 5, 2))
            guard (1...2).contains(channels), (8000...192000).contains(rate),
                  let format = AVAudioFormat(standardFormatWithSampleRate: Double(rate),
                                             channels: AVAudioChannelCount(channels)) else { throw OutputError.failed }
            sessionToken = try IOSAudioSession.shared.acquire(microphone: false)
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            engine.prepare()
            try engine.start()
            player.play()
            // Interruptions or route/configuration changes end this output. No hidden restart policy.
            for name in [AVAudioSession.interruptionNotification, AVAudioSession.routeChangeNotification,
                         .AVAudioEngineConfigurationChange] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: name == .AVAudioEngineConfigurationChange ? engine : nil, queue: nil) { _ in
                    shutdown(fd, SHUT_RDWR)
                })
            }
            try writePacket(fd, Data([1]))
            while true {
                let packet = try readPacket(fd)
                switch packet.first {
                case 3:
                    let host = UInt64(AVAudioTime.seconds(forHostTime: mach_absolute_time()) * 1_000_000_000)
                    let latency = UInt64(max(0, player.outputPresentationLatency) * 1_000_000_000)
                    var response = Data([3]); append(host, to: &response); append(latency, to: &response)
                    try writePacket(fd, response)
                case 2:
                    guard packet.count >= 13 else { throw OutputError.failed }
                    let hostNS = integer(packet, 1, 8), frames = Int(integer(packet, 9, 4))
                    guard frames > 0, frames <= 4096, packet.count == 13 + frames * channels * 4,
                          let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
                          let planes = buffer.floatChannelData else { throw OutputError.failed }
                    buffer.frameLength = AVAudioFrameCount(frames)
                    packet.withUnsafeBytes { raw in
                        for channel in 0..<channels {
                            memcpy(planes[channel], raw.baseAddress!.advanced(by: 13 + channel * frames * 4), frames * 4)
                        }
                    }
                    let nowNS = UInt64(AVAudioTime.seconds(forHostTime: mach_absolute_time()) * 1_000_000_000)
                    guard hostNS > nowNS, hostNS - nowNS <= 35_000_000_000 else { throw OutputError.invalidTarget }
                    guard scheduled.reserve() else { throw OutputError.queueFull }
                    let host = AVAudioTime.hostTime(forSeconds: Double(hostNS) / 1_000_000_000)
                    player.scheduleBuffer(buffer, at: AVAudioTime(hostTime: host), options: [], completionCallbackType: .dataPlayedBack) { _ in scheduled.complete() }
                default: throw OutputError.failed
                }
            }
        } catch {
            // EOF, OS errors and interruptions close the binding; OTP reports/owns recovery.
            NSLog("BEAM Audio audio output closed: %@", error.localizedDescription)
            shutdown(fd, SHUT_RDWR)
        }
    }

    private enum OutputError: LocalizedError {
        case failed, invalidTarget, queueFull
        var errorDescription: String? {
            switch self {
            case .failed: return "Audio output closed or received an invalid local packet."
            case .invalidTarget: return "Audio presentation target is late or beyond the scheduling bound."
            case .queueFull: return "Native audio output scheduling queue is full."
            }
        }
    }
    private func readExactly(_ fd: Int32, _ count: Int) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { raw in
            var offset = 0
            while offset < count {
                let n = recv(fd, raw.baseAddress!.advanced(by: offset), count - offset, 0)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw OutputError.failed }
                offset += n
            }
        }
        return data
    }
    private func readPacket(_ fd: Int32) throws -> Data {
        let header = try readExactly(fd, 4), size = Int(integer(header, 0, 4))
        guard size > 0 && size <= 131072 else { throw OutputError.failed }
        return try readExactly(fd, size)
    }
    private func writePacket(_ fd: Int32, _ data: Data) throws {
        var bytes = Data(); append(UInt32(data.count), to: &bytes); bytes.append(data)
        try bytes.withUnsafeBytes { raw in
            var offset = 0
            while offset < bytes.count {
                let n = send(fd, raw.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw OutputError.failed }
                offset += n
            }
        }
    }
    private func integer(_ data: Data, _ offset: Int, _ count: Int) -> UInt64 {
        data[offset..<(offset + count)].reduce(0) { ($0 << 8) | UInt64($1) }
    }
    private func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var big = value.bigEndian
        withUnsafeBytes(of: &big) { data.append(contentsOf: $0) }
    }
}

private final class IOSOutputQueue {
    private let lock = NSLock()
    private var count = 0
    func reserve() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard count < 2048 else { return false }
        count += 1; return true
    }
    func complete() { lock.lock(); count = max(0, count - 1); lock.unlock() }
}
