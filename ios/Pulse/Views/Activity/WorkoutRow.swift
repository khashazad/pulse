import SwiftUI

/// One workout row in the feed: type dot, name + date, duration / set count, trailing calories.
struct WorkoutRow: View {
    let workout: ActivityWorkoutSummary

    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(ActivityGroup.of(workout.activityType).color).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 3) {
                Text(ActivityGroup.of(workout.activityType).displayName.uppercased())
                    .font(.system(size: 9, weight: .semibold)).tracking(0.6)
                    .foregroundStyle(ActivityGroup.of(workout.activityType).color)
                Text(ActivityType.displayName(workout.activityType))
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.FG.primary)
                Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.FG.secondary)
            }
            Spacer()
            if let cal = workout.activeEnergyCal {
                Text("\(Int(cal.rounded())) kcal")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.FG.secondary)
            }
        }
        .padding(.vertical, 10).padding(.horizontal, 14).ctpCard()
    }

    /// Subtitle line: date, duration, and set count or distance when available.
    /// - Returns: A dot-separated summary string for secondary text.
    private var subtitle: String {
        var parts: [String] = [workout.startTime.formatted(date: .abbreviated, time: .shortened)]
        if let m = workout.durationMin { parts.append("\(Int(m.rounded())) min") }
        if let b = workout.strengthBrief {
            parts.append("\(b.setCount) sets")
        } else if let d = workout.distanceKm {
            parts.append("\(d.clean) km")
        }
        return parts.joined(separator: " · ")
    }
}
