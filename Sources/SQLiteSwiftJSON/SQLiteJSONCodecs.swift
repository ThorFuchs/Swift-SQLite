// SPDX-License-Identifier: Apache-2.0

// Record codecs for exact JSON values from ThorFuchs/Swift-JSON. Compiled only with
// the `SwiftJSON` package trait, so without it this module is empty and the
// dependency graph stays empty:
//
//     .package(url: "https://github.com/ThorFuchs/Swift-SQLite.git", from: "1.3.0",
//              traits: ["SwiftJSON"])

#if SwiftJSON
import Foundation
import JSON
import SQLiteSwift
import SQLiteSwiftModels

extension SQLiteCodec where Value == JSON {
    /// A JSON value as compact JSON text (UTF-8), with every number exactly as parsed.
    ///
    /// SQLite's JSON functions work on the stored text directly, for example
    /// `WHERE payload ->> '$.status' = ?` and indexes on such a path. Reading refuses
    /// anything that isn't JSON text, naming the column: invalid JSON, another storage
    /// class, or a JSONB BLOB written by SQL (select `json(column)` for those).
    public static var jsonText: SQLiteCodec<JSON> {
        SQLiteCodec(
            storage: "TEXT (JSON)",
            encode: { (value) throws(SQLiteError) in
                .text(try writeJSON { try JSONWriter(options: .init(numberStyle: .preserved)).write(value) })
            },
            decode: { (stored) throws(CodecFailure) in
                switch stored {
                case .text(let bytes):
                    switch parsed(bytes) {
                    case .success(let value): return value
                    case .failure(let failure): throw CodecFailure(failure.reason)
                    }
                case .blob: throw CodecFailure("expected JSON TEXT, found a BLOB (JSONB written by SQL? select json(column))")
                case .null: throw CodecFailure("NULL in a non-optional JSON column")
                default: throw CodecFailure("expected JSON TEXT, found \(stored.kind.rawValue)")
                }
            })
    }

}

extension SQLiteCodec where Value: Codable & Sendable {
    /// A `Codable` value stored as JSON text through Swift-JSON's exact coding: numbers
    /// keep their exact value and SQLite's JSON functions work on the column.
    public static func json(_ type: Value.Type) -> SQLiteCodec<Value> {
        SQLiteCodec(
            storage: "TEXT (JSON, \(Value.self))",
            encode: { (value) throws(SQLiteError) in
                let json = try writeJSON { try JSONValueEncoder().encode(value) }
                return try SQLiteCodec<JSON>.jsonText.encode(json)
            },
            decode: { (stored) throws(CodecFailure) in
                guard case .text(let bytes) = stored else {
                    if case .null = stored { throw CodecFailure("NULL in a non-optional JSON column") }
                    throw CodecFailure("expected JSON TEXT, found \(stored.kind.rawValue)")
                }
                let json: JSON
                switch parsed(bytes) {
                case .success(let parsedValue): json = parsedValue
                case .failure(let failure): throw CodecFailure(failure.reason)
                }
                do {
                    return try JSONValueDecoder().decode(Value.self, from: json)
                } catch {
                    throw CodecFailure("JSON doesn't decode as \(Value.self): \(error)")
                }
            })
    }
}

private func writeJSON<T>(_ body: () throws -> T) throws(SQLiteError) -> T {
    do {
        return try body()
    } catch {
        throw .invalidArgument("the value can't be written as JSON: \(error)")
    }
}

private func writeJSON(_ body: () throws -> Data) throws(SQLiteError) -> [UInt8] {
    do {
        return Array(try body())
    } catch {
        throw .invalidArgument("the value can't be written as JSON: \(error)")
    }
}

/// The parsed value, or the reason it isn't valid JSON.
private func parsed(_ bytes: [UInt8]) -> Result<JSON, ParseFailure> {
    do {
        return .success(try JSON.parse(bytes))
    } catch {
        return .failure(ParseFailure(reason: "not valid JSON: \(error)"))
    }
}

private struct ParseFailure: Error {
    let reason: String
}
#endif
