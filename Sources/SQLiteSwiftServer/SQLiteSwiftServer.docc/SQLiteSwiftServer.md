# ``SQLiteSwiftServer``

Metrics, tracing, logs and lifecycle for SQLiteSwift, through the Swift server
ecosystem's standard packages.

## Overview

Each bridge is switched on by a package trait. With no trait enabled the module is
empty and SwiftPM resolves none of the dependencies, so a consumer that doesn't ask
for a bridge keeps an empty dependency graph:

```swift
.package(url: "https://github.com/ThorFuchs/Swift-SQLite.git", from: "1.1.0",
         traits: ["Metrics", "Tracing", "Logging", "ServiceLifecycle"]),
```

| Trait | Type | Package |
| --- | --- | --- |
| `Metrics` | ``SQLiteMetricsObserver`` | swift-metrics |
| `Tracing` | ``SQLiteTracingObserver`` | swift-distributed-tracing |
| `Logging` | ``SQLiteLoggingObserver`` | swift-log |
| `ServiceLifecycle` | ``SQLiteDatabaseService`` | swift-service-lifecycle |

The observers plug into the core's `SQLiteObserver` hook, which runs on the calling
task, so spans nest under the request's span and task-local loggers apply. Combine
them with `SQLiteObservers`:

```swift
var configuration = SQLiteConfiguration(path: path)
configuration.observer = SQLiteObservers(
    SQLiteMetricsObserver(database: "orders"),
    SQLiteTracing.observer(),
    SQLiteLoggingObserver())
let database = try await SQLiteDatabase.open(configuration, migrations: migrations)

let group = ServiceGroup(
    services: [httpServer, SQLiteDatabaseService(database, maintenance: .init(every: .seconds(300)))],
    gracefulShutdownSignals: [.sigterm], logger: logger)
try await group.run()
```

## Topics

### Bridges

- ``SQLiteMetricsObserver``
- ``SQLiteTracingObserver``
- ``SQLiteTracing``
- ``SQLiteLoggingObserver``
- ``SQLiteDatabaseService``
