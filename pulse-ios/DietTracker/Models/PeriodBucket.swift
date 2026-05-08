import Foundation

struct PeriodBucket: Identifiable, Hashable {
    let id: String
    let label: String
    let avgKcalPerDay: Int
    let isCurrent: Bool
}
