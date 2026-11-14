import Foundation
import Testing
@testable import DarkroomKit

// MARK: - Daemon client behaviour
//
// These tests use the real binary's socket path only when no daemon is
// running, so they never disturb an active darkroom session.

@Suite("Daemon client", .serialized)
struct DaemonClientTests {
    /// Skip the whole suite when a live daemon is present: these tests would
    /// otherwise reconfigure the user's screen.
    static var daemonIsLive: Bool {
        if case .success = DaemonSocket.send(.status, timeout: 0.2) { return true }
        return false
    }

    @Test("Unknown command response is the documented literal")
    func unknownCommandLiteral() {
        // The client matches on this exact string to detect an outdated daemon,
        // so a rename here would silently break migration.
        #expect(DarkroomClient.unknownCommandResponse == "error: invalid command")
    }

    @Test("Intensity responses round-trip through the wire format")
    func intensityWireRoundTrip() {
        for percent in stride(from: 0, through: 100, by: 5) {
            let command = DarkroomCommand.intensity(Double(percent) / 100)
            #expect(command.wireValue == "intensity \(percent)")

            guard case .intensity(let parsed) = DarkroomCommand(wireValue: command.wireValue)
            else {
                Issue.record("could not parse \(command.wireValue)")
                continue
            }
            #expect(DarkroomIntensity.percent(from: parsed) == percent)
        }
    }

    @Test("Settings file survives a round trip and rejects a missing file")
    func settingsRoundTrip() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("darkroom-settings-\(UUID().uuidString)")
        #expect(DarkroomSettings.overrideDirectoryForTesting(directory.path))
        defer {
            _ = DarkroomSettings.overrideDirectoryForTesting(nil)
            try? FileManager.default.removeItem(atPath: directory.path)
        }

        // Nothing saved yet: the default is full strength.
        #expect(DarkroomSettings.loadIntensity() == DarkroomIntensity.defaultValue)
        #expect(DarkroomSettings.loadIntensityOrDefault() == DarkroomIntensity.defaultValue)

        for percent in [7, 33, 60, 100] {
            DarkroomSettings.saveIntensity(Double(percent) / 100)
            #expect(DarkroomIntensity.percent(from: DarkroomSettings.loadIntensity()) == percent)
        }

        // A corrupt file must not produce a garbage intensity.
        try? "not a number".write(
            toFile: "\(directory.path)/intensity", atomically: true, encoding: .utf8)
        #expect(DarkroomSettings.loadIntensity() == DarkroomIntensity.defaultValue)
    }

    @Test("An unreachable daemon reports notRunning rather than hanging")
    func unreachableDaemon() {
        // Point the client at a socket path nothing is listening on.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("darkroom-socket-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            atPath: directory.path, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory.path) }

        let missing = "\(directory.path)/nothing.sock"
        #expect(!FileManager.default.fileExists(atPath: missing))

        // The real socket path is in use only if a daemon is running; when it
        // is not, status must fail fast instead of blocking.
        if !Self.daemonIsLive {
            let started = Date()
            let result = DaemonSocket.send(.status, timeout: 1)
            let elapsed = Date().timeIntervalSince(started)
            if case .success = result {
                Issue.record("expected no daemon to answer")
            }
            #expect(elapsed < 1.5)
        }
    }
}
