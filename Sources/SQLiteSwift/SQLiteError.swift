// SPDX-License-Identifier: Apache-2.0

/// A SQLite result code, primary or extended.
///
/// The low eight bits are the primary result code (for example `5` for
/// `SQLITE_BUSY`). The higher bits carry the extended code
/// (for example `SQLITE_CONSTRAINT_UNIQUE`).
public struct SQLiteResultCode: RawRepresentable, Sendable, Hashable, CustomStringConvertible {
    public var rawValue: Int32

    public init(rawValue: Int32) {
        self.rawValue = rawValue
    }

    /// The primary result code (the low eight bits).
    public var primary: SQLiteResultCode {
        SQLiteResultCode(rawValue: rawValue & 0xFF)
    }

    public var description: String { "SQLite result code \(rawValue)" }

    public static let busy = SQLiteResultCode(rawValue: 5)
    public static let locked = SQLiteResultCode(rawValue: 6)
    public static let readOnly = SQLiteResultCode(rawValue: 8)
    public static let interrupt = SQLiteResultCode(rawValue: 9)
    public static let ioError = SQLiteResultCode(rawValue: 10)
    public static let corrupt = SQLiteResultCode(rawValue: 11)
    public static let full = SQLiteResultCode(rawValue: 13)
    public static let cantOpen = SQLiteResultCode(rawValue: 14)
    public static let tooBig = SQLiteResultCode(rawValue: 18)
    public static let constraint = SQLiteResultCode(rawValue: 19)
    public static let notADatabase = SQLiteResultCode(rawValue: 26)
}

/// The details SQLite reported for a failed call.
public struct SQLiteErrorDetails: Sendable, Hashable, CustomStringConvertible {
    /// The extended result code.
    public var code: SQLiteResultCode
    /// SQLite's English-language message (`sqlite3_errmsg`).
    public var message: String

    public init(code: SQLiteResultCode, message: String) {
        self.code = code
        self.message = message
    }

    public var description: String { "\(message) (code \(code.rawValue))" }
}

/// The kind of a ``SQLiteValue``, used by ``SQLiteError/typeMismatch(column:expected:actual:)``.
public enum SQLiteValueKind: String, Sendable, Hashable {
    case null, integer, real, text, blob
}

/// Every error thrown by SQLiteSwift.
///
/// An error has a ``code`` that says what went wrong, a human-readable ``description``
/// and, depending on the code, more detail: ``details`` for errors SQLite reported,
/// ``underlying`` for wrapped errors, and the typed accessors listed on each code.
///
/// Match on ``code``. `Code` is a struct, not an enum, so new codes can be added in
/// minor releases without breaking your `switch`; give it a `default` branch.
///
/// ```swift
/// do throws(SQLiteError) {
///     try await database.write { tx throws(SQLiteError) in ... }
/// } catch {
///     switch error.code {
///     case .busy: retryLater()
///     case .commitOutcomeUnknown: try await reconcile()
///     default: throw error
///     }
/// }
/// ```
///
/// ## Commit outcomes
///
/// When a write throws, whether its transaction was committed depends on the code:
/// - ``Code/commitOutcomeUnknown``: `COMMIT` was issued and did not report success,
///   and the transaction is no longer open. The data may or may not be durable.
///   Resolve it with ``SQLiteDatabase/resolveCommit(_:)`` (for example by reading an
///   idempotency key written in the same transaction).
/// - Every other code: the transaction was not committed. Either the failure happened
///   before `COMMIT` was issued, or `COMMIT` failed while the transaction was still
///   open on the connection (for example a deferred foreign-key violation), and it was
///   then rolled back.
public struct SQLiteError: Error, Sendable, Hashable, CustomStringConvertible {
    /// What went wrong. Compare with `==` or `switch` (with a `default` branch).
    public struct Code: Sendable, Hashable, CustomStringConvertible {
        /// A stable, machine-readable name, for example `"busy"`.
        public let name: String

        private init(_ name: String) { self.name = name }

        public var description: String { name }

        /// Matches an error against a code, so `catch` clauses can name it:
        /// `catch SQLiteError.Code.busy { ... }`.
        public static func ~= (pattern: Code, error: any Error) -> Bool {
            (error as? SQLiteError)?.code == pattern
        }

        // SQLite result codes with their own meaning. `details` is set.

