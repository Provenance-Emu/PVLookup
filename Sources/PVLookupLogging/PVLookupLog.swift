import Foundation
import os

/// Severity of a PVLookup log message.
public enum PVLookupLogLevel: Int, Sendable, Comparable {
    case debug, info, warning, error

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A destination for PVLookup's log messages.
///
/// PVLookup can't depend on an app's logging package (a URL package can't
/// depend on a package the app keeps in its own tree), so it logs through this
/// handler instead. The default writes to os_log (subsystem
/// `org.provenance-emu.PVLookup`). An app with its own pipeline installs a
/// handler at launch, before the first lookup:
///
/// ```swift
/// PVLookupLog.handler = { level, message, file, function, line in
///     switch level { case .error: ELOG(message, file: file, function: function, line: line) ... }
/// }
/// ```
public enum PVLookupLog {
    public typealias Handler = @Sendable (
        _ level: PVLookupLogLevel, _ message: String,
        _ file: String, _ function: String, _ line: Int
    ) -> Void

    /// The handler and level, behind a lock.
    private final class Config: @unchecked Sendable {
        let lock = NSLock()
        var handler: Handler = PVLookupLog.osLogHandler
        var minimumLevel: PVLookupLogLevel = .debug
    }
    private static let config = Config()

    /// Where messages go. Defaults to ``osLogHandler``.
    public static var handler: Handler {
        get { config.lock.withLock { config.handler } }
        set { config.lock.withLock { config.handler = newValue } }
    }

    /// Messages below this level are dropped before formatting. Debug-level
    /// messages are also compiled out of release builds of PVLookup.
    public static var minimumLevel: PVLookupLogLevel {
        get { config.lock.withLock { config.minimumLevel } }
        set { config.lock.withLock { config.minimumLevel = newValue } }
    }

    private static let log = OSLog(subsystem: "org.provenance-emu.PVLookup", category: "PVLookup")

    /// The default handler: os_log, with the message public so it is readable
    /// in Console.
    ///
    /// One `os_log` call with a `%{public}@` format, not `Logger` string
    /// interpolation: in a Debug build each `Logger` interpolation reserves a
    /// large stack buffer, and a switch over four of them in one closure
    /// overflowed the 512 KB stack of a Swift-concurrency thread (SIGBUS in
    /// TheGamesDBSchema.getImages under `swift test`).
    public static let osLogHandler: Handler = { level, message, _, _, _ in
        let type: OSLogType = switch level {
        case .debug: .debug
        case .info: .info
        case .warning: .default
        case .error: .error
        }
        os_log("%{public}@", log: log, type: type, message)
    }

    @usableFromInline
    static func emit(_ level: PVLookupLogLevel, _ message: () -> String,
                     _ file: String, _ function: String, _ line: Int) {
        let (handler, minimum) = config.lock.withLock { (config.handler, config.minimumLevel) }
        guard level >= minimum else { return }
        handler(level, message(), file, function, line)
    }
}

// The names PVLookup's sources have always used (from Provenance's PVLogging),
// at `package` access so they never clash with an app's own DLOG/ELOG.

package func DLOG(_ message: @autoclosure () -> String,
                  file: String = #fileID, function: String = #function, line: Int = #line) {
    #if DEBUG
    PVLookupLog.emit(.debug, message, file, function, line)
    #endif
}

package func ILOG(_ message: @autoclosure () -> String,
                  file: String = #fileID, function: String = #function, line: Int = #line) {
    PVLookupLog.emit(.info, message, file, function, line)
}

package func WLOG(_ message: @autoclosure () -> String,
                  file: String = #fileID, function: String = #function, line: Int = #line) {
    PVLookupLog.emit(.warning, message, file, function, line)
}

package func ELOG(_ message: @autoclosure () -> String,
                  file: String = #fileID, function: String = #function, line: Int = #line) {
    PVLookupLog.emit(.error, message, file, function, line)
}
