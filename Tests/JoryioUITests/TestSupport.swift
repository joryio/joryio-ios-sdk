import Foundation
import XCTest
@testable import Joryio

/// Shared fixtures for the behaviour tests. Every helper builds ISOLATED state:
/// a fresh UserDefaults suite, a fresh SQLite directory and a unique SDK key
/// (which scopes the Keychain service), so tests cannot see each other.
enum TestSupport {
    static func logger() -> Logger {
        Logger(enabled: false, logLevel: .error)
    }

    static func uniqueKey() -> String {
        "jry_sdk_ios_test_\(UUID().uuidString.prefix(8))"
    }

    static func defaults() -> UserDefaults {
        let name = "joryio.tests.\(UUID().uuidString)"
        return UserDefaults(suiteName: name)!
    }

    static func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("joryio-tests-\(UUID().uuidString)")
    }

    static func storage(
        sdkKey: String = uniqueKey(),
        defaults: UserDefaults = defaults(),
        directory: URL = tempDirectory(),
        secureStore: SecureStore = InMemorySecureStore()
    ) -> StorageManager {
        StorageManager(
            sdkKey: sdkKey,
            logger: logger(),
            databaseDirectory: directory,
            userDefaults: defaults,
            secureStore: secureStore
        )
    }

    /// A NetworkClient whose transport is `StubURLProtocol`.
    static func network(apiEndpoint: String = "https://api-eu1.joryio.test/api", maxRetries: Int = 0) -> NetworkClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return NetworkClient(
            sdkKey: "jry_sdk_ios_test",
            apiEndpoint: apiEndpoint,
            logger: logger(),
            maxRetries: maxRetries,
            retryBackoffMs: 1,
            requestTimeout: 5,
            authStore: SdkAuthTokenStore(enabled: false, initialToken: nil),
            sessionConfiguration: configuration
        )
    }

    /// A real `Joryio` instance - not the singleton - on isolated storage and
    /// the stub transport, with no UIApplication / notification-center calls
    /// (a host-less test bundle has neither). Initialised before returning.
    static func sdk(
        config: JoryioConfig = sdkConfig(),
        storage: StorageManager = storage(),
        defaults: UserDefaults = defaults(),
        initialize: Bool = true,
        retiredTokenSettleGrace: TimeInterval = 0
    ) -> Joryio {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let sdk = Joryio(environment: Joryio.Environment(
            storage: { _, _ in storage },
            sessionConfiguration: configuration,
            defaults: defaults,
            systemIntegration: false,
            secItemCalls: unlockedKeychain,
            // No grace minute in tests unless one asks for it: they check
            // that a token is forgotten once its user's items settle.
            retiredTokenSettleGrace: retiredTokenSettleGrace
        ))
        if initialize {
            sdk.initialize(sdkKey: "jry_sdk_ios_test", apiHost: "api-eu1.joryio.test", config: config)
        }
        return sdk
    }

    /// The Keychain answers of a device unlocked since boot. The availability
    /// probe's production decision still runs; only the system call is
    /// stood in for, so a hundred SDK instances do not each round-trip to
    /// securityd. The real Keychain is probed in ReleaseRound4Tests.
    static let unlockedKeychain = KeychainHelper.SecItemCalls(
        copyMatching: { _ in errSecSuccess },
        add: { _ in errSecSuccess }
    )

    /// Quiet defaults for SDK-level tests: no timer flushes, no Session Start,
    /// no in-app sync traffic, no immediate retries.
    static func sdkConfig(
        trackSessionStart: Bool = false,
        optOut: Bool = false,
        trackingConsent: JoryioConfig.TrackingConsent = .granted
    ) -> JoryioConfig {
        JoryioConfig(
            flushInterval: 3600,
            trackSessionStart: trackSessionStart,
            inApp: InAppConfig(enabled: false),
            maxRetries: 0,
            optOut: optOut,
            trackingConsent: trackingConsent
        )
    }

    /// Captured requests whose path ends with `suffix`.
    static func requests(_ suffix: String) -> [StubURLProtocol.Captured] {
        StubURLProtocol.requests.filter { $0.url.path.hasSuffix(suffix) }
    }

    static func event(_ name: String) -> Event {
        Event(type: name, userId: nil, anonymousId: "anon", sessionId: "s")
    }

    static func campaign(_ json: [String: Any]) throws -> InAppCampaign {
        let data = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder().decode(InAppCampaign.self, from: data)
    }
}

/// Captures every request and answers with whatever `responder` returns.
final class StubURLProtocol: URLProtocol {
    struct Captured {
        let url: URL
        let method: String
        let headers: [String: String]
        let body: Data
        var json: [String: Any]? { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] }
    }

    private static let lock = NSLock()
    private static var _requests: [Captured] = []
    static var responder: (URLRequest) -> (Int, Data) = { _ in (200, Data("{\"success\":true}".utf8)) }
    /// Seconds before the answer arrives - so a test can act while a request
    /// is IN FLIGHT. Answered asynchronously; a cancelled request gets none.
    static var delayFor: (URLRequest) -> TimeInterval = { _ in 0 }
    private var stopped = false
    private let stopLock = NSLock()

    static var requests: [Captured] {
        lock.lock(); defer { lock.unlock() }
        return _requests
    }

    static func reset() {
        lock.lock(); _requests = []; lock.unlock()
        responder = { _ in (200, Data("{\"success\":true}".utf8)) }
        delayFor = { _ in 0 }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                body.append(buffer, count: read)
            }
            stream.close()
        }
        let captured = Captured(
            url: request.url!,
            method: request.httpMethod ?? "GET",
            headers: request.allHTTPHeaderFields ?? [:],
            body: body
        )
        Self.lock.lock(); Self._requests.append(captured); Self.lock.unlock()

        // The responder sees the body even when URLSession streamed it.
        var answered = request
        answered.httpBody = body
        let (status, data) = Self.responder(answered)
        let respond = { [self] in
            stopLock.lock()
            let cancelled = stopped
            stopLock.unlock()
            guard !cancelled else { return }
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
        let delay = Self.delayFor(request)
        if delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: respond)
        } else {
            respond()
        }
    }

    override func stopLoading() {
        stopLock.lock()
        stopped = true
        stopLock.unlock()
    }
}

extension XCTestCase {
    /// Poll until `condition` holds or the timeout passes.
    func waitUntil(timeout: TimeInterval = 15, _ condition: @escaping () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(condition(), "condition not met within \(timeout)s", file: file, line: line)
    }
}

/// Stands in for the Keychain: like the real one, it outlives a StorageManager
/// (and, in the reinstall test, the UserDefaults domain).
final class InMemorySecureStore: SecureStore {
    private var items: [String: String] = [:]
    /// The device has not been unlocked since boot: items exist and cannot
    /// be read, exactly like the Keychain then.
    var locked = false

    func isProtectedDataAvailable() -> Bool { !locked }

    @discardableResult
    func setString(_ value: String, forKey account: String) -> Bool {
        items[account] = value
        return true
    }

    func getString(forKey account: String) -> String? { locked ? nil : items[account] }
    var count: Int { items.count }
    func removeItem(forKey account: String) { items.removeValue(forKey: account) }
    func removeAll() { items.removeAll() }
}
