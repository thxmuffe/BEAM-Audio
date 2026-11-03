import Foundation
import AudioToolbox
import WebRTC
import Darwin

private let writeLock = NSLock()
private func send(_ message: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
    writeLock.lock(); defer { writeLock.unlock() }
    FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10]))
}
private func cpuSeconds() -> Double {
    var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
        + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
}
private func hostNS() -> UInt64 {
    var scale = mach_timebase_info_data_t(); mach_timebase_info(&scale)
    let ticks = mach_absolute_time()
    return ticks / UInt64(scale.denom) * UInt64(scale.numer)
        + ticks % UInt64(scale.denom) * UInt64(scale.numer) / UInt64(scale.denom)
}

// Silent, fixed 10 ms output device. Only buffer transfer/timestamps live here;
// this is not a speaker, resampler or replacement for NetEq's recovery policy.
private final class SilentDevice: NSObject, RTCAudioDevice {
    private var delegate: RTCAudioDeviceDelegate?
    private let condition = NSCondition()
    private var stopping = false
    private var finished = true
    private var audio = Data()
    private var blocks: [[UInt64]] = []
    private var statuses: [Int32] = []
    private var overruns = 0
    private(set) var isInitialized = false
    private(set) var isPlayoutInitialized = false
    private(set) var isPlaying = false
    let isRecordingInitialized = false
    let isRecording = false
    let deviceInputSampleRate = 48000.0
    let inputIOBufferDuration = 0.01
    let inputNumberOfChannels = 1
    let inputLatency = 0.0
    let deviceOutputSampleRate = 48000.0
    let outputIOBufferDuration = 0.01
    let outputNumberOfChannels = 2
    let outputLatency = 0.0
    func initialize(with delegate: RTCAudioDeviceDelegate) -> Bool {
        self.delegate = delegate; isInitialized = true; return true
    }
    func initializePlayout() -> Bool { isPlayoutInitialized = true; return true }
    func startPlayout() -> Bool {
        if isPlaying { return true }
        _ = initializePlayout()
        delegate?.dispatchSync {
            self.delegate?.notifyAudioOutputInterrupted()
            self.delegate?.notifyAudioOutputParametersChange()
        }
        condition.lock(); stopping = false; finished = false; condition.unlock()
        isPlaying = true
        Thread.detachNewThread { [self] in render() }
        return true
    }
    private func render() {
        var scale = mach_timebase_info_data_t(); mach_timebase_info(&scale)
        let step = UInt64(10_000_000) * UInt64(scale.denom) / UInt64(scale.numer)
        var deadline = mach_absolute_time()
        var position: UInt64 = 0
        var samples = [Int16](repeating: 0, count: 960)
        while true {
            condition.lock(); let done = stopping; condition.unlock()
            if done { break }
            mach_wait_until(deadline)
            let now = mach_absolute_time()
            if now > deadline + step { overruns += 1 }
            var flags = AudioUnitRenderActionFlags()
            var timestamp = AudioTimeStamp()
            timestamp.mHostTime = deadline; timestamp.mSampleTime = Double(position)
            timestamp.mFlags = [.hostTimeValid, .sampleTimeValid]
            let observed = hostNS()
            let status = samples.withUnsafeMutableBytes { bytes -> OSStatus in
                var output = AudioBufferList(mNumberBuffers: 1,
                    mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: 1920, mData: bytes.baseAddress))
                return delegate?.getPlayoutData(&flags, &timestamp, 0, 480, &output) ?? -1
            }
            audio.append(samples.withUnsafeBytes { Data($0) })
            blocks.append([observed, position, 480])
            if status != noErr { statuses.append(status) }
            position += 480; deadline += step
        }
        condition.lock(); finished = true; condition.broadcast(); condition.unlock()
    }
    func stopPlayout() -> Bool {
        condition.lock(); stopping = true
        while !finished { condition.wait() }
        condition.unlock(); isPlaying = false; return true
    }
    func terminateDevice() -> Bool {
        _ = stopPlayout(); delegate = nil; isInitialized = false; return true
    }
    func initializeRecording() -> Bool { false }
    func startRecording() -> Bool { false }
    func stopRecording() -> Bool { true }
    func save(_ path: String) -> [String: Any] {
        _ = stopPlayout()
        try? audio.write(to: URL(fileURLWithPath: path))
        return ["pcm_path": path, "output_blocks": blocks, "output_frames": audio.count / 4,
                "output_status_errors": statuses, "timer_overruns": overruns]
    }
}

