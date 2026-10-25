import Foundation
import Security

/// 엔진별 API 키 저장소. 키는 엔진 id 로 구분한다.
protocol APIKeyStore: Sendable {
    func key(for engineID: String) -> String?
    func save(_ key: String, for engineID: String) throws
    func delete(for engineID: String) throws
}

struct KeychainError: Error, Equatable {
    var status: OSStatus
}

/// Keychain generic password. service 고정, account = 엔진 id.
struct KeychainKeyStore: APIKeyStore {
    static let service = "dev.tunggary.MacMonitor.ai-verdict"

    private func query(_ engineID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: engineID,
        ]
    }

    func key(for engineID: String) -> String? {
        var q = query(engineID)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func save(_ key: String, for engineID: String) throws {
        let data = Data(key.utf8)
        let status = SecItemUpdate(query(engineID) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw KeychainError(status: status) }
        var add = query(engineID)
        add[kSecValueData as String] = data
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        if addStatus != errSecSuccess { throw KeychainError(status: addStatus) }
    }

    func delete(for engineID: String) throws {
        let status = SecItemDelete(query(engineID) as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound { throw KeychainError(status: status) }
    }
}

/// 테스트용 — 실제 키체인을 건드리지 않는다.
final class MemoryKeyStore: APIKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [String: String]

    init(_ keys: [String: String] = [:]) { self.keys = keys }

    func key(for engineID: String) -> String? { lock.withLock { keys[engineID] } }
    func save(_ key: String, for engineID: String) throws { lock.withLock { keys[engineID] = key } }
    func delete(for engineID: String) throws { _ = lock.withLock { keys.removeValue(forKey: engineID) } }
}
