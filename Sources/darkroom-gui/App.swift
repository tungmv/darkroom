import AppKit
import DarkroomKit

@main
struct DarkroomApp {
    static func main() {
        // `--headless` exists so `make app` smoke tests and CI can verify that
        // the binary starts and can talk to the daemon without opening a UI.
        if CommandLine.arguments.contains("--headless") {
            let intensity = DarkroomClient.currentIntensity()
            print("intensity \(DarkroomIntensity.percent(from: intensity))")
            return
        }

        if CommandLine.arguments.contains("--self-test") {
            exit(SelfTest.run())
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)  // menu bar only, no Dock icon

        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusBar = StatusBarController()
        // Start the daemon lazily but eagerly enough that the first slider drag
        // has nothing to wait for.
        DispatchQueue.global(qos: .utility).async {
            _ = DarkroomClient.ensureDaemon()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Gamma must not outlive the app that set it: leaving an invisible red
        // screen behind with no menu bar icon is the worst failure mode. The
        // remembered strength stays in ~/.darkroom/intensity, so relaunching
        // and dragging the slider back restores it. Short timeout because quit
        // must not hang; if there is no daemon there is nothing to undo anyway.
        _ = DaemonSocket.send(.off, timeout: 0.5)
    }

    /// Single instance: opening Darkroom.app again just pops the panel.
    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        statusBar?.showPanel()
        return true
    }
}
