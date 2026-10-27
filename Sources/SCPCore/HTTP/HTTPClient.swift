import CCurl
import Foundation

/// Small libcurl HTTP(S) client shared by WebDAV and S3: one easy handle (connection
/// reuse), credentials, proxy, timeouts, TLS trust with certificate pinning, and
/// streaming to/from files with progress and cancel.
final class HTTPClient {
    struct Response {
        var status: Int
        var headers: [String: String]
        var body: Data
    }

    enum Auth {
        case none
        case basicOrDigest(user: String, password: String)
        /// AWS Signature V4 ("aws:amz:<region>:s3"), user = access key, password = secret.
        case sigV4(provider: String, accessKey: String, secret: String)
    }

    private let curl: UnsafeMutableRawPointer
    private let errorBuffer = UnsafeMutablePointer<CChar>.allocate(capacity: Int(CURL_ERROR_SIZE) + 1)
    let site: Site
    var auth: Auth = .none
    var settings = ConnectionSettings()
    /// TLS public-key pin; nil = system trust store.
    var pin: String?

    private static let initOnce: Void = { curl_global_init(Int(CURL_GLOBAL_DEFAULT)) }()

    init(site: Site) throws {
        _ = Self.initOnce
        guard let h = curl_easy_init() else { throw FileSystemError(.connection, "Cannot initialize libcurl.") }
        curl = h
        self.site = site
        errorBuffer.initialize(repeating: 0, count: Int(CURL_ERROR_SIZE) + 1)
    }

    deinit {
        curl_easy_cleanup(curl)
        errorBuffer.deallocate()
    }

    var isTLS: Bool { site.ftpEncryption != .none }

    var baseURL: String {
        let host = site.hostName.contains(":") ? "[\(site.hostName)]" : site.hostName
        return "\(isTLS ? "https" : "http")://\(host):\(site.port)"
    }

    /// Percent-encodes each path component (keeps "/").
    static func encodePath(_ path: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/;?#%+&=")
        return path.split(separator: "/", omittingEmptySubsequences: true)
            .map { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? String($0) }
            .joined(separator: "/")
    }

    // MARK: Collecting

    private final class Sink {
        var data = Data()
        var file: FileHandle?
        var input: FileHandle?
        var inputData: Data?
        var inputOffset = 0
        var inputStart: UInt64 = 0
        var progressStart: UInt64 = 0
        var total: UInt64 = 0
        var progress: ((UInt64) -> Bool)?
        var headers: [String: String] = [:]
        var error: Error?
    }

    private static let writeCB: macscp_io_cb = { ptr, size, n, user in
        let sink = Unmanaged<Sink>.fromOpaque(user!).takeUnretainedValue()
        let count = size * n
        let chunk = Data(bytes: ptr!, count: count)
        if let f = sink.file {
            do { try f.write(contentsOf: chunk) } catch { sink.error = error; return 0 }
        } else {
            sink.data.append(chunk)
        }
        sink.total += UInt64(count)
        if let p = sink.progress, !p(sink.total) { return 0 }
        return count
    }

    private static let readCB: macscp_io_cb = { ptr, size, n, user in
        let sink = Unmanaged<Sink>.fromOpaque(user!).takeUnretainedValue()
        let max = size * n
        var chunk: Data
        if let d = sink.inputData {
            chunk = d.subdata(in: sink.inputOffset..<min(d.count, sink.inputOffset + max))
            sink.inputOffset += chunk.count
        } else {
            chunk = (try? sink.input?.read(upToCount: max)) ?? Data()
        }
        guard !chunk.isEmpty else { return 0 }
        chunk.copyBytes(to: UnsafeMutableRawPointer(ptr!).assumingMemoryBound(to: UInt8.self), count: chunk.count)
        sink.total += UInt64(chunk.count)
        if let p = sink.progress, !p(sink.total) { return Int(CURL_READFUNC_ABORT) }
        return chunk.count
    }

    /// Rewinds the upload source (file or in-memory body) to `offset` from the start.
    private static let seekCB: macscp_seek_cb = { user, offset, origin in
        let sink = Unmanaged<Sink>.fromOpaque(user!).takeUnretainedValue()
        guard origin == SEEK_SET else { return Int32(CURL_SEEKFUNC_CANTSEEK) }
        if sink.inputData != nil {
            sink.inputOffset = Int(offset)
        } else if let f = sink.input {
            do { try f.seek(toOffset: sink.inputStart + UInt64(offset)) } catch { return Int32(CURL_SEEKFUNC_FAIL) }
        }
        sink.total = sink.progressStart + UInt64(offset)
        return Int32(CURL_SEEKFUNC_OK)
    }

