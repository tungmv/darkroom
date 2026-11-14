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

        guard timeout > 0 else {
            return .failure(.socketError("timeout must be greater than zero"))
        }

        var socketTimeout = timeval(
            tv_sec: Int(timeout),
            tv_usec: Int32((timeout.truncatingRemainder(dividingBy: 1)) * 1_000_000)
        )
        guard setsockopt(
            fd, SOL_SOCKET, SO_SNDTIMEO, &socketTimeout,
            socklen_t(MemoryLayout<timeval>.size)
        ) == 0,
        setsockopt(
            fd, SOL_SOCKET, SO_RCVTIMEO, &socketTimeout,
            socklen_t(MemoryLayout<timeval>.size)
        ) == 0 else {
            return .failure(.socketError("setsockopt() failed: \(lastError)"))
        }

        let addressResult = makeAddress()
        guard case .success(var addr) = addressResult else {
            if case .failure(let error) = addressResult {
                return .failure(error)
            }
            preconditionFailure("unreachable result state")
        }

        guard connect(fd, sockaddrCast(&addr), socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
        else {
            return .failure(.notRunning("daemon not reachable at \(path)"))
        }

        // Send command + newline.
        let payload = Array((command.wireValue + "\n").utf8)
        if let error = writeAll(fd: fd, bytes: payload) {
            return .failure(error)
        }

        // Shutdown write side so the server knows we're done.
        shutdown(fd, SHUT_WR)

        // Read response.
        var responseBytes: [UInt8] = []
        responseBytes.reserveCapacity(128)
        var buffer = [UInt8](repeating: 0, count: 512)

        while responseBytes.count < 4096 {
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                responseBytes.append(contentsOf: buffer.prefix(count))
                if responseBytes.contains(0x0A) { break }
                continue
            }
            if count == 0 { break }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                return .failure(.socketError("daemon response timed out"))
            }
            return .failure(.socketError("read failed: \(lastError)"))
        }

        guard !responseBytes.isEmpty else {
            return .failure(.socketError("daemon closed connection"))
        }

        let line = responseBytes.prefix { $0 != 0x0A }
        let response = String(decoding: line, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return .success(response)
    }

    // MARK: - Helpers

    /// Build a bounded Unix-domain socket address for both client and server.
    public static func makeAddress() -> Result<sockaddr_un, DarkroomError> {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)

        let pathBytes = Array(path.utf8CString)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count <= capacity else {
            return .failure(.socketError(
                "socket path is too long (maximum \(capacity - 1) UTF-8 bytes): \(path)"
            ))
        }

        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            pathBytes.withUnsafeBytes { source in
                destination.copyBytes(from: source)
            }
        }
        return .success(address)
    }

    private static func writeAll(fd: Int32, bytes: [UInt8]) -> DarkroomError? {
        bytes.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return nil }

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
                } else if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    return .socketError("daemon request timed out")
                } else {
                    return .socketError("write failed: \(lastError)")
                }
            }
            return nil
        }
    }

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

/// Wire protocol spoken over the Unix socket. One command per connection, one
/// response line.
///
/// Wire forms:
///
///     on                 -> "on ok"
///     off                -> "off ok"
///     status             -> "on" | "off"
///     stop               -> "stopping"
///     intensity <0-100>  -> "intensity ok <0-100>"
///     get                -> "intensity <0-100>"
public enum DarkroomCommand: Sendable, Equatable {
    case on
    case off
    case status
    case stop
    /// Set the darkroom strength. `0` restores normal gamma, `1` is red-only.
    case intensity(Double)
    /// Report the current darkroom strength.
    case get

    public var wireValue: String {
        switch self {
        case .on: return "on"
        case .off: return "off"
        case .status: return "status"
        case .stop: return "stop"
        case .intensity(let value):
            return "intensity \(DarkroomIntensity.percent(from: value))"
        case .get: return "get"
        }
    }

    /// Parse a wire command coming from a client.
    public init?(wireValue raw: String) {
        let parts = raw.split(separator: " ", maxSplits: 1)
        guard let verb = parts.first else { return nil }
        let argument = parts.count > 1
            ? parts[1].trimmingCharacters(in: .whitespaces)
            : ""

        switch verb {
        case "on":
            self = .on
        case "off":
            self = .off
        case "status":
            self = .status
        case "stop":
            self = .stop
        case "get":
            self = .get
        case "intensity":
            guard let value = DarkroomIntensity.parse(argument) else { return nil }
            self = .intensity(value)
        default:
            return nil
        }
    }
}

public enum DarkroomError: Error, CustomStringConvertible {
    case notRunning(String)
    case socketError(String)
    /// The daemon answered, but does not understand the requested command
    /// (usually because an older `darkroomd` is still running).
    case outOfDate(String)

    public var description: String {
        switch self {
        case .notRunning(let msg): return msg
        case .socketError(let msg): return msg
        case .outOfDate(let msg): return msg
        }
    }
}
