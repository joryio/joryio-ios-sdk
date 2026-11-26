import Foundation

/// resetTo(anonymousId): the rule a caller-supplied anonymous id must pass
/// (BACKLOG D366). The SAME rule on all five SDKs, byte-identical - the
/// backend parity suite greps the pattern.
///
///  - 8 to 255 characters (the backend stores at most 255), letters, digits
///    and `.` `_` `:` `-` only;
///  - not 24 lowercase hex characters: the shape of a Joryio internal profile
///    id, which several server paths read as the profile itself;
///  - not a user id the SDK holds (signed in, or kept for withdrawals).
enum ResetTo {
    static let anonymousIdPattern = "^[A-Za-z0-9._:-]{8,255}$"
    static let internalIdPattern = "^[0-9a-f]{24}$"

    /// How many anonymous ids tied to a signed-in user (held when a reset()
    /// or resetTo() signed them out) this device remembers, newest kept. The
    /// same cap on all five SDKs; wipeData() forgets them with all other data.
    static let signedInAnonymousIdsMax = 20

    /// Append `id` (moved to the end if present), keeping the newest `signedInAnonymousIdsMax`.
    static func remember(_ list: [String], _ id: String) -> [String] {
        Array((list.filter { $0 != id } + [id]).suffix(signedInAnonymousIdsMax))
    }

    /// A callback that runs at most once (a held call answers when it runs,
    /// or `false` when it is discarded first - never both).
    static func once(_ callback: @escaping (Bool) -> Void) -> (Bool) -> Void {
        let lock = NSLock()
        var done = false
        return { value in
            lock.lock()
            let first = !done
            done = true
            lock.unlock()
            if first { callback(value) }
        }
    }

    private static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }

    /// Nil when `anonymousId` may be adopted, otherwise why not.
    static func refusal(
        _ anonymousId: String?,
        knownUserIds: [String?],
        signedInAnonymousId: String? = nil,
        rememberedSignedInAnonymousIds: [String] = []
    ) -> String? {
        guard let anonymousId, matches(anonymousId, anonymousIdPattern) else {
            return "resetTo: the anonymous id must be 8 to 255 letters, digits, \".\", \"_\", \":\" or \"-\""
        }
        if matches(anonymousId, internalIdPattern) {
            return "resetTo: the anonymous id has the shape of a Joryio profile id"
        }
        if knownUserIds.contains(where: { $0 != nil && $0 == anonymousId }) {
            return "resetTo: the anonymous id is a user id"
        }
        // The anonymous id held while a user is signed in is tied to their
        // profile: the next person on a shared device would inherit it.
        // ...and so is one a signed-in user held before an earlier reset.
        if signedInAnonymousId == anonymousId || rememberedSignedInAnonymousIds.contains(anonymousId) {
            return "resetTo: the anonymous id belongs to the signed-in user"
        }
        return nil
    }
}
