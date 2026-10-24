import Foundation

/// Network client for API communication
class NetworkClient {
    private let sdkKey: String
    private let apiEndpoint: String
    private let logger: Logger
    private let maxRetries: Int
    private let retryBackoffMs: Double
    private let requestTimeout: TimeInterval
    private let session: URLSession
    /// Shared, thread-safe holder for the optional SDK-authentication token and
    /// error handler. Owned by `Joryio`; nil-safe via `enabled`.
    private let authStore: SdkAuthTokenStore

    /// The user identified on this device right now. A request made for
    /// someone else - a write or batch a previous user left behind - never
    /// reaches the app's SDK-authentication handler: asking the host for a
    /// token there would make it sign out, or re-mint for, the CURRENT user
    /// over another person's leftovers (contract v4, 39).
    var currentUserId: () -> String? = { nil }

    init(
        sdkKey: String,
        apiEndpoint: String,
        logger: Logger,
        maxRetries: Int,
        retryBackoffMs: Double,
        requestTimeout: TimeInterval,
        authStore: SdkAuthTokenStore,
        sessionConfiguration: URLSessionConfiguration = .default
    ) {
        // Set by Joryio after construction. Without it the SDK knew it was
        // being rejected and only said so in the log, so a host app could show
        // "initialized" while every request came back 401.
        self.sdkKey = sdkKey
        self.apiEndpoint = apiEndpoint
        self.logger = logger
        self.maxRetries = maxRetries
        self.retryBackoffMs = retryBackoffMs
        self.requestTimeout = requestTimeout
        self.authStore = authStore

        // A copy, so a caller's configuration (tests stub the transport) is
        // never mutated.
        let config = (sessionConfiguration.copy() as? URLSessionConfiguration) ?? .default
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = requestTimeout
        self.session = URLSession(configuration: config)
    }

    // MARK: - Event Tracking

    func trackBatch(_ batch: EventBatch) async throws {
        let endpoint = "\(apiEndpoint)/v1/track/batch"
        try await sendRequest(endpoint: endpoint, method: "POST", body: batch)
        logger.debug("Batch tracked successfully: \(batch.events.count) events")
    }

    /// What the server did with one event batch, classified the way the
    /// queue has to act on it (SDK contract 3, identical on every platform).
    enum BatchOutcome: Equatable {
        /// 2xx `success: true` (or no verdict): delete the batch.
        case accepted
        /// 2xx `success: false`: keep these positions, delete the rest -
        /// including every position in `rejectedIndices`, which the server
        /// refused for good (SDK contract 29). An empty list means nothing
        /// is worth keeping.
        case partial(failedIndices: [Int])
        /// 400 / 413 / 422: the server will never take this batch as it is.
        /// Split it rather than block the queue behind it.
        case rejected(status: Int)
        /// 401 with SDK authentication that the refresh flow could not fix.
        /// Keep the events, unless they belong to a user who is no longer the
        /// current one (SDK contract 30) - the queue decides with `reason`.
        case authFailed(reason: SdkAuthErrorReason?)
        /// 402 (ingestion suspended) or 403: stop sending this session.
        case suspended(status: Int)
        /// 429 / 5xx / offline / timeout: keep everything, back off.
        case retryLater(retryAfter: TimeInterval?)
    }

    /// Send pre-encoded events as ONE attempt and classify the answer.
    ///
    /// One attempt, not the retry loop: the queue owns backoff for batches,
    /// so a run of failures cannot stack this client's retries on top of the
    /// queue's. The events go out as the exact JSON they were stored as.
    func sendEventBatch(_ eventsJSON: [String], userId: String?) async -> BatchOutcome {
        let endpoint = "\(apiEndpoint)/v1/track/batch"
        let body = Data(("{\"events\":[" + eventsJSON.joined(separator: ",") + "]}").utf8)

        do {
            // The queue cuts batches at a user change, so the batch's user is
            // known: the token is routed by it without parsing a body of up
            // to ~900 KB (scan 8, N4). "" is anonymous, as in the body.
            let subject = userId.flatMap { $0.isEmpty ? nil : $0 }
            let (status, data, http, authReason) = try await performRawWithAuth(
                endpoint: endpoint, body: body, requestUserId: userId, subject: .known(subject)
            )
            if let authReason {
                onTransportFailure?(NetworkError.sdkAuthError(reason: authReason, endpoint: endpoint, rawReason: authReason.rawValue))
                return .authFailed(reason: authReason)
            }

            let outcome = Self.classifyBatchResponse(
                status: status,
                body: data,
                retryAfterHeader: http.value(forHTTPHeaderField: "Retry-After"),
                batchCount: eventsJSON.count
            )
            switch outcome {
            case .accepted, .partial:
                onTransportSuccess?()
            case .rejected(let code), .suspended(let code):
                onTransportFailure?(NetworkError.httpError(code))
            case .authFailed:
                onTransportFailure?(NetworkError.unauthorized)
            case .retryLater(let retryAfter):
                onTransportFailure?(status == 429 ? NetworkError.rateLimited(retryAfter: retryAfter) : NetworkError.httpError(status))
            }
            return outcome
        } catch {
            // Offline, timeout, DNS: transient by definition.
            onTransportFailure?(error)
            return .retryLater(retryAfter: nil)
        }
    }

