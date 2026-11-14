import AppKit
import DarkroomKit

/// Root view that owns keyboard handling so arrow keys nudge the slider even
/// though the slider itself never becomes first responder.
final class DarkroomRootView: NSView {
    weak var panel: DarkroomPanel?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard let panel, panel.handleKey(event) else {
            super.keyDown(with: event)
            return
        }
    }
}

/// The popover panel: one big slider plus quick presets.
@MainActor
final class DarkroomPanel: NSViewController {
    private let controller = IntensityController()

    /// Called whenever the effective intensity changes, so the status bar can
    /// redraw its icon.
    var onIntensityChanged: ((Double) -> Void)?

    /// Strength the panel is currently showing. Optimistic: it updates on the
    /// drag itself and is corrected by the daemon's reply (or by `refresh()`
    /// after a failure), so the icon and the toggle never lag a drag.
    private(set) var intensity: Double = 0

    /// True while an intensity change is still being applied.
    var isApplying: Bool { controller.isApplying }

    private let titleLabel = NSTextField(labelWithString: "Darkroom")
    private let valueLabel = NSTextField(labelWithString: "0%")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let slider = NSSlider(value: 0, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let switchButton = NSSwitch()
    private let switchLabel = NSTextField(labelWithString: "Enabled")
    private let errorLabel = NSTextField(labelWithString: "")
    private var presetButtons: [NSButton] = []

    private let presets = [25, 50, 75, 100]
    private var isSwitchAdjusting = false

    private static let width: CGFloat = 320

    override func loadView() {
        let root = DarkroomRootView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 200))
        root.translatesAutoresizingMaskIntoConstraints = false
        root.panel = self
        view = root
        let contentHeight = buildUI(in: root)

        // Size the panel to its content so there is never dead space at the
        // bottom (the height used to be a hand-tuned constant).
        let height = contentHeight
        root.frame = NSRect(x: 0, y: 0, width: Self.width, height: height)
        preferredContentSize = NSSize(width: Self.width, height: height)
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        controller.onUpdate = { [weak self] intensity in
            guard let self else { return }
            // Confirmed by the daemon: adopt it, unless the user has already
            // queued a newer value (their drag wins).
            guard !self.controller.isApplying else { return }
            self.render(intensity)
        }
        controller.onError = { [weak self] message in
            self?.showError(message)
        }
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        view.window?.makeFirstResponder(view)
        refreshDisplayCount()

