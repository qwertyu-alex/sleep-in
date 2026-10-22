import Darwin
import Foundation

/// The timer's state, shared as JSON with the app, other commands, and `state.json`.
struct TimerState: Codable, Equatable {
    var status: String
    var deadline: Double?
    var dryRun: Bool?
    var lidClosed: Bool?
    var lidAwake: Bool?
    var message: String?

    enum CodingKeys: String, CodingKey {
        case status, deadline, message
        case dryRun = "dry_run", lidClosed = "lid_closed", lidAwake = "lid_awake"
    }

    init(status: String, deadline: Double? = nil, dryRun: Bool? = nil, lidClosed: Bool? = nil,
         lidAwake: Bool? = nil, message: String? = nil) {
        self.status = status
        self.deadline = deadline
        self.dryRun = dryRun
        self.lidClosed = lidClosed
        self.lidAwake = lidAwake
        self.message = message
    }

    init(json: Data) throws { self = try JSONDecoder().decode(TimerState.self, from: json) }

    /// One line of JSON, with keys in a fixed order.
    var json: String {
        var fields = ["\"status\": \(jsonString(status))"]
        if let deadline { fields.append("\"deadline\": \(deadline)") }
        if let dryRun { fields.append("\"dry_run\": \(dryRun)") }
        if let lidClosed { fields.append("\"lid_closed\": \(lidClosed)") }
        if let lidAwake { fields.append("\"lid_awake\": \(lidAwake)") }
        if let message { fields.append("\"message\": \(jsonString(message))") }
        return "{" + fields.joined(separator: ", ") + "}"
    }
}

func jsonString(_ text: String) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed, .withoutEscapingSlashes]),
           as: UTF8.self)
}

enum Duration {
    static let maximum = 604800.0

    /// Seconds in a duration such as 45m, 1h, 1h30m, or 1.5h.
    static func parse(_ value: String) throws -> Double {
        let compact = value.lowercased().filter { !$0.isWhitespace }
        guard compact.wholeMatch(of: try! Regex("(?:[0-9]+(?:\\.[0-9]+)?[hms])+")) != nil else {
            throw TimerError("Use units, such as 45m, 1h, or 1h30m.")
        }
        var seconds = 0.0
        for match in compact.matches(of: try! Regex("([0-9]+(?:\\.[0-9]+)?)([hms])")) {
            let number = Double(match.output[1].substring!)!
            seconds += number * ["h": 3600, "m": 60, "s": 1][String(match.output[2].substring!)]!
        }
        guard seconds.isFinite, seconds >= 1, seconds <= maximum else {
            throw TimerError("Choose a duration from 1 second to 7 days.")
        }
        return seconds
    }
}

private let clock: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "EEE HH:mm:ss"
    return formatter
}()

/// What the timer is doing, in one line, such as "Mac sleeps at Fri 01:30:00 (1h 47m 12s remaining)."
func describe(_ state: TimerState, now: Double = Date().timeIntervalSince1970) -> String {
    guard state.status == "running", let deadline = state.deadline else { return state.message ?? "" }
    let remaining = max(0, Int((deadline - now).rounded(.up)))
    let end = clock.string(from: Date(timeIntervalSince1970: deadline))
    let action = state.dryRun == true ? "Dry run ends" : "Mac sleeps"
    var lid = ""
    if state.lidClosed == true {
        lid = state.lidAwake == true ? " Lid closed: awake on charger." : " Lid closed: connect charger to stay awake."
    }
    return "\(action) at \(end) (\(remaining / 3600)h \(remaining % 3600 / 60)m \(remaining % 60)s remaining)." + lid
}

/// Where the timer keeps its state, control socket, and lock.
struct TimerPaths {
    let root: URL
    var socket: String { root.appendingPathComponent("timer.sock").path }
    var state: URL { root.appendingPathComponent("state.json") }
    var lock: String { root.appendingPathComponent("control.lock").path }

    static var standard: TimerPaths {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        return TimerPaths(root: URL(fileURLWithPath: home).appendingPathComponent(".local/share/sleep-in"))
    }

    /// Creates the directory, private to this user.
    func prepare() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard chmod(root.path, 0o700) == 0 else { throw systemError("Couldn't secure \(root.path)") }
    }

    /// Replaces the saved state in one step, so readers never see half a file.
    func save(_ state: TimerState) throws {
        let temporary = root.appendingPathComponent("state.tmp")
        try Data((state.json + "\n").utf8).write(to: temporary)
        guard rename(temporary.path, self.state.path) == 0 else { throw systemError("Couldn't save the timer state") }
    }

    func load() throws -> TimerState? {
        guard FileManager.default.fileExists(atPath: state.path) else { return nil }
        return try TimerState(json: Data(contentsOf: state))
    }

    /// Takes the lock that keeps two commands from starting competing timers.
    func lockControl() throws -> Int32 {
        let fd = open(lock, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw systemError("Couldn't open \(lock)") }
        while flock(fd, LOCK_EX) != 0 {
            guard errno == EINTR else {
                close(fd)
                throw systemError("Couldn't lock \(lock)")
            }
        }
        return fd
    }

    /// Sends a command to the running timer and returns its state, or nil if no timer is running.
    func request(_ command: String) throws -> TimerState? {
        guard let connection = try UnixSocket.connect(to: socket) else { return nil }
        defer { connection.close() }
        connection.setTimeout(3)
        try connection.send(Data(command.utf8))
        return try TimerState(json: connection.receive(limit: 8192))
    }
}

private var stopSignal: sig_atomic_t = 0

