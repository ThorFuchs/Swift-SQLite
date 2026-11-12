// SPDX-License-Identifier: Apache-2.0

/// A table or column name that helpers quote safely into SQL.
///
/// The name is wrapped in double quotes, with embedded double quotes doubled, so it
/// can't inject SQL. Names that are empty or contain NUL are refused with
/// ``SQLiteError/Code/invalidArgument`` when used.
public struct SQLiteIdentifier: Sendable, Hashable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let name: String

    public init(_ name: String) {
        self.name = name
    }

    public init(stringLiteral value: String) {
        self.name = value
    }

    public var description: String { name }

    /// The quoted form, for example `"my ""table"""`.
    public func quoted() throws(SQLiteError) -> String {
        guard !name.isEmpty, !name.utf8.contains(0) else {
            throw .invalidArgument("identifier must be non-empty and contain no NUL")
        }
        var result = "\""
        for character in name {
            if character == "\"" { result += "\"\"" } else { result.append(character) }
        }
        result += "\""
        return result
    }
}