        // Adopt an already-running daemon's value synchronously so the first
        // frame is correct instead of flashing 0% before the async reply lands.
        if let current = DarkroomClient.runningIntensity() {
            render(current)
        }
        controller.refresh()
    }

    // MARK: - UI

    /// Builds the view tree and returns the height the stack needs.
    @discardableResult
    private func buildUI(in root: NSView) -> CGFloat {
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor

        valueLabel.font = .monospacedDigitSystemFont(ofSize: 34, weight: .light)
        valueLabel.alignment = .center
        valueLabel.textColor = .labelColor

        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.alignment = .center

        slider.target = self
        slider.action = #selector(sliderChanged(_:))
        slider.isContinuous = true
        slider.controlSize = .large
        slider.numberOfTickMarks = 5
        slider.tickMarkPosition = .below
        slider.allowsTickMarkValuesOnly = false
        slider.toolTip = "Darkroom intensity (use ← → , or 0 / 1 for off / full)"
        slider.refusesFirstResponder = true

        switchButton.target = self
        switchButton.action = #selector(switchChanged(_:))
        switchLabel.font = .systemFont(ofSize: 12)
        switchLabel.textColor = .labelColor

        presetButtons = presets.map { percent in
            let button = NSButton(
                title: "\(percent)%",
                target: self,
                action: #selector(presetTapped(_:))
            )
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11)
            button.tag = percent
            return button
        }

        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.textColor = .systemRed
        errorLabel.alignment = .center
        errorLabel.stringValue = " "  // reserve the row so the height is stable
        errorLabel.lineBreakMode = .byTruncatingTail

        let presetStack = NSStackView(views: presetButtons)
        presetStack.orientation = .horizontal
        presetStack.distribution = .fillEqually
        presetStack.spacing = 6

        let switchStack = NSStackView(views: [switchButton, switchLabel])
        switchStack.orientation = .horizontal
        switchStack.spacing = 8
        switchStack.alignment = .centerY

        let quitButton = NSButton(title: "Quit", target: self, action: #selector(quit))
        quitButton.bezelStyle = .inline
        quitButton.controlSize = .small
        quitButton.font = .systemFont(ofSize: 11)
        quitButton.isBordered = false
        quitButton.contentTintColor = .secondaryLabelColor

        let footerStack = NSStackView(views: [subtitleLabel, NSView(), quitButton])
        footerStack.orientation = .horizontal
        footerStack.spacing = 8
        footerStack.alignment = .centerY

        let stack = NSStackView(views: [
            titleLabel,
            valueLabel,
            slider,
            presetStack,
            switchStack,
            errorLabel,
            footerStack,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(2, after: titleLabel)
        stack.setCustomSpacing(4, after: valueLabel)
        stack.setCustomSpacing(14, after: presetStack)
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 12, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        for subview in [valueLabel, subtitleLabel, slider, presetStack, switchStack, errorLabel, footerStack] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            subview.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        }

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])

        // Measure now that the constraints exist; the popover is sized from
        // this so the layout cannot drift out of sync with a hardcoded height.
        root.layoutSubtreeIfNeeded()
        return stack.fittingSize.height
    }

    // MARK: - Rendering

    private func render(_ intensity: Double) {
        let value = DarkroomIntensity.normalized(intensity)
        self.intensity = value
        let percent = DarkroomIntensity.percent(from: value)
        if !slider.isHighlighted || abs(slider.doubleValue - Double(percent)) < 0.5 {
            slider.doubleValue = Double(percent)
        }

        valueLabel.stringValue = "\(percent)%"
        valueLabel.textColor = percent > 0
            ? NSColor(calibratedRed: 0.95, green: 0.32, blue: 0.32, alpha: 1)
            : .labelColor

        if !isSwitchAdjusting {
            switchButton.state = percent > 0 ? .on : .off
        }

        subtitleLabel.stringValue = percent == 0
            ? "Normal display"
            : (percent >= 100 ? "Red-only display" : "Partly red-tinted")

        // Only an exact match highlights a preset; a rounded nearest match
        // would claim "25%" while the display sits at 30%.
        for button in presetButtons {
            button.state = button.tag == percent ? .on : .off
        }

        onIntensityChanged?(value)
    }

    /// Re-read the display count (called when screens are plugged or removed).
    func refreshDisplayCount() {
        let count = getActiveDisplayIDs().count
        let displays: String
        switch count {
        case 0: displays = "no display"
        case 1: displays = "1 display"
        default: displays = "\(count) displays"
        }
        titleLabel.stringValue = "Darkroom · \(displays)"
    }

    /// Called when the popover closes: drop optimistic state and re-read the
    /// daemon, so a failed drag cannot leave the UI lying.
    func finishEditing() {
        controller.refresh()
    }

    /// Pull the current strength from the daemon (used at launch, so the menu
    /// bar icon matches gamma that is already applied).
    func syncFromDaemon() {
        controller.refresh()
    }

    /// Background poll entry point: re-read the daemon unless a change is still
    /// in flight, so the icon tracks CLI changes without fighting a drag.
    func refreshFromDaemon() {
        guard !controller.isApplying else { return }
        controller.refresh()
    }


    /// Set the strength from outside the panel (status bar toggle, self-test).
    func setIntensity(_ intensity: Double) {
        clearError()
        let value = DarkroomIntensity.normalized(intensity)
        controller.request(value)
        render(value)
    }

    private var errorToken = 0

    /// Test hook: drive the error row exactly as a daemon failure would.
    func showErrorForTesting(_ message: String) { showError(message) }

    /// Height the popover asks for.
    var panelHeight: CGFloat { preferredContentSize.height }

    private func showError(_ message: String) {
        errorToken += 1
        let token = errorToken
        errorLabel.stringValue = message

        // Keep the panel usable: the message clears on the next successful
        // change, or after a few seconds. The token stops an old timer from
        // clearing a newer message.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard self.errorToken == token else { return }
            self.clearError()
        }
    }

    private func clearError() {
        errorToken += 1
        errorLabel.stringValue = " "
    }

    // MARK: - Actions

    @objc private func sliderChanged(_ sender: NSSlider) {
        clearError()
        // Snap to 5% steps while dragging so the value is predictable, but
        // never round the endpoints away.
        let raw = sender.doubleValue
        let percent = (raw <= 1 || raw >= 99) ? raw.rounded() : (raw / 5).rounded() * 5
        let intensity = DarkroomIntensity.normalized(percent / 100)
        controller.request(intensity)
        // Optimistic render: gamma updates land in ~10 ms.
        render(intensity)
    }

    @objc private func presetTapped(_ sender: NSButton) {
        clearError()
        let intensity = DarkroomIntensity.normalized(Double(sender.tag) / 100)
        controller.request(intensity)
        render(intensity)
    }

    @objc private func switchChanged(_ sender: NSSwitch) {
        clearError()
        isSwitchAdjusting = true
        defer { isSwitchAdjusting = false }

        if sender.state == .on {
            // Re-enabling restores the last strength the user actually used
            // rather than defaulting to full red.
            setIntensity(DarkroomSettings.loadIntensityOrDefault())
        } else {
            setIntensity(0)
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Keyboard

    /// Let arrow keys nudge the slider by 5% (or 1% with Shift/Option).
    func handleKey(_ event: NSEvent) -> Bool {
        let fine = event.modifierFlags.contains(.shift)
        let step = fine ? 1.0 : 5.0
        var percent = slider.doubleValue

        switch event.keyCode {
        case 123:  // left
            percent -= step
        case 124:  // right
            percent += step
        case 125:  // down
            percent -= step
        case 126:  // up
            percent += step
        default:
            if let characters = event.charactersIgnoringModifiers {
                switch characters {
                case "+", "=":
                    percent += step
                case "-", "_":
                    percent -= step
                case "0":
                    percent = 0
                case "1":
                    percent = 100
                default:
                    return false
                }
            } else {
                return false
            }
        }

        let clamped = min(max(percent, 0), 100)
        let intensity = DarkroomIntensity.normalized(clamped / 100)
        controller.request(intensity)
        render(intensity)
        return true
    }
}