    /**
     One exchange that runs the SDK-authentication refresh-and-retry-once flow
     and returns the answer instead of throwing on a non-2xx status.

     The returned reason is set when the final answer is still an
     SDK-authentication 401. The app's handler is called on every such 401
     for the CURRENT user while SDK authentication is enabled - including
     when no token was ever set (reason `missing`, SDK contract 30). A
     request carrying another user's id (`requestUserId`, left over from
     before a logout or a switch) never reaches the handler: the caller
     drops it instead (contract v4, 39).
     */
    private func performRawWithAuth(
        endpoint: String,
        body: Data,
        requestUserId: String?,
        subject: AuthSubject = .readFromBody
    ) async throws -> (Int, Data, HTTPURLResponse, SdkAuthErrorReason?) {
        var (status, data, http) = try await performRaw(endpoint: endpoint, method: "POST", body: body, subject: subject)
        guard status == 401, let parsed = Self.parseSdkAuthError(from: data) else {
            return (status, data, http, nil)
        }
        guard authStore.enabled, let handler = authStore.currentHandler() else {
            return (status, data, http, parsed.reason)
        }
        if let requestUserId, requestUserId != currentUserId() {
            logger.debug("SDK authentication refused a request of a previous user; not asking the app for a token")
            return (status, data, http, parsed.reason)
        }
        let failedToken = authStore.currentToken()
        handler(SdkAuthError(reason: parsed.reason, endpoint: endpoint, refreshExhausted: false, rawReason: parsed.rawReason))
        guard let refreshed = await waitForRefreshedToken(differentFrom: failedToken), refreshed != failedToken else {
            handler(SdkAuthError(reason: parsed.reason, endpoint: endpoint, refreshExhausted: true, rawReason: parsed.rawReason))
            return (status, data, http, parsed.reason)
        }
        (status, data, http) = try await performRaw(endpoint: endpoint, method: "POST", body: body, subject: subject)
        if status == 401, let again = Self.parseSdkAuthError(from: data) {
            handler(SdkAuthError(reason: again.reason, endpoint: endpoint, refreshExhausted: true, rawReason: again.rawReason))
            return (status, data, http, again.reason)
        }
        return (status, data, http, nil)
    }

    // MARK: - Durable writes (identify, addAlias, subscriptions, the opt-out record, push unregister)

    /// What the server did with one durable write, reduced to what the write
    /// outbox must DO about it (SDK contracts 15 and 28).
    enum WriteOutcome: Equatable {
        /// 2xx, not `success: false`: stored.
        case done
        /// The server refused it for good - 400 / 403 / 409 / 413 / 422 and
        /// the other 4xx it would repeat forever. Dropped with a log line.
        case refused(status: Int)
        /// 404: no profile yet (subscriptions). Retried after the queued
        /// events are flushed, a bounded number of times.
        case notFound
        /// 401 that the SDK-authentication refresh could not fix.
        case authRejected(reason: SdkAuthErrorReason?)
        /// Kept and retried. `answered`: whether this answer counts toward
        /// the write's attempt cap (contract v4, 40 - one rule on every SDK):
        /// 2xx `success: false` counts; offline, timeouts (408), 402, 429
        /// and 5xx NEVER do - a device offline for a week, a server down for
        /// a day, or an account paused for billing (402) keeps the write.
        /// The same as Android and web: 402 used to count here alone, so a
        /// write was dropped after ten tries against a paused account that
        /// the other SDKs kept until it was restored.
        case retry(retryAfter: TimeInterval?, answered: Bool)
        /// 402: ingestion paused for the workspace. Never counted. The
        /// outbox parks the writes that are not withdrawals and still sends
        /// the withdrawals behind them, which the server accepts from a
        /// paused account (SDK contract v5, 50).
        case suspended(retryAfter: TimeInterval?)
    }

