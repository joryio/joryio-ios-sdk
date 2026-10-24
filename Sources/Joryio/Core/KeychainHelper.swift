import Foundation
import Security

/// Thin wrapper over the iOS/macOS Keychain (SecItem*) for storing small string
/// secrets at rest.
///
/// Why the Keychain (vs UserDefaults):
/// UserDefaults is already encrypted at rest by iOS Data Protection (the app
/// sandbox is encrypted; the default class is CompleteUntilFirstUserAuthentication).
/// The Keychain adds a dedicated, hardware-backed secure store for the few
/// identity-linking secrets (APNs device token, userId) that warrant the
/// strongest available at-rest handling. No third-party crypto is used — this is
/// entirely OS-native.
///
/// Accessibility is `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`:
///  - AfterFirstUnlock: the item is readable in the background once the device
///    has been unlocked at least once since boot, so background/terminate event
///    flushes and silent-push handling still work.
///  - ThisDeviceOnly: the item is never synced to iCloud Keychain and does not
///    migrate to a new device via encrypted backup — it stays on the device that
///    created it, which is the right semantics for a per-device push token.
///
/// Items are scoped per SDK key (service + account) so multiple SDK instances in
/// the same app do not collide.
/// Where the SDK keeps its few secrets. The Keychain in production; tests
/// substitute an in-memory store, because a host-less test bundle has no
/// Keychain entitlement.
protocol SecureStore: AnyObject {
    @discardableResult func setString(_ value: String, forKey account: String) -> Bool
    func getString(forKey account: String) -> String?
    func removeItem(forKey account: String)
    func removeAll()
    /// False while the device has not been unlocked since boot: the store's
    /// items exist but cannot be read, and an empty read means nothing.
    func isProtectedDataAvailable() -> Bool
}

extension SecureStore {
    func isProtectedDataAvailable() -> Bool { true }
}

final class KeychainHelper: SecureStore {
    private let service: String
    private let logger: Logger?
    private let secItemCalls: SecItemCalls

    init(sdkKey: String, logger: Logger? = nil, secItemCalls: SecItemCalls = .system) {
        // One service namespace per SDK key so separate instances stay isolated.
        self.service = Self.service(for: sdkKey)
        self.logger = logger
        self.secItemCalls = secItemCalls
    }

    static func service(for sdkKey: String) -> String { "com.joryio.sdk.\(sdkKey)" }

    /// Store (insert or update) a string value under `account`.
    @discardableResult
    func setString(_ value: String, forKey account: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }

        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        // Try to update an existing item first.
        let attributesToUpdate: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributesToUpdate as CFDictionary)
        if updateStatus == errSecSuccess {
            return true
        }

        if updateStatus == errSecItemNotFound {
            // Not present yet — add it.
            var addQuery = baseQuery
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus == errSecSuccess {
                return true
            }
            logger?.error("Keychain add failed for \(account): OSStatus \(addStatus)")
            return false
        }

        logger?.error("Keychain update failed for \(account): OSStatus \(updateStatus)")
        return false
    }

    /// Read a string value stored under `account` (nil if absent).
    func getString(forKey account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess else {
            if status != errSecItemNotFound {
                logger?.error("Keychain read failed for \(account): OSStatus \(status)")
            }
            return nil
        }

        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    /// The two SecItem calls the availability probe makes. The system's in
    /// production; tests answer with the statuses a device gives before and
    /// after the first unlock, so the PRODUCTION decision below is what they
    /// exercise.
    struct SecItemCalls {
        var copyMatching: (CFDictionary) -> OSStatus
        var add: (CFDictionary) -> OSStatus

        static let system = SecItemCalls(
            copyMatching: { query in
                var result: AnyObject?
                return SecItemCopyMatching(query, &result)
            },
            add: { query in SecItemAdd(query, nil) }
        )
    }

    /// The item the probe reads. Holds nothing; it exists to be readable.
    static let probeAccount = "protected_data_probe"

    /**
     Has the device been unlocked since it started? The question the SDK's
     storage depends on: the database is
     `completeUntilFirstUserAuthentication` and the Keychain items
     `AfterFirstUnlock`, so both are readable on a LOCKED device once it has
     been unlocked once since boot.

     Asked of the Keychain itself, on whatever thread calls - never of
     `UIApplication.isProtectedDataAvailable`. That one answers false
     whenever the screen is locked (it reflects `complete` protection), so
     the SDK deferred its whole start on every locked background launch - a
     silent push then produced no receipt and no sync (scan 4, finding 1).

     A dedicated probe item, written `AfterFirstUnlock`, so the answer does
     not depend on whether the app happens to have stored anything yet:
     - read succeeds: unlocked since boot;
     - `errSecInteractionNotAllowed` (read, or the add after not-found):
       not unlocked since boot;
     - anything else (no Keychain entitlement, an unexpected error): treated
       as available - a probe that cannot answer must never hold the SDK
       back for the life of the process.
     */
    func isProtectedDataAvailable() -> Bool {
        Self.probeProtectedData(service: service, calls: secItemCalls)
    }

    static func probeProtectedData(service: String, calls: SecItemCalls) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: probeAccount
        ]
        var read = base
        read[kSecReturnData as String] = true
        read[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = calls.copyMatching(read as CFDictionary)
        switch status {
        case errSecSuccess:
            return true
        case errSecInteractionNotAllowed:
            return false
        case errSecItemNotFound:
            var add = base
            add[kSecValueData as String] = Data("1".utf8)
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            return calls.add(add as CFDictionary) != errSecInteractionNotAllowed
        default:
            return true
        }
    }

    /// Delete every item this SDK key owns (all accounts under its service).
    /// Used when a reinstall is detected - see StorageManager.
    func removeAll() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            logger?.error("Keychain wipe failed: OSStatus \(status)")
        }
    }

    /// Delete the value stored under `account` (no-op if absent).
    func removeItem(forKey account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            logger?.error("Keychain delete failed for \(account): OSStatus \(status)")
        }
    }
}
