import SwiftUI
import AppKit
import ImageGlassCore

/// A single thumbnail item used by Strip, Grid, and (small variant) Details/Tree.
/// Pulls thumbnails from the shared `ThumbnailCache` actor on `.onAppear`,
/// releases the SwiftUI image on `.onDisappear` (spec §6.6 — memory budget).
struct FileListItemView: View {
    let entry: FileEntry
    /// Max-side, in pixels, of the requested thumbnail.
    let pixelSide: Int
    /// Layout side, in pt. May differ from pixelSide (e.g. Strip 96/Details 24).
    let pointSide: CGFloat

    /// Whether this item is currently selected.
    let isSelected: Bool
    /// Whether this item is the focused item (keyboard cursor).
    let isFocused: Bool
    /// Show filename below the thumb? (Grid yes, Strip no.)
    let showsLabel: Bool

    @State private var image: NSImage?
    @State private var didFailDecode = false

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color(nsColor: .underPageBackgroundColor))

                if let img = image {
                    Image(nsImage: img)
                        .resizable()
                        .interpolation(.medium)
                        .scaledToFit()
                        .frame(width: pointSide, height: pointSide)
                } else if didFailDecode {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: entry.url.path))
                        .resizable()
                        .scaledToFit()
                        .frame(width: pointSide * 0.6, height: pointSide * 0.6)
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .opacity(0.5)
                }

                // Badges (spec §4.2)
                VStack {
                    Spacer()
                    HStack(spacing: 2) {
                        Spacer()
                        ForEach(badges, id: \.self) { sym in
                            Image(systemName: sym)
                                .font(.system(size: max(8, pointSide * 0.10), weight: .bold))
                                .foregroundStyle(.white)
                                .shadow(radius: 1)
                        }
                    }
                    .padding(.horizontal, 3)
                    .padding(.bottom, 2)
                }
            }
            .frame(width: pointSide, height: pointSide)
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(borderColor, lineWidth: isSelected ? 2 : (isFocused ? 1.5 : 0.5))
            )
            .contentShape(Rectangle())

            if showsLabel {
                Text(entry.name)
                    .font(.system(size: 10))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: pointSide)
                    .help(entry.name)
            }
        }
        .help(entry.name)
        .task(id: entry.path + "|" + String(pixelSide)) {
            await loadThumbnail()
        }
        .onDisappear {
            // Spec §6.6 — drop SwiftUI's retained copy when cell scrolls off.
            image = nil
        }
    }

    private var badges: [String] {
        var out: [String] = []
        if entry.isAnimated { out.append("play.circle.fill") }
        if entry.isRAW { out.append("camera.aperture") }
        return out
    }

    private var borderColor: Color {
        if isSelected { return .accentColor }
        if isFocused { return .accentColor.opacity(0.5) }
        return .clear
    }

    @MainActor
    private func loadThumbnail() async {
        guard entry.isImageLike else {
            didFailDecode = true
            return
        }
        let url = entry.url
        let side = pixelSide
        let cg = await ThumbnailCache.shared.thumbnail(for: url, maxSide: side)
        guard let cg = cg else {
            didFailDecode = true
            return
        }
        image = NSImage(cgImage: cg, size: .zero)
    }
}
