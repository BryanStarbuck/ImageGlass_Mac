import SwiftUI
import ImageGlassCore

/// Thumbnail Strip mode — one horizontal row.
/// Spec §2.2.
struct FileListStripView: View {

    @Bindable var model: FileListViewModel

    private let thumbPointSide: CGFloat = 96 // Spec §2.2

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: true) {
                LazyHStack(spacing: 8) {
                    ForEach(model.visibleEntries) { entry in
                        FileListItemView(
                            entry: entry,
                            pixelSide: 128, // Image I/O thumbnail size — bigger than display side for crispness on retina
                            pointSide: thumbPointSide,
                            isSelected: model.selectionState.selected.contains(entry.path),
                            isFocused: model.selectionState.focused == entry.path,
                            showsLabel: false
                        )
                        .id(entry.path)
                        .onTapGesture { model.click(entry.path) }
                        .contextMenu { contextMenu(for: entry) }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
            }
            .onChange(of: model.selectionState.focused) { _, focused in
                guard let focused else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(focused, anchor: .center)
                }
            }
        }
        .frame(height: thumbPointSide + 16)
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
