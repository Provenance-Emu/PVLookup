// swift-tools-version:6.0
import Foundation
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

// A version tag resolves to the prebuilt XCFrameworks from that tag's GitHub release;
// `main` always builds from source. The release workflow fills this in on the tagged
// commit only, so it stays `nil` on every branch.
// Set PV_BUILD_FROM_SOURCE=1 to build a tagged version from source instead.
let binaryRelease: (version: String, checksums: [String: String])? = nil

let environment = ProcessInfo.processInfo.environment
let buildFromSource = binaryRelease == nil || environment["PV_BUILD_FROM_SOURCE"] != nil
// The release workflow builds the frameworks it publishes from dynamic products, one
// module at a time, and names the ones already built so later modules link them
// instead of compiling them in again.
let buildingRelease = environment["PV_XCFRAMEWORK_BUILD"] != nil
let libraryType: Product.Library.LibraryType? = buildingRelease ? .dynamic : nil
let prebuilt = Set((environment["PV_XCFRAMEWORK_PREBUILT"] ?? "").split(separator: " ").map(String.init))

let module: (Target) -> Target = { source in
    prebuilt.contains(source.name)
        ? .binaryTarget(name: source.name, path: ".xcframework-build/\(source.name).xcframework")
        : source
}
// A product made only of a prebuilt framework cannot ask for a linkage type.
let libraryTypeFor: (String) -> Product.Library.LibraryType? = { module in
    prebuilt.contains(module) ? nil : libraryType
}

// The released modules, in dependency order (the order the release workflow builds them).
let releasedModules = [
    "PVLookupLogging", "PVLookupTypes", "ROMMetadataProvider", "PVSQLiteDatabase", "TheGamesDB",
    "libretrodb", "OpenVGDB", "ShiraGame", "LibretroCheatDB", "PVLookup"
]

// What the modules share with the apps: one prebuilt copy each. A prebuilt module does not
// pass its dependencies on, so every module that imports another names all three.
let shared: [Target.Dependency] = [
    .product(name: "PVSystems", package: "PVSystems"),
    .product(name: "SQLite", package: "PVDependencies"),
    .product(name: "ZIPFoundation", package: "PVDependencies")
]
// Used by one or two modules each, as `internal import`s: linked inside those modules'
// frameworks and absent from their interfaces. Lighter does not compile with library
// evolution, so it cannot be a shared framework.
let lighter: Target.Dependency = .product(name: "Lighter", package: "Lighter")
let crypto: Target.Dependency = .product(name: "Crypto", package: "swift-crypto")