/// Ctrl+C, closing the terminal, and `kill` all cancel the timer cleanly.
func catchStopSignals() {
    for number in [SIGTERM, SIGINT, SIGHUP] {
        signal(number) { _ in stopSignal = 1 }
    }
}

/// Everything the timer needs from macOS, replaceable in tests.
struct TimerSystem {
    var keepAwake: () throws -> ChildProcess = {
        // -w releases the assertion even if this process is killed unexpectedly.
        try Spawned("/usr/bin/caffeinate", ["-i", "-s", "-w", String(getpid())])
    }
    var requestSleep: () throws -> Void = requestSystemSleep
    var lidSession: (String?) -> LidSessionProtocol = { LidSession(helper: $0) }
    var catchSignals: () -> Void = catchStopSignals
    var write: (String) -> Void = { text in
        fputs(text, stdout)
        fflush(stdout)
    }
    var isTerminal = isatty(STDOUT_FILENO) == 1
    var parentPID: () -> pid_t = getppid
}

struct TimerOptions {
    var seconds: Double
    var dryRun = false
    var json = false
    /// The app that started this timer; the timer stops if it goes away.
    var parentPID: pid_t?
    var lidClosed = false
    var lidHelper: String?
}

private let cancelledMessage = "Timer cancelled. Normal sleep settings restored."

/// Keeps the Mac awake until the deadline, answering other commands, then requests sleep.
/// Sleep settings are restored on every path out, including errors.
func runTimer(_ options: TimerOptions, paths: TimerPaths, lock: Int32, system: TimerSystem = TimerSystem()) throws {
    let now = { Date().timeIntervalSince1970 }
    var state = TimerState(status: "running", deadline: now() + options.seconds, dryRun: options.dryRun,
                           lidClosed: options.lidClosed, lidAwake: false)
    var server: UnixSocket?
    var stopping = false
    var lid: LidSessionProtocol?
    var awake: ChildProcess?
    func cancelled() -> Bool {
        stopping || stopSignal != 0 || options.parentPID.map { system.parentPID() != $0 } ?? false
    }
    func report() {
        system.write((options.json ? state.json : describe(state)) + "\n")
    }

    system.catchSignals()
    var failure: Error?
    do {
        awake = try system.keepAwake()
        if options.lidClosed {
            if !options.json {
                system.write("Approve with Touch ID or your password to allow lid-closed use on the charger.\n")
            }
            let session = system.lidSession(options.lidHelper)
            lid = session
            if try !session.start(cancelled: cancelled) { stopping = true }
        }
        // Authorization time is not deducted from the countdown.
        state.deadline = now() + options.seconds
        if let lid, !cancelled() {
            state.lidAwake = try lid.update(deadline: state.deadline!)
        }
        unlink(paths.socket)
        server = try UnixSocket.listen(at: paths.socket, backlog: 4)
        try paths.save(state)
        flock(lock, LOCK_UN)
        report()
        if !options.json { system.write("Keep this terminal open. Press Ctrl+C to cancel.\n") }
        var lastDisplay: String?
        while !stopping && now() < state.deadline! {
            if cancelled() {
                stopping = true
                break
            }
            // Each update is also the heartbeat that keeps the helper's override alive.
            if let lid {
                let lidAwake = try lid.update(deadline: state.deadline!)
                if lidAwake != state.lidAwake {
                    state.lidAwake = lidAwake
                    try paths.save(state)
                    if options.json { report() }
                }
            }
            let display = describe(state)
            if !options.json && system.isTerminal && display != lastDisplay {
                system.write("\r\u{1B}[2K" + display)
                lastDisplay = display
            }
            if !awake!.isRunning { throw TimerError("The macOS keep-awake process stopped unexpectedly.") }
            guard let connection = try server!.accept(timeout: 0.2) else { continue }
            defer { connection.close() }
            connection.setTimeout(1)
            // A misbehaving client only loses its own reply.
            do {
                guard let command = String(data: try connection.receive(limit: 64), encoding: .utf8) else { continue }
                if command == "cancel" {
                    stopping = true
                    state.status = "cancelled"
                    state.message = cancelledMessage
                    try paths.save(state)
                } else if command.hasPrefix("extend ") {
                    let words = command.split(whereSeparator: \.isWhitespace)
                    guard words.count > 1, let extra = Double(words[1]) else { continue }
                    if extra.isFinite && extra > 0 {
                        state.deadline = min(state.deadline! + extra, now() + Duration.maximum)
                        try paths.save(state)
                        if options.json { report() }
                    }
                }
                try connection.send(Data(state.json.utf8))
            } catch {}
        }
        if cancelled() { stopping = true }
        // Restore sleep before requesting it, including while the lid is closed.
        if let session = lid {
            try session.close()
            lid = nil
            state.lidAwake = false
        }
        if stopping {
            state.status = "cancelled"
            state.message = cancelledMessage
        } else if options.dryRun {
            state.status = "completed"
            state.message = "Dry run completed. No sleep command was sent."
        } else {
            state.status = "completed"
            state.message = "Timer expired; sleep requested from macOS."
            try paths.save(state)
            try system.requestSleep()
        }
        try paths.save(state)
    } catch {
        state.status = "failed"
        state.message = "Timer failed: \(error.localizedDescription)"
        try? paths.save(state)
        failure = error
    }

    server?.close()
    // A failed restoration is retried here; that failure is the one to report.
    var cleanupFailure: Error?
    if let lid {
        do { try lid.close() } catch { cleanupFailure = error }
    }
    if let awake {
        if awake.isRunning { awake.terminate() }
        awake.wait()
    }
    unlink(paths.socket)
    if let error = cleanupFailure ?? failure { throw error }
    if !options.json && system.isTerminal { system.write("\r\u{1B}[2K") }
    report()
}
