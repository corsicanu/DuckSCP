// SPDX-License-Identifier: GPL-3.0-or-later
import CommonCrypto
import CryptoKit
import Foundation

/// Converts PuTTY .ppk private keys (what WinSCP uses) to OpenSSH format,
/// which libssh2 can load. Supports ssh-ed25519 and ssh-rsa, PPK v2 and v3
/// unencrypted, and PPK v2 encrypted (aes256-cbc). PPK v3 encryption uses
/// Argon2 and is not supported: convert those with PuTTYgen.
public enum PuTTYKey {
    public enum Error: Swift.Error, Equatable, CustomStringConvertible {
        case notPPK, unsupportedAlgorithm(String), unsupportedEncryption(String), passphraseRequired, wrongPassphrase, malformed

        public var description: String {
            switch self {
            case .notPPK: return "Not a PuTTY private key file."
            case .unsupportedAlgorithm(let a): return "PuTTY key type \(a) is not supported. Convert it to OpenSSH format with PuTTYgen."
            case .unsupportedEncryption(let e): return "PuTTY key encryption \(e) is not supported. Convert it to OpenSSH format with PuTTYgen (Conversions → Export OpenSSH key)."
            case .passphraseRequired: return "The key is protected by a passphrase."
            case .wrongPassphrase: return "Incorrect passphrase."
            case .malformed: return "The PuTTY key file is damaged."
            }
        }
    }

    public static func isPPK(_ data: Data) -> Bool {
        data.starts(with: Data("PuTTY-User-Key-File-".utf8))
    }

    public static func needsPassphrase(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8) else { return false }
        return text.contains("Encryption: aes256-cbc")
    }

    /// Returns an unencrypted OpenSSH private key ("-----BEGIN OPENSSH PRIVATE KEY-----").
    public static func toOpenSSH(_ data: Data, passphrase: String?) throws -> String {
        guard let text = String(data: data, encoding: .utf8), isPPK(data) else { throw Error.notPPK }
        var headers: [String: String] = [:]
        var publicB64 = "", privateB64 = ""
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        var i = 0
        var version = 2
        while i < lines.count {
            let line = lines[i]
            guard let colon = line.firstIndex(of: ":") else { i += 1; continue }
            let key = String(line[..<colon])
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if key.hasPrefix("PuTTY-User-Key-File-") {
                version = Int(key.dropFirst("PuTTY-User-Key-File-".count)) ?? 2
                headers["Algorithm"] = value
            } else if key == "Public-Lines" || key == "Private-Lines" {
                let n = Int(value) ?? 0
                guard i + n < lines.count else { throw Error.malformed }
                let body = lines[(i + 1)...(i + n)].joined()
                if key == "Public-Lines" { publicB64 = body } else { privateB64 = body }
                i += n
            } else {
                headers[key] = value
            }
            i += 1
        }
        guard let algorithm = headers["Algorithm"], let pub = Data(base64Encoded: publicB64),
              var priv = Data(base64Encoded: privateB64) else { throw Error.malformed }
        let encryption = headers["Encryption"] ?? "none"
        let comment = headers["Comment"] ?? ""

        switch (encryption, version) {
        case ("none", _): break
        case ("aes256-cbc", 2):
            guard let passphrase, !passphrase.isEmpty else { throw Error.passphraseRequired }
            priv = try decryptV2(priv, passphrase: passphrase)
            guard verifyMACv2(algorithm: algorithm, encryption: encryption, comment: comment, pub: pub, priv: priv,
                              mac: headers["Private-MAC"] ?? "", passphrase: passphrase) else { throw Error.wrongPassphrase }
        default:
            throw Error.unsupportedEncryption("\(encryption) (PPK v\(version))")
        }

        var pubReader = SSHWire.Reader(pub)
        var privReader = SSHWire.Reader(priv)
        guard try pubReader.text() == algorithm else { throw Error.malformed }

        var privateSection = Data()
        let check = UInt32.random(in: .min ... .max)
        privateSection += SSHWire.uint32(check) + SSHWire.uint32(check)
        switch algorithm {
        case "ssh-ed25519":
            let pk = try pubReader.bytes()
            let seed = try ed25519Seed(fromMPInt: try privReader.bytes(), publicKey: pk)
            privateSection += SSHWire.string(algorithm) + SSHWire.string(pk) + SSHWire.string(seed + pk)
        case "ssh-rsa":
            let e = try pubReader.bytes(), n = try pubReader.bytes()
            let d = try privReader.bytes(), p = try privReader.bytes(), q = try privReader.bytes(), iqmp = try privReader.bytes()
            privateSection += SSHWire.string(algorithm)
            for v in [n, e, d, iqmp, p, q] { privateSection += SSHWire.string(v) }
        default:
            throw Error.unsupportedAlgorithm(algorithm)
        }
        privateSection += SSHWire.string(comment)
        var pad: UInt8 = 1
        while privateSection.count % 8 != 0 { privateSection.append(pad); pad += 1 }

        var out = Data("openssh-key-v1".utf8) + Data([0])
        out += SSHWire.string("none") + SSHWire.string("none") + SSHWire.string(Data())
        out += SSHWire.uint32(1) + SSHWire.string(pub) + SSHWire.string(privateSection)
        let b64 = out.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN OPENSSH PRIVATE KEY-----\n\(b64)\n-----END OPENSSH PRIVATE KEY-----\n"
    }

    /// PuTTY stores the Ed25519 seed as an mpint of the little-endian value.
    /// Try the plausible byte orders and keep the one whose public key matches.
    static func ed25519Seed(fromMPInt raw: Data, publicKey: Data) throws -> Data {
        var bytes = Array(raw.drop(while: { $0 == 0 }))
        guard bytes.count <= 32 else { throw Error.malformed }
        bytes = Array(repeating: 0, count: 32 - bytes.count) + bytes
        for candidate in [Data(bytes.reversed()), Data(bytes)] {
            if let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: candidate),
               key.publicKey.rawRepresentation == publicKey {
                return candidate
            }
        }
        throw Error.malformed
    }

    static func decryptV2(_ data: Data, passphrase: String) throws -> Data {
        guard data.count % 16 == 0 else { throw Error.malformed }
        let pw = Data(passphrase.utf8)
        let key = Data(Insecure.SHA1.hash(data: SSHWire.uint32(0) + pw)) + Data(Insecure.SHA1.hash(data: SSHWire.uint32(1) + pw))
        let iv = Data(count: 16)
        var out = Data(count: data.count)
        var moved = 0
        let status = out.withUnsafeMutableBytes { outPtr in
            data.withUnsafeBytes { inPtr in
                key.prefix(32).withUnsafeBytes { keyPtr in
                    iv.withUnsafeBytes { ivPtr in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), 0,
                                keyPtr.baseAddress, 32, ivPtr.baseAddress, inPtr.baseAddress, data.count,
                                outPtr.baseAddress, data.count, &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw Error.malformed }
        return out.prefix(moved)
    }

    static func verifyMACv2(algorithm: String, encryption: String, comment: String, pub: Data, priv: Data,
                            mac: String, passphrase: String) -> Bool {
        let macKey = Data(Insecure.SHA1.hash(data: Data("putty-private-key-file-mac-key".utf8) + Data(passphrase.utf8)))
        let message = SSHWire.string(algorithm) + SSHWire.string(encryption) + SSHWire.string(comment)
            + SSHWire.string(pub) + SSHWire.string(priv)
        let computed = HMAC<Insecure.SHA1>.authenticationCode(for: message, using: SymmetricKey(data: macKey))
        return Data(computed).map { String(format: "%02x", $0) }.joined() == mac.lowercased()
    }
}
