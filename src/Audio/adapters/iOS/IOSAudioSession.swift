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
