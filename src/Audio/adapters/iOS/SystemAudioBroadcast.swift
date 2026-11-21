import ReplayKit
import UIKit

/// iPhone system audio is shared through a system broadcast, which only the
/// person can start: iOS shows its own sheet and the red indicator. This opens
/// that sheet for the app's upload extension and reports when the broadcast
/// starts or stops (the extension posts a Darwin notification; the audio
/// itself goes from the extension to the engine through the shared ring).
@MainActor
final class SystemAudioBroadcast {
    static let shared = SystemAudioBroadcast()
    /// Called on every start or stop, with whether it now runs.
    var onChange: ((Bool) -> Void)?
    var running: Bool { ba_system_audio_running() }
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

    private init() {
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil, { _, _, _, _, _ in
            Task { @MainActor in SystemAudioBroadcast.shared.changed() }
        }, "org.beam-audio.system-audio.changed" as CFString, nil, .deliverImmediately)
    }

    private func changed() {
        let now = running
        if now { waiters.values.forEach { $0.resume(returning: true) }; waiters.removeAll() }
        onChange?(now)
    }

    /// Opens the broadcast sheet preselected on this app's extension and waits
    /// for the person to start it. False when they did not within the time.
    func start(extensionBundle: String, within seconds: Double) async -> Bool {
        if running { return true }
        guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows).first(where: \.isKeyWindow) else { return false }
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        picker.preferredExtension = extensionBundle
        picker.showsMicrophoneButton = false
        picker.alpha = 0.01
        window.addSubview(picker)
        defer { picker.removeFromSuperview() }
        // The picker has no API to open; its own button does (the usual approach).
        picker.subviews.compactMap { $0 as? UIButton }.first?.sendActions(for: .touchUpInside)
        let id = UUID()
        return await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            waiters[id] = done
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(seconds))
                self.waiters.removeValue(forKey: id)?.resume(returning: self.running)
            }
        }
    }
}
