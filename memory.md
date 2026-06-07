# Cross-Machine Compile-Drift Log

This file tracks each time the project breaks when pulled from the **other**
computer, so we can spot patterns over time and harden the code (and the
build/`just` scripts) against the differences. Bryan works on the **desktop**
in U.S. morning/daytime hours and switches to the **laptop** around
4:00–5:30 PM Pacific. Each switch tends to expose a new toolchain delta.

Append new entries at the top. Keep each entry self-contained.

---

## Known environment delta (as of 2026-06-07)

| Aspect | Desktop (this machine) | Laptop |
|---|---|---|
| macOS user | `bryan` | `bryanstarbuck` |
| Project path | `/Users/bryan/BGit/tools_various/ImageGlass_Mac` | `/Users/bryanstarbuck/BGit/tools_local/ImageGlass_Mac` |
| Kernel (`uname -mrs`) | `Darwin 25.5.0 arm64` | (unknown — likely older Darwin/macOS) |
| Swift toolchain | `Apple Swift 6.3.2 (swiftlang-6.3.2.1.108)` | (unknown — older than 6.3, accepts `deinit` access to MainActor state) |
| Compile target triple | `arm64-apple-macosx26.0` (macOS 26 SDK / Xcode 26) | (unknown — almost certainly an earlier macOS SDK) |

**Rule of thumb:** the desktop is the *newer* toolchain. If something compiles
on the laptop and fails here, the most likely cause is that the desktop's
newer Swift enforces a rule the laptop's Swift didn't. Fixes should be
written so they compile on **both** — never `#if swift(>=6.3)`-style splits
when an `assumeIsolated` wrapper or `nonisolated(unsafe)` annotation works
on both compilers.

