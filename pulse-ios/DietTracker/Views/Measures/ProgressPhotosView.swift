/// Photos sub-tab of the Measures screen.
///
/// Hosts `ProgressPhotosView`, which renders a date strip and the day's
/// photos as a flat 2-column grid. Each card shows its tag as a top-left
/// badge; tapping a card expands it to fullscreen via `matchedGeometryEffect`,
/// tapping again collapses back to the grid. The "Add" button opens
/// `PhotoCaptureSession` directly. Also triggers `ProgressPhotoStore.reconcile`
/// over a 30-day window when the selected date changes or on pull-to-refresh,
/// and exposes a "Manage tags" entry point in the toolbar.
import SwiftUI

struct ProgressPhotosView: View {
    @Environment(ProgressPhotoStore.self) private var store
    @Environment(ProgressPhotoTagStore.self) private var tagStore
    @State private var selectedDate: Date = Calendar.current.startOfDay(for: Date())
    @State private var showCapture = false
    @State private var showManageTags = false
    @State private var expandedId: UUID?
    @Namespace private var photoNS

    private let gridColumns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    var body: some View {
        ZStack {
            Theme.BG.primary.ignoresSafeArea()
            ScrollView {
                VStack(spacing: Theme.Layout.sectionSpacing) {
                    dateStrip
                    grid
                    addButton
                    syncFooter
                    Spacer(minLength: Theme.Layout.dockClearance)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }

            if let id = expandedId,
               let meta = sortedPhotos.first(where: { $0.id == id }) {
                ProgressPhotoDetailView(
                    meta: meta,
                    tagName: tagName(for: meta.tagId),
                    namespace: photoNS,
                    onClose: { withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { expandedId = nil } }
                )
                .transition(.opacity)
                .zIndex(1)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showManageTags = true } label: {
                    Image(systemName: "tag")
                        .foregroundStyle(Theme.CTP.mauve)
                }
            }
        }
        .task {
            await tagStore.reload()
            await reloadRange()
        }
        .refreshable { await reloadRange() }
        .onChange(of: selectedDate) { _, _ in
            Task { await reloadRange() }
        }
        .sheet(isPresented: $showCapture) {
            PhotoCaptureSession(date: selectedDate)
        }
        .sheet(isPresented: $showManageTags) {
            NavigationStack { ManageTagsView() }
        }
    }

    // MARK: date strip

    private var dateStrip: some View {
        HStack(spacing: 8) {
            chip("Today") { selectedDate = Calendar.current.startOfDay(for: Date()) }
            chip("−1") { shift(-1) }
            chip("−7") { shift(-7) }
            Spacer()
            DatePicker("", selection: $selectedDate, displayedComponents: .date)
                .labelsHidden()
                .tint(Theme.CTP.mauve)
        }
    }

    private func chip(_ label: String, action: @escaping () -> Void) -> some View {
        Button(label, action: action)
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Theme.BG.secondary, in: Capsule())
            .foregroundStyle(Theme.FG.primary)
    }

    private func shift(_ days: Int) {
        if let d = Calendar.current.date(byAdding: .day, value: days, to: selectedDate) {
            selectedDate = Calendar.current.startOfDay(for: d)
        }
    }

    // MARK: grid

    /// Photos for the selected date, sorted by tag display order then by
    /// capture time so the grid stays stable across re-renders. Tags that
    /// aren't loaded sort to the end with `Int.max` ordering.
    private var sortedPhotos: [ProgressPhotoMetadata] {
        store.photos(on: selectedDate).sorted { a, b in
            let oa = tagStore.tag(id: a.tagId)?.sortOrder ?? Int.max
            let ob = tagStore.tag(id: b.tagId)?.sortOrder ?? Int.max
            if oa != ob { return oa < ob }
            return a.updatedAt < b.updatedAt
        }
    }

    private var grid: some View {
        let photos = sortedPhotos
        return Group {
            if photos.isEmpty {
                Text("No photos for this day yet.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.FG.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 24)
            } else {
                LazyVGrid(columns: gridColumns, spacing: 12) {
                    ForEach(photos) { meta in
                        ProgressPhotoCell(
                            meta: meta,
                            tagName: tagName(for: meta.tagId),
                            namespace: photoNS,
                            isExpanded: expandedId == meta.id,
                            onTap: {
                                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                                    expandedId = meta.id
                                }
                            }
                        )
                    }
                }
            }
        }
    }

    /// Returns the display name for a tag id, falling back to "Tag" when the
    /// tag catalog hasn't loaded the row yet.
    /// - Parameter id: tag id referenced by a photo.
    /// - Returns: tag display name or the literal "Tag".
    private func tagName(for id: UUID) -> String {
        tagStore.tag(id: id)?.name ?? "Tag"
    }

    // MARK: add + sync footer

    private var addButton: some View {
        Button { showCapture = true } label: {
            HStack {
                Image(systemName: "plus.circle.fill")
                Text("Add photo")
            }
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(Theme.CTP.mauve)
            .frame(maxWidth: .infinity)
            .padding()
            .background(Theme.BG.secondary, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var syncFooter: some View {
        Group {
            if store.pendingCount == 0 {
                Text("All synced")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.FG.tertiary)
            } else {
                Text("\(store.pendingCount) pending…")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.FG.tertiary)
            }
        }
    }

    private func reloadRange() async {
        let from = Calendar.current.date(byAdding: .day, value: -30, to: selectedDate) ?? selectedDate
        await store.reconcile(from: from, to: selectedDate)
    }
}
