// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Foundation

/// Just enough X.509 handling to pin a server's public key: PEM → DER, and the
/// DER bytes of subjectPublicKeyInfo, whose SHA-256 is what libcurl's
/// CURLOPT_PINNEDPUBLICKEY ("sha256//<base64>") compares.
public enum Certificate {
    /// First certificate in libcurl's CERTINFO text ("Cert:-----BEGIN CERTIFICATE-----...").
    public static func firstDER(fromPEM text: String) -> Data? {
        guard let begin = text.range(of: "-----BEGIN CERTIFICATE-----"),
              let end = text.range(of: "-----END CERTIFICATE-----", range: begin.upperBound..<text.endIndex) else { return nil }
        let b64 = text[begin.upperBound..<end.lowerBound].filter { !$0.isWhitespace }
        return Data(base64Encoded: String(b64))
    }

    /// "AB:CD:…" SHA-256 of the whole certificate, as browsers and WinSCP show it.
    public static func fingerprint(_ der: Data) -> String {
        SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    /// libcurl pin for the certificate's public key.
    public static func pin(_ der: Data) -> String? {
        subjectPublicKeyInfo(der).map { "sha256//" + Data(SHA256.hash(data: $0)).base64EncodedString() }
    }

    /// Certificate ::= SEQ { tbsCertificate SEQ { [0] version?, serial, signature, issuer, validity, subject, spki, ... } ... }
    public static func subjectPublicKeyInfo(_ der: Data) -> Data? {
        let bytes = [UInt8](der)
        guard let cert = element(bytes, at: 0), let tbs = element(bytes, at: cert.contentStart) else { return nil }
        var pos = tbs.contentStart
        var index = 0
        while pos < tbs.end, let e = element(bytes, at: pos) {
            if index == 0 && bytes[pos] == 0xA0 { pos = e.end; continue } // optional explicit version
            if index == 5 { return Data(bytes[pos..<e.end]) }
            index += 1
            pos = e.end
        }
        return nil
    }

    private struct Element { let contentStart: Int; let end: Int }

    /// Parses one DER TLV at `pos` (single-byte tags, definite lengths).
    private static func element(_ b: [UInt8], at pos: Int) -> Element? {
        guard pos + 2 <= b.count else { return nil }
        var i = pos + 1
        var length = Int(b[i])
        i += 1
        if length & 0x80 != 0 {
            let n = length & 0x7F
            guard n > 0, n <= 4, i + n <= b.count else { return nil }
            length = b[i..<(i + n)].reduce(0) { $0 << 8 | Int($1) }
            i += n
        }
        guard i + length <= b.count else { return nil }
        return Element(contentStart: i, end: i + length)
    }
}
