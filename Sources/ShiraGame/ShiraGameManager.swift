import Foundation
import PVLookupLogging
import PVSQLiteDatabase

public enum ShiraGameError: Error {
    case databaseNotFound
    case extractionFailed
    case invalidCompressedFile
    case initializationTimeout
}

/// Manager for the ShiraGame SQLite database.
///
/// Uses the shared `SQLiteDatabaseManager` (source from `LookupDatabases`,
/// content-fingerprinted extraction). It used to carry its own copy of the
/// extraction code, which had no fingerprint: an updated database zip was
/// never re-extracted over an existing copy.
public actor ShiraGameManager {
    /// Singleton instance to coordinate database operations
    public static let shared = ShiraGameManager()

    private let databaseManager = SQLiteDatabaseManager(database: .shiragame)

    /// Path to the database file
    public nonisolated var databasePath: URL {
        databaseManager.databasePath
    }

    /// Ensures the database is extracted and ready to use
    public func prepareDatabaseIfNeeded() async throws {
        do {
            try await databaseManager.prepareDatabaseIfNeeded()
        } catch SQLiteDatabaseError.databaseNotFound {
            DLOG("ShiraGameManager: no ShiraGame database configured or bundled")
            throw ShiraGameError.databaseNotFound
        }
    }
}
