import Foundation

/// The privileged helper owns only overrides it enabled itself.
final class LidSleepPolicy {
    private let change: (Bool) throws -> Void
    private(set) var enabled = false
    private var needsRestore = false

    init(change: @escaping (Bool) throws -> Void) { self.change = change }

    func update(onAC: Bool, deadline: Double, now: Double) throws {
        let wanted = onAC && now < deadline
        guard wanted != enabled else { return }
        if wanted {
            // An unsuccessful command may still have changed the system setting.
            needsRestore = true
            try change(true)
            enabled = true
        } else {
            try release()
        }
    }

    func release() throws {
        guard needsRestore else { return }
        try change(false)
        enabled = false
        needsRestore = false
    }

    func recoverOwnedOverride() throws {
        needsRestore = true
        try release()
    }
}