        /// The database stayed locked (`SQLITE_BUSY` or `SQLITE_LOCKED`) after the
        /// configured busy timeout ran out.
        public static let busy = Code("busy")
        /// A constraint failed (`SQLITE_CONSTRAINT`). The extended code in ``SQLiteError/details`` says which kind.
        public static let constraint = Code("constraint")
        /// The database file is corrupt or is not a database (`SQLITE_CORRUPT`, `SQLITE_NOTADB`).
        public static let corrupt = Code("corrupt")
        /// The database or disk is full (`SQLITE_FULL`), including reaching `max_page_count`.
        public static let full = Code("full")
        /// A write was attempted on a read-only connection or file (`SQLITE_READONLY`).
        public static let readOnly = Code("readOnly")
        /// The database file could not be opened (`SQLITE_CANTOPEN`), for example because
        /// its directory doesn't exist or isn't accessible.
        public static let cantOpen = Code("cantOpen")
        /// An operating-system I/O error (`SQLITE_IOERR`). The extended code says which
        /// operation failed (for example `SQLITE_IOERR_FSYNC`).
        public static let ioError = Code("ioError")
        /// A string, BLOB or row exceeded SQLite's length limit (`SQLITE_TOOBIG`).
        public static let tooBig = Code("tooBig")
        /// Any other SQLite result code.
        public static let sqlite = Code("sqlite")

        // Stopped operations. Any open transaction was rolled back.

        /// The operation stopped because the calling task was cancelled
        /// (`sqlite3_interrupt`).
        public static let interrupted = Code("interrupted")
        /// The operation ran past its ``SQLiteOperationLimits/timeout``.
        public static let deadlineExceeded = Code("deadlineExceeded")
        /// The operation used more than its
        /// ``SQLiteOperationLimits/maxInstructions``. ``SQLiteError/limit`` is the budget.
        public static let instructionLimitExceeded = Code("instructionLimitExceeded")

        // Commit outcome.

        /// `COMMIT` was issued but did not report success, and the transaction is no
        /// longer open, so SQLiteSwift cannot tell whether it was committed.
        /// ``SQLiteError/underlying`` is what `COMMIT` reported.
        public static let commitOutcomeUnknown = Code("commitOutcomeUnknown")

        // Schema, file and settings.

        /// The database's `user_version` is newer than the migrations this code knows.
        /// The database is left untouched. See ``SQLiteError/databaseVersion`` and
        /// ``SQLiteError/supportedVersion``.
        public static let schemaTooNew = Code("schemaTooNew")
        /// A migration failed. Its transaction was rolled back, unless
        /// ``SQLiteError/underlying`` is ``commitOutcomeUnknown``; earlier migrations
        /// stay committed. See ``SQLiteError/migrationVersion`` and
        /// ``SQLiteError/migrationName``.
        public static let migrationFailed = Code("migrationFailed")
        /// A setting SQLiteSwift applied was not in effect when read back. The database
        /// was closed again. See ``SQLiteError/setting``.
        public static let settingMismatch = Code("settingMismatch")
        /// An existing file does not have the configured ``SQLiteFileIdentity``. Nothing
        /// was written. See ``SQLiteError/setting``.
        public static let fileIdentityMismatch = Code("fileIdentityMismatch")

        // Limits and values.

        /// A result exceeded its byte budget. ``SQLiteError/limit`` is the budget.
        public static let resultTooLarge = Code("resultTooLarge")
        /// A query returned more rows than allowed. ``SQLiteError/limit`` is the limit.
        public static let rowLimitExceeded = Code("rowLimitExceeded")
        /// A column value did not have the requested type. See
        /// ``SQLiteError/typeMismatch``.
        public static let typeMismatch = Code("typeMismatch")

        // Usage.

        /// The database was closed.
        public static let closed = Code("closed")
        /// The configuration or the migration list is invalid.
        public static let invalidConfiguration = Code("invalidConfiguration")
        /// An argument was invalid (for example an identifier containing NUL, or a
        /// per-query limit above the configured hard cap).
        public static let invalidArgument = Code("invalidArgument")
        /// The API was used incorrectly (for example a transaction used after its
        /// closure returned).
        public static let misuse = Code("misuse")
    }

    /// The detail of a ``Code/typeMismatch`` error.
    public struct TypeMismatch: Sendable, Hashable {
        /// The zero-based column index.
        public var column: Int
        public var expected: SQLiteValueKind
        public var actual: SQLiteValueKind
    }

    /// The detail of a ``Code/settingMismatch`` or ``Code/fileIdentityMismatch`` error.
    public struct SettingMismatch: Sendable, Hashable {
        /// The setting, for example `journal_mode` or `application_id`.
        public var name: String
        public var expected: String
        public var actual: String
    }

