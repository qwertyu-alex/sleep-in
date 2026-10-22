import Darwin
import Foundation

/// A mistake on the command line; reported with the usage line and exit status 2.
struct UsageError: Error, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
}

/// Stops with a message on standard error and the given exit status.
struct CommandExit: Error {
    let status: Int32
    let message: String
}

struct Arguments: Equatable {
    var action = ""
    var amount: String?
    var dryRun = false
    var lidClosed = false
    var replace = false
    var json = false
    var help = false
    /// Used by the app; not shown in the help.
    var lidHelper: String?
    var guiParent: pid_t?
    var stateDirectory: String?

    private static let flags = ["--help", "--dry-run", "--lid-closed", "--replace", "--json"]
    private static let valued = ["--lid-helper", "--gui-parent", "--state-dir"]

    private static func isOption(_ argument: String) -> Bool {
        argument.hasPrefix("-") && argument != "-" && argument.wholeMatch(of: try! Regex("-[0-9]+|-[0-9]*\\.[0-9]+")) == nil
    }

    /// Options may come anywhere, as unique prefixes, and as --name=value.
    static func parse(_ arguments: [String]) throws -> Arguments {
        var result = Arguments()
        var positionals: [String] = []
        var unrecognized: [String] = []
        var index = 0
        var onlyPositionals = false
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            if onlyPositionals || !isOption(argument) {
                positionals.append(argument)
                continue
            }
            if argument == "--" {
                onlyPositionals = true
                continue
            }
            if argument == "-h" { return Arguments(help: true) }
            guard argument.hasPrefix("--") else {
                unrecognized.append(argument)
                continue
            }
            let parts = argument.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let given = String(parts[0])
            let inline = parts.count > 1 ? String(parts[1]) : nil
            let matches = (flags + valued).filter { $0.hasPrefix(given) }
            let name: String
            if (flags + valued).contains(given) {
                name = given
            } else if matches.count == 1 {
                name = matches[0]
            } else if matches.isEmpty {
                unrecognized.append(argument)
                continue
            } else {
                throw UsageError("ambiguous option: \(given) could match \(matches.joined(separator: ", "))")
            }
            if flags.contains(name) {
                if let inline { throw UsageError("argument \(name): ignored explicit argument '\(inline)'") }
                switch name {
                case "--help": return Arguments(help: true)
                case "--dry-run": result.dryRun = true
                case "--lid-closed": result.lidClosed = true
                case "--replace": result.replace = true
                default: result.json = true
                }
                continue
            }
            let value: String
            if let inline {
                value = inline
            } else if index < arguments.count, !isOption(arguments[index]) {
                value = arguments[index]
                index += 1
            } else {
                throw UsageError("argument \(name): expected one argument")
            }
            switch name {
            case "--lid-helper": result.lidHelper = value
            case "--state-dir": result.stateDirectory = value
            default:
                guard let pid = pid_t(value) else { throw UsageError("argument --gui-parent: invalid int value: '\(value)'") }
                result.guiParent = pid
            }
        }
        guard let action = positionals.first else { throw UsageError("the following arguments are required: action") }
        result.action = action
        result.amount = positionals.count > 1 ? positionals[1] : nil
        unrecognized += positionals.dropFirst(2)
        guard unrecognized.isEmpty else { throw UsageError("unrecognized arguments: \(unrecognized.joined(separator: " "))") }
        return result
    }
}

enum SleepInCommand {
    static let usage = """
        usage: sleep-in [-h] [--dry-run] [--lid-closed] [--replace] [--json]
                        action [amount]

        """

    static let help = usage + """

        Keep your Mac awake until a timer expires, then put it to sleep.

        positional arguments:
          action        Duration with h/m/s units, or status, cancel, or extend
          amount        With extend: time to add, such as 15m

        options:
          -h, --help    show this help message and exit
          --dry-run     Keep awake for the duration but do not sleep at the end
          --lid-closed  Also prevent lid-close sleep on AC power; asks for Touch ID
          --replace     Replace an existing timer
          --json        Print machine-readable timer events

        Examples: sleep-in 1h | sleep-in 1h30m | sleep-in extend 15m | sleep-in status | sleep-in cancel
        Runs in this terminal. Ctrl+C or closing Terminal cancels.
        Use --lid-closed for lid-closed use while plugged in (approve with Touch ID).

        """

