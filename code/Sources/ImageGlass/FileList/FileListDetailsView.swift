import SwiftUI
import ImageGlassCore

/// Details / List mode — backed by SwiftUI Table. Spec §2.4.
struct FileListDetailsView: View {

    @Bindable var model: FileListViewModel

    @State private var sortOrder: [KeyPathComparator<FileEntry>] = [
        KeyPathComparator(\FileEntry.name)
    ]

    var body: some View {
        Table(
            model.visibleEntries,
            selection: Binding(
                get: { model.selectionState.selected },
                set: { newSelection in
                    model.setSelection(paths: Array(newSelection))
                }
            ),
            sortOrder: $sortOrder
        ) {
            TableColumn("") { entry in
                FileListItemView(
                    entry: entry,
                    pixelSide: 64,
                    pointSide: FileListThumbSize.detailsRowSide,
                    isSelected: model.selectionState.selected.contains(entry.path),
                    isFocused: model.selectionState.focused == entry.path,
                    showsLabel: false
                )
                .frame(width: FileListThumbSize.detailsRowSide,
                       height: FileListThumbSize.detailsRowSide)
            }
            .width(28)
            TableColumn("Name", value: \.name) { entry in
                Text(entry.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .onTapGesture(count: 2) { model.click(entry.path) }
            }
            .width(min: 120, ideal: 240)
            TableColumn("Size") { (entry: FileEntry) in
                Text(formatSize(entry.size))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 80)
            TableColumn("Dimensions") { (entry: FileEntry) in
                Text(formatDimensions(entry.dimensions))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 110)
            TableColumn("Modified") { (entry: FileEntry) in
                Text(formatDate(entry.mtime))
                    .foregroundStyle(.secondary)
            }
            .width(min: 100, ideal: 140)
            TableColumn("Type") { (entry: FileEntry) in
                Text(entry.ext.isEmpty ? "—" : entry.ext.uppercased())
                    .foregroundStyle(.secondary)
            }
            .width(min: 50, ideal: 60)
        }
        .onChange(of: sortOrder) { _, new in
            // Map Table's KeyPathComparator into our spec sort. Currently
            // only name → name; richer mapping is left to a follow-up.
            if let first = new.first {
                let isAsc = first.order == .forward
                model.setSort(field: .name, direction: isAsc ? .ascending : .descending)
            }
        }
    }

    // MARK: - Formatters

    private func formatSize(_ bytes: Int64?) -> String {
        guard let b = bytes else { return "—" }
        return ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }

    private func formatDimensions(_ size: CGSize?) -> String {
        guard let s = size, s.width > 0, s.height > 0 else { return "—" }
        return "\(Int(s.width))×\(Int(s.height))"
    }

    private static let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return df
    }()

    private func formatDate(_ date: Date?) -> String {
        guard let d = date else { return "—" }
        return Self.dateFormatter.string(from: d)
    }
}
