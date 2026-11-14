import ArgumentParser
import DarkroomKit
import Foundation

// MARK: - Shared helpers

func sendOrStart(_ command: DarkroomCommand) -> String {
    switch DarkroomClient.send(command) {
    case .success(let response):
        return response
    case .failure(let error):
        return "error: \(error.description)"
    }
}

func commandError(_ response: String) -> String {
    DarkroomClient.commandError(response)
}

// MARK: - CLI

@main
struct Darkroom: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "darkroom",
        abstract: "Toggle darkroom mode from the terminal (red-only, low-light friendly).",
        subcommands: [
            On.self, Off.self, Status.self, Toggle.self, Stop.self,
            Intensity.self, Get.self, Gui.self,
        ],
        defaultSubcommand: Toggle.self
    )
}

// ---- Commands ----

struct On: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "on",
        abstract: "Enable darkroom mode on all active displays."
    )

    @Option(name: .customLong("intensity"), help: "Strength: 0-100 or 0.0-1.0.")
    var intensity: String?

    func run() throws {
        if let intensity {
            guard let value = DarkroomIntensity.parse(intensity) else {
                print("Error: intensity must be between 0 and 100 (or 0.0-1.0)")
                throw ExitCode.failure
            }
            let result = sendOrStart(.intensity(value))
            if result.hasPrefix("intensity ok") {
                print("Darkroom mode ON (\(Intensity.describe(result)))")
            } else {
                print("Error: \(commandError(result))")
                throw ExitCode.failure
            }
            return
        }

        let result = sendOrStart(.on)
        if result == "on ok" {
            let percent = DarkroomIntensity.percent(from: DarkroomClient.currentIntensity())
            print("Darkroom mode ON (\(percent)%)")
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
        let daemonRunning = DarkroomClient.isDaemonRunning()

        guard !displays.isEmpty else {
            // Screens asleep / session locked: still report the daemon's intent
            // so `status` is useful in scripts.
            let intent = DarkroomClient.currentIntensity()
            print("Darkroom mode: \(intent > 0 ? "ON" : "OFF")")
            if intent > 0 {
                print("Intensity: \(DarkroomIntensity.percent(from: intent))%")
            }
            print("No active displays (screen asleep or session locked).")
            return
        }

        let displayStates = displays.map { display in
            (
                display: display,
                intensity: readDarkroomIntensity(for: display.id)
            )
        }
        let active = displayStates.filter { $0.intensity > 0 }
        let strongest = active.map(\.intensity).max() ?? 0

        print("Darkroom mode: \(active.isEmpty ? "OFF" : "ON")")
        if !active.isEmpty {
            print("Intensity: \(DarkroomIntensity.percent(from: strongest))%")
        }
        if !daemonRunning {
            print("(daemon not running)")
        }
        print("\(displays.count) active display\(displays.count == 1 ? "" : "s"):")
        for state in displayStates {
            let label = state.intensity > 0
                ? "darkroom \(DarkroomIntensity.percent(from: state.intensity))%"
                : "normal"
            print("  \(state.intensity > 0 ? "●" : "○") \(state.display.name) — \(label)")
        }
    }
}

struct Intensity: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "intensity",
        abstract: "Set the darkroom strength (0 = normal, 100 = red-only)."
    )

    @Argument(help: "Strength as a percentage (0-100) or a fraction (0.0-1.0).")
    var value: String

    func run() throws {
        guard let normalized = DarkroomIntensity.parse(value) else {
            print("Error: intensity must be between 0 and 100 (or 0.0-1.0)")
            throw ExitCode.failure
        }

        let result = sendOrStart(.intensity(normalized))
        if result.hasPrefix("intensity ok") {
            print("Darkroom intensity \(Self.describe(result))")
        } else {
            print("Error: \(commandError(result))")
            throw ExitCode.failure
        }
    }

    static func describe(_ response: String) -> String {
        guard let intensity = DarkroomClient.parseIntensityResponse(response) else {
            return ""
        }
        return "\(DarkroomIntensity.percent(from: intensity))%"
    }
}

struct Get: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Print the current darkroom intensity as a percentage."
    )

    func run() throws {
        let intensity = DarkroomClient.currentIntensity()
        print(DarkroomIntensity.percent(from: intensity))
    }
}

struct Gui: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "gui",
        abstract: "Launch the menu bar app with the intensity slider."
    )

    func run() throws {
        var candidates = [
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications/Darkroom.app").path,
            "/Applications/Darkroom.app",
        ]

        // Alongside the executable (installed bundle) and, for development,
        // next to the package root that holds .build/Darkroom.app.
        if let executable = invokedExecutablePath() {
            let directory = URL(fileURLWithPath: executable).deletingLastPathComponent()
            candidates.append(directory.appendingPathComponent("Darkroom.app").path)
            candidates.append(
                directory.deletingLastPathComponent()
                    .appendingPathComponent("Darkroom.app").path)
            candidates.append(
                directory.appendingPathComponent(".build/Darkroom.app").path)
        }
        candidates.append(".build/Darkroom.app")

        guard let app = candidates.first(where: {
            FileManager.default.fileExists(atPath: $0)
        }) else {
            print("""
            Error: Darkroom.app was not found. Build it with:
              make app
            """)
            throw ExitCode.failure
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = [app]
        do {
            try task.run()
            task.waitUntilExit()
            print("Launched \(app)")
        } catch {
            print("Error: could not launch \(app): \(error.localizedDescription)")
            throw ExitCode.failure
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
        let isCurrentlyOn = DarkroomClient.currentIntensity() > 0

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

struct Stop: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop",
        abstract: "Stop the background daemon and restore normal gamma."
    )

    func run() throws {
        switch DaemonSocket.send(.stop) {
        case .success("stopping"):
            // The daemon writes its response before completing cleanup. Wait
            // until it has removed the socket so an install/restart cannot
            // accidentally keep talking to the old executable.
            for _ in 0..<50 {
                if case .failure = DaemonSocket.send(.status, timeout: 0.1) {
                    print("Darkroom daemon stopped")
                    return
                }
                usleep(20_000)
            }
            print("Error: darkroomd did not stop")
            throw ExitCode.failure

        case .success(let response):
            print("Error: \(commandError(response))")
            throw ExitCode.failure

        case .failure:
            print("Darkroom daemon is not running")
        }
    }
}
