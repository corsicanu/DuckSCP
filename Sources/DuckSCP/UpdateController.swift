// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SCPCore

/// Checks the GitHub repository from branding.env (Info.plist DuckUpdateRepo) for a newer
/// release, at launch and from the app menu, and updates the app in place on request.
final class UpdateController {
    static let shared = UpdateController()
    private var busy = false
    private var progress: ProgressSheet?

    private var repo: String? {
        (Bundle.main.object(forInfoDictionaryKey: "DuckUpdateRepo") as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// `--update-api <url>` points the checker at a test server (development only).
    private var apiBase: URL {
        if let i = CommandLine.arguments.firstIndex(of: "--update-api"), i + 1 < CommandLine.arguments.count,
           let u = URL(string: CommandLine.arguments[i + 1]) { return u }
        return URL(string: "https://api.github.com")!
    }

    private var current: SemVer { SemVer(Branding.version) ?? SemVer("0.0.0")! }

    private var arch: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    /// - Parameter userInitiated: menu item: also says "up to date" and shows errors.
    ///   At launch only a newer version produces a dialog.
    func check(userInitiated: Bool) {
        guard !busy, let repo else {
            if userInitiated && repo == nil { info("Updates are not configured for this build.", "") }
            return
        }
        busy = true
        Task {
            let result: Result<[Updater.Release], Error> = await Task.detached { [apiBase] in
                do { return .success(try await Updater.fetchReleases(repo: repo, apiBase: apiBase)) } catch { return .failure(error) }
            }.value
            await MainActor.run {
                busy = false
                switch result {
                case .failure(let e):
                    if userInitiated { info("Could not check for updates", String(describing: e)) }
                case .success(let releases):
                    if let r = Updater.newest(in: releases, newerThan: current) {
                        offer(r)
                    } else if userInitiated {
                        info("You're up to date", "\(Branding.appName) \(current) is the newest version.")
                    }
                }
            }
        }
    }

    private func info(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        present(a) { _ in }
    }

    /// As a sheet on the front window when there is one (keeps the app responsive).
    private func present(_ a: NSAlert, _ done: @escaping (NSApplication.ModalResponse) -> Void) {
        if let w = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.sheetParent == nil }) {
            a.beginSheetModal(for: w, completionHandler: done)
        } else {
            done(a.runModal())
        }
    }

    private func offer(_ r: Updater.Release) {
        let a = NSAlert()
        let version = r.version.map(String.init(describing:)) ?? r.tagName
        if r.prerelease {
            a.messageText = "\(Branding.appName) \(version) is available (pre-release)"
            a.alertStyle = .warning
        } else {
            a.messageText = "\(Branding.appName) \(version) is available"
        }
        var text = "You have \(current)."
        if r.prerelease {
            text += "\n\nThis is a pre-release: it may contain bugs or features that are not fully tested yet."
        }
        if let notes = r.body?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
            text += "\n\n" + (notes.count > 700 ? String(notes.prefix(700)) + "…" : notes)
        }
        a.informativeText = text
        a.addButton(withTitle: "Update")
        a.addButton(withTitle: "Later")
        a.addButton(withTitle: "Release Page")
        // Test aid: --update-auto-accept clicks Update (used by the end-to-end update test).
        if CommandLine.arguments.contains("--update-auto-accept") { return install(r) }
        present(a) { [self] response in
            switch response {
            case .alertFirstButtonReturn: install(r)
            case .alertThirdButtonReturn: NSWorkspace.shared.open(r.htmlURL)
            default: break
            }
        }
    }

    /// Downloads, verifies (checksum, signature, bundle id, version), then swaps the app
    /// bundle after quitting and relaunches. Falls back to the release page if the app
    /// cannot replace itself (read-only location, running from the disk image).
    private func install(_ r: Updater.Release) {
        let sheet = ProgressSheet(title: "Downloading update")
        progress = sheet
        sheet.window?.center()
        sheet.showWindow(nil)
        let bundleID = Branding.bundleID, arch = self.arch
        Task {
            let result: Result<URL, Error> = await Task.detached {
                do { return .success(try await Updater.download(r, arch: arch, bundleID: bundleID)) } catch { return .failure(error) }
            }.value
            await MainActor.run {
                sheet.close()
                progress = nil
                switch result {
                case .failure(let e):
                    failed(e, r)
                case .success(let app):
                    do {
                        try Updater.verifySameSigner(app, as: Bundle.main.bundleURL)
                        try Updater.scheduleReplace(target: Bundle.main.bundleURL, with: app, afterExitOf: getpid(),
                                                    relaunch: !CommandLine.arguments.contains("--update-no-relaunch"))
                        NSApp.terminate(nil)
                    } catch {
                        failed(error, r)
                    }
                }
            }
        }
    }

    private func failed(_ error: Error, _ r: Updater.Release) {
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = "The update could not be installed"
        a.informativeText = String(describing: error)
        a.addButton(withTitle: "Open Release Page")
        a.addButton(withTitle: "Close")
        if a.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(r.htmlURL) }
    }
}
