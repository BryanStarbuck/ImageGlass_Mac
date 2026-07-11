# ImageGlass_Mac — task runner.
#
# Run `just` (no args) to see the recipe list. Run `just bootstrap` on a
# fresh clone to install everything needed to build.
#
# Requirements on the host machine:
#   * macOS 14 (Sonoma) or later
#   * Xcode 16+ command-line tools (`xcode-select --install`)
#   * just (`brew install just`)
#
# Everything else is fetched into the repo by recipes below.

set shell := ["bash", "-euo", "pipefail", "-c"]

# Pin tool versions in one place so contributors get reproducible builds.
swift_min_version := "5.10"

# Where the Swift package lives. Kept in a subdirectory so the repo root
# can host the justfile, vendor/, docs/, etc. without confusing SwiftPM.
#
# `just` already resolves the nearest justfile when invoked from a
# subdirectory (e.g. from `pm/`) and runs recipes with the working
# directory set to this justfile's directory — so `just build` / `just
# run` work from the repo root AND from any subdirectory. Anchoring the
# package path to `justfile_directory()` makes that absolute and
# invocation-directory-independent, so it keeps working even under
# `just --working-directory …` or when a recipe is called from another
# recipe.
pkg := justfile_directory() / "code"

# Default recipe: print the list.
default:
    @just --list --unsorted

# ---------------------------------------------------------------------------
# Bootstrap — what a brand-new contributor runs once.
# ---------------------------------------------------------------------------

# Verify host tooling, fetch all dependencies, do a first build.
bootstrap: check-tools deps build
    @echo
    @echo "  ImageGlass_Mac is ready. Try:"
    @echo "    just run        # launch the app"
    @echo "    just mcp        # launch the MCP server on stdio"
    @echo "    just test       # run the test suite"
    @echo
    @echo "  MCP registration:"
    @echo "    The project ships .mcp.json — Claude Code picks it up automatically."
    @echo "    If you need to re-register manually: just mcp-register"
    @echo

# Register the imageglass-mcp server with Claude Code using the current
# repo path. .mcp.json handles this automatically on new machines; run
# this only if the registration somehow gets stale.
mcp-register:
    @echo "==> registering imageglass-mcp with Claude Code"
    claude mcp add imageglass-mcp \
        --transport stdio \
        "$(pwd)/scripts/mcp-server.sh"
    @echo "==> done — restart Claude Code to pick up the new registration"

# Print the versions of every required tool. Fails fast on a missing one.
check-tools:
    @echo "==> checking host tooling"
    @command -v swift >/dev/null || { echo "missing: swift (install Xcode command-line tools)"; exit 1; }
    @swift --version | head -n1
    @command -v xcrun >/dev/null || { echo "missing: xcrun (install Xcode command-line tools)"; exit 1; }
    @command -v curl >/dev/null  || { echo "missing: curl"; exit 1; }
    @command -v shasum >/dev/null|| { echo "missing: shasum"; exit 1; }
    @echo "==> host tooling OK"

# ---------------------------------------------------------------------------
# Dependencies.
# ---------------------------------------------------------------------------

# Fetch all dependencies (SwiftPM + native libraries in vendor/).
deps: deps-swiftpm deps-vendor

# Resolve SwiftPM dependencies (cached in code/.build, gitignored).
deps-swiftpm:
    @echo "==> resolving SwiftPM dependencies"
    cd {{pkg}} && swift package resolve

# Fetch native libraries into vendor/<name>/. See vendor/CLAUDE.md.
deps-vendor:
    @echo "==> fetching native vendor libraries"
    @# No native libraries are wired into the build yet. When the first
    @# non-ImageIO decoder lands, add `just deps-libvips` (etc.) here and
    @# add the matching recipe below. See vendor/CLAUDE.md for the full
    @# procedure.
    @echo "    (no native libraries yet — see vendor/CLAUDE.md)"

# Remove everything in vendor/ except the tracked files.
clean-deps:
    @echo "==> wiping vendor/"
    @find vendor -mindepth 1 -maxdepth 1 \
        ! -name '.gitignore' \
        ! -name 'README.md' \
        ! -name 'CLAUDE.md' \
        -exec rm -rf {} +

