import Darwin
import Foundation

/// A failure explained in words the user can act on.
struct TimerError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// The current `errno` as a user-facing error.
func systemError(_ action: String, _ code: Int32 = errno) -> TimerError {
    TimerError("\(action): \(String(cString: strerror(code)))")
}

/// A child process the timer starts, watches, and stops.
protocol ChildProcess: AnyObject {
    var isRunning: Bool { get }
    func terminate()
    func wait()
}

/// A process started with `posix_spawn`, so the timer controls exactly what it inherits.
final class Spawned: ChildProcess {
    let pid: pid_t
    private var status: Int32?

    /// Runs `path` with no access to the timer's own files and sockets.
    /// Without `output`, the child shares this command's standard input and output.
    init(_ path: String, _ arguments: [String], output: Int32? = nil) throws {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        if let output {
            posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
            posix_spawn_file_actions_adddup2(&actions, output, 1)
            posix_spawn_file_actions_adddup2(&actions, output, 2)
        } else {
            for fd in Int32(0)...2 { posix_spawn_file_actions_addinherit_np(&actions, fd) }
        }
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // This command ignores SIGPIPE; children start with every signal at its default.
        var signals = sigset_t()
        sigfillset(&signals)
        posix_spawnattr_setsigdefault(&attributes, &signals)
        sigemptyset(&signals)
        posix_spawnattr_setsigmask(&attributes, &signals)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        let argv = ([path] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, path, &actions, &attributes, argv, environ)
        guard result == 0 else { throw systemError("Couldn't start \(path)", result) }
        self.pid = pid
    }

    var isRunning: Bool {
        guard status == nil else { return false }
        var value: Int32 = 0
        let result = waitpid(pid, &value, WNOHANG)
        if result == 0 { return true }
        status = result == pid ? value : -1
        return false
    }

    func terminate() {
        // Once reaped, the process ID may belong to someone else.
        if status == nil { kill(pid, SIGTERM) }
    }

    func wait() {
        while status == nil {
            var value: Int32 = 0
            let result = waitpid(pid, &value, 0)
            if result == pid { status = value }
            else if errno != EINTR { status = -1 }
        }
    }

    /// Waits up to `timeout` seconds; false if the process is still running.
    func wait(timeout: Double) -> Bool {
        let limit = ProcessInfo.processInfo.systemUptime + timeout
        while isRunning {
            guard ProcessInfo.processInfo.systemUptime < limit else { return false }
            usleep(20_000)
        }
        return true
    }

    /// The exit status, or nil if the process was killed by a signal.
    var exitCode: Int32? {
        guard let status, status >= 0, status & 0x7f == 0 else { return nil }
        return (status >> 8) & 0xff
    }
}

/// An unlinked temporary file that collects a child's output.
final class Capture {
    let fd: Int32

    init() throws {
        var template = Array((NSTemporaryDirectory() + "sleep-in.XXXXXX").utf8CString)
        fd = template.withUnsafeMutableBufferPointer { mkstemp($0.baseAddress!) }
        guard fd >= 0 else { throw systemError("Couldn't create a temporary file") }
        unlink(String(cString: template))
    }

    deinit { close(fd) }

    var text: String {
        lseek(fd, 0, SEEK_SET)
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(fd, &chunk, chunk.count)
            if count <= 0 { break }
            data.append(contentsOf: chunk.prefix(count))
        }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Asks macOS to sleep now, the same as choosing Sleep from the Apple menu.
func requestSystemSleep() throws {
    let output = try Capture()
    let child = try Spawned("/usr/bin/pmset", ["sleepnow"], output: output.fd)
    guard child.wait(timeout: 30) else {
        kill(child.pid, SIGKILL)
        child.wait()
        throw TimerError("macOS didn't respond to the sleep request.")
    }
    guard child.exitCode != 0 else { return }
    let text = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
    throw TimerError(text.isEmpty ? "macOS rejected the sleep request." : text)
}

/// A Unix domain socket, as used by the timer's control socket and the lid-closed helper.
final class UnixSocket {
    let fd: Int32
    private var open = true

    private init(fd: Int32) {
        self.fd = fd
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    deinit { close() }

    func close() {
        if open { Darwin.close(fd) }
        open = false
    }

    private static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw TimerError("The socket path is too long: \(path)")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return address
    }

    private static func make() throws -> UnixSocket {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw systemError("Couldn't create a socket") }
        return UnixSocket(fd: fd)
    }

    /// Listens at `path`, readable and writable only by this user.
    static func listen(at path: String, backlog: Int32) throws -> UnixSocket {
        let socket = try make()
        var address = try address(path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(socket.fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else { throw systemError("Couldn't create \(path)") }
        guard chmod(path, 0o600) == 0, Darwin.listen(socket.fd, backlog) == 0 else { throw systemError("Couldn't listen on \(path)") }
        return socket
    }

    /// Connects to `path`, or returns nil when nothing is listening there.
    static func connect(to path: String) throws -> UnixSocket? {
        let socket = try make()
        var address = try address(path)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(socket.fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if result == 0 { return socket }
        if errno == ENOENT || errno == ECONNREFUSED { return nil }
        throw systemError("Couldn't connect to the timer")
    }

    /// Waits up to `timeout` seconds for a connection; nil on timeout or a signal.
    func accept(timeout: Double) throws -> UnixSocket? {
        var item = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let ready = poll(&item, 1, Int32(timeout * 1000))
        if ready < 0 && errno != EINTR { throw systemError("Couldn't wait for connections") }
        guard ready > 0 else { return nil }
        let connection = Darwin.accept(fd, nil, nil)
        guard connection >= 0 else {
            if errno == EINTR || errno == ECONNABORTED { return nil }
            throw systemError("Couldn't accept a connection")
        }
        return UnixSocket(fd: connection)
    }

    /// Limits how long each send and receive may block.
    func setTimeout(_ seconds: Double) {
        var value = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - seconds.rounded(.down)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
    }

    /// The user ID of the process on the other end.
    var peerUID: uid_t? {
        var uid: uid_t = 0
        var gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 ? uid : nil
    }

    func send(_ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let sent = Darwin.send(fd, raw.baseAddress! + offset, raw.count - offset, 0)
                if sent < 0 && errno == EINTR { continue }
                guard sent > 0 else { throw errno == EAGAIN ? TimerError("timed out") : systemError("Connection failed") }
                offset += sent
            }
        }
    }

    /// Up to `limit` bytes; empty once the other end has closed the connection.
    func receive(limit: Int) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: limit)
        while true {
            let count = recv(fd, &buffer, limit, 0)
            if count >= 0 { return Data(buffer.prefix(count)) }
            if errno == EINTR { continue }
            throw errno == EAGAIN ? TimerError("timed out") : systemError("Connection failed")
        }
    }
}
