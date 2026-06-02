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
pkg := "code"

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

# Build everything (debug).
build:
    cd {{pkg}} && swift build

# Build everything (release).
build-release:
    cd {{pkg}} && swift build -c release

# Launch the SwiftUI app (debug).
run:
    cd {{pkg}} && swift run ImageGlass

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
# Housekeeping.
# ---------------------------------------------------------------------------

# Remove build artifacts (keeps vendor/ intact — use clean-deps for that).
clean:
    cd {{pkg}} && swift package clean
    rm -rf {{pkg}}/.build {{pkg}}/.swiftpm

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
