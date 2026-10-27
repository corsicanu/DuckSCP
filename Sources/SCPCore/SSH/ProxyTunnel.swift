// SPDX-License-Identifier: GPL-3.0-or-later
import CLibSSH2
import Foundation

/// Opens a TCP connection to `host:port` through a SOCKS4a, SOCKS5 or HTTP CONNECT proxy
/// and returns the connected socket, ready for the SSH handshake.
public enum ProxyTunnel {
    public static func open(_ proxy: ProxySettings, password: String?, host: String, port: Int,
                            timeout: TimeInterval, family: Int32) throws -> Int32 {
        var gai: Int32 = 0
        let fd = duckscp_tcp_connect(proxy.host, Int32(proxy.port), Int32(timeout * 1000), family, &gai)
        guard fd >= 0 else {
            throw FileSystemError(.connection, gai != 0 ? "Proxy host \"\(proxy.host)\" does not exist."
                                                        : "Cannot connect to proxy \(proxy.host):\(proxy.port).")
        }
        setTimeout(fd, timeout)
        do {
            switch proxy.kind {
            case .socks5: try socks5(fd, proxy: proxy, password: password, host: host, port: port)
            case .socks4: try socks4(fd, user: proxy.user, host: host, port: port)
            case .http: try httpConnect(fd, proxy: proxy, password: password, host: host, port: port)
            case .none: break
            }
        } catch {
            close(fd)
            throw error
        }
        setTimeout(fd, 0) // libssh2 manages its own timeouts
        return fd
    }

    private static func setTimeout(_ fd: Int32, _ seconds: TimeInterval) {
        var tv = timeval(tv_sec: Int(seconds), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    private static func send(_ fd: Int32, _ bytes: [UInt8]) throws {
        var sent = 0
        while sent < bytes.count {
            let n = bytes[sent...].withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
            guard n > 0 else { throw FileSystemError(.connection, "Proxy connection closed.") }
            sent += n
        }
    }

    private static func recv(_ fd: Int32, _ count: Int) throws -> [UInt8] {
        var out = [UInt8](repeating: 0, count: count)
        var got = 0
        while got < count {
            let n = out[got...].withUnsafeMutableBytes { Darwin.recv(fd, $0.baseAddress, $0.count, 0) }
            guard n > 0 else { throw FileSystemError(.connection, "Proxy did not answer.") }
            got += n
        }
        return out
    }

    private static func socks5(_ fd: Int32, proxy: ProxySettings, password: String?, host: String, port: Int) throws {
        let auth = !proxy.user.isEmpty
        try send(fd, auth ? [5, 2, 0, 2] : [5, 1, 0])
        let choice = try recv(fd, 2)
        guard choice[0] == 5, choice[1] != 0xFF else { throw FileSystemError(.connection, "SOCKS5 proxy refused all authentication methods.") }
        if choice[1] == 2 {
            let u = Array(proxy.user.utf8.prefix(255)), p = Array((password ?? "").utf8.prefix(255))
            try send(fd, [1, UInt8(u.count)] + u + [UInt8(p.count)] + p)
            guard try recv(fd, 2)[1] == 0 else { throw FileSystemError(.authentication, "SOCKS5 proxy rejected the user name or password.") }
        }
        let h = Array(host.utf8.prefix(255))
        try send(fd, [5, 1, 0, 3, UInt8(h.count)] + h + [UInt8(port >> 8), UInt8(port & 0xFF)])
        let reply = try recv(fd, 4)
        guard reply[1] == 0 else { throw FileSystemError(.connection, "SOCKS5 proxy could not reach \(host):\(port) (code \(reply[1])).") }
        switch reply[3] {
        case 1: _ = try recv(fd, 4 + 2)
        case 4: _ = try recv(fd, 16 + 2)
        case 3: _ = try recv(fd, Int(try recv(fd, 1)[0]) + 2)
        default: throw FileSystemError(.connection, "Invalid SOCKS5 reply.")
        }
    }

    /// SOCKS4a: the proxy resolves the host name.
    private static func socks4(_ fd: Int32, user: String, host: String, port: Int) throws {
        try send(fd, [4, 1, UInt8(port >> 8), UInt8(port & 0xFF), 0, 0, 0, 1] + Array(user.utf8) + [0] + Array(host.utf8) + [0])
        let reply = try recv(fd, 8)
        guard reply[1] == 0x5A else { throw FileSystemError(.connection, "SOCKS4 proxy refused the connection (code \(reply[1])).") }
    }

    private static func httpConnect(_ fd: Int32, proxy: ProxySettings, password: String?, host: String, port: Int) throws {
        let target = host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
        var request = "CONNECT \(target) HTTP/1.1\r\nHost: \(target)\r\n"
        if !proxy.user.isEmpty {
            request += "Proxy-Authorization: Basic \(Data("\(proxy.user):\(password ?? "")".utf8).base64EncodedString())\r\n"
        }
        try send(fd, Array((request + "\r\n").utf8))
        var head = [UInt8]()
        while !head.suffix(4).elementsEqual([13, 10, 13, 10]) {
            head += try recv(fd, 1)
            guard head.count < 16384 else { throw FileSystemError(.connection, "HTTP proxy reply too long.") }
        }
        let status = String(decoding: head, as: UTF8.self).split(separator: "\r\n").first.map(String.init) ?? ""
        let code = status.split(separator: " ").dropFirst().first.flatMap { Int($0) } ?? 0
        switch code {
        case 200..<300: return
        case 407: throw FileSystemError(.authentication, "HTTP proxy authentication failed.")
        default: throw FileSystemError(.connection, "HTTP proxy refused the connection: \(status)")
        }
    }
}
