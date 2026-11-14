# ``SQLiteSwiftModelContext``

An observable, main-actor editing context for SQLiteSwiftModels records.

## Overview

A ``SQLiteModelContext`` loads records into ``SQLiteModel`` handles, one per record,
that views can bind to. You edit a handle's value directly and save the context;
the save is atomic and conditional, so it never overwrites a row that changed in
the meantime. Every handle has an explicit state, and every way out of a conflict
is a decision you make.

While ``SQLiteModelContext/observeChanges(bufferSize:)`` runs, handles follow the
saves of other contexts. ``SQLiteLiveQuery`` keeps a filtered result list current.

## Topics

### Essentials

- <doc:EditingWithAContext>
- ``SQLiteModelContext``
- ``SQLiteModel``

### Saving

- ``SQLiteSaveResult``
- ``SQLiteSaveConflict``
- ``SQLiteSaveResolution``

### Live results

- ``SQLiteLiveQuery``
