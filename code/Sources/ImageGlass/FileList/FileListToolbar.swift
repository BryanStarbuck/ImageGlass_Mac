import SwiftUI
import ImageGlassCore

/// Top toolbar for the File List Panel.
/// Spec §2.7 / §4.1 — Scope, mode toggle, sort menu, filter field,
/// refresh, edit-scope. 32 pt tall, matches Mail.app.
struct FileListToolbarView: View {

    @Bindable var model: FileListViewModel

    /// Called when the user clicks the Refresh button. Hosted by the panel
    /// container so the panel can route into AppState.reevaluateActive().
    let onRefresh: () -> Void

    /// Called when the user clicks the Edit-Scope button. Hosted by the
    /// panel container. The panel framework opens the scope editor.
    let onEditScope: () -> Void

    /// Called when the user clicks the scope name to switch scopes. Hosted
    /// by the panel container.
    let onPickScope: () -> Void

    @FocusState private var filterFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            // Scope name (clickable)
            Button(action: onPickScope) {
                HStack(spacing: 4) {
                    Image(systemName: "folder")
                    Text(model.activeScopeName.isEmpty ? "No Scope" : model.activeScopeName)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                }
            }
            .buttonStyle(.plain)
            .help("Switch scope")

            Divider().frame(height: 16)

            // Mode toggle — segmented control with 5 segments. Spec §2.7.
            Picker("Mode", selection: Binding(
                get: { model.viewMode },
                set: { model.setViewMode($0) }
            )) {
                ForEach(FileListViewMode.allCases) { mode in
                    Image(systemName: mode.sfSymbol)
                        .help(mode.label)
                        .tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 180)

            // Sort menu. Spec §5.1.
            Menu {
                ForEach(FileListSortField.allCases) { field in
                    Button {
                        model.setSort(field: field, direction: model.sortDescriptor.direction)
                    } label: {
                        HStack {
                            Text(field.label)
                            if model.sortDescriptor.field == field {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
                Divider()
                Button {
                    let opposite: FileListSortDirection =
                        model.sortDescriptor.direction == .ascending ? .descending : .ascending
                    model.setSort(field: model.sortDescriptor.field, direction: opposite)
                } label: {
                    Label(
                        model.sortDescriptor.direction == .ascending ? "Descending" : "Ascending",
                        systemImage: model.sortDescriptor.direction == .ascending
                            ? "arrow.down" : "arrow.up"
                    )
                }
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
                    .labelStyle(.iconOnly)
            }
            .menuStyle(.borderlessButton)
            .help("Sort: \(model.sortDescriptor.field.label) \(model.sortDescriptor.direction.label)")
            .fixedSize()

            // Filter field. Spec §5.2.
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("Filter", text: Binding(
                    get: { model.filterText },
                    set: { model.setFilter($0) }
                ))
                .textFieldStyle(.plain)
                .focused($filterFocused)
                .onSubmit { filterFocused = false }
                if !model.filterText.isEmpty {
                    Button {
                        model.setFilter("")
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear filter")
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .frame(maxWidth: 220)

            Spacer(minLength: 4)

            // Refresh
            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("Re-evaluate scope")
            .keyboardShortcut("r", modifiers: .command)

            // Edit
            Button(action: onEditScope) {
                Image(systemName: "pencil")
            }
            .buttonStyle(.plain)
            .help("Edit scope")
        }
        .padding(.horizontal, 8)
        .frame(height: 32)
        .background(.regularMaterial)
    }
}
