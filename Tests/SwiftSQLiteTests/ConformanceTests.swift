// SPDX-License-Identifier: Apache-2.0

import SwiftSQLite
import SwiftSQLiteTesting
import Testing

/// Runs the generic conformance kit against several configurations.
@Suite("Conformance kit")
struct ConformanceTests {
    static let checks = SQLiteConformanceKit.Check.allCases

    private func expectPassed(_ result: SQLiteConformanceKit.CheckResult) {
        #expect(result.outcome == .passed, "\(result.check): \(result.outcome) notes: \(result.notes)")
    }

    @Test("Default pool (1 writer + 4 readers), synchronous=FULL", arguments: checks)
    func defaultConfiguration(check: SQLiteConformanceKit.Check) async {
        let kit = SQLiteConformanceKit(migrations: sampleMigrations)
        expectPassed(await kit.run(check))
    }

    @Test("Single connection", arguments: checks)
    func singleConnection(check: SQLiteConformanceKit.Check) async {
        let kit = SQLiteConformanceKit(migrations: sampleMigrations) { path in
            SQLiteConfiguration.singleConnection(path: path)
        }
        expectPassed(await kit.run(check))
    }

    @Test("synchronous=NORMAL opt-in, 2 readers, no statement cache", arguments: checks)
    func normalSynchronous(check: SQLiteConformanceKit.Check) async {
        let kit = SQLiteConformanceKit(migrations: sampleMigrations) { path in
            var configuration = SQLiteConfiguration(path: path)
            configuration.synchronous = .normal
            configuration.readerCount = 2
            configuration.limits.statementCacheCapacity = 0
            return configuration
        }
        expectPassed(await kit.run(check))
    }

    @Test("No consumer migrations", arguments: checks)
    func noMigrations(check: SQLiteConformanceKit.Check) async {
        let kit = SQLiteConformanceKit()
        expectPassed(await kit.run(check))
    }

    @Test("In-memory database skips file-only checks", arguments: checks)
    func inMemory(check: SQLiteConformanceKit.Check) async {
        let kit = SQLiteConformanceKit(migrations: sampleMigrations) { _ in .inMemory() }
        let result = await kit.run(check)
        switch check {
        case .schemaTooNew, .busyContention, .walCheckpoint, .recoveryAfterAbortedWrite:
            #expect(result.outcome == .skipped("needs a file database"))
        default:
            expectPassed(result)
        }
    }

    @Test("runAll returns every check in order")
    func runAll() async {
        let results = await SQLiteConformanceKit(migrations: sampleMigrations).runAll()
        #expect(results.map(\.check) == SQLiteConformanceKit.Check.allCases)
        for result in results { expectPassed(result) }
    }
}
