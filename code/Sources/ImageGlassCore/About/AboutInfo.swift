import Foundation

/// Static, code-owned metadata for the About surface.
///
/// This is the single source of truth that both the SwiftUI About window
/// and any documentation generators (or tests) read from. The fields are
/// intentionally plain `String` / `URL` so they can be rendered in either
/// SwiftUI or a plain `NSTextView`, and asserted on from XCTest without
/// any UI dependency.
///
/// The Mac rebuild is a fork by Bryan Starbuck. Upstream credit to the
/// original creator, Dương Diệu Pháp, is preserved verbatim — both
/// authorship lines belong on the About surface.
public enum AboutInfo {

    // MARK: - Project identity

    /// Display name of this fork.
    public static let projectName = "ImageGlass for Mac"

    /// Display name of the original upstream project.
    public static let upstreamProjectName = "ImageGlass"

    /// One-line tagline shown under the app title.
    public static let tagline =
        "Open-source, ad-free photo viewer — Mac-native rebuild."

    /// Copyright string. Range follows upstream (2010 first release →
    /// current spec year 2026).
    public static let copyright = "© 2010–2026 Dương Diệu Pháp"

    /// One-paragraph history blurb (spec: "over 16 years (since 2010)…
    /// single maintainer who continues to work on the project in his
    /// spare time").
    public static let historyBlurb = """
        ImageGlass is an open-source, ad-free photo viewer for Windows. \
        It has been actively developed and maintained for over 16 years \
        (since 2010) by a single maintainer who continues to work on \
        the project in his spare time.
        """

    // MARK: - Version

    /// Marketing version of this Mac fork. Sourced from the in-code
    /// Releases catalog so the About surface and the Releases & News
    /// window can never drift.
    public static var appVersion: String {
        if let mac = ReleasesCatalog.releases.first(where: { $0.origin == .macFork }) {
            return mac.version
        }
        return "ImageGlass_Mac"
    }

    /// Short text shown next to the title — e.g. "Version ImageGlass_Mac 0.1".
    public static var versionLine: String {
        "Version \(appVersion)"
    }

    // MARK: - Credits

    public struct Person: Sendable, Equatable {
        public let name: String
        public let role: String
        public let detail: String
        public let contactEmail: String?
        public init(
            name: String,
            role: String,
            detail: String,
            contactEmail: String? = nil
        ) {
            self.name = name
            self.role = role
            self.detail = detail
            self.contactEmail = contactEmail
        }
    }

    /// Upstream creator. Per spec: copyright is held by Dương Diệu Pháp.
    public static let upstreamCreator = Person(
        name: "Dương Diệu Pháp",
        role: "Creator & sole maintainer of upstream ImageGlass",
        detail: """
            Vietnamese software engineer. Senior Frontend Engineer at \
            OpenProtein.AI by day; maintains ImageGlass in his spare \
            time. Active on GitHub and author of several open-source \
            web libraries.
            """,
        contactEmail: "phap@imageglass.org"
    )

    /// Fork maintainer. This must NOT erase upstream credit — both
    /// people appear on the About surface.
    public static let forkMaintainer = Person(
        name: "Bryan Starbuck",
        role: "Fork maintainer (Mac-native rebuild)",
        detail: """
            This is Bryan Starbuck's fork of upstream ImageGlass — \
            adds MCP, panels, scopes, and Local Storage on top of a \
            from-scratch SwiftUI + AppKit rebuild for macOS 14+.
            """
    )

    // MARK: - Philosophy

    /// Three guiding principles (verbatim from the spec).
    public static let philosophy: [String] = [
        "Open source. Source is publicly hosted on GitHub. Anyone can read, fork, modify, and contribute.",
        "Ad-free, always. No banners, no upsells, no telemetry-driven ads.",
        "Community-funded. Sustainability comes from donations and sponsorships, not from advertising or paid feature gates."
    ]

    /// The maintainer's own statement about funding, quoted in the spec.
    public static let maintainerQuote =
        "Your financial backing not only sustains this project but also fuels my motivation for crafting future releases."

    // MARK: - License

    /// License the source is distributed under.
    ///
    /// Upstream ImageGlass is released under the GNU General Public
    /// License v3.0. We surface that explicitly here so users see the
    /// license without leaving the app.
    public static let licenseShortName = "GPLv3"
    public static let licenseFullName = "GNU General Public License, version 3.0"
    public static let licenseURL = URL(string: "https://www.gnu.org/licenses/gpl-3.0.html")!

