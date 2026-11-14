// swift-tools-version: 6.4
// SPDX-License-Identifier: Apache-2.0
import PackageDescription

/// SQLite compile-time options for the vendored amalgamation (Linux only).
///
/// Only preprocessor defines are used; the package declares no `unsafeFlags`.
/// Apple platforms link the system SQLite instead and ignore this target's code.
let amalgamationDefines: [CSetting] = [
    .define("SQLITE_THREADSAFE", to: "1", .when(platforms: [.linux])),
    .define("SQLITE_DQS", to: "0", .when(platforms: [.linux])),
    .define("SQLITE_DEFAULT_MEMSTATUS", to: "0", .when(platforms: [.linux])),
    .define("SQLITE_OMIT_LOAD_EXTENSION", .when(platforms: [.linux])),
    .define("SQLITE_OMIT_DEPRECATED", .when(platforms: [.linux])),
    .define("SQLITE_ENABLE_API_ARMOR", .when(platforms: [.linux])),
    .define("SQLITE_MAX_EXPR_DEPTH", to: "1000", .when(platforms: [.linux])),
    .define("HAVE_USLEEP", to: "1", .when(platforms: [.linux])),
    .define("_GNU_SOURCE", .when(platforms: [.linux])),
]

let package = Package(
    name: "Swift-SQLite",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "SQLiteSwift", targets: ["SQLiteSwift"]),
        .library(name: "SQLiteSwiftTesting", targets: ["SQLiteSwiftTesting"]),
    ],
    targets: [
        // Pinned, unmodified SQLite amalgamation. `shim.c` compiles it on Linux only;
        // see Sources/CSQLiteSwift/PROVENANCE.md and THIRD_PARTY_NOTICES.md.
        .target(
            name: "CSQLiteSwift",
            exclude: ["sqlite3.c", "PROVENANCE.md"],
            sources: ["shim.c", "thread.c"],
            cSettings: amalgamationDefines,
            linkerSettings: [
                .linkedLibrary("pthread", .when(platforms: [.linux])),
                .linkedLibrary("m", .when(platforms: [.linux])),
            ]
        ),
        .target(
            name: "SQLiteSwift",
            dependencies: [
                .target(name: "CSQLiteSwift", condition: .when(platforms: [.linux]))
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "SQLiteSwiftTesting",
            dependencies: ["SQLiteSwift"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Opt-in model layer (see Documentation/MODEL-ARCHITECTURE.md). No product yet:
        // it ships as a product once its gates pass, so its API can still change.
        .target(
            name: "SQLiteSwiftModels",
            dependencies: ["SQLiteSwift"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SQLiteSwiftModelsTests",
            dependencies: ["SQLiteSwiftModels", "SQLiteSwift", "SQLiteSwiftTesting"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SQLiteSwiftTests",
            dependencies: ["SQLiteSwift", "SQLiteSwiftTesting"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
