import Foundation

/// Trend period granularity for the activity summary endpoint.
enum ActivityPeriod: String, CaseIterable, Identifiable, Hashable {
    case week, month, year
    var id: String { rawValue }
    /// Human label for the period selector segment.
    var label: String {
        switch self {
        case .week: "Week"
        case .month: "Month"
        case .year: "Year"
        }
    }
}

/// Compact lifting rollup shown on a feed row for a linked strength workout.
struct StrengthBrief: Codable, Hashable {
    let exerciseCount: Int
    let setCount: Int
    let volumeLbs: Double
    enum CodingKeys: String, CodingKey {
        case exerciseCount = "exercise_count"
        case setCount = "set_count"
        case volumeLbs = "volume_lbs"
    }
}

/// One workout as it appears in the chronological feed.
struct ActivityWorkoutSummary: Codable, Identifiable, Hashable {
    let id: UUID
    let activityType: String
    let startTime: Date
    let endTime: Date
    let durationMin: Double?
    let activeEnergyCal: Double?
    let distanceKm: Double?
    let hasStrengthDetail: Bool
    let strengthBrief: StrengthBrief?
    enum CodingKeys: String, CodingKey {
        case id
        case activityType = "activity_type"
        case startTime = "start_time"
        case endTime = "end_time"
        case durationMin = "duration_min"
        case activeEnergyCal = "active_energy_cal"
        case distanceKm = "distance_km"
        case hasStrengthDetail = "has_strength_detail"
        case strengthBrief = "strength_brief"
    }
}

/// A page of feed workouts plus the opaque composite cursor for the next (older) page.
/// `nextBefore` / `nextBeforeId` are kept as raw strings and echoed verbatim to the
/// server, so the `(start_time, id)` cursor round-trips without precision loss.
struct WorkoutFeedPage: Codable, Hashable {
    let items: [ActivityWorkoutSummary]
    let nextBefore: String?
    let nextBeforeId: String?
    enum CodingKeys: String, CodingKey {
        case items
        case nextBefore = "next_before"
        case nextBeforeId = "next_before_id"
    }
}

/// A single Hevy set within an exercise.
struct WorkoutSet: Codable, Identifiable, Hashable {
    let setIndex: Int
    let setType: String?
    let weightLbs: Double?
    let reps: Int?
    let rpe: Double?
    let distanceKm: Double?
    let durationSeconds: Int?
    var id: Int { setIndex }
    enum CodingKeys: String, CodingKey {
        case setIndex = "set_index"
        case setType = "set_type"
        case weightLbs = "weight_lbs"
        case reps
        case rpe
        case distanceKm = "distance_km"
        case durationSeconds = "duration_seconds"
    }
}

/// One exercise: its sets, set count, total volume, and top set by est-1RM.
struct WorkoutExercise: Codable, Identifiable, Hashable {
    let exerciseTitle: String
    let supersetId: String?
    let setCount: Int
    let volumeLbs: Double
    let topSet: WorkoutSet?
    let sets: [WorkoutSet]
    var id: String { exerciseTitle }
    enum CodingKeys: String, CodingKey {
        case exerciseTitle = "exercise_title"
        case supersetId = "superset_id"
        case setCount = "set_count"
        case volumeLbs = "volume_lbs"
        case topSet = "top_set"
        case sets
    }
}

/// Workout-level lifting totals shown in the detail strength header.
struct StrengthTotals: Codable, Hashable {
    let exerciseCount: Int
    let setCount: Int
    let volumeLbs: Double
    enum CodingKeys: String, CodingKey {
        case exerciseCount = "exercise_count"
        case setCount = "set_count"
        case volumeLbs = "volume_lbs"
    }
}

