# PVLookup

Game metadata and artwork lookup for Provenance, iFly and iCube. It covers libretrodb, OpenVGDB,
TheGamesDB, ShiraGame and the libretro cheat database.

```swift
.package(url: "https://github.com/Provenance-Emu/PVLookup.git", .upToNextMajor(from: "1.0.0"))
```

Products: `PVLookup` (plus `-Static` and `-Dynamic` variants), `LibretroCheatDB`, `libretrodb`.

## Databases are not in the package

The databases (about 175 MB) are assets on this repo's `databases-YYYY-MM-DD` releases. A release
is never edited after it's published; a refresh is a new tag. Each release has a `databases.json`
listing every asset with its size, sha256, zip entry and source.

Each app pins the assets it wants in a `databases.lock.json` and fetches them at build time with
[`Scripts/fetch-lookup-databases.sh`](Scripts/fetch-lookup-databases.sh). Copy the script into the
app; the format is in its header. Downloads are verified by sha256 and cached in
`~/Library/Caches/PVLookupDatabases`. Add the destination folder to the app as resources.

By default PVLookup looks for `<file name>.zip` in the main bundle: `libretrodb.sqlite.zip`,
`openvgdb.sqlite.zip`, `thegamesdb.sqlite.zip`, `shiragame.sqlite3.zip`,
`libretro_cheats.sqlite.zip`. A database the app doesn't ship is unavailable, and lookups that need
it return nothing. To take a variant under the default name, use `as` in the lock file. iFly does
this, fetching `libretrodb-dreamcast.sqlite.zip` as `libretrodb.sqlite.zip`. To look somewhere
else, configure it at launch:

```swift
import PVLookup

LookupDatabases.configure([
    .libretrodb: .bundled(.main, resource: "libretrodb-dreamcast.sqlite"),  // <resource>.zip
    .openvgdb: .file(extractedSQLiteURL),                                    // used in place
])
```

## Logging

PVLookup logs through `PVLookupLog`, which defaults to `os_log` (subsystem
`org.provenance-emu.PVLookup`). Route it into your own logger:

```swift
PVLookupLog.handler = { level, message, file, function, line in /* … */ }
PVLookupLog.minimumLevel = .info
```

PVLookup must not depend on any package an app keeps in its own tree (such as Provenance's
`PVLogging`). SwiftPM would then see two packages with the same identity.

## Tests

```sh
Scripts/fetch-lookup-databases.sh databases.lock.json .databases
swift test
```

The tests read only the fetched databases (`PVLookupTestSupport.TestDatabases`), never a copy left
in Caches by an earlier run.

## Publishing new databases

1. Build or collect the zips. Each zip holds one file named after the database's file name
   (`libretrodb.sqlite`, …). The lean Dreamcast-family libretrodb comes from
   `Tools/libretrodb/generate_libretrodb_if_needed.sh` (output in `.build-libretrodb/out/`).
   The cheat database comes from Provenance's `Scripts/generate_cheatdb_if_needed.sh`.
2. Write `databases.json` (name, database, entry, size, uncompressedSize, sha256, source).
3. `gh release create databases-YYYY-MM-DD <zips> databases.json`.
4. Update `databases.lock.json` here and in each app.

Seeded on 2026-10-17 from Provenance's `PVLookup/` (Provenance-Emu/Provenance `9529d8509c`), with
iFly's fixes ported on top.
