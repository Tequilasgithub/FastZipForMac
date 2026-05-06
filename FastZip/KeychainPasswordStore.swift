import Foundation
import Security

/// 基于 macOS 本地钥匙串的密码存储——所有密码存为单条 Keychain 记录（JSON），
/// 读写各一次 Keychain 调用，避免逐条查询导致的多次权限弹窗。
final class KeychainPasswordStore {
    static let shared = KeychainPasswordStore()

    private let service = "com.example.FastZip.passwords"
    private let account = "all_passwords"

    /// 保存全部密码（覆盖写入）
    func saveAll(_ items: [StoredItem]) throws {
        let data = try JSONEncoder().encode(items)

        let delQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(delQuery as CFDictionary)

        var addQuery = delQuery
        addQuery[kSecValueData as String] = data

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw StoreError.saveFailed(status: status)
        }
    }

    /// 读取全部密码（单次查询）
    func loadAll() throws -> [StoredItem] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status != errSecItemNotFound else { return [] }
        guard status == errSecSuccess else {
            throw StoreError.readFailed(status: status)
        }

        guard let dict = result as? [String: Any],
              let data = dict[kSecValueData as String] as? Data else { return [] }

        return (try? JSONDecoder().decode([StoredItem].self, from: data)) ?? []
    }

    /// 删除全部密码
    func deleteAll() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw StoreError.deleteFailed(status: status)
        }
    }
}

// MARK: - 类型

struct StoredItem: Codable, Identifiable {
    var id: String
    var name: String
    var password: String
    var label: String?
}

enum StoreError: LocalizedError {
    case saveFailed(status: OSStatus)
    case readFailed(status: OSStatus)
    case deleteFailed(status: OSStatus)

    var errorDescription: String? {
        let msg: String
        switch self {
        case .saveFailed(let s):  msg = "写入 Keychain 失败 (OSStatus: \(s))"
        case .readFailed(let s):  msg = "读取 Keychain 失败 (OSStatus: \(s))"
        case .deleteFailed(let s): msg = "删除 Keychain 失败 (OSStatus: \(s))"
        }
        return msg
    }
}
