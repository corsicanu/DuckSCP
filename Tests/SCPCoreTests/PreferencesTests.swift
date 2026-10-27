import Foundation
import Testing
@testable import SCPCore

@Suite struct PreferencesTests {
    @Test func tolerantDecodingKeepsDefaults() throws {
        let p = try JSONDecoder().decode(Preferences.self, from: Data(#"{"theme":"dark","unknownKey":1,"speedLimitKBps":"bad"}"#.utf8))
        #expect(p.theme == .dark)
        #expect(p.speedLimitKBps == 0)
        #expect(p.editorBundleIDs.first == "com.sublimetext.4" && p.editorBundleIDs.last == "com.apple.TextEdit")
    }

    @Test func storePersistsAndNotifies() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("p-\(UUID())/prefs.json")
        let store = PreferencesStore(fileURL: url)
        var notified = false
        let token = NotificationCenter.default.addObserver(forName: PreferencesStore.didChange, object: store, queue: nil) { _ in notified = true }
        defer { NotificationCenter.default.removeObserver(token) }
        try store.update { $0.showHiddenFiles = false }
        #expect(notified)
        #expect(PreferencesStore(fileURL: url).current.showHiddenFiles == false)
    }

    @Test func fileMasks() {
        let m = FileMask("*.tmp; .git/, Thumbs.db ;*.LOG")
        #expect(m.matches("a.tmp", isDirectory: false))
        #expect(m.matches("x.log", isDirectory: false))
        #expect(m.matches(".git", isDirectory: true))
        #expect(!m.matches(".git", isDirectory: false))
        #expect(m.matches("thumbs.db", isDirectory: false))
        #expect(!m.matches("a.tmpx", isDirectory: false))
        #expect(FileMask.glob("a?c*", "abcdef") && !FileMask.glob("a?c", "ac"))
        #expect(FileMask("").isEmpty)
    }

    @Test func foldersAlwaysFirst() {
        var e = [RemoteEntry(name: "b.txt", kind: .file, size: 5), RemoteEntry(name: "zdir", kind: .directory),
                 RemoteEntry(name: "a.txt", kind: .file, size: 9), RemoteEntry(name: "adir", kind: .directory),
                 RemoteEntry(name: "link", kind: .symlink, targetIsDirectory: true), RemoteEntry(name: "file10", kind: .file),
                 RemoteEntry(name: "file2", kind: .file)]
        EntrySort.sort(&e, by: .name, ascending: true)
        #expect(e.map(\.name) == ["adir", "link", "zdir", "a.txt", "b.txt", "file2", "file10"])
        EntrySort.sort(&e, by: .name, ascending: false)
        #expect(e.map(\.name) == ["zdir", "link", "adir", "file10", "file2", "b.txt", "a.txt"])
        EntrySort.sort(&e, by: .size, ascending: false)
        let topThreeAreFolders = e.prefix(3).allSatisfy { $0.isDirectoryLike }
        #expect(topThreeAreFolders)
    }
}

@Suite struct TransferOptionTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("opt-" + UUID().uuidString)

    @Test func excludeMaskSkipsFilesAndFolders() throws {
        let src = root.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: src.appendingPathComponent(".git"), withIntermediateDirectories: true)
        for f in ["keep.txt", "skip.tmp", ".git/config"] { try Data().write(to: src.appendingPathComponent(f)) }
        let dst = root.appendingPathComponent("dst")
        try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)
        var o = TransferEngine.Options()
        o.exclude = FileMask("*.tmp; .git/")
        try TransferEngine(fs: LocalFileSystem(), options: o, ask: { _ in .overwrite }, report: { _ in true })
            .upload([src], to: dst.path, deleteSource: true)
        let copied = try FileManager.default.contentsOfDirectory(atPath: dst.appendingPathComponent("src").path)
        #expect(copied == ["keep.txt"])
        #expect(FileManager.default.fileExists(atPath: src.path)) // excluded items mean the move is incomplete
    }

    @Test func speedLimitIsRespected() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let f = root.appendingPathComponent("f.bin")
        try Data(count: 1_000_000).write(to: f)
        let out = root.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var o = TransferEngine.Options()
        o.speedLimit = 2_000_000 // 1 MB at 2 MB/s ≈ 0.5 s
        let start = Date()
        try TransferEngine(fs: LocalFileSystem(), options: o, ask: { _ in .overwrite }, report: { _ in true }).upload([f], to: out.path)
        #expect(Date().timeIntervalSince(start) > 0.35)
    }

    @Test func timeShiftAndLogging() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let f = root.appendingPathComponent("t.txt")
        try Data("x".utf8).write(to: f)
        let when = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes([.modificationDate: when], ofItemAtPath: f.path)
        let logURL = root.appendingPathComponent("log/session.log")
        let log = try SessionLog(url: logURL)
        let fs = LoggingFileSystem(TimeShiftFileSystem(LocalFileSystem(), hours: 2), log: log, tag: "test")
        #expect(try fs.stat(f.path).modified == when.addingTimeInterval(7200))
        try fs.setModificationDate(f.path, when.addingTimeInterval(7200))
        #expect(try LocalFileSystem().stat(f.path).modified == when)
        _ = try? fs.list(root.appendingPathComponent("missing").path)
        Thread.sleep(forTimeInterval: 0.2)
        let text = try String(contentsOf: logURL, encoding: .utf8)
        #expect(text.contains("List ") && text.contains("! List"))
    }

    @Test func importsWinSCPPreferencesAndSiteOptions() {
        let ini = """
        [Configuration\\Interface]
        ConfirmDeleting=0
        DoubleClickAction=1
        [Configuration\\Interface\\Panels]
        ShowHiddenFiles=0
        [Configuration\\Interface\\CopyParam]
        PreserveTime=0
        CPSLimit=102400
        [Sessions\\s]
        HostName=h
        Compression=1
        TimeDifference=0.0416666666666667
        """
        let r = WinSCPIniImporter(keySearchDirectories: []).importData(Data(ini.utf8))
        var p = Preferences()
        r.preferenceChanges.forEach { $0.apply(&p) }
        #expect(!p.confirmDelete && p.doubleClickAction == .copy && !p.showHiddenFiles && !p.preserveTimestamp && p.speedLimitKBps == 100)
        #expect(r.sites.first?.sshCompression == true && r.sites.first?.timeOffsetHours == 1)
    }
}
