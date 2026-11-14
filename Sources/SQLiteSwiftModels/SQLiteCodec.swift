// SPDX-License-Identifier: Apache-2.0

import Foundation
import SQLiteSwift

/// Converts one Swift value to and from its exact SQLite storage.
///
/// Codecs are strict: decoding never repairs or guesses. NULL in a non-optional
/// column, a wrong storage class, invalid UTF-8, an out-of-range integer or an
/// unparsable value throws ``SQLiteError/Code/invalidStoredValue`` naming the column.
/// Wrap a codec in ``optional(_:)`` to map SQL NULL to `nil`.
public struct SQLiteCodec<Value>: Sendable {
    /// A short description of the stored form, for example `TEXT (UTF-8)`.
    public let storage: String
    let encodeValue: @Sendable (Value) throws(SQLiteError) -> SQLiteRawValue
    let decodeValue: @Sendable (SQLiteRawValue) throws(CodecFailure) -> Value

    /// A codec from two conversion functions. `decode` throws ``CodecFailure`` with a
    /// reason; the caller adds the column name.
    public init(
        storage: String,
        encode: @escaping @Sendable (Value) throws(SQLiteError) -> SQLiteRawValue,
        decode: @escaping @Sendable (SQLiteRawValue) throws(CodecFailure) -> Value
    ) {
        self.storage = storage
        self.encodeValue = encode
        self.decodeValue = decode
    }

    /// Why a stored value could not be decoded.
    public struct CodecFailure: Error, Sendable, Hashable {
        public var reason: String
        public init(_ reason: String) { self.reason = reason }
    }

    /// Encodes a value for binding.
    public func encode(_ value: Value) throws(SQLiteError) -> SQLiteRawValue {
        try encodeValue(value)
    }

    /// Decodes a stored value; `column` names it in the error.
    public func decode(_ stored: SQLiteRawValue, column: String) throws(SQLiteError) -> Value {
        do throws(CodecFailure) {
            return try decodeValue(stored)
        } catch {
            throw .invalidStoredValue(column: column, reason: error.reason)
        }
    }
}

// MARK: - Helpers

func unexpected(_ stored: SQLiteRawValue, expected: String) -> SQLiteCodec<Never>.CodecFailure {
    if case .null = stored { return .init("NULL in a non-optional \(expected) column") }
    return .init("expected \(expected), found \(stored.kind.rawValue)")
}

extension SQLiteCodec {
    /// Maps SQL NULL to `nil`; other values use `wrapped`.
    public static func optional<Wrapped>(_ wrapped: SQLiteCodec<Wrapped>) -> SQLiteCodec<Wrapped?>
    where Value == Wrapped? {
        SQLiteCodec<Wrapped?>(
            storage: wrapped.storage + " or NULL",
            encode: { (value) throws(SQLiteError) in
                guard let value else { return .null }
                return try wrapped.encodeValue(value)
            },
            decode: { (stored) throws(SQLiteCodec<Wrapped?>.CodecFailure) in
                if case .null = stored { return nil }
                do throws(SQLiteCodec<Wrapped>.CodecFailure) {
                    return try wrapped.decodeValue(stored)
                } catch {
                    throw .init(error.reason)
                }
            })
    }

    /// Stores a `RawRepresentable` value (for example a string enum) through its raw
    /// value. An unknown raw value is an invalid stored value.
    public static func rawValue(_ raw: SQLiteCodec<Value.RawValue>) -> SQLiteCodec<Value>
    where Value: RawRepresentable & Sendable {
        SQLiteCodec(
            storage: raw.storage,
            encode: { (value) throws(SQLiteError) in try raw.encodeValue(value.rawValue) },
            decode: { (stored) throws(CodecFailure) in
                let rawValue: Value.RawValue
                do throws(SQLiteCodec<Value.RawValue>.CodecFailure) {
                    rawValue = try raw.decodeValue(stored)
                } catch {
                    throw .init(error.reason)
                }
                guard let value = Value(rawValue: rawValue) else {
                    throw .init("\(rawValue) is not a valid \(Value.self)")
                }
                return value
            })
    }
}

