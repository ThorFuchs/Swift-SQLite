// SPDX-License-Identifier: Apache-2.0

#if os(Linux)
internal import CSQLiteSwift
#else
internal import SQLite3
#endif

/// `PRAGMA auto_vacuum`. SQLite has exactly these three modes.
public enum SQLiteAutoVacuum: Int, Sendable, Hashable, CustomStringConvertible {
    case none = 0
    case full = 1
    case incremental = 2

    public var description: String {
        switch self {
        case .none: "NONE"
        case .full: "FULL"
        case .incremental: "INCREMENTAL"
        }
    }
}

/// Marks a database file as belonging to your application and checks the mark on
/// every open.
///
/// Set it as ``SQLiteConfiguration/fileIdentity``.
/// - **New file:** SQLiteSwift sets `page_size` and `auto_vacuum` (if given) and
///   `application_id` before anything else is written, then reads them back.
/// - **Existing file:** each value is compared and never rewritten. A mismatch
///   throws ``SQLiteError/Code/fileIdentityMismatch`` before anything is written,
///   so opening the wrong file can't damage it.
///
/// The schema version stays with migrations (`user_version`); the identity says
/// *which* file it is, migrations say *which version* of it.
public struct SQLiteFileIdentity: Sendable, Hashable {
    /// `PRAGMA application_id`, stored at offset 68 of the file header. Pick a value
    /// unique to your file format (for example four ASCII bytes); must not be 0.
    public var applicationID: Int32
    /// `PRAGMA page_size` for new files (a power of two in 512...65536), or `nil` for
    /// SQLite's default. Checked on existing files when set.
    public var pageSize: Int?
    /// `PRAGMA auto_vacuum` for new files, or `nil` for SQLite's default (`NONE`).
    /// Checked on existing files when set.
    public var autoVacuum: SQLiteAutoVacuum?
    /// Whether an existing file with `application_id` 0 (for example one created
    /// before you adopted an identity) is marked instead of refused. Default `false`.
    public var adoptsUnmarkedFiles: Bool

    public init(
        applicationID: Int32,
        pageSize: Int? = nil,
        autoVacuum: SQLiteAutoVacuum? = nil,
        adoptsUnmarkedFiles: Bool = false
    ) {
        self.applicationID = applicationID
        self.pageSize = pageSize
        self.autoVacuum = autoVacuum
        self.adoptsUnmarkedFiles = adoptsUnmarkedFiles
    }

    func validate() throws(SQLiteError) {
        guard applicationID != 0 else {
            throw .invalidConfiguration("fileIdentity.applicationID must not be 0")
        }
        if let pageSize {
            guard (512...65536).contains(pageSize), pageSize & (pageSize - 1) == 0 else {
                throw .invalidConfiguration("fileIdentity.pageSize must be a power of two in 512...65536")
            }
        }
    }

    static func hex(_ value: Int64) -> String {
        "0x" + String(UInt32(truncatingIfNeeded: value), radix: 16, uppercase: true)
    }
}

/// What opening must do about the file identity.
enum SQLiteFileIdentityPlan {
    case nothing
    case create(SQLiteFileIdentity)
    case adopt(SQLiteFileIdentity)
}

extension SQLiteConnectionCore {
    func integerPragma(_ name: String) throws(SQLiteError) -> Int64 {
        guard case .integer(let value) = try scalarInternal("PRAGMA \(name)") else { return 0 }
        return value
    }

    /// Checks the identity of an existing file without writing anything.
    func inspectFileIdentity() throws(SQLiteError) -> SQLiteFileIdentityPlan {
        guard let identity = configuration.fileIdentity else { return .nothing }
        if try integerPragma("page_count") == 0 {
            return .create(identity)
        }
        let actualID = try integerPragma("application_id")
        var plan = SQLiteFileIdentityPlan.nothing
        if actualID != Int64(identity.applicationID) {
            guard actualID == 0, identity.adoptsUnmarkedFiles else {
                throw .fileIdentityMismatch(
                    setting: "application_id",
                    expected: SQLiteFileIdentity.hex(Int64(identity.applicationID)),
                    actual: SQLiteFileIdentity.hex(actualID))
            }
            plan = .adopt(identity)
        }
        try checkStructure(identity, mismatch: SQLiteError.fileIdentityMismatch)
        return plan
    }

    /// Writes the identity of a new file (or marks an adopted one) and reads it back.
    func applyFileIdentity(_ plan: SQLiteFileIdentityPlan) throws(SQLiteError) {
        switch plan {
        case .nothing:
            return
        case .create(let identity):
            if let pageSize = identity.pageSize { try execInternal("PRAGMA page_size = \(pageSize)") }
            if let autoVacuum = identity.autoVacuum { try execInternal("PRAGMA auto_vacuum = \(autoVacuum)") }
            try execInternal("PRAGMA application_id = \(identity.applicationID)")
            try checkStructure(identity, mismatch: SQLiteError.settingMismatch)
            try verifyPragma("application_id", expected: .integer(Int64(identity.applicationID)))
        case .adopt(let identity):
            try execInternal("PRAGMA application_id = \(identity.applicationID)")
            try verifyPragma("application_id", expected: .integer(Int64(identity.applicationID)))
        }
    }

    private func checkStructure(
        _ identity: SQLiteFileIdentity,
        mismatch: (String, String, String) -> SQLiteError
    ) throws(SQLiteError) {
        if let pageSize = identity.pageSize {
            let actual = try integerPragma("page_size")
            guard actual == pageSize else { throw mismatch("page_size", String(pageSize), String(actual)) }
        }
        if let autoVacuum = identity.autoVacuum {
            let actual = try integerPragma("auto_vacuum")
            guard actual == autoVacuum.rawValue else {
                let name = SQLiteAutoVacuum(rawValue: Int(actual))?.description ?? String(actual)
                throw mismatch("auto_vacuum", autoVacuum.description, name)
            }
        }
    }
}
