// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

let app = DuckApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
