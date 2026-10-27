import Foundation
import Testing
@testable import SCPCore

private let httpd = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("macscp-test-httpd")
private let davUp = FileManager.default.fileExists(atPath: httpd.appendingPathComponent("dav.pid").path)
private let s3Up = FileManager.default.fileExists(atPath: httpd.appendingPathComponent("s3.pid").path)

@Suite(.enabled(if: davUp, "start scripts/test_httpd.sh"), .serialized)
struct WebDAVTests {
    let site = Site(path: "dav", fileProtocol: .webdav, hostName: "127.0.0.1", port: 2180, userName: "tester")

    @Test func roundTrip() throws {
        let fs = try Connector.connect(site: site, password: "secret", prompter: TestPrompter(),
                                       hostKeys: HostKeyStore(fileURL: URL(fileURLWithPath: "/dev/null"), knownHostsFiles: []))
        #expect(fs.protocolName == "WebDAV")
        try exerciseFileSystem(fs, parent: "/", attributes: false)
        // Folder rename via MOVE.
        try fs.makeDirectory("/ren-a")
        try fs.rename("/ren-a", to: "/ren b")
        #expect(try fs.stat("/ren b").kind == .directory)
        try fs.removeDirectory("/ren b")
    }

    @Test func wrongPasswordIsAuthenticationError() {
        #expect(throws: FileSystemError.self) {
            try WebDAVFileSystem.connect(site: site, password: "nope", prompter: TestPrompter())
        }
    }

    @Test func parsesMultistatusWithFailedPropstat() {
        let xml = """
        <?xml version="1.0"?><d:multistatus xmlns:d="DAV:">
        <d:response><d:href>/dir/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
        <d:response><d:href>http://h/dir/a%20b.txt</d:href>
          <d:propstat><d:prop><d:getcontentlength>12</d:getcontentlength><d:getlastmodified>Tue, 02 Jan 2024 03:04:05 GMT</d:getlastmodified><d:resourcetype/></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
          <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 404 Not Found</d:status></d:propstat>
        </d:response></d:multistatus>
        """
        let items = WebDAVParser.parse(Data(xml.utf8))
        #expect(items.count == 2)
        let file = items[1].entry
        #expect(file?.name == "a b.txt" && file?.kind == .file && file?.size == 12)
        #expect(file?.modified == Date(timeIntervalSince1970: 1_704_164_645))
    }
}

@Suite(.enabled(if: s3Up, "start scripts/test_httpd.sh"), .serialized)
struct S3Tests {
    let site: Site = {
        var s = Site(path: "s3", fileProtocol: .s3, hostName: "127.0.0.1", port: 2190, userName: "AKIDEXAMPLE")
        s.s3Region = "eu-central-1"
        return s
    }()

    func connect() throws -> RemoteFileSystem {
        try Connector.connect(site: site, password: "secret", prompter: TestPrompter(),
                              hostKeys: HostKeyStore(fileURL: URL(fileURLWithPath: "/dev/null"), knownHostsFiles: []))
    }

    @Test func roundTripInsideBucket() throws {
        let fs = try connect()
        let bucket = "/macscp-\(UUID().uuidString.lowercased().prefix(8))"
        try fs.makeDirectory(bucket)
        #expect(try fs.list("/").contains { $0.name == String(bucket.dropFirst()) && $0.kind == .directory })
        try exerciseFileSystem(fs, parent: bucket, attributes: false)
        try fs.removeDirectory(bucket)
    }

    @Test func listsBeyondOnePage() throws {
        let fs = try connect()
        let bucket = "/macscp-big-\(UUID().uuidString.lowercased().prefix(6))"
        try fs.makeDirectory(bucket)
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("empty-\(UUID())")
        try Data().write(to: empty)
        for i in 0..<2100 { try fs.upload(empty, to: "\(bucket)/f\(i).txt", offset: 0) { _ in true } }
        try fs.makeDirectory("\(bucket)/sub")
        let entries = try fs.list(bucket)
        #expect(entries.filter { $0.kind == .file }.count == 2100)
        #expect(entries.contains { $0.name == "sub" && $0.kind == .directory })
        #expect(try fs.stat("\(bucket)/sub").kind == .directory)
    }

    @Test func pathSplitting() {
        #expect(S3FileSystem.split("/b/a/c.txt") == ("b", "a/c.txt"))
        #expect(S3FileSystem.split("/") == ("", ""))
        #expect(S3FileSystem.encode("a b/c+") == "a%20b%2Fc%2B")
    }
}
