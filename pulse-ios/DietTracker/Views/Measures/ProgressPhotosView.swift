/// Photos sub-tab of the Measures screen.
///
/// Hosts `ProgressPhotosView`, which renders a date strip and the day's
/// photos grouped by tag, with an Add button that walks the user through
/// `TagPickerSheet` → `PhotoCaptureSession`. Also triggers
/// `ProgressPhotoStore.reconcile` over a 30-day window when the selected
/// date changes or on pull-to-refresh, and exposes a "Manage tags" entry
/// point in the toolbar.
import SwiftUI

struct ProgressPhotosView: View {
    @Environment(ProgressPhotoStore.self) private var store
    @Environment(ProgressPhotoTagStore.self) private var tagStore
    @State private var selectedDate: Date = Calendar.current.startOfDay(for: Date())
    @State private var showTagPicker = false
    @State private var pickedTag: ProgressPhotoTag?
    @State private var showCapture = false
    @State private var showManageTags = false

    var body: some View {
        ZStack {
            Theme.BG.primary.ignoresSafeArea()
            ScrollView {
                VStack(spacing: Theme.Layout.sectionSpacing) {
                    dateStrip
                    sections
                    addButton
                    syncFooter
                    Spacer(minLength: Theme.Layout.dockClearance)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
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
        .sheet(isPresented: $showTagPicker) {
            TagPickerSheet { tag in
                pickedTag = tag
                showCapture = true
            }
        }
        .sheet(isPresented: $showCapture) {
            if let tag = pickedTag {
                PhotoCaptureSession(date: selectedDate, tag: tag)
            }
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

    // MARK: sections

    /// Photos for the selected date grouped by tag, in tag sort order. Tags
    /// with no photos for this date are skipped to keep the screen lean.
    private var sections: some View {
        let photos = store.photos(on: selectedDate)
        let byTag = Dictionary(grouping: photos, by: \.tagId)
        let orderedTags = tagStore.tags.filter { byTag[$0.id] != nil }
        return VStack(alignment: .leading, spacing: 16) {
            if orderedTags.isEmpty {
                Text("No photos for this day yet.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.FG.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 24)
            } else {
                ForEach(orderedTags) { tag in
                    if let group = byTag[tag.id], !group.isEmpty {
                        tagSection(tag: tag, photos: group)
                    }
                }
            }
        }
    }

    private func tagSection(tag: ProgressPhotoTag, photos: [ProgressPhotoMetadata]) -> some View {
        let cols = [GridItem(.flexible()), GridItem(.flexible())]
        return VStack(alignment: .leading, spacing: 8) {
            Text(tag.name)
                .font(.system(size: 13, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Theme.FG.secondary)
            LazyVGrid(columns: cols, spacing: 12) {
                ForEach(photos) { meta in
                    ProgressPhotoCell(meta: meta)
                }
            }
        }
    }

    // MARK: add + sync footer

    private var addButton: some View {
        Button { showTagPicker = true } label: {
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