    /// POST one durable write as ONE attempt; the outbox owns retries.
    func sendWrite(path: String, body: Data, userId: String?) async -> WriteOutcome {
        let endpoint = "\(apiEndpoint)\(path)"
        do {
            let (status, data, http, authReason) = try await performRawWithAuth(endpoint: endpoint, body: body, requestUserId: userId)
            if let authReason {
                onTransportFailure?(NetworkError.sdkAuthError(reason: authReason, endpoint: endpoint, rawReason: authReason.rawValue))
                return .authRejected(reason: authReason)
            }
            let outcome = Self.classifyWriteResponse(
                status: status,
                body: data,
                retryAfterHeader: http.value(forHTTPHeaderField: "Retry-After")
            )
            if outcome == .done { onTransportSuccess?() } else { onTransportFailure?(NetworkError.httpError(status)) }
            return outcome
        } catch {
            onTransportFailure?(error)
            return .retry(retryAfter: nil, answered: false)
        }
    }

    /// Pure classification of a durable write's answer (unit-testable).
    static func classifyWriteResponse(status: Int, body: Data, retryAfterHeader: String?) -> WriteOutcome {
        switch status {
        case 200...299:
            return isRejection(body) ? .retry(retryAfter: nil, answered: true) : .done
        case 401:
            return .authRejected(reason: nil)
        case 404:
            return .notFound
        case 402:
            return .suspended(retryAfter: parseRetryAfter(retryAfterHeader))
        case 408, 429:
            // A timeout and a rate limit say nothing about the write itself.
            return .retry(retryAfter: parseRetryAfter(retryAfterHeader), answered: false)
        case 400...499:
            // 403 included: a write the identity policy refuses is dropped,
            // so it never blocks the writes behind it (SDK contract 28).
            return .refused(status: status)
        default:
            // 5xx: the server's failure, never the write's (contract v4, 40).
            return .retry(retryAfter: parseRetryAfter(retryAfterHeader), answered: false)
        }
    }

    /// Pure classification, separated so the contract is unit-testable
    /// without a server.
    static func classifyBatchResponse(
        status: Int,
        body: Data,
        retryAfterHeader: String?,
        batchCount: Int
    ) -> BatchOutcome {
        switch status {
        case 200...299:
            let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            func positions(_ key: String) -> [Int]? {
                (json?[key] as? [Any])?
                    .compactMap { ($0 as? NSNumber)?.intValue }
                    .filter { $0 >= 0 && $0 < batchCount }
            }
            // Refused FOR GOOD (property limits, invalid): dropped, never
            // retried. `failedIndices` stays "retry" (SDK contract 29).
            let rejected = Set(positions("rejectedIndices") ?? [])
            guard let success = json?["success"] as? Bool, success == false else {
                return rejected.isEmpty ? .accepted : .partial(failedIndices: [])
            }
            // A 200 that says `success: false` used to be treated as success,
            // and the batch was DELETED - events the server had just said it
            // did not store. Keep what it names; without a list, keep it all -
            // except what it refused for good.
            let keep: Set<Int>
            if let failed = positions("failedIndices"), !failed.isEmpty {
                keep = Set(failed)
            } else {
                keep = Set(0..<batchCount)
            }
            return .partial(failedIndices: keep.subtracting(rejected).sorted())
        case 400, 413, 422:
            return .rejected(status: status)
        case 401:
            return .authFailed(reason: nil)
        case 402, 403:
            return .suspended(status: status)
        default:
            if status == 429 || status >= 500 {
                return .retryLater(retryAfter: parseRetryAfter(retryAfterHeader))
            }
            // Any other 4xx is a client error the server will repeat forever;
            // treat it like the explicit rejections so it cannot wedge the queue.
            return .rejected(status: status)
        }
    }

    /// One HTTP exchange with the standard SDK headers, returning whatever the
    /// server said instead of throwing on a non-2xx status.
    private func performRaw(
        endpoint: String,
        method: String,
        body: Data,
        subject: AuthSubject = .readFromBody
    ) async throws -> (Int, Data, HTTPURLResponse) {
        guard let url = URL(string: endpoint) else { throw NetworkError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(sdkKey, forHTTPHeaderField: "Authorization")
        request.setValue(sdkKey, forHTTPHeaderField: "X-App-Key")
        if let authToken = authToken(routing: body, subject: subject) {
            request.setValue(authToken, forHTTPHeaderField: "X-Joryio-Auth")
        }
        request.httpBody = body
        logger.debug("Sending \(method) request to \(endpoint)")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NetworkError.invalidResponse }
        logger.debug("Response status: \(http.statusCode)")
        return (http.statusCode, data, http)
    }

