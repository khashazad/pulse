// Pulse/State/FoodDuplicateGrouper.swift
/// Pure grouping-candidate finder. Clusters standalone custom foods whose names
/// share a stem once size/quantity words are stripped, so the grouping flow can
/// hint "these look like portions of one food". Stem = the remaining content
/// tokens, order-independent; clusters of size >= 2 are returned, each preserving
/// input order.
import Foundation

enum FoodDuplicateGrouper {
    /// Size/quantity tokens that distinguish portions of the same food and so are
    /// excluded from the stem key.
    private static let sizeWords: Set<String> = [
        "small", "medium", "large", "xl", "mini", "regular", "big",
        "per", "100g", "g", "kg", "oz", "ml", "l", "cup", "cups", "serving",
        "slice", "slices", "piece", "pieces", "half", "whole", "a", "an",
    ]

    /// Clusters foods by their size-stripped stem.
    /// Inputs:
    ///   - foods: the standalone custom foods to consider.
    /// Outputs: clusters (each >= 2 foods) sharing a non-empty stem, in first-seen
    ///   stem order; foods with an empty stem after stripping are never clustered.
    static func clusters(from foods: [CustomFood]) -> [[CustomFood]] {
        var order: [String] = []
        var buckets: [String: [CustomFood]] = [:]
        for food in foods {
            let key = stem(food.name)
            guard !key.isEmpty else { continue }
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(food)
        }
        return order.compactMap { key in
            let bucket = buckets[key] ?? []
            return bucket.count >= 2 ? bucket : nil
        }
    }

    /// Computes the order-independent stem key for a name.
    /// Inputs:
    ///   - name: the food name.
    /// Outputs: sorted, space-joined content tokens with size words and pure
    ///   numbers removed; "" when nothing remains.
    private static func stem(_ name: String) -> String {
        let tokens = name.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !sizeWords.contains($0) && !$0.allSatisfy(\.isNumber) }
        return tokens.sorted().joined(separator: " ")
    }
}
