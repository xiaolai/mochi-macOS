import AppKit
@MainActor final class Delegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    func save(_ event: String) {
        let root = URL(fileURLWithPath:CommandLine.arguments[1]); try? FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        try? Data("\(getpid())".utf8).write(to:root.appendingPathComponent(event),options:.atomic)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect:NSRect(x:150,y:150,width:500,height:300),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        window.title = "Mochi legacy test fixture"; window.makeKeyAndOrderFront(nil); save("ready")
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        window.makeKeyAndOrderFront(nil); save("reopened"); return false
    }
}
@main struct LegacyMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = Delegate(); app.delegate = delegate; app.setActivationPolicy(.regular); app.run()
        withExtendedLifetime(delegate) {}
    }
}
