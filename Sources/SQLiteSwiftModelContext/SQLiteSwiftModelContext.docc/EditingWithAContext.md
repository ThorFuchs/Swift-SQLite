# Editing with a context

Load, edit and save records from a view, and decide what happens when someone
else changed them first.

## Create a context

A context saves through a `SQLiteModelStore`. Create one store per database and one
context per editing scope, such as a window:

```swift
import SQLiteSwiftModelContext
import SQLiteSwiftModels

let store = SQLiteModelStore(database: database)
let context = SQLiteModelContext(store: store)
```

## Edit and save

```swift
if let article = try await context.find(Article.self, id: "intro") {
    article.value.title = "A better title"   // the handle is now dirty
    switch try await context.save() {
    case .saved: break
    case .conflict(let conflict): print("\(conflict.table) \(conflict.id) changed")
    }
}
```

`find` returns the same handle for the same record every time. Edits made while a
save runs stay unsaved and keep the handle dirty afterwards. A second `save()`
waits for the first.

## States

A handle is always in one ``SQLiteModel/State``:

| State | Meaning |
| --- | --- |
| `clean` | The value equals the stored row. |
| `dirty` | Local edits, a new record, or a deletion wait for the next save. |
| `saving` | A save of the edits is running. |
| `conflicted` | The stored row changed or was deleted since the handle read it. |
| `deleted` | The row is gone; the handle left the context. |
| `indeterminate` | A save's commit outcome is unknown. |

## Resolve a conflict

A conflicted handle keeps your value, its ``SQLiteModel/baseline`` and the stored
``SQLiteModel/remote``. Choose:

- ``SQLiteModel/useRemote()`` takes the stored row and drops your edits;
- ``SQLiteModel/keepLocal()`` keeps your value and bases it on the stored row; the
  next save is still conditional;
- ``SQLiteModel/discard()`` drops your edits.

A row deleted by someone else is never saved again: `keepLocal()` refuses it.

## Unknown commit outcomes

If a save can't tell whether its commit happened, its handles become
`indeterminate` and further saves throw until you call
``SQLiteModelContext/resolveIndeterminate()``. It looks for the save's marker on a
fresh connection and moves the handles on, or makes them dirty again. Your edits
are kept either way.

## Follow other writers

```swift
struct ArticleView: View {
    let context: SQLiteModelContext
    @State var drafts: SQLiteLiveQuery<Article>

    var body: some View {
        List(drafts.results, id: \.value.id) { Text($0.value.title) }
            .task { try? await drafts.run() }
            .task { try? await context.observeChanges() }
    }
}
```

Outside SwiftUI, `Observations` (Swift 6.2; macOS 26, iOS 26 and Linux) turns a
handle or a live query into an async sequence:

```swift
for await title in Observations({ article.value.title }) {
    print("now:", title)   // local edits and applied remote rows alike
}
```

While ``SQLiteModelContext/observeChanges(bufferSize:)`` runs, clean handles take
other contexts' saves, dirty ones keep their draft and become conflicted, and
remote deletions are shown. A ``SQLiteLiveQuery`` re-reads its results after every
batch that touches its table. Both stop when their task is cancelled.
