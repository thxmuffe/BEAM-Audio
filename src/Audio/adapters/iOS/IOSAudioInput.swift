import AVFAudio
import CoreMedia
import Foundation
import Darwin
import ScreenCaptureKit

/// Packet-four local binding. Capture queues are bounded; no native networking,
/// source identities, mixing or presentation policy lives here.
final class IOSAudioInput {
    private let lock = NSLock()
    private var listener: Int32 = -1
    private var connections = Set<Int32>()
    @MainActor var broadcast: IOSBroadcastAuthorization?

    func start() throws -> UInt16 {
        var port: UInt16 = 0
        let fd = ba_bridge_listen(&port)
        guard fd >= 0 else { throw CaptureFailure("Could not create the capture binding.") }
        lock.lock(); listener = fd; lock.unlock()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            while true {
                let client = ba_bridge_accept(fd)
                guard client >= 0 else { break }
                lock.lock()
                guard listener == fd else { lock.unlock(); close(client); break }
                connections.insert(client); lock.unlock()
                DispatchQueue.global(qos: .userInitiated).async { [self] in
                    serve(client)
                    lock.lock(); connections.remove(client); lock.unlock()
                    close(client)
                }
            }
        }
        return port
    }
    func stop() {
        lock.lock(); defer { lock.unlock() }
        for fd in connections { shutdown(fd, SHUT_RDWR) }
        if listener >= 0 { shutdown(listener, SHUT_RDWR); close(listener); listener = -1 }
    }
    private func serve(_ fd: Int32) {
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
        let capture = IOSCaptureBuffers()
        var engine: AVAudioEngine?
        var session: UUID?
        var stopBroadcast: (() -> Void)?
        var observers: [NSObjectProtocol] = []
        defer {
            observers.forEach(NotificationCenter.default.removeObserver)
            engine?.inputNode.removeTap(onBus: 0); engine?.stop()
            stopBroadcast?(); IOSAudioSession.shared.release(session)
        }
        do {
            let config = try IOSCaptureWire.read(fd)
            guard config.count == 2, config[0] == 1 else { throw CaptureFailure("Invalid capture request.") }
            var rate: Int = 48000, channels: Int = 2
            if config[1] == 1 {
                guard AVAudioApplication.shared.recordPermission == .granted else { throw CaptureFailure("Microphone permission is required.") }
                session = try IOSAudioSession.shared.acquire(microphone: true)
                let audio = AVAudioEngine(); engine = audio
                let format = audio.inputNode.outputFormat(forBus: 0)
                rate = Int(format.sampleRate); channels = Int(format.channelCount)
                guard format.commonFormat == .pcmFormatFloat32, !format.isInterleaved,
                      (1...2).contains(channels), (8000...192000).contains(rate) else {
                    throw CaptureFailure("Unsupported microphone PCM format.")
                }
                audio.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, time in
                    guard time.isHostTimeValid else { capture.fail("Microphone supplied no capture timestamp."); return }
                    capture.append(buffer, host: UInt64(AVAudioTime.seconds(forHostTime: time.hostTime) * 1_000_000_000))
                }
                audio.prepare(); try audio.start()
                for name in [AVAudioSession.interruptionNotification, AVAudioSession.routeChangeNotification,
                             .AVAudioEngineConfigurationChange] {
                    observers.append(NotificationCenter.default.addObserver(forName: name, object: name == .AVAudioEngineConfigurationChange ? audio : nil, queue: nil) { _ in
                        capture.fail("Microphone interrupted or route changed; toggle to retry.")
                    })
                }
            } else if config[1] == 2 {
                if #available(iOS 27.0, *) {
                    let ready = DispatchSemaphore(value: 0)
                    var result: Result<() -> Void, Error>?
                    Task { @MainActor [self] in
                        do {
                            guard let broadcast else { throw CaptureFailure("Choose system audio before enabling broadcast.") }
                            result = .success(try await broadcast.start(capture))
                        } catch { result = .failure(error) }
                        ready.signal()
                    }
                    ready.wait()
                    stopBroadcast = try result!.get()
                } else { throw CaptureFailure("System audio broadcast requires iOS 27 or later.") }
            } else { throw CaptureFailure("Unknown capture kind.") }
            var metadata = Data([1]); IOSCaptureWire.append(UInt32(rate), to: &metadata); IOSCaptureWire.append(UInt16(channels), to: &metadata)
            try IOSCaptureWire.write(fd, metadata)
            while true {
                guard try IOSCaptureWire.read(fd) == Data([114]) else { throw CaptureFailure("Invalid capture credit.") }
                var clock = Data([5]); IOSCaptureWire.append(IOSCaptureWire.hostNS(), to: &clock)
                try IOSCaptureWire.write(fd, clock)
                let batch = capture.drain()
                if let error = batch.error { throw CaptureFailure(error) }
                for block in batch.blocks {
                    var data = Data([2]); IOSCaptureWire.append(block.host, to: &data)
                    IOSCaptureWire.append(block.frames, to: &data); IOSCaptureWire.append(batch.dropped, to: &data)
                    data.append(block.samples); try IOSCaptureWire.write(fd, data)
                }
                try IOSCaptureWire.write(fd, Data([4]))
            }
        } catch {
            try? IOSCaptureWire.write(fd, Data([3]) + Data(error.localizedDescription.utf8))
            NSLog("BEAM Audio capture closed: %@", error.localizedDescription)
        }
    }
}

