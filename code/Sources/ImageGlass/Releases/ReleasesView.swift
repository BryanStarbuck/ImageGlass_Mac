import SwiftUI
import ImageGlassCore

/// "Releases & News" surface — shows recent ImageGlass releases (both this
/// Mac-native fork and the upstream Windows/cross-platform project) plus
/// project milestones.
struct ReleasesView: View {

    private let releases: [ReleaseNote] = ReleasesCatalog.sortedReverseChronological
    private let milestones: [ProjectMilestone] = ReleasesCatalog.milestones
        .sorted { $0.date > $1.date }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                releaseList
                Divider().padding(.vertical, 4)
                milestoneSection
                Divider().padding(.vertical, 4)
                footer
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .frame(minWidth: 560, idealWidth: 720, minHeight: 480, idealHeight: 640)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Releases & News")
                .font(.largeTitle.bold())
            Text("Recent ImageGlass releases, milestones, and the v10 roadmap.")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Releases

    private var releaseList: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Recent Releases")
                .font(.title2.bold())
            ForEach(releases) { note in
                ReleaseCard(note: note)
            }
        }
    }

    // MARK: - Milestones

    private var milestoneSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Project Milestones")
                .font(.title2.bold())
            ForEach(milestones) { m in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(m.title).font(.headline)
                        Spacer(minLength: 8)
                        Text(Self.yearString(m.date))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(m.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Where to get releases")
                .font(.headline)
            Link("Official site — imageglass.org",
                 destination: URL(string: "https://imageglass.org")!)
            Link("GitHub Releases (binaries, betas, changelogs)",
                 destination: URL(string: "https://github.com/d2phap/ImageGlass/releases")!)
            Text("Note: the upstream releases listed above are shipped by the original "
                 + "ImageGlass project. This Mac-native fork tracks them for reference; "
                 + "we ship our own ImageGlass_Mac builds separately.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 6)
        }
    }

    // MARK: - Helpers

    private static func yearString(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy"
        return fmt.string(from: date)
    }
}

// MARK: - Release card

private struct ReleaseCard: View {
    let note: ReleaseNote

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(note.title)
                    .font(.title3.weight(.semibold))
                Spacer(minLength: 8)
                kindBadge
                originBadge
            }
            HStack(spacing: 8) {
                Text(note.version)
                    .font(.subheadline.monospaced())
                    .foregroundStyle(.secondary)
                Text("·").foregroundStyle(.secondary)
                Text(Self.dateString(note.date))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(note.highlights.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .top, spacing: 6) {
                    Text("•").foregroundStyle(.secondary)
                    Text(line)
                }
                .font(.callout)
            }
            if !note.milestones.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "flag.fill")
                        .foregroundStyle(.tint)
                    Text(note.milestones.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 2)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 1)
        )
    }

    private var kindBadge: some View {
        let isStable = note.kind == .stable
        let label = isStable ? "STABLE" : "BETA"
        let color: Color = isStable ? .green : .orange
        return Text(label)
            .font(.caption2.bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.18))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    @ViewBuilder
    private var originBadge: some View {
        if note.origin == .macFork {
            Text("MAC FORK")
                .font(.caption2.bold())
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.blue.opacity(0.18))
                .foregroundStyle(Color.blue)
                .clipShape(Capsule())
        } else {
            Text("UPSTREAM")
                .font(.caption2.bold())
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.gray.opacity(0.18))
                .foregroundStyle(.secondary)
                .clipShape(Capsule())
        }
    }

    private static func dateString(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "MMMM yyyy"
        return fmt.string(from: date)
    }
}
