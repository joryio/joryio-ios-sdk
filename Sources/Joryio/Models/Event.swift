import Foundation

/// Represents a tracked event
public struct Event: Codable {
    /// Client-generated idempotency id, mirrors web SDK's `eventId`.
    /// Lets the backend dedupe events that arrive twice after a retry.
    public let eventId: String
    public let type: String
    public let properties: [String: AnyCodable]
    public let timestamp: Date
    public let userId: String?
    public let anonymousId: String
    public let sessionId: String?

    public init(
        type: String,
        properties: EventProperties = [:],
        timestamp: Date = Date(),
        userId: String?,
        anonymousId: String,
        sessionId: String?,
        eventId: String = UUID().uuidString
    ) {
        self.eventId = eventId
        self.type = type
        self.properties = properties.mapValues { AnyCodable($0) }
        self.timestamp = timestamp
        self.userId = userId
        self.anonymousId = anonymousId
        self.sessionId = sessionId
    }

    enum CodingKeys: String, CodingKey {
        case eventId
        case type
        case properties
        case timestamp
        case userId
        case anonymousId
        case sessionId
    }
}

/// Wrapper for encoding/decoding Any values
public struct AnyCodable: Codable {
    public let value: Any

    public init(_ value: Any) {
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let intValue = try? container.decode(Int.self) {
            value = intValue
        } else if let doubleValue = try? container.decode(Double.self) {
            value = doubleValue
        } else if let boolValue = try? container.decode(Bool.self) {
            value = boolValue
        } else if let stringValue = try? container.decode(String.self) {
            value = stringValue
        } else if let arrayValue = try? container.decode([AnyCodable].self) {
            value = arrayValue.map { $0.value }
        } else if let dictValue = try? container.decode([String: AnyCodable].self) {
            value = dictValue.mapValues { $0.value }
        } else if container.decodeNil() {
            value = NSNull()
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported type")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        // Booleans FIRST, by their CoreFoundation type. A boolean that arrives
        // as an NSNumber - from Objective-C, a React Native or Unity bridge, or
        // JSONSerialization - also matches `as Int`, so the switch below sent
        // `true` as `1` and a boolean attribute or property landed as a number.
        // kCFBooleanTrue/False are distinct CF types from every other NSNumber,
        // and a Swift `Bool` bridges to them too, so this one check covers both.
        if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
            try container.encode(number.boolValue)
            return
        }

        switch value {
        case let intValue as Int:
            try container.encode(intValue)
        case let doubleValue as Double:
            try container.encode(doubleValue)
        case let boolValue as Bool:
            try container.encode(boolValue)
        case let stringValue as String:
            try container.encode(stringValue)
        case let arrayValue as [Any]:
            try container.encode(arrayValue.map { AnyCodable($0) })
        case let dictValue as [String: Any]:
            try container.encode(dictValue.mapValues { AnyCodable($0) })
        case is NSNull:
            try container.encodeNil()
        case let dateValue as Date:
            // The active encoder is WireJSON's: ISO 8601 UTC with
            // milliseconds, the string the backend, Android and web use.
            try container.encode(dateValue)
        case let decimalValue as Decimal:
            try container.encode(decimalValue)
        case let numberValue as NSNumber:
            // Bridged NSNumber (e.g. Int64 or values coming from Obj-C / RN
            // dictionaries) that didn't match Int/Double/Bool above.
            try container.encode(numberValue.doubleValue)
        default:
            // Never throw here: a single odd property must not discard the
            // whole event. Coerce anything unknown to a readable string.
            try container.encode(String(describing: value))
        }
    }
}

/// Batch of events for API submission
public struct EventBatch: Codable {
    public let events: [Event]

    public init(events: [Event]) {
        self.events = events
    }
}
