import SwiftUI
import ImageGlassCore

struct ContentView: View {
    @Bindable var state: AppState

    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            DirectoryFilenamePanel(state: state)
                .frame(minWidth: 220, idealWidth: 280)
        } detail: {
            VStack(spacing: 0) {
                ImageViewer(state: state, viewer: state.viewer)
                statusBar
            }
        }
        .navigationTitle(windowTitle)
        .tint(state.themeStore.currentTheme.colors.accentColor)
        .preferredColorScheme(state.themeStore.currentTheme.preferredColorScheme)
        .task { await state.bootstrap() }
        .onChange(of: state.showPanelColumn) { _, visible in
            // Charter §2: the user can show / hide the panel column. Mirror
            // the AppState flag into the SwiftUI split-view visibility so the
            // toolbar button actually does what its tooltip says.
            columnVisibility = visible ? .all : .detailOnly
        }
        .onChange(of: columnVisibility) { _, vis in
            // User-driven drag of the sidebar divider also flips the flag,
            // so menu commands and tests reading `showPanelColumn` see truth.
            let visible = (vis != .detailOnly)
            if state.showPanelColumn != visible {
                state.showPanelColumn = visible
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    state.showPanelColumn.toggle()
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .help("Toggle panel column")
            }
        }
    }

    private var windowTitle: String {
        if let path = state.selectedFile {
            return (path as NSString).lastPathComponent
        }
        return "ImageGlass"
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            Text("\(state.resolvedFiles.count) files")
                .foregroundStyle(.secondary)
            if let evaluatedAt = state.lastEvaluated {
                Text("· evaluated \(relative(evaluatedAt))")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let path = state.selectedFile {
                Text(path)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(.caption, design: .monospaced))
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.bar)
    }

    private func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }
}
