import Foundation
import CoreFoundation

/// A display preference only. Platform expiry still determines whether a historical SC is eligible.
struct SCLifetimePolicy: Equatable {
    enum Mode: String { case official, tiers, uniform }
    static let amounts = [30, 50, 100, 500, 1000, 2000]
    var mode: Mode = .official
    var uniformSeconds = 60
    var tiers = [Int: Int]()

    init(_ value: Any? = nil) {
        guard let object = value as? JSON else { return }
        mode = Mode(rawValue: object.str("mode")) ?? .official
        uniformSeconds = Self.seconds(object["uniformSeconds"]) ?? 60
        let configured = object.obj("tiers")
        for amount in Self.amounts {
            if let seconds = Self.seconds(configured[String(amount)]) { tiers[amount] = seconds }
        }
    }

    private static func seconds(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let seconds = number.doubleValue
        guard seconds.isFinite, seconds.rounded(.towardZero) == seconds, (1...7200).contains(seconds) else { return nil }
        return Int(seconds)
    }

    func lifetime(price: Int, officialRemaining: Double, officialTotal: Double) -> (duration: Double, totalDuration: Double)? {
        guard officialRemaining.isFinite, officialTotal.isFinite else { return nil }
        let total = min(7200, max(1, officialTotal))
        let remaining = min(total, max(0, officialRemaining))
        guard remaining > 0 else { return nil }
        let custom: Int?
        switch mode {
        case .official: custom = nil
        case .uniform: custom = uniformSeconds
        case .tiers: custom = Self.amounts.last(where: { price >= $0 }).flatMap { tiers[$0] }
        }
        guard let custom else { return (remaining, total) }
        let adjusted = Double(custom) - (total - remaining)
        guard adjusted > 0 else { return nil }
        return (adjusted, Double(custom))
    }
}