let sourceTargets: [Target] = [
    module(.target(name: "PVLookupLogging")),
    module(.target(name: "PVLookupTypes", dependencies: ["PVLookupLogging"] + shared)),
    module(.target(name: "ROMMetadataProvider", dependencies: ["PVLookupTypes", "PVLookupLogging"] + shared)),
    module(.target(name: "PVSQLiteDatabase", dependencies: ["PVLookupLogging"] + shared)),
    module(.target(
        name: "TheGamesDB",
        dependencies: ["PVLookupLogging", "PVSQLiteDatabase", "PVLookupTypes", "ROMMetadataProvider", crypto] + shared,
        exclude: ["Resources"]
    )),
    module(.target(
        name: "libretrodb",
        dependencies: ["PVLookupLogging", "PVSQLiteDatabase", "PVLookupTypes", "ROMMetadataProvider"] + shared,
        exclude: ["Resources"]
    )),
    module(.target(
        name: "OpenVGDB",
        dependencies: ["PVLookupLogging", "PVSQLiteDatabase", "PVLookupTypes", "ROMMetadataProvider", lighter] + shared,
        exclude: ["Resources", "swiftgen.yml"]
    )),
    module(.target(
        name: "ShiraGame",
        dependencies: ["PVLookupLogging", "ROMMetadataProvider", "PVSQLiteDatabase", "PVLookupTypes", lighter] + shared,
        exclude: ["Resources", "swiftgen.yml"]
    )),
    module(.target(
        name: "LibretroCheatDB",
        dependencies: ["PVLookupLogging", "PVSQLiteDatabase"] + shared,
        exclude: ["Resources"]
    )),
    module(.target(
        name: "PVLookup",
        dependencies: [
            "PVLookupLogging", "OpenVGDB", "ROMMetadataProvider", "PVLookupTypes", "libretrodb", "ShiraGame",
            "TheGamesDB", "PVSQLiteDatabase"
        ] + shared
    ))
] + (buildingRelease ? [] : [
    .target(
        name: "PVLookupTestSupport",
        dependencies: ["PVSQLiteDatabase"],
        path: "Sources/PVLookupTestSupport"
    ),
    .testTarget(
        name: "PVLookupTests",
        dependencies: ["PVLookup", "PVLookupLogging", "PVSystems", "PVSQLiteDatabase", "PVLookupTestSupport"]
    ),
    .testTarget(
        name: "TheGamesDBTests",
        dependencies: ["TheGamesDB", "PVLookup", "PVLookupLogging", "PVLookupTestSupport"]
    ),
    .testTarget(
        name: "LibretroCheatDBTests",
        dependencies: ["LibretroCheatDB", "PVLookupLogging", "PVLookupTestSupport"]
    ),
    .testTarget(
        name: "PVSQLiteDatabaseTests",
        dependencies: [
            "PVSQLiteDatabase",
            .product(name: "ZIPFoundation", package: "PVDependencies")
        ]
    )
])

let binaryTargets: [Target] = binaryRelease.map { release in
    release.checksums.sorted { $0.key < $1.key }.map { module, checksum in
        .binaryTarget(
            name: module,
            url: "https://github.com/Provenance-Emu/PVLookup/releases/download/\(release.version)/\(module).xcframework.zip",
            checksum: checksum
        )
    } + [
        // What the prebuilt frameworks link against.
        .target(name: "PVLookupDependencies", dependencies: shared, path: "Sources/BinaryDependencies")
    ]
} ?? []

// `PVLookupTypes` and `TheGamesDB` are not products: apps import them through `PVLookup`.
let sourceProducts: [Product] = buildingRelease
    ? releasedModules.map { .library(name: $0, type: libraryTypeFor($0), targets: [$0]) }
    : [
        .library(name: "PVLookup", targets: ["PVLookup"]),
        .library(name: "PVLookup-Static", type: .static, targets: ["PVLookup"]),
        .library(name: "PVLookup-Dynamic", type: .dynamic, targets: ["PVLookup"]),
        .library(name: "LibretroCheatDB", targets: ["LibretroCheatDB"]),
        .library(name: "libretrodb", targets: ["libretrodb"])
    ]
// Every product carries all ten frameworks: they are small and link each other.
let binaryProducts: [Product] = ["PVLookup", "PVLookup-Static", "PVLookup-Dynamic", "LibretroCheatDB", "libretrodb"].map {
    .library(name: $0, targets: releasedModules + ["PVLookupDependencies"])
}

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
    // Product names are the same in both modes, so consumers never change.
    products: buildFromSource ? sourceProducts : binaryProducts,
    dependencies: [
        // 1.0.3 is the first PVSystems release with a usable prebuilt framework.
        .package(url: "https://github.com/Provenance-Emu/PVSystems.git", .upToNextMajor(from: "1.0.3")),
        // Prebuilt SQLite.swift and ZIPFoundation, shared with the apps. A graph cannot
        // hold these and the upstream packages at once.
        .package(url: "https://github.com/Provenance-Emu/PVDependencies.git", .upToNextMajor(from: "1.0.0"))
    ] + (buildFromSource ? [
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        // 1.0.1 is the first Lighter that compiles with library evolution.
        .package(url: "https://github.com/JoeMatt/Lighter.git", from: "1.0.1")
    ] : []),
    targets: buildFromSource ? sourceTargets : binaryTargets,
    swiftLanguageModes: [.v5, .v6]
)
