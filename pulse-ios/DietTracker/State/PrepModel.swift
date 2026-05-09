import Foundation
import Observation

@Observable
final class PrepModel {
    var selectedContainerId: UUID?
    var tareWeightG: Double = 0
    var totalGrams: Double?
    var portions: Int = 1

    var netGrams: Double? {
        guard let total = totalGrams else { return nil }
        return max(0, total - tareWeightG)
    }

    var perPortionGrams: Double? {
        guard let net = netGrams else { return nil }
        let p = max(1, portions)
        return net / Double(p)
    }
}
