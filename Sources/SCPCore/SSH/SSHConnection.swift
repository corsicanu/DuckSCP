import CLibSSH2
import Foundation

/// UI hooks used while connecting. Called on the connecting (background) thread;
/// implementations may block while they ask the user.
public protocol ConnectionPrompter: AnyObject {
    func status(_ text: String)
    func verifyHostKey(host: String, port: Int, key: HostKey, verdict: HostKeyVerdict) -> HostKeyDecision
    /// Returns nil when the user cancels.
    func askPassword(_ prompt: String) -> String?
    func askPassphrase(keyPath: String) -> String?
    func banner(_ text: String)
}

/// An authenticated libssh2 session over a TCP socket.
public final class SSHConnection {
    let session: OpaquePointer
    private let socket: Int32
    private var closed = false

    private static let initOnce: Void = { _ = libssh2_init(0) }()

    /// Connects, verifies the host key and authenticates. Throws `FileSystemError`.
    public static func open(site: Site, password: String?, prompter: ConnectionPrompter, hostKeys: HostKeyStore,
                            timeout: TimeInterval = 15) throws -> SSHConnection {
        _ = initOnce
        prompter.status("Searching for host...")
        var gaiError: Int32 = 0
        let fd = macscp_tcp_connect(site.hostName, Int32(site.port), Int32(timeout * 1000), &gaiError)
        guard fd >= 0 else {
            if gaiError != 0 { throw FileSystemError(.connection, "Host \"\(site.hostName)\" does not exist.") }
            throw FileSystemError(.connection, "Network error: Connection to \"\(site.hostName)\" \(errno == ETIMEDOUT ? "timed out" : "refused").")
        }
        guard let session = macscp_session_init() else {
            Darwin.close(fd)
            throw FileSystemError(.connection, "Cannot initialize SSH session.")
        }
        let conn = SSHConnection(session: session, socket: fd)
        do {
            try conn.handshake(site: site, prompter: prompter, hostKeys: hostKeys, timeout: timeout)
            try conn.authenticate(site: site, password: password, prompter: prompter)
            libssh2_keepalive_config(session, 1, 30)
            return conn
        } catch {
            conn.close()
            throw error
        }
    }

    private init(session: OpaquePointer, socket: Int32) {
        self.session = session
        self.socket = socket
    }

    deinit { close() }

    public func close() {
        guard !closed else { return }
        closed = true
        libssh2_session_disconnect_ex(session, SSH_DISCONNECT_BY_APPLICATION, "Closed by user", "")
        libssh2_session_free(session)
        Darwin.close(socket)
    }

    /// Sends a keepalive if one is due. Call periodically on the session queue.
    public func keepalive() {
        var next: Int32 = 0
        libssh2_keepalive_send(session, &next)
    }

    func error(_ fallback: String, code: FileSystemError.Code = .other) -> FileSystemError {
        var rc: Int32 = 0
        let msg = String(cString: macscp_last_error(session, &rc))
        if rc == LIBSSH2_ERROR_SOCKET_DISCONNECT || rc == LIBSSH2_ERROR_SOCKET_SEND || rc == LIBSSH2_ERROR_SOCKET_RECV
            || rc == LIBSSH2_ERROR_TIMEOUT {
            return FileSystemError(.connection, "Connection lost: \(msg.isEmpty ? fallback : msg)")
        }
        return FileSystemError(code, msg.isEmpty ? fallback : "\(fallback): \(msg)")
    }

    // MARK: Handshake

    private func handshake(site: Site, prompter: ConnectionPrompter, hostKeys: HostKeyStore, timeout: TimeInterval) throws {
        libssh2_session_set_blocking(session, 1)
        libssh2_session_set_timeout(session, Int(timeout * 2000))
        prompter.status("Connecting to host...")
        guard libssh2_session_handshake(session, socket) == 0 else {
            throw error("Server unexpectedly closed network connection", code: .connection)
        }
        var len = 0
        var type: Int32 = 0
        guard let raw = libssh2_session_hostkey(session, &len, &type), len > 0 else {
            throw error("Cannot read server host key", code: .hostKey)
        }
        let blob = Data(bytes: raw, count: len)
        var reader = SSHWire.Reader(blob)
        let key = HostKey(type: (try? reader.text()) ?? "unknown", blob: blob)

        let verdict = hostKeys.verify(host: site.hostName, port: site.port, key: key)
        if verdict != .trusted {
            switch prompter.verifyHostKey(host: site.hostName, port: site.port, key: key, verdict: verdict) {
            case .acceptAndSave:
                do { try hostKeys.save(host: site.hostName, port: site.port, key: key) } catch {
                    prompter.status("Could not save host key: \(error)")
                }
            case .acceptOnce: break
            case .reject: throw FileSystemError(.hostKey, "Host key was not verified.")
            }
        }
    }

    // MARK: Authentication

