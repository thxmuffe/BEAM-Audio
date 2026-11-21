import AVFAudio
import Foundation

/// One OS session for independent input/output bindings. Releasing the speaker
/// must not deactivate an active microphone (or the reverse).
final class IOSAudioSession {
    static let shared = IOSAudioSession()
    private let lock = NSLock()
    private var clients: [UUID: (microphone: Bool, mixing: Bool)] = [:]
    /// mixing: other apps keep playing. Broadcasting their audio needs it, and
    /// it stays on while any binding asks for it.
    func acquire(microphone: Bool, mixing: Bool = false) throws -> UUID {
        lock.lock(); defer { lock.unlock() }
        let token = UUID()
        let session = AVAudioSession.sharedInstance()
        let recording = microphone || clients.values.contains { $0.microphone }
        let mixed = mixing || clients.values.contains { $0.mixing }
        var options: AVAudioSession.CategoryOptions = recording ? [.defaultToSpeaker] : []
        if mixed { options.insert(.mixWithOthers) }
        try session.setCategory(recording ? .playAndRecord : .playback, mode: .default, options: options)
        try session.setActive(true)
        clients[token] = (microphone, mixing)
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

// C entry points let the audio engine's iOS shell share the OS-session owner
// with other bindings. Stopping its output releases only its own token.
private final class EngineSessionToken {
    let value: UUID
    init(_ value: UUID) { self.value = value }
}
/// Called on the engine's control thread, never the main thread: the first
/// microphone use waits here for the user's answer to the permission prompt.
@_cdecl("ba_engine_audio_acquire")
func baEngineAudioAcquire(_ microphone: Bool, _ mixing: Bool) -> UnsafeMutableRawPointer? {
    if microphone {
        if AVAudioApplication.shared.recordPermission == .undetermined {
            let answered = DispatchSemaphore(value: 0)
            AVAudioApplication.requestRecordPermission { _ in answered.signal() }
            answered.wait()
        }
        guard AVAudioApplication.shared.recordPermission == .granted else { return nil }
    }
    guard let token = try? IOSAudioSession.shared.acquire(microphone: microphone, mixing: mixing) else { return nil }
    return Unmanaged.passRetained(EngineSessionToken(token)).toOpaque()
}
@_cdecl("ba_engine_audio_release")
func baEngineAudioRelease(_ pointer: UnsafeMutableRawPointer?) {
    guard let pointer else { return }
    IOSAudioSession.shared.release(Unmanaged<EngineSessionToken>.fromOpaque(pointer).takeRetainedValue().value)
}
