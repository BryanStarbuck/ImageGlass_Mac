# vendor/

Native library staging directory for ImageGlass_Mac.

**This directory's contents are not checked into git.** Only this README,
`CLAUDE.md`, and `.gitignore` are tracked. The actual libraries are fetched
on demand by `just deps` (run from the repo root). See `CLAUDE.md` in this
directory for the full specification.

## Why a vendor directory at all

ImageGlass_Mac uses Apple's ImageIO for the majority of image formats, but a
few formats need third-party decoders (libvips, ImageMagick, librsvg,
OpenEXR — see the project root `CLAUDE.md` for the list). We do **not**
assume contributors have these installed via Homebrew; the project must be
buildable from a clean clone without polluting the user's system.

`just deps` downloads pinned, signed binaries (or builds from source) into
this directory. The Swift package and the app bundle link against the
copies here, not against `/opt/homebrew/lib`.

## Quick start

```sh
# From the repo root:
just bootstrap   # checks tooling, fetches all vendor deps, runs first build
just deps        # re-fetches vendor deps only
just clean-deps  # removes everything in vendor/ except the tracked files
```

## Why is this directory tracked at all if its contents aren't?

Because contributors need somewhere predictable to drop the libraries
without having to guess a path, and so the `.gitignore` rules travel with
the repo. A `git clone` of ImageGlass_Mac produces a `vendor/` that is
empty-but-present, ready for `just deps` to populate.