    // MARK: - User Identification

    func identify(_ request: IdentifyRequest) async throws {
        let endpoint = "\(apiEndpoint)/v1/identify"
        try await sendRequest(endpoint: endpoint, method: "POST", body: request)
        logger.debug("User identified: \(maskIdentifier(request.userId))")
    }

    /// A labelled alias (`/v1/alias/add`). Works for an anonymous visitor too:
    /// the request carries the anonymous id always and the user id only when
    /// there is one.
    func addAlias(_ request: AddAliasRequest) async throws {
        let endpoint = "\(apiEndpoint)/v1/alias/add"
        try await sendRequest(endpoint: endpoint, method: "POST", body: request)
        logger.debug("Alias added: \(request.aliasLabel)")
    }

    func setAttributes(_ request: SetAttributesRequest) async throws {
        let endpoint = "\(apiEndpoint)/v1/attributes"
        try await sendRequest(endpoint: endpoint, method: "POST", body: request)
        logger.debug("Attributes set for user")
    }

    // MARK: - Subscriptions (marketing, not tracking consent)

    func updateChannelSubscription(_ request: ChannelSubscriptionRequest) async throws {
        let endpoint = "\(apiEndpoint)/v1/subscriptions/channel"
        try await sendRequest(endpoint: endpoint, method: "POST", body: request)
        logger.debug("Subscription updated for channel \(request.channel)")
    }

    func updateSubscriptionGroup(_ request: SubscriptionGroupRequest) async throws {
        let endpoint = "\(apiEndpoint)/v1/subscriptions/group"
        try await sendRequest(endpoint: endpoint, method: "POST", body: request)
        logger.debug("Subscription group \(request.groupId) \(request.action)d")
    }

    // MARK: - In-App Messaging

    /// Display-time re-check for a `reevaluateBeforeDisplay` campaign.
    func resolveInAppCampaign(_ request: ResolveRequest) async throws -> ResolveResponse {
        let endpoint = "\(apiEndpoint)/v1/in-app/resolve"
        return try await sendRequest(endpoint: endpoint, method: "POST", body: request)
    }

    func syncInAppCampaigns(_ request: SessionSyncRequest) async throws -> SessionSyncResponse {
        let endpoint = "\(apiEndpoint)/v1/in-app/sync"
        let response: SessionSyncResponse = try await sendRequest(
            endpoint: endpoint,
            method: "POST",
            body: request
        )
        logger.debug("In-app campaigns synced: \(response.campaigns.count) campaigns")
        return response
    }

    func trackImpression(_ request: TrackImpressionRequest) async throws {
        let endpoint = "\(apiEndpoint)/v1/in-app/track"
        try await sendRequest(endpoint: endpoint, method: "POST", body: request)
        logger.debug("Impression tracked: \(request.campaignId)")
    }

    /// A form inside a message: the values go to the backend with this SDK's identity (same route the web SDK uses).
    func submitInAppForm(_ request: InAppFormSubmitRequest) async throws -> InAppFormSubmitResponse {
        let endpoint = "\(apiEndpoint)/v1/in-app/form-submit"
        // ONE attempt. A submission is not idempotent: a timeout or a 5xx can
        // arrive after the server stored the values, and the retry loop then
        // submitted the same form two or three times. The person retries from
        // the form, which says the attempt failed.
        let response: InAppFormSubmitResponse = try await sendRequest(
            endpoint: endpoint, method: "POST", body: request, maxAttempts: 1
        )
        logger.debug("In-app form submitted: \(request.campaignId) ok=\(response.ok)")
        return response
    }

    // MARK: - Push Notifications

    func registerPushToken(userId: String?, anonymousId: String, deviceToken: String, deviceId: String?, deviceInfo: [String: Any]) async throws {
        let endpoint = "\(apiEndpoint)/v1/push/register"
        let body = PushTokenRequest(
            userId: userId,
            anonymousId: anonymousId,
            token: deviceToken,
            platform: "ios",
            deviceId: deviceId,
            deviceInfo: deviceInfo
        )
        try await sendRequest(endpoint: endpoint, method: "POST", body: body)
        logger.debug("Push token registered")
    }

    /// Tell the backend this token no longer belongs to a reachable device.
    /// `unregisterPush()` used to stop at the OS: the server kept the token
    /// and kept sending to it. Android and web have always called this.
    func unregisterPushToken(userId: String?, anonymousId: String, deviceToken: String) async throws {
        let endpoint = "\(apiEndpoint)/v1/push/unregister"
        let body = UnregisterPushTokenRequest(
            userId: userId,
            anonymousId: anonymousId,
            token: deviceToken,
            platform: "ios"
        )
        try await sendRequest(endpoint: endpoint, method: "POST", body: body)
        logger.debug("Push token unregistered")
    }

