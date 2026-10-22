import Darwin
import Foundation

private var failures = 0

private func check(_ condition: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
    if !condition() {
        failures += 1
        print("FAIL line \(line): \(message)")
    }
}

/// Runs `body` and checks that it fails with a message matching `pattern`.
private func checkThrows(_ pattern: String, line: Int = #line, _ body: () throws -> Void) {
    do {
        try body()
        check(false, "expected an error matching \(pattern)", line: line)
    } catch {
        let text = (error as? UsageError)?.message ?? error.localizedDescription
        check(text.range(of: pattern, options: .regularExpression) != nil, "unexpected error: \(text)", line: line)
    }
}

private func temporaryDirectory() -> String {
    var template = Array("/tmp/sleep-in-test-XXXXXX".utf8CString)
    _ = template.withUnsafeMutableBufferPointer { mkdtemp($0.baseAddress!)! }
    return String(cString: template)
}

private final class Events {
    var list: [String] = []
}

private final class FakeProcess: ChildProcess {
    var running: Bool
    var terminated = 0
    var onTerminate: () -> Void = {}
    init(running: Bool) { self.running = running }
    var isRunning: Bool { running }
    func terminate() {
        terminated += 1
        onTerminate()
    }
    func wait() {}
}

private final class FakeLid: LidSessionProtocol {
    let events: Events
    var ready = true
    var startError: Error?
    var updateError: Error?
    var closeError: Error?
    init(_ events: Events) { self.events = events }

    func start(cancelled: () -> Bool) throws -> Bool {
        events.list.append("authorize")
        if let startError { throw startError }
        return ready
    }

    func update(deadline: Double) throws -> Bool {
        if let updateError { throw updateError }
        events.list.append("charger checked")
        return true
    }

    func close() throws {
        events.list.append("sleep restored")
        if let closeError { throw closeError }
    }
}

private final class FakeConnection: LidConnection {
    var replies: [String]
    var sent: [String] = []
    var closed = 0
    init(_ replies: [String]) { self.replies = replies }
    func send(_ data: Data) throws { sent.append(String(decoding: data, as: UTF8.self)) }
    func receive() throws -> Data { replies.isEmpty ? Data() : Data(replies.removeFirst().utf8) }
    func close() { closed += 1 }
}

/// A short lid-closed timer with fake system calls; returns what happened, in order.
private func runFakeTimer(dryRun: Bool = false, configure: (FakeLid) -> Void = { _ in }) -> (events: [String], state: TimerState?, error: Error?) {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let paths = TimerPaths(root: URL(fileURLWithPath: directory))
    let events = Events()
    let lid = FakeLid(events)
    configure(lid)
    var system = TimerSystem()
    system.keepAwake = {
        let awake = FakeProcess(running: true)
        awake.onTerminate = { events.list.append("caffeinate released") }
        return awake
    }
    system.requestSleep = { events.list.append("sleep requested") }
    system.lidSession = { _ in lid }
    system.catchSignals = {}
    system.write = { _ in }
    system.isTerminal = false
    let lock = open(directory + "/lock", O_CREAT | O_WRONLY, 0o600)
    defer { close(lock) }
    var failure: Error?
    do {
        try runTimer(TimerOptions(seconds: 0.02, dryRun: dryRun, json: true, lidClosed: true), paths: paths, lock: lock, system: system)
    } catch {
        failure = error
    }
    return (events.list, try? paths.load(), failure)
}

private struct Failure: LocalizedError {
    let errorDescription: String?
    init(_ text: String) { errorDescription = text }
}

