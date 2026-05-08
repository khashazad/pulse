import Foundation

struct PeriodBucket: Identifiable, Hashable {
    let id: Int
    let label: String
    let avgKcalPerDay: Int
    let isCurrent: Bool
}
