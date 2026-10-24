import Foundation
import UIKit

/// Device information utilities
struct DeviceInfo {
    /// Get comprehensive device information
    static func getDeviceInfo() -> [String: Any] {
        var info: [String: Any] = [:]

        // Device model
        info["model"] = getDeviceModel()

        // OS version
        info["os_version"] = UIDevice.current.systemVersion
        info["os_name"] = UIDevice.current.systemName

        // App version
        if let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
            info["app_version"] = appVersion
        }

        // Build number - sent as a NUMBER, to match Android.
        //
        // CFBundleVersion is a String in Apple's API, and this used to forward
        // it as one. Android sends packageInfo.longVersionCode, a Long. So the
        // same property crossed the wire as two types depending on the phone,
        // and `$build_number` became the only genuinely mixed property in the
        // workspace: 365 numeric rows from Android against 134 string rows
        // from iOS, on one event. A segment rule like "build >= 220" then
        // compared iOS builds lexicographically, where "98" > "220".
        //
        // Apple documents CFBundleVersion as a monotonically increasing
        // integer, and every value observed in production ("1", "95", "97",
        // "98") is one. When it is NOT parseable - some apps use "1.2.3" - the
        // key is OMITTED rather than sent as a string: re-introducing the
        // second type would restore exactly the bug this fixes, and
        // `$app_version` (CFBundleShortVersionString) already carries the
        // human-readable version for those apps.
        if let raw = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
           let buildNumber = Int(raw.trimmingCharacters(in: .whitespaces)) {
            info["build_number"] = buildNumber
        }

        // Bundle ID
        if let bundleId = Bundle.main.bundleIdentifier {
            info["bundle_id"] = bundleId
        }

        // Screen dimensions - read on the main thread only (see screenSize()).
        if let screen = screenSize() {
            info["screen_width"] = Int(screen.width)
            info["screen_height"] = Int(screen.height)
        }

        // Device locale
        info["locale"] = Locale.current.identifier

        // Timezone
        info["timezone"] = TimeZone.current.identifier

        // Carrier (if available)
        #if !targetEnvironment(simulator)
        // Carrier info would go here if CTTelephonyNetworkInfo is available
        #endif

        return info
    }

    private static let screenLock = NSLock()
    private static var cachedScreenSize: CGSize?

    /// The screen size, read from UIKit on the MAIN thread only.
    ///
    /// getDeviceInfo() runs on background queues (Session Start, push token
    /// registration). `UIScreen.main` is main-thread UIKit state: read off
    /// the main thread it can block on the main queue, and a host whose main
    /// thread is itself waiting on the SDK (a semaphore, a sync dispatch)
    /// then hangs - the test bundle did exactly that. So the main thread
    /// reads and caches it; any other thread uses the cached value, and the
    /// first such call before any main-thread read omits the two keys and
    /// schedules the read for later.
    static func screenSize() -> CGSize? {
        if Thread.isMainThread {
            let size = UIScreen.main.bounds.size
            screenLock.lock()
            cachedScreenSize = size
            screenLock.unlock()
            return size
        }
        screenLock.lock()
        let cached = cachedScreenSize
        screenLock.unlock()
        if cached == nil { primeScreenSize() }
        return cached
    }

    /// Cache the screen size: now when on the main thread, else asynchronously
    /// on it (never a sync dispatch - that is the hang this avoids).
    static func primeScreenSize() {
        if Thread.isMainThread {
            _ = screenSize()
        } else {
            DispatchQueue.main.async { _ = screenSize() }
        }
    }

    /// Build tracking properties for Session Start
    static func getTrackingProperties(deviceId: String) -> [String: Any] {
        var properties: [String: Any] = [:]
        let info = getDeviceInfo()

        properties["$device_id"] = deviceId
        properties["$platform"] = "ios"
        properties["$model"] = info["model"]
        properties["$os_name"] = info["os_name"]
        properties["$os_version"] = info["os_version"]
        properties["$app_version"] = info["app_version"]
        properties["$build_number"] = info["build_number"]
        properties["$bundle_id"] = info["bundle_id"]
        properties["$screen_width"] = info["screen_width"]
        properties["$screen_height"] = info["screen_height"]
        properties["$locale"] = info["locale"]
        properties["$timezone"] = info["timezone"]

        let preferredLanguages = Locale.preferredLanguages
        if let primaryLanguage = preferredLanguages.first {
            properties["$language"] = Locale(identifier: primaryLanguage).languageCode ?? primaryLanguage
            properties["$languages"] = preferredLanguages
        }

        return properties
    }

    /// Get device model name
    static func getDeviceModel() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machineMirror = Mirror(reflecting: systemInfo.machine)
        let identifier = machineMirror.children.reduce("") { identifier, element in
            guard let value = element.value as? Int8, value != 0 else { return identifier }
            return identifier + String(UnicodeScalar(UInt8(value)))
        }
        return mapToDevice(identifier: identifier)
    }

    /// Map device identifier to friendly name
    private static func mapToDevice(identifier: String) -> String {
        switch identifier {
        // iPhone
        case "iPhone14,2": return "iPhone 13 Pro"
        case "iPhone14,3": return "iPhone 13 Pro Max"
        case "iPhone14,4": return "iPhone 13 mini"
        case "iPhone14,5": return "iPhone 13"
        case "iPhone14,7": return "iPhone 14"
        case "iPhone14,8": return "iPhone 14 Plus"
        case "iPhone15,2": return "iPhone 14 Pro"
        case "iPhone15,3": return "iPhone 14 Pro Max"
        case "iPhone15,4": return "iPhone 15"
        case "iPhone15,5": return "iPhone 15 Plus"
        case "iPhone16,1": return "iPhone 15 Pro"
        case "iPhone16,2": return "iPhone 15 Pro Max"

        // iPad
        case "iPad13,18": return "iPad 10th Gen"
        case "iPad13,19": return "iPad 10th Gen"
        case "iPad14,3": return "iPad Pro 11-inch (4th Gen)"
        case "iPad14,4": return "iPad Pro 11-inch (4th Gen)"
        case "iPad14,5": return "iPad Pro 12.9-inch (6th Gen)"
        case "iPad14,6": return "iPad Pro 12.9-inch (6th Gen)"

        // Simulator
        case "i386", "x86_64", "arm64":
            return "Simulator (\(identifier))"

        default:
            return identifier
        }
    }
}
