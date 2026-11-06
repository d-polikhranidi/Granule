import AppKit

// Clickhouse Viewer for the Mac: ClickHouse results of any size, without
// nibs. A window of saved connections, a window of queries for each one;
// the menu bar's commands reach the window in front through the responder chain.

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
