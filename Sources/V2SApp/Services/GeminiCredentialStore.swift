import Foundation
import Security

protocol CredentialStore: AnyObject {
    var isConfigured: Bool { get }
    func read() throws -> String?
    func save(_ credential: String) throws
    func delete() throws
}

enum CredentialStoreError: Error, Equatable {
    case invalidCredential
    case keychain(OSStatus)
}

final class GeminiCredentialStore: CredentialStore {
    static let service = "com.leo.lectureassistant.gemini"
    private let account: String

    init(account: String = "default") {
        self.account = account
    }

    var isConfigured: Bool {
        guard let stored = try? read() else { return false }
        return stored.isEmpty == false
    }

    func read() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CredentialStoreError.keychain(status) }
        guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
            throw CredentialStoreError.invalidCredential
        }
        return value
    }

    func save(_ credential: String) throws {
        let trimmed = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 20, trimmed.contains(where: { $0.isWhitespace }) == false else {
            throw CredentialStoreError.invalidCredential
        }
        let data = Data(trimmed.utf8)
        var attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw CredentialStoreError.keychain(updateStatus) }
        attributes.merge(baseQuery) { current, _ in current }
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw CredentialStoreError.keychain(addStatus) }
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.keychain(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]
    }
}

final class InMemoryCredentialStore: CredentialStore {
    var credential: String?
    var isConfigured: Bool { credential?.isEmpty == false }
    func read() throws -> String? { credential }
    func save(_ credential: String) throws { self.credential = credential }
    func delete() throws { credential = nil }
}