struct CaptureFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

final class IOSCaptureBuffers {
    struct Block { let host: UInt64; let frames: UInt32; let samples: Data }
    private let lock = NSLock()
    private var blocks: [Block] = []
    private var dropped: UInt64 = 0
    private var error: String?
    func fail(_ message: String) { lock.lock(); error = message; lock.unlock() }
    func append(_ buffer: AVAudioPCMBuffer, host: UInt64) {
        guard let planes = buffer.floatChannelData else { fail("Capture supplied no Float32 planes."); return }
        let frames = Int(buffer.frameLength), channels = Int(buffer.format.channelCount)
        guard frames > 0, frames <= 4096, (1...2).contains(channels) else { fail("Capture block exceeds the binding limits."); return }
        var samples = Data(capacity: frames * channels * 4)
        for c in 0..<channels { samples.append(UnsafeBufferPointer(start: UnsafeRawPointer(planes[c]).assumingMemoryBound(to: UInt8.self), count: frames * 4)) }
        lock.lock(); defer { lock.unlock() }
        if blocks.count == 8 { blocks.removeFirst(); dropped += 1 }
        blocks.append(Block(host: host, frames: UInt32(frames), samples: samples))
    }
    func drain() -> (blocks: [Block], dropped: UInt64, error: String?) {
        lock.lock(); defer { lock.unlock() }
        let batch = blocks; blocks.removeAll(keepingCapacity: true)
        return (batch, dropped, error)
    }
}

@MainActor
final class IOSBroadcastAuthorization: NSObject {
    private var implementation: AnyObject?
    private var preparing = false
    func prepare() async throws {
        guard !preparing else { throw CaptureFailure("System audio selection is already open.") }
        preparing = true; defer { preparing = false }
        if #available(iOS 27.0, *) {
            let picker = IOSSystemAudioCapture(); implementation = picker
            do { try await picker.prepare() }
            catch { await picker.stop(); implementation = nil; throw error }
        } else { throw CaptureFailure("System audio broadcast requires iOS 27 or later.") }
    }
    @available(iOS 27.0, *)
    func start(_ buffers: IOSCaptureBuffers) async throws -> () -> Void {
        guard let capture = implementation as? IOSSystemAudioCapture else { throw CaptureFailure("Choose system audio before enabling broadcast.") }
        try await capture.start(buffers)
        return { Task { @MainActor in await capture.stop() } }
    }
}