    public static let licenseSummary = """
        ImageGlass is free software: you can redistribute it and/or \
        modify it under the terms of the GNU General Public License as \
        published by the Free Software Foundation, either version 3 of \
        the License, or (at your option) any later version.

        ImageGlass is distributed in the hope that it will be useful, \
        but WITHOUT ANY WARRANTY; without even the implied warranty of \
        MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the \
        GNU General Public License for more details.
        """

    // MARK: - Recognition

    /// A single recognition / milestone entry shown in the About surface.
    /// Distinct from `ReleaseNote` because these are project-level events,
    /// not software releases.
    public struct Recognition: Sendable, Equatable, Identifiable {
        public let title: String
        public let detail: String
        public var id: String { title }
        public init(title: String, detail: String) {
            self.title = title
            self.detail = detail
        }
    }

    /// Recognition entries pulled verbatim from the spec.
    public static let recognition: [Recognition] = [
        Recognition(
            title: "WeAreDevelopers World Congress 2025 (Berlin)",
            detail: "ImageGlass was selected for the Open Source Spotlight."
        ),
        Recognition(
            title: "15-year anniversary",
            detail: "Celebrated with the 9.3 release, which added enhanced Windows Explorer compatibility."
        ),
    ]

    // MARK: - Distribution Channels

    /// Items hosted by the official upstream website (spec: Distribution
    /// Channels). Plain strings — these describe what `imageglass.org`
    /// hosts and are not individually linkable.
    public static let distributionChannels: [String] = [
        "All software releases (stable and beta)",
        "Theme packs (.igtheme)",
        "Extension icon packs",
        "Language packs",
        "Developer tools / SDK for building third-party integrations",
    ]

    // MARK: - Links

    public struct Link: Sendable, Equatable, Identifiable {
        public let title: String
        public let subtitle: String
        public let url: URL
        public var id: String { url.absoluteString }
        public init(title: String, subtitle: String, url: URL) {
            self.title = title
            self.subtitle = subtitle
            self.url = url
        }
    }

    /// Upstream / fork / project home links.
    public static let projectLinks: [Link] = [
        Link(
            title: "Upstream Website",
            subtitle: "imageglass.org — official site for the original project",
            url: URL(string: "https://imageglass.org")!
        ),
        Link(
            title: "Upstream GitHub",
            subtitle: "Source code, issues, and releases for the original Windows app",
            url: URL(string: "https://github.com/d2phap/ImageGlass")!
        )
    ]

    /// Legal documents published on the upstream website (spec).
    public static let legalLinks: [Link] = [
        Link(
            title: "End-User License Agreement",
            subtitle: "Published on the upstream website",
            url: URL(string: "https://imageglass.org/license")!
        ),
        Link(
            title: "Privacy Policy",
            subtitle: "Published on the upstream website",
            url: URL(string: "https://imageglass.org/privacy")!
        ),
    ]

    /// Donation channels offered by upstream (per spec).
    public static let donationChannels: [Link] = [
        Link(
            title: "GitHub Sponsors",
            subtitle: "Recurring or one-time support via GitHub",
            url: URL(string: "https://github.com/sponsors/d2phap")!
        ),
        Link(
            title: "Patreon",
            subtitle: "Recurring support with tier-specific benefits",
            url: URL(string: "https://www.patreon.com/d2phap")!
        ),
        Link(
            title: "PayPal",
            subtitle: "One-time donation via PayPal",
            url: URL(string: "https://www.paypal.com/paypalme/d2phap")!
        ),
        Link(
            title: "Stripe",
            subtitle: "One-time donation via Stripe",
            url: URL(string: "https://donate.stripe.com/9AQ4hQ9dq5lZ8YwbII")!
        ),
        Link(
            title: "OpenPledge.io",
            subtitle: "Community pledge platform — ImageGlass recently joined",
            url: URL(string: "https://openpledge.io")!
        )
    ]

    // MARK: - Contact

    /// Maintainer contact email (mirror of `upstreamCreator.contactEmail`).
    public static let contactEmail = "phap@imageglass.org"

    public static var contactMailtoURL: URL {
        URL(string: "mailto:\(contactEmail)")!
    }
}
