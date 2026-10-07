import XCTest
@testable import Joryio

/// SDK contract 3 on iOS: what the queue does with each server answer.
///
/// Every test here failed against the 1.3.0-rc queue, which treated anything
/// but a thrown error as success (deleting what a `success: false` response
/// had just refused), re-sent a rejected batch forever at the head of the
/// queue, and deleted "the first N rows" after a send.
final class EventQueueContractTests: XCTestCase {

    /// Scripted answers, one per request, recording what was sent.
    final class FakeSender: EventBatchSender {
        var answers: [([String]) -> NetworkClient.BatchOutcome] = []
        var sent: [[String]] = []
        var defaultAnswer: NetworkClient.BatchOutcome = .accepted
        var onSend: (([String]) -> Void)?

        func sendEventBatch(_ eventsJSON: [String], userId: String?) async -> NetworkClient.BatchOutcome {
            sent.append(eventsJSON)
            onSend?(eventsJSON)
            if !answers.isEmpty { return answers.removeFirst()(eventsJSON) }
            return defaultAnswer
        }
    }

    private func makeQueue(
        sender: FakeSender,
        storage: StorageManager,
        batchSize: Int = 50,
        maxQueueSize: Int = 1000
    ) -> QueueManager {
        QueueManager(
            storage: storage,
            sender: sender,
            logger: TestSupport.logger(),
            batchSize: batchSize,
            flushInterval: 3600,
            maxQueueSize: maxQueueSize,
            sendImmediately: false,
            startTimer: false
        )
    }

    private func types(in storage: StorageManager) throws -> [String] {
        try storage.dequeueEvents(limit: 10_000).map(\.type)
    }

    private func enqueue(_ names: [String], into storage: StorageManager) throws {
        for name in names { try storage.enqueueEvent(TestSupport.event(name)) }
    }

    func testRejectedBatchIsBisectedAndOnlyTheBadEventIsDropped() async throws {
        let storage = TestSupport.storage()
        try enqueue(["a", "b", "BAD", "d"], into: storage)
        let sender = FakeSender()
        // The server refuses any request containing the bad event.
        sender.answers = Array(repeating: { json in
            json.contains { $0.contains("\"BAD\"") } ? .rejected(status: 400) : .accepted
        }, count: 10)
        let queue = makeQueue(sender: sender, storage: storage)

        await queue.flush()

        XCTAssertEqual(try types(in: storage), [], "the valid events are delivered and the bad one dropped")
        let delivered = sender.sent.filter { !$0.contains { $0.contains("\"BAD\"") } }.flatMap { $0 }
        XCTAssertEqual(delivered.count, 3)
    }

    func testSuccessFalseKeepsTheFailedIndicesAndDeletesTheRest() async throws {
        let storage = TestSupport.storage()
        try enqueue(["e0", "e1", "e2", "e3"], into: storage)
        let sender = FakeSender()
        sender.answers = [{ _ in .partial(failedIndices: [1, 3]) }]
        let queue = makeQueue(sender: sender, storage: storage)

        await queue.flush()

        XCTAssertEqual(try types(in: storage), ["e1", "e3"])
    }

    func testRetryableFailureKeepsEverythingAndBacksOff() async throws {
        let storage = TestSupport.storage()
        try enqueue(["a", "b"], into: storage)
        let sender = FakeSender()
        sender.defaultAnswer = .retryLater(retryAfter: 60)
        let queue = makeQueue(sender: sender, storage: storage)

        await queue.flush()
        await queue.flush() // inside the backoff window: no second request

        XCTAssertEqual(try types(in: storage), ["a", "b"])
        XCTAssertEqual(sender.sent.count, 1)
    }

    func testSuspensionStopsSendingForTheSessionAndKeepsEvents() async throws {
        let storage = TestSupport.storage()
        try enqueue(["a"], into: storage)
        let sender = FakeSender()
        sender.defaultAnswer = .suspended(status: 402)
        let queue = makeQueue(sender: sender, storage: storage)

        await queue.flush()
        queue.resetBackoff()
        await queue.flush()

        XCTAssertTrue(queue.isSuspended)
        XCTAssertEqual(sender.sent.count, 1)
        XCTAssertEqual(try types(in: storage), ["a"])
    }