The username/path drift is already abstracted away — nothing in the
checked-in code references `~bryan` or `~bryanstarbuck` directly; the
justfile uses `$(pwd)` and `.mcp.json` was made portable in commit
`00b647e` ("fix: replace hardcoded MCP path with portable .mcp.json +
wrapper script"). The only place I've seen a hardcoded laptop path
checked in is `out/leak_*.mdx` analysis notes — those are human-written
docs, not built code, so they're harmless drift.

---

## 2026-06-07 07:16 PDT — Deeper analysis: theses on what the two computers actually are

This entry doesn't fix new code. It records the *thesis* behind the
05:12 fix so future entries have a baseline to confirm or refute as
more drift surfaces.

### What we know vs. what we're guessing

**Known (this machine, verified by `swift --version`, `uname -mrs`, `pwd`):**
* macOS user `bryan`, project at `/Users/bryan/BGit/tools_various/ImageGlass_Mac`
* Darwin `25.5.0 arm64` → that's macOS 26 (Sequoia successor) running
  on Apple Silicon
* Swift `6.3.2` (`swiftlang-6.3.2.1.108 clang-2100.1.1.101`)
* Default target triple `arm64-apple-macosx26.0` — i.e. the SDK is
  the macOS 26 SDK that ships with Xcode 26
* Project pinned to `swift-tools-version: 6.0`, `swiftLanguageModes: [.v5]`,
  `platforms: [.macOS(.v14)]`

**Known (laptop, verified from artifacts checked in by the laptop):**
* macOS user `bryanstarbuck` (vs. `bryan` here) — different Apple ID
  username on each machine
* Project path `/Users/bryanstarbuck/BGit/tools_local/ImageGlass_Mac` —
  note **`tools_local`** not `tools_various`. This is a separate
  on-disk root. The path appears hardcoded in
  `out/leak_resource_observer.mdx:11` and
  `out/leak_unbounded_cache.mdx`. Those were authored on the laptop
  and checked in.
* The laptop authored commits `1856ff9`, `8622bf2`, `55b1ff5`, `2241dfb`,
  `1fcd8dc` (timezone offset `+0545` = Asia/Kathmandu / Nepal Time).
  Bryan also commits from Pacific (`-0700`). The Kathmandu-offset
  commits are *not* Bryan's — they're a collaborator (possibly an
  agent or remote contributor running on a different machine entirely).
  This is a third actor we should not conflate with "the laptop."
* The laptop's Swift accepted `deinit` reading `@MainActor` state
  with no error — this rules out Swift 6.2+ in strict mode and most
  likely puts the laptop on Swift 6.0 or 6.1 (Xcode 16.x), maybe
  even Swift 5.10 if it's still on Xcode 15.

**Best-guess thesis on the laptop's stack:**
* macOS 14 (Sonoma) or 15 (Sequoia) — older than the desktop's macOS 26
* Xcode 16.x or earlier — would ship Swift 6.0 / 6.1 by default
* Same Apple Silicon architecture (the universal binary build is for
  arm64+x86_64; nothing in the symptom set has been arch-specific)

### The direction-of-drift pattern

So far, every cross-machine break has the same shape:

```
laptop (older toolchain) ─── commit ───▶ desktop (newer toolchain) → fails
```

The newer Swift on the desktop enforces a rule that the older Swift on
the laptop doesn't. The fix has to compile on **both**, so the right
move is always "satisfy the *stricter* compiler" — that way the
laxer compiler accepts it for free.

We have not yet seen the reverse direction (desktop commits a fix that
the laptop rejects). If/when we do, it'll most likely be: the desktop
used a Swift 6.2+ syntax (`isolated deinit`, typed throws shorthand,
new `~Copyable` syntax, etc.) that the laptop's older parser can't
read. The defense against that is to **prefer pre-existing patterns
already in the codebase** (which is why `MainActor.assumeIsolated`
was the right choice — it's already used in 4+ places, so it's
proven on both machines).

### Why the leak-fix triggered this specifically

Commit `3a2d882` ("Bryan 21") was a leak-cleanup pass driven by three
analysis docs in `out/leak_*.mdx`. The fix for the heartbeat-timer
leak (`out/leak_resource_observer.mdx`) was textually copied from
the doc's "Fix" code block (lines 65–78) straight into `AppState`.
The doc was written naïvely with respect to Swift 6 isolation rules
— it read the leak correctly but proposed code that doesn't compile
on Swift 6.3.

**Lesson:** when the laptop generates an "analysis doc" with a code
block that's meant to be pasted into the codebase, that code block
needs to be vetted against the *newer* compiler's rules before it
gets committed. Otherwise we end up with the laptop fixing a runtime
bug by introducing a compile bug visible only on the desktop.

Two of the three leak-fix docs were authored on the laptop
(`leak_resource_observer.mdx` and `leak_unbounded_cache.mdx` both
embed the laptop's `/Users/bryanstarbuck/...` path). The third
(`leak_retain_cycle.mdx`) uses a project-relative path, so it's
either author-neutral or written on the desktop. The retain-cycle
fix (the `[weak self]` refactor in `reevaluateActive()`) did *not*
trip the desktop build — it was already isolation-clean. Only the
heartbeat/observer fix (the `deinit`) tripped, because only it
touched MainActor-isolated stored properties from a nonisolated
context.

### Predictions for the next drift (so we can check them when it happens)

1. **Tonight, when Bryan switches to the laptop**, the laptop will
   pull the desktop's `MainActor.assumeIsolated`-wrapped deinit and
   should compile fine — `assumeIsolated` was available in Swift 5.9+,
   so it predates both toolchains comfortably.

2. **The `NSMenu` `Sendable` warning** (`ImageCanvasView.swift:162`)
   will become a hard error the day the project flips
   `swiftLanguageModes` from `.v5` to `.v6`. The codebase already
   wraps two NSMenu-returning callsites in `MainActor.assumeIsolated`
   to silence the worse version of this warning; the third callsite
   (line 162) needs the same treatment before the language-mode bump.
   Not urgent, but noted.

3. **The next compile break on either machine is most likely to be
   one of these classes:**
   * Another `deinit` of an `@MainActor` class somewhere else in the
     project (the desktop will catch it).
   * A `Sendable` conformance becoming required at a function
     boundary (the desktop will catch it under
     `-strict-concurrency=complete`).
   * A new Apple SDK API used on the desktop that doesn't exist in
     the laptop's older SDK (the laptop will catch this — first
     reverse-direction break to expect).
   * A `swift package resolve` lockfile mismatch if SwiftPM
     ever generates a `Package.resolved` with a tools-version the
     other machine can't read. Currently `code/.build/` is gitignored
     and `Package.resolved` isn't tracked at the root — check this
     stays true.

### Hardening the `just` scripts (concrete next steps when there's time)

These would have caught the 05:12 break before it shipped from the
laptop. Listed in order of effort:

* **Tighten `check-tools` to enforce a Swift floor.** Today the
  recipe runs `command -v swift` and prints the version. Make it
  parse the major.minor and exit non-zero when below
  `swift_min_version` (currently `"5.10"` and never used). Bump the
  floor to `"6.0"` now that the project requires Swift 6 tooling
  semantics.
* **Add a `just preflight` recipe that runs before every commit.** It
  should: (a) run `check-tools`, (b) run `swift build` with
  `-warnings-as-errors`, (c) run `swift build -Xswiftc
  -strict-concurrency=complete` as a non-fatal "stricter" pass and
  print the diff. The stricter pass is what catches Swift-6-language-mode
  errors before the language-mode bump.
* **Add a `just deps-check` recipe** that, for every native library
  the project will eventually link (libvips, ImageMagick, librsvg,
  OpenEXR — see `CLAUDE.md` "Image Decoding"), checks `vendor/<name>/`
  before relying on Homebrew. Right now `deps-vendor` is a no-op
  (`echo "(no native libraries yet — see vendor/CLAUDE.md)"`). The
  moment the first non-ImageIO decoder lands, this becomes the
  next class of cross-machine drift: one machine has the dylib in
  `vendor/`, the other expects `brew install vips` to be on PATH.
  Wire `deps-libvips` etc. as recipes that download into
  `vendor/<name>/` so neither machine depends on Homebrew state.
* **Stop hardcoding absolute paths in checked-in `out/leak_*.mdx`
  docs.** Two of those three docs embed `/Users/bryanstarbuck/...`.
  Replace with project-relative paths (`code/Sources/...`) when
  writing future analysis docs — this is a doc-hygiene rule, not a
  build break, but it's the same kind of leak.

### Open questions to confirm later

* What macOS version is the laptop actually on? (Need a `sw_vers`
  output committed somewhere, or a `just diag` recipe that prints
  the env to stdout for paste-into-memory-log.)
* What Xcode version? (`xcodebuild -version`)
* Is the laptop ever building on x86_64? The project's release
  recipe is `swift build -c release --arch arm64 --arch x86_64` —
  the universal flag — but day-to-day `just build` is arm64-only on
  whichever machine runs it. No drift here yet, but worth noting.

A **`just diag`** recipe that dumps `sw_vers`, `xcodebuild -version`,
`swift --version`, `uname -mrs`, `pwd`, and any installed Homebrew
formulae we depend on, into `out/diag_<hostname>_<date>.txt`, would
let us check that file into git from each machine and converge this
table from "(unknown)" to actual data. Strongest single intervention
for the future of this log.

---

## 2026-06-07 05:12 PDT — Desktop: `deinit` can't touch MainActor state

**Symptom (this machine).** After pulling commit `3a2d882` ("Bryan 21"),
`just build` failed with four hard errors and a warning:

```
AppState.swift:291: error: main actor-isolated property 'heartbeatTimer'
                    can not be referenced from a nonisolated context
AppState.swift:292: error: ... 'directoriesChangedToken' ...
AppState.swift:295: error: ... 'firstImageFoundToken' ...
AppState.swift:298: error: ... 'directoryDidChangeToken' ...
ImageCanvasView.swift:162: warning: conformance of 'NSMenu' to 'Sendable'
                    is unavailable; this is an error in the Swift 6 language mode
```

The errors all point at the new `deinit` block that commit `3a2d882`
added to `AppState` (`code/Sources/ImageGlass/AppState.swift`). The
class is annotated `@MainActor @Observable public final class AppState`,
the storage being touched is MainActor-isolated, and the deinit reads
those properties directly.

**Why the laptop compiled it but the desktop didn't.** Swift 6.x (the
exact threshold is around 6.2; this machine is **6.3.2**, target
`arm64-apple-macosx26.0`) tightened the isolation rules so that `deinit`
of a `@MainActor` class is **implicitly nonisolated**. Reading a
MainActor-isolated stored property from inside such a deinit is a hard
error. Older Swift — what the laptop is still running — inherited the
class's `@MainActor` isolation into `deinit` and let the same code
compile. The `Sendable` warning on `NSMenu` is the same family of
change (the project is in Swift 5 language mode, so it's still just a
warning here — it'll become an error the next time the laptop's
toolchain catches up).

