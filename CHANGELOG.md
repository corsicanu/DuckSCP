# Changelog

## 1.0.2 (2026-10-28)

- **No more Keychain prompts after updates:** releases are signed with a stable certificate, so macOS treats each version as the same app. Updating from 1.0.0/1.0.1 asks one last time (Always Allow).
- **Updates must come from the same signer:** the built-in updater refuses packages signed by a different certificate.
- **Sites reopen where you left them:** the last remote and local folders are remembered per site, on by default (Advanced → Remember last used directory).
- **Import warnings clear:** the ⚠︎ disappears after a successful connection, on Save, or via Manage → Clear Warnings.

Release notes: [docs/releases/v1.0.2.md](docs/releases/v1.0.2.md).

## 1.0.1 (2026-10-28)

- **Drop prompt with history:** dropping files (from Finder or the other panel) asks where to put them, like WinSCP. It suggests the folder you dropped on, plus a global history of recent target folders. F5/F6 use the same dialog.
- **Update checker:** checks GitHub Releases at launch and from the app menu. Pre-releases are offered with a warning. **Update** verifies the package (checksum, signature, bundle id, version) and replaces the app in place.
- **Finder-style rename:** click a selected name again to rename it in place. F2 does the same.

Release notes: [docs/releases/v1.0.1.md](docs/releases/v1.0.1.md).

## 1.0.0 (2026-10-27)

First public release. See [docs/releases/v1.0.0.md](docs/releases/v1.0.0.md) for the release notes and checksums.
