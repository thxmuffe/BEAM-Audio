import Foundation
import AVFAudio
import WebRTC
import Darwin

/// Native WebRTC audio comparison. Only signaling/status cross the local socket.
final class IOSWebRTCAudio {
    private var listener: Int32 = -1
    private var client: Int32 = -1
    private let lock = NSLock()
    func start() throws -> UInt16 {
        var port: UInt16 = 0
        listener = ba_bridge_listen(&port)
        guard listener >= 0 else { throw NSError(domain: "WebRTC audio", code: 1) }
        setenv("BA_AUDIO_ENGINE", "libwebrtc", 1)
        let fd = listener
        RTCInitializeSSL()
        DispatchQueue.global(qos: .userInitiated).async {
            while true {
                let accepted = ba_bridge_accept(fd)
                guard accepted >= 0 else { return }
                self.lock.lock()
                guard self.listener == fd else { self.lock.unlock(); close(accepted); return }
                self.client = accepted; self.lock.unlock()
                NativeAudioConnection(socket: accepted).serve()
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

private final class NativeAudioConnection: NSObject, RTCPeerConnectionDelegate {
    private let socket: Int32
    private let writeLock = NSLock()
    private let state = DispatchQueue(label: "org.beam-audio.native-audio-state")
    private var closed = false
    private var factory: RTCPeerConnectionFactory?
    private var audioDevice: WebRTCPlaybackDevice?
    private var pc: RTCPeerConnection?
    private var playing = false
    private var remoteReady = false
    private var candidates: [RTCIceCandidate] = []
    private var observers: [NSObjectProtocol] = []
    private var minimumDelayMS: Double?
    private var minimumDelayControlAvailable = false

    init(socket: Int32) {
        self.socket = socket
        super.init()
        var noSignal: Int32 = 1
        setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
    }

    func serve() {
        defer {
            observers.forEach(NotificationCenter.default.removeObserver)
            writeLock.lock(); closed = true; shutdown(socket, SHUT_RDWR); close(socket); writeLock.unlock()
            state.sync { pc?.close(); pc = nil }
        }
        do {
            while true {
                let header = try read(4)
                let size = header.reduce(0) { ($0 << 8) | Int($1) }
                guard size > 0 && size <= 131072,
                      let command = try JSONSerialization.jsonObject(with: read(size)) as? [String: Any]
                else { throw NSError(domain: "WebRTC audio", code: 2) }
                try state.sync { try handle(command) }
            }
        } catch { /* EOF tears down this native session; Erlang owns restart. */ }
    }

    private func handle(_ command: [String: Any]) throws {
        switch command["op"] as? String {
        case "prepare":
            guard pc == nil else { return }
            let output = WebRTCPlaybackDevice()
            audioDevice = output
            factory = RTCPeerConnectionFactory(encoderFactory: nil, decoderFactory: nil, audioDevice: output)
            let config = RTCConfiguration()
            config.sdpSemantics = .unifiedPlan
            config.iceServers = (command["ice_servers"] as? [[String: Any]] ?? []).map {
                RTCIceServer(urlStrings: $0["urls"] as? [String] ?? [],
                    username: $0["username"] as? String ?? "", credential: $0["credential"] as? String ?? "")
            }
            pc = factory?.peerConnection(with: config,
                constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil), delegate: self)
            guard let pc else { throw NSError(domain: "WebRTC audio", code: 3) }
            let transceiver = RTCRtpTransceiverInit()
            transceiver.direction = .recvOnly
            pc.addTransceiver(of: .audio, init: transceiver)
            updateTracks()
            pc.offer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { [weak self] offer, error in
                guard let self, let offer, error == nil else { self?.fail("Cannot create audio offer"); return }
                pc.setLocalDescription(offer) { error in
                    if error != nil { self.fail("Cannot set audio offer"); return }
                    self.send(["event": "offer", "sdp": offer.sdp])
                }
            }
            for name in [AVAudioSession.routeChangeNotification, AVAudioSession.interruptionNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] notification in
                    if name == AVAudioSession.routeChangeNotification,
                       let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                       AVAudioSession.RouteChangeReason(rawValue: raw) == .categoryChange { return }
                    self?.fail("Audio route changed; stop and subscribe again")
                })
            }
        case "answer":
            guard let sdp = command["sdp"] as? String, let pc else { return }
            pc.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: sdp)) { [weak self] error in
                guard let self else { return }
                if error != nil { self.fail("Cannot apply audio answer"); return }
                self.state.async {
                    self.remoteReady = true
                    self.candidates.forEach { pc.add($0, completionHandler: { _ in }) }
                    self.candidates.removeAll()
                    self.updateTracks()
                }
            }
        case "candidate":
            guard let value = command["candidate"] as? [String: Any], let sdp = value["candidate"] as? String else { return }
            let candidate = RTCIceCandidate(sdp: sdp, sdpMLineIndex: Int32(value["sdpMLineIndex"] as? Int ?? 0),
                                            sdpMid: value["sdpMid"] as? String)
            if remoteReady { pc?.add(candidate, completionHandler: { _ in }) } else { candidates.append(candidate) }
        case "play": playing = true; updateTracks(); send(["event": "playing"])
        case "pause": playing = false; updateTracks(); send(["event": "paused"])
        case "minimum_delay":
            let milliseconds = (command["delay_ms"] as? NSNumber)?.doubleValue
            guard command["delay_ms"] is NSNull ||
                    (milliseconds.map { $0.isFinite && $0 >= 0 && $0 <= 10000 } == true) else {
                send(["event": "minimum_delay", "configured": false,
                      "request_id": command["request_id"] ?? NSNull()]); return
            }
            let receivers = (pc?.receivers ?? []).filter { $0.track?.kind == "audio" }
            let seconds = milliseconds.map { NSNumber(value: $0 / 1000) }
            let configured = !receivers.isEmpty && receivers.allSatisfy { ba_webrtc_set_minimum_delay($0, seconds) }
            minimumDelayControlAvailable = configured
            if configured { minimumDelayMS = milliseconds }
            send(["event": "minimum_delay", "configured": configured,
                  "request_id": command["request_id"] ?? NSNull(),
                  "requested_ms": milliseconds.map { $0 as Any } ?? NSNull()])
        case "clock":
            if let sent = command["sent_ns"] {
                send(["event": "clock", "sent_ns": sent, "host_ns": hostNanoseconds()])
            }
        case "stats":
            // Snapshot public track-delivery metadata on the state queue.
            // This is not a timestamp for samples at the physical speaker.
            var source: RTCRtpSource?
            for receiver in pc?.receivers ?? [] {
                for candidate in receiver.sources where candidate.sourceType == .SSRC {
                    if candidate.timestampUs > (source?.timestampUs ?? -.infinity) { source = candidate }
                }
            }
            let deliverySource = source
            let observedHost = hostNanoseconds()
            var outputTiming = audioDevice?.timingSnapshot() ?? [:]
            outputTiming["outputTrackEnabled"] = playing
            let requestedDelay = minimumDelayMS
            let delayControlAvailable = minimumDelayControlAvailable
            pc?.statistics { [weak self] report in
                for row in report.statistics.values where row.type == "inbound-rtp" &&
                    ((row.values["kind"] as? String) == "audio" || (row.values["mediaType"] as? String) == "audio") {
                    let keys = ["packetsReceived", "bytesReceived", "packetsLost", "jitter", "concealedSamples",
                                "totalSamplesReceived", "jitterBufferDelay", "jitterBufferEmittedCount", "audioLevel",
                                "insertedSamplesForDeceleration", "removedSamplesForAcceleration",
                                "silentConcealedSamples", "concealmentEvents", "jitterBufferTargetDelay",
                                "jitterBufferMinimumDelay", "estimatedPlayoutTimestamp", "playoutId"]
                    var summary: [String: Any] = ["event": "stats"]
                    for key in keys { if let value = row.values[key] { summary[key] = value } }
                    summary.merge(outputTiming) { _, new in new }
                    // This is sender-NTP track time, not local speaker emission.
                    // Absence must be observable rather than hidden by our field filter.
                    summary["estimatedPlayoutTimestampAvailable"] = row.values["estimatedPlayoutTimestamp"] != nil
                    // Route reports, not measured capture-to-speaker latency.
                    let audioSession = AVAudioSession.sharedInstance()
                    summary["outputLatency"] = audioSession.outputLatency
                    summary["outputIOBufferDuration"] = audioSession.ioBufferDuration
                    summary["minimumDelayControlAvailable"] = delayControlAvailable
                    summary["requestedMinimumDelayMs"] = requestedDelay.map { $0 as Any } ?? NSNull()
                    if let source = deliverySource {
                        summary["sourceRtpTimestamp"] = source.rtpTimestamp
                        summary["sourceTimestampUs"] = source.timestampUs
                        summary["sourceObservedHostTimeNs"] = observedHost
                    }
                    self?.send(summary)
                }
            }
        default: break
        }
    }

    private func updateTracks() { state.async { self.pc?.receivers.forEach { $0.track?.isEnabled = self.playing } } }
    private func hostNanoseconds() -> UInt64 {
        UInt64(AVAudioTime.seconds(forHostTime: mach_absolute_time()) * 1_000_000_000)
    }
    private func fail(_ text: String) { send(["event": "error", "error": text]); shutdown(socket, SHUT_RDWR) }
    private func read(_ size: Int) throws -> Data {
        var result = Data(count: size)
        try result.withUnsafeMutableBytes { raw in
            var done = 0
            while done < size {
                let count = recv(socket, raw.baseAddress!.advanced(by: done), size - done, 0)
                guard count > 0 else { throw NSError(domain: "WebRTC audio socket", code: 1) }
                done += count
            }
        }
        return result
    }
    private func send(_ value: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: value) else { return }
        var size = UInt32(data.count).bigEndian
        var packet = Data(bytes: &size, count: 4); packet.append(data)
        writeLock.lock(); defer { writeLock.unlock() }
        guard !closed else { return }
        packet.withUnsafeBytes { raw in
            var done = 0
            while done < raw.count {
                let count = Darwin.send(socket, raw.baseAddress!.advanced(by: done), raw.count - done, 0)
                if count <= 0 { shutdown(socket, SHUT_RDWR); return }
                done += count
            }
        }
    }
    func peerConnection(_ pc: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ pc: RTCPeerConnection, didAdd stream: RTCMediaStream) { updateTracks() }
    func peerConnection(_ pc: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ pc: RTCPeerConnection) {}
    func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        if newState == .connected || newState == .completed { updateTracks(); send(["event": "connected"]) }
        if newState == .failed { fail("Native WebRTC audio connection failed") }
    }
    func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ pc: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        send(["event": "candidate", "candidate": ["candidate": candidate.sdp,
            "sdpMid": candidate.sdpMid ?? "0", "sdpMLineIndex": candidate.sdpMLineIndex]])
    }
    func peerConnection(_ pc: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ pc: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}
