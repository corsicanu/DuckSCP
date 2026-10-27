// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// WinSCP's "simple" password obfuscation used for passwords stored in WinSCP.ini
/// when no master password is set. It is reversible by design (not encryption);
/// imported passwords are moved into the macOS Keychain straight away.
public enum WinSCPPassword {
    static let magic: UInt8 = 0xA3
    static let flag: UInt8 = 0xFF
    static let maxLen = 50

    public enum DecodeError: Error, Equatable {
        case malformed
        case keyMismatch
    }

    /// - Parameter key: `UserName + HostName` of the session, as WinSCP does.
    public static func decode(_ hex: String, key: String) throws -> String {
        var bytes = try hexBytes(hex)
        func next() throws -> UInt8 {
            guard !bytes.isEmpty else { throw DecodeError.malformed }
            return ~(bytes.removeFirst() ^ magic)
        }
        let first = try next()
        let length: Int
        if first == flag {
            _ = try next() // internal version byte
            length = Int(try next())
        } else {
            length = Int(first)
        }
        let shift = Int(try next())
        guard bytes.count >= shift + length else { throw DecodeError.malformed }
        bytes.removeFirst(shift)
        var out = [UInt8]()
        out.reserveCapacity(length)
        for _ in 0..<length { out.append(try next()) }

        if first == flag {
            let keyBytes = Array(key.utf8)
            guard out.starts(with: keyBytes) else { throw DecodeError.keyMismatch }
            out.removeFirst(keyBytes.count)
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Produces the same format WinSCP writes. Used for tests and for exporting.
    public static func encode(_ password: String, key: String,
                              random: () -> UInt8 = { UInt8.random(in: .min ... .max) }) -> String {
        let data = Array((key + password).utf8)
        var out = ""
        func put(_ c: UInt8) { out += String(format: "%02X", ~c ^ magic) }
        let shift = data.count < maxLen ? Int(random()) % (maxLen - data.count) : 0
        put(flag); put(0); put(UInt8(truncatingIfNeeded: data.count)); put(UInt8(shift))
        for _ in 0..<shift { put(random()) }
        data.forEach(put)
        while out.count < maxLen * 2 { put(random()) }
        return out
    }

    private static func hexBytes(_ s: String) throws -> [UInt8] {
        let chars = Array(s.utf8)
        guard chars.count % 2 == 0 else { throw DecodeError.malformed }
        var out = [UInt8]()
        out.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let hi = nibble(chars[i]), let lo = nibble(chars[i + 1]) else { throw DecodeError.malformed }
            out.append(hi << 4 | lo)
            i += 2
        }
        return out
    }

    private static func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return c - UInt8(ascii: "0")
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return c - UInt8(ascii: "A") + 10
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return c - UInt8(ascii: "a") + 10
        default: return nil
        }
    }
}
