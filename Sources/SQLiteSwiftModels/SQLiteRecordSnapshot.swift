// SPDX-License-Identifier: Apache-2.0

import SQLiteSwift

/// Which stored row a snapshot came from, and which change of it.
///
/// - The **revision** starts at 1 and grows by one with every managed update.
/// - The **incarnation** is 16 random bytes set when the row is inserted and never
///   changed. A row deleted and inserted again under the same key gets a new
///   incarnation, so an old snapshot never matches it (no ABA).
public struct SQLiteRecordVersion: Sendable, Hashable, CustomStringConvertible {
    public let revision: Int64
    public let incarnation: [UInt8]

    /// The number of bytes in an incarnation.
    public static let incarnationByteCount = 16

    /// A version from its parts. `revision` must be at least 1 and `incarnation`
    /// 16 bytes.
    public init(revision: Int64, incarnation: [UInt8]) throws(SQLiteError) {
        guard revision >= 1 else { throw .invalidArgument("a revision is at least 1, got \(revision)") }
        guard incarnation.count == Self.incarnationByteCount else {
            throw .invalidArgument("an incarnation has 16 bytes, got \(incarnation.count)")
        }
        self.revision = revision
        self.incarnation = incarnation
    }

    init(stored revision: SQLiteRawValue, incarnation: SQLiteRawValue,
         revisionColumn: String, incarnationColumn: String) throws(SQLiteError) {
        guard case .integer(let value) = revision, value >= 1 else {
            throw .invalidStoredValue(column: revisionColumn, reason: "expected an INTEGER of at least 1, found \(revision)")
        }
        guard case .blob(let bytes) = incarnation, bytes.count == Self.incarnationByteCount else {
            throw .invalidStoredValue(column: incarnationColumn, reason: "expected a 16-byte BLOB, found \(incarnation)")
        }
        self.revision = value
        self.incarnation = bytes
    }

    public var description: String {
        let hex = incarnation.prefix(4).map { byte in
            let digits = String(byte, radix: 16)
            return digits.count == 1 ? "0" + digits : digits
        }.joined()
        return "r\(revision)/\(hex)…"
    }
}

/// An immutable record value together with the version it was read at.
public struct SQLiteRecordSnapshot<Record: SQLiteRecord>: Sendable, Equatable {
    public let value: Record
    public let version: SQLiteRecordVersion

    public init(value: Record, version: SQLiteRecordVersion) {
        self.value = value
        self.version = version
    }
}

extension SQLiteRecordSnapshot: Hashable where Record: Hashable {}
