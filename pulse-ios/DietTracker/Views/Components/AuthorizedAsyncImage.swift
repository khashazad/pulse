/// Async image loader that respects custom auth headers.
/// SwiftUI's `AsyncImage` cannot attach an `Authorization` header, so this view drives
/// `URLSession` directly with a caller-supplied `URLRequest` and renders the image via
/// the `content` closure once decoded, falling back to `placeholder` until then.
import SwiftUI

/// SwiftUI image view that fetches with an arbitrary authenticated `URLRequest`.
/// `content` receives the decoded `Image` on success; `placeholder` is shown otherwise.
struct AuthorizedAsyncImage<Content: View, Placeholder: View>: View {
    let request: URLRequest
    let content: (Image) -> Content
    let placeholder: () -> Placeholder

    @State private var loadedImage: UIImage?
    @State private var isLoading = false

    var body: some View {
        Group {
            if let img = loadedImage {
                content(Image(uiImage: img))
            } else {
                placeholder()
            }
        }
        .task(id: request.url) {
            await load()
        }
    }

    /// Performs the request via `URLSession.shared` and stores the decoded `UIImage`
    /// on success. Re-entrant calls while `isLoading` is true are dropped. Errors are
    /// swallowed so the view keeps showing the placeholder.
    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
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