@available(iOS 27.0, *)
@MainActor
private final class IOSSystemAudioCapture: NSObject, SCContentSharingPickerObserver, SCStreamOutput, SCStreamDelegate {
    private var continuation: CheckedContinuation<Void, Error>?
    private var filter: SCContentFilter?
    private var stream: SCStream?
    private var buffers: IOSCaptureBuffers?
    func prepare() async throws {
        let picker = SCContentSharingPicker.shared
        guard picker.isAvailable else { throw CaptureFailure("System audio capture is unavailable on this Device.") }
        picker.add(self); picker.isActive = true
        var config = picker.defaultConfiguration
        config.showsMicrophoneControl = false; config.showsCameraControl = false
        picker.defaultConfiguration = config
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation; picker.present()
        }
    }
    func start(_ buffers: IOSCaptureBuffers) async throws {
        guard let filter, stream == nil else { throw CaptureFailure("System audio permission is missing or capture is already active.") }
        self.buffers = buffers
        let config = SCStreamConfiguration()
        config.capturesAudio = true; config.sampleRate = 48000; config.channelCount = 2
        config.excludesCurrentProcessAudio = true
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: .main)
        self.stream = stream
        do { try await stream.startCapture() }
        catch { self.stream = nil; throw error }
    }
    func stop() async {
        try? await stream?.stopCapture(); stream = nil; buffers = nil
        SCContentSharingPicker.shared.remove(self)
        SCContentSharingPicker.shared.isActive = false
    }
    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor in continuation?.resume(throwing: CaptureFailure("System audio sharing was cancelled.")); continuation = nil }
    }
    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        Task { @MainActor in
            self.filter = filter
            // On iOS the system owns changes to an active sharing filter.
            continuation?.resume(); continuation = nil
        }
    }
    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Task { @MainActor in continuation?.resume(throwing: error); continuation = nil }
    }
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in buffers?.fail(error.localizedDescription) }
    }
    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        // ScreenCaptureKit supplies capture-time host PTS; arrival time is never
        // substituted for missing timestamps.
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        guard pts.isValid, pts.isNumeric, pts.seconds >= 0,
              let description = CMSampleBufferGetFormatDescription(sample) else {
            Task { @MainActor in buffers?.fail("Missing system audio timestamp or format.") }; return
        }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        guard format.commonFormat == .pcmFormatFloat32, !format.isInterleaved,
              format.sampleRate == 48000, format.channelCount == 2 else {
            Task { @MainActor in buffers?.fail("Invalid system audio format or capture timestamp.") }; return
        }
        let frames = CMSampleBufferGetNumSamples(sample)
        guard (1...4096).contains(frames) else {
            Task { @MainActor in buffers?.fail("System audio block exceeds the binding limits.") }; return
        }
        var needed = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sample, bufferListSizeNeededOut: &needed,
            bufferListOut: nil, bufferListSize: 0, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: 0, blockBufferOut: nil)
        guard (MemoryLayout<AudioBufferList>.size...4096).contains(needed) else {
            Task { @MainActor in buffers?.fail("Invalid system audio buffer list.") }; return
        }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: needed, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let list = raw.assumingMemoryBound(to: AudioBufferList.self)
        var retained: CMBlockBuffer?
        let result = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sample, bufferListSizeNeededOut: nil,
            bufferListOut: list, bufferListSize: needed, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: 0, blockBufferOut: &retained)
        guard result == noErr, let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: list, deallocator: nil) else {
            Task { @MainActor in buffers?.fail("Could not read system audio buffers.") }; return
        }
        guard buffer.frameCapacity >= AVAudioFrameCount(frames) else {
            Task { @MainActor in buffers?.fail("System audio buffer is shorter than its frame count.") }; return
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        let host = CMClockConvertHostTimeToSystemUnits(pts)
        let hostNS = UInt64(AVAudioTime.seconds(forHostTime: host) * 1_000_000_000)
        // This callback queue is main; append copies before releasing CM storage.
        MainActor.assumeIsolated { buffers?.append(buffer, host: hostNS) }
    }
}

private enum IOSCaptureWire {
    static func hostNS() -> UInt64 { UInt64(AVAudioTime.seconds(forHostTime: mach_absolute_time()) * 1_000_000_000) }
    static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var big = value.bigEndian; withUnsafeBytes(of: &big) { data.append(contentsOf: $0) }
    }
    static func read(_ fd: Int32) throws -> Data {
        let header = try exact(fd, 4)
        let size = header.reduce(0) { ($0 << 8) | Int($1) }
        guard (1...131072).contains(size) else { throw CaptureFailure("Invalid local capture packet.") }
        return try exact(fd, size)
    }
    private static func exact(_ fd: Int32, _ count: Int) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { raw in
            var offset = 0
            while offset < count {
                let n = recv(fd, raw.baseAddress!.advanced(by: offset), count-offset, 0)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw CaptureFailure("Capture binding closed.") }; offset += n
            }
        }
        return data
    }
    static func write(_ fd: Int32, _ packet: Data) throws {
        var data = Data(); append(UInt32(packet.count), to: &data); data.append(packet)
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < data.count {
                let n = send(fd, raw.baseAddress!.advanced(by: offset), data.count-offset, 0)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw CaptureFailure("Capture binding closed.") }; offset += n
            }
        }
    }
}
