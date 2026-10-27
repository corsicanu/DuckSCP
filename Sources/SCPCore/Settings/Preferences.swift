import Foundation

/// Application preferences, mirroring WinSCP's Preferences dialog sections.
/// Decoding is tolerant: missing keys keep their defaults.
public struct Preferences: Codable, Equatable {
    // MARK: Environment
    public enum Theme: String, Codable, CaseIterable { case system, light, dark }
    public enum Interface: String, Codable, CaseIterable { case commander, explorer }
    public var theme: Theme = .system
    public var interface: Interface = .commander

    // MARK: Confirmations
    public var confirmDelete = true
    public var confirmOverwrite = true
    public var confirmExitWithTransfers = true
    public var confirmDisconnect = false

    // MARK: Panels
    public enum SizeFormat: String, Codable, CaseIterable { case bytes, kilobytes, short }
    public enum DoubleClickAction: String, Codable, CaseIterable { case open, edit, copy }
    public var showHiddenFiles = true
    public var sizeFormat: SizeFormat = .bytes
    public var doubleClickAction: DoubleClickAction = .edit
    public var useTrashForLocalDelete = true
    public var synchronizedBrowsing = false

    // MARK: Editors
    /// Tried in order; the first installed one opens files (F4 / Edit).
    public var editorBundleIDs = ["com.sublimetext.4", "com.sublimetext.3", "com.sublimetext.2", "com.apple.TextEdit"]
    /// Path to an editor .app chosen by the user; takes precedence when set.
    public var customEditorPath = ""

    // MARK: Transfer
    public var preserveTimestamp = true
    public var preservePermissions = false
    public var resumeEnabled = true
    public var resumeThresholdKB = 100
    public var transferInBackgroundByDefault = false
    /// 0 = unlimited.
    public var speedLimitKBps = 0
    /// WinSCP-style exclude mask, e.g. "*.tmp; .git/; Thumbs.db".
    public var excludeMask = ""

    // MARK: Endurance
    public var autoReconnect = true
    public var reconnectAttempts = 3
    public var reconnectDelaySeconds = 5

    // MARK: Network
    public enum IPVersion: String, Codable, CaseIterable { case auto, ipv4, ipv6 }
    public var connectTimeoutSeconds = 15
    public var keepaliveSeconds = 30
    public var ipVersion: IPVersion = .auto

    // MARK: Logging
    public var loggingEnabled = false
    public var logPath = ""

    public init() {}

    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func get<T: Decodable>(_ k: CodingKeys, _ into: inout T) { if let v = try? c.decode(T.self, forKey: k) { into = v } }
        get(.theme, &theme); get(.interface, &interface)
        get(.confirmDelete, &confirmDelete); get(.confirmOverwrite, &confirmOverwrite)
        get(.confirmExitWithTransfers, &confirmExitWithTransfers); get(.confirmDisconnect, &confirmDisconnect)
        get(.showHiddenFiles, &showHiddenFiles); get(.sizeFormat, &sizeFormat); get(.doubleClickAction, &doubleClickAction)
        get(.useTrashForLocalDelete, &useTrashForLocalDelete); get(.synchronizedBrowsing, &synchronizedBrowsing)
        get(.editorBundleIDs, &editorBundleIDs); get(.customEditorPath, &customEditorPath)
        get(.preserveTimestamp, &preserveTimestamp); get(.preservePermissions, &preservePermissions)
        get(.resumeEnabled, &resumeEnabled); get(.resumeThresholdKB, &resumeThresholdKB)
        get(.transferInBackgroundByDefault, &transferInBackgroundByDefault); get(.speedLimitKBps, &speedLimitKBps)
        get(.excludeMask, &excludeMask)
        get(.autoReconnect, &autoReconnect); get(.reconnectAttempts, &reconnectAttempts); get(.reconnectDelaySeconds, &reconnectDelaySeconds)
        get(.connectTimeoutSeconds, &connectTimeoutSeconds); get(.keepaliveSeconds, &keepaliveSeconds); get(.ipVersion, &ipVersion)
        get(.loggingEnabled, &loggingEnabled); get(.logPath, &logPath)
    }

    /// Transfer engine options derived from these preferences.
    public var transferOptions: TransferEngine.Options {
        var o = TransferEngine.Options()
        o.preserveTimestamp = preserveTimestamp
        o.preservePermissions = preservePermissions
        o.resume = resumeEnabled
        o.partialThreshold = UInt64(max(0, resumeThresholdKB)) * 1024
        o.speedLimit = UInt64(max(0, speedLimitKBps)) * 1024
        o.exclude = FileMask(excludeMask)
        return o
    }
}

/// Loads and saves preferences as JSON (mode 0600) and broadcasts changes.
public final class PreferencesStore {
    public static let didChange = Notification.Name("PreferencesDidChange")
    public let fileURL: URL
    private let lock = NSLock()
    private var value: Preferences

    /// Safe to read from any thread (sessions read endurance/network settings off the main thread).
    public var current: Preferences { lock.withLock { value } }

    public init(fileURL: URL) {
        self.fileURL = fileURL
        value = (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode(Preferences.self, from: $0) } ?? Preferences()
    }

    public func update(_ change: (inout Preferences) -> Void) throws {
        var p = current
        change(&p)
        guard p != current else { return }
        lock.withLock { value = p }
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(p).write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}

/// WinSCP file masks: "*.txt; *.log" include patterns separated by ";" or ",";
/// a trailing "/" matches directories only ("node_modules/").
public struct FileMask: Equatable {
    public let patterns: [(glob: String, directoryOnly: Bool)]
    public let source: String

    public init(_ mask: String) {
        source = mask
        patterns = mask.split(whereSeparator: { $0 == ";" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { $0.hasSuffix("/") ? (String($0.dropLast()), true) : ($0, false) }
    }

    public var isEmpty: Bool { patterns.isEmpty }

    public func matches(_ name: String, isDirectory: Bool) -> Bool {
        patterns.contains { p in (!p.directoryOnly || isDirectory) && FileMask.glob(p.glob, name) }
    }

    /// Case-insensitive "*" and "?" matching (WinSCP masks are case-insensitive).
    public static func glob(_ pattern: String, _ name: String) -> Bool {
        let p = Array(pattern.lowercased()), n = Array(name.lowercased())
        var pi = 0, ni = 0, star = -1, mark = 0
        while ni < n.count {
            if pi < p.count, p[pi] == "?" || p[pi] == n[ni] { pi += 1; ni += 1 }
            else if pi < p.count, p[pi] == "*" { star = pi; mark = ni; pi += 1 }
            else if star >= 0 { pi = star + 1; mark += 1; ni = mark }
            else { return false }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }

    public static func == (a: FileMask, b: FileMask) -> Bool { a.source == b.source }
}
