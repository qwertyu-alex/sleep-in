import Foundation
import Security

/// Shared by Sleep In's lid-closed client and its root launch daemon.
enum LidService {
    /// The launchd label and Mach service name; also the daemon's signing identifier.
    static let name = "io.github.qwertyu-alex.sleep-in.lid-daemon"
    static let clientIdentifier = "io.github.qwertyu-alex.sleep-in.lid-client"
}

@objc(SleepInLidService)
protocol SleepInLidService {
    /// Lets the client confirm macOS allows the daemon before asking for Touch ID.
    func ping(reply: @escaping (Bool) -> Void)
    /// Connects back to the timer's socket as root; the session then runs over that socket.
    func startSession(socketPath: String, reply: @escaping (String?) -> Void)
}

/// A code requirement matching `identifier` signed by the same Developer ID team as this program.
func sameTeamRequirement(identifier: String) -> String? {
    var code: SecCode?
    var staticCode: SecStaticCode?
    var info: CFDictionary?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
          SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
          SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
          let team = (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String,
          !team.isEmpty, team.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
    return #"anchor apple generic and identifier "\#(identifier)" and certificate leaf[subject.OU] = "\#(team)""#
}
