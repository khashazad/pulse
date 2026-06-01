/// DayProximityClustering: pure helper that folds the day's already-grouped rows
/// into time-proximity clusters.
/// A cluster is a run of consecutive `DayRow`s whose `consumedAt` times sit close
/// together — i.e. a single eating/logging occasion. Splitting the day this way
/// lets the UI render each occasion as its own card so mis-logged items (an entry
/// stamped at the wrong time, an accidental duplicate) stand out as their own
/// lonely cluster.
/// Role: shared logic used by the Intake day view; no view or network deps.
import Foundation

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
