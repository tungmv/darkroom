import Darwin
import Foundation

// MARK: - Socket path

public enum DaemonSocket {
    static let label = "sh.darkroom.darkroomd"

    public static var path: String {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".darkroom").path
        // Ensure the directory exists.
        _ = try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        return "\(dir)/darkroomd.sock"
    }

    // MARK: - Public API

    /// Send a command to the daemon and return its response line.
    @discardableResult
    public static func send(_ command: DarkroomCommand, timeout: TimeInterval = 5)
        -> Result<String, DarkroomError>
    {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            return .failure(.socketError("socket() failed: \(lastError)"))
        }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathCap = MemoryLayout.size(ofValue: addr.sun_path)
        withUnsafeMutablePointer(to: &addr.sun_path) { sunPathPtr in
            sunPathPtr.withMemoryRebound(to: Int8.self, capacity: pathCap) { bufPtr in
                _ = path.withCString { strcpy(bufPtr, $0) }
            }
        }

        guard connect(fd, sockaddrCast(&addr), socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
        else {
            return .failure(.notRunning("daemon not reachable at \(path)"))
        }

        // Send command + newline.
        let payload = command.rawValue + "\n"
        guard payload.withCString({
            write(fd, $0, payload.utf8.count)
        }) > 0 else {
            return .failure(.socketError("write failed: \(lastError)"))
        }

        // Shutdown write side so the server knows we're done.
        shutdown(fd, SHUT_WR)

        // Read response.
        var buf = [UInt8](repeating: 0, count: 1024)
        let n = read(fd, &buf, buf.count)
        guard n > 0 else {
            if n == 0 {
                return .failure(.socketError("daemon closed connection"))
            }
            return .failure(.socketError("read failed: \(lastError)"))
        }

        let response = String(decoding: buf[0..<n], as: UTF8.self).trimmingCharacters(in: .newlines)
        return .success(response)
    }

    // MARK: - Helpers

    private static func sockaddrCast(_ ptr: UnsafeMutablePointer<sockaddr_un>)
        -> UnsafeMutablePointer<sockaddr>
    {
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { $0 }
    }

    private static var lastError: String {
        String(cString: strerror(errno))
    }
}

// MARK: - Commands & Error

public enum DarkroomCommand: String, CaseIterable {
    case on      = "on"
    case off     = "off"
    case status  = "status"
    case stop    = "stop"
}

public enum DarkroomError: Error, CustomStringConvertible {
    case notRunning(String)
    case socketError(String)

    public var description: String {
        switch self {
        case .notRunning(let msg): return msg
        case .socketError(let msg): return msg
        }
    }
}
