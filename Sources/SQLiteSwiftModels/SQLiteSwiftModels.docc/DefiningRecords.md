# Defining, reading and writing records

Describe a record, create its table, and read and write it with explicit
expectations.

## Describe the record

A record is a `Sendable`, `Equatable` struct with an `id`. Its descriptor names the
table, the key column and one typed column per stored field:

```swift
import SQLiteSwift
import SQLiteSwiftModels

struct Article: SQLiteRecord {
    var id: String
    var title: String
    var publishedAt: Date?

    static let idColumn = SQLiteColumn("id", \Article.id, .text)
    static let titleColumn = SQLiteColumn("title", \Article.title, .text)
    static let publishedColumn = SQLiteColumn("published_at", \Article.publishedAt, .optional(.unixMilliseconds))

    static let descriptor = SQLiteRecordDescriptor(
        table: "articles", key: idColumn, columns: titleColumn, publishedColumn
    ) { row throws(SQLiteError) in
        Article(id: try row.value(idColumn), title: try row.value(titleColumn),
                publishedAt: try row.value(publishedColumn))
    }
}
```

Codecs convert exactly or refuse: text must be valid UTF-8, integers must fit,
dates must be whole milliseconds, a `Bool` is 0 or 1. A stored value a codec can't
read throws `SQLiteError.Code.invalidStoredValue` with the column's name.

## Create the tables

Each managed table has two more columns the model layer owns, `revision` and
`incarnation`. Add the store's own tables with
``SQLiteModelSchema/migration(version:name:)`` to your migration list:

```swift
let migrations = [
    SQLiteMigration(version: 1, name: "articles", sql: """
        CREATE TABLE articles (
            id TEXT PRIMARY KEY, title TEXT NOT NULL, published_at INTEGER,
            revision INTEGER NOT NULL CHECK (revision >= 1),
            incarnation BLOB NOT NULL);
        """),
    SQLiteModelSchema.migration(version: 2),
]
let database = try await SQLiteDatabase.open(configuration, migrations: migrations)
```

`verifySchema(for:)` on a transaction checks that the table has every mapped
column.

## Read

```swift
let snapshot = try await database.read { tx throws(SQLiteError) in
    try tx.fetch(Article.self, id: "intro")
}
```

`fetchAll(_:where:limits:)` returns the matching records in key order and never
truncates: more rows than the limit throw.

## Write with an expectation

Every write says what it expects: ``SQLiteWriteExpectation/absent`` to insert, or
the ``SQLiteRecordVersion`` it read to update or delete. The outcome is a value:

- ``SQLiteRecordWriteOutcome/inserted(_:)`` and ``SQLiteRecordWriteOutcome/updated(_:)``
  carry the row as stored;
- ``SQLiteRecordWriteOutcome/conflict(current:)`` carries the row that is there
  instead;
- ``SQLiteRecordWriteOutcome/missing`` means the row is gone.

Busy databases, deadlines, cancellation and constraint violations stay errors.

## Batches and the change stream

Create one ``SQLiteModelStore`` per database. Its
``SQLiteModelStore/writeRecords(_:origin:limits:)`` runs a list of writes in one
transaction; the first conflict rolls them all back and is reported:

```swift
let store = SQLiteModelStore(database: database)
switch try await store.writeRecords([.insert(draft), .update(edited, expecting: version)]) {
case .committed(let reports): print(reports.map(\.summary))
case .rolledBack(let failure): print("write \(failure.index) found \(failure.summary)")
}
```

Subscribers get a snapshot and every batch committed after it:

```swift
let (articles, changes) = try await store.subscribe { tx throws(SQLiteError) in
    try tx.fetchAll(Article.self)
}
for await event in changes {
    switch event {
    case .committed(let batch): apply(batch.changes)
    case .resyncRequired: break  // subscribe again for a fresh snapshot
    }
}
```

Only writes made through the store in this process are published. Raw SQL, other
processes and other `SQLiteDatabase` instances are not seen.

## Resume after a restart

Give the store a ``SQLiteModelStore/ChangeLog`` (and add
``SQLiteModelSchema/changeLogMigration(version:name:)`` to the migrations). Every
committed batch is then also written to a bounded log in its own transaction, and a
consumer that remembers the last sequence it processed continues exactly there:

```swift
let store = SQLiteModelStore(database: database, changeLog: .retain(batches: 10_000))
for await event in try await store.subscribe(after: lastProcessedSequence) {
    switch event {
    case .committed(let batch):
        try await forward(batch)               // for example to a queue or a webhook
        lastProcessedSequence = batch.sequence // store it with your own progress
    case .resyncRequired:
        break  // the log no longer reaches back far enough: take a new snapshot
    }
}
```

The missed batches come first, then the live ones, with nothing lost or repeated
between them. When that can't be guaranteed (the log was pruned past the point,
the store is behind the consumer, or the missed batches don't fit the buffer) the
subscription delivers only `resyncRequired`.
