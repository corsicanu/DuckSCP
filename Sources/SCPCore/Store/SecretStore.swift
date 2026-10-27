// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Security

/// Where site passwords live. The app uses the Keychain; tests use memory.
public protocol SecretStore: AnyObject {
    func password(for id: UUID) -> String?
    func setPassword(_ password: String?, for id: UUID) throws
}

public final class InMemorySecretStore: SecretStore {
    private var values: [UUID: String] = [:]
    public init() {}
    public func password(for id: UUID) -> String? { values[id] }
    public func setPassword(_ password: String?, for id: UUID) throws { values[id] = password }
}

/// Generic-password Keychain items, one per site, service = bundle id + ".sites".
public final class KeychainSecretStore: SecretStore {
    public struct KeychainError: Error, CustomStringConvertible {
        public let status: OSStatus
        public var description: String {
            (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
        }
    }

    private let service: String

    public init(service: String) { self.service = service }

    private func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: id.uuidString]
    }

    public func password(for id: UUID) -> String? {
        var q = query(id)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func setPassword(_ password: String?, for id: UUID) throws {
        let q = query(id)
        SecItemDelete(q as CFDictionary)
        guard let password else { return }
        var add = q
        add[kSecValueData as String] = Data(password.utf8)
        // Readable only while the Mac is unlocked, never synced or migrated to other devices.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }
}