private final class Receiver: NSObject, RTCPeerConnectionDelegate {
    private let device = SilentDevice()
    private var factory: RTCPeerConnectionFactory?
    private var pc: RTCPeerConnection?
    private var pending: [RTCIceCandidate] = []
    private var ready = false
    private let path: String
    init(path: String) { self.path = path; super.init() }
    func handle(_ command: [String: Any]) {
        switch command["op"] as? String {
        case "prepare":
            RTCInitializeSSL()
            factory = RTCPeerConnectionFactory(encoderFactory: nil, decoderFactory: nil, audioDevice: device)
            let config = RTCConfiguration(); config.sdpSemantics = .unifiedPlan
            pc = factory?.peerConnection(with: config,
                constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil), delegate: self)
            send(["event": "ready"])
        case "clock": send(["event": "clock", "host_ns": hostNS()])
        case "offer":
            guard let pc, let sdp = command["sdp"] as? String, !sdp.isEmpty else { return }
            pc.setRemoteDescription(RTCSessionDescription(type: .offer, sdp: sdp)) { [self] error in
                if let error { send(["event": "error", "error": error.localizedDescription]); return }
                ready = true; pending.forEach { pc.add($0, completionHandler: { _ in }) }; pending.removeAll()
                pc.answer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { answer, error in
                    guard let answer, error == nil else { send(["event": "error", "error": "No SDP answer"]); return }
                    pc.setLocalDescription(answer) { error in
                        if let error { send(["event": "error", "error": error.localizedDescription]); return }
                        send(["event": "answer", "sdp": answer.sdp])
                    }
                }
            }
        case "candidate":
            guard let c = command["candidate"] as? [String: Any], let sdp = c["candidate"] as? String, !sdp.isEmpty else { return }
            let candidate = RTCIceCandidate(sdp: sdp, sdpMLineIndex: Int32(c["sdpMLineIndex"] as? Int ?? 0), sdpMid: c["sdpMid"] as? String)
            if ready { pc?.add(candidate, completionHandler: { _ in }) } else { pending.append(candidate) }
        case "minimum_delay":
            let delay = command["seconds"] as? NSNumber
            let receivers = pc?.receivers ?? []
            let configured = !receivers.isEmpty && receivers.allSatisfy { ParviWebRTCSetMinimumDelay($0, delay) }
            send(["event": "minimum_delay", "configured": configured])
        case "stats", "finish":
            pc?.statistics { [self] report in
                var stats: [String: Any] = [:]
                for row in report.statistics.values where row.type == "inbound-rtp" {
                    for key in ["packetsReceived", "packetsLost", "bytesReceived", "jitter", "concealedSamples",
                        "totalSamplesReceived", "concealmentEvents", "insertedSamplesForDeceleration",
                        "removedSamplesForAcceleration", "jitterBufferDelay", "jitterBufferEmittedCount"] {
                        if let value = row.values[key] { stats[key] = value }
                    }
                }
                DispatchQueue.main.async { [self] in
                    stats["cpu_seconds"] = cpuSeconds()
                    stats["host_ns"] = hostNS()
                    stats["request_id"] = command["request_id"] ?? ""
                    if command["op"] as? String == "finish" {
                        pc?.close()
                        stats.merge(device.save(path)) { _, new in new }
                        stats["event"] = "finished"
                        send(stats); exit(0)
                    } else {
                        stats["event"] = "stats"; send(stats)
                    }
                }
            }
        default: break
        }
    }
    func peerConnection(_ pc: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ pc: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ pc: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ pc: RTCPeerConnection) {}
    func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        if newState == .failed { send(["event": "error", "error": "ICE failed"]) }
    }
    func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ pc: RTCPeerConnection, didGenerate c: RTCIceCandidate) {
        send(["event": "candidate", "candidate": ["candidate": c.sdp, "sdpMid": c.sdpMid ?? "0", "sdpMLineIndex": c.sdpMLineIndex]])
    }
    func peerConnection(_ pc: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ pc: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}

@main private struct Main {
    static func main() {
        let receiver = Receiver(path: CommandLine.arguments[1])
        DispatchQueue.global().async {
            while let line = readLine(), let data = line.data(using: .utf8) {
                guard let command = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
                DispatchQueue.main.async { receiver.handle(command) }
            }
            DispatchQueue.main.async { exit(0) }
        }
        RunLoop.main.run()
    }
}
