import Foundation

/// WinSCP "Endurance": what to do when a connection drops.
public struct ReconnectPolicy {
    public var enabled = true
    public var attempts = 3
    public var delay: TimeInterval = 5
    public init() {}
    public init(_ p: Preferences) {
        enabled = p.autoReconnect
        attempts = max(1, p.reconnectAttempts)
        delay = TimeInterval(max(0, p.reconnectDelaySeconds))
    }

    /// Replaces a dead connection: tries `connect` up to `attempts` times.
    /// `status` reports progress; returns nil when reconnecting is off or failed.
    public func reconnect(_ connect: () throws -> RemoteFileSystem, status: (String) -> Void) -> RemoteFileSystem? {
        guard enabled else { return nil }
        for attempt in 1...attempts {
            status("Connection lost. Reconnecting (\(attempt)/\(attempts))...")
            if attempt > 1 { Thread.sleep(forTimeInterval: delay) }
            if let fs = try? connect() { return fs }
        }
        return nil
    }
}

/// Owns a connected file system and runs every call on one serial queue,
/// delivering results on the main queue. Reconnects transparently after
/// connection errors (Preferences → Endurance).
public final class RemoteSession {
    public let site: Site
    /// Replaced after a reconnect. Use only inside `perform`/`sync` (on the session queue).
    public private(set) var fs: RemoteFileSystem {
        didSet { lock.withLock { cachedProtocolName = fs.protocolName } }
    }
    private let lock = NSLock()
    private var cachedProtocolName = ""
    /// Thread-safe, for the status bar.
    public var protocolName: String { lock.withLock { cachedProtocolName } }
    public private(set) var homeDirectory = "/"
    private let queue: DispatchQueue
    public let connectedAt = Date()
    /// Opens another connection to the same site (transfer queue, reconnects).
    public let makeConnection: () throws -> RemoteFileSystem
    /// Read on the session queue for every failure, so preference changes apply at once.
    public var reconnectPolicy: () -> ReconnectPolicy = { ReconnectPolicy() }
    /// Status messages while reconnecting (called on the main queue).
    public var onStatus: ((String) -> Void)?

    public init(site: Site, fs: RemoteFileSystem, makeConnection: @escaping () throws -> RemoteFileSystem) {
        self.site = site
        self.fs = fs
        self.makeConnection = makeConnection
        cachedProtocolName = fs.protocolName
        queue = DispatchQueue(label: "session.\(site.hostName)", qos: .userInitiated)
        homeDirectory = (try? fs.homeDirectory()) ?? "/"
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 15, repeating: 15) // libssh2 sends only when its interval is due
        timer.setEventHandler { [weak self] in self?.fs.keepalive() }
        timer.resume()
        keepaliveTimer = timer
    }

    private var keepaliveTimer: DispatchSourceTimer?

    public func perform<T>(_ work: @escaping (RemoteFileSystem) throws -> T,
                           completion: @escaping (Result<T, Error>) -> Void) {
        queue.async { [self] in
            let result = Result { try runReconnecting(work) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Runs synchronously on the session queue (for use from background work).
    public func sync<T>(_ work: (RemoteFileSystem) throws -> T) throws -> T {
        try queue.sync { try runReconnecting(work) }
    }

    /// Runs `work`; after a connection error, reconnects and runs it once more.
    private func runReconnecting<T>(_ work: (RemoteFileSystem) throws -> T) throws -> T {
        do {
            return try work(fs)
        } catch let e as FileSystemError where e.code == .connection {
            fs.close()
            let report: (String) -> Void = { [weak self] text in DispatchQueue.main.async { self?.onStatus?(text) } }
            guard let fresh = reconnectPolicy().reconnect(makeConnection, status: report) else { throw e }
            fs = fresh
            report("Reconnected.")
            return try work(fs)
        }
    }

    public func close() {
        keepaliveTimer?.cancel()
        queue.async { [self] in fs.close() }
    }
}