/// Full workout detail: Apple stats plus linked Hevy exercises when present.
struct ActivityWorkoutDetail: Codable, Identifiable, Hashable {
    let id: UUID
    let activityType: String
    let startTime: Date
    let endTime: Date
    let durationMin: Double?
    let activeEnergyCal: Double?
    let basalEnergyCal: Double?
    let avgHeartRate: Double?
    let maxHeartRate: Double?
    let distanceKm: Double?
    let elevationAscendedM: Double?
    let stepCount: Int?
    let flightsClimbed: Int?
    let avgMets: Double?
    let indoor: Bool?
    let exercises: [WorkoutExercise]
    let strengthTotals: StrengthTotals?
    enum CodingKeys: String, CodingKey {
        case id
        case activityType = "activity_type"
        case startTime = "start_time"
        case endTime = "end_time"
        case durationMin = "duration_min"
        case activeEnergyCal = "active_energy_cal"
        case basalEnergyCal = "basal_energy_cal"
        case avgHeartRate = "avg_heart_rate"
        case maxHeartRate = "max_heart_rate"
        case distanceKm = "distance_km"
        case elevationAscendedM = "elevation_ascended_m"
        case stepCount = "step_count"
        case flightsClimbed = "flights_climbed"
        case avgMets = "avg_mets"
        case indoor
        case exercises
        case strengthTotals = "strength_totals"
    }
}

/// A metric's current value, the prior period's value, and percent change.
struct MetricDelta: Codable, Hashable {
    let current: Double
    let previous: Double
    let pct: Double?
}

/// Headline totals for a trend period.
struct ActivityTotals: Codable, Hashable {
    let workoutCount: Int
    let totalDurationMin: Double
    let totalActiveEnergyCal: Double
    enum CodingKeys: String, CodingKey {
        case workoutCount = "workout_count"
        case totalDurationMin = "total_duration_min"
        case totalActiveEnergyCal = "total_active_energy_cal"
    }
}

/// Period-over-period deltas for the three headline totals.
struct ActivityDeltas: Codable, Hashable {
    let workoutCount: MetricDelta
    let totalDurationMin: MetricDelta
    let totalActiveEnergyCal: MetricDelta
    enum CodingKeys: String, CodingKey {
        case workoutCount = "workout_count"
        case totalDurationMin = "total_duration_min"
        case totalActiveEnergyCal = "total_active_energy_cal"
    }
}

/// One slice of the by-type breakdown (duration share of the period).
struct TypeBreakdown: Codable, Identifiable, Hashable {
    let activityType: String
    let count: Int
    let durationMin: Double
    let share: Double
    var id: String { activityType }
    enum CodingKeys: String, CodingKey {
        case activityType = "activity_type"
        case count
        case durationMin = "duration_min"
        case share
    }
}

/// Weekly rollup for the period breakdown shown on the Month Trends screen.
/// Populated by the server only when `period == "month"`.
struct WeekRollup: Codable, Identifiable, Hashable {
    let weekStart: Date
    let weekEnd: Date
    let sessionCount: Int
    let durationMin: Double
    let byType: [TypeBreakdown]

    /// Stable identity for `ForEach`/`Identifiable`; mirrors `weekStart`.
    /// - Returns: The `weekStart` date.
    var id: Date { weekStart }

    enum CodingKeys: String, CodingKey {
        case weekStart = "week_start"
        case weekEnd = "week_end"
        case sessionCount = "session_count"
        case durationMin = "duration_min"
        case byType = "by_type"
    }
}

/// Monthly rollup for the period breakdown shown on the Year Trends screen.
/// Populated by the server only when `period == "year"`.
struct MonthRollup: Codable, Identifiable, Hashable {
    let monthStart: Date
    let sessionCount: Int
    let durationMin: Double

    /// Stable identity for `ForEach`/`Identifiable`; mirrors `monthStart`.
    /// - Returns: The `monthStart` date.
    var id: Date { monthStart }

    enum CodingKeys: String, CodingKey {
        case monthStart = "month_start"
        case sessionCount = "session_count"
        case durationMin = "duration_min"
    }
}

