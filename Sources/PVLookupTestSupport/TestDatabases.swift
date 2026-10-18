import Foundation
import PVSQLiteDatabase

/// Points PVLookup at the databases fetched into `<package>/.databases/` by
///
///     Scripts/fetch-lookup-databases.sh databases.lock.json .databases
///
/// Call `TestDatabases.configure()` before a test touches a database (suite
/// `init()` is fine; it is idempotent). Without the fetch the tests fail with
/// `databaseNotFound`, instead of passing on a stale copy some earlier run left
/// in Caches.
public enum TestDatabases {
    /// `<package root>/.databases`, found from this file's location.
    public static let directory: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // PVLookupTestSupport
        .deletingLastPathComponent()   // Sources
        .deletingLastPathComponent()   // package root
        .appendingPathComponent(".databases", isDirectory: true)

    private static let configured: Void = {
        guard let bundle = Bundle(url: directory) else {
            print("TestDatabases: \(directory.path) is missing. Run Scripts/fetch-lookup-databases.sh databases.lock.json .databases")
            return
        }
        // Full libretrodb, not the lean Dreamcast one: the tests cover every system.
        LookupDatabases.configure(Dictionary(uniqueKeysWithValues: LookupDatabase.allCases.map {
            ($0, LookupDatabaseSource.bundled(bundle, resource: $0.defaultResourceName))
        }))
    }()

    public static func configure() { _ = configured }
}
