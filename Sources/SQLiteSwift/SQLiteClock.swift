// SPDX-License-Identifier: Apache-2.0

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// A point in time stored as integer milliseconds since 1970-01-01T00:00:00Z.
///
/// Store it in an `INTEGER` column; comparisons in SQL then match comparisons here.
public struct SQLiteTimestamp: Sendable, Hashable, Comparable, CustomStringConvertible {
    public var millisecondsSince1970: Int64

    public init(millisecondsSince1970: Int64) {
        self.millisecondsSince1970 = millisecondsSince1970
    }

    public static func < (lhs: SQLiteTimestamp, rhs: SQLiteTimestamp) -> Bool {
        lhs.millisecondsSince1970 < rhs.millisecondsSince1970
    }

    /// This timestamp moved by `duration`, truncated to whole milliseconds and
    /// saturating at the `Int64` range.
    public func advanced(by duration: Duration) -> SQLiteTimestamp {
        let (seconds, attoseconds) = duration.components
        let (secondsMS, overflow1) = seconds.multipliedReportingOverflow(by: 1000)
        let millis = attoseconds / 1_000_000_000_000_000
        let (delta, overflow2) = secondsMS.addingReportingOverflow(millis)
        let (sum, overflow3) = millisecondsSince1970.addingReportingOverflow(delta)
        if overflow1 || overflow2 || overflow3 {
            return SQLiteTimestamp(millisecondsSince1970: seconds < 0 ? .min : .max)
        }
        return SQLiteTimestamp(millisecondsSince1970: sum)
    }

    /// The value to bind for this timestamp.
    public var sqliteValue: SQLiteValue { .integer(millisecondsSince1970) }

    public var description: String { "\(millisecondsSince1970) ms since 1970" }
}

/// A source of the current time for expiry helpers.
///
/// SQLiteSwift never reads the wall clock in its expiry helpers; they ask the clock
/// in ``SQLiteConfiguration/clock``. Tests inject a manual clock
/// (`SQLiteManualClock` in SQLiteSwiftTesting).
public protocol SQLiteClock: Sendable {
    /// The current time.
    func now() -> SQLiteTimestamp
}

/// The system wall clock (`CLOCK_REALTIME`).
public struct SQLiteSystemClock: SQLiteClock {
    public init() {}

    public func now() -> SQLiteTimestamp {
        var spec = timespec()
        clock_gettime(CLOCK_REALTIME, &spec)
        return SQLiteTimestamp(
            millisecondsSince1970: Int64(spec.tv_sec) * 1000 + Int64(spec.tv_nsec) / 1_000_000
        )
    }
}