    private func authenticate(site: Site, password: String?, prompter: ConnectionPrompter) throws {
        let user = site.userName.isEmpty ? NSUserName() : site.userName
        prompter.status("Authenticating...")
        let methodsPtr = libssh2_userauth_list(session, user, UInt32(user.utf8.count))
        if methodsPtr == nil, libssh2_userauth_authenticated(session) != 0 { return } // "none" auth accepted
        let methodList = methodsPtr.map { String(cString: $0) } ?? "publickey,password,keyboard-interactive"
        let methods = Set(methodList.split(separator: ",").map(String.init))
        var bannerPtr: UnsafeMutablePointer<CChar>?
        if libssh2_userauth_banner(session, &bannerPtr) == 0, let bannerPtr {
            let text = String(cString: bannerPtr).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { prompter.banner(text) }
        }

        if methods.contains("publickey") {
            if !site.privateKeyPath.isEmpty, try authenticateWithKeyFile(site.privateKeyPath, user: user, prompter: prompter) { return }
            if authenticateWithAgent(user: user, prompter: prompter) { return }
        }

        var current = password
        let canPassword = methods.contains("password"), canKbd = methods.contains("keyboard-interactive")
        guard canPassword || canKbd else {
            throw FileSystemError(.authentication, "No supported authentication methods available (server sent: \(methods.sorted().joined(separator: ", "))).")
        }
        for attempt in 0..<3 {
            if current == nil || attempt > 0 {
                guard let p = prompter.askPassword(attempt == 0 ? "Password:" : "Access denied. Password:") else { throw FileSystemError.cancelled }
                current = p
            }
            guard let pw = current else { continue }
            prompter.status("Authenticating with password...")
            if canKbd, macscp_userauth_kbdint(session, user, pw) == 0 { return }
            if canPassword, macscp_userauth_password(session, user, pw) == 0 { return }
        }
        throw FileSystemError(.authentication, "Access denied.")
    }

    /// Tries a private key file (OpenSSH/PEM directly, PuTTY .ppk via conversion).
    private func authenticateWithKeyFile(_ path: String, user: String, prompter: ConnectionPrompter) throws -> Bool {
        let expanded = (path as NSString).expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: expanded) else {
            prompter.status("Cannot read private key \(path)")
            return false
        }
        prompter.status("Authenticating with public key \"\(URL(fileURLWithPath: expanded).lastPathComponent)\"...")
        if PuTTYKey.isPPK(data) {
            var passphrase: String?
            if PuTTYKey.needsPassphrase(data) {
                guard let p = prompter.askPassphrase(keyPath: path) else { throw FileSystemError.cancelled }
                passphrase = p
            }
            let pem: String
            do { pem = try PuTTYKey.toOpenSSH(data, passphrase: passphrase) } catch {
                throw FileSystemError(.authentication, "\(path): \(error)")
            }
            return pem.withCString { ptr in
                libssh2_userauth_publickey_frommemory(session, user, user.utf8.count, nil, 0, ptr, strlen(ptr), nil) == 0
            }
        }
        if libssh2_userauth_publickey_fromfile_ex(session, user, UInt32(user.utf8.count), nil, expanded, nil) == 0 { return true }
        // Most likely encrypted: ask for the passphrase (3 tries).
        for _ in 0..<3 {
            guard let p = prompter.askPassphrase(keyPath: path) else { throw FileSystemError.cancelled }
            if libssh2_userauth_publickey_fromfile_ex(session, user, UInt32(user.utf8.count), nil, expanded, p) == 0 { return true }
        }
        return false
    }

    /// ssh-agent (the macOS equivalent of Pageant).
    private func authenticateWithAgent(user: String, prompter: ConnectionPrompter) -> Bool {
        guard ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"] != nil, let agent = libssh2_agent_init(session) else { return false }
        defer {
            libssh2_agent_disconnect(agent)
            libssh2_agent_free(agent)
        }
        guard libssh2_agent_connect(agent) == 0, libssh2_agent_list_identities(agent) == 0 else { return false }
        var prev: UnsafeMutablePointer<libssh2_agent_publickey>?
        var identity: UnsafeMutablePointer<libssh2_agent_publickey>?
        while libssh2_agent_get_identity(agent, &identity, prev) == 0 {
            prompter.status("Authenticating with agent key...")
            if libssh2_agent_userauth(agent, user, identity) == 0 { return true }
            prev = identity
        }
        return false
    }

    // MARK: Exec channel (used by SCP)

    /// Runs a command and returns (exit status, stdout, stderr).
    func exec(_ command: String) throws -> (Int32, Data, String) {
        guard let channel = macscp_channel_open_session(session) else { throw error("Cannot open channel", code: .connection) }
        defer { libssh2_channel_free(channel) }
        guard macscp_channel_exec(channel, command) == 0 else { throw error("Cannot execute command") }
        var out = Data(), err = Data()
        var buf = [CChar](repeating: 0, count: 32 * 1024)
        while true {
            let n = libssh2_channel_read_ex(channel, 0, &buf, buf.count)
            if n > 0 { out.append(Data(bytes: buf, count: n)); continue }
            if n < 0 { throw error("Read failed", code: .connection) }
            break
        }
        while true {
            let n = macscp_channel_read_stderr(channel, &buf, buf.count)
            if n > 0 { err.append(Data(bytes: buf, count: n)); continue }
            break
        }
        libssh2_channel_close(channel)
        libssh2_channel_wait_closed(channel)
        let status = libssh2_channel_get_exit_status(channel)
        return (status, out, String(decoding: err, as: UTF8.self))
    }
}
