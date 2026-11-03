import Foundation
import CryptoKit
import Security

/// Platform storage only. Erlang owns cluster membership and reconnection.
public struct NativeIdentity: Sendable {
    public let seedHex: String
    public let publicKeyHex: String
    public let stateDirectory: URL

    public static func load() throws -> NativeIdentity {
        try load(account: "device-v1", directory: "cluster")
    }

    public static func loadInspector() throws -> NativeIdentity {
        try load(account: "inspector-v1", directory: "inspector")
    }

    private static func load(account: String, directory subdirectory: String) throws -> NativeIdentity {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "org.opensound.parvi.native-identity",
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
            .appendingPathComponent("org.opensound.parvi/\(subdirectory)", isDirectory: true)
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
            NSLocalizedDescriptionKey: "Could not load the saved node identity (Keychain status \(status))."
        ])
    }
}
