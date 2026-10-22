import Foundation

enum Failure: Error { case command }

@main
struct LidSleepPolicyTests {
    static func main() throws {
        var changes: [Bool] = []
        let policy = LidSleepPolicy { changes.append($0) }
        try policy.update(onAC: false, deadline: 200, now: 100)
        assert(changes.isEmpty, "Battery must never enable the override")
        try policy.update(onAC: true, deadline: 200, now: 100)
        try policy.update(onAC: true, deadline: 200, now: 101)
        assert(changes == [true], "Heartbeats must not rewrite settings")
        try policy.update(onAC: false, deadline: 200, now: 102)
        assert(changes == [true, false], "Unplugging must restore sleep")
        try policy.update(onAC: true, deadline: 200, now: 103)
        try policy.update(onAC: true, deadline: 200, now: 200)
        assert(changes == [true, false, true, false], "The deadline must restore sleep independently")
        try policy.update(onAC: true, deadline: 250, now: 201)
        try policy.release() // App exit, lost connection, or heartbeat timeout.
        try policy.release()
        assert(changes == [true, false, true, false, true, false])

        var attempts: [Bool] = []
        var failEnable = true
        var failRestore = true
        let failing = LidSleepPolicy { enabled in
            attempts.append(enabled)
            if enabled && failEnable { throw Failure.command }
            if !enabled && failRestore { throw Failure.command }
        }
        do { try failing.update(onAC: true, deadline: 200, now: 100); assertionFailure() }
        catch Failure.command {}
        assert(!failing.enabled)
        do { try failing.release(); assertionFailure() }
        catch Failure.command {}
        failRestore = false
        try failing.release()
        assert(attempts == [true, false, false], "A failed enable still needs cleanup; failed cleanup must be retried")
        failEnable = false
        try failing.update(onAC: true, deadline: 200, now: 100)
        failRestore = true
        do { try failing.update(onAC: false, deadline: 200, now: 100); assertionFailure() }
        catch Failure.command {}
        assert(failing.enabled, "Failed restoration must remain owned")
        failRestore = false
        try failing.release()
        assert(!failing.enabled)

        var recovery: [Bool] = []
        var recoveryFails = true
        let recovering = LidSleepPolicy {
            recovery.append($0)
            if recoveryFails { throw Failure.command }
        }
        do { try recovering.recoverOwnedOverride(); assertionFailure() }
        catch Failure.command {}
        recoveryFails = false
        try recovering.release()
        assert(recovery == [false, false], "Interrupted overrides must remain owned until restored")
        print("Lid sleep policy checks passed")
    }
}
