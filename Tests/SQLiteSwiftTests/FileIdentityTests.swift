// SPDX-License-Identifier: Apache-2.0

import SQLiteSwift
import SQLiteSwiftTesting
import Testing

@Suite("File identity and effective settings")
struct FileIdentityTests {
    private let identity = SQLiteFileIdentity(applicationID: 0x5351_4C54, pageSize: 8192, autoVacuum: .incremental)

    private func open(_ path: String, _ identity: SQLiteFileIdentity?) async throws(SQLiteError) -> SQLiteDatabase {
        var configuration = SQLiteConfiguration(path: path)
        configuration.fileIdentity = identity
        return try await SQLiteDatabase.open(configuration, migrations: sampleMigrations)
    }

    @Test("A new file gets the identity; reopening with it succeeds")
    func newFile() async throws {
        let directory = try SQLiteTemporaryDirectory()
        let path = directory.file("id.sqlite")
        let database = try await open(path, identity)
        let settings = try await database.effectiveSettings()
        #expect(settings.applicationID == 0x5351_4C54)
        #expect(settings.pageSize == 8192)
        #expect(settings.autoVacuum == .incremental)
        #expect(settings.journalMode == "wal")
        await database.close()
        let reopened = try await open(path, identity)
        #expect(try await reopened.schemaVersion() == sampleMigrations.count)
        await reopened.close()
    }

    @Test("A file with another identity is refused and left untouched")
    func wrongFile() async throws {
        let directory = try SQLiteTemporaryDirectory()
        let path = directory.file("id.sqlite")
        await (try open(path, identity)).close()
        let before = SQLiteCrashImage.contents(path)
        let error = await caught { try await open(path, SQLiteFileIdentity(applicationID: 42)) }
        #expect(code(error) == .fileIdentityMismatch)
        #expect(error?.setting == SQLiteError.SettingMismatch(name: "application_id", expected: "0x2A", actual: "0x53514C54"))
        #expect(SQLiteCrashImage.contents(path) == before)
        let pageError = await caught { try await open(path, SQLiteFileIdentity(applicationID: 0x5351_4C54, pageSize: 4096)) }
        #expect(pageError?.setting?.name == "page_size")
        let vacuumError = await caught { try await open(path, SQLiteFileIdentity(applicationID: 0x5351_4C54, autoVacuum: .full)) }
        #expect(vacuumError?.setting == SQLiteError.SettingMismatch(name: "auto_vacuum", expected: "FULL", actual: "INCREMENTAL"))
    }

    @Test("An unmarked file is refused unless adoption is allowed")
    func unmarkedFile() async throws {
        let directory = try SQLiteTemporaryDirectory()
        let path = directory.file("old.sqlite")
        await (try open(path, nil)).close()
        let refused = await caught { try await open(path, SQLiteFileIdentity(applicationID: 7)) }
        #expect(code(refused) == .fileIdentityMismatch)
        let adopted = try await open(path, SQLiteFileIdentity(applicationID: 7, adoptsUnmarkedFiles: true))
        #expect(try await adopted.effectiveSettings().applicationID == 7)
        await adopted.close()
        await (try open(path, SQLiteFileIdentity(applicationID: 7))).close()
    }

    @Test("Invalid identities are refused", arguments: [
        SQLiteFileIdentity(applicationID: 0),
        SQLiteFileIdentity(applicationID: 1, pageSize: 1000),
        SQLiteFileIdentity(applicationID: 1, pageSize: 131_072),
    ])
    func invalid(identity: SQLiteFileIdentity) async throws {
        var configuration = SQLiteConfiguration.inMemory()
        configuration.fileIdentity = identity
        let error = await caught { try await SQLiteDatabase.open(configuration, migrations: []) }
        #expect(code(error) == .invalidConfiguration)
    }

    @Test("Effective settings report engine, limits and memory mapping")
    func effectiveSettings() async throws {
        var configuration = SQLiteConfiguration.inMemory()
        configuration.fileIdentity = SQLiteFileIdentity(applicationID: -1)
        let database = try await SQLiteDatabase.open(configuration, migrations: [])
        let settings = try await database.effectiveSettings()
        #expect(settings.applicationID == -1)
        #expect(settings.maxLength == configuration.limits.hardMaxResultBytes)
        #expect(settings.mmapSize >= 0)
        #expect(settings.compileOptions.contains { $0.hasPrefix("THREADSAFE=") })
        await database.close()
    }
}
