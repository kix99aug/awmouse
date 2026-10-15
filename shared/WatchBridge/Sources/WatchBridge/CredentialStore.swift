import Foundation
import Security

/// The watch's own copy of its credentials, in the Keychain.
///
/// Not UserDefaults: the key in here is this device's identity, and holding it
/// is enough to drive the computer's cursor. And not left to WatchConnectivity
/// alone, whose stored context belongs to the session rather than to the app
/// and is replaced, not merged, by whatever the phone sends next.
struct CredentialStore {
    private let service = "space.keybo.awmouse.watch"
    private let account = "credentials"

    func load() -> HostCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return try? JSONDecoder().decode(HostCredentials.self, from: data)
    }

    func save(_ credentials: HostCredentials) {
        guard let data = try? JSONEncoder().encode(credentials) else { return }
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(match as CFDictionary)
        var add = match
        add[kSecValueData as String] = data
        // Readable whenever the watch has been unlocked since boot, which is
        // whenever someone can open the app; and never restored to another
        // device, which would be a second watch holding this one's identity.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess { print("credential store: \(status)") }
    }
}
