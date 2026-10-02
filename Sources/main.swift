import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    let barController = MenuBarController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        barController.install()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // 退出前把风扇恢复为系统自动模式
        FanController.shared.shutdown()
        return .terminateNow
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
