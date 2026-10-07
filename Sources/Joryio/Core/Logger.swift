import Foundation
import os.log

/// Logger for SDK debugging and diagnostics
public class Logger {
    private let enabled: Bool
    private let logLevel: JoryioConfig.LogLevel
    private let subsystem = "io.joryio.sdk"

    init(enabled: Bool, logLevel: JoryioConfig.LogLevel) {
        self.enabled = enabled
        self.logLevel = logLevel
    }

    func error(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        log(message, level: .error, file: file, function: function, line: line)
    }

    func warn(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        guard shouldLog(.warn) else { return }
        log(message, level: .warn, file: file, function: function, line: line)
    }

    func info(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        guard shouldLog(.info) else { return }
        log(message, level: .info, file: file, function: function, line: line)
    }

    func debug(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        guard shouldLog(.debug) else { return }
        log(message, level: .debug, file: file, function: function, line: line)
    }

    private func shouldLog(_ level: JoryioConfig.LogLevel) -> Bool {
        guard enabled else { return false }

        let levelOrder: [JoryioConfig.LogLevel] = [.error, .warn, .info, .debug]
        guard let currentIndex = levelOrder.firstIndex(of: logLevel),
              let requestedIndex = levelOrder.firstIndex(of: level) else {
            return false
        }

        return requestedIndex <= currentIndex
    }

    private func log(_ message: String, level: JoryioConfig.LogLevel, file: String, function: String, line: Int) {
        guard enabled else { return }

        let fileName = (file as NSString).lastPathComponent
        let prefix = "[\(level.rawValue.uppercased())] [Joryio]"
        let location = "[\(fileName):\(line) \(function)]"

        if #available(iOS 14.0, *) {
            let osLog = OSLog(subsystem: subsystem, category: level.rawValue)
            let osLogType: OSLogType

            switch level {
            case .error:
                osLogType = .error
            case .warn:
                osLogType = .default
            case .info:
                osLogType = .info
            case .debug:
                osLogType = .debug
            }

            os_log("%{public}@ %{public}@ %{public}@", log: osLog, type: osLogType, prefix, location, message)
        } else {
            print("\(prefix) \(location) \(message)")
        }
    }
}
