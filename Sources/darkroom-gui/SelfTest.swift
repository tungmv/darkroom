import AppKit
import DarkroomKit

/// `--self-test` mode: build the real panel offscreen, drive the slider the way
/// a user would, and assert the daemon reports back the same strength. Used by
/// `make check-gui` so the whole GUI→daemon→gamma path is verifiable without a
/// human looking at a screen.
@MainActor
enum SelfTest {
    static func run() -> Int32 {
        var failures = 0

        func check(_ condition: Bool, _ label: String, _ detail: String = "") {
            if condition {
                print("  ok   \(label)")
            } else {
                failures += 1
                print("  FAIL \(label)\(detail.isEmpty ? "" : ": \(detail)")")
            }
        }

        print("GUI self-test")

        let hasDisplays = !getActiveDisplayIDs().isEmpty
        if !hasDisplays {
            print("  note no active display (screen asleep or session locked):")
            print("       gamma cannot be verified, checking the daemon path only")
        }

        let panel = DarkroomPanel()
        panel.loadView()
        _ = panel.view  // force the view tree so constraints run

        let original: Double? = {
            guard case .success(let value) = DaemonSocket.send(.get) else { return nil }
            return DarkroomClient.parseIntensityResponse(value)
        }()

        for percent in [25, 60, 100, 0] {
            panel.setIntensity(Double(percent) / 100)
            waitForIdle(panel)

            let reported = DarkroomClient.currentIntensity()
            check(
                DarkroomIntensity.percent(from: reported) == percent,
                "slider \(percent)% reaches the daemon",
                "daemon says \(DarkroomIntensity.percent(from: reported))%"
            )
            check(
                DarkroomIntensity.percent(from: panel.intensity) == percent,
                "panel state tracks \(percent)%",
                "panel says \(DarkroomIntensity.percent(from: panel.intensity))%"
            )
        }

        // Toggling off and back on must restore the last used strength.
        panel.setIntensity(0.55)
        waitForIdle(panel)
        panel.setIntensity(0)
        waitForIdle(panel)
        check(
            DarkroomIntensity.percent(from: DarkroomClient.currentIntensity()) == 0,
            "turning off clears the tint"
        )
        panel.setIntensity(DarkroomSettings.loadIntensityOrDefault())
        waitForIdle(panel)
        check(
            DarkroomIntensity.percent(from: panel.intensity) == 55,
            "re-enabling restores the last strength",
            "panel says \(DarkroomIntensity.percent(from: panel.intensity))%"
        )

        // The error row must not change the popover height, or the panel would
        // clip when a failure is reported.
        let heightBefore = panel.panelHeight
        panel.showErrorForTesting("daemon unavailable")
        let heightAfter = panel.panelHeight
        check(
            abs(heightBefore - heightAfter) < 0.5,
            "error row does not resize the panel",
            "\(heightBefore) -> \(heightAfter)"
        )

        panel.setIntensity(0)
        waitForIdle(panel)

        // A display read-back should agree with what the panel last applied.
        if hasDisplays {
            let measured = DarkroomIntensity.percent(
                from: currentDarkroomIntensity(for: getActiveDisplayIDs()))
            check(measured == 0, "gamma is normal after the 0% step", "measured \(measured)%")
        }

        // Restore whatever was active before the test.
        if let original {
            _ = DarkroomClient.setIntensity(original)
        }

        // Optional: dump the panel as a PNG so the layout can be eyeballed
        // without a live screen (useful on locked/headless sessions).
        if let index = CommandLine.arguments.firstIndex(of: "--snapshot"),
           index + 1 < CommandLine.arguments.count {
            let path = CommandLine.arguments[index + 1]
            panel.setIntensity(Double(
                CommandLine.arguments.first(where: { $0.hasPrefix("--at=") })
                    .map { Double($0.dropFirst(5)) ?? 60 } ?? 60) / 100)
            waitForIdle(panel)
            if snapshot(panel.view, to: path) {
                print("  wrote \(path)")
            } else {
                failures += 1
                print("  FAIL could not write \(path)")
            }
        }

        print(failures == 0 ? "self-test passed" : "self-test failed (\(failures))")
        return failures == 0 ? 0 : 1
    }

    /// Render a view (and its subviews) into a PNG for visual inspection.
    private static func snapshot(_ view: NSView, to path: String) -> Bool {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return false
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            return false
        }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }

    /// Spin the run loop until the controller has no queued or in-flight work.
    private static func waitForIdle(_ panel: DarkroomPanel, timeout: TimeInterval = 3) {
        let deadline = Date().addingTimeInterval(timeout)
        while panel.isApplying, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        // One extra turn so the finished request's completion lands.
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
}
