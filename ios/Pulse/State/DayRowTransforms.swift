/// DayRowTransforms: pure helpers that fold a flat list of FoodEntry into the
/// renderable day-view shape, then split that into time-proximity clusters.
/// One pipeline in two steps: `groupDayEntries` buckets entries by group id and
/// merges repeated saved-meal instances into `DayRow`s; `clusterByProximity`
/// then folds those rows into `DayCluster`s, starting a new cluster whenever the
/// gap between consecutive rows exceeds `DayProximity.gap`.
/// Role: shared logic used by the Intake day view; no view or network deps.
import Foundation

// MARK: - Grouping

/// One renderable row in the day view: either a single entry or an aggregated meal group.
enum DayRow: Identifiable {
    case single(FoodEntry)
    case meal(MealGroup)

    var id: String {
        switch self {
        case .single(let e): return "single:\(e.id.uuidString)"
        case .meal(let g):   return g.id
        }
    }

    var sortDate: Date {
        switch self {
        case .single(let e): return e.consumedAt
        case .meal(let g):   return g.sortDate
        }
    }
}

/// Aggregated representation of one or more saved-meal instances grouped under a shared mealId.
struct MealGroup: Identifiable {
    let id: String
    let mealId: UUID?
    let displayName: String
    let count: Int
    let items: [FoodEntry]
    let totals: MacroTotals
    let sortDate: Date
}

/// Buckets entries by `entryGroupId`, classifies single vs. meal instances, then merges
/// meal instances sharing the same `mealId` into one row. Returns a stably sorted list.
/// Inputs:
///   - entries: raw food entries for a single day, in arrival order.
/// Outputs: ordered `DayRow` array ready for SwiftUI rendering.
func groupDayEntries(_ entries: [FoodEntry]) -> [DayRow] {
    // 1. Bucket entries by entry_group_id, preserving stable arrival order within each bucket.
    var bucketOrder: [UUID] = []
    var buckets: [UUID: [FoodEntry]] = [:]
    for entry in entries {
        if buckets[entry.entryGroupId] == nil {
            bucketOrder.append(entry.entryGroupId)
        }
        buckets[entry.entryGroupId, default: []].append(entry)
    }

    // 2. First pass: classify each bucket.
    enum Classified {
        case single(FoodEntry)
        case mealInstance(items: [FoodEntry], mealId: UUID?, mealName: String?, time: Date, entryGroupId: UUID)
    }

    var classified: [Classified] = []
    for groupId in bucketOrder {
        let items = buckets[groupId] ?? []
        if items.count == 1 {
            classified.append(.single(items[0]))
        } else {
            let time = items.map(\.consumedAt).max() ?? .distantPast
            // mealId / mealName are taken from the first item; all items in a log_meal call share them.
            let mealId = items.first?.mealId
            let mealName = items.first?.mealName
            classified.append(.mealInstance(items: items, mealId: mealId, mealName: mealName, time: time, entryGroupId: groupId))
        }
    }

    // 3. Merge meal instances by mealId (only when non-nil); nil-mealId instances stay separate.
    var rows: [DayRow] = []
    var mergedByMealId: [UUID: (groupIndex: Int, MealGroup)] = [:]

    for c in classified {
        switch c {
        case .single(let e):
            rows.append(.single(e))
        case .mealInstance(let items, let mealId, let mealName, let time, let entryGroupId):
            let totals = MacroTotals(
                calories: items.reduce(0) { $0 + $1.calories },
                proteinG: items.reduce(0.0) { $0 + $1.proteinG },
                carbsG: items.reduce(0.0) { $0 + $1.carbsG },
                fatG: items.reduce(0.0) { $0 + $1.fatG }
            )
            if let mealId, let existing = mergedByMealId[mealId] {
                let prev = existing.1
                let useNewItems = time >= prev.sortDate
                // Pin displayName to the same instance that wins for items; fall back to the
                // other instance's name (or "Meal") when the chosen instance has no name.
                let newCandidate: String? = (mealName?.isEmpty == false) ? mealName : nil
                let prevCandidate: String? = prev.displayName == "Meal" ? nil : prev.displayName
                let mergedDisplayName = useNewItems
                    ? (newCandidate ?? prevCandidate ?? "Meal")
                    : (prevCandidate ?? newCandidate ?? "Meal")
                let merged = MealGroup(
                    id: prev.id,
                    mealId: prev.mealId,
                    displayName: mergedDisplayName,
                    count: prev.count + 1,
                    items: useNewItems ? items : prev.items,
                    totals: MacroTotals(
                        calories: prev.totals.calories + totals.calories,
                        proteinG: prev.totals.proteinG + totals.proteinG,
                        carbsG: prev.totals.carbsG + totals.carbsG,
                        fatG: prev.totals.fatG + totals.fatG
                    ),
                    sortDate: max(prev.sortDate, time)
                )
                rows[existing.groupIndex] = .meal(merged)
                mergedByMealId[mealId] = (existing.groupIndex, merged)
            } else {
                let group = MealGroup(
                    id: mealId.map { "meal:\($0.uuidString)" } ?? "anon:\(entryGroupId.uuidString)",
                    mealId: mealId,
                    displayName: (mealName?.isEmpty == false ? mealName! : "Meal"),
                    count: 1,
                    items: items,
                    totals: totals,
                    sortDate: time
                )
                rows.append(.meal(group))
                if let mealId {
                    mergedByMealId[mealId] = (rows.count - 1, group)
                }
            }
        }
    }

    // 4. Stable sort by representative time. `Array.sorted(by:)` is stable in Swift 5.0+.
    return rows.sorted { lhs, rhs in
        if lhs.sortDate == rhs.sortDate { return false }  // preserve insertion order on ties
        return lhs.sortDate < rhs.sortDate
    }
}

// MARK: - Proximity clustering

/// Tunables for day-view proximity clustering.
enum DayProximity {
    /// Maximum gap between two consecutive entries' `consumedAt` times before a
    /// new cluster begins. 45 minutes sits comfortably between intra-occasion
    /// logging bursts (seconds-to-minutes apart) and the hours-long gaps between
    /// distinct meals.
    static let gap: TimeInterval = 45 * 60
}

/// A run of consecutive day rows logged close together in time.
struct DayCluster: Identifiable {
    /// Stable id derived from the first row, so SwiftUI diffing is well-behaved.
    let id: String
    /// The rows in this cluster, in their original chronological order.
    let rows: [DayRow]
}

/// Splits chronologically-ordered day rows into proximity clusters: a new cluster
/// starts whenever the gap between a row and the row before it exceeds `gap`.
/// Inputs:
///   - rows: the day's rows, already sorted ascending by representative time
///     (as produced by `groupDayEntries`).
///   - gap: maximum allowed gap between consecutive rows within one cluster, in
///     seconds. Defaults to `DayProximity.gap`.
/// Outputs: clusters in chronological order; empty when `rows` is empty. Every
/// returned cluster is non-empty.
func clusterByProximity(_ rows: [DayRow], gap: TimeInterval = DayProximity.gap) -> [DayCluster] {
    guard let first = rows.first else { return [] }

    var clusters: [DayCluster] = []
    var current: [DayRow] = [first]
    var previousDate = first.sortDate

    for row in rows.dropFirst() {
        if row.sortDate.timeIntervalSince(previousDate) > gap {
            clusters.append(DayCluster(id: current[0].id, rows: current))
            current = [row]
        } else {
            current.append(row)
        }
        previousDate = row.sortDate
    }
    clusters.append(DayCluster(id: current[0].id, rows: current))
    return clusters
}
