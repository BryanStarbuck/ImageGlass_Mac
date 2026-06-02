import SwiftUI
import Combine
import ImageGlassCore

struct ContentView: View {
    @Bindable var state: AppState
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic

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
        .task {
            await state.bootstrap()
            AboutAppDelegate.registerListenerAndFlush()
        }
        .onReceive(NotificationCenter.default.publisher(for: .imageGlassOpenURLs)) { note in
            guard let urls = note.userInfo?["urls"] as? [URL] else { return }
            for url in urls { state.openExternalFile(url: url) }
        }
        .onChange(of: state.showPanelColumn) { _, show in
            columnVisibility = show ? .all : .detailOnly
        }
        .onChange(of: columnVisibility) { _, vis in
            let shown = (vis != .detailOnly)
            if state.showPanelColumn != shown { state.showPanelColumn = shown }
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
