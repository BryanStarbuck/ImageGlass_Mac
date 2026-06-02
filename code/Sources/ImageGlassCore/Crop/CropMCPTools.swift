import Foundation

/// State of the active crop selection in the GUI, persisted to Local Storage
/// so the (out-of-process) MCP server can read and write it.
///
/// Spec reference: `docs/crop.mdx` sections 5.2 / 5.3. The standalone MCP
/// stdio binary cannot dispatch into the GUI's `CropController` directly,
/// so the in-process AppState mirrors the live selection through this small
/// JSON file. The GUI watches the file for external writes and applies them
/// when the user grants permission.
public struct LiveCropSelection: Codable, Equatable, Sendable {
    public var imagePath: String?
    public var sourceWidth: Int
    public var sourceHeight: Int
    public var selection: CropRect?
    public var aspectRatio: String
    public var apply: Bool
    public var updatedAt: Date

    public init(
        imagePath: String? = nil,
        sourceWidth: Int = 0,
        sourceHeight: Int = 0,
        selection: CropRect? = nil,
        aspectRatio: String = "free",
        apply: Bool = false,
        updatedAt: Date = Date()
    ) {
        self.imagePath = imagePath
        self.sourceWidth = sourceWidth
        self.sourceHeight = sourceHeight
        self.selection = selection
        self.aspectRatio = aspectRatio
        self.apply = apply
        self.updatedAt = updatedAt
    }

    public static var fileURL: URL {
        AppPaths.scopesDir.appendingPathComponent("crop-live.json")
    }

    public static func load() -> LiveCropSelection? {
        let url = fileURL
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(LiveCropSelection.self, from: data)
    }

    public static func save(_ live: LiveCropSelection) throws {
        try AppPaths.ensureDirectories()
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try enc.encode(live)
        try data.write(to: fileURL, options: .atomic)
    }
}

/// MCP tool descriptors + dispatchers for the crop subsystem.
/// Glued into the main `MCPTools` switch in `MCPTools.swift`.
public struct CropMCPTools {

    public init() {}

    // MARK: Descriptors

