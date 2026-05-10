import Foundation

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

struct MealGroup: Identifiable {
    let id: String
    let mealId: UUID?
    let displayName: String
    let count: Int
    let items: [FoodEntry]
    let totals: MacroTotals
    let sortDate: Date
}

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
                let merged = MealGroup(
                    id: prev.id,
                    mealId: prev.mealId,
                    displayName: prev.displayName,
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
