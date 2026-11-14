import CoreGraphics
import Darwin
import DarkroomKit
import Foundation

final class DarkroomDaemon: @unchecked Sendable {
    private let queue = DispatchQueue(label: "sh.darkroom.darkroomd.state")
    private let gammaApplier = GammaApplier()
    /// Strength currently applied, 0...1. `0` means normal gamma.
    private var intensity: Double = 0
    private var gammaTimer: DispatchSourceTimer?
    private var signalSources: [DispatchSourceSignal] = []
    private var lockFD: Int32 = -1

    func run() -> Never {
        acquireInstanceLock()
        setupSignals()

        queue.sync {
            let ids = getActiveDisplayIDs()
            let measured = currentDarkroomIntensity(for: ids)
            if measured > 0 {
                intensity = measured
                startGammaTimer()
            } else {
                intensity = 0
            }
        }

        runServer()
    }

    // MARK: - Process lifetime

    private func acquireInstanceLock() {
        let lockPath = URL(fileURLWithPath: DaemonSocket.path)
            .deletingLastPathComponent()
            .appendingPathComponent("darkroomd.lock")
            .path

        lockFD = open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard lockFD >= 0 else {
            fatalError("open lock failed: \(lastError)")
        }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            fputs("darkroomd: another instance is already running\n", stderr)
            exit(0)
        }
    }

    private func setupSignals() {
        // Dispatch signal sources let cleanup happen outside a signal handler.
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        signal(SIGPIPE, SIG_IGN)

        for signalNumber in [SIGINT, SIGTERM] {
            let source = DispatchSource.makeSignalSource(
                signal: signalNumber,
                queue: queue
            )
            source.setEventHandler { [weak self] in
                self?.restoreAndExit()
            }
            source.resume()
            signalSources.append(source)
        }
    }

    private func restoreAndExit() -> Never {
        fputs("darkroomd: restoring gamma and exiting\n", stderr)
        stopGammaTimer()
        _ = gammaApplier.apply(intensity: 0, to: getActiveDisplayIDs())
        intensity = 0
        unlink(DaemonSocket.path)
        if lockFD >= 0 {
            close(lockFD)
        }
        exit(0)
    }

    // MARK: - Gamma timer

    private func startGammaTimer() {
        guard gammaTimer == nil else { return }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + .milliseconds(500),
            repeating: .milliseconds(500),
            leeway: .milliseconds(50)
        )
        timer.setEventHandler { [weak self] in
            guard let self, self.intensity > 0 else { return }
            _ = self.gammaApplier.apply(
                intensity: self.intensity,
                to: getActiveDisplayIDs()
            )
        }
        timer.resume()
        gammaTimer = timer
    }

    private func stopGammaTimer() {
        gammaTimer?.cancel()
        gammaTimer = nil
    }

    // MARK: - Socket server

    private func runServer() -> Never {
        let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            fatalError("socket() failed: \(lastError)")
        }

        unlink(DaemonSocket.path)

        let addressResult = DaemonSocket.makeAddress()
        guard case .success(var address) = addressResult else {
            if case .failure(let error) = addressResult {
                fatalError(error.description)
            }
            preconditionFailure("unreachable result state")
        }

        guard bind(
            socketFD,
            sockaddrCast(&address),
            socklen_t(MemoryLayout<sockaddr_un>.size)
        ) == 0 else {
            fatalError("bind() failed: \(lastError)")
        }
        _ = chmod(DaemonSocket.path, S_IRUSR | S_IWUSR)

        guard listen(socketFD, 8) == 0 else {
            fatalError("listen() failed: \(lastError)")
        }

        fputs("darkroomd: listening on \(DaemonSocket.path)\n", stderr)

        while true {
            let clientFD = accept(socketFD, nil, nil)
            guard clientFD >= 0 else {
                if errno == EINTR { continue }
                fputs("darkroomd: accept error: \(lastError)\n", stderr)
                continue
            }

            queue.async { [weak self] in
                self?.handleClient(clientFD)
                close(clientFD)
            }
        }
    }

    private func handleClient(_ fd: Int32) {
        guard let rawCommand = readCommand(from: fd),
              let command = DarkroomCommand(wireValue: rawCommand)
        else {
            _ = respond(fd, "error: invalid command")
            return
        }

        switch command {
        case .on:
            let target = DarkroomSettings.loadIntensityOrDefault()
            guard setIntensity(target) else {
                _ = respond(fd, "error: no active display accepted the gamma table")
                return
            }
            _ = respond(fd, "on ok")

        case .off:
            guard setIntensity(0) else {
                _ = respond(fd, "error: no active display accepted the normal gamma table")
                return
            }
            _ = respond(fd, "off ok")

        case .intensity(let value):
            guard setIntensity(value) else {
                _ = respond(fd, "error: no active display accepted the gamma table")
                return
            }
            let percent = DarkroomIntensity.percent(from: intensity)
            if percent > 0 {
                DarkroomSettings.saveIntensity(intensity)
            }
            _ = respond(fd, "intensity ok \(percent)")

        case .get:
            _ = respond(fd, "intensity \(DarkroomIntensity.percent(from: intensity))")

        case .status:
            _ = respond(fd, intensity > 0 ? "on" : "off")

        case .stop:
            _ = respond(fd, "stopping")
            restoreAndExit()
        }
    }

    /// Apply `value` to every active display and update the timer state.
    /// Returns false only when displays exist but none accepted the table.
    private func setIntensity(_ value: Double) -> Bool {
        let target = DarkroomIntensity.normalized(value)
        let ids = getActiveDisplayIDs()

        // No active displays means the screens are asleep or the session is
        // locked, not that the request is invalid. Record the intent and let
        // the reapply timer paint it once a display comes back.
        if ids.isEmpty {
            intensity = target
            if target > 0 {
                startGammaTimer()
            } else {
                stopGammaTimer()
            }
            return true
        }

        guard gammaApplier.apply(intensity: target, to: ids) else {
            // Roll back so the state never claims an intensity that is not on
            // screen.
            _ = gammaApplier.apply(intensity: intensity, to: getActiveDisplayIDs())
            return false
        }

        intensity = target
        if target > 0 {
            startGammaTimer()
        } else {
            stopGammaTimer()
        }
        return true
    }

    private func readCommand(from fd: Int32) -> String? {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(16)
        var buffer = [UInt8](repeating: 0, count: 64)

        while bytes.count < 256 {
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                bytes.append(contentsOf: buffer.prefix(count))
                if bytes.contains(0x0A) { break }
                continue
            }
            if count < 0 && errno == EINTR { continue }
            break
        }

        guard !bytes.isEmpty else { return nil }
        let line = bytes.prefix { $0 != 0x0A }
        return String(decoding: line, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func respond(_ fd: Int32, _ message: String) -> Bool {
        let bytes = Array((message + "\n").utf8)
        return bytes.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return true }

            var offset = 0
            while offset < rawBuffer.count {
                let count = write(
                    fd,
                    baseAddress.advanced(by: offset),
                    rawBuffer.count - offset
                )
                if count > 0 {
                    offset += count
                } else if count < 0 && errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }

    private func sockaddrCast(
        _ pointer: UnsafeMutablePointer<sockaddr_un>
    ) -> UnsafeMutablePointer<sockaddr> {
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { $0 }
    }

    private var lastError: String {
        String(cString: strerror(errno))
    }
}

DarkroomDaemon().run()