    public func descriptors() -> [MCP.ToolDescriptor] {
        [
            .init(
                name: "crop_image",
                description: "Crops an image file to the given rectangle (in source pixels) and writes the result to a new file or overwrites the input. Metadata (EXIF, ICC, XMP) is preserved unless strip_metadata is true. For JPEG inputs, attempts a lossless transform if the rectangle aligns to MCU boundaries.",
                inputSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "input_path":     ["type": "string"],
                        "x":              ["type": "integer", "minimum": 0],
                        "y":              ["type": "integer", "minimum": 0],
                        "width":          ["type": "integer", "minimum": 1],
                        "height":         ["type": "integer", "minimum": 1],
                        "output_path":    ["type": "string"],
                        "format":         ["type": "string", "enum": ["jpeg","png","heic","avif","webp","tiff","gif","auto"]],
                        "quality":        ["type": "number", "minimum": 0.0, "maximum": 1.0],
                        "lossless_jpeg":  ["type": "boolean"],
                        "strip_metadata": ["type": "boolean"],
                        "overwrite":      ["type": "boolean"],
                    ],
                    "required": ["input_path", "x", "y", "width", "height"],
                    "additionalProperties": false,
                ])
            ),
            .init(
                name: "get_crop_selection",
                description: "Returns the current crop selection in the active ImageGlass window, in source pixels. Returns null if no selection is active.",
                inputSchema: AnyCodable([
                    "type": "object",
                    "properties": [:] as [String: Any],
                    "additionalProperties": false,
                ])
            ),
            .init(
                name: "set_crop_selection",
                description: "Sets the crop selection in the active ImageGlass window. The crop panel opens if it is not already open. Returns the actual selection after clamping and snapping. If apply is true, the GUI applies the crop the next time it reads this file.",
                inputSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "x":      ["type": "integer", "minimum": 0],
                        "y":      ["type": "integer", "minimum": 0],
                        "width":  ["type": "integer", "minimum": 1],
                        "height": ["type": "integer", "minimum": 1],
                        "apply":  ["type": "boolean"],
                    ],
                    "required": ["x", "y", "width", "height"],
                    "additionalProperties": false,
                ])
            ),
            .init(
                name: "read_image_dimensions",
                description: "Returns the pixel width and height of an image file without decoding the pixel data.",
                inputSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "input_path": ["type": "string"],
                    ],
                    "required": ["input_path"],
                    "additionalProperties": false,
                ])
            ),
        ]
    }

    public static let toolNames: Set<String> = [
        "crop_image",
        "get_crop_selection",
        "set_crop_selection",
        "read_image_dimensions",
    ]

    // MARK: Dispatch

    public func call(name: String, arguments: [String: Any?]) throws -> MCP.CallToolResult {
        switch name {
        case "crop_image":          return try cropImage(arguments)
        case "get_crop_selection":  return try getCropSelection(arguments)
        case "set_crop_selection":  return try setCropSelection(arguments)
        case "read_image_dimensions":
            return try readImageDimensions(arguments)
        default:
            return .text("Unknown crop tool: \(name)", isError: true)
        }
    }

    // MARK: - crop_image

    private func cropImage(_ args: [String: Any?]) throws -> MCP.CallToolResult {
        guard let input = args["input_path"] as? String, !input.isEmpty else {
            return .text("Missing 'input_path'", isError: true)
        }
        guard let x = intArg(args, "x"),
              let y = intArg(args, "y"),
              let w = intArg(args, "width"),
              let h = intArg(args, "height") else {
            return .text("Missing or invalid x/y/width/height (integers required).", isError: true)
        }

        let outputPath = args["output_path"] as? String
        let formatStr = (args["format"] as? String) ?? "auto"
        let format = OutputFormat(rawValue: formatStr) ?? .auto
        let quality = (args["quality"] as? Double) ?? 0.92
        let losslessJPEG = (args["lossless_jpeg"] as? Bool) ?? true
        let strip = (args["strip_metadata"] as? Bool) ?? false
        let overwrite = (args["overwrite"] as? Bool) ?? false

        let rect = CropRect(x: x, y: y, width: w, height: h)
        let opts = CropOptions(
            format: format,
            quality: quality,
            losslessJPEG: losslessJPEG,
            stripMetadata: strip,
            overwrite: overwrite
        )

        do {
            let result = try CropPipeline.cropFile(
                inputPath: input,
                rect: rect,
                outputPath: outputPath,
                options: opts
            )
            return .text(prettyJSON([
                "output_path":   result.outputPath,
                "width":         result.width,
                "height":        result.height,
                "format":        result.format.rawValue,
                "bytes_written": result.bytesWritten,
                "lossless_used": result.losslessUsed,
            ] as [String: Any]))
        } catch {
            return .text("crop_image failed: \(error)", isError: true)
        }
    }

    // MARK: - get / set selection

    private func getCropSelection(_ args: [String: Any?]) throws -> MCP.CallToolResult {
        guard let live = LiveCropSelection.load() else {
            return .text(prettyJSON([
                "image_path":   NSNull(),
                "source_width": 0,
                "source_height":0,
                "selection":    NSNull(),
                "aspect_ratio": "free",
            ] as [String: Any]))
        }
        var dict: [String: Any] = [
            "image_path":    live.imagePath ?? "",
            "source_width":  live.sourceWidth,
            "source_height": live.sourceHeight,
            "aspect_ratio":  live.aspectRatio,
        ]
        if let sel = live.selection {
            dict["selection"] = [
                "x": sel.x, "y": sel.y, "width": sel.width, "height": sel.height,
            ]
        } else {
            dict["selection"] = NSNull()
        }
        return .text(prettyJSON(dict))
    }

    private func setCropSelection(_ args: [String: Any?]) throws -> MCP.CallToolResult {
        guard let x = intArg(args, "x"),
              let y = intArg(args, "y"),
              let w = intArg(args, "width"),
              let h = intArg(args, "height") else {
            return .text("Missing or invalid x/y/width/height.", isError: true)
        }
        let apply = (args["apply"] as? Bool) ?? false

        var live = LiveCropSelection.load() ?? LiveCropSelection()
        var rect = CropRect(x: x, y: y, width: w, height: h)
        if live.sourceWidth > 0 && live.sourceHeight > 0 {
            rect = rect.clamped(toSourceWidth: live.sourceWidth, sourceHeight: live.sourceHeight)
        }
        live.selection = rect
        live.apply = apply
        live.updatedAt = Date()
        try LiveCropSelection.save(live)

        return .text(prettyJSON([
            "selection": [
                "x": rect.x, "y": rect.y, "width": rect.width, "height": rect.height,
            ] as [String: Any],
            "applied": apply,
        ] as [String: Any]))
    }

    // MARK: - read_image_dimensions

    private func readImageDimensions(_ args: [String: Any?]) throws -> MCP.CallToolResult {
        guard let input = args["input_path"] as? String, !input.isEmpty else {
            return .text("Missing 'input_path'", isError: true)
        }
        do {
            let (w, h) = try CropPipeline.readDimensions(of: input)
            return .text(prettyJSON([
                "input_path": AppPaths.expandTilde(input),
                "width": w,
                "height": h,
            ] as [String: Any]))
        } catch {
            return .text("read_image_dimensions failed: \(error)", isError: true)
        }
    }

    // MARK: - helpers

    private func intArg(_ args: [String: Any?], _ key: String) -> Int? {
        if let i = args[key] as? Int { return i }
        if let d = args[key] as? Double { return Int(d) }
        return nil
    }

    private func prettyJSON(_ dict: [String: Any]) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]),
           let s = String(data: data, encoding: .utf8) {
            return s
        }
        return "{}"
    }
}