// MARK: - Text and bytes

extension SQLiteCodec where Value == String {
    /// TEXT, valid UTF-8. Invalid UTF-8 is refused, never repaired.
    public static var text: SQLiteCodec<String> {
        SQLiteCodec(
            storage: "TEXT (UTF-8)",
            encode: { (value) throws(SQLiteError) in .text(Array(value.utf8)) },
            decode: { (stored) throws(CodecFailure) in
                guard case .text(let bytes) = stored else { throw .init(unexpected(stored, expected: "TEXT").reason) }
                guard let string = String(validating: bytes, as: UTF8.self) else {
                    throw .init("TEXT is not valid UTF-8")
                }
                return string
            })
    }
}

extension SQLiteCodec where Value == [UInt8] {
    /// BLOB, byte for byte. An empty BLOB decodes to `[]`.
    public static var blob: SQLiteCodec<[UInt8]> {
        SQLiteCodec(
            storage: "BLOB",
            encode: { (value) throws(SQLiteError) in .blob(value) },
            decode: { (stored) throws(CodecFailure) in
                guard case .blob(let bytes) = stored else { throw .init(unexpected(stored, expected: "BLOB").reason) }
                return bytes
            })
    }
}

// MARK: - Numbers

extension SQLiteCodec where Value == Int64 {
    /// INTEGER.
    public static var integer: SQLiteCodec<Int64> {
        SQLiteCodec(
            storage: "INTEGER",
            encode: { (value) throws(SQLiteError) in .integer(value) },
            decode: { (stored) throws(CodecFailure) in
                guard case .integer(let value) = stored else { throw .init(unexpected(stored, expected: "INTEGER").reason) }
                return value
            })
    }
}

extension SQLiteCodec where Value == Int {
    /// INTEGER, range-checked against `Int`.
    public static var int: SQLiteCodec<Int> {
        SQLiteCodec(
            storage: "INTEGER",
            encode: { (value) throws(SQLiteError) in .integer(Int64(value)) },
            decode: { (stored) throws(CodecFailure) in
                guard case .integer(let value) = stored else { throw .init(unexpected(stored, expected: "INTEGER").reason) }
                guard let int = Int(exactly: value) else { throw .init("\(value) does not fit in Int") }
                return int
            })
    }
}

extension SQLiteCodec where Value == Bool {
    /// INTEGER 0 or 1. Any other value is refused.
    public static var bool: SQLiteCodec<Bool> {
        SQLiteCodec(
            storage: "INTEGER (0 or 1)",
            encode: { (value) throws(SQLiteError) in .integer(value ? 1 : 0) },
            decode: { (stored) throws(CodecFailure) in
                switch stored {
                case .integer(0): return false
                case .integer(1): return true
                case .integer(let other): throw .init("\(other) is not a Bool (0 or 1)")
                default: throw .init(unexpected(stored, expected: "INTEGER").reason)
                }
            })
    }
}

extension SQLiteCodec where Value == Double {
    /// REAL. An INTEGER is accepted when it converts to `Double` exactly (SQLite may
    /// store whole numbers as INTEGER). NaN is refused when encoding (SQLite stores it
    /// as NULL).
    public static var real: SQLiteCodec<Double> {
        SQLiteCodec(
            storage: "REAL",
            encode: { (value) throws(SQLiteError) in
                guard !value.isNaN else { throw .invalidArgument("NaN cannot be stored; SQLite turns it into NULL") }
                return .real(value)
            },
            decode: { (stored) throws(CodecFailure) in
                switch stored {
                case .real(let value): return value
                case .integer(let value):
                    guard let exact = Double(exactly: value) else { throw .init("\(value) is not exactly representable as Double") }
                    return exact
                default: throw .init(unexpected(stored, expected: "REAL").reason)
                }
            })
    }
}

