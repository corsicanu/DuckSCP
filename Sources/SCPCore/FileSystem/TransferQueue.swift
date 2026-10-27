import Foundation

/// Background transfers, processed one at a time on a dedicated connection so
/// browsing the session stays responsive (WinSCP's "Transfer in background").
public final class TransferQueue {
    public enum State: Equatable {
        case pending, connecting, running, done, failed(String), cancelled

        public var isFinished: Bool {
            switch self {
            case .done, .failed, .cancelled: return true
            default: return false
            }
        }
    }

    public enum Direction { case upload, download }

    public final class Item {
        public let id = UUID()
        public let direction: Direction
        /// Upload: local file URLs. Download: remote entries inside `sourceDir`.
        public let localSources: [URL]
        public let remoteSources: [RemoteEntry]
        public let sourceDir: String
        public let targetDir: String
        public let move: Bool
        public let options: TransferEngine.Options
        public internal(set) var state: State = .pending
        public internal(set) var progress = TransferEngine.Progress()
        public internal(set) var startedAt: Date?
        public internal(set) var finishedAt: Date?
        var cancelRequested = false
        var reconnects = 0

        public init(upload urls: [URL], to targetDir: String, move: Bool = false, options: TransferEngine.Options = .init()) {
            direction = .upload
            localSources = urls
            remoteSources = []
            sourceDir = urls.first?.deletingLastPathComponent().path ?? ""
            self.targetDir = targetDir
            self.move = move
            self.options = options
        }

        public init(download entries: [RemoteEntry], from sourceDir: String, to targetDir: String, move: Bool = false,
                    options: TransferEngine.Options = .init()) {
            direction = .download
            localSources = []
            remoteSources = entries
            self.sourceDir = sourceDir
            self.targetDir = targetDir
            self.move = move
            self.options = options
        }

        public var sourceDescription: String {
            let names = direction == .upload ? localSources.map(\.lastPathComponent) : remoteSources.map(\.name)
            let first = names.first.map { RemotePath.join(sourceDir, $0) } ?? sourceDir
            return names.count > 1 ? "\(first) (+\(names.count - 1))" : first
        }

        /// Bytes per second since the item started.
        public var speed: Double {
            guard let s = startedAt else { return 0 }
            let t = (finishedAt ?? Date()).timeIntervalSince(s)
            return t > 0.5 ? Double(progress.totalDone) / t : 0
        }
    }

    public private(set) var items: [Item] = []
    /// Called on the main queue whenever an item changes.
    public var onChange: ((Item) -> Void)?
    /// Called on the worker thread for overwrite questions.
    public var ask: (TransferEngine.Conflict) -> TransferEngine.Decision = { _ in .skip }

    private let connect: () throws -> RemoteFileSystem
    public var reconnectPolicy: () -> ReconnectPolicy = { ReconnectPolicy() }
    private var fs: RemoteFileSystem?
    private let worker = DispatchQueue(label: "transfer.queue", qos: .utility)
    private let lock = NSLock()
    private var running = false

    public init(connect: @escaping () throws -> RemoteFileSystem) {
        self.connect = connect
    }

    public func add(_ item: Item) {
        lock.withLock { items.append(item) }
        notify(item)
        pump()
    }

    public func cancel(_ item: Item) {
        lock.withLock {
            item.cancelRequested = true
            if item.state == .pending { item.state = .cancelled }
        }
        notify(item)
    }

    public func removeFinished() {
        lock.withLock { items.removeAll { $0.state.isFinished } }
    }

    public var hasActiveItems: Bool { lock.withLock { items.contains { !$0.state.isFinished } } }

    public func close() {
        lock.withLock { items.filter { !$0.state.isFinished }.forEach { $0.cancelRequested = true } }
        worker.async { [self] in
            fs?.close()
            fs = nil
        }
    }

    private func notify(_ item: Item) {
        DispatchQueue.main.async { [weak self] in self?.onChange?(item) }
    }

    private func pump() {
        let next: Item? = lock.withLock {
            guard !running, let i = items.first(where: { $0.state == .pending }) else { return nil }
            running = true
            return i
        }
        guard let item = next else { return }
        worker.async { [self] in
            process(item)
            lock.withLock { running = false }
            pump()
        }
    }

    private func process(_ item: Item) {
        do {
            if fs == nil {
                set(item, .connecting)
                fs = try connect()
            }
            guard let fs else { return }
            lock.withLock { item.startedAt = Date() }
            set(item, .running)
            var lastNotify = Date.distantPast
            let engine = TransferEngine(fs: fs, options: item.options, ask: ask) { [self] p in
                let cancelled: Bool = lock.withLock {
                    item.progress = p
                    return item.cancelRequested
                }
                if Date().timeIntervalSince(lastNotify) > 0.2 {
                    lastNotify = Date()
                    notify(item)
                }
                return !cancelled
            }
            switch item.direction {
            case .upload: try engine.upload(item.localSources, to: item.targetDir, deleteSource: item.move)
            case .download:
                try engine.download(from: item.sourceDir, entries: item.remoteSources,
                                    to: URL(fileURLWithPath: item.targetDir), deleteSource: item.move)
            }
            set(item, .done)
        } catch let e as FileSystemError where e.code == .cancelled {
            set(item, .cancelled)
        } catch let e as FileSystemError where e.code == .connection && !item.cancelRequested
                    && item.reconnects < reconnectPolicy().attempts {
            item.reconnects += 1
            fs?.close()
            fs = nil
            // Reconnect and retry the item; .filepart resume continues where it stopped.
            if let fresh = reconnectPolicy().reconnect(connect, status: { _ in set(item, .connecting) }) {
                fs = fresh
                lock.withLock { item.state = .pending }
                return process(item)
            }
            set(item, .failed(String(describing: e)))
        } catch {
            set(item, .failed(String(describing: error)))
        }
    }

    private func set(_ item: Item, _ state: State) {
        lock.withLock {
            item.state = state
            if state.isFinished { item.finishedAt = Date() }
        }
        notify(item)
    }
}

/// Answers connection questions for background connections from what the user
/// already answered for the foreground one, without showing any UI.
public final class CachedPrompter: ConnectionPrompter {
    public var password: String?
    public var passphrases: [String: String] = [:]
    public var acceptedHostKey: HostKey?
    public var acceptedUntrustedCertificate = false

    public init() {}

    public func status(_ text: String) {}
    public func banner(_ text: String) {}

    public func verifyHostKey(host: String, port: Int, key: HostKey, verdict: HostKeyVerdict) -> HostKeyDecision {
        key == acceptedHostKey ? .acceptOnce : .reject
    }

    public func askPassword(_ prompt: String) -> String? { password }
    public func confirmUntrustedCertificate(host: String, message: String) -> Bool { acceptedUntrustedCertificate }
    public func askPassphrase(keyPath: String) -> String? { passphrases[keyPath] }
}
