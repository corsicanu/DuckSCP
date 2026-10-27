import Foundation

/// Opens the right file system for a site.
public enum Connector {
    public static func connect(site: Site, password: String?, prompter: ConnectionPrompter,
                               hostKeys: HostKeyStore, settings: ConnectionSettings = .init()) throws -> RemoteFileSystem {
        settings.log?.write("[\(site.displayTarget)] Connecting with \(site.fileProtocol.title) to port \(site.port)")
        var fs: RemoteFileSystem
        do {
            fs = try open(site: site, password: password, prompter: prompter, hostKeys: hostKeys, settings: settings)
        } catch {
            settings.log?.write("[\(site.displayTarget)] ! Connection failed: \(error)")
            throw error
        }
        settings.log?.write("[\(site.displayTarget)] Connected (\(fs.protocolName))")
        if site.timeOffsetHours != 0 { fs = TimeShiftFileSystem(fs, hours: site.timeOffsetHours) }
        if let log = settings.log { fs = LoggingFileSystem(fs, log: log, tag: site.displayTarget) }
        return fs
    }

    private static func open(site: Site, password: String?, prompter: ConnectionPrompter,
                             hostKeys: HostKeyStore, settings: ConnectionSettings) throws -> RemoteFileSystem {
        switch site.fileProtocol {
        case .sftp:
            let conn = try SSHConnection.open(site: site, password: password, prompter: prompter, hostKeys: hostKeys, settings: settings)
            prompter.status("Starting the session...")
            do {
                return try SFTPFileSystem(connection: conn)
            } catch {
                guard site.allowScpFallback else { conn.close(); throw error }
                prompter.status("SFTP not available, falling back to SCP...")
                return SCPFileSystem(connection: conn)
            }
        case .scp:
            let conn = try SSHConnection.open(site: site, password: password, prompter: prompter, hostKeys: hostKeys, settings: settings)
            return SCPFileSystem(connection: conn)
        case .ftp:
            return try FTPFileSystem.connect(site: site, password: password, prompter: prompter, settings: settings, hostKeys: hostKeys)
        case .webdav:
            return try WebDAVFileSystem.connect(site: site, password: password, prompter: prompter, settings: settings, hostKeys: hostKeys)
        case .s3:
            return try S3FileSystem.connect(site: site, password: password, prompter: prompter, settings: settings, hostKeys: hostKeys)
        }
    }
}
