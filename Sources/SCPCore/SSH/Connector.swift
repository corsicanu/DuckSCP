import Foundation

/// Opens the right file system for a site.
public enum Connector {
    public static func connect(site: Site, password: String?, prompter: ConnectionPrompter,
                               hostKeys: HostKeyStore) throws -> RemoteFileSystem {
        switch site.fileProtocol {
        case .sftp:
            let conn = try SSHConnection.open(site: site, password: password, prompter: prompter, hostKeys: hostKeys)
            prompter.status("Starting the session...")
            do {
                return try SFTPFileSystem(connection: conn)
            } catch {
                guard site.allowScpFallback else { conn.close(); throw error }
                prompter.status("SFTP not available, falling back to SCP...")
                return SCPFileSystem(connection: conn)
            }
        case .scp:
            let conn = try SSHConnection.open(site: site, password: password, prompter: prompter, hostKeys: hostKeys)
            return SCPFileSystem(connection: conn)
        case .ftp:
            return try FTPFileSystem.connect(site: site, password: password, prompter: prompter)
        case .webdav, .s3:
            throw FileSystemError(.unsupported, "\(site.fileProtocol.title) is not supported yet.")
        }
    }
}
