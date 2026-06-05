import Foundation

/// Result of querying GitHub Releases for an updated build.
public struct UpdateCheckResult: Sendable, Equatable {
    public let currentVersion: String
    public let latestVersion: String?
    public let latestPublishedAt: Date?
    public let latestReleaseURL: URL?
    public let isUpdateAvailable: Bool
    public let channel: ReleaseChannel
    public let checkedAt: Date

    public init(
        currentVersion: String,
        latestVersion: String?,
        latestPublishedAt: Date?,
        latestReleaseURL: URL?,
        isUpdateAvailable: Bool,
        channel: ReleaseChannel,
        checkedAt: Date
    ) {
        self.currentVersion = currentVersion
        self.latestVersion = latestVersion
        self.latestPublishedAt = latestPublishedAt
        self.latestReleaseURL = latestReleaseURL
        self.isUpdateAvailable = isUpdateAvailable
        self.channel = channel
        self.checkedAt = checkedAt
    }
}

/// Errors that can short-circuit an update check.
public enum UpdateCheckError: Error, Equatable, Sendable {
    case disabledByPolicy
    case networkUnavailable
    case malformedResponse
    case httpStatus(Int)
}

/// Disabled-by-default checker that asks GitHub Releases whether a newer
/// build of `ACT3ai/ImageGlass_Mac` exists.
///
/// The spec doesn't mandate automatic update checks (the project ships via
/// GitHub Releases — users opt in by visiting the page), so the implementation
/// is fully functional but `isEnabledByDefault == false`. Code in the GUI
/// must read `isEnabled` (or pass `force: true`) before issuing the network
/// call, so no telemetry-style background traffic happens unless the user
/// opts in.
public struct UpdateChecker: Sendable {

    /// GitHub repo for the Mac fork. The upstream Windows repo lives at
    /// `d2phap/ImageGlass`; this fork lives at `ACT3ai/ImageGlass_Mac`.
    public static let repoOwner = "ACT3ai"
    public static let repoName = "ImageGlass_Mac"

    /// Privacy default — no network call until the user opts in.
    public static let isEnabledByDefault: Bool = false

    public let channel: ReleaseChannel
    public let currentVersion: String
    public let session: URLSession
    public let isEnabled: Bool

    public init(
        channel: ReleaseChannel = AppVersion.channel,
        currentVersion: String = AppVersion.marketingVersion,
        isEnabled: Bool = UpdateChecker.isEnabledByDefault,
        session: URLSession = .shared
    ) {
        self.channel = channel
        self.currentVersion = currentVersion
        self.isEnabled = isEnabled
        self.session = session
    }

    /// Build the URL we would query. Exposed so tests can assert routing
    /// without doing any network I/O.
    public var endpointURL: URL {
        URL(string: "https://api.github.com/repos/\(Self.repoOwner)/\(Self.repoName)/\(channel.githubReleasesPath)")!
    }

    /// Returns the latest published release for this channel, or `nil` if
    /// there isn't one available yet. `force` overrides `isEnabled` — the
    /// "Check for Updates…" menu item passes `force: true` because the user
    /// is explicitly asking.
    public func check(force: Bool = false) async throws -> UpdateCheckResult {
        let _trace = PerformanceLog.shared.start(
            "Releases.CheckForUpdate",
            extra: [("channel", channel.rawValue), ("force", String(force))]
        )
        defer { _trace.finish() }
        if !force && !isEnabled {
            throw UpdateCheckError.disabledByPolicy
        }
        var req = URLRequest(url: endpointURL)
        req.setValue(AppVersion.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 10

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            ErrorLog.log("update check network request failed for \(endpointURL.absoluteString)",
                         error: error,
                         class: "UpdateChecker")
            throw UpdateCheckError.networkUnavailable
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            ErrorLog.log("update check returned HTTP \(http.statusCode) for \(endpointURL.absoluteString)",
                         class: "UpdateChecker")
            throw UpdateCheckError.httpStatus(http.statusCode)
        }

        let latest: LatestRelease?
        do {
            latest = try Self.parseLatest(data: data, channel: channel)
        } catch {
            ErrorLog.log("update check failed to parse response from \(endpointURL.absoluteString)",
                         error: error,
                         class: "UpdateChecker")
            throw error
        }
        let available = Self.isNewer(latest?.version, than: currentVersion)
        return UpdateCheckResult(
            currentVersion: currentVersion,
            latestVersion: latest?.version,
            latestPublishedAt: latest?.publishedAt,
            latestReleaseURL: latest?.htmlURL,
            isUpdateAvailable: available,
            channel: channel,
            checkedAt: Date()
        )
    }

    // MARK: - Parsing

    struct LatestRelease: Equatable {
        let version: String
        let publishedAt: Date?
        let htmlURL: URL?
    }

    static func parseLatest(data: Data, channel: ReleaseChannel) throws -> LatestRelease? {
        let obj = try JSONSerialization.jsonObject(with: data)

        // /latest returns a single object; /releases returns an array. We
        // pick the first non-draft entry that matches the channel.
        switch obj {
        case let dict as [String: Any]:
            return release(from: dict)
        case let arr as [Any]:
            for case let dict as [String: Any] in arr {
                if (dict["draft"] as? Bool) == true { continue }
                let isPrerelease = (dict["prerelease"] as? Bool) ?? false
                if channel == .stable && isPrerelease { continue }
                if let r = release(from: dict) { return r }
            }
            return nil
        default:
            throw UpdateCheckError.malformedResponse
        }
    }

    private static func release(from dict: [String: Any]) -> LatestRelease? {
        // `tag_name` is the GitHub release tag, e.g. "v0.2.0" or "0.2.0-beta".
        guard let tag = (dict["tag_name"] as? String) ?? (dict["name"] as? String) else {
            return nil
        }
        let version = normalize(tag: tag)
        let urlString = dict["html_url"] as? String
        let url = urlString.flatMap(URL.init(string:))
        var publishedAt: Date?
        if let pub = dict["published_at"] as? String {
            publishedAt = ISO8601DateFormatter().date(from: pub)
        }
        return LatestRelease(version: version, publishedAt: publishedAt, htmlURL: url)
    }

    static func normalize(tag: String) -> String {
        var t = tag
        if t.hasPrefix("v") || t.hasPrefix("V") {
            t.removeFirst()
        }
        return t
    }

    /// Compares two dotted version strings ("0.1.0" vs "0.2.0"). Falls back
    /// to a string compare if either side isn't parseable. Pre-release
    /// suffixes ("0.2.0-beta") are stripped for the numeric comparison.
    static func isNewer(_ candidate: String?, than current: String) -> Bool {
        guard let candidate, !candidate.isEmpty else { return false }
        let c = numericComponents(of: candidate)
        let cur = numericComponents(of: current)
        let n = max(c.count, cur.count)
        for i in 0..<n {
            let a = i < c.count ? c[i] : 0
            let b = i < cur.count ? cur[i] : 0
            if a > b { return true }
            if a < b { return false }
        }
        // Numeric equality — treat a pre-release as "older" than its release
        // (so "0.2.0-beta" is not newer than "0.2.0").
        return false
    }

    private static func numericComponents(of version: String) -> [Int] {
        let core = version.split(separator: "-", maxSplits: 1).first.map(String.init) ?? version
        let plusStripped = core.split(separator: "+", maxSplits: 1).first.map(String.init) ?? core
        return plusStripped.split(separator: ".").map { Int($0) ?? 0 }
    }
}
