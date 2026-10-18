import Foundation
import PVSQLiteDatabase
import PVLookupLogging

/// Manager for LibretroDB SQLite database
public actor LibretroDBManager {
    /// Singleton instance
    public static let shared = LibretroDBManager()

    private let databaseManager: SQLiteDatabaseManager

    private init() {
        self.databaseManager = SQLiteDatabaseManager(database: .libretrodb, indexes: Self.lookupIndexes)
    }

    /// Ensures database is ready for use
    public func prepareDatabaseIfNeeded() async throws {
        try await databaseManager.prepareDatabaseIfNeeded()
    }

    /// The full libretrodb ships with no indexes, so every md5/serial lookup was
    /// a full table scan, and SQLite built a transient automatic index on every
    /// query. Over a bulk library scan that was a multi-second matching stall
    /// (iFly 3a0f2b528 measured 0.25 s to 0.015 s per query once the serial_id
    /// join was indexed). iFly's lean database already has these.
    static let lookupIndexes = [
        "CREATE INDEX IF NOT EXISTS idx_roms_md5 ON roms(md5)",
        "CREATE INDEX IF NOT EXISTS idx_roms_serial_id ON roms(serial_id)",
        "CREATE INDEX IF NOT EXISTS idx_games_serial_id ON games(serial_id)",
        "CREATE INDEX IF NOT EXISTS idx_games_display_name ON games(display_name COLLATE NOCASE)"
    ]

    /// Path to the database file
    public var databasePath: URL {
        databaseManager.databasePath
    }
}
