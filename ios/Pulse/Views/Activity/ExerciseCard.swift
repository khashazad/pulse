import SwiftUI

/// An expandable card for one exercise: collapsed shows top set + volume,
/// expanded reveals the full ordered set list.
struct ExerciseCard: View {
    let exercise: WorkoutExercise
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.16)) { expanded.toggle() }
            } label: {
                header
            }
            .buttonStyle(.plain)
            if expanded {
                VStack(spacing: 6) {
                    ForEach(exercise.sets) { set in setRow(set) }
                }
                .padding(.top, 10)
            }
        }
        .padding(14)
        .ctpCard()
    }

    /// Collapsed/expanded header row: exercise title, top-set summary, volume, set count, and chevron.
    /// - Returns: An `HStack` summarizing the exercise for the collapsed card row.
    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(exercise.exerciseTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.FG.primary)
                if let top = exercise.topSet {
                    Text(Self.setSummary(top) + "  ·  top set")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.FG.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text("\(Int(exercise.volumeLbs.rounded())) lb")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.FG.primary)
                Text("\(exercise.setCount) sets")
                    .font(.system(size: 11)).foregroundStyle(Theme.FG.tertiary)
            }
            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.FG.tertiary)
                .padding(.leading, 4)
        }
    }

    /// One row in the expanded set list: index, optional set-type badge, summary, and optional RPE.
    /// - Parameter set: The individual set to render.
    /// - Returns: An `HStack` row representing a single set's metrics.
    private func setRow(_ set: WorkoutSet) -> some View {
        HStack {
            Text("\(set.setIndex + 1)")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.FG.tertiary)
                .frame(width: 22, alignment: .leading)
            if let tag = set.setType, tag != "normal" {
                Text(tag.capitalized)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.CTP.peach)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Theme.CTP.peach.opacity(0.16)))
            }
            Spacer()
            Text(Self.setSummary(set))
                .font(.system(size: 13)).foregroundStyle(Theme.FG.primary)
            if let rpe = set.rpe {
                Text("RPE \(rpe.clean)")
                    .font(.system(size: 11)).foregroundStyle(Theme.FG.tertiary)
                    .frame(width: 56, alignment: .trailing)
            }
        }
    }

    /// Renders a set as "weight × reps" (or distance/duration when no weight).
    /// - Parameter set: The set to summarize.
    /// - Returns: A short human string for the set's main metric.
    static func setSummary(_ set: WorkoutSet) -> String {
        if let w = set.weightLbs, let r = set.reps { return "\(w.clean) lb × \(r)" }
        if let d = set.distanceKm { return "\(d.clean) km" }
        if let s = set.durationSeconds { return "\(s / 60)m \(s % 60)s" }
        if let r = set.reps { return "\(r) reps" }
        return "—"
    }
}

