import SwiftUI
import AppKit
import ImageGlassCore

/// SwiftUI About surface that replaces the default `App > About ImageGlass`.
///
/// All content is sourced from `AboutInfo` in `ImageGlassCore`. Links open
/// in the user's default browser via `NSWorkspace`. Layout is a scrollable
/// vertical stack so the window stays usable at smaller heights.
struct AboutView: View {

    @State private var versionCopiedAt: Date?

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 18) {
                header
                Divider()
                historySection
                Divider()
                forkCreditSection
                Divider()
                upstreamCreatorSection
                Divider()
                philosophySection
                Divider()
                recognitionSection
                Divider()
                donationsSection
                Divider()
                projectLinksSection
                Divider()
                distributionSection
                Divider()
                legalSection
                Divider()
                licenseSection
                Divider()
                contactSection
                Spacer(minLength: 4)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 520, idealHeight: 700)
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            appIcon
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(AboutInfo.projectName)
                    .font(.system(size: 26, weight: .semibold))
                Text(AboutInfo.tagline)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                versionButton
                Text(AboutInfo.copyright)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Live `NSApp.applicationIconImage` so the icon stays in sync with
    /// whatever the bundle ships (or what the user assigns at runtime).
    private var appIcon: some View {
        Image(nsImage: NSApp.applicationIconImage ?? NSImage(named: NSImage.applicationIconName) ?? NSImage())
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
    }

    /// Version line is a button — clicking it copies the version string
    /// to the clipboard, which is the standard small affordance Apple
    /// uses in their own About panels.
    private var versionButton: some View {
        let label: String = {
            if let copiedAt = versionCopiedAt, Date().timeIntervalSince(copiedAt) < 1.5 {
                return "Copied — \(AboutInfo.versionLine)"
            }
            return AboutInfo.versionLine
        }()
        return Button(action: copyVersionToClipboard) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Click to copy version to clipboard")
        .accessibilityLabel(Text("Version \(AboutInfo.appVersion). Click to copy."))
    }

    private func copyVersionToClipboard() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(AboutInfo.appVersion, forType: .string)
        versionCopiedAt = Date()
    }

    private var historySection: some View {
        Text(AboutInfo.historyBlurb)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var recognitionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Recognition")
            ForEach(AboutInfo.recognition) { r in
                VStack(alignment: .leading, spacing: 1) {
                    Text(r.title).fontWeight(.semibold)
                    Text(r.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var distributionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Distribution Channels")
            Text("The official upstream site hosts:")
                .font(.callout)
                .foregroundStyle(.secondary)
            ForEach(AboutInfo.distributionChannels, id: \.self) { item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("•").foregroundStyle(.secondary)
                    Text(item)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var legalSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Legal")
            ForEach(AboutInfo.legalLinks) { link in
                linkRow(link)
            }
        }
    }

    private var forkCreditSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Fork")
            personBlock(AboutInfo.forkMaintainer)
        }
    }

    private var upstreamCreatorSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Upstream Creator")
            personBlock(AboutInfo.upstreamCreator)
            if let email = AboutInfo.upstreamCreator.contactEmail {
                Button {
                    AboutView.open(AboutInfo.contactMailtoURL)
                } label: {
                    Label(email, systemImage: "envelope")
                }
                .buttonStyle(.link)
            }
        }
    }

    private var philosophySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Project Philosophy")
            ForEach(Array(AboutInfo.philosophy.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("•").foregroundStyle(.secondary)
                    Text(line).fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("“\(AboutInfo.maintainerQuote)”")
                .italic()
                .foregroundStyle(.secondary)
                .padding(.top, 4)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var donationsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Support the Project")
            ForEach(AboutInfo.donationChannels) { link in
                linkRow(link)
            }
        }
    }

    private var projectLinksSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Project Links")
            ForEach(AboutInfo.projectLinks) { link in
                linkRow(link)
            }
        }
    }

    private var licenseSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("License")
            HStack(spacing: 6) {
                Text(AboutInfo.licenseShortName).fontWeight(.semibold)
                Text("—").foregroundStyle(.secondary)
                Button(AboutInfo.licenseFullName) {
                    AboutView.open(AboutInfo.licenseURL)
                }
                .buttonStyle(.link)
            }
            Text(AboutInfo.licenseSummary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var contactSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Contact")
            Button {
                AboutView.open(AboutInfo.contactMailtoURL)
            } label: {
                Label(AboutInfo.contactEmail, systemImage: "envelope")
            }
            .buttonStyle(.link)
        }
    }

    // MARK: - Helpers

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.headline)
            .foregroundStyle(.primary)
    }

    private func personBlock(_ p: AboutInfo.Person) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(p.name).font(.body).fontWeight(.semibold)
            Text(p.role)
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(p.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
    }

    private func linkRow(_ link: AboutInfo.Link) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Button(link.title) {
                AboutView.open(link.url)
            }
            .buttonStyle(.link)
            Text(link.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Open a URL in the default browser / mail client. Static so the
    /// `AboutWindowController` can reach it too if it needs to.
    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}

#if DEBUG
#Preview {
    AboutView()
}
#endif
