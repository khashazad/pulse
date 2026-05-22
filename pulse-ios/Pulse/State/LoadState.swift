/// LoadState: generic four-state lifecycle for any async-loaded resource.
/// Provides idle/loading/loaded/failed cases used by view-models across the app
/// to drive SwiftUI rendering uniformly.
/// Role: shared state primitive consumed by every Observable model in this folder.
import Foundation

/// Generic load-state lifecycle for async resources, parameterized by the loaded payload type.
enum LoadState<T> {
    case idle
    case loading
    case loaded(T)
    case failed(PulseError)
}
