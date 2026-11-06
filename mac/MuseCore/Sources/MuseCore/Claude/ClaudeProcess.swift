import Foundation

/// A running Claude Code process.
public protocol ClaudeProcessHandle: AnyObject, Sendable {
    var isRunning: Bool { get }
    /// SIGINT: Claude Code ends the turn cleanly.
    func interrupt()
    /// SIGTERM.
    func terminate()
}

/// Starts Claude Code for one turn: writes `stdin` and closes it, hands each stdout line to `onLine`, then calls `onExit`
/// with the exit code and stderr once stdout is drained and the process is gone.
public protocol ClaudeLauncher: Sendable {
    func launch(executable: String, arguments: [String], cwd: URL, environment: [String: String], stdin: String,
                onLine: @escaping @Sendable (String) -> Void, onExit: @escaping @Sendable (Int32, String) -> Void) throws -> any ClaudeProcessHandle
}

/// Foundation's Process (macOS and Linux).
public struct ProcessLauncher: ClaudeLauncher {
    public init() {}

    public func launch(executable: String, arguments: [String], cwd: URL, environment: [String: String], stdin: String,
                       onLine: @escaping @Sendable (String) -> Void, onExit: @escaping @Sendable (Int32, String) -> Void) throws -> any ClaudeProcessHandle {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        p.currentDirectoryURL = cwd
        p.environment = environment
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe
        try p.run()
        let handle = ProcessHandle(p)
        // stdin: one line, then EOF.
        DispatchQueue.global().async {
            let w = inPipe.fileHandleForWriting
            w.write(Data(stdin.utf8))
            try? w.close()
        }
        let errBox = ErrBuffer()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            let r = errPipe.fileHandleForReading
            while true {
                let d = r.availableData
                if d.isEmpty { break }
                errBox.append(d)
            }
            group.leave()
        }
        DispatchQueue.global().async {
            let r = outPipe.fileHandleForReading
            var buf = Data()
            while true {
                let d = r.availableData
                if d.isEmpty { break }
                buf.append(d)
                while let nl = buf.firstIndex(of: 0x0A) {
                    let line = buf[buf.startIndex..<nl]
                    onLine(String(decoding: line, as: UTF8.self))
                    buf.removeSubrange(buf.startIndex...nl)
                }
            }
            if !buf.isEmpty { onLine(String(decoding: buf, as: UTF8.self)) }
            group.wait()
            p.waitUntilExit()
            onExit(p.terminationStatus, errBox.text)
        }
        return handle
    }

    final class ErrBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ d: Data) {
            lock.lock()
            // Only the tail matters (the last line names the problem).
            data.append(d)
            if data.count > 64 * 1024 { data = data.suffix(32 * 1024) }
            lock.unlock()
        }
        var text: String {
            lock.lock()
            defer { lock.unlock() }
            return String(decoding: data, as: UTF8.self)
        }
    }

    final class ProcessHandle: ClaudeProcessHandle, @unchecked Sendable {
        private let p: Process
        init(_ p: Process) { self.p = p }
        var isRunning: Bool { p.isRunning }
        func interrupt() { if p.isRunning { p.interrupt() } }
        func terminate() { if p.isRunning { p.terminate() } }
    }
}

/// Runs a short command (`claude --version`, `claude auth status`) and returns its exit code and output.
public enum ClaudeShell {
    public struct Result: Sendable, Equatable {
        public var status: Int32
        public var stdout: String
        public var stderr: String
    }

    public static func run(_ executable: String, _ arguments: [String], environment: [String: String]? = nil, timeout: Double = 15) async -> Result? {
        await withCheckedContinuation { (cont: CheckedContinuation<Result?, Never>) in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: executable)
                p.arguments = arguments
                if let environment { p.environment = environment }
                let out = Pipe(), err = Pipe()
                p.standardOutput = out
                p.standardError = err
                p.standardInput = FileHandle.nullDevice
                do { try p.run() } catch {
                    cont.resume(returning: nil)
                    return
                }
                let deadline = DispatchTime.now() + timeout
                DispatchQueue.global().asyncAfter(deadline: deadline) { if p.isRunning { p.terminate() } }
                let errBox = ProcessLauncher.ErrBuffer()
                let g = DispatchGroup()
                g.enter()
                DispatchQueue.global().async {
                    errBox.append(err.fileHandleForReading.readDataToEndOfFile())
                    g.leave()
                }
                let outData = out.fileHandleForReading.readDataToEndOfFile()
                g.wait()
                p.waitUntilExit()
                cont.resume(returning: Result(status: p.terminationStatus, stdout: String(decoding: outData, as: UTF8.self), stderr: errBox.text))
            }
        }
    }

    /// Install and sign-in state: `claude --version`, then `claude auth status`.
    public static func probe(executable: String?, environment: [String: String]) async -> ClaudeCodeInfo {
        guard let executable else { return ClaudeCodeInfo() }
        guard let v = await run(executable, ["--version"], environment: environment), v.status == 0 else {
            return ClaudeCodeInfo(installed: false)
        }
        let version = ClaudeCodeLocator.version(v.stdout)
        guard let a = await run(executable, ["auth", "status"], environment: environment) else {
            return ClaudeCodeInfo(installed: true, signedIn: false, version: version)
        }
        return ClaudeCodeInfo(installed: true, signedIn: ClaudeCodeLocator.auth(exitCode: a.status, output: a.stdout).signedIn, version: version)
    }
}
