import Foundation
import LocalAuthentication

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

/// Asks for Touch ID, then has Sleep In's root daemon connect to the timer's socket.
@main
struct LidAwakeClient {
    static func main() {
        guard CommandLine.arguments.count == 2 else { fail("Usage: SleepInLidClient <timer socket>") }
        guard let requirement = sameTeamRequirement(identifier: LidService.name) else {
            fail("Lid-closed mode needs Sleep In signed with a Developer ID. Rebuild it with ./gui/build.sh.")
        }
        let connection = NSXPCConnection(machServiceName: LidService.name, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: SleepInLidService.self)
        // Only talk to Sleep In's own daemon, not another program using its name.
        connection.setCodeSigningRequirement(requirement)
        connection.resume()
        defer { connection.invalidate() }
        var failure: Error?
        guard let service = connection.synchronousRemoteObjectProxyWithErrorHandler({ failure = $0 }) as? SleepInLidService else {
            fail("Couldn't reach Sleep In's lid-closed helper.")
        }

        // Check that macOS allows the daemon before asking for a fingerprint.
        var reachable = false
        service.ping { reachable = $0 }
        guard reachable else {
            if (failure as NSError?)?.code == NSXPCConnectionCodeSigningRequirementFailure {
                fail("Sleep In's lid-closed helper failed its signature check. Rebuild Sleep In with ./gui/build.sh.")
            }
            fail("Lid-closed mode isn't set up yet. Open Sleep In, check “Keep awake with lid closed”, "
                 + "press Start, and allow Sleep In in System Settings.")
        }

        let context = LAContext()
        let decided = DispatchSemaphore(value: 0)
        var approved = false
        var approval: Error?
        // macOS shows this as “Sleep In is trying to …” with Touch ID, or a password when Touch ID is unavailable.
        context.evaluatePolicy(.deviceOwnerAuthentication,
                               localizedReason: "keep your Mac awake with the lid closed while plugged in") { success, error in
            approved = success
            approval = error
            decided.signal()
        }
        decided.wait()
        guard approved else {
            switch (approval as? LAError)?.code {
            case .userCancel?, .appCancel?, .systemCancel?:
                fail("Approval was cancelled. No lid-closed session was started.")
            default:
                fail("Couldn't confirm it's you: \(approval?.localizedDescription ?? "unknown error").")
            }
        }

        var replied = false
        var problem: String?
        service.startSession(socketPath: CommandLine.arguments[1]) { error in
            replied = true
            problem = error
        }
        if let problem { fail(problem) }
        guard replied else {
            fail("Sleep In's lid-closed helper stopped responding: \(failure?.localizedDescription ?? "no reply").")
        }
    }
}