    private enum Payload: Sendable, Hashable {
        case none
        case details(SQLiteErrorDetails)
        case reason(String)
        case limit(Int)
        case versions(database: Int, supported: Int)
        case typeMismatch(TypeMismatch)
        case setting(SettingMismatch)
        case migration(version: Int, name: String)
    }

    /// What went wrong.
    public let code: Code
    private let payload: Payload
    // An array, so the struct can contain an error of its own type.
    private let wrapped: [SQLiteError]

    private init(_ code: Code, _ payload: Payload = .none, underlying: SQLiteError? = nil) {
        self.code = code
        self.payload = payload
        self.wrapped = underlying.map { [$0] } ?? []
    }

    // MARK: Detail

    /// What SQLite reported, for errors that came from a SQLite call.
    public var details: SQLiteErrorDetails? {
        if case .details(let d) = payload { return d }
        return nil
    }

    /// The error this one wraps: what `COMMIT` reported for
    /// ``Code/commitOutcomeUnknown``, or why a migration failed for
    /// ``Code/migrationFailed``.
    public var underlying: SQLiteError? { wrapped.first }

    /// The explanation for ``Code/invalidConfiguration``, ``Code/invalidArgument`` and
    /// ``Code/misuse``.
    public var reason: String? {
        if case .reason(let r) = payload { return r }
        return nil
    }

    /// The limit that was exceeded, for ``Code/resultTooLarge``,
    /// ``Code/rowLimitExceeded`` and ``Code/instructionLimitExceeded``.
    public var limit: Int? {
        if case .limit(let l) = payload { return l }
        return nil
    }

    /// The database's `user_version`, for ``Code/schemaTooNew``.
    public var databaseVersion: Int? {
        if case .versions(let database, _) = payload { return database }
        return nil
    }

    /// The newest schema version the migrations define, for ``Code/schemaTooNew``.
    public var supportedVersion: Int? {
        if case .versions(_, let supported) = payload { return supported }
        return nil
    }

    /// The failed migration's version, for ``Code/migrationFailed``.
    public var migrationVersion: Int? {
        if case .migration(let version, _) = payload { return version }
        return nil
    }

    /// The failed migration's name, for ``Code/migrationFailed``.
    public var migrationName: String? {
        if case .migration(_, let name) = payload { return name }
        return nil
    }

    /// The detail of a ``Code/typeMismatch`` error.
    public var typeMismatch: TypeMismatch? {
        if case .typeMismatch(let t) = payload { return t }
        return nil
    }

    /// The detail of a ``Code/settingMismatch`` or ``Code/fileIdentityMismatch`` error.
    public var setting: SettingMismatch? {
        if case .setting(let s) = payload { return s }
        return nil
    }

    /// The SQLite result code behind this error, if it came from SQLite, including
    /// through ``underlying``.
    public var resultCode: SQLiteResultCode? {
        if let details { return details.code }
        if code == .interrupted { return .interrupt }
        return underlying?.resultCode
    }

    /// Whether the operation stopped because it was cancelled or ran out of time or
    /// instructions (``Code/interrupted``, ``Code/deadlineExceeded`` or
    /// ``Code/instructionLimitExceeded``). Its transaction was rolled back.
    public var isStop: Bool {
        code == .interrupted || code == .deadlineExceeded || code == .instructionLimitExceeded
    }

    public var description: String {
        switch payload {
        case .details(let d):
            switch code {
            case .busy: return "database is busy: \(d)"
            case .constraint: return "constraint failed: \(d)"
            case .corrupt: return "database is corrupt: \(d)"
            case .full: return "database or disk is full: \(d)"
            case .readOnly: return "read-only: \(d)"
            case .cantOpen: return "cannot open database: \(d)"
            case .ioError: return "I/O error: \(d)"
            case .tooBig: return "value too big: \(d)"
            default: return "SQLite error: \(d)"
            }
        case .reason(let reason):
            switch code {
            case .invalidConfiguration: return "invalid configuration: \(reason)"
            case .invalidArgument: return "invalid argument: \(reason)"
            default: return "\(code): \(reason)"
            }
        case .limit(let limit):
            switch code {
            case .resultTooLarge: return "result exceeds the limit of \(limit) bytes"
            case .rowLimitExceeded: return "query returned more than \(limit) rows"
            case .instructionLimitExceeded: return "operation exceeded its budget of \(limit) instructions"
            default: return "\(code) (limit \(limit))"
            }
        case .versions(let found, let supported):
            return "database schema version \(found) is newer than supported version \(supported)"
        case .typeMismatch(let t):
            return "column \(t.column) is \(t.actual.rawValue), expected \(t.expected.rawValue)"
        case .setting(let s):
            let what = code == .fileIdentityMismatch ? "file identity" : "setting"
            return "\(what) \(s.name) is \(s.actual), expected \(s.expected)"
        case .migration(let version, let name):
            return "migration \(version) (\(name)) failed: \(underlying.map(String.init(describing:)) ?? "unknown")"
        case .none:
            switch code {
            case .interrupted: return "operation interrupted by task cancellation"
            case .deadlineExceeded: return "operation exceeded its deadline"
            case .closed: return "database is closed"
            case .commitOutcomeUnknown:
                return "commit outcome unknown (COMMIT reported: \(underlying.map(String.init(describing:)) ?? "nothing"))"
            default: return code.name
            }
        }
    }

