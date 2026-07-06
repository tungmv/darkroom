import CoreGraphics
import Darwin
import DarkroomKit
import Foundation

// MARK: - State (nonisolated to avoid Swift 6 MainActor isolation)

nonisolated(unsafe) var darkroomEnabled = false
nonisolated(unsafe) var gammaTimer: DispatchSourceTimer?

// MARK: - Signal handling

func setupSignals() {
    // SIGINT / SIGTERM → restore gamma and exit.
    signal(SIGINT, { _ in restoreAndExit() })
    signal(SIGTERM, { _ in restoreAndExit() })

    // Don't crash on disconnected clients.
    signal(SIGPIPE, SIG_IGN)
}

func restoreAndExit() {
    fputs("darkroomd: restoring gamma and exiting\n", stderr)
    gammaTimer?.cancel()
    let ids = getActiveDisplays().map(\.id)
    applyGamma(enabled: false, to: ids)
    darkroomEnabled = false
    unlink(DaemonSocket.path)
    exit(0)
}

// MARK: - Gamma timer (reapply periodically to beat ColorSync / Lunar)

func startGammaTimer() {
    gammaTimer?.cancel()
    let timer = DispatchSource.makeTimerSource(queue: .global())
    timer.schedule(deadline: .now(), repeating: .milliseconds(500))
    timer.setEventHandler {
        guard darkroomEnabled else { return }
        let ids = getActiveDisplays().map(\.id)
        applyGamma(enabled: true, to: ids)
    }
    timer.resume()
    gammaTimer = timer
}

// MARK: - Socket server

func runServer() {
    let sock = socket(AF_UNIX, SOCK_STREAM, 0)
    guard sock >= 0 else {
        fatalError("socket() failed: \(String(cString: strerror(errno)))")
    }

    // Remove stale socket file.
    unlink(DaemonSocket.path)

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathCap = MemoryLayout.size(ofValue: addr.sun_path)
    withUnsafeMutablePointer(to: &addr.sun_path) { sunPathPtr in
        sunPathPtr.withMemoryRebound(to: Int8.self, capacity: pathCap) { bufPtr in
            _ = DaemonSocket.path.withCString { strcpy(bufPtr, $0) }
        }
    }

    guard bind(sock, sockaddrCast(&addr), socklen_t(MemoryLayout<sockaddr_un>.size)) == 0 else {
        fatalError("bind() failed: \(String(cString: strerror(errno)))")
    }
    guard listen(sock, 8) == 0 else {
        fatalError("listen() failed: \(String(cString: strerror(errno)))")
    }

    fputs("darkroomd: listening on \(DaemonSocket.path)\n", stderr)

    while true {
        let client = accept(sock, nil, nil)
        guard client >= 0 else {
            if errno == EINTR { continue }
            fputs("darkroomd: accept error: \(String(cString: strerror(errno)))\n", stderr)
            continue
        }

        DispatchQueue.global().async {
            handleClient(client)
            close(client)
        }
    }
}

func handleClient(_ fd: Int32) {
    var buf = [UInt8](repeating: 0, count: 256)
    let n = read(fd, &buf, buf.count)
    guard n > 0 else { return }

    let raw = String(decoding: buf[0..<n], as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)

    guard let cmd = DarkroomCommand(rawValue: raw) else {
        _ = respond(fd, "error: unknown command '\(raw)'")
        return
    }

    switch cmd {
    case .on:
        let ids = getActiveDisplays().map(\.id)
        applyGamma(enabled: true, to: ids)
        darkroomEnabled = true
        startGammaTimer()
        _ = respond(fd, "on ok")

    case .off:
        gammaTimer?.cancel()
        gammaTimer = nil
        let ids = getActiveDisplays().map(\.id)
        applyGamma(enabled: false, to: ids)
        darkroomEnabled = false
        _ = respond(fd, "off ok")

    case .status:
        _ = respond(fd, darkroomEnabled ? "on" : "off")

    case .stop:
        _ = respond(fd, "stopping")
        restoreAndExit()
    }
}

func respond(_ fd: Int32, _ message: String) -> Bool {
    let payload = message + "\n"
    return payload.withCString {
        write(fd, $0, payload.utf8.count) > 0
    }
}

// MARK: - Helpers

func sockaddrCast(_ ptr: UnsafeMutablePointer<sockaddr_un>) -> UnsafeMutablePointer<sockaddr> {
    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { $0 }
}

// MARK: - Entry

setupSignals()
runServer()
