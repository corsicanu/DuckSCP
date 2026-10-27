// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Watches a downloaded copy of a remote file and uploads it back after every save
/// (WinSCP's "edit": F4, or double-click with the Edit action).
///
/// Editors save in two ways, and both must be caught:
/// - in place (Sublime Text's default, `atomic_save: false`): the file is rewritten,
///   which only a watcher on the file itself sees;
/// - atomically (TextEdit, BBEdit, Sublime with `atomic_save: true`): a new file is
///   renamed over the old one, which the old file's watcher misses.
/// So there are three triggers: a vnode source on the file (re-armed after a
/// replace), one on its folder, and a 1-second poll of size, date and inode as a
/// safety net. Changes are debounced so an upload starts after the save settles.
public final class RemoteFileEditor {
    public let local: URL
    public let remotePath: String
    private let upload: (URL, String, @escaping (Error?) -> Void) -> Void
    private let onUploaded: (Error?) -> Void
    private let queue: DispatchQueue
    private var fileSource: DispatchSourceFileSystemObject?
    private var dirSource: DispatchSourceFileSystemObject?
    private var poll: DispatchSourceTimer?
    private var pending: DispatchWorkItem?
    private var lastUploaded: Signature?
    private var uploading = false
    private var dirtyWhileUploading = false
    private var stopped = false

    /// Size, modification date and inode: any save changes at least one of them.
    struct Signature: Equatable {
        let size: UInt64, modified: TimeInterval, inode: UInt64
    }

    /// - Parameters:
    ///   - upload: uploads `local` to `remotePath` and calls back when done (any thread).
    ///   - onUploaded: called on `queue` after each upload attempt.
    public init(local: URL, remotePath: String, queue: DispatchQueue = .main, debounce: TimeInterval = 0.4,
                upload: @escaping (URL, String, @escaping (Error?) -> Void) -> Void,
                onUploaded: @escaping (Error?) -> Void) {
        self.local = local
        self.remotePath = remotePath
        self.queue = queue
        self.debounce = debounce
        self.upload = upload
        self.onUploaded = onUploaded
        lastUploaded = signature()
        queue.async { [weak self] in self?.start() }
    }

    private let debounce: TimeInterval

    func signature() -> Signature? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: local.path) else { return nil }
        return Signature(size: (a[.size] as? NSNumber)?.uint64Value ?? 0,
                         modified: (a[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0,
                         inode: (a[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0)
    }

    private func start() {
        guard !stopped else { return }
        armFileSource()
        let dfd = open(local.deletingLastPathComponent().path, O_EVTONLY)
        if dfd >= 0 {
            let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: dfd, eventMask: [.write, .rename, .delete, .link], queue: queue)
            src.setEventHandler { [weak self] in self?.armFileSource(); self?.changed() }
            src.setCancelHandler { close(dfd) }
            src.resume()
            dirSource = src
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.changed() }
        timer.resume()
        poll = timer
    }

    /// (Re)opens the watcher on the file; after an atomic save the old descriptor
    /// points at the replaced file, so a fresh one is needed.
    private func armFileSource() {
        fileSource?.cancel()
        fileSource = nil
        let fd = open(local.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .attrib, .rename, .delete], queue: queue)
        src.setEventHandler { [weak self, weak src] in
            guard let self, let src else { return }
            if !src.data.isDisjoint(with: [.rename, .delete]) { self.armFileSource() }
            self.changed()
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        fileSource = src
    }

    /// Debounced: uploads once the file has stopped changing for `debounce` seconds.
    private func changed() {
        guard !stopped, let sig = signature(), sig != lastUploaded else { return }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.uploadIfChanged() }
        pending = work
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    private func uploadIfChanged() {
        guard !stopped, let sig = signature(), sig != lastUploaded else { return }
        if uploading { dirtyWhileUploading = true; return }
        uploading = true
        lastUploaded = sig
        upload(local, remotePath) { [weak self] error in
            guard let self else { return }
            self.queue.async {
                self.uploading = false
                // A failed upload is reported once and retried on the next save,
                // not every second by the poll.
                self.onUploaded(error)
                if self.dirtyWhileUploading {
                    self.dirtyWhileUploading = false
                    self.changed()
                }
            }
        }
    }

    /// Stops watching. `removeCopy` deletes the local folder holding the copy.
    public func stop(removeCopy: Bool = true) {
        queue.async { [self] in
            stopped = true
            pending?.cancel()
            fileSource?.cancel()
            dirSource?.cancel()
            poll?.cancel()
            if removeCopy { try? FileManager.default.removeItem(at: local.deletingLastPathComponent()) }
        }
    }
}