private func timerTests() {
    // Restores sleep before requesting it.
    var run = runFakeTimer()
    check(run.error == nil, "timer failed: \(String(describing: run.error))")
    if let restored = run.events.firstIndex(of: "sleep restored"), let requested = run.events.firstIndex(of: "sleep requested") {
        check(restored < requested, "sleep must be restored before it is requested: \(run.events)")
    } else {
        check(false, "missing restore or sleep request: \(run.events)")
    }
    check(run.state?.status == "completed" && run.state?.lidAwake == false, "unexpected final state: \(String(describing: run.state))")

    // A dry run restores sleep without requesting it.
    run = runFakeTimer(dryRun: true)
    check(run.events.contains("sleep restored") && !run.events.contains("sleep requested"), "dry run: \(run.events)")

    // Cancelling during authorization starts nothing.
    run = runFakeTimer { $0.ready = false }
    check(!run.events.contains("charger checked") && !run.events.contains("sleep requested"), "cancelled: \(run.events)")
    check(run.state?.status == "cancelled", "cancelled state: \(String(describing: run.state))")

    // A failed authorization releases everything.
    run = runFakeTimer { $0.startError = Failure("denied") }
    check(run.error?.localizedDescription == "denied", "authorization error: \(String(describing: run.error))")
    check(run.events.contains("sleep restored") && run.events.contains("caffeinate released"), "authorization cleanup: \(run.events)")
    check(!run.events.contains("sleep requested"), "authorization failure requested sleep")

    // A disconnected helper fails without a sleep request.
    run = runFakeTimer { $0.updateError = Failure("disconnected") }
    check(run.error?.localizedDescription == "disconnected", "disconnect error: \(String(describing: run.error))")
    check(run.events.contains("sleep restored") && run.events.contains("caffeinate released"), "disconnect cleanup: \(run.events)")
    check(!run.events.contains("sleep requested"), "disconnect requested sleep")

    // A failed restoration blocks the final sleep request.
    run = runFakeTimer { $0.closeError = Failure("restore failed") }
    check(run.error?.localizedDescription == "restore failed", "restore error: \(String(describing: run.error))")
    check(run.events.contains("caffeinate released") && !run.events.contains("sleep requested"), "restore failure: \(run.events)")
    check(run.state?.status == "failed", "restore failure state: \(String(describing: run.state))")
}

private func connected(_ replies: [String]) -> (LidSession, FakeConnection, FakeProcess) {
    let session = LidSession(helper: "/nonexistent")
    let connection = FakeConnection(replies)
    let process = FakeProcess(running: false) // The client exits once the daemon has connected.
    session.connection = connection
    session.process = process
    return (session, connection, process)
}

private func lidSessionTests() {
    // Status and release require acknowledgments.
    var (session, connection, process) = connected(["{\"lid_awake\": true}\n", "{\"released\": true}\n"])
    check((try? session.update(deadline: 123)) == true, "update should report lid_awake")
    check((try? session.close()) != nil, "close should succeed")
    let sent = connection.sent.compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? NSDictionary }
    check(sent == [["deadline": 123], ["stop": true]], "sent: \(connection.sent)")
    check(process.terminated == 0 && connection.closed == 1, "an exited client must not be terminated")

    // A release failure is reported.
    (session, connection, _) = connected(["{\"error\": \"powerd unavailable\"}\n"])
    checkThrows("powerd unavailable") { try session.close() }
    check(connection.closed == 1, "connection must close after a failed release")

    // End of file and unconfirmed power states are rejected.
    for reply in ["", "{\"ready\": true}\n", "{\"lid_awake\": 1}\n"] {
        (session, _, _) = connected([reply])
        checkThrows(".") { _ = try session.update(deadline: 123) }
    }

    // Cancelling a pending Touch ID prompt terminates the client.
    let pending = LidSession(helper: "/nonexistent")
    let client = FakeProcess(running: true)
    pending.process = client
    try? pending.close()
    check(client.terminated == 1, "pending client must be terminated")

    // A client failure is reported with the client's own message.
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let helper = directory + "/client"
    FileManager.default.createFile(atPath: helper, contents: Data())
    var launched: [String] = []
    let failing = LidSession(helper: helper) { client, socket, output in
        launched = [client, socket]
        let text = "Approval was cancelled. No lid-closed session was started.\n"
        _ = text.withCString { write(output, $0, strlen($0)) }
        return FakeProcess(running: false)
    }
    checkThrows("^Approval was cancelled") { _ = try failing.start(cancelled: { false }) }
    check(launched.first == helper, "client path: \(launched)")
    check(launched.last.map { $0.hasPrefix("/tmp/sleep-in-lid-") && $0.hasSuffix("/helper.sock") } == true, "socket path: \(launched)")
    try? failing.close()
}

