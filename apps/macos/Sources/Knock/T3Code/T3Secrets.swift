import Foundation
import Security

// WAG-264: where the T3 Code token lives. The token goes in the Keychain and nowhere else:
// never knock.db, never a log, never the UI, never UserDefaults.

/// One secret in a safe store. A fake stands in for it in every test, so no test touches the
/// real Keychain.
protocol SecretStoring: Sendable {
    func load() -> String?
    @discardableResult func save(_ secret: String) -> Bool
    func delete()
}

/// The login Keychain, one generic password item for the app.
struct KeychainSecretStore: SecretStoring {
    static let t3Service = "dev.limone.knock.t3code"
    let service: String
    let account: String

    init(service: String = KeychainSecretStore.t3Service, account: String = "orchestration-token") {
        self.service = service
        self.account = account
    }

    private var identity: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    func load() -> String? {
        var query = identity
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    func save(_ secret: String) -> Bool {
        let data = Data(secret.utf8)
        let update = SecItemUpdate(identity as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return true }
        var add = identity
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    func delete() {
        SecItemDelete(identity as CFDictionary)
    }
}

/// What is not secret about the connection: when the token ends, and which end date the one
/// reminder already went out for. `UserDefaults`, because the reminder check must not read the Keychain.
protocol T3MetaStoring: Sendable {
    var expiry: Date? { get }
    func setExpiry(_ date: Date?)
    /// The expiry the renew reminder was already sent for.
    var remindedFor: Date? { get }
    func setRemindedFor(_ date: Date?)
}

struct UserDefaultsT3Meta: T3MetaStoring, @unchecked Sendable {
    static let expiryKey = "T3CodeTokenExpiry"
    static let remindedKey = "T3CodeRenewRemindedFor"
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var expiry: Date? { read(Self.expiryKey) }
    var remindedFor: Date? { read(Self.remindedKey) }
    func setExpiry(_ date: Date?) { write(Self.expiryKey, date) }
    func setRemindedFor(_ date: Date?) { write(Self.remindedKey, date) }

    private func read(_ key: String) -> Date? {
        defaults.object(forKey: key) == nil ? nil : Date(timeIntervalSince1970: defaults.double(forKey: key))
    }

    private func write(_ key: String, _ date: Date?) {
        if let date { defaults.set(date.timeIntervalSince1970, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
}
