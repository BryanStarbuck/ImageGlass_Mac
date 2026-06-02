import Foundation

/// A Scope defines which files are in the active file list.
/// Persisted as plain JSON in Local Storage.
public struct Scope: Codable, Equatable, Sendable {
    public var name: String
    public var description: String?
    public var include: IncludeRules
    public var exclude: ExcludeRules
    public var lastEvaluated: Date?
    public var resolvedFiles: [String]

    public init(
        name: String,
        description: String? = nil,
        include: IncludeRules = .init(),
        exclude: ExcludeRules = .init(),
        lastEvaluated: Date? = nil,
        resolvedFiles: [String] = []
    ) {
        self.name = name
        self.description = description
        self.include = include
        self.exclude = exclude
        self.lastEvaluated = lastEvaluated
        self.resolvedFiles = resolvedFiles
    }

    public struct IncludeRules: Codable, Equatable, Sendable {
        public var directories: [String]
        public var recursive: Bool
        public var globs: [String]
        public var extensions: [String]

        public init(
            directories: [String] = [],
            recursive: Bool = true,
            globs: [String] = [],
            extensions: [String] = []
        ) {
            self.directories = directories
            self.recursive = recursive
            self.globs = globs
            self.extensions = extensions
        }
    }

    public struct ExcludeRules: Codable, Equatable, Sendable {
        public var globs: [String]
        public var hiddenFiles: Bool

        public init(globs: [String] = [], hiddenFiles: Bool = true) {
            self.globs = globs
            self.hiddenFiles = hiddenFiles
        }
    }
}

/// Default scope that ships with first launch.
public extension Scope {
    static var starter: Scope {
        // Pull the default extension list from the central format registry so
        // the on-disk story stays in sync with what the loader can actually
        // decode (see `docs/supported-formats.mdx`).
        Scope(
            name: "default",
            description: "Default scope — your Pictures folder.",
            include: .init(
                directories: ["~/Pictures"],
                recursive: true,
                extensions: FormatRegistry.shared.defaultScopeExtensions()
            ),
            exclude: .init(hiddenFiles: true)
        )
    }
}