private func durationTests() {
    for (text, seconds) in [("1h30m", 5400.0), (" 1H 30M ", 5400), ("1.5h", 5400), ("45s", 45), ("168h", 604800)] {
        check((try? Duration.parse(text)) == seconds, "\(text) should be \(seconds) seconds")
    }
    checkThrows("^Use units") { _ = try Duration.parse("90") }
    checkThrows("^Use units") { _ = try Duration.parse("8d") }
    checkThrows("^Choose a duration") { _ = try Duration.parse("0s") }
    checkThrows("^Choose a duration") { _ = try Duration.parse("169h") }
}

private func describeTests() {
    var state = TimerState(status: "running", deadline: 10000, dryRun: false, lidClosed: false, lidAwake: false)
    let text = describe(state, now: 10000 - 6431.5)
    check(text.hasPrefix("Mac sleeps at ") && text.hasSuffix(" (1h 47m 12s remaining)."), text)
    state.dryRun = true
    state.lidClosed = true
    check(describe(state, now: 20000).hasPrefix("Dry run ends at ") && describe(state, now: 20000).hasSuffix("(0h 0m 0s remaining). Lid closed: connect charger to stay awake."),
          describe(state, now: 20000))
    state.lidAwake = true
    check(describe(state, now: 0).hasSuffix(" Lid closed: awake on charger."), describe(state, now: 0))
    check(describe(TimerState(status: "cancelled", message: "Done.")) == "Done.", "finished timers show their message")
}

private func stateTests() {
    let state = TimerState(status: "completed", deadline: 1792700480.940244, dryRun: true, lidClosed: false, lidAwake: false,
                           message: "Say \"hi\"")
    check(state.json == #"{"status": "completed", "deadline": 1792700480.940244, "dry_run": true, "lid_closed": false, "lid_awake": false, "message": "Say \"hi\""}"#,
          state.json)
    check((try? TimerState(json: Data(state.json.utf8))) == state, "state must survive a round trip")
    check(TimerState(status: "inactive", message: "No timer is running.").json == #"{"status": "inactive", "message": "No timer is running."}"#,
          "inactive JSON")
}

private func argumentTests() {
    let parsed = try? Arguments.parse(["2h", "--dry", "--lid-c", "--gui-parent=42", "--state-dir", "/tmp/x", "--lid-helper", "/c"])
    check(parsed == Arguments(action: "2h", dryRun: true, lidClosed: true, lidHelper: "/c", guiParent: 42, stateDirectory: "/tmp/x"),
          String(describing: parsed))
    check((try? Arguments.parse(["status", "-h", "--bogus"]))?.help == true, "help wins once reached")
    check((try? Arguments.parse(["--", "-5m"]))?.action == "-5m", "-- ends options")
    checkThrows("^the following arguments are required: action$") { _ = try Arguments.parse([]) }
    checkThrows("^unrecognized arguments: --bogus 3h$") { _ = try Arguments.parse(["1h", "--bogus", "2h", "3h"]) }
    checkThrows("^ambiguous option: --l could match") { _ = try Arguments.parse(["--l", "1h"]) }
    checkThrows("^argument --gui-parent: expected one argument$") { _ = try Arguments.parse(["1h", "--gui-parent"]) }
    checkThrows("^argument --gui-parent: invalid int value: 'x'$") { _ = try Arguments.parse(["1h", "--gui-parent", "x"]) }
    checkThrows("^argument --json: ignored explicit argument '1'$") { _ = try Arguments.parse(["status", "--json=1"]) }
}

@main
struct TimerTests {
    static func main() {
        timerTests()
        lidSessionTests()
        durationTests()
        describeTests()
        stateTests()
        argumentTests()
        if failures > 0 {
            print("\(failures) timer checks failed")
            exit(1)
        }
        print("Timer checks passed")
    }
}
