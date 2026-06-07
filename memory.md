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