# ---------------------------------------------------------------------------
# Build, run, test.
# ---------------------------------------------------------------------------

# Build everything (debug). Kills any running ImageGlass first so the
# build never fights a live process holding the binary, matching the
# `run` recipe's kill-then-act contract.
build:
    @echo "==> killing any existing ImageGlass process"
    @pkill -x ImageGlass || true
    cd {{pkg}} && swift build

# Build everything (release).
build-release:
    cd {{pkg}} && swift build -c release

# Build a release universal binary (arm64 + x86_64).
# Required for distributing a single ImageGlass.app that runs on both
# Apple Silicon and Intel Macs per ../CLAUDE.md "Architectures: arm64 +
# x86_64 universal binary".
build-universal:
    cd {{pkg}} && swift build -c release --arch arm64 --arch x86_64

# Launch the SwiftUI app (debug). Kills any prior instance, builds, then
# launches detached so the terminal returns immediately.
run:
    @echo "==> killing any existing ImageGlass process"
    @pkill -x ImageGlass || true
    @echo "==> building"
    cd {{pkg}} && swift build --product ImageGlass
    @echo "==> launching"
    @nohup "{{pkg}}/.build/debug/ImageGlass" >/dev/null 2>&1 & echo "==> launched (pid $!)"

# Open code/Package.swift in Xcode and start a debug session on the
# ImageGlass scheme. Xcode owns the run from this point — set
# breakpoints, step, inspect variables, etc. in Xcode's debugger.
# First open on a fresh clone can take ~30s while Xcode indexes the
# package before the debug session starts.
debug:
    @echo "==> killing any existing ImageGlass process"
    @pkill -x ImageGlass || true
    @echo "==> opening {{pkg}}/Package.swift in Xcode and starting debugger"
    @osascript \
        -e 'set pkgPath to "{{pkg}}/Package.swift"' \
        -e 'tell application "Xcode"' \
        -e '  activate' \
        -e '  open pkgPath' \
        -e '  set waited to 0' \
        -e '  repeat until (exists workspace document 1) and (loaded of workspace document 1)' \
        -e '    delay 1' \
        -e '    set waited to waited + 1' \
        -e '    if waited > 240 then error "Xcode never finished loading the package (waited 240s)"' \
        -e '  end repeat' \
        -e '  set theWorkspace to workspace document 1' \
        -e '  try' \
        -e '    set active scheme of theWorkspace to (first scheme of theWorkspace whose name is "ImageGlass")' \
        -e '  end try' \
        -e '  debug theWorkspace' \
        -e 'end tell'

# Launch the MCP server on stdio (debug).
mcp:
    cd {{pkg}} && swift run imageglass-mcp

# Run the whole test suite.
test:
    cd {{pkg}} && swift test

# Run tests with verbose output (useful in CI).
test-verbose:
    cd {{pkg}} && swift test --verbose

# ---------------------------------------------------------------------------
# Packaging — release bundle and DMG.
#
# These recipes produce a distributable .app bundle and a .dmg from the
# universal binary. Code signing + notarization are intentionally separate
# steps (`sign`, `notarize`) so contributors without a Developer ID
# certificate can still build a local .app and .dmg.
# ---------------------------------------------------------------------------

# Output directories (gitignored; see .gitignore).
dist_dir := "dist"
app_name := "ImageGlass.app"

