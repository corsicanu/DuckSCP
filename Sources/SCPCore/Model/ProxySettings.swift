import Foundation

/// Per-site proxy (WinSCP: Advanced → Connection → Proxy).
public struct ProxySettings: Codable, Equatable {
    public enum Kind: String, Codable, CaseIterable {
        case none, socks4, socks5, http
        public var title: String {
            switch self {
            case .none: return "None"
            case .socks4: return "SOCKS4"
            case .socks5: return "SOCKS5"
            case .http: return "HTTP"
            }
        }
    }

    public var kind: Kind = .none
    public var host = ""
    public var port = 1080
    public var user = ""
    /// Keychain account for the proxy password (separate from the site password).
    public var secretID = UUID()

    public init() {}

    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = (try? c.decode(Kind.self, forKey: .kind)) ?? .none
        host = (try? c.decode(String.self, forKey: .host)) ?? ""
        port = (try? c.decode(Int.self, forKey: .port)) ?? 1080
        user = (try? c.decode(String.self, forKey: .user)) ?? ""
        secretID = (try? c.decode(UUID.self, forKey: .secretID)) ?? UUID()
    }

    public var isEnabled: Bool { kind != .none && !host.isEmpty }

    /// libcurl proxy URL; "h" variants resolve the target host on the proxy, like WinSCP.
    public var curlURL: String? {
        guard isEnabled else { return nil }
        let h = host.contains(":") ? "[\(host)]" : host
        switch kind {
        case .none: return nil
        case .socks4: return "socks4a://\(h):\(port)"
        case .socks5: return "socks5h://\(h):\(port)"
        case .http: return "http://\(h):\(port)"
        }
    }
}
