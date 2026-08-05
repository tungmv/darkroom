import CoreGraphics
import Darwin
import DarkroomKit
import Foundation

final class DarkroomDaemon: @unchecked Sendable {
    private let queue = DispatchQueue(label: "sh.darkroom.darkroomd.state")
    private let gammaApplier = GammaApplier()
    private var darkroomEnabled = false
    private var gammaTimer: DispatchSourceTimer?
    private var signalSources: [DispatchSourceSignal] = []
    private var lockFD: Int32 = -1

    func run() -> Never {
        acquireInstanceLock()
        setupSignals()

        queue.sync {
            let ids = getActiveDisplayIDs()
            darkroomEnabled = ids.contains { readDarkroomActive(for: $0) }
            if darkroomEnabled {
                startGammaTimer()
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
        _ = gammaApplier.apply(enabled: false, to: getActiveDisplayIDs())
        darkroomEnabled = false
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
            guard let self, self.darkroomEnabled else { return }
            _ = self.gammaApplier.apply(
                enabled: true,
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
              let command = DarkroomCommand(rawValue: rawCommand)
        else {
            _ = respond(fd, "error: invalid command")
            return
        }

        switch command {
        case .on:
            let ids = getActiveDisplayIDs()
            guard gammaApplier.apply(enabled: true, to: ids) else {
                _ = gammaApplier.apply(enabled: false, to: ids)
                darkroomEnabled = false
                stopGammaTimer()
                _ = respond(fd, "error: failed to apply gamma to all active displays")
                return
            }

            darkroomEnabled = true
            startGammaTimer()
            _ = respond(fd, "on ok")

        case .off:
            stopGammaTimer()
            darkroomEnabled = false
            guard gammaApplier.apply(enabled: false, to: getActiveDisplayIDs()) else {
                _ = respond(fd, "error: failed to restore gamma on all active displays")
                return
            }
            _ = respond(fd, "off ok")

        case .status:
            _ = respond(fd, darkroomEnabled ? "on" : "off")

        case .stop:
            _ = respond(fd, "stopping")
            restoreAndExit()
        }
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
