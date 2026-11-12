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
    /// Port 9876 answers, but not with the MCP for Blender protocol. Seen in the wild: Blender's official MCP add-on
    /// (Blender Lab, same default port) ends each reply with a NUL byte and evicts clients after 10 s, which the
    /// `uvx mcp-for-blender` server reports as "Incomplete JSON response received".
    case otherServer

    public var errorDescription: String? {
        switch self {
        case .notConnected: return "Blender isn't connected (open Blender and start the MCP add-on's server on port 9876)"
        case .timedOut: return "Blender didn't answer in time"
        case .otherServer: return BlenderError.otherServerText
        case .command(let m): return "Blender: \(m)"
        case .badReply(let m): return "Unexpected reply from Blender (\(m))"
        }
    }

    public static let otherServerText = "Another program is using Blender's port 9876, not the MCP for Blender add-on. "
        + "Most likely Blender's official MCP add-on (Blender Lab): turn it off in Blender → Preferences → Add-ons, restart Blender, "
        + "then press Start MCP Server in the MCP for Blender panel (N sidebar)."

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
        if case .string(let m)? = o["message"] {
            // Blender Lab's MCP add-on: its words, not MCP for Blender's ("Unknown command type: …").
            if m == "Client timed out" || m.hasPrefix("Unknown request type") { throw BlenderError.otherServer }
            throw BlenderError.command(BlenderError.shortMessage(m))
        }
        throw BlenderError.badReply("no status")
    }

    /// True once the bytes so far are one complete JSON object.
    static func isComplete(_ buf: Data) -> Bool {
        var r = ReplyReader(maxReply: Int.max)
        if case .done? = try? r.feed(buf) { return true }
        return false
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

        // Read until the braces close (the add-on sends no framing), then parse once.
        var reader = ReplyReader(maxReply: maxReply)
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            guard try wait(fd, events: Int16(POLLIN), until: deadline) else { throw BlenderError.timedOut }
            let n = chunk.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            if n < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                throw BlenderError.notConnected
            }
            if n == 0 { return try reader.finish() }
            if case .done(let reply) = try reader.feed(Data(chunk[0..<n])) { return reply }
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

/// Reads one unframed JSON object from a byte stream, chunk by chunk, in linear time: it tracks brace depth outside
/// strings (UTF-8 continuation bytes are never `"`, `\\`, `{` or `}`), and parses once when the top-level object closes.
struct ReplyReader {
    enum Step: Equatable { case needMore, done(Data) }

    let maxReply: Int
    private(set) var buffer = Data()
    private var depth = 0
    private var started = false
    private var inString = false
    private var escaped = false

    init(maxReply: Int) { self.maxReply = maxReply }

    /// Adds bytes; `.done(object)` once they hold one complete JSON object. Only the new bytes are scanned.
    mutating func feed(_ bytes: Data) throws -> Step {
        let start = buffer.count
        buffer.append(bytes)
        if buffer.count > maxReply { throw BlenderError.badReply("reply over \(maxReply / 1_048_576) MB") }
        var end: Int?
        for (i, b) in bytes.enumerated() {
            // JSON never carries a raw NUL; a NUL-terminated reply is another MCP server's protocol.
            if b == 0 { throw BlenderError.otherServer }
            if end != nil { continue } // past the object: only look for that NUL
            if !started {
                if b == 0x20 || b == 0x0A || b == 0x0D || b == 0x09 { continue }
                guard b == UInt8(ascii: "{") else { throw BlenderError.badReply("not a JSON object: \(preview)") }
                started = true
                depth = 1
                continue
            }
            if inString {
                if escaped { escaped = false } else if b == UInt8(ascii: "\\") { escaped = true } else if b == UInt8(ascii: "\"") { inString = false }
                continue
            }
            switch b {
            case UInt8(ascii: "\""): inString = true
            case UInt8(ascii: "{"), UInt8(ascii: "["): depth += 1
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                depth -= 1
                if depth == 0 { end = start + i + 1 }
            default: break
            }
        }
        guard let end else { return .needMore }
        let reply = buffer.prefix(end)
        guard (try? JSONSerialization.jsonObject(with: reply)) != nil else { throw BlenderError.badReply("not valid JSON: \(preview)") }
        return .done(Data(reply))
    }

    /// The connection closed: an empty stream means nobody answered; a partial object says how much arrived.
    func finish() throws -> Data {
        if buffer.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { throw BlenderError.notConnected }
        throw BlenderError.badReply("connection closed mid-reply after \(buffer.count) bytes")
    }

    private var preview: String { String(decoding: buffer.prefix(80), as: UTF8.self) }
}
