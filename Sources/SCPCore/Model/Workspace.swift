import Foundation

/// A saved set of sessions opened together (WinSCP workspace). Each entry is a full
/// copy of the site settings, like WinSCP stores them; passwords live in the Keychain.
public struct Workspace: Codable, Equatable, Identifiable {
    public var id = UUID()
    public var name: String
    public var sites: [Site]

    public init(name: String, sites: [Site]) {
        self.name = name
        self.sites = sites
    }
}
