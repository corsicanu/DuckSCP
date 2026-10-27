import Foundation

/// Owns a connected file system and runs every call on one serial queue,
/// delivering results on the main queue.
public final class RemoteSession {
    public let site: Site
    public let fs: RemoteFileSystem
    public private(set) var homeDirectory = "/"
    private let queue: DispatchQueue
    public let connectedAt = Date()

    public init(site: Site, fs: RemoteFileSystem) {
        self.site = site
        self.fs = fs
        queue = DispatchQueue(label: "session.\(site.hostName)", qos: .userInitiated)
        homeDirectory = (try? fs.homeDirectory()) ?? "/"
    }

    public func perform<T>(_ work: @escaping (RemoteFileSystem) throws -> T,
                           completion: @escaping (Result<T, Error>) -> Void) {
        queue.async { [fs] in
            let result = Result { try work(fs) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Runs synchronously on the session queue (for use from background work).
    public func sync<T>(_ work: (RemoteFileSystem) throws -> T) throws -> T {
        try queue.sync { try work(fs) }
    }

    public func close() {
        queue.async { [fs] in fs.close() }
    }
}
