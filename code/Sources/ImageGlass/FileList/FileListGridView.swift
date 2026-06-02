import SwiftUI
import ImageGlassCore

/// Thumbnail Grid mode — multi-row vertically scrollable grid via LazyVGrid.
/// Spec §2.3. Fluid columns via `.adaptive(minimum:)`.
struct FileListGridView: View {

    @Bindable var model: FileListViewModel

    private var pointSide: CGFloat { model.thumbSize.pointSide }
    private var pixelSide: Int { model.thumbSize.pixelSide }

    private var columns: [GridItem] {
        // Spec §2.3 — fluid columns via adaptive.
        [GridItem(.adaptive(minimum: pointSide + 12), spacing: 12, alignment: .top)]
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                    ForEach(model.visibleEntries) { entry in
                        FileListItemView(
                            entry: entry,
                            pixelSide: pixelSide,
                            pointSide: pointSide,
                            isSelected: model.selectionState.selected.contains(entry.path),
                            isFocused: model.selectionState.focused == entry.path,
                            showsLabel: true
                        )
                        .id(entry.path)
                        .onTapGesture { model.click(entry.path) }
                        .contextMenu { contextMenu(for: entry) }
                    }
                }
                .padding(12)
            }
            .onChange(of: model.selectionState.focused) { _, focused in
                guard let focused else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(focused, anchor: .center)
                }
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for entry: FileEntry) -> some View {
        Button("Open in Viewer") { model.click(entry.path) }
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([entry.url])
        }
        Divider()
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(entry.url.path, forType: .string)
        }
    }
}
