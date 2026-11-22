# Performance Budgets

**Reference hardware**: MacBook with Apple M2, 16 GB RAM, macOS 14 or later.

A budget counts as met only with a benchmark result, measured on the reference hardware.

## Budgets

| Metric | Budget | Measured by |
|---|---|---|
| Cold start to window | < 400 ms | `--bench-startup` (spike S3) |
| Warm start to window | < 200 ms | `--bench-startup` |
| Dashboard rendering | < 300 ms | `--bench-startup` |
| Navigation (go to definition, open file, switch tab) | < 100 ms | UI benchmark |
| Key press to commit | p99 < 8 ms, max 16 ms | `make bench` |
| Key press to frame | p99 ≤ 2 frames + 1 ms | `make bench` with display |
| Open 10 MB file | < 300 ms, scroll at display refresh rate | `make bench` |
| Relex after edit | < 1 ms for a common line | `make bench` |
| Completion popup after result | < 30 ms; local filtering < 5 ms | `make bench` |
| PHP parse | common file < 2 ms; 30 000 files in parallel < 10 s | spike S1, PHP benchmark |
| PHP completion / definition | < 50 ms / < 20 ms | marker benchmark |
| PHP warm start from cache | < 2 s | PHP benchmark |
| PHP index memory on a large project (framework app with `vendor/`) | < 400 MB | PHP benchmark |
| Open file by name (20 000 files) | < 50 ms per keystroke | `make bench` |
| Find in Files first results | < 100 ms | search benchmark |
| Go to Symbol / Search Everywhere | < 100 ms | search benchmark |
| Idle memory, core app without a large project being indexed | target < 100 MB (to be confirmed by spike S3) | `phys_footprint` sample |
| Idle CPU (window in background) | ~0 %: timers and caret blinking stop, App Nap allowed | Activity Monitor and sample |

## Rules

- Language intelligence, databases, Docker monitoring and SSH connections start only when they are first needed, not when a project opens.
- On memory pressure (`DispatchSource.makeMemoryPressureSource`), the app drops line layout caches, closed-file data and old search results.
- On battery, whole-project indexing and analysis run at `.utility` priority.
- Lists and tables are virtualized (view-based `NSTableView` and `NSOutlineView`).
- UI updates from background work are coalesced to at most one per frame. Progress updates are throttled to 4 per second.
- A change in the editing path must pass `make bench`. CI fails when a budget is exceeded (the CI profile checks p99 only, because virtual machines have one-off spikes).