/// One calendar day's workouts within a `WeekDetail` response.
struct DayGroup: Codable, Identifiable, Hashable {
    let date: Date
    let workouts: [ActivityWorkoutSummary]

    /// Stable identity for `ForEach`/`Identifiable`; mirrors the day's date.
    /// - Returns: The `date` value.
    var id: Date { date }
}

/// Full week detail returned by `GET /activity/week`.
/// Contains each day that had at least one workout, with the workouts for that day.
struct WeekDetail: Codable, Hashable {
    let weekStart: Date
    let weekEnd: Date
    let dayGroups: [DayGroup]

    enum CodingKeys: String, CodingKey {
        case weekStart = "week_start"
        case weekEnd = "week_end"
        case dayGroups = "day_groups"
    }
}

/// Strength volume + workout time for one sub-bucket of the period.
struct VolumeBucket: Codable, Identifiable, Hashable {
    let bucketStart: Date
    let volumeLbs: Double
    let durationMin: Double
    var id: Date { bucketStart }
    enum CodingKeys: String, CodingKey {
        case bucketStart = "bucket_start"
        case volumeLbs = "volume_lbs"
        case durationMin = "duration_min"
    }
}

/// A lift's best estimated 1RM in the period, flagged when it's an all-time PR.
struct TopLift: Codable, Identifiable, Hashable {
    let exerciseTitle: String
    let bestEst1rm: Double
    let bestWeightLbs: Double
    let bestReps: Int
    let date: Date
    let isPr: Bool
    var id: String { exerciseTitle }
    enum CodingKeys: String, CodingKey {
        case exerciseTitle = "exercise_title"
        case bestEst1rm = "best_est_1rm"
        case bestWeightLbs = "best_weight_lbs"
        case bestReps = "best_reps"
        case date
        case isPr = "is_pr"
    }
}

/// One activity type's cardio classification, count, and display name.
/// Used both in the `GET /activity/types` list response and as the return
/// value of `PUT /activity/types/{activity_type}`.
struct ActivityTypeSetting: Codable, Identifiable, Hashable {
    /// The raw activity type string as stored in `apple_workouts.activity_type`.
    let activityType: String
    /// Human-readable label for the type (e.g. "Traditional Strength Training").
    let displayName: String
    /// Total number of imported workouts with this activity type.
    let count: Int
    /// Whether this type is classified as cardio for summary grouping.
    let isCardio: Bool

    /// Stable identity for `ForEach`/`Identifiable`; mirrors `activityType`.
    /// - Returns: The raw `activityType` string.
    var id: String { activityType }

    enum CodingKeys: String, CodingKey {
        case activityType = "activity_type"
        case displayName = "display_name"
        case count
        case isCardio = "is_cardio"
    }
}

/// Envelope returned by `GET /activity/types`.
struct ActivityTypesResponse: Codable {
    /// All activity types found in the imported workouts, with their
    /// current `is_cardio` setting and workout count.
    let types: [ActivityTypeSetting]
}

/// Week/month/year trend summary powering the Trends screen and feed strip.
/// `byType` replaces the former `byGroup` — both strength types collapse into
/// a single entry with `activityType == "Weights"`.
/// `weeks` is populated only when `period == "month"`.
/// `months` is populated only when `period == "year"`.
struct ActivitySummary: Codable, Hashable {
    let period: String
    let periodStart: Date
    let periodEnd: Date
    let totals: ActivityTotals
    let deltas: ActivityDeltas
    let byType: [TypeBreakdown]
    let weeks: [WeekRollup]
    let months: [MonthRollup]
    let volumeSeries: [VolumeBucket]
    let topLifts: [TopLift]

    enum CodingKeys: String, CodingKey {
        case period
        case periodStart = "period_start"
        case periodEnd = "period_end"
        case totals
        case deltas
        case byType = "by_type"
        case weeks
        case months
        case volumeSeries = "volume_series"
        case topLifts = "top_lifts"
    }
}
