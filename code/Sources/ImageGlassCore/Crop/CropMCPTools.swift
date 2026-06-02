import Foundation
import CoreGraphics

/// MCP tool descriptors and dispatch for the crop subsystem.
/// Three tools per `docs/crop.mdx §7`:
///   * `crop_image` — headless file-system crop (`§7.1`).
///   * `get_crop_selection` — read the GUI's current selection (`§7.2`).
///   * `set_crop_selection` — propose a new selection for the GUI (`§7.3`).
///
/// Pattern mirrors `ThemeMCPTools` — surfaced through the top-level
/// `MCPTools` router.
public struct CropMCPTools {

    public static let toolNames: Set<String> = [
        "crop_image",
        "get_crop_selection",
        "set_crop_selection",
    ]

    private let session: CropSession

    public init(session: CropSession = .shared) {
        self.session = session
    }

    // MARK: - Descriptors

    public func descriptors() -> [MCP.ToolDescriptor] {
        [
            .init(
                name: "crop_image",
                description: "Crop an image file to the given rectangle and write the result. JPEG sources can use a lossless MCU-aligned path when lossless_jpeg=true (default). Returns the output path, dimensions, byte count, and the actual rect that was cropped (which may be larger than the requested rect when the lossless path rounded outward to an MCU boundary).",
                inputSchema: AnyCodable([
                    "type": "object",
                    "required": ["input_path", "x", "y", "width", "height"],
                    "properties": [
                        "input_path":  ["type": "string", "description": "Absolute path to the source image."],
                        "x":           ["type": "integer", "minimum": 0],
                        "y":           ["type": "integer", "minimum": 0],
                        "width":       ["type": "integer", "exclusiveMinimum": 0],
                        "height":      ["type": "integer", "exclusiveMinimum": 0],
                        "output_path": ["type": "string", "description": "Where to write. If omitted, writes <basename>_cropped.<ext> next to the source."],
                        "format":      ["type": "string", "enum": ["auto", "jpeg", "png", "webp", "heic", "avif", "tiff"], "default": "auto"],
                        "quality":     ["type": "integer", "minimum": 1, "maximum": 100, "default": 90],
                        "lossless_jpeg":     ["type": "boolean", "default": true],
                        "preserve_metadata": ["type": "boolean", "default": true],
                        "strip_gps":         ["type": "boolean", "default": false],
                    ],
                    "additionalProperties": false,
                ])
            ),
            .init(
                name: "get_crop_selection",
                description: "Read the active crop selection in the GUI, if any. Returns { rect, aspect_ratio, image_path }. rect is null when the crop tool is closed or has no selection.",
                inputSchema: AnyCodable([
                    "type": "object",
                    "properties": [:] as [String: Any],
                    "additionalProperties": false,
                ])
            ),
            .init(
                name: "set_crop_selection",
                description: "Propose a new crop selection in the GUI. The GUI picks the proposal up on its next run-loop tick and switches into idle-with-rect state. Implicitly opens the crop tool if it is closed.",
                inputSchema: AnyCodable([
                    "type": "object",
                    "required": ["x", "y", "width", "height"],
                    "properties": [
                        "x":            ["type": "integer", "minimum": 0],
                        "y":            ["type": "integer", "minimum": 0],
                        "width":        ["type": "integer", "exclusiveMinimum": 0],
                        "height":       ["type": "integer", "exclusiveMinimum": 0],
                        "aspect_ratio": ["type": "string", "description": "Optional SelectionAspectRatio name (FreeRatio, Original, Custom, Ratio1_1, Ratio1_2, Ratio2_1, Ratio2_3, Ratio3_2, Ratio3_4, Ratio4_3, Ratio9_16, Ratio16_9)."],
                    ],
                    "additionalProperties": false,
                ])
            ),
        ]
    }

    // MARK: - Dispatch

    public func call(name: String, arguments: [String: Any?]) throws -> MCP.CallToolResult {
        switch name {
        case "crop_image":         return try cropImage(arguments)
        case "get_crop_selection": return getCropSelection()
        case "set_crop_selection": return try setCropSelection(arguments)
        default:                   return .text("Unknown crop tool: \(name)", isError: true)
        }
    }

    // MARK: - Tool bodies

