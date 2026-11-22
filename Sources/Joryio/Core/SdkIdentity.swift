import Foundation

/// What every request says about the SDK that sent it (D427), so the
/// dashboard can show which version an app runs and when a newer one is out.
///
/// Same wire names on all five SDKs (the backend's sdk-version-parity spec
/// greps them): `X-Joryio-SDK` is the platform - the header the backend's
/// SDK-key guard and bot detection already read - and `X-Joryio-SDK-Version`
/// this build's version. A bridge (React Native, Unity) calls
/// `Joryio.setSdkWrapper(name:version:)` before `initialize`, and its requests
/// then also carry `X-Joryio-SDK-Wrapper` and `X-Joryio-SDK-Wrapper-Version`:
/// the bridge's requests leave through this SDK, so it keeps saying `ios`.
enum SdkIdentity {
    static let platformHeader = "X-Joryio-SDK"
    static let versionHeader = "X-Joryio-SDK-Version"
    static let wrapperHeader = "X-Joryio-SDK-Wrapper"
    static let wrapperVersionHeader = "X-Joryio-SDK-Wrapper-Version"
    static let platform = "ios"

    private static let lock = NSLock()
    private static var wrapper: (name: String, version: String)?

    /// False (and nothing changes) for a name or version that is not header-safe.
    @discardableResult
    static func setWrapper(name: String?, version: String?) -> Bool {
        let n = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let v = (version ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard n.range(of: "^[a-z][a-z0-9-]{0,31}$", options: .regularExpression) != nil,
              v.range(of: "^[0-9A-Za-z.+-]{1,32}$", options: .regularExpression) != nil
        else { return false }
        lock.lock(); wrapper = (n, v); lock.unlock()
        return true
    }

    /// Set the identity headers on one request.
    static func apply(to request: inout URLRequest) {
        request.setValue(platform, forHTTPHeaderField: platformHeader)
        request.setValue(SDK_VERSION, forHTTPHeaderField: versionHeader)
        lock.lock(); let w = wrapper; lock.unlock()
        if let w {
            request.setValue(w.name, forHTTPHeaderField: wrapperHeader)
            request.setValue(w.version, forHTTPHeaderField: wrapperVersionHeader)
        }
    }

    /// Tests only.
    static func resetForTesting() {
        lock.lock(); wrapper = nil; lock.unlock()
    }
}

extension Joryio {
    /// For Joryio's own React Native and Unity bridges - an app never calls
    /// this. Names the bridge on every request (`X-Joryio-SDK-Wrapper` and
    /// `X-Joryio-SDK-Wrapper-Version`, D427) so the dashboard can show the
    /// version of the package the app installed. Call before `initialize`.
    /// Returns false, and changes nothing, for a name or version that is not
    /// header-safe.
    @discardableResult
    public static func setSdkWrapper(name: String, version: String) -> Bool {
        SdkIdentity.setWrapper(name: name, version: version)
    }
}
