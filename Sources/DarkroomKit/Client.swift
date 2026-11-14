import Foundation

// MARK: - Persistence

/// Small on-disk record of the last intensity, so the GUI and CLI can restore
/// the user's preferred strength across launches and daemon restarts.
public enum DarkroomSettings {
    /// Test hook: redirect the settings directory. Returns false for a path
    /// that cannot be created.
    @discardableResult
    public static func overrideDirectoryForTesting(_ path: String?) -> Bool {
        guard let path else {
            overrideDirectory = nil
            return true
        }
        do {
            try FileManager.default.createDirectory(
                atPath: path, withIntermediateDirectories: true)
        } catch {
            return false
        }
        overrideDirectory = path
        return true
    }

    private nonisolated(unsafe) static var overrideDirectory: String?

    public static var directory: String {
        if let overrideDirectory { return overrideDirectory }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".darkroom").path
    }

    private static var intensityFile: String {
        _ = try? FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true)
        return "\(directory)/intensity"
    }

    public static func loadIntensity() -> Double {
        guard let text = try? String(contentsOfFile: intensityFile, encoding: .utf8),
              let percent = Double(text.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            return DarkroomIntensity.defaultValue
        }
        return DarkroomIntensity.normalized(percent / 100)
    }

    public static func saveIntensity(_ intensity: Double) {
        let percent = DarkroomIntensity.percent(from: intensity)
        try? String(percent).write(
            toFile: intensityFile, atomically: true, encoding: .utf8)
    }
}

// MARK: - Locating the daemon binary

/// Resolve the executable path used to invoke this process.
///
/// Shells commonly preserve `argv[0]` as just `darkroom`, even when they found
/// it through `PATH`, so it cannot be assumed to be an absolute path.
public func invokedExecutablePath() -> String? {
    let invocation = CommandLine.arguments[0]
    let fileManager = FileManager.default

    if invocation.contains("/") {
        return fileManager.fileExists(atPath: invocation) ? invocation : nil
    }

    let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
    for directory in path.split(separator: ":", omittingEmptySubsequences: false) {
        let base = directory.isEmpty ? "." : String(directory)
        let candidate = URL(fileURLWithPath: base)
            .appendingPathComponent(invocation)
            .path
        if fileManager.isExecutableFile(atPath: candidate) {
            return candidate
        }
    }

    return nil
}

/// Candidate locations for `darkroomd`, in priority order.
public func daemonCandidates() -> [String] {
    let fileManager = FileManager.default
    var candidates: [String] = []

    if let ourPath = invokedExecutablePath() {
        let url = URL(fileURLWithPath: ourPath)
        // Installed side-by-side, or bundled inside Darkroom.app/Contents/MacOS.
        candidates.append(
            url.deletingLastPathComponent()
                .appendingPathComponent("darkroomd").path)

        // `swift run` from the package root.
        if url.lastPathComponent == "darkroom" || url.lastPathComponent == "darkroom-gui" {
            let root = url.deletingLastPathComponent().deletingLastPathComponent()
            candidates.append(root.appendingPathComponent(".build/release/darkroomd").path)
            candidates.append(root.appendingPathComponent(".build/debug/darkroomd").path)
        }
    }

    candidates.append(contentsOf: [
        ".build/release/darkroomd",
        ".build/debug/darkroomd",
        "/usr/local/bin/darkroomd",
        "/opt/homebrew/bin/darkroomd",
    ])

    var seen = Set<String>()
    return candidates.filter { path in
        guard fileManager.isExecutableFile(atPath: path) else { return false }
        return seen.insert(path).inserted
    }
}

// MARK: - Client

/// Thin client over the daemon socket that starts `darkroomd` on demand.
public enum DarkroomClient {
    public static func isDaemonRunning() -> Bool {
        if case .success = DaemonSocket.send(.status, timeout: 0.5) { return true }
        return false
    }

    /// Start darkroomd in the background if it isn't already running.
    /// Returns nil on success or a user-facing error on failure.
    public static func ensureDaemon(startTimeout: TimeInterval = 3) -> String? {
        // Quick check: is the daemon already reachable?
        if case .success = DaemonSocket.send(.status, timeout: 0.25) {
            return nil
        }

        guard let daemonPath = daemonCandidates().first else {
            return "darkroomd was not found next to this binary or on PATH"
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: daemonPath)
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            return "could not launch darkroomd: \(error.localizedDescription)"
        }

