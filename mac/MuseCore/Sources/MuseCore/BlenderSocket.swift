import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Sends one add-on command (`{"type", "params"}`) and returns its `result`. Errors are `BlenderError`.
public protocol BlenderTransport: Sendable {
    func send(_ type: String, _ params: [String: JSONValue], timeout: TimeInterval) async throws -> JSONValue
}

public enum BlenderError: Error, Equatable, Sendable, LocalizedError {
    /// Blender isn't running, or the add-on's server isn't started (N panel → BlenderMCP → Connect).
    case notConnected
    case timedOut
    /// The add-on answered `{"status": "error", "message"}`.
    case command(String)
    case badReply(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected: return "Blender isn't connected (open Blender and start the MCP add-on's server on port 9876)"
        case .timedOut: return "Blender didn't answer in time"
        case .command(let m): return "Blender: \(m)"
        case .badReply(let m): return "Unexpected reply from Blender (\(m))"
        }
    }

    /// The add-on reports a Python exception as a JSON string {exception_type, message, traceback}: keep it short.
    public static func shortMessage(_ raw: String) -> String {
        if let d = raw.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            let type = o["exception_type"] as? String
            let msg = (o["message"] as? String) ?? (o["error"] as? String) ?? raw
            return String((type.map { "\($0): \(msg)" } ?? msg).prefix(300))
        }
        return String(raw.prefix(300))
    }
}

/// The add-on's socket server: one JSON object per request, one JSON object back on the same connection, no framing.
/// Localhost only; any other host is refused at init.
public final class BlenderSocket: BlenderTransport, @unchecked Sendable {
    public static let defaultPort: UInt16 = 9876
    public let port: UInt16
    /// Replies bigger than this are refused (scene info and code output are small; screenshots go through a file).
    let maxReply = 32 * 1024 * 1024

    public init(host: String = "127.0.0.1", port: UInt16 = BlenderSocket.defaultPort) throws {
        guard host == "127.0.0.1" || host == "localhost" else { throw BlenderError.badReply("only 127.0.0.1 is allowed") }
        self.port = port
    }

    public func send(_ type: String, _ params: [String: JSONValue], timeout: TimeInterval) async throws -> JSONValue {
        let body = try JSONEncoder().encode(JSONValue.object(["type": .string(type), "params": .object(params)]))
        let port = self.port
        let maxReply = self.maxReply
        let reply: Data = try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do { cont.resume(returning: try BlenderSocket.exchange(body, port: port, timeout: timeout, maxReply: maxReply)) } catch { cont.resume(throwing: error) }
            }
        }
        return try BlenderSocket.unwrap(reply)
    }

    /// `{"status": "success", "result"}` → result; `{"status": "error", "message"}` → BlenderError.command.
    public static func unwrap(_ reply: Data) throws -> JSONValue {
        guard case .object(let o)? = try? JSONDecoder().decode(JSONValue.self, from: reply) else { throw BlenderError.badReply("not a JSON object") }
        if case .string("success")? = o["status"] { return o["result"] ?? .null }
        if case .string(let m)? = o["message"] { throw BlenderError.command(BlenderError.shortMessage(m)) }
        throw BlenderError.badReply("no status")
    }

    /// True once the bytes so far are one complete JSON value (split UTF-8 or a half object just fails to parse).
    static func isComplete(_ buf: Data) -> Bool {
        guard let last = buf.last(where: { !($0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09) }), last == UInt8(ascii: "}") else { return false }
        return (try? JSONSerialization.jsonObject(with: buf)) != nil
    }

    // MARK: POSIX socket (Linux and macOS)

    private static func exchange(_ body: Data, port: UInt16, timeout: TimeInterval, maxReply: Int) throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        #if canImport(Darwin)
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #else
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard fd >= 0 else { throw BlenderError.notConnected }
        defer { close(fd) }
        #if canImport(Darwin)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif

        var addr = sockaddr_in()
        #if canImport(Darwin)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = in_addr_t(0x7F00_0001).bigEndian // 127.0.0.1, always
        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard rc == 0 else { throw BlenderError.notConnected }

        // Write it all.
        var sent = 0
        try body.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            while sent < raw.count {
                guard try wait(fd, events: Int16(POLLOUT), until: deadline) else { throw BlenderError.timedOut }
                #if canImport(Darwin)
                let n = Darwin.send(fd, base + sent, raw.count - sent, 0)
                #else
                let n = Glibc.send(fd, base + sent, raw.count - sent, Int32(MSG_NOSIGNAL))
                #endif
                if n < 0 {
                    if errno == EINTR || errno == EAGAIN { continue }
                    throw BlenderError.notConnected
                }
                sent += n
            }
        }

        // Read until the bytes parse as one JSON object.
        var buf = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            guard try wait(fd, events: Int16(POLLIN), until: deadline) else { throw BlenderError.timedOut }
            let n = chunk.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            if n < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                throw BlenderError.notConnected
            }
            if n == 0 {
                if isComplete(buf) { return buf }
                throw buf.isEmpty ? BlenderError.notConnected : BlenderError.badReply("connection closed mid-reply")
            }
            buf.append(contentsOf: chunk[0..<n])
            if buf.count > maxReply { throw BlenderError.badReply("reply too large") }
            if isComplete(buf) { return buf }
        }
    }

    /// poll() until ready or the deadline; false on timeout.
    private static func wait(_ fd: Int32, events: Int16, until deadline: Date) throws -> Bool {
        while true {
            let left = deadline.timeIntervalSinceNow
            if left <= 0 { return false }
            var p = pollfd(fd: fd, events: events, revents: 0)
            let r = poll(&p, 1, Int32(min(left, 1) * 1000) + 1)
            if r > 0 { return true }
            if r < 0, errno != EINTR { throw BlenderError.notConnected }
        }
    }
}
