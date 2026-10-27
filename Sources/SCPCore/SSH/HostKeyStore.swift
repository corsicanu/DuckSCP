import CryptoKit
import Foundation

/// A server's host key as presented during the SSH handshake.
public struct HostKey: Codable, Equatable {
    public var type: String
    public var blob: Data

    public init(type: String, blob: Data) {
        self.type = type
        self.blob = blob
    }

    /// "SHA256:base64" without padding, like OpenSSH and WinSCP.
    public var sha256Fingerprint: String {
        let digest = Data(SHA256.hash(data: blob)).base64EncodedString()
        return "SHA256:" + digest.replacingOccurrences(of: "=", with: "")
    }

    /// "ab:cd:…" MD5, shown by older WinSCP versions.
    public var md5Fingerprint: String {
        Insecure.MD5.hash(data: blob).map { String(format: "%02x", $0) }.joined(separator: ":")
    }
}

public enum HostKeyVerdict: Equatable {
    case trusted
    case unknown
    /// A different key of the same type is on record for this host.
    case changed(previous: String)
}

public enum HostKeyDecision { case acceptAndSave, acceptOnce, reject }

/// Our own host key cache, plus read-only checks against ~/.ssh/known_hosts
/// and keys imported from WinSCP.ini.
public final class HostKeyStore {
    public let fileURL: URL
    public var knownHostsFiles: [URL]
    private var keys: [String: [HostKey]] = [:]
    private let lock = NSLock()

