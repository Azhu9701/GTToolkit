import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    let barController = MenuBarController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        barController.install()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
