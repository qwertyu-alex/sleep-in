import Darwin

umask(0o077)
// A closed app or terminal must not kill the timer before it restores sleep settings.
signal(SIGPIPE, SIG_IGN)
exit(SleepInCommand.main(Array(CommandLine.arguments.dropFirst())))
