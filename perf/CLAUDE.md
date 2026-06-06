# perf/ — Performance Hunt

PERF_DIR is dir `~/BGit/tools_various/ImageGlass_Mac/perf/`

This directory exists to hunt down performance problems in ImageGlass_Mac by analyzing a captured run of the app. The goal is to find:

* Where wall-clock time is being spent (which actions dominate total elapsed time).
* Which individual calls are taking too long (high `max_elapsed_ms` outliers, slow averages).
* Which work is happening on the main thread that should be moved to a background thread (anything that blocks UI responsiveness — large directory walks, image decode, file-watcher batches, slideshow advance, etc.).
* How much of the slowdown is self-inflicted by excessive logging volume itself (the log is 1.4 GB / 7.5M lines for one session — the act of writing it is part of the perf problem).

## Files

* `performance.snapshot.log` — Captured perf log from a real app run. Format is one event per line, space-separated `key=value` pairs, e.g. `ts=2026-06-05T19:25:33.790Z phase=start action=MCP.ToolCall.add_directory instance=1 corr=21d0e98d`. Events come in matched `phase=start` / `phase=finish` pairs correlated by `corr=`; the `finish` line carries `elapsed_ms=N`. **NEVER modify or rewrite this file.** It is the input evidence; treat it as read-only. It is gitignored due to size.
* `parse_perf.js` — Node.js stream parser. Reads the log line-by-line (no full load — uses `fs.createReadStream` + `readline`), aggregates by `action` over `phase=finish` records, and emits a CSV of `action, instance_count, avg_elapsed_ms, total_elapsed_ms, min_elapsed_ms, max_elapsed_ms` sorted by instance count. Also prints a top-15-by-count summary to stdout.
  Usage: `node parse_perf.js performance.snapshot.log perf_report.csv`
* `perf_report.csv` — Aggregated output of `parse_perf.js`. This is the working spreadsheet for the perf hunt. If empty or missing, regenerate by running the parser against the log.
* `.gitkeep` — Keeps the directory present in git even when the large log and generated CSV are ignored.

## Workflow

1. Confirm `perf_report.csv` has rows. If empty, run `node parse_perf.js performance.snapshot.log` to regenerate it.
2. Read `perf_report.csv`. Re-sort mentally by `total_elapsed_ms` (biggest time sinks), then by `max_elapsed_ms` (worst single-call outliers), then by `instance_count` (chatty actions inflating log volume and overhead).
3. For each suspect action, cross-reference the action name back to the Swift source under `~/BGit/tools_various/ImageGlass_Mac/` to find where it is emitted, whether it runs on the main thread, and whether it can be moved off-thread, batched, cached, or eliminated.
4. Pay special attention to actions whose `instance_count` is in the millions — those are candidates for log-level demotion or removal regardless of per-call time, because the sheer logging cost is a perf problem on its own.

## What the current snapshot is telling us (June 5 2026 capture)

Headline offenders in `perf_report.csv` from this run, worth investigating first:

* `DirectoryWalk.SingleDir` — 2.85M instances, total ~135M ms (~37.7 hours of wall time across the run), max single call 884,237 ms (~14.7 min). This single action dominates everything. Likely culprits: repeated re-walks of the same directory, no caching, and/or running on the main thread.
* `DirectoryWalk.Parallel` — only 21 instances but avg 630,501 ms (~10.5 min) and max 1,081,730 ms (~18 min). Long-running batch work — confirm it is actually off the main thread and that progress is reportable/cancellable.
* `DirectoryWalk.Run` — 6 instances, avg 21,291 ms. Same family, same questions.
* `Tree.Traverse.Log` — 888K instances. The name itself implies this is a log-emitting traversal; this is a strong "the logging is the problem" candidate.
* `Slideshow.Advance` — 73 instances, avg 5,557 ms, max 42,881 ms (~43 s for a single slideshow step). Almost certainly main-thread image work; should decode/prefetch off-thread.
* `Image.Load` / `Image.Decode` — avg 69.5 ms / 50.8 ms. Individually not catastrophic but should be background-thread + prefetched, never on the UI thread during navigation.
* `FileWatcher.EventBatch` — 68 instances, avg 269 ms, min 250 ms. Suspicious floor — looks like a fixed debounce/sleep rather than real work. Verify.
* `LocalStorage.*` family — thousands of YAML encode/decode/read/write events. Hot path; consider in-memory cache + write coalescing.

## Rules for this directory

* Do not edit `performance.snapshot.log` under any circumstance.
* `perf_report.csv` is regenerable — safe to overwrite by re-running `parse_perf.js`.
* If a new perf capture is dropped in, prefer to keep the parser stable and let the CSV change; only edit `parse_perf.js` if the log format itself changes or new aggregations are needed.
* Findings and recommendations from analysis belong in the project's normal docs / issue tracker, not as new files in this directory. Keep `perf/` focused on raw input + parser + aggregated output.
