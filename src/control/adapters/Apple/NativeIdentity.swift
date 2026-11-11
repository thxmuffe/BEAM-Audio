import Foundation
import CryptoKit
import Security
import Darwin

/// Platform storage only. Erlang owns Buffee membership and reconnection.
public struct NativeIdentity: Sendable {
    public let seedHex: String
    public let publicKeyHex: String
    public let stateDirectory: URL

    public static func load() throws -> NativeIdentity {
        try load(account: "device-v1", directory: "cluster")
    }

    /// Desktop instances keep separate keys and state. Slot 1 preserves the
    /// original identity; advisory locks release automatically on process exit.
    public static func loadDesktop() throws -> DesktopDeviceIdentity {
        let root = try FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("org.opensound.beamaudio", isDirectory: true)
        let lease = try DesktopInstanceLease.acquire(root: root)
        let suffix = lease.slot == 1 ? "" : "-\(lease.slot)"
        let identity = try load(account: "device-v1\(suffix)", directory: "cluster\(suffix)")
        return DesktopDeviceIdentity(identity: identity, lease: lease)
    }

    public static func loadInspector() throws -> NativeIdentity {
        try load(account: "inspector-v1", directory: "inspector")
    }

    private static func load(account: String, directory subdirectory: String) throws -> NativeIdentity {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "org.opensound.beamaudio.native-identity",
            kSecAttrAccount as String: account
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query.merging([
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]) { _, value in value } as CFDictionary, &item)
        let seed: Data
        if status == errSecSuccess, let stored = item as? Data {
            seed = stored
        } else if status == errSecItemNotFound {
            seed = Curve25519.Signing.PrivateKey().rawRepresentation
            let result = SecItemAdd(query.merging([
                kSecValueData as String: seed,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            ]) { _, value in value } as CFDictionary, nil)
            guard result == errSecSuccess else { throw keychainError(result) }
        } else {
            throw keychainError(status)
        }
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        let directory = try FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("org.opensound.beamaudio/\(subdirectory)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        return NativeIdentity(seedHex: hex(seed), publicKeyHex: hex(key.publicKey.rawRepresentation),
                              stateDirectory: directory)
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined()
    }

    private static func keychainError(_ status: OSStatus) -> NSError {
        NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [
            NSLocalizedDescriptionKey: "Could not load the saved Device Identity (Keychain status \(status))."
        ])
    }
}

public struct DesktopDeviceIdentity: Sendable {
    public let identity: NativeIdentity
    public let lease: DesktopInstanceLease
}

/// A conventional OS file lock, held for the full native runtime lifetime.
public final class DesktopInstanceLease: @unchecked Sendable {
    public let slot: Int
    private let descriptor: Int32
    private init(slot: Int, descriptor: Int32) { self.slot = slot; self.descriptor = descriptor }
    public static func acquire(root: URL) throws -> DesktopInstanceLease {
        for slot in 1...100 {
            let directory = root.appendingPathComponent(slot == 1 ? "cluster" : "cluster-\(slot)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let fd = open(directory.appendingPathComponent("runtime.lock").path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { return DesktopInstanceLease(slot: slot, descriptor: fd) }
            let error = errno; close(fd)
            guard error == EWOULDBLOCK else { throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO) }
        }
        throw NSError(domain: "OpenSound", code: 1, userInfo: [NSLocalizedDescriptionKey: "All desktop Device instances are in use."])
    }
    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
}
