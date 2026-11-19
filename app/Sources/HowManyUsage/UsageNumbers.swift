import Foundation
import CoreFoundation

/// Untrusted API/log numbers must not reach trapping integer conversions or geometry.
enum UsageNumbers {
    static func finite(_ value: Any?) -> Double? {
        let result: Double?
        if let number = value as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            result = number.doubleValue
        } else if let string = value as? String {
            result = Double(string)
        } else { return nil }
        return result.flatMap { $0.isFinite ? $0 : nil }
    }

    static func integer(_ value: Any?) -> Int? {
        if let string = value as? String { return Int(string) }
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
        // Conditional bridging checks representability; intValue would truncate/wrap.
        return number as? Int
    }

    static func count(_ value: Any?) -> Int { max(0, integer(value) ?? 0) }

    /// Counts are nonnegative. An unrepresentable aggregate saturates, never wraps.
    static func sum(_ counts: Int...) -> Int {
        counts.reduce(0) { total, count in
            let (next, overflow) = total.addingReportingOverflow(max(0, count))
            return overflow ? Int.max : next
        }
    }

    static func percent(_ value: Double?) -> Double? {
        value.flatMap { $0.isFinite && (0...100).contains($0) ? $0 : nil }
    }

    static func date(epoch: Double) -> Date? {
        guard epoch.isFinite,
              (Date.distantPast.timeIntervalSince1970...Date.distantFuture.timeIntervalSince1970).contains(epoch) else { return nil }
        return Date(timeIntervalSince1970: epoch)
    }

    static func wholeText(_ value: Double, rounding: FloatingPointRoundingRule = .toNearestOrAwayFromZero) -> String {
        guard value.isFinite, let number = Int(exactly: value.rounded(rounding)) else { return "—" }
        return String(number)
    }
}
