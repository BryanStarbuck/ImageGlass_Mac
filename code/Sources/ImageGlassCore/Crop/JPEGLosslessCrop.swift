import Foundation

/// JPEG MCU (Minimum Coded Unit) detection and alignment math.
///
/// Spec reference: `docs/crop.mdx` section 3.3. A JPEG can be cropped without
/// re-encoding iff both crop corners land on MCU boundaries (8×8 for 4:4:4,
/// 16×16 for 4:2:0 chroma-subsampled JPEGs).
///
/// **Status (Mac fork v1):** the *true* lossless transform path documented
/// in the spec requires `libjpeg-turbo`'s `tjtransform()` API. We do NOT
/// vendor `libjpeg-turbo` (no Homebrew or system deps) in the current
/// build; the actual byte-preserving crop path is therefore **not yet
/// implemented**, and `CropPipeline` falls back to the Image I/O
/// re-encode path. This file still exposes the alignment math + MCU
/// detection so the pipeline can:
///   * surface the dashed "lossless-rounded" outline in the UI,
///   * report `lossless_used: false` from MCP, and
///   * round selection edges outward when callers opt in to the rounded
///     rectangle.
public enum JPEGLosslessCrop {

    /// MCU detection result for a JPEG.
    public struct MCUInfo: Equatable, Sendable {
        public let mcuWidth: Int   // 8 or 16
        public let mcuHeight: Int  // 8 or 16
        /// True iff the chroma is sub-sampled (4:2:0 or similar).
        public let chromaSubsampled: Bool
    }

    /// Parse the JPEG SOF0/SOF2 marker to derive the MCU dimensions.
    /// Returns nil for non-JPEG inputs.
    ///
    /// Format reference: SOF marker `FF C0` (or `FF C2` for progressive)
    /// followed by `len(2) precision(1) height(2) width(2) numComponents(1)`,
    /// then per-component `id(1) samplingFactors(1) qTable(1)`. The Y
    /// component's high-nibble = horizontal sampling factor, low-nibble =
    /// vertical sampling factor. MCU = (8 * Hmax, 8 * Vmax).
    public static func detectMCU(jpegData: Data) -> MCUInfo? {
        guard jpegData.count > 4 else { return nil }
        guard jpegData[0] == 0xFF, jpegData[1] == 0xD8 else { return nil }

        var i = 2
        while i + 3 < jpegData.count {
            guard jpegData[i] == 0xFF else { return nil }
            // Skip fill bytes.
            var marker = jpegData[i + 1]
            while marker == 0xFF, i + 2 < jpegData.count {
                i += 1
                marker = jpegData[i + 1]
            }
            i += 2

            // Markers without a length field.
            if marker == 0xD8 || marker == 0xD9 || (marker >= 0xD0 && marker <= 0xD7) {
                continue
            }

            guard i + 1 < jpegData.count else { return nil }
            let segLen = (Int(jpegData[i]) << 8) | Int(jpegData[i + 1])
            guard segLen >= 2, i + segLen <= jpegData.count else { return nil }

            // SOF markers are 0xC0...0xCF except 0xC4 (DHT), 0xC8 (JPG), 0xCC (DAC).
            let isSOF = (marker >= 0xC0 && marker <= 0xCF)
                     && marker != 0xC4 && marker != 0xC8 && marker != 0xCC
            if isSOF {
                // Layout: segLen(2 already counted) precision(1) h(2) w(2) numC(1) then components.
                let base = i + 2 // skip the length field itself
                guard base + 6 <= jpegData.count else { return nil }
                let numComponents = Int(jpegData[base + 5])
                guard numComponents >= 1 else { return nil }

                var maxH = 1, maxV = 1
                for c in 0..<numComponents {
                    let off = base + 6 + c * 3
                    guard off + 2 < jpegData.count else { return nil }
                    let factors = jpegData[off + 1]
                    let h = Int((factors & 0xF0) >> 4)
                    let v = Int(factors & 0x0F)
                    maxH = max(maxH, h)
                    maxV = max(maxV, v)
                }
                let mw = 8 * maxH
                let mh = 8 * maxV
                let subsampled = (maxH > 1 || maxV > 1)
                return MCUInfo(mcuWidth: mw, mcuHeight: mh, chromaSubsampled: subsampled)
            }
            i += segLen
        }
        return nil
    }

    /// Round a crop rectangle **outward** to the next MCU boundary.
    /// Bottom/right edges are also rounded up but capped at the source size.
    public static func roundToMCU(
        _ rect: CropRect,
        mcu: MCUInfo,
        sourceWidth: Int,
        sourceHeight: Int
    ) -> CropRect {
        let mw = max(1, mcu.mcuWidth)
        let mh = max(1, mcu.mcuHeight)

        // Round x/y *down* and right/bottom *up* to grow the rect outward.
        let x0 = (rect.x / mw) * mw
        let y0 = (rect.y / mh) * mh
        let right = rect.x + rect.width
        let bottom = rect.y + rect.height
        let x1 = min(sourceWidth, ((right + mw - 1) / mw) * mw)
        let y1 = min(sourceHeight, ((bottom + mh - 1) / mh) * mh)

        return CropRect(x: x0, y: y0, width: max(0, x1 - x0), height: max(0, y1 - y0))
    }

    /// True iff the rectangle is already MCU-aligned on all four edges.
    public static func isAligned(_ rect: CropRect, mcu: MCUInfo, sourceWidth: Int, sourceHeight: Int) -> Bool {
        let mw = max(1, mcu.mcuWidth)
        let mh = max(1, mcu.mcuHeight)
        let leftOK   = rect.x % mw == 0
        let topOK    = rect.y % mh == 0
        let right    = rect.x + rect.width
        let bottom   = rect.y + rect.height
        let rightOK  = (right % mw == 0) || right == sourceWidth
        let bottomOK = (bottom % mh == 0) || bottom == sourceHeight
        return leftOK && topOK && rightOK && bottomOK
    }
}
