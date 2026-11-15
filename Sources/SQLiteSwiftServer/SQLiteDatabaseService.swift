// SPDX-License-Identifier: Apache-2.0

#if ServiceLifecycle
import ServiceLifecycle
import SQLiteSwift

/// Runs a database as a service in a `ServiceGroup`: it closes the database on graceful
/// shutdown and can run explicit maintenance on a schedule meanwhile.
///
/// ```swift
/// let service = SQLiteDatabaseService(database, maintenance: .init(every: .seconds(300)))
/// let group = ServiceGroup(services: [service, httpServer], logger: logger)
/// try await group.run()
/// ```
///
/// On graceful shutdown it stops the maintenance, runs `PRAGMA optimize` (if
/// maintenance asked for it) and closes the database, which lets running operations
/// finish and fails waiting ones with `.closed`. Put it after the services that use the
/// database, so they stop first. Maintenance failures don't end the service; an
/// observer on the database sees them.
public struct SQLiteDatabaseService: Service {
    /// Maintenance on a fixed interval.
    public struct Maintenance: Sendable {
        public var interval: Duration
        /// A WAL checkpoint each interval; `nil` for none.
        public var checkpoint: SQLiteCheckpointMode?
        /// `PRAGMA optimize` each interval and before closing.
        public var optimize: Bool

        public init(every interval: Duration, checkpoint: SQLiteCheckpointMode? = .passive, optimize: Bool = true) {
            self.interval = interval
            self.checkpoint = checkpoint
            self.optimize = optimize
        }
    }

    public let database: SQLiteDatabase
    public let maintenance: Maintenance?

    public init(_ database: SQLiteDatabase, maintenance: Maintenance? = nil) {
        self.database = database
        self.maintenance = maintenance
    }

    public func run() async throws {
        if let maintenance {
            _ = try? await cancelWhenGracefulShutdown { try await Self.maintain(self.database, maintenance) }
            if maintenance.optimize { try? await database.optimize() }
        } else {
            try? await gracefulShutdown()
        }
        await database.close()
    }

    private static func maintain(_ database: SQLiteDatabase, _ maintenance: Maintenance) async throws {
        while true {
            try await Task.sleep(for: maintenance.interval)
            if let mode = maintenance.checkpoint { _ = try? await database.checkpoint(mode) }
            if maintenance.optimize { try? await database.optimize() }
        }
    }
}
#endif