    func testBatchSizeIsCappedAtTheServerLimit() async throws {
        let storage = TestSupport.storage()
        try enqueue((0..<620).map { "e\($0)" }, into: storage)
        let sender = FakeSender()
        let queue = makeQueue(sender: sender, storage: storage, batchSize: 5000)

        await queue.flush()

        XCTAssertEqual(sender.sent.first?.count, 500)
        XCTAssertEqual(sender.sent.map(\.count), [500, 120])
    }

    /// Deleting "the first N rows" after a send removed the wrong events when
    /// the cap trimmed the head of the queue mid-flight: the newest event was
    /// deleted and the trimmed one was "delivered" twice over.
    func testDeletesTheRowsItSentNotTheFirstN() async throws {
        let storage = TestSupport.storage()
        try enqueue(["e1", "e2", "e3"], into: storage)
        let sender = FakeSender()
        let queue = makeQueue(sender: sender, storage: storage, batchSize: 3, maxQueueSize: 3)
        sender.onSend = { [weak queue] _ in
            // A new event arrives while the batch is in flight; the cap trims e1.
            sender.onSend = nil
            queue?.enqueue(TestSupport.event("e4"))
        }

        await queue.flush()

        // e1 was trimmed by the cap, e2/e3 delivered in the first batch, and
        // e4 - which deleting "the first 3 rows" used to destroy unsent - goes
        // out in the second.
        XCTAssertEqual(sender.sent.count, 2)
        XCTAssertTrue(sender.sent[1].contains { $0.contains("\"e4\"") }, "the event that arrived mid-flight must be sent")
        XCTAssertEqual(try types(in: storage), [])
    }

    func testNothingLeavesWhileSendingIsNotPermitted() async throws {
        let storage = TestSupport.storage()
        try enqueue(["a"], into: storage)
        let sender = FakeSender()
        let queue = makeQueue(sender: sender, storage: storage)
        queue.canSend = { false } // consent pending

        await queue.flush()

        XCTAssertTrue(sender.sent.isEmpty)
        XCTAssertEqual(try types(in: storage), ["a"])
    }

    func testOnlyTheCapDropsEventsOldestFirst() throws {
        let storage = TestSupport.storage()
        let queue = makeQueue(sender: FakeSender(), storage: storage, maxQueueSize: 3)
        for name in ["a", "b", "c", "d", "e"] { queue.enqueue(TestSupport.event(name)) }
        XCTAssertEqual(try types(in: storage), ["c", "d", "e"])
    }

    // MARK: - Response classification

    private func classify(_ status: Int, _ body: String = "{}", count: Int = 3) -> NetworkClient.BatchOutcome {
        NetworkClient.classifyBatchResponse(status: status, body: Data(body.utf8), retryAfterHeader: nil, batchCount: count)
    }

    func testClassification() {
        XCTAssertEqual(classify(200, #"{"success":true}"#), .accepted)
        XCTAssertEqual(classify(200, #"{"success":false,"failedIndices":[2]}"#), .partial(failedIndices: [2]))
        XCTAssertEqual(classify(200, #"{"success":false}"#), .partial(failedIndices: [0, 1, 2]),
                       "no list means the whole batch failed")
        XCTAssertEqual(classify(400), .rejected(status: 400))
        XCTAssertEqual(classify(413), .rejected(status: 413))
        XCTAssertEqual(classify(422), .rejected(status: 422))
        XCTAssertEqual(classify(402), .suspended(status: 402))
        XCTAssertEqual(classify(403), .suspended(status: 403))
        XCTAssertEqual(classify(401), .authFailed(reason: nil))
        XCTAssertEqual(classify(503), .retryLater(retryAfter: nil))
        XCTAssertEqual(
            NetworkClient.classifyBatchResponse(status: 429, body: Data(), retryAfterHeader: "30", batchCount: 1),
            .retryLater(retryAfter: 30)
        )
    }

    func testRequestsStayUnderTheByteLimit() {
        let big = String(repeating: "x", count: 400_000)
        let rows = (0..<5).map { StorageManager.QueuedEvent(id: Int64($0), json: "\"\(big)\"") }
        XCTAssertEqual(QueueManager.limitByBytes(rows).count, 2)
        XCTAssertEqual(QueueManager.limitByBytes([rows[0]]).count, 1, "a single event is always attempted")
    }
}
