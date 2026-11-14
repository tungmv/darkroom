import AppKit
import DarkroomKit

/// Status bar controller: owns the popover, the bar icon, and the global
/// hotkey that toggles darkroom mode from anywhere.
@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let panel: DarkroomPanel
    private var hotKey: HotKey?
    /// Polls the daemon so CLI changes show up in the menu bar while the app
    /// is open.
    private var pollTimer: Timer?

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        panel = DarkroomPanel()
        super.init()

        configureStatusItem()
        configurePopover()
        configureHotKey()
        observeScreenChanges()

        panel.onIntensityChanged = { [weak self] _ in
            self?.updateIcon()
        }
        updateIcon()

        // Match the icon to whatever gamma is already on screen (the daemon may
        // have been left on by the CLI).
        panel.syncFromDaemon()
        startPolling()
    }

    // MARK: - Setup

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.image = Self.icon(active: false)
        button.imagePosition = .imageOnly
        button.toolTip = "Darkroom — click to adjust intensity (⌥⌘R toggles)"
        button.action = #selector(togglePopover(_:))
        button.target = self
        button.sendAction(on: [.leftMouseUp])
    }

    private func configurePopover() {
        popover.contentViewController = panel
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
    }

    private func configureHotKey() {
        hotKey = HotKey(keyCode: 0x0F, modifiers: [.command, .option]) { [weak self] in
            Task { @MainActor in
                self?.toggleEnabled()
            }
        }
    }

    /// Light 2s poll: cheap (one small socket round trip) and keeps the icon
    /// honest when `darkroom intensity ...` runs from a terminal.
    private func startPolling() {
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                // Skip while the panel is open: the idler already refreshes on
                // close, and polling would fight an in-progress drag.
                guard let self, !self.popover.isShown else { return }
                self.panel.refreshFromDaemon()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func observeScreenChanges() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.panel.refreshDisplayCount()
                self?.updateIcon()
            }
        }
    }

    // MARK: - Actions

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    /// Open the panel from outside (e.g. reopening the app).
    func showPanel() {
        guard !popover.isShown else { return }
        togglePopover(nil)
    }

    private func toggleEnabled() {
        let current = panel.intensity
        let target = current > 0
            ? 0
            : max(DarkroomSettings.loadIntensityOrDefault(), 0.1)
        panel.setIntensity(target)
    }

    // MARK: - Icon

    private func updateIcon() {
        let active = panel.intensity > 0
        statusItem.button?.image = Self.icon(active: active)
        statusItem.button?.toolTip = active
            ? "Darkroom \(DarkroomIntensity.percent(from: panel.intensity))% — click to adjust"
            : "Darkroom off — click to adjust"
    }

    /// A filled dot when active, hollow when off.
    private static func icon(active: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let color: NSColor = active ? .systemRed : .secondaryLabelColor
            color.setStroke()
            color.setFill()

            let outer = NSBezierPath(ovalIn: rect.insetBy(dx: 5, dy: 5))
            outer.lineWidth = 1.6
            if active {
                outer.fill()
            } else {
                outer.stroke()
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    // MARK: - Popover delegate

    func popoverDidClose(_ notification: Notification) {
        panel.finishEditing()
    }
}
