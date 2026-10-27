import AppKit

enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()
        let name = Branding.appName

        let appMenu = NSMenu()
        appMenu.add("About \(name)", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), "")
        appMenu.addItem(.separator())
        appMenu.add("Hide \(name)", #selector(NSApplication.hide(_:)), "h")
        appMenu.add("Quit \(name)", #selector(NSApplication.terminate(_:)), "q")
        main.addItem(submenu: appMenu, title: name)

        let session = NSMenu(title: "Session")
        session.add("New Session…", #selector(AppDelegate.showLogin), "n")
        main.addItem(submenu: session, title: "Session")

        let edit = NSMenu(title: "Edit")
        edit.add("Cut", #selector(NSText.cut(_:)), "x")
        edit.add("Copy", #selector(NSText.copy(_:)), "c")
        edit.add("Paste", #selector(NSText.paste(_:)), "v")
        edit.add("Select All", #selector(NSText.selectAll(_:)), "a")
        main.addItem(submenu: edit, title: "Edit")

        let window = NSMenu(title: "Window")
        window.add("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        window.add("Close", #selector(NSWindow.performClose(_:)), "w")
        main.addItem(submenu: window, title: "Window")
        NSApp.windowsMenu = window
        return main
    }
}

extension NSMenu {
    func addItem(submenu: NSMenu, title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
    }
}
