import Foundation

/**
 The one JSON shape the SDK writes - to the server and to its own storage.

 Timestamps are ISO 8601 in UTC WITH MILLISECONDS (SDK contract v5, 55), the
 same as Android (`yyyy-MM-dd'T'HH:mm:ss.SSS'Z'`) and web. `JSONEncoder`'s
 `.iso8601` strategy writes whole seconds, so a Session Start and the first
 event of its session, fired within one second, reached the server with the
 SAME timestamp and could not be ordered there - on iOS only.

 The decoder reads both shapes: rows queued by an earlier build carry whole
 seconds, and the server's own dates (JavaScript `toISOString`) carry
 milliseconds, which `.iso8601` decoding refuses.
 */
enum WireJSON {
    /// `ISO8601DateFormatter` is thread-safe; one instance serves every caller.
    private static let withMilliseconds: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    private static let wholeSeconds: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    /// `2026-10-07T09:15:02.123Z`.
    static func timestamp(_ date: Date = Date()) -> String {
        withMilliseconds.string(from: date)
    }

    static func date(from string: String) -> Date? {
        withMilliseconds.date(from: string) ?? wholeSeconds.date(from: string)
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(timestamp(date))
        }
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            guard let date = date(from: raw) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not an ISO 8601 date: \(raw)")
            }
            return date
        }
        return decoder
    }
}

/**
 Non-finite numbers (NaN, +/-Infinity) are not JSON (SDK contract v5, 49).

 One in an event's properties used to make the whole event fail to encode
 and be lost; one in an attribute write failed every flush of the pending
 set, so later attribute writes never reached the server either. The rule on
 every platform: the key (or array element) carrying it is dropped at entry
 with a warning, and the call otherwise goes ahead.
 */
enum FiniteValues {
    static func isNonFinite(_ value: Any) -> Bool {
        if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() { return false }
        switch value {
        case let d as Double: return !d.isFinite
        case let f as Float: return !f.isFinite
        case let d as Decimal: return d.isNaN
        case let n as NSNumber: return !n.doubleValue.isFinite
        default: return false
        }
    }

    /// The dictionary without non-finite numbers, at any depth. `dropped`
    /// receives the dotted path of every key or element removed.
    static func sanitized(_ dict: [String: Any], prefix: String = "", dropped: inout [String]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, raw) in dict {
            let value = Joryio.unwrapped(raw)
            let path = prefix.isEmpty ? key : "\(prefix).\(key)"
            if isNonFinite(value) { dropped.append(path); continue }
            result[key] = sanitizedValue(value, path: path, dropped: &dropped)
        }
        return result
    }

    private static func sanitizedValue(_ value: Any, path: String, dropped: inout [String]) -> Any {
        if let dict = value as? [String: Any] {
            return sanitized(dict, prefix: path, dropped: &dropped)
        }
        if let array = value as? [Any] {
            var kept: [Any] = []
            for (index, raw) in array.enumerated() {
                let element = Joryio.unwrapped(raw)
                if isNonFinite(element) { dropped.append("\(path)[\(index)]"); continue }
                kept.append(sanitizedValue(element, path: "\(path)[\(index)]", dropped: &dropped))
            }
            return kept
        }
        return value
    }
}
