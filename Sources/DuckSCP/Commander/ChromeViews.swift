// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SCPCore

// Small custom views for the Commander window ("classic, refined" look).
// Everything coloured uses Theme.accent and repaints on Theme.didChange.

/// Base for views that repaint when the accent or appearance changes.
class ThemedView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged), name: Theme.didChange, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc func themeChanged() { needsDisplay = true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

// MARK: - Tabs

/// Session tabs: rounded-top tabs that merge into the content below, a colour swatch
/// per site (WinSCP site colour), and a trailing "+" for a new session.
final class SessionTabStrip: ThemedView {
    struct Tab { var title: String; var color: NSColor?; var tooltip: String }

    var tabs: [Tab] = [] { didSet { rebuild() } }
    var selected = 0 { didSet { rebuild() } }
    var onSelect: ((Int) -> Void)?
    var onNew: (() -> Void)?
    var onClose: ((Int) -> Void)?
    private let stack = NSStackView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.alignment = .bottom
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    private func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, t) in tabs.enumerated() {
            let v = TabView(tab: t, active: i == selected)
            v.onClick = { [weak self] in self?.onSelect?(i) }
            v.onClose = { [weak self] in self?.onClose?(i) }
            stack.addArrangedSubview(v)
        }
        let plus = TabView(tab: Tab(title: "", color: nil, tooltip: "New session"), active: false, isPlus: true)
        plus.onClick = { [weak self] in self?.onNew?() }
        stack.addArrangedSubview(plus)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }

    private final class TabView: ThemedView {
        var onClick: (() -> Void)?
        var onClose: (() -> Void)?
        private let tab: Tab
        private let active: Bool
        private let isPlus: Bool
        private var hovering = false
        private let glyph = NSImageView()

        init(tab: Tab, active: Bool, isPlus: Bool = false) {
            self.tab = tab
            self.active = active
            self.isPlus = isPlus
            super.init(frame: .zero)
            toolTip = tab.tooltip
            translatesAutoresizingMaskIntoConstraints = false
            let width = isPlus ? 30 : min(220, max(110, (tab.title as NSString).size(withAttributes: [.font: Self.font(active)]).width + 46))
            widthAnchor.constraint(equalToConstant: width).isActive = true
            heightAnchor.constraint(equalToConstant: 26).isActive = true
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
            // Glyphs as image views: AppKit renders (and snapshots) these reliably.
            glyph.image = NSImage(systemSymbolName: isPlus ? "plus" : "xmark", accessibilityDescription: isPlus ? "New session" : "Close")
            glyph.symbolConfiguration = .init(pointSize: isPlus ? 11 : 8, weight: .semibold)
            glyph.contentTintColor = isPlus ? .secondaryLabelColor : .tertiaryLabelColor
            glyph.translatesAutoresizingMaskIntoConstraints = false
            glyph.isHidden = !(isPlus || active)
            addSubview(glyph)
            NSLayoutConstraint.activate([
                glyph.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -1),
                isPlus ? glyph.centerXAnchor.constraint(equalTo: centerXAnchor) : glyph.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            ])
            setAccessibilityRole(.radioButton)
            setAccessibilityLabel(isPlus ? "New session" : tab.title)
        }

        required init?(coder: NSCoder) { fatalError() }

        static func font(_ active: Bool) -> NSFont { .systemFont(ofSize: 12, weight: active ? .semibold : .regular) }

        override func draw(_ dirtyRect: NSRect) {
            let r = bounds.insetBy(dx: 0.5, dy: 0).offsetBy(dx: 0, dy: -1)
            let path = NSBezierPath(roundedRect: NSRect(x: r.minX, y: r.minY, width: r.width, height: r.height + 8), xRadius: 7, yRadius: 7)
            if active {
                NSColor.controlBackgroundColor.setFill()
                path.fill()
                NSColor.separatorColor.setStroke()
                path.lineWidth = 0.5
                path.stroke()
                // Merge with the panels below.
                NSColor.controlBackgroundColor.setFill()
                NSRect(x: r.minX + 0.5, y: 0, width: r.width - 1, height: 2).fill()
            } else if hovering {
                NSColor.labelColor.withAlphaComponent(0.06).setFill()
                path.fill()
            }
            if isPlus { return }
            var x: CGFloat = 12
            let swatch = NSRect(x: x, y: (bounds.height - 8) / 2 - 1, width: 8, height: 8)
            (tab.color ?? NSColor.tertiaryLabelColor).setFill()
            NSBezierPath(roundedRect: swatch, xRadius: 2, yRadius: 2).fill()
            x += 16
            let attrs: [NSAttributedString.Key: Any] = [.font: Self.font(active),
                                                        .foregroundColor: active ? NSColor.labelColor : NSColor.secondaryLabelColor]
            let title = tab.title as NSString
            let size = title.size(withAttributes: attrs)
            title.draw(with: NSRect(x: x, y: (bounds.height - size.height) / 2 - 1, width: bounds.width - x - 22, height: size.height),
                       options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin], attributes: attrs)
        }

        private var closeRect: NSRect { NSRect(x: bounds.width - 20, y: 0, width: 16, height: bounds.height - 2) }


        override func mouseEntered(with event: NSEvent) { hovering = true; glyph.isHidden = false; needsDisplay = true }
        override func mouseExited(with event: NSEvent) { hovering = false; glyph.isHidden = !(isPlus || active); needsDisplay = true }

        override func mouseUp(with event: NSEvent) {
            let p = convert(event.locationInWindow, from: nil)
            if !isPlus, closeRect.contains(p) { onClose?() } else { onClick?() }
        }
    }
}

