import Darwin
import Foundation
import IOKit.ps

private var interrupted: sig_atomic_t = 0

private struct HelperError: LocalizedError {
    let text: String
    var errorDescription: String? { text }
    init(_ text: String) { self.text = text }
}

private func pmset(_ arguments: [String]) throws -> String {
    let child = Process()
    let output = Pipe()
    child.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    child.arguments = arguments
    child.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
    child.standardInput = FileHandle.nullDevice
    child.standardOutput = output
    child.standardError = output
    try child.run()
    let limit = ProcessInfo.processInfo.systemUptime + 5
    while child.isRunning && ProcessInfo.processInfo.systemUptime < limit { usleep(20_000) }
    if child.isRunning {
        kill(child.processIdentifier, SIGKILL)
        child.waitUntilExit()
        throw HelperError("The macOS power settings command timed out.")
    }
    child.waitUntilExit()
    let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    guard child.terminationStatus == 0 else { throw HelperError("Couldn't change macOS sleep settings: \(text)") }
    return text
}

private func onACPower() -> Bool {
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let source = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
    return source as String == kIOPSACPowerValue
}

private func connectToTimer(path: String, uid: uid_t) throws -> Int32 {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8) + [0]
    guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw HelperError("Timer socket path is too long.") }
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw HelperError("Couldn't create helper connection.") }
    let result = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    var peerUID: uid_t = 0
    var peerGID: gid_t = 0
    guard result == 0, getpeereid(fd, &peerUID, &peerGID) == 0, peerUID == uid else {
        close(fd)
        throw HelperError("Couldn't connect to the user who started the timer.")
    }
    var timeout = timeval(tv_sec: 2, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    return fd
}

private func sendJSON(_ value: [String: Any], to fd: Int32) throws {
    var data = try JSONSerialization.data(withJSONObject: value)
    data.append(10)
    try data.withUnsafeBytes { raw in
        var offset = 0
        while offset < raw.count {
            let sent = send(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset, 0)
            guard sent > 0 else { throw HelperError("Timer connection closed.") }
            offset += sent
        }
    }
}

/// A root-owned journal also recovers an override after a hard-killed helper.
private final class SessionLock {
    let fd: Int32

    init() throws {
        fd = open("/var/run/sleep-in-lid.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw HelperError("Couldn't open the lid-mode lock.") }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == 0,
              info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_mode & 0o077 == 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw HelperError("Another lid-closed session is already running.")
        }
    }

    deinit { close(fd) }

    var hasUnrestoredOverride: Bool {
        var bytes = [UInt8](repeating: 0, count: 16)
        return pread(fd, &bytes, bytes.count, 0) > 0
    }

    func mark(_ owned: Bool) throws {
        guard ftruncate(fd, 0) == 0 else { throw HelperError("Couldn't save the sleep recovery state.") }
        if owned {
            let bytes = Array("owned\n".utf8)
            guard bytes.withUnsafeBytes({ pwrite(fd, $0.baseAddress, $0.count, 0) }) == bytes.count else {
                throw HelperError("Couldn't save the sleep recovery state.")
            }
        }
        guard fsync(fd) == 0 else { throw HelperError("Couldn't save the sleep recovery state.") }
    }
}

/// Runs one timer's session until it stops, disconnects, or misses heartbeats; always restores sleep.
private func serve(_ fd: Int32) throws {
    let lock: SessionLock
    do { lock = try SessionLock() }
    catch {
        try? sendJSON(["error": error.localizedDescription], to: fd)
        throw error
    }
    let policy = LidSleepPolicy { enabled in
        if enabled { try lock.mark(true) }
        _ = try pmset(["-a", "disablesleep", enabled ? "1" : "0"])
        if !enabled { try lock.mark(false) }
    }
    // Keep retrying restoration if powerd is temporarily unavailable.
    defer {
        while true {
            do { try policy.release(); break }
            catch {
                FileHandle.standardError.write(Data(("Retrying sleep restoration: \(error.localizedDescription)\n").utf8))
                usleep(1_000_000)
            }
        }
    }
    do {
        if lock.hasUnrestoredOverride {
            try policy.recoverOwnedOverride()
        }
        let settings = try pmset(["-g"])
        if settings.range(of: #"(?m)^\s*SleepDisabled\s+1\s*$"#, options: .regularExpression) != nil {
            throw HelperError("System sleep is already disabled by another tool. Enable it there before using lid-closed mode.")
        }
        try sendJSON(["ready": true], to: fd)
        var buffer = Data()
        var deadline = 0.0
        var lastHeartbeat = ProcessInfo.processInfo.systemUptime
        while interrupted == 0 {
            // Power monitoring and lease expiry run independently of the app.
            guard ProcessInfo.processInfo.systemUptime - lastHeartbeat < 5 else { break }
            try policy.update(onAC: onACPower(), deadline: deadline, now: Date().timeIntervalSince1970)
            var item = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let result = poll(&item, 1, 200)
            if result < 0 {
                if errno == EINTR { continue }
                throw HelperError("Couldn't monitor the timer connection.")
            }
            if result == 0 { continue }
            var chunk = [UInt8](repeating: 0, count: 1024)
            let count = recv(fd, &chunk, chunk.count, 0)
            if count <= 0 { break }
            buffer.append(contentsOf: chunk.prefix(count))
            guard buffer.count <= 4096 else { throw HelperError("Invalid timer message.") }
            while let newline = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                guard let message = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    throw HelperError("Invalid timer message.")
                }
                if message["stop"] as? Bool == true {
                    try policy.release()
                    try sendJSON(["released": true], to: fd)
                    return
                }
                guard let next = message["deadline"] as? Double, next.isFinite,
                      next > 0, next <= Date().timeIntervalSince1970 + 604801 else {
                    throw HelperError("Invalid timer deadline.")
                }
                deadline = next
                lastHeartbeat = ProcessInfo.processInfo.systemUptime
                try policy.update(onAC: onACPower(), deadline: deadline, now: Date().timeIntervalSince1970)
                try sendJSON(["lid_awake": policy.enabled], to: fd)
            }
        }
    } catch {
        try? sendJSON(["error": error.localizedDescription], to: fd)
        throw error
    }
}