# Stage a release .app bundle from the universal binary into dist/.
# Run `just build-universal` first.
bundle: build-universal
    @echo "==> staging {{app_name}} into {{dist_dir}}/"
    @rm -rf "{{dist_dir}}/{{app_name}}"
    @mkdir -p "{{dist_dir}}/{{app_name}}/Contents/MacOS"
    @mkdir -p "{{dist_dir}}/{{app_name}}/Contents/Resources"
    @cp "{{pkg}}/.build/apple/Products/Release/ImageGlass" \
        "{{dist_dir}}/{{app_name}}/Contents/MacOS/ImageGlass"
    @cp "{{pkg}}/.build/apple/Products/Release/imageglass-mcp" \
        "{{dist_dir}}/{{app_name}}/Contents/MacOS/imageglass-mcp" || true
    @# Minimal Info.plist so Finder recognizes the bundle. A full plist
    @# (UTIs, document types, hardened-runtime entitlements) lives in the
    @# Xcode project once that's added — this is just enough to launch.
    @printf '%s\n' \
        '<?xml version="1.0" encoding="UTF-8"?>' \
        '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
        '<plist version="1.0"><dict>' \
        '  <key>CFBundleExecutable</key><string>ImageGlass</string>' \
        '  <key>CFBundleIdentifier</key><string>org.imageglass.mac</string>' \
        '  <key>CFBundleName</key><string>ImageGlass</string>' \
        '  <key>CFBundlePackageType</key><string>APPL</string>' \
        '  <key>CFBundleShortVersionString</key><string>0.1.0</string>' \
        '  <key>CFBundleVersion</key><string>0.1.0</string>' \
        '  <key>LSMinimumSystemVersion</key><string>14.0</string>' \
        '</dict></plist>' \
        > "{{dist_dir}}/{{app_name}}/Contents/Info.plist"
    @echo "==> {{dist_dir}}/{{app_name}} ready"

# Codesign the staged bundle with the supplied Developer ID identity.
# Usage:  just sign "Developer ID Application: Your Name (TEAMID)"
sign identity: bundle
    @echo "==> codesigning {{app_name}} with: {{identity}}"
    codesign --force --deep --options runtime --timestamp \
        --sign "{{identity}}" \
        "{{dist_dir}}/{{app_name}}"
    codesign --verify --deep --strict --verbose=2 "{{dist_dir}}/{{app_name}}"

# Build a .dmg from the staged bundle.
# Run `just bundle` (and ideally `just sign ...`) first.
dmg: bundle
    @echo "==> building ImageGlass.dmg"
    @rm -f "{{dist_dir}}/ImageGlass.dmg"
    hdiutil create -volname ImageGlass \
        -srcfolder "{{dist_dir}}/{{app_name}}" \
        -ov -format UDZO \
        "{{dist_dir}}/ImageGlass.dmg"
    @echo "==> {{dist_dir}}/ImageGlass.dmg ready"

# Notarize the DMG. Requires an Apple notary keychain profile.
# Usage:  just notarize my-notary-profile
notarize profile: dmg
    @echo "==> submitting ImageGlass.dmg to Apple notary service"
    xcrun notarytool submit "{{dist_dir}}/ImageGlass.dmg" \
        --keychain-profile "{{profile}}" --wait
    xcrun stapler staple "{{dist_dir}}/ImageGlass.dmg"

# ---------------------------------------------------------------------------
# Housekeeping.
# ---------------------------------------------------------------------------

# Remove build artifacts (keeps vendor/ intact — use clean-deps for that).
clean:
    cd {{pkg}} && swift package clean
    rm -rf {{pkg}}/.build {{pkg}}/.swiftpm {{dist_dir}}

# Nuke everything fetched or built. Equivalent to a fresh clone state.
distclean: clean clean-deps
    @echo "==> repo is back to checked-in state"

# Format Swift sources (swift-format ships with Xcode 16+).
fmt:
    @if command -v swift-format >/dev/null; then \
        swift-format format --in-place --recursive {{pkg}}/Sources {{pkg}}/Tests; \
    else \
        echo "swift-format not found — install Xcode 16+ or run:"; \
        echo "  xcrun --find swift-format"; \
        exit 1; \
    fi

# Lint Swift sources without modifying them.
lint:
    @if command -v swift-format >/dev/null; then \
        swift-format lint --recursive {{pkg}}/Sources {{pkg}}/Tests; \
    else \
        echo "swift-format not found"; exit 1; \
    fi

# Show what would be checked into git on a `git add .` from a fresh clone.
preview-add:
    @git status --short --untracked-files=all