// MARK: - Breadcrumb path bar

/// "/ var / www / html" in a rounded field; every component is clickable, the current
/// folder is bold, and the home folder shows as "~" on the local side.
final class BreadcrumbBar: ThemedView {
    var onNavigate: ((String) -> Void)?
    var onEdit: (() -> Void)?
    private let stack = NSStackView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 24),
        ])
        setAccessibilityRole(.group)
        setAccessibilityLabel("Path")
    }

    required init?(coder: NSCoder) { fatalError() }

    /// - Parameter home: shown as "~" when `path` is inside it (local panel).
    func show(path: String, home: String?) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        var crumbs: [(String, String)] = []
        var rest = path
        if let home, path == home || path.hasPrefix(home + "/") {
            crumbs.append(("~", home))
            rest = String(path.dropFirst(home.count))
        } else {
            crumbs.append(("/", "/"))
        }
        var acc = crumbs[0].1 == "/" ? "" : crumbs[0].1
        for part in rest.split(separator: "/") {
            acc += "/" + part
            crumbs.append((String(part), acc))
        }
        for (i, c) in crumbs.enumerated() {
            // "/ var / www": the root crumb is itself the first slash.
            if i > 1 || (i == 1 && crumbs[0].0 == "~") { stack.addArrangedSubview(separator()) }
            let last = i == crumbs.count - 1
            let b = NSButton(title: c.0, target: self, action: #selector(clicked(_:)))
            b.isBordered = false
            b.font = .systemFont(ofSize: 12, weight: last ? .semibold : .regular)
            b.contentTintColor = last ? .labelColor : .secondaryLabelColor
            b.identifier = NSUserInterfaceItemIdentifier(c.1)
            b.toolTip = c.1
            b.lineBreakMode = .byTruncatingMiddle
            b.setContentCompressionResistancePriority(last ? .defaultHigh : .defaultLow, for: .horizontal)
            stack.addArrangedSubview(b)
        }
        toolTip = path
    }

    private func separator() -> NSTextField {
        let l = NSTextField(labelWithString: "/")
        l.textColor = .tertiaryLabelColor
        l.font = .systemFont(ofSize: 12)
        return l
    }

    @objc private func clicked(_ sender: NSButton) {
        if let p = sender.identifier?.rawValue { onNavigate?(p) }
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onEdit?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.05).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }
}

// MARK: - Table rows

/// Selection drawn in the app accent: solid in the active panel, a soft tint otherwise.
final class AccentRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        (emphasizedLook ? Theme.accent : Theme.accentSoft).setFill()
        bounds.fill()
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle {
        isSelected && emphasizedLook ? .emphasized : .normal
    }

    /// Solid accent for the active panel of the key window (also during screenshots).
    private var emphasizedLook: Bool {
        guard let panel = (superview as? PanelTableView)?.panel else { return isEmphasized }
        return panel.isActive && (window?.isKeyWindow ?? false)
    }
}

/// Thin accent bar along the left edge of the active panel.
final class AccentEdge: ThemedView {
    override func draw(_ dirtyRect: NSRect) {
        Theme.accent.setFill()
        bounds.fill()
    }
}

// MARK: - Colour swatch

/// Rounded colour swatch; click opens the shared NSColorPanel bound to it.
final class ColorSwatchButton: NSButton {
    var color: NSColor = .systemBlue { didSet { needsDisplay = true } }
    var onChange: ((NSColor) -> Void)?

