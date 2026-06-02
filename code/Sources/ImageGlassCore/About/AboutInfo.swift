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
