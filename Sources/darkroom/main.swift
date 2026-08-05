import ArgumentParser
import DarkroomKit
import Foundation

// MARK: - Daemon helpers

/// Resolve the executable path used to invoke this process.
///
/// Shells commonly preserve `argv[0]` as just `darkroom`, even when they found
/// it through `PATH`, so it cannot be assumed to be an absolute path.
func invokedExecutablePath() -> String? {
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

/// Start darkroomd in the background if it isn't already running.
/// Returns nil on success or a user-facing error on failure.
func ensureDaemon() -> String? {
    // Quick check: is the daemon already reachable?
    if case .success = DaemonSocket.send(.status, timeout: 0.25) {
        return nil
    }

    // Find darkroomd binary next to this process.
    let daemonPath: String
    if let ourPath = invokedExecutablePath(),
       URL(fileURLWithPath: ourPath).lastPathComponent == "darkroom" {
        // Installed side-by-side.
        daemonPath = URL(fileURLWithPath: ourPath)
            .deletingLastPathComponent()
            .appendingPathComponent("darkroomd")
            .path
    } else {
        // Running via swift run — try common locations.
        let candidates = [
            ".build/debug/darkroomd",
            ".build/release/darkroomd",
        ]
        daemonPath = candidates.first {
            FileManager.default.isExecutableFile(atPath: $0)
        } ?? candidates[0]
    }

    guard FileManager.default.isExecutableFile(atPath: daemonPath) else {
        return "darkroomd is missing or not executable at \(daemonPath)"
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
    for _ in 0..<30 {
        usleep(100_000)  // 100 ms
        if case .success = DaemonSocket.send(.status, timeout: 0.25) {
            return nil
        }
    }
    return "darkroomd did not become ready"
}

func sendOrStart(_ command: DarkroomCommand) -> String {
    switch DaemonSocket.send(command) {
    case .success(let response):
        return response
    case .failure:
        // Daemon not running — try to start it and retry.
        if let error = ensureDaemon() {
            return "error: \(error)"
        }
        switch DaemonSocket.send(command, timeout: 10) {
        case .success(let response):
            return response
        case .failure(let err):
            return "error: \(err.description)"
        }
    }
}

func commandError(_ response: String) -> String {
    if response.hasPrefix("error: ") {
        return String(response.dropFirst("error: ".count))
    }
    return response
}

// MARK: - CLI

@main
struct Darkroom: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "darkroom",
        abstract: "Toggle darkroom mode from the terminal (red-only, low-light friendly).",
        subcommands: [On.self, Off.self, Status.self, Toggle.self],
        defaultSubcommand: Toggle.self
    )
}

// ---- Commands ----

struct On: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "on",
        abstract: "Enable darkroom mode on all active displays."
    )

    func run() throws {
        let result = sendOrStart(.on)
        if result == "on ok" {
            print("Darkroom mode ON")
        } else {
            print("Error: \(commandError(result))")
            throw ExitCode.failure
        }
    }
}

struct Off: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "off",
        abstract: "Disable darkroom mode (restore normal gamma)."
    )

    func run() throws {
        let result = sendOrStart(.off)
        if result == "off ok" {
            print("Darkroom mode OFF")
        } else {
            print("Error: \(commandError(result))")
            throw ExitCode.failure
        }
    }
}

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show darkroom mode status on each active display."
    )

    func run() throws {
        // Read status directly from gamma tables (works even if daemon is offline).
        let displays = getActiveDisplays()
        let daemonRunning = (try? DaemonSocket.send(.status).get()) != nil

        guard !displays.isEmpty else {
            print("No active displays found.")
            return
        }

        let displayStates = displays.map { display in
            (display: display, active: readDarkroomActive(for: display.id))
        }
        let anyActive = displayStates.contains { $0.active }
        print("Darkroom mode: \(anyActive ? "ON" : "OFF")")
        if !daemonRunning {
            print("(daemon not running)")
        }
        print("\(displays.count) active display\(displays.count == 1 ? "" : "s"):")
        for state in displayStates {
            print("  \(state.active ? "●" : "○") \(state.display.name) — \(state.active ? "darkroom" : "normal")")
        }
    }
}

struct Toggle: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "toggle",
        abstract: "Toggle darkroom mode on/off."
    )

    func run() throws {
        // Check current state via the daemon (if running) or gamma tables.
        let isCurrentlyOn: Bool
        if case .success(let resp) = DaemonSocket.send(.status), resp == "on" {
            isCurrentlyOn = true
        } else {
            // Daemon not running — fall back to reading gamma tables directly.
            let displays = getActiveDisplays()
            isCurrentlyOn = displays.contains { readDarkroomActive(for: $0.id) }
        }

        if isCurrentlyOn {
            let result = sendOrStart(.off)
            if result == "off ok" {
                print("Darkroom mode OFF")
            } else {
                print("Error: \(commandError(result))")
                throw ExitCode.failure
            }
        } else {
            let result = sendOrStart(.on)
            if result == "on ok" {
                print("Darkroom mode ON")
            } else {
                print("Error: \(commandError(result))")
                throw ExitCode.failure
            }
        }
    }
}
