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

/// Every error thrown by SwiftSQLite.
///
/// SQLite result codes that callers usually need to handle (busy, constraint,
/// corrupt, full, interrupted) have their own cases. Every other result code is
/// wrapped in ``sqlite(_:)``.
public enum SQLiteError: Error, Sendable, Hashable, CustomStringConvertible {
    /// The database stayed locked (`SQLITE_BUSY` or `SQLITE_LOCKED`) after the
    /// configured busy timeout ran out.
    case busy(SQLiteErrorDetails)
    /// A constraint failed (`SQLITE_CONSTRAINT`). The extended code says which kind.
    case constraint(SQLiteErrorDetails)
    /// The database file is corrupt or is not a database (`SQLITE_CORRUPT`, `SQLITE_NOTADB`).
    case corrupt(SQLiteErrorDetails)
    /// The database or disk is full (`SQLITE_FULL`). This includes reaching `max_page_count`.
    case full(SQLiteErrorDetails)
    /// A write was attempted on a read-only connection or file (`SQLITE_READONLY`).
    case readOnly(SQLiteErrorDetails)
    /// A string, BLOB or row exceeded SQLite's length limit (`SQLITE_TOOBIG`).
    case tooBig(SQLiteErrorDetails)
    /// The operation stopped because the calling task was cancelled.
    ///
    /// SwiftSQLite calls `sqlite3_interrupt` on the connection running the operation.
    /// Any open transaction is rolled back before this error is thrown.
    case interrupted
    /// The database's `user_version` is newer than the migrations this code knows.
    ///
    /// The database is left untouched; nothing is written to it.
    case schemaTooNew(databaseVersion: Int, supportedVersion: Int)
    /// A result exceeded its byte budget (``SQLiteQueryLimits/maxBytes`` or a BLOB limit).
    case resultTooLarge(limit: Int)
    /// A query returned more rows than its ``SQLiteQueryLimits/maxRows``.
    case rowLimitExceeded(limit: Int)
    /// A column value did not have the requested type.
    case typeMismatch(column: Int, expected: SQLiteValueKind, actual: SQLiteValueKind)
    /// The database was closed.
    case closed
    /// The configuration or the migration list is invalid.
    case invalidConfiguration(String)
    /// An argument was invalid (for example an identifier containing NUL, or a
    /// per-query limit above the configured hard cap).
    case invalidArgument(String)
    /// The API was used incorrectly (for example a transaction used after its closure returned).
    case misuse(String)
    /// A migration failed. The migration's transaction was rolled back; earlier
    /// migrations stay committed.
    indirect case migrationFailed(version: Int, name: String, underlying: SQLiteError)
    /// Any other SQLite result code.
    case sqlite(SQLiteErrorDetails)

    public var description: String {
        switch self {
        case .busy(let d): "database is busy: \(d)"
        case .constraint(let d): "constraint failed: \(d)"
        case .corrupt(let d): "database is corrupt: \(d)"
        case .full(let d): "database or disk is full: \(d)"
        case .readOnly(let d): "read-only: \(d)"
        case .tooBig(let d): "value too big: \(d)"
        case .interrupted: "operation interrupted by task cancellation"
        case .schemaTooNew(let found, let supported):
            "database schema version \(found) is newer than supported version \(supported)"
        case .resultTooLarge(let limit): "result exceeds the limit of \(limit) bytes"
        case .rowLimitExceeded(let limit): "query returned more than \(limit) rows"
        case .typeMismatch(let column, let expected, let actual):
            "column \(column) is \(actual.rawValue), expected \(expected.rawValue)"
        case .closed: "database is closed"
        case .invalidConfiguration(let reason): "invalid configuration: \(reason)"
        case .invalidArgument(let reason): "invalid argument: \(reason)"
        case .misuse(let reason): "misuse: \(reason)"
        case .migrationFailed(let version, let name, let underlying):
            "migration \(version) (\(name)) failed: \(underlying)"
        case .sqlite(let d): "SQLite error: \(d)"
        }
    }

    /// The SQLite result code behind this error, if it came from SQLite.
    public var resultCode: SQLiteResultCode? {
        switch self {
        case .busy(let d), .constraint(let d), .corrupt(let d), .full(let d),
            .readOnly(let d), .tooBig(let d), .sqlite(let d):
            d.code
        case .interrupted: .interrupt
        case .migrationFailed(_, _, let underlying): underlying.resultCode
        default: nil
        }
    }

    /// Maps a SQLite result code and message to a typed error.
    static func make(code: Int32, message: String) -> SQLiteError {
        let details = SQLiteErrorDetails(code: SQLiteResultCode(rawValue: code), message: message)
        switch details.code.primary {
        case .busy, .locked: return .busy(details)
        case .constraint: return .constraint(details)
        case .corrupt, .notADatabase: return .corrupt(details)
        case .full: return .full(details)
        case .readOnly: return .readOnly(details)
        case .tooBig: return .tooBig(details)
        case .interrupt: return .interrupted
        default: return .sqlite(details)
        }
    }
}