    /// Runs the command and returns its exit status.
    static func main(_ arguments: [String]) -> Int32 {
        do {
            try run(arguments)
            return 0
        } catch let error as UsageError {
            fputs(usage + "sleep-in: error: \(error.message)\n", stderr)
            return 2
        } catch let error as CommandExit {
            fputs(error.message, stderr)
            return error.status
        } catch {
            fputs("sleep-in: \(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    private static func output(_ text: String) {
        fputs(text + "\n", stdout)
        fflush(stdout)
    }

    static func run(_ arguments: [String]) throws {
        let args = try Arguments.parse(arguments)
        if args.help {
            fputs(help, stdout)
            return
        }
        if let parent = args.guiParent, parent != getppid() {
            throw UsageError("The app that started this timer is no longer running.")
        }
        let controlling = ["status", "cancel", "extend"].contains(args.action)
        if controlling && (args.dryRun || args.replace || args.lidClosed || args.lidHelper != nil) {
            throw UsageError("--dry-run, --replace, and --lid-closed apply only when starting a timer.")
        }
        if args.lidHelper != nil && !args.lidClosed { throw UsageError("--lid-helper requires --lid-closed.") }
        if args.action == "extend" && args.amount == nil {
            throw UsageError("Say how much time to add, such as: sleep-in extend 15m")
        }
        if args.action != "extend", let amount = args.amount { throw UsageError("unrecognized arguments: \(amount)") }
        var seconds = 0.0
        if args.action != "status" && args.action != "cancel" {
            do { seconds = try Duration.parse(args.amount ?? args.action) }
            catch let error as TimerError { throw UsageError(error.message) }
        }

        let paths = args.stateDirectory.map { TimerPaths(root: URL(fileURLWithPath: $0)) } ?? .standard
        try paths.prepare()
        // Serialize commands so simultaneous starts cannot create competing timers.
        let lock = try paths.lockControl()
        defer { close(lock) }
        let active = try paths.request("status")
        func show(_ state: TimerState) { output(args.json ? state.json : describe(state)) }

        switch args.action {
        case "status":
            if let active {
                show(active)
            } else {
                var message = "No timer is running."
                if let previous = try paths.load() {
                    message += " " + (previous.status == "running" ? "The previous timer was interrupted." : describe(previous))
                }
                output(args.json ? TimerState(status: "inactive", message: message).json : message)
            }
            return
        case "extend":
            guard active != nil, let updated = try paths.request("extend \(seconds)"), updated.status == "running" else {
                throw CommandExit(status: 1, message: "No timer is running.\n")
            }
            show(updated)
            return
        default:
            break
        }
        if let active {
            guard args.action == "cancel" || args.replace else {
                throw CommandExit(status: 1, message: describe(active) + "\nUse --replace to change it, or sleep-in cancel to stop it.\n")
            }
            _ = try paths.request("cancel")
            let limit = ProcessInfo.processInfo.systemUptime + 5
            while access(paths.socket, F_OK) == 0 && ProcessInfo.processInfo.systemUptime < limit { usleep(50_000) }
            if access(paths.socket, F_OK) == 0 {
                throw CommandExit(status: 1, message: "The previous timer is still stopping. Try again shortly.\n")
            }
        }
        if args.action == "cancel" {
            output(active != nil ? "Timer cancelled. Normal sleep settings restored." : "No timer is running.")
            return
        }
        try runTimer(TimerOptions(seconds: seconds, dryRun: args.dryRun, json: args.json, parentPID: args.guiParent,
                                  lidClosed: args.lidClosed, lidHelper: args.lidHelper),
                     paths: paths, lock: lock)
    }
}
