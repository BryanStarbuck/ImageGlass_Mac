import Foundation

public enum AppPaths {
    public static let appName = "ImageGlass"

    public static var appSupportDir: URL {
        let fm = FileManager.default
        let base = try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return (base ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support"))
            .appendingPathComponent(appName, isDirectory: true)
    }

    public static var scopesDir: URL {
        appSupportDir.appendingPathComponent("scopes", isDirectory: true)
    }

    public static var configFile: URL {
        appSupportDir.appendingPathComponent("igconfig.json")
    }

    public static func ensureDirectories() throws {
        let fm = FileManager.default
        for dir in [appSupportDir, scopesDir] {
            if !fm.fileExists(atPath: dir.path) {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
        }
    }

    public static func expandTilde(_ path: String) -> String {
        guard path.hasPrefix("~") else { return path }
        let home = NSHomeDirectory()
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + String(path.dropFirst(1)) }
        return path
    }

    public static func contractTilde(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + String(path.dropFirst(home.count)) }
        return path
    }
}
