// swift-tools-version: 6.4
// SPDX-License-Identifier: Apache-2.0
import PackageDescription

// A separate package, so the library's dependency graph stays empty. Run with
// Scripts/run-benchmarks.sh (release build).
let package = Package(
    name: "SQLiteSwiftBenchmarks",
    platforms: [.macOS(.v15), .iOS(.v18)],
    dependencies: [.package(name: "Swift-SQLite", path: "..")],
    targets: [.executableTarget(name: "SQLiteSwiftBenchmarks", dependencies: [
        .product(name: "SQLiteSwift", package: "Swift-SQLite"),
        .product(name: "SQLiteSwiftModels", package: "Swift-SQLite"),
    ])],
    swiftLanguageModes: [.v6]
)
