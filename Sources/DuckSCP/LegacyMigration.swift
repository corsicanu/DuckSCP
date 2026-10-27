import Foundation
import SCPCore

/// One-time move of data from the app's previous name (Info.plist LegacyAppName /
/// LegacyBundleID): the Application Support folder, then site and proxy passwords
/// from the old Keychain service. Old Keychain items are left in place.
enum LegacyMigration {
    static func run() {
        let info = Bundle.main.infoDictionary ?? [:]
        guard let oldName = info["LegacyAppName"] as? String, !oldName.isEmpty, oldName != Branding.appName,
              let oldID = info["LegacyBundleID"] as? String, !oldID.isEmpty else { return }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let oldDir = support.appendingPathComponent(oldName), newDir = support.appendingPathComponent(Branding.appName)
        guard FileManager.default.fileExists(atPath: oldDir.path), !FileManager.default.fileExists(atPath: newDir.path) else { return }
        do { try FileManager.default.moveItem(at: oldDir, to: newDir) } catch { return }

        let store = SiteStore(fileURL: newDir.appendingPathComponent("sites.json"), secrets: InMemorySecretStore())
        let oldKeys = KeychainSecretStore(service: oldID + ".sites")
        let newKeys = KeychainSecretStore(service: Branding.bundleID + ".sites")
        let ids = (store.sites + store.workspaces.flatMap(\.sites)).flatMap { [$0.id, $0.proxy.secretID] }
        for id in ids {
            if let pw = oldKeys.password(for: id) { try? newKeys.setPassword(pw, for: id) }
        }
    }
}