    private func cropImage(_ args: [String: Any?]) throws -> MCP.CallToolResult {
        let inputPath = try requireString(args, "input_path")
        let x = try requireInt(args, "x")
        let y = try requireInt(args, "y")
        let w = try requireInt(args, "width")
        let h = try requireInt(args, "height")
        guard w > 0, h > 0, x >= 0, y >= 0 else {
            throw MCPToolError.missingArgument("x/y/width/height must be non-negative; width/height > 0")
        }
        let inputURL = URL(fileURLWithPath: AppPaths.expandTilde(inputPath))

        let formatString = (args["format"] as? String) ?? "auto"
        guard let format = CropOutputFormat(rawValue: formatString) else {
            return .text("Unsupported output format: \(formatString)", isError: true)
        }
        let quality = (args["quality"] as? Int) ?? 90
        let losslessJPEG = (args["lossless_jpeg"] as? Bool) ?? true
        let preserveMeta = (args["preserve_metadata"] as? Bool) ?? true
        let stripGPS = (args["strip_gps"] as? Bool) ?? false

        let outputURL: URL
        if let raw = args["output_path"] as? String, !raw.isEmpty {
            outputURL = URL(fileURLWithPath: AppPaths.expandTilde(raw))
        } else {
            outputURL = CropPipeline.defaultCroppedOutputURL(for: inputURL, format: format)
        }

        let rect = CGRect(x: x, y: y, width: w, height: h)
        let options = CropPipeline.Options(
            format: format,
            quality: quality,
            preferLossless: losslessJPEG,
            preserveMetadata: preserveMeta,
            stripGPS: stripGPS
        )
        do {
            let result = try CropPipeline.crop(
                inputURL: inputURL,
                rect: rect,
                outputURL: outputURL,
                options: options
            )
            return .text(prettyJSON(result))
        } catch let e as CropPipeline.Error {
            return .text(e.description, isError: true)
        } catch {
            return .text("crop_image failed: \(error.localizedDescription)", isError: true)
        }
    }

    private func getCropSelection() -> MCP.CallToolResult {
        let s = session.snapshot()
        let rectField: Any
        if let r = s.rect {
            rectField = [Int(r.minX), Int(r.minY), Int(r.width), Int(r.height)]
        } else {
            rectField = NSNull()
        }
        return .text(prettyJSON([
            "rect": rectField,
            "aspect_ratio": s.aspectRatio.rawValue,
            "image_path": s.imagePath ?? NSNull(),
        ] as [String: Any]))
    }

    private func setCropSelection(_ args: [String: Any?]) throws -> MCP.CallToolResult {
        let x = try requireInt(args, "x")
        let y = try requireInt(args, "y")
        let w = try requireInt(args, "width")
        let h = try requireInt(args, "height")
        guard w > 0, h > 0, x >= 0, y >= 0 else {
            throw MCPToolError.missingArgument("x/y/width/height must be non-negative; width/height > 0")
        }
        var aspect: SelectionAspectRatio? = nil
        if let raw = args["aspect_ratio"] as? String, !raw.isEmpty {
            guard let a = SelectionAspectRatio(rawValue: raw) else {
                return .text("Unknown aspect_ratio '\(raw)'. Valid names: \(SelectionAspectRatio.allCases.map(\.rawValue).joined(separator: ", "))", isError: true)
            }
            aspect = a
        }
        let rect = CGRect(x: x, y: y, width: w, height: h)
        session.propose(.init(rect: rect, aspectRatio: aspect))
        // Also reflect into the visible state so an immediate get_ sees it.
        session.setRect(rect)
        if let a = aspect { session.setAspectRatio(a) }
        return .text(prettyJSON([
            "rect": [x, y, w, h],
        ] as [String: Any]))
    }

    // MARK: - Arg helpers

    private func requireString(_ args: [String: Any?], _ key: String) throws -> String {
        guard let raw = args[key], let v = raw as? String, !v.isEmpty else {
            throw MCPToolError.missingArgument(key)
        }
        return v
    }

    private func requireInt(_ args: [String: Any?], _ key: String) throws -> Int {
        if let v = args[key] as? Int { return v }
        if let d = args[key] as? Double { return Int(d) }
        if let s = args[key] as? String, let v = Int(s) { return v }
        throw MCPToolError.missingArgument(key)
    }

    // MARK: - JSON

    private func prettyJSON<T: Encodable>(_ value: T) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(value), let s = String(data: data, encoding: .utf8) {
            return s
        }
        return "{}"
    }

    private func prettyJSON(_ dict: [String: Any]) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]),
           let s = String(data: data, encoding: .utf8) {
            return s
        }
        return "{}"
    }
}
