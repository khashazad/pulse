/// Async image loader that respects custom auth headers.
/// SwiftUI's `AsyncImage` cannot attach an `Authorization` header, so this view drives
/// `URLSession` directly with a caller-supplied `URLRequest` and renders the image via
/// the `content` closure once decoded, falling back to `placeholder` until then.
import SwiftUI

/// Hashable identity for the request fields that affect authenticated image loading.
struct AuthorizedAsyncImageRequestIdentity: Hashable {
    private let url: URL?
    private let method: String?
    private let headers: [Header]
    private let cachePolicy: UInt
    private let timeoutInterval: TimeInterval
    private let body: Data?

    /// Captures the stable request fields SwiftUI should use to decide
    /// whether to restart the image-loading task.
    /// Inputs:
    ///   - request: URLRequest whose URL, method, headers, cache policy, timeout, and body form the identity.
    /// Outputs: AuthorizedAsyncImageRequestIdentity used as a SwiftUI task id.
    /// Throws: none.
    init(_ request: URLRequest) {
        self.url = request.url
        self.method = request.httpMethod
        self.headers = (request.allHTTPHeaderFields ?? [:])
            .map { Header(name: $0.key.lowercased(), value: $0.value) }
            .sorted { lhs, rhs in
                lhs.name == rhs.name ? lhs.value < rhs.value : lhs.name < rhs.name
            }
        self.cachePolicy = request.cachePolicy.rawValue
        self.timeoutInterval = request.timeoutInterval
        self.body = request.httpBody
    }

    private struct Header: Hashable {
        let name: String
        let value: String
    }
}

/// SwiftUI image view that fetches with an arbitrary authenticated `URLRequest`.
/// `content` receives the decoded `Image` on success; `placeholder` is shown otherwise.
struct AuthorizedAsyncImage<Content: View, Placeholder: View>: View {
    let request: URLRequest
    let content: (Image) -> Content
    let placeholder: () -> Placeholder

    @State private var loadedImage: UIImage?
    @State private var loadedImageURL: URL?

    var body: some View {
        Group {
            if let img = loadedImage {
                content(Image(uiImage: img))
            } else {
                placeholder()
            }
        }
        .task(id: AuthorizedAsyncImageRequestIdentity(request)) {
            // Only blank the rendered image when the URL itself changes —
            // header-only churn (e.g. token rotation, cache-policy tweak)
            // should reload without a placeholder flicker.
            if loadedImageURL != request.url { loadedImage = nil }
            loadedImageURL = request.url
            await load()
        }
    }

    /// Performs the request via `URLSession.shared` and stores the decoded `UIImage`
    /// on success. Errors are swallowed so the view keeps showing the placeholder.
    /// Inputs: none.
    /// Outputs: Void; updates `loadedImage` when image decoding succeeds.
    /// Throws: none.
    private func load() async {
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            if let img = UIImage(data: data) {
                self.loadedImage = img
            }
        } catch {
            // leave placeholder
        }
    }
}
