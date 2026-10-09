#if MOCHI_DEVELOPMENT
import AppKit

/// Explicitly enabled only in the remote, isolated development test process.
@MainActor final class SingleInstanceE2E {
    private var observer: NSObjectProtocol?
    func attach(_ window: NSWindow, tray: TrayController) {
        guard observer == nil, let scope = ProcessInfo.processInfo.environment["MOCHI_INSTANCE_EVENTS_DIR"] else { return }
        observer = DistributedNotificationCenter.default().addObserver(forName:Notification.Name("mochi.e2e.command"),object:scope,queue:.main) { [weak window,weak tray] notification in
            MainActor.assumeIsolated {
                guard let window, let tray else { return }
                let command = notification.userInfo?["command"] as? String
                switch command {
                case "hide": tray.closeToTray()
                case "minimize": window.miniaturize(nil)
                case "quit": tray.quitApp(); return
                default: break
                }
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds:200_000_000)
                    let state: [String:Any] = ["pid":getpid(),"time":Date().timeIntervalSince1970,"visible":window.isVisible,"miniaturized":window.isMiniaturized,"hidden":NSApp.isHidden,"active":NSApp.isActive,"key":window.isKeyWindow,"dock":NSApp.activationPolicy() == .regular,"tray":tray.statusItem != nil]
                    if let data = try? JSONSerialization.data(withJSONObject:state,options:.sortedKeys) {
                        try? data.write(to:URL(fileURLWithPath:scope).appendingPathComponent("workspace-\(getpid()).json"),options:.atomic)
                    }
                }
            }
        }
        InstanceEvidence.record("workspace-attached")
    }
    deinit { if let observer { DistributedNotificationCenter.default().removeObserver(observer) } }
}
#endif
