// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

func label(_ text: String) -> NSTextField {
    let l = NSTextField(labelWithString: text)
    l.translatesAutoresizingMaskIntoConstraints = false
    return l
}

func button(_ title: String, _ target: AnyObject?, _ action: Selector?) -> NSButton {
    let b = NSButton(title: title, target: target, action: action)
    b.bezelStyle = .rounded
    b.translatesAutoresizingMaskIntoConstraints = false
    return b
}

func textField(_ width: CGFloat? = nil) -> NSTextField {
    let f = NSTextField()
    f.translatesAutoresizingMaskIntoConstraints = false
    if let width { f.widthAnchor.constraint(equalToConstant: width).isActive = true }
    return f
}

/// A push button that pops a menu below itself, like WinSCP's split buttons ("Tools ▾").
final class MenuButton: NSButton {
    var popupMenu = NSMenu()

    convenience init(title: String, menu: NSMenu) {
        self.init(title: title + " ▾", target: nil, action: nil)
        bezelStyle = .rounded
        translatesAutoresizingMaskIntoConstraints = false
        popupMenu = menu
        target = self
        action = #selector(showMenu)
    }

    @objc private func showMenu() {
        popupMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 4), in: self)
    }
}

extension NSMenu {
    @discardableResult
    func add(_ title: String, _ action: Selector?, _ key: String = "", target: AnyObject? = nil,
             modifiers: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = target
        addItem(item)
        return item
    }
}

/// Reports itself active while screenshots force the active appearance (see SnapshotWindow).
final class DuckApplication: NSApplication {
    override var isActive: Bool { SnapshotWindow.forceActiveAppearance || super.isActive }
}

/// Window that can draw its active (key) appearance while screenshots are taken from a
/// background process, which macOS no longer lets take focus. Off outside --snapshot.
class SnapshotWindow: NSWindow {
    static var forceActiveAppearance = false
    override var isKeyWindow: Bool { Self.forceActiveAppearance || super.isKeyWindow }
    override var isMainWindow: Bool { Self.forceActiveAppearance || super.isMainWindow }
}

extension NSWindow {
    /// Renders the content view into a PNG; used by --snapshot for headless UI checks.
    func writeSnapshot(to url: URL) {
        // PDF drawing renders controls faithfully even off screen, but skips the window
        // background, so paint that first in the window's own (light or dark) appearance.
        // The frame view includes the title bar and toolbar, not just the content.
        guard let view = contentView?.superview ?? contentView, let pdf = NSImage(data: view.dataWithPDF(inside: view.bounds)) else { return }
        let image = NSImage(size: view.bounds.size)
        image.lockFocus()
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            NSRect(origin: .zero, size: view.bounds.size).fill()
        }
        pdf.draw(in: NSRect(origin: .zero, size: view.bounds.size))
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return }
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}

func showError(_ error: Error, in window: NSWindow?) {
    let alert = NSAlert()
    alert.alertStyle = .critical
    alert.messageText = "Error"
    alert.informativeText = String(describing: error)
    if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
}
