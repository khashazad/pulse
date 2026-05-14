import Foundation

enum WeightFormatter {
    static let kgToLb: Double = 2.20462262

    static func toLb(_ value: Double, from unit: WeightUnit) -> Double {
        switch unit {
        case .lb: return value
        case .kg: return value * kgToLb
        }
    }

    static func fromLb(_ lb: Double, to unit: WeightUnit) -> Double {
        switch unit {
        case .lb: return lb
        case .kg: return lb / kgToLb
        }
    }

    static func display(lb: Double, in unit: WeightUnit) -> String {
        let value = fromLb(lb, to: unit)
        return String(format: "%.1f %@", value, unit.rawValue)
    }
}
