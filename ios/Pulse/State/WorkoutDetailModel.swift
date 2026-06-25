import Foundation

/// Loads and holds a single workout's full detail.
@Observable
final class WorkoutDetailModel {
    private(set) var state: LoadState<ActivityWorkoutDetail> = .idle
    private weak var auth: AuthSession?
    private let workoutId: UUID

    /// - Parameters:
    ///   - id: The workout to load.
    ///   - auth: The signed-in session used to build an authorized client.
    init(id: UUID, auth: AuthSession) {
        self.workoutId = id
        self.auth = auth
    }

    /// Loads the workout detail into `state`, mapping failures to `LoadState.failed`.
    /// - Returns: Nothing; result is published via `state`.
    func load() async {
        guard let client = auth?.makeClient() else { state = .failed(.notSignedIn); return }
        state = .loading
        do {
            state = .loaded(try await client.activityWorkoutDetail(id: workoutId))
        } catch let error as PulseError {
            if error == .unauthorized { auth?.handleUnauthorized() }
            state = .failed(error)
        } catch {
            state = .failed(.server(status: -1))
        }
    }

    /// A labeled stat tile for the detail grid.
    struct Stat { let label: String; let value: String }

    /// Builds the ordered Apple-stat tiles present for a workout (skips nil metrics).
    /// - Parameter d: The loaded workout detail.
    /// - Returns: Up to several `Stat` tiles (calories, duration, HR, distance, etc.).
    static func appleStats(_ d: ActivityWorkoutDetail) -> [Stat] {
        var out: [Stat] = []
        if let c = d.activeEnergyCal { out.append(Stat(label: "Active kcal", value: String(Int(c.rounded())))) }
        if let m = d.durationMin { out.append(Stat(label: "Duration", value: "\(Int(m.rounded())) min")) }
        if let hr = d.avgHeartRate { out.append(Stat(label: "Avg HR", value: "\(Int(hr.rounded()))")) }
        if let hr = d.maxHeartRate { out.append(Stat(label: "Max HR", value: "\(Int(hr.rounded()))")) }
        if let km = d.distanceKm { out.append(Stat(label: "Distance", value: "\(km.clean) km")) }
        if let el = d.elevationAscendedM { out.append(Stat(label: "Elevation", value: "\(Int(el.rounded())) m")) }
        if let mets = d.avgMets { out.append(Stat(label: "Avg METs", value: mets.clean)) }
        return out
    }
}