/// launchd starts the daemon on demand; it exits when idle so nothing runs between timers.
private final class Activity {
    private let queue = DispatchQueue(label: "io.github.qwertyu-alex.sleep-in.lid-daemon.activity")
    private var connections = 0
    private var sessions = 0
    private var idleSince = ProcessInfo.processInfo.systemUptime
    private var timer: DispatchSourceTimer?

    func change(connections: Int = 0, sessions: Int = 0) {
        queue.sync {
            self.connections += connections
            self.sessions += sessions
            idleSince = ProcessInfo.processInfo.systemUptime
        }
    }

    func exitWhenIdle() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [unowned self] in
            // Sessions always finish restoring sleep first, including after SIGTERM.
            guard sessions == 0 else { return }
            if interrupted != 0 || (connections == 0 && ProcessInfo.processInfo.systemUptime - idleSince >= 10) {
                exit(0)
            }
        }
        timer.resume()
        self.timer = timer
    }
}

private let activity = Activity()

private final class Service: NSObject, SleepInLidService {
    private let uid: uid_t

    init(uid: uid_t) { self.uid = uid }

    func ping(reply: @escaping (Bool) -> Void) { reply(true) }

    func startSession(socketPath: String, reply: @escaping (String?) -> Void) {
        guard uid != 0 else { return reply("Start lid-closed mode as your own user, not as root.") }
        guard interrupted == 0 else { return reply("Sleep In's helper is shutting down. Please try again.") }
        do {
            // Connect before replying, so the timer can already accept when the client exits.
            let fd = try connectToTimer(path: socketPath, uid: uid)
            activity.change(sessions: 1)
            Thread.detachNewThread {
                defer {
                    close(fd)
                    activity.change(sessions: -1)
                }
                do { try serve(fd) }
                catch { FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)) }
            }
            reply(nil)
        } catch {
            reply(error.localizedDescription)
        }
    }
}

private final class Listener: NSObject, NSXPCListenerDelegate {
    private let requirement: String

    init(requirement: String) { self.requirement = requirement }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard interrupted == 0 else { return false }
        // Only Sleep In's own client, signed by the same team, may ask for a root session.
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = NSXPCInterface(with: SleepInLidService.self)
        connection.exportedObject = Service(uid: connection.effectiveUserIdentifier)
        activity.change(connections: 1)
        connection.invalidationHandler = { activity.change(connections: -1) }
        connection.resume()
        return true
    }
}

private var listenerDelegate: Listener?

@main
struct LidAwakeDaemon {
    static func main() {
        // Read-only diagnostics also work without administrator privileges.
        if CommandLine.arguments == [CommandLine.arguments[0], "--power-source"] {
            print(onACPower() ? "AC Power" : "Battery or unknown")
            return
        }
        guard getuid() == 0, let requirement = sameTeamRequirement(identifier: LidService.clientIdentifier) else {
            FileHandle.standardError.write(Data("Sleep In's lid-closed daemon runs from launchd and needs a Developer ID signature.\n".utf8))
            exit(1)
        }
        signal(SIGPIPE, SIG_IGN)
        signal(SIGTERM) { _ in interrupted = 1 }
        signal(SIGINT) { _ in interrupted = 1 }
        signal(SIGHUP) { _ in interrupted = 1 }
        let delegate = Listener(requirement: requirement)
        listenerDelegate = delegate
        let listener = NSXPCListener(machServiceName: LidService.name)
        listener.delegate = delegate
        listener.resume()
        activity.exitWhenIdle()
        withExtendedLifetime(listener) { dispatchMain() }
    }
}
