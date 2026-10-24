import Foundation

/// Session information
public struct SessionInfo: Codable {
    public let sessionId: String
    public let sessionStart: Date
    public var lastActivity: Date

    public init(sessionId: String = UUID().uuidString, sessionStart: Date = Date()) {
        self.sessionId = sessionId
        self.sessionStart = sessionStart
        self.lastActivity = sessionStart
    }

    /// Check if session has expired based on timeout
    public func isExpired(timeout: TimeInterval) -> Bool {
        return Date().timeIntervalSince(lastActivity) > timeout
    }

    /// Update last activity timestamp
    public mutating func updateActivity() {
        self.lastActivity = Date()
    }
}
