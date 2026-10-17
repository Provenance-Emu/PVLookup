// swift-tools-version:6.0
import PackageDescription

// Game metadata and artwork lookup over SQLite databases (libretrodb, OpenVGDB,
// TheGamesDB, ShiraGame, the libretro cheat database), shared by Provenance,
// iFly and iCube.
//
// The package ships NO database bytes. The databases are assets on this repo's
// `databases-YYYY-MM-DD` releases; each app fetches the ones it wants
// (Scripts/fetch-lookup-databases.sh + a databases.lock.json) into its own
// bundle. See README.md and `LookupDatabases`.
//
// Like PVSystems, this must not depend on any package an app keeps in its own
// tree (e.g. Provenance's PVLogging): logging goes through `PVLookupLog`.
let package = Package(
    name: "PVLookup",
    platforms: [
        .iOS(.v17),
        .tvOS(.v17),
        .watchOS(.v9),
        .macOS(.v14),
        .macCatalyst(.v17),
        .visionOS(.v1)
    ],
    products: [
        .library(name: "PVLookup", targets: ["PVLookup"]),
        .library(name: "PVLookup-Static", type: .static, targets: ["PVLookup"]),
        .library(name: "PVLookup-Dynamic", type: .dynamic, targets: ["PVLookup"]),
        .library(name: "LibretroCheatDB", targets: ["LibretroCheatDB"]),
        // iFly reads libretrodb directly for cheat metadata.
        .library(name: "libretrodb", targets: ["libretrodb"])
    ],
    dependencies: [
        .package(url: "https://github.com/Provenance-Emu/PVSystems.git", .upToNextMajor(from: "1.0.0")),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        .package(url: "https://github.com/stephencelis/SQLite.swift.git", .upToNextMajor(from: "0.15.3")),
        .package(url: "https://github.com/JoeMatt/Lighter.git", from: "1.0.0"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", .upToNextMajor(from: "0.9.18")),
        .package(url: "https://github.com/apple/swift-openapi-runtime", from: "1.0.0")
    ],
    targets: [
        // MARK: - Lookup

        .target(
            name: "PVLookup",
            dependencies: [
                "PVLookupLogging",
                "OpenVGDB",
                "ROMMetadataProvider",
                "PVLookupTypes",
                "libretrodb",
                "ShiraGame",
                "PVSystems",
                "TheGamesDB",
                "PVSQLiteDatabase"
            ]
        ),

        // MARK: - Logging (internal shim; see PVLookupLog)

        .target(name: "PVLookupLogging"),

        // MARK: - SQLite wrapper and database sources

        .target(
            name: "PVSQLiteDatabase",
            dependencies: [
                "PVLookupLogging",
                .product(name: "SQLite", package: "sqlite.swift"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation")
            ]
        ),

        // MARK: - TheGamesDB

        .target(
            name: "TheGamesDB",
            dependencies: [
                "PVLookupLogging",
                "PVSQLiteDatabase",
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "Crypto", package: "swift-crypto"),
                "PVLookupTypes",
                "ROMMetadataProvider",
                "PVSystems"
            ],
            exclude: ["Resources"]
        ),

        // MARK: - LibretroCheatDB

        .target(
            name: "LibretroCheatDB",
            dependencies: [
                "PVLookupLogging",
                "PVSQLiteDatabase",
                .product(name: "SQLite", package: "sqlite.swift")
            ],
            exclude: ["Resources"]
        ),

        // MARK: - libretrodb (https://github.com/avojak/libretrodb-sqlite)

        .target(
            name: "libretrodb",
            dependencies: [
                "PVLookupLogging",
                "PVSQLiteDatabase",
                "PVLookupTypes",
                "PVSystems",
                "ROMMetadataProvider"
            ],
            exclude: ["Resources"]
        ),

        // MARK: - OpenVGDB (https://github.com/OpenVGDB/OpenVGDB/releases)
        // Regenerate: swift run sqlite2swift Lighter.json OpenVGDB Sources/OpenVGDB/Resources/openvgdb_schema.sql Sources/OpenVGDB/OpenVGDBSQL.swift

        .target(
            name: "OpenVGDB",
            dependencies: [
                "PVLookupLogging",
                "PVSQLiteDatabase",
                "Lighter",
                "PVLookupTypes",
                "PVSystems",
                "ROMMetadataProvider"
            ],
            exclude: ["Resources", "swiftgen.yml"]
        ),

        // MARK: - ShiraGame (https://shiraga.me/)
        // Regenerate: swift run sqlite2swift Lighter.json ShiraGame Sources/ShiraGame/Resources/shiragame_schema.sql Sources/ShiraGame/ShiraGameSQL.swift

        .target(
            name: "ShiraGame",
            dependencies: [
                "PVLookupLogging",
                "ROMMetadataProvider",
                "PVSQLiteDatabase",
                "PVLookupTypes",
                "PVSystems",
                "Lighter"
            ],
            exclude: ["Resources", "swiftgen.yml"]
        ),

        // MARK: - ROMMetadataProvider

        .target(
            name: "ROMMetadataProvider",
            dependencies: ["PVLookupTypes", "PVLookupLogging"]
        ),

        // MARK: - PVLookupTypes

        .target(
            name: "PVLookupTypes",
            dependencies: ["PVLookupLogging", "PVSystems"]
        ),

        // MARK: - Tests

        .testTarget(
            name: "PVLookupTests",
            dependencies: ["PVLookup", "PVLookupLogging", "PVSystems", "PVSQLiteDatabase"]
        ),
        .testTarget(
            name: "TheGamesDBTests",
            dependencies: ["TheGamesDB", "PVLookup", "PVLookupLogging"]
        ),
        .testTarget(
            name: "LibretroCheatDBTests",
            dependencies: ["LibretroCheatDB", "PVLookupLogging"]
        ),
        .testTarget(
            name: "PVSQLiteDatabaseTests",
            dependencies: [
                "PVSQLiteDatabase",
                .product(name: "ZIPFoundation", package: "ZIPFoundation")
            ]
        )
    ],
    swiftLanguageModes: [.v5, .v6]
)