    /// Scheme + host (+ port) of the API endpoint, with any path - `/api`
    /// included - removed.
    ///
    /// The push receipt and click routes are mounted at the HOST ROOT
    /// (`/track/push/...`), not under `/api` like the SDK routes. They used to
    /// be built on `apiEndpoint`, which `normalizeApiEndpoint` always ends in
    /// `/api`, so every receipt and click went to `/api/track/push/...`.
    static func trackingRoot(of apiEndpoint: String) -> String {
        guard var components = URLComponents(string: apiEndpoint), components.host != nil else {
            var trimmed = apiEndpoint
            if trimmed.hasSuffix("/api") { trimmed.removeLast(4) }
            return trimmed
        }
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.string ?? apiEndpoint
    }

    private var trackingRoot: String { Self.trackingRoot(of: apiEndpoint) }

    /// Report that a push ARRIVED on this device.
    ///
    /// The only positive delivery signal push can produce: APNs answers a send
    /// with "accepted" and never reports what reached the handset, so the
    /// device saying so for itself is the difference between "Apple took it"
    /// and "it reached someone".
    ///
    /// `trackingId` is HMAC-signed by the backend and identifies the campaign,
    /// variant and recipient - this device asserts none of them.
    func reportPushDelivered(trackingId: String) async throws {
        // Root-mounted, like trackPushClick below: the signed trackingId is the
        // authority, and the same route serves the web service worker, which
        // has no SDK key at all. Built on the HOST ROOT - see trackingRoot.
        let endpoint = "\(trackingRoot)/track/push/delivered/\(trackingId)"
        guard let url = URL(string: endpoint) else { throw NetworkError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        _ = try await session.data(for: request)
        logger.debug("Push delivery receipt sent")
    }

    func trackPushClick(trackingId: String) async throws {
        let endpoint = "\(trackingRoot)/track/push/click/\(trackingId)"

        guard let url = URL(string: endpoint) else {
            throw NetworkError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Carry the SDK-auth JWT on this beacon too when enabled - routed by
        // `sub` like every other request (SDK contract v7 72, v8 82): the
        // signed-in user's own token, never one set for someone else before
        // their identify() (scan 8, N3), and none for an anonymous visitor.
        // The route authenticates by the signed trackingId; the header is
        // informational. A fire-and-forget GET: no refresh-and-retry flow.
        if let authToken = authToken(forBody: nil) {
            request.setValue(authToken, forHTTPHeaderField: "X-Joryio-Auth")
        }

        let (_, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NetworkError.invalidResponse
        }

        if httpResponse.statusCode != 200 {
            throw NetworkError.httpError(httpResponse.statusCode)
        }

        logger.debug("Push click tracked: \(trackingId)")
    }

    // MARK: - Generic Request Handler

    /// Max backoff cap (seconds) so exponential growth can't produce huge sleeps.
    private let maxBackoffSeconds: Double = 30.0

    private func sendRequest<T: Encodable, R: Decodable>(
        endpoint: String,
        method: String,
        body: T,
        maxAttempts: Int? = nil
    ) async throws -> R {
        var lastError: Error?
        let retries = maxAttempts.map { max(0, $0 - 1) } ?? maxRetries

        for attempt in 0...retries {
            do {
                let result: R = try await performRequestWithAuthRetry(endpoint: endpoint, method: method, body: body)
                onTransportSuccess?()
                return result
            } catch {
                lastError = error

                // Fail fast on non-retryable errors (401 and 4xx except 429).
                // Retrying these just hammers the server and never succeeds.
                guard isRetryable(error), !Self.isServerVerdict(error) else {
                    logger.warn("Request failed, not retrying now: \(error.localizedDescription)")
                    onTransportFailure?(error)
                    throw error
                }

                logger.warn("Request failed (attempt \(attempt + 1)/\(retries + 1)): \(error.localizedDescription)")

                if attempt < retries {
                    let delay = retryDelay(for: error, attempt: attempt)
                    logger.debug("Retrying after \(String(format: "%.2f", delay))s...")
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }
        }

        // Every retry exhausted. Report before throwing, so the host app can
        // see a sustained outage and not only a one-off blip.
        if let lastError { onTransportFailure?(lastError) }
        throw lastError ?? NetworkError.unknown
    }

    /// Whether an error is worth retrying. 401 and 4xx (except 429) are permanent.
    /// Internal (not private) so the facade can classify `lastTransportError`
    /// with the SAME rule the retry loop uses.
    func isRetryable(_ error: Error) -> Bool {
        if let netError = error as? NetworkError {
            switch netError {
            case .unauthorized, .invalidURL, .invalidResponse:
                return false
            case .sdkAuthError:
                // The one-shot refresh-and-retry already ran inside
                // performRequestWithAuthRetry; never loop the outer retry on it.
                return false
            case .rateLimited:
                return true
            case .serverRejected:
                // Kept and retried LATER by the caller - never acknowledged.
                return true
            case .httpError(let code):
                // Only server errors are transient; other 4xx are permanent.
                return code >= 500
            case .unknown:
                return true
            }
        }
        // Transport-level errors (timeouts, connection loss) are retryable.
        return true
    }

    /// Compute the retry delay: honor Retry-After for 429, otherwise capped
    /// exponential backoff with jitter to avoid a synchronized retry storm.
    private func retryDelay(for error: Error, attempt: Int) -> Double {
        if case NetworkError.rateLimited(let retryAfter) = error, let retryAfter = retryAfter {
            return min(retryAfter, maxBackoffSeconds)
        }
        let base = retryBackoffMs * pow(2.0, Double(attempt)) / 1000.0
        let capped = min(base, maxBackoffSeconds)
        let jitter = Double.random(in: 0...(capped * 0.3))
        return capped + jitter
    }

    private func sendRequest<T: Encodable>(
        endpoint: String,
        method: String,
        body: T,
        maxAttempts: Int? = nil
    ) async throws {
        let _: EmptyResponse = try await sendRequest(endpoint: endpoint, method: method, body: body, maxAttempts: maxAttempts)
    }

    /// A 2xx whose body says `success: false` is the server's considered
    /// answer, not a blip: the request loop does not hammer it, but the caller
    /// keeps its data and tries again later (SDK contract 15).
    static func isServerVerdict(_ error: Error) -> Bool {
        if case NetworkError.serverRejected = error { return true }
        return false
    }

    /// Longest we'll wait for the app to supply a refreshed token after invoking
    /// the auth-error handler. The handler may set the token synchronously (loop
    /// returns on the first check) or asynchronously (bounded poll below).
    private let authRefreshWaitSeconds: Double = 5.0

    /// Wrap `performRequest` with the SDK-authentication one-shot refresh flow.
    ///
    /// On a 401 that decodes to `sdk_authentication_error`, invoke the app's
    /// error handler, wait (bounded) for a fresh token, and retry the request
    /// exactly ONCE with it. This is deliberately separate from the transient
    /// retry/backoff loop in `sendRequest` — an sdk-auth 401 is not a normal
    /// retry, it's a refresh-and-retry, and it never loops.
    ///
    /// Queue interaction: on failure this simply throws. The QueueManager
    /// deletes a batch only after a successful send, so the events stay queued
    /// and the next flush carries whatever token is current — we neither drop
    /// nor duplicate a batch on auth failure.
    private func performRequestWithAuthRetry<T: Encodable, R: Decodable>(
        endpoint: String,
        method: String,
        body: T
    ) async throws -> R {
        do {
            return try await performRequest(endpoint: endpoint, method: method, body: body)
        } catch let NetworkError.sdkAuthError(reason, ep, raw) {
            // Only meaningful when SDK auth is enabled; otherwise rethrow.
            guard authStore.enabled else { throw NetworkError.sdkAuthError(reason: reason, endpoint: ep, rawReason: raw) }

            let failedToken = authStore.currentToken()

            guard let handler = authStore.currentHandler() else {
                logger.warn("SDK auth rejected (\(reason.rawValue)) at \(ep) but no error handler is set; leaving request unsent")
                throw NetworkError.sdkAuthError(reason: reason, endpoint: ep, rawReason: raw)
            }

            // Ask the app to mint a fresh token. It responds by calling
            // setSdkAuthenticationToken(_:), synchronously or asynchronously.
            handler(SdkAuthError(reason: reason, endpoint: ep, refreshExhausted: false, rawReason: raw))

            if let refreshed = await waitForRefreshedToken(differentFrom: failedToken),
               refreshed != failedToken {
                logger.debug("Retrying \(ep) once with refreshed SDK auth token")
                // performRequest re-reads the (now refreshed) token from the store.
                return try await performRequest(endpoint: endpoint, method: method, body: body)
            }

            // No fresh token arrived in time — surface exhaustion and stop (no loop).
            logger.warn("No refreshed SDK auth token after handler for \(ep); not retrying")
            handler(SdkAuthError(reason: reason, endpoint: ep, refreshExhausted: true, rawReason: raw))
            throw NetworkError.sdkAuthError(reason: reason, endpoint: ep, rawReason: raw)
        }
    }

    /// Bounded poll for the app to install a token different from the one that
    /// just failed. Returns as soon as it changes (synchronous handlers hit the
    /// first check and never sleep); returns the current token after the
    /// deadline otherwise.
    private func waitForRefreshedToken(differentFrom old: String?) async -> String? {
        let deadline = Date().addingTimeInterval(authRefreshWaitSeconds)
        while Date() < deadline {
            if let current = authStore.currentToken(), current != old {
                return current
            }
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }
        return authStore.currentToken()
    }

    private func performRequest<T: Encodable, R: Decodable>(
        endpoint: String,
        method: String,
        body: T
    ) async throws -> R {
        guard let url = URL(string: endpoint) else {
            throw NetworkError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(sdkKey, forHTTPHeaderField: "Authorization")
        request.setValue(sdkKey, forHTTPHeaderField: "X-App-Key")

        let encoder = WireJSON.encoder()
        let encoded = try encoder.encode(body)
        request.httpBody = encoded

        // Attach the customer-minted SDK-authentication JWT when enabled and set.
        // Read fresh on the network thread so a refreshed token is picked up.
        if let authToken = authToken(forBody: encoded) {
            request.setValue(authToken, forHTTPHeaderField: "X-Joryio-Auth")
        }

        logger.debug("Sending \(method) request to \(endpoint)")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NetworkError.invalidResponse
        }

        logger.debug("Response status: \(httpResponse.statusCode)")

        guard (200...299).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 401 {
                // Distinguish a customer-JWT rejection (triggers refresh-and-retry)
                // from a plain unauthorized (bad SDK key — permanent).
                if let parsed = Self.parseSdkAuthError(from: data) {
                    throw NetworkError.sdkAuthError(
                        reason: parsed.reason,
                        endpoint: endpoint,
                        rawReason: parsed.rawReason
                    )
                }
                throw NetworkError.unauthorized
            } else if httpResponse.statusCode == 429 {
                let retryAfter = Self.parseRetryAfter(httpResponse.value(forHTTPHeaderField: "Retry-After"))
                throw NetworkError.rateLimited(retryAfter: retryAfter)
            } else {
                throw NetworkError.httpError(httpResponse.statusCode)
            }
        }

        // SDK contract 15: a 2xx that says `success: false` is a FAILURE on
        // every route - attributes, identify, addAlias, subscriptions, push
        // registration. It used to decode as success, so the caller
        // acknowledged a write the server had just said it did not store
        // (the identity service answers a database error this way).
        if Self.isRejection(data) {
            throw NetworkError.serverRejected(message: Self.rejectionMessage(in: data))
        }

        let decoder = WireJSON.decoder()
        return try decoder.decode(R.self, from: data)
    }

    /// Is this 2xx body `{ "success": false, ... }`? A body without a
    /// `success` key (or with `true`) is an acceptance.
    static func isRejection(_ data: Data) -> Bool {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let success = json["success"] as? Bool
        else { return false }
        return success == false
    }

    private static func rejectionMessage(in data: Data) -> String? {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return (json?["error"] as? String) ?? (json?["message"] as? String)
    }

    // MARK: - Errors

    /// Invoked on every request the client gives up on. Set by Joryio so the
    /// facade can expose the last failure to the host app.
    var onTransportFailure: ((Error) -> Void)?

    /// Cleared on any success, so a stale failure is never shown as current.
    var onTransportSuccess: (() -> Void)?

    enum NetworkError: Error {
        case invalidURL
        case invalidResponse
        case unauthorized
        case rateLimited(retryAfter: TimeInterval?)
        case httpError(Int)
        /// A 401 whose body is `{ error: "sdk_authentication_error", reason: ... }`.
        /// Carries the reason and endpoint so the refresh flow can surface context.
        case sdkAuthError(reason: SdkAuthErrorReason, endpoint: String, rawReason: String?)
        /// 2xx with `success: false`: the server answered and did not store it.
        case serverRejected(message: String?)
        case unknown
    }

    /// Whose request it is, for routing the SDK-authentication token.
    enum AuthSubject {
        /// Read the user from the body (`subjectUserId(of:)`).
        case readFromBody
        /// The caller already knows the user (nil: anonymous) - an event
        /// batch, cut at a user change by the queue.
        case known(String?)
    }

    /// The SDK-authentication token for a request body: the one whose `sub`
    /// is the request's user (SDK contract v7, 72 - see
    /// `SdkAuthTokenStore.token(forSubject:currentUserId:)`). The body is
    /// parsed only when a token could be attached at all (a session token or
    /// a kept one) and the caller does not already know the user. The
    /// current user is asked only for a bodyless request or an unreadable
    /// session token (a Keychain read while a user is held).
    func authToken(forBody body: Data?) -> String? {
        guard authStore.enabled, authStore.hasAnyToken else { return nil }
        // A bodyless request (an in-app GET, the push-click beacon) is about
        // whoever is signed in; otherwise the body names the subject, and an
        // anonymous one carries no token (contract v7 72).
        let current: () -> String? = { [weak self] in self?.currentUserId() }
        let subject = body.map { Self.subjectUserId(of: $0) } ?? current()
        return authStore.token(forSubject: subject, currentUserId: current)
    }

    /// `authToken(forBody:)` when the caller already knows the request's user
    /// (nil: anonymous) - the body is not read.
    func authToken(forKnownSubject subject: String?) -> String? {
        guard authStore.enabled, authStore.hasAnyToken else { return nil }
        return authStore.token(forSubject: subject, currentUserId: { [weak self] in self?.currentUserId() })
    }

    /// The token for a request, by `subject`.
    func authToken(routing body: Data, subject: AuthSubject) -> String? {
        switch subject {
        case .readFromBody: return authToken(forBody: body)
        case .known(let user): return authToken(forKnownSubject: user)
        }
    }

    /// The identified user a request body is about (nil: anonymous) - the
    /// same fields the server binds the token to.
    static func subjectUserId(of body: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        func nonEmpty(_ v: Any?) -> String? {
            guard let s = v as? String, !s.isEmpty else { return nil }
            return s
        }
        if let u = nonEmpty(json["userId"]) ?? nonEmpty(json["externalId"]) { return u }
        if let identify = json["identify"] as? [String: Any], let u = nonEmpty(identify["userId"]) { return u }
        for key in ["events", "impressions"] {
            if let list = json[key] as? [[String: Any]],
               let u = list.lazy.compactMap({ nonEmpty($0["userId"]) }).first {
                return u
            }
        }
        return nil
    }

    /// Body shape of a backend SDK-authentication rejection.
    private struct SdkAuthErrorBody: Decodable {
        let error: String
        let reason: String?
    }

    /// Decode a 401 body into an `SdkAuthErrorReason` if it is an
    /// `sdk_authentication_error`; otherwise nil (a plain unauthorized).
    private static func parseSdkAuthError(
        from data: Data
    ) -> (reason: SdkAuthErrorReason, rawReason: String?)? {
        guard
            let body = try? JSONDecoder().decode(SdkAuthErrorBody.self, from: data),
            body.error == "sdk_authentication_error"
        else {
            return nil
        }
        // Both halves: the mapped enum for branching, and what the server
        // literally said for the `.unknown` case.
        return (SdkAuthErrorReason(backendReason: body.reason), body.reason)
    }

    /// Parse a `Retry-After` header. Supports the delta-seconds form (e.g. "30")
    /// and the HTTP-date form; returns nil if absent or unparseable.
    static func parseRetryAfter(_ value: String?) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else {
            return nil
        }
        if let seconds = TimeInterval(value) {
            return max(0, seconds)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = formatter.date(from: value) {
            return max(0, date.timeIntervalSinceNow)
        }
        return nil
    }

    private struct EmptyResponse: Decodable {
        let success: Bool?
    }
}

/// Log-safe form of an end-user identifier.
///
/// Passes an ordinary id through UNCHANGED. Our docs tell customers not to use
/// an email as the userId - among other reasons, a guessable id lets someone
/// forge another user's data - so the normal case is an opaque id that is not
/// PII, and masking it would only make a debug log useless for tracing one
/// user's problem.
///
/// Masks ONLY when the value looks like an email, i.e. when a customer ignored
/// that guidance. Defence in depth for the non-compliant case, zero cost to the
/// compliant one.
///
/// Note these logs are gated behind the debug log level, so a release build
/// emits nothing either way.
internal func maskIdentifier(_ value: String?) -> String {
    guard let value, !value.isEmpty else { return "(none)" }
    // Not an email → not PII by our own contract → log it in full.
    guard let at = value.firstIndex(of: "@"), at > value.startIndex else { return value }

    let local = String(value[value.startIndex..<at])
    let domain = String(value[value.index(after: at)...])
    let tld = domain.lastIndex(of: ".").map { String(domain[$0...]) } ?? ""
    return "\(local.first.map(String.init) ?? "?")***@\(domain.first.map(String.init) ?? "?")***\(tld)"
}
