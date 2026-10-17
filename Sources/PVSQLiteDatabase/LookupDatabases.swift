import Foundation
import os

/// The databases PVLookup can read.
///
/// PVLookup ships none of them. Each is an asset on a `databases-YYYY-MM-DD`
/// release of github.com/Provenance-Emu/PVLookup, which the app fetches at build
/// time (Scripts/fetch-lookup-databases.sh + databases.lock.json) and copies
/// into its bundle. A database the app doesn't ship is simply unavailable:
/// lookups that need it return no result.
public enum LookupDatabase: String, CaseIterable, Sendable {
    case libretrodb
    case openvgdb
    case thegamesdb
    case shiragame
    case libretroCheats

    /// The database file's name: the entry inside the zip, and the name of the
    /// extracted copy in Caches.
    public var fileName: String {
        switch self {
        case .libretrodb: "libretrodb.sqlite"
        case .openvgdb: "openvgdb.sqlite"
        case .thegamesdb: "thegamesdb.sqlite"
        case .shiragame: "shiragame.sqlite3"
        case .libretroCheats: "libretro_cheats.sqlite"
        }
    }

    /// The zip's resource name, without `.zip`. This is the name the default
    /// source looks for in the app's main bundle.
    public var defaultResourceName: String { fileName }
}

/// Where a database comes from.
public enum LookupDatabaseSource: Sendable {
    /// `<resource>.zip` in `bundle`. It's extracted once into Caches and
    /// re-extracted only when the zip's contents change.
    case bundled(Bundle, resource: String)
    /// An already-extracted SQLite file, used in place (tests, tools).
    case file(URL)
}

/// Per-app configuration of the lookup databases.
///
/// With no configuration every database is looked up as
/// `<fileName>.zip` in `Bundle.main`, which is where the fetch script's output
/// lands when the app adds it as a resource. Override per database at launch,
/// before the first lookup:
///
/// ```swift
/// LookupDatabases.configure([
///     .libretrodb: .bundled(.main, resource: "libretrodb-dreamcast.sqlite"),
/// ])
/// ```
public enum LookupDatabases {
    private static let overrides = OSAllocatedUnfairLock<[LookupDatabase: LookupDatabaseSource]>(initialState: [:])

    /// Replaces the per-database overrides. Databases not in `sources` use the default.
    public static func configure(_ sources: [LookupDatabase: LookupDatabaseSource]) {
        overrides.withLock { $0 = sources }
    }

    /// The source `database` will be read from.
    public static func source(for database: LookupDatabase) -> LookupDatabaseSource {
        overrides.withLock { $0[database] } ?? .bundled(.main, resource: database.defaultResourceName)
    }

    /// Whether `database` can be prepared: its zip or file exists, or a copy
    /// was already extracted into Caches.
    public static func isAvailable(_ database: LookupDatabase) -> Bool {
        switch source(for: database) {
        case let .bundled(bundle, resource):
            if bundle.url(forResource: resource, withExtension: "zip") != nil { return true }
            return FileManager.default.fileExists(atPath: SQLiteDatabaseManager.cachesURL(for: database.fileName).path)
        case let .file(url):
            return FileManager.default.fileExists(atPath: url.path)
        }
    }
}
