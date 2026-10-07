import Foundation
import Security

enum KeychainStore {
    /// Same service and accounts as version 1.2, so tokens survive upgrades and downgrades.
    private static let service = "com.vpsmonitor.credentials.v3"
    private static let legacyServices = ["com.vpsmonitor.credentials.v2", "com.vpsmonitor.credentials"]
    /// Version 1.1 kept a single token under this account.
    private static let legacySingleAccount = "coolify-token"

    static func account(for profileID: UUID) -> String {
        "coolify-token-\(profileID.uuidString.lowercased())"
    }

    /// Returns the profile's Coolify token, copying it from older storage when needed.
    /// macOS may ask once for permission after the app is rebuilt or updated.
    static func token(for profileID: UUID) -> String {
        let account = account(for: profileID)
        if let token = read(service: service, account: account) { return token }
        var candidates = legacyServices.map { ($0, account) }
        if profileID == ConfigurationStore.legacyProfileID {
            candidates.append(("com.vpsmonitor.credentials", legacySingleAccount))
        }
        for (legacyService, legacyAccount) in candidates {
            if let token = read(service: legacyService, account: legacyAccount), !token.isEmpty {
                try? save(token, for: profileID)
                return token
            }
        }
        return ""
    }

    static func save(_ token: String, for profileID: UUID) throws {
        let query = baseQuery(service: service, account: account(for: profileID))
        SecItemDelete(query as CFDictionary)
        guard !token.isEmpty else { return }
        var item = query
        item[kSecValueData as String] = Data(token.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    static func deleteToken(for profileID: UUID) {
        SecItemDelete(baseQuery(service: service, account: account(for: profileID)) as CFDictionary)
    }

    private static func read(service: String, account: String) -> String? {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func baseQuery(service: String, account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
}
