import Darwin
import Foundation

/// The timer's side of a lid-closed session; replaceable in tests.
protocol LidSessionProtocol: AnyObject {
    /// Waits for Touch ID and the helper. False if the timer was cancelled first.
    func start(cancelled: () -> Bool) throws -> Bool
    /// Sends the deadline as a heartbeat; true while the lid may be closed.
    func update(deadline: Double) throws -> Bool
    /// Has the helper restore sleep, and confirms it did.
    func close() throws
}

/// A connection to the helper; replaceable in tests.
protocol LidConnection: AnyObject {
    func send(_ data: Data) throws
    /// Empty once the helper has disconnected.
    func receive() throws -> Data
    func close()
}

extension UnixSocket: LidConnection {
    func receive() throws -> Data { try receive(limit: 1024) }
}

/// A Touch ID-approved session with Sleep In's root daemon; the timer stays unprivileged.
final class LidSession: LidSessionProtocol {
    typealias Launch = (_ client: String, _ socketPath: String, _ output: Int32) throws -> ChildProcess

    let helper: String
    private let launch: Launch
    var connection: LidConnection?
    var process: ChildProcess?
    private var listener: UnixSocket?
    private var directory: String?
    private var diagnostics: Capture?
    private var buffer = Data()

    init(helper: String? = nil, launch: @escaping Launch = { try Spawned($0, [$1], output: $2) }) {
        self.helper = helper ?? LidSession.bundledClient
        self.launch = launch
    }

    /// The Touch ID client that ships beside this command in the app.
    static var bundledClient: String {
        let command = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        return command.resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent("SleepInLidClient").path
    }

    func start(cancelled: () -> Bool) throws -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: helper, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw TimerError("Lid-closed mode needs the sleep-in command from the Sleep In app.")
        }
        // /tmp keeps the socket path below macOS's 104-byte limit.
        var template = Array("/tmp/sleep-in-lid-XXXXXX".utf8CString)
        // mkdtemp fills in the template; read the name from the array, which is still alive.
        guard template.withUnsafeMutableBufferPointer({ mkdtemp($0.baseAddress!) }) != nil else {
            throw systemError("Couldn't create a temporary folder")
        }
        let directory = String(cString: template)
        self.directory = directory
        let path = directory + "/helper.sock"
        let listener = try UnixSocket.listen(at: path, backlog: 1)
        self.listener = listener
        let diagnostics = try Capture()
        self.diagnostics = diagnostics
        // The signed client asks for Touch ID, then the daemon connects here before the client exits.
        let process = try launch(helper, path, diagnostics.fd)
        self.process = process
        let limit = ProcessInfo.processInfo.systemUptime + 120
        while !cancelled() {
            // Checked before accepting, so a connection made just before the client exited still counts.
            let exited = !process.isRunning
            guard let connection = try listener.accept(timeout: 0.2) else {
                if exited {
                    let detail = diagnostics.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    throw TimerError(detail.isEmpty ? "Could not start lid-closed mode." : String(detail.suffix(500)))
                }
                if ProcessInfo.processInfo.systemUptime >= limit {
                    throw TimerError("Approval timed out. Please start the timer again.")
                }
                continue
            }
            // Only the privileged daemon can acknowledge that sleep was changed.
            guard connection.peerUID == 0 else {
                connection.close()
                continue
            }
            connection.setTimeout(8)
            self.connection = connection
            guard jsonBool(try receive()["ready"]) == true else {
                throw TimerError("The lid-closed helper did not become ready.")
            }
            return true
        }
        return false
    }

    private func receive() throws -> [String: Any] {
        guard let connection else { throw TimerError("The lid-closed helper is not connected.") }
        while !buffer.contains(10) {
            let chunk = try connection.receive()
            guard !chunk.isEmpty else { throw TimerError("The lid-closed helper disconnected unexpectedly.") }
            buffer.append(chunk)
            guard buffer.count <= 4096 else { throw TimerError("Invalid response from the lid-closed helper.") }
        }
        let newline = buffer.firstIndex(of: 10)!
        let line = Data(buffer[..<newline])
        buffer = Data(buffer[buffer.index(after: newline)...])
        guard let message = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            throw TimerError("Invalid response from the lid-closed helper.")
        }
        if let error = message["error"] { throw TimerError("\(error)") }
        return message
    }

    private func exchange(_ message: String) throws -> [String: Any] {
        guard let connection else { throw TimerError("The lid-closed helper is not connected.") }
        try connection.send(Data((message + "\n").utf8))
        return try receive()
    }

    func update(deadline: Double) throws -> Bool {
        guard let lidAwake = jsonBool(try exchange("{\"deadline\": \(deadline)}")["lid_awake"]) else {
            throw TimerError("The lid-closed helper did not confirm its power state.")
        }
        return lidAwake
    }

    func close() throws {
        var failure: Error?
        if connection != nil {
            do {
                guard jsonBool(try exchange("{\"stop\": true}")["released"]) == true else {
                    throw TimerError("The lid-closed helper did not confirm sleep restoration.")
                }
            } catch {
                failure = error
            }
        }
        connection?.close() // EOF also makes the independent daemon restore sleep.
        connection = nil
        listener?.close()
        listener = nil
        if let process {
            // A client still running is only waiting for Touch ID; the daemon does the restoring.
            if process.isRunning { process.terminate() }
            process.wait()
            self.process = nil
        }
        if let directory {
            try? FileManager.default.removeItem(atPath: directory)
            self.directory = nil
        }
        diagnostics = nil
        if let failure {
            throw TimerError("Could not confirm normal sleep settings: \(failure.localizedDescription)")
        }
    }
}

/// A JSON true or false; numbers such as 1 don't count.
func jsonBool(_ value: Any?) -> Bool? {
    guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
    return number.boolValue
}