extension SQLiteCodec where Value == Decimal {
    /// TEXT holding the decimal's canonical description (for example `"12.50"` is
    /// stored as `"12.5"`). Decoding refuses text that doesn't round-trip exactly, so
    /// no precision is lost silently.
    public static var decimalText: SQLiteCodec<Decimal> {
        SQLiteCodec(
            storage: "TEXT (decimal)",
            encode: { (value) throws(SQLiteError) in
                guard !value.isNaN else { throw .invalidArgument("NaN cannot be stored as a decimal") }
                return .text(Array(value.description.utf8))
            },
            decode: { (stored) throws(CodecFailure) in
                guard case .text(let bytes) = stored else { throw .init(unexpected(stored, expected: "TEXT").reason) }
                guard let text = String(validating: bytes, as: UTF8.self),
                      let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")),
                      !value.isNaN, value.description == text
                else { throw .init("\"\(String(decoding: bytes, as: UTF8.self))\" is not a canonical decimal") }
                return value
            })
    }
}

// MARK: - Identifiers and time

extension SQLiteCodec where Value == UUID {
    /// TEXT in lowercase canonical form (`xxxxxxxx-xxxx-…`). Other spellings are refused.
    public static var uuidText: SQLiteCodec<UUID> {
        SQLiteCodec(
            storage: "TEXT (UUID)",
            encode: { (value) throws(SQLiteError) in .text(Array(value.uuidString.lowercased().utf8)) },
            decode: { (stored) throws(CodecFailure) in
                guard case .text(let bytes) = stored else { throw .init(unexpected(stored, expected: "TEXT").reason) }
                let text = String(decoding: bytes, as: UTF8.self)
                guard let value = UUID(uuidString: text), value.uuidString.lowercased() == text else {
                    throw .init("\"\(text)\" is not a lowercase canonical UUID")
                }
                return value
            })
    }

    /// BLOB of exactly 16 bytes.
    public static var uuidBlob: SQLiteCodec<UUID> {
        SQLiteCodec(
            storage: "BLOB (16-byte UUID)",
            encode: { (value) throws(SQLiteError) in
                withUnsafeBytes(of: value.uuid) { .blob(Array($0)) }
            },
            decode: { (stored) throws(CodecFailure) in
                guard case .blob(let bytes) = stored else { throw .init(unexpected(stored, expected: "BLOB").reason) }
                guard bytes.count == 16 else { throw .init("a UUID BLOB has 16 bytes, found \(bytes.count)") }
                var uuid: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
                withUnsafeMutableBytes(of: &uuid) { $0.copyBytes(from: bytes) }
                return UUID(uuid: uuid)
            })
    }
}

extension SQLiteCodec where Value == SQLiteTimestamp {
    /// INTEGER milliseconds since 1970 (the representation expiry helpers use).
    public static var timestamp: SQLiteCodec<SQLiteTimestamp> {
        SQLiteCodec(
            storage: "INTEGER (ms since 1970)",
            encode: { (value) throws(SQLiteError) in .integer(value.millisecondsSince1970) },
            decode: { (stored) throws(CodecFailure) in
                guard case .integer(let ms) = stored else { throw .init(unexpected(stored, expected: "INTEGER").reason) }
                return SQLiteTimestamp(millisecondsSince1970: ms)
            })
    }
}

extension SQLiteCodec where Value == Date {
    /// INTEGER milliseconds since 1970. Sub-millisecond precision is refused when
    /// encoding rather than rounded silently.
    public static var unixMilliseconds: SQLiteCodec<Date> {
        SQLiteCodec(
            storage: "INTEGER (ms since 1970)",
            encode: { (value) throws(SQLiteError) in
                // Dates are binary floating point: accept the nearest millisecond only
                // if it converts back to exactly the same Date.
                let ms = (value.timeIntervalSince1970 * 1000).rounded()
                guard ms.isFinite, let exact = Int64(exactly: ms),
                      Date(timeIntervalSince1970: Double(exact) / 1000) == value
                else {
                    throw .invalidArgument("\(value) is not a whole number of milliseconds since 1970")
                }
                return .integer(exact)
            },
            decode: { (stored) throws(CodecFailure) in
                guard case .integer(let ms) = stored else { throw .init(unexpected(stored, expected: "INTEGER").reason) }
                return Date(timeIntervalSince1970: Double(ms) / 1000)
            })
    }
}
