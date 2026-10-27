// SPDX-License-Identifier: GPL-3.0-or-later
import CommonCrypto
import CryptoKit
import Foundation

/// Decrypts WinSCP.ini passwords protected by a master password.
///
/// WinSCP stores them as hex of `FF 01` + salt(16) + AES-256-CTR ciphertext + MAC(10),
/// using Brian Gladman's WinZip-AES "fcrypt" scheme: PBKDF2-HMAC-SHA1 (1000 rounds,
/// 66 bytes: AES key, HMAC key, 2-byte verifier), CTR with a little-endian counter
/// starting at 1, and HMAC-SHA1 over the ciphertext truncated to 10 bytes.
/// Every result is MAC-checked, so a wrong master password can never yield a wrong password.
public enum WinSCPMasterPassword {
    static let saltLength = 16, macLength = 10, keyLength = 32, iterations: UInt32 = 1000

    public enum Error: Swift.Error, Equatable { case malformed, wrongPassword }

    struct Keys {
        let aes: Data, hmac: Data, verifier: Data
    }

    static func deriveKeys(_ password: String, salt: Data) -> Keys {
        let pw = Array(password.utf8)
        var out = [UInt8](repeating: 0, count: 2 * keyLength + 2)
        salt.withUnsafeBytes { s in
            _ = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pw.map { CChar(bitPattern: $0) }, pw.count,
                                     s.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), iterations, &out, out.count)
        }
        return Keys(aes: Data(out[0..<keyLength]), hmac: Data(out[keyLength..<2 * keyLength]), verifier: Data(out[(2 * keyLength)...]))
    }

    /// AES-CTR with fcrypt's counter: the first 8 bytes form a little-endian integer, starting at 1.
    static func ctr(_ input: Data, key: Data) -> Data {
        var nonce = [UInt8](repeating: 0, count: 16)
        var out = Data(capacity: input.count)
        var block = [UInt8](repeating: 0, count: 16)
        var index = 16
        for byte in input {
            if index == 16 {
                var j = 0
                repeat { nonce[j] &+= 1; j += 1 } while j < 8 && nonce[j - 1] == 0
                var moved = 0
                key.withUnsafeBytes { k in
                    _ = CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                                k.baseAddress, keyLength, nil, nonce, 16, &block, 16, &moved)
                }
                index = 0
            }
            out.append(byte ^ block[index])
            index += 1
        }
        return out
    }

    static func mac(_ ciphertext: Data, key: Data) -> Data {
        Data(HMAC<Insecure.SHA1>.authenticationCode(for: ciphertext, using: SymmetricKey(data: key))).prefix(macLength)
    }

    /// Checks the master password against `[Configuration\Security] MasterPasswordVerifier`
    /// (hex of salt(16) + random(16) + MAC(10) of that random block encrypted with the password).
    public static func verify(_ password: String, verifierHex: String) -> Bool? {
        guard let v = hexData(verifierHex), v.count == saltLength + 16 + macLength else { return nil }
        let salt = v.prefix(saltLength), dummy = v.dropFirst(saltLength).prefix(16), expected = v.suffix(macLength)
        let keys = deriveKeys(password, salt: Data(salt))
        return mac(ctr(Data(dummy), key: keys.aes), key: keys.hmac) == Data(expected)
    }

    /// True when the stored password value uses master-password encryption.
    public static func isEncrypted(_ hex: String) -> Bool { hex.uppercased().hasPrefix("FF01") }

    /// - Parameter key: `UserName + HostName`, stripped if the plaintext starts with it.
    public static func decrypt(_ hex: String, masterPassword: String, key: String = "") throws -> String {
        guard isEncrypted(hex), let raw = hexData(hex), raw.count >= 2 + saltLength + macLength else { throw Error.malformed }
        let blob = raw.dropFirst(2)
        let salt = blob.prefix(saltLength)
        let ciphertext = blob.dropFirst(saltLength).dropLast(macLength)
        let keys = deriveKeys(masterPassword, salt: Data(salt))
        guard mac(Data(ciphertext), key: keys.hmac) == Data(blob.suffix(macLength)) else { throw Error.wrongPassword }
        var plain = String(decoding: ctr(Data(ciphertext), key: keys.aes), as: UTF8.self)
        if !key.isEmpty, plain.hasPrefix(key) { plain.removeFirst(key.count) }
        return plain
    }

    /// Test helper and future export: produces the same format WinSCP writes.
    public static func encrypt(_ password: String, masterPassword: String, salt: Data? = nil) -> String {
        let salt = salt ?? Data((0..<saltLength).map { _ in UInt8.random(in: 0...255) })
        let keys = deriveKeys(masterPassword, salt: salt)
        let ct = ctr(Data(password.utf8), key: keys.aes)
        let blob = Data([0xFF, 0x01]) + salt + ct + mac(ct, key: keys.hmac)
        return blob.map { String(format: "%02X", $0) }.joined()
    }

    static func hexData(_ s: String) -> Data? {
        guard s.count % 2 == 0 else { return nil }
        var out = Data(capacity: s.count / 2)
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            guard let b = UInt8(s[i..<j], radix: 16) else { return nil }
            out.append(b)
            i = j
        }
        return out
    }
}