    // MARK: Making errors

    /// An error for a SQLite result code.
    public static func sqlite(code: SQLiteResultCode, message: String) -> SQLiteError {
        let details = SQLiteErrorDetails(code: code, message: message)
        let kind: Code
        switch code.primary {
        case .busy, .locked: kind = .busy
        case .constraint: kind = .constraint
        case .corrupt, .notADatabase: kind = .corrupt
        case .full: kind = .full
        case .readOnly: kind = .readOnly
        case .tooBig: kind = .tooBig
        case .cantOpen: kind = .cantOpen
        case .ioError: kind = .ioError
        case .interrupt: return .interrupted
        default: kind = .sqlite
        }
        return SQLiteError(kind, .details(details))
    }

    static func make(code: Int32, message: String) -> SQLiteError {
        sqlite(code: SQLiteResultCode(rawValue: code), message: message)
    }

    /// The task was cancelled.
    public static let interrupted = SQLiteError(.interrupted)
    /// The operation ran past its deadline.
    public static let deadlineExceeded = SQLiteError(.deadlineExceeded)
    /// The database is closed.
    public static let closed = SQLiteError(.closed)

    public static func instructionLimitExceeded(limit: Int) -> SQLiteError {
        SQLiteError(.instructionLimitExceeded, .limit(limit))
    }
    public static func commitOutcomeUnknown(_ underlying: SQLiteError) -> SQLiteError {
        SQLiteError(.commitOutcomeUnknown, underlying: underlying)
    }
    public static func schemaTooNew(databaseVersion: Int, supportedVersion: Int) -> SQLiteError {
        SQLiteError(.schemaTooNew, .versions(database: databaseVersion, supported: supportedVersion))
    }
    public static func migrationFailed(version: Int, name: String, underlying: SQLiteError) -> SQLiteError {
        SQLiteError(.migrationFailed, .migration(version: version, name: name), underlying: underlying)
    }
    public static func settingMismatch(setting: String, expected: String, actual: String) -> SQLiteError {
        SQLiteError(.settingMismatch, .setting(SettingMismatch(name: setting, expected: expected, actual: actual)))
    }
    public static func fileIdentityMismatch(setting: String, expected: String, actual: String) -> SQLiteError {
        SQLiteError(.fileIdentityMismatch, .setting(SettingMismatch(name: setting, expected: expected, actual: actual)))
    }
    public static func resultTooLarge(limit: Int) -> SQLiteError {
        SQLiteError(.resultTooLarge, .limit(limit))
    }
    public static func rowLimitExceeded(limit: Int) -> SQLiteError {
        SQLiteError(.rowLimitExceeded, .limit(limit))
    }
    public static func typeMismatch(column: Int, expected: SQLiteValueKind, actual: SQLiteValueKind) -> SQLiteError {
        SQLiteError(.typeMismatch, .typeMismatch(TypeMismatch(column: column, expected: expected, actual: actual)))
    }
    public static func invalidConfiguration(_ reason: String) -> SQLiteError {
        SQLiteError(.invalidConfiguration, .reason(reason))
    }
    public static func invalidArgument(_ reason: String) -> SQLiteError {
        SQLiteError(.invalidArgument, .reason(reason))
    }
    public static func misuse(_ reason: String) -> SQLiteError {
        SQLiteError(.misuse, .reason(reason))
    }
    /// A read-only error that SQLiteSwift raises itself (with `SQLITE_READONLY`).
    static func readOnly(_ message: String) -> SQLiteError {
        sqlite(code: .readOnly, message: message)
    }
}