    public init(fileURL: URL, knownHostsFiles: [URL] = [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/known_hosts")]) {
        self.fileURL = fileURL
        self.knownHostsFiles = knownHostsFiles
        if let data = try? Data(contentsOf: fileURL) {
            keys = (try? JSONDecoder().decode([String: [HostKey]].self, from: data)) ?? [:]
        }
    }

    /// OpenSSH's host pattern: "host" for port 22, "[host]:port" otherwise.
    public static func hostID(_ host: String, _ port: Int) -> String {
        port == 22 ? host.lowercased() : "[\(host.lowercased())]:\(port)"
    }

    public func verify(host: String, port: Int, key: HostKey) -> HostKeyVerdict {
        let id = Self.hostID(host, port)
        var candidates = lock.withLock { keys[id] ?? [] }
        candidates += knownHostsFiles.flatMap { Self.parseKnownHosts($0, hostID: id) }
        if candidates.contains(key) { return .trusted }
        if let old = candidates.first(where: { $0.type == key.type }) { return .changed(previous: old.sha256Fingerprint) }
        return .unknown
    }

    /// Replaces any key of the same type for the host.
    public func save(host: String, port: Int, key: HostKey) throws {
        let id = Self.hostID(host, port)
        let data: Data = try lock.withLock {
            var list = keys[id] ?? []
            list.removeAll { $0.type == key.type }
            list.append(key)
            keys[id] = list
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            return try enc.encode(keys)
        }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    // MARK: known_hosts

    static func parseKnownHosts(_ url: URL, hostID: String) -> [HostKey] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var out: [HostKey] = []
        for line in text.split(whereSeparator: \.isNewline) {
            var fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard !fields.isEmpty, !fields[0].hasPrefix("#") else { continue }
            if fields[0] == "@revoked" || fields[0] == "@cert-authority" { continue }
            guard fields.count >= 3, let blob = Data(base64Encoded: fields[2]) else { continue }
            let patterns = fields.removeFirst()
            if patterns.split(separator: ",").contains(where: { matches(String($0), hostID: hostID) }) {
                out.append(HostKey(type: fields[0], blob: blob))
            }
        }
        return out
    }

    /// Plain names, or hashed "|1|salt|hmac" entries (HMAC-SHA1 of the host id).
    static func matches(_ pattern: String, hostID: String) -> Bool {
        if pattern.hasPrefix("|1|") {
            let parts = pattern.split(separator: "|")
            guard parts.count == 3, let salt = Data(base64Encoded: String(parts[1])),
                  let hash = Data(base64Encoded: String(parts[2])) else { return false }
            let mac = HMAC<Insecure.SHA1>.authenticationCode(for: Data(hostID.utf8), using: SymmetricKey(data: salt))
            return Data(mac) == hash
        }
        return pattern.lowercased() == hostID
    }

    // MARK: WinSCP / PuTTY cached keys

    /// Converts WinSCP's `[SshHostKeys]` entries (PuTTY format) into saved keys.
    /// Supports ssh-ed25519 and ssh-rsa; returns how many were imported.
    @discardableResult
    public func importWinSCP(_ entries: [(key: String, value: String)]) -> Int {
        var count = 0
        for (name, value) in entries {
            // "ssh-ed25519@22:example.com" (older WinSCP uses "rsa2@22:host")
            guard let at = name.firstIndex(of: "@"), let colon = name[at...].firstIndex(of: ":"),
                  let port = Int(name[name.index(after: at)..<colon]) else { continue }
            let algo = String(name[..<at])
            let host = String(name[name.index(after: colon)...])
            guard let key = Self.puttyKey(algo: algo, value: value), (try? save(host: host, port: port, key: key)) != nil else { continue }
            count += 1
        }
        return count
    }

    static func puttyKey(algo: String, value: String) -> HostKey? {
        let parts = value.split(separator: ",").map { $0.hasPrefix("0x") ? String($0.dropFirst(2)) : String($0) }
        switch algo {
        case "ssh-ed25519":
            // PuTTY stores the curve point as "0x<x>,0x<y>". The wire key is y in
            // little-endian with x's low bit folded into the top bit.
            guard parts.count == 2, let x = hexBytes(parts[0]), var y = hexBytes(parts[1]), y.count <= 32 else { return nil }
            y = Array(repeating: 0, count: 32 - y.count) + y
            var le = Array(y.reversed())
            if let last = x.last, last & 1 == 1 { le[31] |= 0x80 }
            return HostKey(type: algo, blob: SSHWire.string("ssh-ed25519") + SSHWire.string(Data(le)))
        case "rsa2", "ssh-rsa":
            // "0x<e>,0x<n>"
            guard parts.count == 2, let e = hexBytes(parts[0]), let n = hexBytes(parts[1]) else { return nil }
            return HostKey(type: "ssh-rsa", blob: SSHWire.string("ssh-rsa") + SSHWire.mpint(e) + SSHWire.mpint(n))
        default:
            return nil
        }
    }

    static func hexBytes(_ s: String) -> [UInt8]? {
        var hex = s
        if hex.count % 2 == 1 { hex = "0" + hex }
        var out: [UInt8] = []
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            guard let b = UInt8(hex[i..<j], radix: 16) else { return nil }
            out.append(b)
            i = j
        }
        return out
    }
}

/// SSH wire-format encoding helpers (RFC 4251).
public enum SSHWire {
    public static func uint32(_ v: UInt32) -> Data {
        Data([UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)])
    }

    public static func string(_ s: String) -> Data { string(Data(s.utf8)) }
    public static func string(_ d: Data) -> Data { uint32(UInt32(d.count)) + d }

    /// Big-endian two's complement with a leading zero when the top bit is set.
    public static func mpint(_ bytes: [UInt8]) -> Data {
        var b = Array(bytes.drop(while: { $0 == 0 }))
        if let first = b.first, first & 0x80 != 0 { b.insert(0, at: 0) }
        return string(Data(b))
    }

    /// Sequential reader for wire-format blobs.
    public struct Reader {
        private var data: Data
        public init(_ data: Data) { self.data = Data(data) }
        public var isAtEnd: Bool { data.isEmpty }

        public mutating func uint32() throws -> UInt32 {
            guard data.count >= 4 else { throw FileSystemError(.other, "Truncated key data.") }
            let v = data.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            data = data.dropFirst(4)
            return v
        }

        public mutating func bytes() throws -> Data {
            let n = Int(try uint32())
            guard data.count >= n else { throw FileSystemError(.other, "Truncated key data.") }
            let v = data.prefix(n)
            data = data.dropFirst(n)
            return Data(v)
        }

        public mutating func text() throws -> String { String(decoding: try bytes(), as: UTF8.self) }
    }
}