        // Wait for the daemon to become ready (poll the socket).
        let deadline = Date().addingTimeInterval(startTimeout)
        while Date() < deadline {
            usleep(50_000)  // 50 ms
            if case .success = DaemonSocket.send(.status, timeout: 0.25) {
                return nil
            }
        }
        return "darkroomd did not become ready"
    }

    /// Send a command, starting the daemon first if it is not running.
    ///
    /// A running daemon that answers `error: invalid command` was built before
    /// this command existed (e.g. after `make install` replaced the binaries but
    /// an old darkroomd was still alive). It is retired and replaced so the CLI
    /// and GUI never talk to a stale protocol.
    public static func send(_ command: DarkroomCommand, timeout: TimeInterval = 10)
        -> Result<String, DarkroomError>
    {
        if case .success(let response) = DaemonSocket.send(command, timeout: 2) {
            if response == Self.unknownCommandResponse {
                retireDaemon()
            } else {
                return .success(response)
            }
        }

        if let error = ensureDaemon() {
            return .failure(.outOfDate(error))
        }

        switch DaemonSocket.send(command, timeout: timeout) {
        case .success(let response):
            if response == Self.unknownCommandResponse {
                return .failure(.outOfDate(
                    "darkroomd is too old for this command; rebuild and reinstall both binaries"))
            }
            return .success(response)
        case .failure(let error):
            return .failure(error)
        }
    }

    static let unknownCommandResponse = "error: invalid command"

    /// Ask the running daemon to restore gamma and exit, then wait for its
    /// socket to disappear. Returns true once nothing answers on the socket.
    @discardableResult
    static func retireDaemon(timeout: TimeInterval = 2) -> Bool {
        _ = DaemonSocket.send(.stop, timeout: timeout)

        // The daemon removes its socket and releases its lock before exiting.
        // Only proceed once the socket is actually gone, otherwise the restart
        // below could connect to the process we just asked to stop.
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if case .failure = DaemonSocket.send(.status, timeout: 0.1) {
                // Confirm the socket file is gone too: a daemon still finishing
                // shutdown can accept and then fail.
                if !FileManager.default.fileExists(atPath: DaemonSocket.path) {
                    return true
                }
            }
            usleep(20_000)
        }
        return false
    }

    // MARK: High-level operations

    /// Apply `intensity` (0...1). Persistence of the last *used* strength
    /// happens in the daemon, the single writer, so it is recorded exactly when
    /// the gamma table is actually applied.
    public static func setIntensity(_ intensity: Double) -> String? {
        switch send(.intensity(intensity)) {
        case .success(let response):
            return response.hasPrefix("intensity ok") ? nil : commandError(response)
        case .failure(let error):
            return error.description
        }
    }

    /// Current intensity reported by the daemon, falling back to reading the
    /// gamma tables directly when the daemon is not running.
    public static func currentIntensity() -> Double {
        if case .success(let response) = DaemonSocket.send(.get, timeout: 2),
           let value = parseIntensityResponse(response) {
            return value
        }
        return currentDarkroomIntensity(for: getActiveDisplayIDs())
    }

    /// Query a daemon that is already running, without launching one. Returns
    /// nil when no daemon answers, so callers can avoid showing a placeholder.
    ///
    /// Cheap enough for the main thread: connecting to a missing socket path
    /// fails immediately rather than waiting out the timeout.
    public static func runningIntensity(timeout: TimeInterval = 0.2) -> Double? {
        guard case .success(let response) = DaemonSocket.send(.get, timeout: timeout) else {
            return nil
        }
        return parseIntensityResponse(response)
    }

    /// Parse `"intensity 35"` and `"intensity ok 35"` into `0.35`.
    public static func parseIntensityResponse(_ response: String) -> Double? {
        let parts = response.split(separator: " ").filter { $0 != "ok" }
        guard parts.count == 2, parts[0] == "intensity",
              let percent = Double(parts[1])
        else {
            return nil
        }
        return DarkroomIntensity.normalized(percent / 100)
    }

    public static func commandError(_ response: String) -> String {
        if response.hasPrefix("error: ") {
            return String(response.dropFirst("error: ".count))
        }
        return response
    }
}

extension DarkroomSettings {
    /// Last saved intensity, or full strength when nothing was ever saved.
    public static func loadIntensityOrDefault() -> Double {
        let value = loadIntensity()
        return value > 0 ? value : DarkroomIntensity.defaultValue
    }
}
