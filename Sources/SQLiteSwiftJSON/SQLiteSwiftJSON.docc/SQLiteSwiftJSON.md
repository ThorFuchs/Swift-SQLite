# ``SQLiteSwiftJSON``

Record codecs for exact JSON values from Swift-JSON.

## Overview

Enable the `SwiftJSON` trait to use this module; without it the module is empty and
the package adds no dependencies:

```swift
.package(url: "https://github.com/ThorFuchs/Swift-SQLite.git", from: "1.3.0", traits: ["SwiftJSON"]),
// target: .product(name: "SQLiteSwiftJSON", package: "Swift-SQLite")
```

Two codecs plug into `SQLiteColumn`:

```swift
struct Event: SQLiteRecord {
    var id: String
    var payload: JSON          // an exact Swift-JSON value
    var settings: Settings     // any Codable type

    static let payloadColumn = SQLiteColumn("payload", \Event.payload, .jsonText)
    static let settingsColumn = SQLiteColumn("settings", \Event.settings, .json(Settings.self))
    // …
}
```

Both store compact JSON text with numbers exactly as written, so SQLite's JSON
functions work on the columns: filter with `payload ->> '$.status' = ?`, search
arrays with `json_each`, and index a path. Records come back through
`fetchAll(_:sql:_:)` or the usual reads. An index on a path also makes SQLite refuse
malformed JSON on write.

Reading is strict: invalid JSON, a JSONB BLOB written by SQL, or NULL in a
non-optional column throws `invalidStoredValue` naming the column. Use
`.optional(.jsonText)` for a nullable column.
