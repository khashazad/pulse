// Pulse/State/FoodTabFilter.swift
/// Pure, UI-free name filtering for the Food tab's shared search field. Applied
/// to whichever section (meals or custom foods) is active. A blank query returns
/// the full list sorted by name; a non-blank query keeps case-insensitive
/// substring matches, also name-sorted. Kept here so it unit-tests without
/// rendering.
import Foundation

/// Namespace for the Food tab's section filters.
enum FoodTabFilter {
    /// The single source of truth for the tab's name-match rule: a blank (after
    /// trimming) query matches everything; otherwise a locale-aware,
    /// case-insensitive substring match.
    /// Inputs:
    ///   - name: the candidate display name.
    ///   - query: raw search text (may be blank or whitespace).
    /// Outputs: `true` when the name passes the active query.
    static func matches(_ name: String, query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return q.isEmpty || name.localizedCaseInsensitiveContains(q)
    }

    /// Filters meal summaries by name.
    /// Inputs:
    ///   - meals: the loaded meal summaries.
    ///   - query: raw search text (may be blank or whitespace).
    /// Outputs: name-sorted matches; the full list when the query is blank.
    static func meals(_ meals: [MealSummary], query: String) -> [MealSummary] {
        filtered(meals, query: query, name: \.name)
    }

    /// Filters custom foods by name.
    /// Inputs:
    ///   - foods: the loaded custom foods.
    ///   - query: raw search text (may be blank or whitespace).
    /// Outputs: name-sorted matches; the full list when the query is blank.
    static func foods(_ foods: [CustomFood], query: String) -> [CustomFood] {
        filtered(foods, query: query, name: \.name)
    }

    /// Shared filter+sort over any element exposing a name key path.
    /// Inputs:
    ///   - items: the elements to filter.
    ///   - query: raw search text.
    ///   - name: key path to the element's display name.
    /// Outputs: name-sorted matches (locale-aware, case-insensitive); the full
    ///   sorted list when the trimmed query is empty.
    private static func filtered<T>(_ items: [T], query: String, name: KeyPath<T, String>) -> [T] {
        let matched = items.filter { matches($0[keyPath: name], query: query) }
        return matched.sorted { $0[keyPath: name].localizedCaseInsensitiveCompare($1[keyPath: name]) == .orderedAscending }
    }
}
