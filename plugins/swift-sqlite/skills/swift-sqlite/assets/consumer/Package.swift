// swift-tools-version: 6.4
// SPDX-License-Identifier: Apache-2.0
import PackageDescription

// Acceptance fixture for the developer kit's recipes: it imports every product, which
// a real consumer should not do. Scripts/run_kit_recipes.sh swaps this pin for the
// local checkout in CI.
let package = Package(
    name: "SwiftSQLiteKitRecipes",
    platforms: [.macOS(.v15), .iOS(.v18)],
    dependencies: [.package(url: "https://github.com/ThorFuchs/Swift-SQLite.git", exact: "1.2.0")],
    targets: [.executableTarget(name: "Consumer", dependencies: [
        .product(name: "SQLiteSwift", package: "Swift-SQLite"),
        .product(name: "SQLiteSwiftModels", package: "Swift-SQLite"),
        .product(name: "SQLiteSwiftModelContext", package: "Swift-SQLite"),
        .product(name: "SQLiteSwiftTesting", package: "Swift-SQLite"),
    ])],
    swiftLanguageModes: [.v6]
)
