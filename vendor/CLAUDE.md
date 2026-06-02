# vendor/ — native dependency specification

This file is the source of truth for what libraries ImageGlass_Mac depends
on outside of Apple's SDKs and the Swift Package Manager registry. Every
entry below is fetched by `just deps` into a sibling subdirectory of this
file.

## Layout

```
vendor/
├── .gitignore        # ignores everything except the three tracked files
├── README.md         # human-facing description
├── CLAUDE.md         # this file — the spec
├── libvips/          # populated by `just deps`, gitignored
├── imagemagick/      # populated by `just deps`, gitignored
├── librsvg/          # populated by `just deps`, gitignored
└── openexr/          # populated by `just deps`, gitignored
```

Each library directory holds:
* `include/` — public headers consumed by the Swift package
* `lib/` — `.dylib` / `.a` files, signed for Apple distribution
* `LICENSE` — the library's own license text (kept alongside the binary)
* `VERSION` — a single line with the pinned upstream version tag

The Swift package's `Package.swift` references these paths via
`unsafeFlags(["-L", "vendor/<name>/lib"])` and a system-library target.

## Current dependencies

| Name | Version | License | Source | Status |
|------|---------|---------|--------|--------|
| (none yet) | — | — | — | — |

The fork's current Swift sources only use Apple frameworks (ImageIO, Core
Graphics, Core Image, Metal, AppKit, SwiftUI, Foundation). Native vendor
libraries come online when the `ImageDecoder` protocol gets its first
non-ImageIO backend — at that point, the table above is updated and a new
`just deps` recipe is added for each library.

## Planned dependencies (not yet wired in)

The root `CLAUDE.md` lists these as candidates for the `ImageDecoder`
protocol. None of them are required for the app to build today.

* **libvips** — fast streaming decoder for very large images.
  License: LGPL-2.1 (GPL-v3-compatible). Upstream:
  https://github.com/libvips/libvips
* **ImageMagick** (Magick++ / MagickWand) — broad format coverage.
  License: ImageMagick license (Apache-2.0-style, GPL-v3-compatible).
  Upstream: https://github.com/ImageMagick/ImageMagick
* **librsvg** — full SVG rendering. License: LGPL-2.1. Upstream:
  https://gitlab.gnome.org/GNOME/librsvg
* **OpenEXR** — HDR `.exr` files. License: BSD-3-Clause. Upstream:
  https://github.com/AcademySoftwareFoundation/openexr

## How to add a new vendored library

1. Add a row to the **Current dependencies** table above.
2. Add a recipe to the root `justfile` named `deps-<name>` that downloads
   the pinned release tarball, verifies its SHA-256, extracts to
   `vendor/<name>/`, and writes `vendor/<name>/VERSION`.
3. Have the top-level `deps` recipe call `deps-<name>`.
4. Add a system-library target to `code/Package.swift` pointing at
   `vendor/<name>/include` and `vendor/<name>/lib`.
5. Sign the dylib for the app bundle in the `app` recipe (`codesign` with
   the Developer ID).
6. Document the integration in `code/Sources/ImageGlassCore/Decoders/`.

## Why not just use Homebrew?

* Homebrew installs to `/opt/homebrew` (Apple Silicon) or `/usr/local`
  (Intel), which contributors may not have, may have at the wrong version,
  or may have built with the wrong flags.
* Distributing a `.dmg` requires the dylibs to live inside the app bundle
  with the right install names (`@rpath/libfoo.dylib`), code-signed by us.
* CI and notarization must reproduce identical binaries across machines —
  Homebrew's rolling-release model makes that unreliable.

`just deps` pins exact versions and exact hashes, so every clone produces
an identical `vendor/` tree.
