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
/// handler instead. The default writes to `os.Logger` (subsystem
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

    private static let state = OSAllocatedUnfairLock<(handler: Handler, minimumLevel: PVLookupLogLevel)>(
        initialState: (PVLookupLog.osLogHandler, .debug)
    )

    /// Where messages go. Defaults to ``osLogHandler``.
    public static var handler: Handler {
        get { state.withLock { $0.handler } }
        set { state.withLock { $0.handler = newValue } }
    }

    /// Messages below this level are dropped before formatting. Debug-level
    /// messages are also compiled out of release builds of PVLookup.
    public static var minimumLevel: PVLookupLogLevel {
        get { state.withLock { $0.minimumLevel } }
        set { state.withLock { $0.minimumLevel = newValue } }
    }

    private static let logger = Logger(subsystem: "org.provenance-emu.PVLookup", category: "PVLookup")

    /// The default handler: `os.Logger`, with messages marked public so they
    /// are readable in Console.
    public static let osLogHandler: Handler = { level, message, _, _, _ in
        switch level {
        case .debug: logger.debug("\(message, privacy: .public)")
        case .info: logger.info("\(message, privacy: .public)")
        case .warning: logger.warning("\(message, privacy: .public)")
        case .error: logger.error("\(message, privacy: .public)")
        }
    }

    @usableFromInline
    static func emit(_ level: PVLookupLogLevel, _ message: () -> String,
                     _ file: String, _ function: String, _ line: Int) {
        let (handler, minimum) = state.withLock { ($0.handler, $0.minimumLevel) }
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
