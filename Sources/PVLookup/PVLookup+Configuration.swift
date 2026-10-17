// The per-app configuration surface, re-exported so an app needs only
// `import PVLookup`:
//
//   LookupDatabases.configure([.libretrodb: .bundled(.main, resource: "libretrodb-dreamcast.sqlite")])
//   PVLookupLog.handler = { level, message, file, function, line in ... }
//
// Both are optional. Without them, databases come from `<name>.zip` in the
// main bundle and logs go to os.Logger.
//
// Scoped imports, because the PVSQLiteDatabase module also has a struct named
// PVSQLiteDatabase, which shadows the module in a qualified typealias.

@_exported import enum PVSQLiteDatabase.LookupDatabase
@_exported import enum PVSQLiteDatabase.LookupDatabaseSource
@_exported import enum PVSQLiteDatabase.LookupDatabases
@_exported import enum PVLookupLogging.PVLookupLog
@_exported import enum PVLookupLogging.PVLookupLogLevel
