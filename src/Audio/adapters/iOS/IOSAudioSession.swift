import AVFAudio
import Foundation

/// One OS session for independent input/output bindings. Releasing the speaker
/// must not deactivate an active microphone (or the reverse).
final class IOSAudioSession {
    static let shared = IOSAudioSession()
    private let lock = NSLock()
    private var clients: [UUID: Bool] = [:]
    func acquire(microphone: Bool) throws -> UUID {
        lock.lock(); defer { lock.unlock() }
        let token = UUID()
        let session = AVAudioSession.sharedInstance()
        let recording = microphone || clients.values.contains(true)
        try session.setCategory(recording ? .playAndRecord : .playback, mode: .default,
                                options: recording ? [.defaultToSpeaker] : [])
        try session.setActive(true)
        clients[token] = microphone
        return token
    }
    func release(_ token: UUID?) {
        guard let token else { return }
        lock.lock(); defer { lock.unlock() }
        clients.removeValue(forKey: token)
        // Keep the category stable while another binding is using it. Changing
        // a route/category invalidates its time mapping and requires OTP recovery.
        if clients.isEmpty { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
    }
}

// C entry points let the native GStreamer host share the existing OS-session
// owner with microphone/output bindings. A native stop releases only its token.
private final class NativeStreamSessionToken {
    let value: UUID
    init(_ value: UUID) { self.value = value }
}
@_cdecl("ba_native_stream_audio_acquire")
func baNativeStreamAudioAcquire() -> UnsafeMutableRawPointer? {
    guard let token = try? IOSAudioSession.shared.acquire(microphone: false) else { return nil }
    return Unmanaged.passRetained(NativeStreamSessionToken(token)).toOpaque()
}
@_cdecl("ba_native_stream_audio_release")
func baNativeStreamAudioRelease(_ pointer: UnsafeMutableRawPointer?) {
    guard let pointer else { return }
    IOSAudioSession.shared.release(Unmanaged<NativeStreamSessionToken>.fromOpaque(pointer).takeRetainedValue().value)
}
