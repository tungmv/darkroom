import AppKit
import DarkroomKit

/// Applies intensity changes off the main thread and coalesces rapid slider
/// updates so a fast drag never queues up a backlog of socket round trips.
@MainActor
final class IntensityController {
    /// Last intensity the daemon accepted.
    private(set) var appliedIntensity: Double = 0
    /// True while a request is in flight.
    private(set) var isBusy = false
    /// True while a request is in flight or queued behind one.
    var isApplying: Bool { isBusy || pending != nil }

    var onUpdate: ((Double) -> Void)?
    var onError: ((String) -> Void)?

    private let queue = DispatchQueue(label: "sh.darkroom.gui.apply", qos: .userInitiated)
    private var pending: Double?

    func refresh() {
        guard !isBusy, pending == nil else { return }
        queue.async { [weak self] in
            let value = DarkroomClient.currentIntensity()
            Task { @MainActor in
                self?.appliedIntensity = value
                self?.onUpdate?(value)
            }
        }
    }

    /// Request `intensity`; earlier queued values are dropped.
    func request(_ intensity: Double) {
        pending = DarkroomIntensity.normalized(intensity)
        pump()
    }

    private func pump() {
        guard !isBusy, let value = pending else { return }
        pending = nil
        isBusy = true

        queue.async { [weak self] in
            let error = DarkroomClient.setIntensity(value)
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.onError?(error)
                } else {
                    self.appliedIntensity = value
                    self.onUpdate?(value)
                }
                self.isBusy = false
                self.pump()
            }
        }
    }
}
