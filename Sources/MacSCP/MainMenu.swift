import AppKit

enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()
        let name = Branding.appName

        let appMenu = NSMenu()
        appMenu.add("About \(name)", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), "")
        appMenu.addItem(.separator())
        appMenu.add("Preferences…", #selector(AppDelegate.showPreferences), ",")
        appMenu.addItem(.separator())
        appMenu.add("Hide \(name)", #selector(NSApplication.hide(_:)), "h")
        appMenu.add("Quit \(name)", #selector(NSApplication.terminate(_:)), "q")
        main.addItem(submenu: appMenu, title: name)

        let session = NSMenu(title: "Session")
        session.add("New Session…", #selector(AppDelegate.showLogin), "n")
        session.add("Disconnect", #selector(CommanderWindowController.disconnect), "")
        session.add("Refresh", #selector(CommanderWindowController.refreshAll), "r")
        main.addItem(submenu: session, title: "Session")

        let files = NSMenu(title: "Files")
        let fkeys: [(String, Int, Int)] = [
            ("Rename", 2, NSF2FunctionKey), ("Edit", 4, NSF4FunctionKey), ("Copy…", 5, NSF5FunctionKey),
            ("Move…", 6, NSF6FunctionKey), ("Create Directory…", 7, NSF7FunctionKey), ("Delete", 8, NSF8FunctionKey),
            ("Properties", 9, NSF9FunctionKey),
        ]
        for (title, tag, key) in fkeys {
            let item = files.add(title, #selector(AppDelegate.filesCommand(_:)), String(Character(UnicodeScalar(key)!)), modifiers: [])
            item.tag = tag
        }
        main.addItem(submenu: files, title: "Files")

        let view = NSMenu(title: "View")
        view.add("Show Hidden Files", #selector(AppDelegate.toggleHiddenFiles), ".", modifiers: [.command, .shift])
        main.addItem(submenu: view, title: "View")

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