    convenience init() {
        self.init(frame: NSRect(x: 0, y: 0, width: 44, height: 24))
        isBordered = false
        title = ""
        target = self
        action = #selector(openPanel)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 44).isActive = true
        heightAnchor.constraint(equalToConstant: 24).isActive = true
        setAccessibilityLabel("Custom accent color")
        toolTip = "Choose a custom accent color"
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
        color.setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    @objc private func openPanel() {
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.color = color
        panel.setTarget(self)
        panel.setAction(#selector(panelChanged(_:)))
        panel.orderFront(nil)
    }

    @objc private func panelChanged(_ sender: NSColorPanel) {
        color = sender.color
        onChange?(sender.color)
    }
}

// MARK: - Progress

/// Rounded progress track filled with the accent (NSProgressIndicator cannot be tinted).
final class TransferBar: ThemedView {
    var fraction: Double = 0 { didSet { needsDisplay = true } }
    var color: NSColor?

    override var intrinsicContentSize: NSSize { NSSize(width: 150, height: 5) }

    override func draw(_ dirtyRect: NSRect) {
        let r = NSRect(x: 0, y: (bounds.height - 5) / 2, width: bounds.width, height: 5)
        NSColor.labelColor.withAlphaComponent(0.1).setFill()
        NSBezierPath(roundedRect: r, xRadius: 2.5, yRadius: 2.5).fill()
        guard fraction > 0 else { return }
        (color ?? Theme.accent).setFill()
        NSBezierPath(roundedRect: NSRect(x: r.minX, y: r.minY, width: max(5, r.width * min(1, fraction)), height: 5),
                     xRadius: 2.5, yRadius: 2.5).fill()
    }
}

// MARK: - Bottom bars

/// "F5 Copy": a keycap plus a label, as one button.
final class KeycapButton: NSButton {
    convenience init(key: String, title: String, target: AnyObject?, action: Selector?) {
        self.init(frame: .zero)
        self.target = target
        self.action = action
        isBordered = false
        let attr = NSMutableAttributedString()
        attr.append(NSAttributedString(attachment: Self.keycap(key)))
        attr.append(NSAttributedString(string: " " + title, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor,
                                                                           .baselineOffset: 1]))
        attributedTitle = attr
        setAccessibilityLabel("\(title) (\(key))")
        toolTip = "\(title) (\(key), or fn-\(key) on a Mac keyboard)"
    }

    private static func keycap(_ key: String) -> NSTextAttachment {
        let font = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
        let size = (key as NSString).size(withAttributes: [.font: font])
        let w = size.width + 10, h: CGFloat = 17
        let img = NSImage(size: NSSize(width: w, height: h), flipped: false) { r in
            let body = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 1), xRadius: 4, yRadius: 4)
            NSColor.controlBackgroundColor.setFill()
            body.fill()
            NSColor.separatorColor.setStroke()
            body.lineWidth = 1
            body.stroke()
            (key as NSString).draw(at: NSPoint(x: 5, y: (h - size.height) / 2), withAttributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
            return true
        }
        let a = NSTextAttachment()
        a.image = img
        a.bounds = NSRect(x: 0, y: -4, width: w, height: h)
        return a
    }
}

/// Capsule label in the status bar: green with a lock for encrypted connections,
/// orange with an open lock for plain FTP/HTTP.
final class StatusPill: ThemedView {
    var text = "" { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    var secure = true { didSet { needsDisplay = true } }
    private let font = NSFont.systemFont(ofSize: 11, weight: .medium)
    private let lock = NSImageView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        lock.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
        lock.translatesAutoresizingMaskIntoConstraints = false
        addSubview(lock)
        NSLayoutConstraint.activate([
            lock.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            lock.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: text.isEmpty ? 0 : (text as NSString).size(withAttributes: [.font: font]).width + 30, height: 18)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !text.isEmpty else { return }
        let color: NSColor = secure ? .systemGreen : .systemOrange
        color.withAlphaComponent(0.15).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        lock.image = NSImage(systemSymbolName: secure ? "lock.fill" : "lock.open.fill", accessibilityDescription: secure ? "Encrypted" : "Not encrypted")
        lock.contentTintColor = color
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color.blended(withFraction: 0.35, of: .labelColor) ?? color]
        let size = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: NSPoint(x: 21, y: (bounds.height - size.height) / 2), withAttributes: attrs)
    }
}

extension Format {
    /// Finder-style dates: "Today 09:30", "Yesterday 18:40", otherwise "12 Oct 2026".
    static func shortDate(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today " + timeFormatter.string(from: d) }
        if cal.isDateInYesterday(d) { return "Yesterday " + timeFormatter.string(from: d) }
        return dayFormatter.string(from: d)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("d MMM yyyy")
        return f
    }()
}