    private static let headerCB: macscp_io_cb = { ptr, size, n, user in
        let sink = Unmanaged<Sink>.fromOpaque(user!).takeUnretainedValue()
        let line = String(decoding: Data(bytes: ptr!, count: size * n), as: UTF8.self)
        if line.hasPrefix("HTTP/") { sink.headers.removeAll() } // keep only the final response's headers
        if let colon = line.firstIndex(of: ":") {
            sink.headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return size * n
    }

    // MARK: Requests

    struct Request {
        var method = "GET"
        var url: String
        var headers: [String] = []
        var body: Data?
        var uploadFile: FileHandle?
        var uploadSize: UInt64 = 0
        var downloadTo: FileHandle?
        var rangeFrom: UInt64 = 0
        var noBody = false
        var progress: ((UInt64) -> Bool)?
        var progressStart: UInt64 = 0
    }

    func perform(_ r: Request, what: String, path: String) throws -> Response {
        curl_easy_reset(curl)
        macscp_curl_str(curl, CURLOPT_URL, r.url)
        macscp_curl_long(curl, CURLOPT_CONNECTTIMEOUT, Int(settings.timeout))
        macscp_curl_long(curl, CURLOPT_LOW_SPEED_LIMIT, 1)
        macscp_curl_long(curl, CURLOPT_LOW_SPEED_TIME, 60)
        macscp_curl_long(curl, CURLOPT_NOSIGNAL, 1)
        macscp_curl_ptr(curl, CURLOPT_ERRORBUFFER, errorBuffer)
        errorBuffer[0] = 0
        switch settings.ipVersion {
        case .ipv4: macscp_curl_long(curl, CURLOPT_IPRESOLVE, Int(CURL_IPRESOLVE_V4))
        case .ipv6: macscp_curl_long(curl, CURLOPT_IPRESOLVE, Int(CURL_IPRESOLVE_V6))
        case .auto: break
        }
        if let pin {
            macscp_curl_long(curl, CURLOPT_SSL_VERIFYPEER, 0)
            macscp_curl_long(curl, CURLOPT_SSL_VERIFYHOST, 0)
            macscp_curl_str(curl, CURLOPT_PINNEDPUBLICKEY, pin)
        }
        if let proxy = site.proxy.curlURL {
            macscp_curl_str(curl, CURLOPT_PROXY, proxy)
            if !site.proxy.user.isEmpty {
                macscp_curl_str(curl, CURLOPT_PROXYUSERNAME, site.proxy.user)
                macscp_curl_str(curl, CURLOPT_PROXYPASSWORD, settings.proxyPassword ?? "")
            }
            if site.proxy.kind == .http { macscp_curl_long(curl, CURLOPT_HTTPPROXYTUNNEL, 1) }
        }
        switch auth {
        case .none: break
        case .basicOrDigest(let user, let password):
            macscp_curl_str(curl, CURLOPT_USERNAME, user)
            macscp_curl_str(curl, CURLOPT_PASSWORD, password)
            macscp_curl_long(curl, CURLOPT_HTTPAUTH, 1 | 2) // CURLAUTH_BASIC | CURLAUTH_DIGEST (macros Swift cannot import)
        case .sigV4(let provider, let key, let secret):
            macscp_curl_str(curl, CURLOPT_AWS_SIGV4, provider)
            macscp_curl_str(curl, CURLOPT_USERNAME, key)
            macscp_curl_str(curl, CURLOPT_PASSWORD, secret)
        }

        var headers = r.headers
        if r.uploadFile != nil || r.body != nil {
            if r.method == "PUT" {
                macscp_curl_long(curl, CURLOPT_UPLOAD, 1)
                macscp_curl_off(curl, CURLOPT_INFILESIZE_LARGE, curl_off_t(r.uploadFile != nil ? r.uploadSize : UInt64(r.body!.count)))
            } else {
                macscp_curl_long(curl, CURLOPT_POST, 1)
                macscp_curl_off(curl, CURLOPT_POSTFIELDSIZE_LARGE, curl_off_t(r.body?.count ?? 0))
                macscp_curl_str(curl, CURLOPT_CUSTOMREQUEST, r.method)
            }
            headers.append("Expect:") // no 100-continue round trip
        } else if r.noBody {
            macscp_curl_long(curl, CURLOPT_NOBODY, 1)
        } else if r.method != "GET" {
            macscp_curl_str(curl, CURLOPT_CUSTOMREQUEST, r.method)
        }
        if r.rangeFrom > 0 { macscp_curl_str(curl, CURLOPT_RANGE, "\(r.rangeFrom)-") }

        var list: UnsafeMutablePointer<curl_slist>?
        for h in headers {
            guard !h.unicodeScalars.contains(where: { $0 == "\r" || $0 == "\n" }) else {
                throw FileSystemError(.other, "Invalid characters in \(path).")
            }
            list = curl_slist_append(list, h)
        }
        defer { curl_slist_free_all(list) }
        if list != nil { macscp_curl_ptr(curl, CURLOPT_HTTPHEADER, list) }

        let sink = Sink()
        sink.file = r.downloadTo
        sink.input = r.uploadFile
        sink.inputData = r.uploadFile == nil ? r.body : nil
        sink.progress = r.progress
        sink.total = r.progressStart
        sink.progressStart = r.progressStart
        sink.inputStart = (try? r.uploadFile?.offset()) ?? 0
        let ptr = Unmanaged.passRetained(sink).toOpaque()
        defer { Unmanaged<Sink>.fromOpaque(ptr).release() }
        macscp_curl_write_cb(curl, Self.writeCB, ptr)
        macscp_curl_read_cb(curl, Self.readCB, ptr)
        macscp_curl_seek_cb(curl, Self.seekCB, ptr)
        macscp_curl_ptr(curl, CURLOPT_HEADERFUNCTION, unsafeBitCast(Self.headerCB, to: UnsafeMutableRawPointer.self))
        macscp_curl_ptr(curl, CURLOPT_HEADERDATA, ptr)

        let rc = curl_easy_perform(curl)
        if let e = sink.error { throw e }
        guard rc == CURLE_OK else {
            let detail = errorBuffer[0] != 0 ? String(cString: errorBuffer) : String(cString: curl_easy_strerror(rc))
            switch rc {
            case CURLE_ABORTED_BY_CALLBACK, CURLE_WRITE_ERROR where r.progress != nil: throw FileSystemError.cancelled
            case CURLE_COULDNT_RESOLVE_HOST: throw FileSystemError(.connection, "Host \"\(site.hostName)\" does not exist.")
            case CURLE_COULDNT_RESOLVE_PROXY: throw FileSystemError(.connection, "Proxy host \"\(site.proxy.host)\" does not exist.")
            case CURLE_SSL_PINNEDPUBKEYNOTMATCH:
                throw FileSystemError(.hostKey, "The server's certificate has CHANGED since you accepted it. This could be an attack.")
            case CURLE_PEER_FAILED_VERIFICATION, CURLE_SSL_CACERT_BADFILE:
                throw FileSystemError(.hostKey, "The server's TLS certificate is not trusted: \(detail)")
            default: throw FileSystemError(.connection, "\(what) \(path) failed: \(detail)")
            }
        }
        var status = 0
        macscp_curl_info_long(curl, CURLINFO_RESPONSE_CODE, &status)
        return Response(status: status, headers: sink.headers, body: sink.data)
    }

    /// Maps HTTP error statuses to file system errors.
    static func check(_ r: Response, _ what: String, _ path: String, ok: Set<Int> = []) throws {
        if (200..<300).contains(r.status) || ok.contains(r.status) { return }
        let detail = String(decoding: r.body.prefix(300), as: UTF8.self)
        switch r.status {
        case 401: throw FileSystemError(.authentication, "Access denied.")
        case 403: throw FileSystemError(.permissionDenied, "Permission denied: \(path)")
        case 404: throw FileSystemError(.notFound, "No such file or directory: \(path)")
        case 405, 409, 412: throw FileSystemError(.exists, "\(what) \(path) failed (HTTP \(r.status)).")
        case 507: throw FileSystemError(.other, "\(what) \(path) failed: insufficient storage.")
        default: throw FileSystemError(.other, "\(what) \(path) failed (HTTP \(r.status)) \(detail)")
        }
    }

    /// Fetches the server certificate without credentials and without trusting it.
    func probeCertificate() -> Data? {
        curl_easy_reset(curl)
        macscp_curl_str(curl, CURLOPT_URL, baseURL + "/")
        macscp_curl_long(curl, CURLOPT_CONNECTTIMEOUT, Int(settings.timeout))
        macscp_curl_long(curl, CURLOPT_SSL_VERIFYPEER, 0)
        macscp_curl_long(curl, CURLOPT_SSL_VERIFYHOST, 0)
        macscp_curl_long(curl, CURLOPT_CERTINFO, 1)
        macscp_curl_long(curl, CURLOPT_NOBODY, 1)
        if let proxy = site.proxy.curlURL { macscp_curl_str(curl, CURLOPT_PROXY, proxy) }
        _ = curl_easy_perform(curl)
        var buf = [CChar](repeating: 0, count: 256 * 1024)
        guard macscp_curl_first_cert(curl, &buf, buf.count) > 0 else { return nil }
        return Certificate.firstDER(fromPEM: String(cString: buf))
    }

    /// Runs `attempt` with system trust, falling back to the user-confirmed pin flow
    /// shared with FTPS (anonymous probe → fingerprint prompt → pinned public key).
    func establishTrust<T>(prompter: ConnectionPrompter, hostKeys: HostKeyStore?, attempt: () throws -> T) throws -> T {
        guard isTLS else { return try attempt() }
        pin = hostKeys?.certificate(host: site.hostName, port: site.port).flatMap(Certificate.pin)
        do {
            return try attempt()
        } catch let e as FileSystemError where e.code == .hostKey {
            guard let der = probeCertificate(), let newPin = Certificate.pin(der) else {
                throw FileSystemError(.hostKey, "\(e.message) (the certificate could not be read)")
            }
            switch prompter.verifyCertificate(host: site.hostName, port: site.port, fingerprint: Certificate.fingerprint(der),
                                              problem: e.message, changed: pin != nil) {
            case .reject: throw FileSystemError(.hostKey, "Certificate was not accepted.")
            case .acceptAndSave: try? hostKeys?.save(host: site.hostName, port: site.port, key: HostKey(type: "x509", blob: der))
            case .acceptOnce: break
            }
            pin = newPin
            return try attempt()
        }
    }
}
