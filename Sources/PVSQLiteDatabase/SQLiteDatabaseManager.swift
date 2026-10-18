import Foundation
import PVLookupLogging
import ZIPFoundation
import SQLite

public enum SQLiteDatabaseError: Error {
    case databaseNotFound
    case extractionFailed
    case invalidCompressedFile
    case initializationTimeout
}

/// Manages SQLite database initialization and extraction
public actor SQLiteDatabaseManager {
    /// Path to the database: the extracted copy in Caches, or the file itself for a `.file` source.
    public nonisolated var databasePath: URL {
        if case let .file(url) = resolvedSource { return url }
        return Self.cachesURL(for: databaseName)
    }

    /// Where a bundled database named `fileName` is extracted.
    public static func cachesURL(for fileName: String) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent(fileName)
    }

    /// Sidecar file recording which bundled archive contents the extracted database came from.
    ///
    /// Staleness used to be decided by comparing the bundle zip's modification date against the
    /// extracted database's. ZIPFoundation stamps extracted files with the archive entry's
    /// (old) date while the bundle zip carries the build/install date, so that comparison was
    /// always true and every launch deleted and re-extracted hundreds of MB, triggering
    /// MetricKit `MXDiskWriteException`s. A content fingerprint is stable across installs.
    public nonisolated var sourceMarkerPath: URL {
        databasePath.appendingPathExtension("source")
    }

    private enum Origin: Sendable {
        case database(LookupDatabase)
        case fixed(LookupDatabaseSource)
    }

    private let origin: Origin
    private let databaseName: String
    private let indexes: [String]
    private var isDatabasePrepared = false

    /// The source, resolved on every use so `LookupDatabases.configure` applies
    /// even to managers created before it ran.
    private nonisolated var resolvedSource: LookupDatabaseSource {
        switch origin {
        case let .database(database): LookupDatabases.source(for: database)
        case let .fixed(source): source
        }
    }

    /// A manager for one of PVLookup's databases, read from the source
    /// `LookupDatabases` gives for it.
    /// - Parameter indexes: `CREATE INDEX IF NOT EXISTS` statements applied to
    ///   the extracted copy (never to a caller's `.file` database).
    public init(database: LookupDatabase, indexes: [String] = []) {
        self.origin = .database(database)
        self.databaseName = database.fileName
        self.indexes = indexes
    }

    /// A manager for `<compressedName>.zip` in `bundle`, extracting the entry `databaseName`.
    public init(bundle: Bundle, databaseName: String, compressedName: String? = nil) {
        self.origin = .fixed(.bundled(bundle, resource: compressedName ?? databaseName))
        self.databaseName = databaseName
        self.indexes = []
    }

    /// Ensures the database is extracted and ready to use
    public func prepareDatabaseIfNeeded() async throws {
        if isDatabasePrepared {
            DLOG("SQLiteDatabaseManager: Database already prepared")
            return
        }

        DLOG("SQLiteDatabaseManager: Starting database preparation...")

        let fileManager = FileManager.default

        let bundle: Bundle
        let compressedName: String
        switch resolvedSource {
        case let .file(url):
            guard fileManager.fileExists(atPath: url.path) else {
                DLOG("SQLiteDatabaseManager: \(url.path) does not exist")
                throw SQLiteDatabaseError.databaseNotFound
            }
            isDatabasePrepared = true
            return
        case let .bundled(sourceBundle, resource):
            bundle = sourceBundle
            compressedName = resource
        }

        // Get the compressed database from the bundle
        guard let compressedURL = bundle.url(forResource: compressedName, withExtension: "zip") else {
            // No archive to (re-)extract from; fall back to an already extracted copy if present.
            if fileManager.fileExists(atPath: databasePath.path) {
                DLOG("SQLiteDatabaseManager: No bundled zip, using existing database")
                applyIndexes(at: databasePath)
                isDatabasePrepared = true
                return
            }
            DLOG("SQLiteDatabaseManager: Failed to find compressed database in bundle")
            throw SQLiteDatabaseError.databaseNotFound
        }

        let fingerprint = archiveFingerprint(of: compressedURL)

        // Check if database already exists and is up to date
        if fileManager.fileExists(atPath: databasePath.path) {
            let storedFingerprint = try? String(contentsOf: sourceMarkerPath, encoding: .utf8)

            if let storedFingerprint, storedFingerprint == fingerprint {
                DLOG("SQLiteDatabaseManager: Database already exists and is up to date")
                applyIndexes(at: databasePath)
                isDatabasePrepared = true
                return
            }

            if storedFingerprint == nil || fingerprint == nil {
                // Databases extracted by older builds have no marker. Until now they were
                // re-extracted on every launch, so they already match the bundled archive;
                // adopt them instead of rewriting them yet again.
                DLOG("SQLiteDatabaseManager: Adopting existing database without re-extracting")
                writeSourceMarker(fingerprint)
                applyIndexes(at: databasePath)
                isDatabasePrepared = true
                return
            }

            DLOG("SQLiteDatabaseManager: Bundled archive contents changed — re-extracting")
            try? fileManager.removeItem(at: databasePath)
        }

        DLOG("SQLiteDatabaseManager: Database not found, starting extraction from: \(compressedURL)")

        // Create a temporary directory for extraction
        let tempDir = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        DLOG("SQLiteDatabaseManager: Created temp directory at: \(tempDir)")

        defer {
            try? fileManager.removeItem(at: tempDir)
            DLOG("SQLiteDatabaseManager: Cleaned up temp directory")
        }

        // Extract using FileManager+Zip
        DLOG("SQLiteDatabaseManager: Starting extraction...")
        try fileManager.zipItem(at: compressedURL, unzipTo: tempDir)
        DLOG("SQLiteDatabaseManager: Extraction complete")

        // Move extracted database to final location
        let extractedDB = tempDir.appendingPathComponent(databaseName)
        // Index the copy before it's visible at databasePath.
        applyIndexes(at: extractedDB)
        try fileManager.moveItem(at: extractedDB, to: databasePath)
        DLOG("SQLiteDatabaseManager: Moved database to final location")

        writeSourceMarker(fingerprint)

        isDatabasePrepared = true
        DLOG("SQLiteDatabaseManager: Database preparation complete")
    }

    /// Creates `indexes` (`CREATE INDEX IF NOT EXISTS …` statements) in the
    /// database at `url` unless every one already exists. Runs inside
    /// `prepareDatabaseIfNeeded`, before the database is reported ready, so no
    /// lookup can run while an index is being built (building them on 87k rows
    /// takes seconds and holds the write lock: concurrent reads failed with
    /// "database is locked"). Never throws: lookups work without the indexes,
    /// just slower.
    private func applyIndexes(at url: URL) {
        guard !indexes.isEmpty else { return }
        do {
            let connection = try Connection(url.path)
            connection.busyTimeout = 30
            let existing = Set(try connection.prepare("SELECT name FROM sqlite_master WHERE type = 'index'")
                .compactMap { $0[0] as? String })
            let missing = indexes.filter { statement in
                guard let name = Self.indexName(in: statement) else { return true }
                return !existing.contains(name)
            }
            guard !missing.isEmpty else { return }
            DLOG("SQLiteDatabaseManager: creating \(missing.count) index(es) in \(databaseName)")
            for statement in missing {
                try connection.execute(statement)
            }
        } catch {
            WLOG("SQLiteDatabaseManager: could not index \(databaseName): \(error)")
        }
    }

    /// The index name in a `CREATE INDEX [IF NOT EXISTS] <name> ON …` statement.
    static func indexName(in statement: String) -> String? {
        let words = statement.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let on = words.firstIndex(where: { $0.uppercased() == "ON" }), on > 0 else { return nil }
        return words[on - 1]
    }

    /// Content fingerprint (CRC32 + uncompressed size) of the database entry in the bundled zip.
    /// Only reads the archive's central directory, so it is cheap.
    private func archiveFingerprint(of zipURL: URL) -> String? {
        do {
            let archive = try Archive(url: zipURL, accessMode: .read)
            guard let entry = archive[databaseName] else {
                DLOG("SQLiteDatabaseManager: Entry \(databaseName) not found in \(zipURL.lastPathComponent)")
                return nil
            }
            return "\(entry.checksum)-\(entry.uncompressedSize)"
        } catch {
            DLOG("SQLiteDatabaseManager: Failed to read archive fingerprint: \(error)")
            return nil
        }
    }

    private func writeSourceMarker(_ fingerprint: String?) {
        guard let fingerprint else { return }
        do {
            try fingerprint.write(to: sourceMarkerPath, atomically: true, encoding: .utf8)
        } catch {
            DLOG("SQLiteDatabaseManager: Failed to write source marker: \(error)")
        }
    }
}
