import Foundation
import Security

/// The watch's own copy of its credentials, in the Keychain.
///
/// Not UserDefaults: the key in here is this device's identity, and holding it
/// is enough to drive the computer's cursor. And not left to WatchConnectivity
/// alone, whose stored context belongs to the session rather than to the app
/// and is replaced, not merged, by whatever the phone sends next.
public struct CredentialStore: Sendable {
    private let service = "space.keybo.awmouse.watch"
    private let account: String

    /// `credentials` holds what the phone sent; `selection` holds which of
    /// its computers the watch has chosen, which is the watch's own business
    /// and so is kept apart from anything the phone can overwrite.
    public init(account: String = "credentials") {
        self.account = account
    }

    func load() -> HostCredentials? {
        loadData().flatMap { try? JSONDecoder().decode(HostCredentials.self, from: $0) }
    }

    func save(_ credentials: HostCredentials) {
        guard let data = try? JSONEncoder().encode(credentials) else { return }
        save(data)
    }

    /// The chosen computer's address. In the Keychain too, because an
    /// address is as good as the key for reaching that computer.
    public func loadString() -> String? {
        loadData().flatMap { String(data: $0, encoding: .utf8) }
    }

    public func save(string: String) {
        save(Data(string.utf8))
    }

    private func loadData() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    private func save(_ data: Data) {
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
