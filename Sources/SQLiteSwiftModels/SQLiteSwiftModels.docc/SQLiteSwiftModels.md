# ``SQLiteSwiftModels``

Typed records over SQLiteSwift: strict codecs, versioned snapshots, conditional
writes and a stream of committed changes.

## Overview

SQLiteSwiftModels maps plain Swift structs to tables without macros or reflection.
You describe each record once, with typed columns and codecs that refuse every value
they can't represent exactly. Reads return immutable snapshots that carry a
version: a revision that grows with every update and a random incarnation that a
row keeps for life. Writes say what they expect to find and report what they found:

```swift
switch try tx.update(article, expecting: snapshot.version) {
case .updated(let stored): show(stored)
case .conflict(let current): ask(mine: article, theirs: current.value)
case .missing: showDeleted()
default: break
}
```

Nothing is overwritten behind your back, and a key that was deleted and inserted
again never matches an old version.

``SQLiteModelStore`` runs batches of writes all or nothing and publishes each
committed batch to subscribers, with a snapshot handoff that loses nothing and
buffers that never grow without bound.

The module has no main-actor code, so it fits servers as well as apps. For an
observable editing context in an app, see the `SQLiteSwiftModelContext` module.

## Topics

### Essentials

- <doc:DefiningRecords>
- ``SQLiteRecord``
- ``SQLiteRecordDescriptor``
- ``SQLiteColumn``
- ``SQLiteRecordRow``

### Codecs

- ``SQLiteCodec``

### Versions and snapshots

- ``SQLiteRecordVersion``
- ``SQLiteRecordSnapshot``

### Writing

- ``SQLiteWriteExpectation``
- ``SQLiteRecordWriteOutcome``
- ``SQLiteRecordWrite``
- ``SQLiteRecordWriteReport``
- ``SQLiteRecordBatchOutcome``

### Store and change stream

- ``SQLiteModelStore``
- ``SQLiteChangeSubscription``
- ``SQLiteChangeEvent``
- ``SQLiteCommittedChange``
- ``SQLiteRecordChange``
- ``SQLiteChangeOrigin``
- ``SQLiteModelStore/ChangeLog``
- ``SQLiteModelSchema``