The laptop was the source of commit `3a2d882`: it (1) added the
`deinit` to fix a real `Timer` + observer-token leak documented in
`out/leak_resource_observer.mdx`, and (2) checked it in. The fix was
correct on the laptop's toolchain. It just didn't survive the upgrade
to the desktop's stricter compiler.

**Root cause.** Toolchain skew — Swift 6.3.2 on the desktop vs.
something earlier (probably 6.0/6.1) on the laptop — combined with a
genuine Swift evolution change (implicit `deinit` isolation removed for
`@MainActor` classes).

**Fix (portable — compiles on both toolchains).** Wrapped the deinit
body in `MainActor.assumeIsolated { ... }`. This is the same pattern
already used elsewhere in the codebase (`AboutWindow.swift`,
`ImageCanvasView.swift`, `WindowStateController.swift`,
`WindowRegistryBootstrap.swift`). The wrapper:

* Compiles on older Swift (where it's effectively redundant) and on
  Swift 6.3+ (where it's required to access MainActor state from a
  nonisolated deinit).
* Is runtime-safe in practice: `AppState` is an `@Observable @MainActor`
  singleton owned by SwiftUI; its last release happens on the main
  thread, which is what `assumeIsolated` requires.

Left an in-file comment explaining the toolchain delta so the next time
this code is touched on the laptop, the author doesn't strip the wrapper
thinking it's redundant.

**File touched.** `code/Sources/ImageGlass/AppState.swift` — replaced
the `deinit` block at line ~290.

**Verified.** `just build` → `Build complete! (6.84s)`. Only the
pre-existing `NSMenu`/`Sendable` warning remains; not blocking.

**Open hardening ideas (not done yet).**

1. **Bake a `swift --version` floor into `check-tools`.** Right now the
   justfile only checks that `swift` exists. A `swift_min_version` is
   declared at the top of the file (`5.10`) but never enforced. If we
   parse `swift --version` and refuse to build when the minor version
   is older than, say, 6.0, the laptop will fail loudly before it ships
   another commit that only compiles on the older toolchain.
2. **Add a "compile on both" CI smoke target.** A `just build-strict`
   recipe that adds `-strict-concurrency=complete` would catch
   future occurrences of this exact class of regression — the desktop
   would fail in `build-strict` before either machine pushes.
3. **Sweep the rest of `AppState`'s lifecycle hooks** for the same
   pattern: any `@MainActor` class with stored timers/observers needs
   either an `assumeIsolated`-wrapped deinit or `nonisolated(unsafe)`
   storage. None tripped this build, but the next Swift bump (or
   enabling Swift 6 language mode in `Package.swift`) will surface
   them all at once.

---

(Add the next entry above this line.)
