# Spike S1: PHP scanning speed in Swift

Measured 2026-11-22 on M2 / 16 GB (8 cores), release build, warm file cache, second run.

Tool: `swift build -c release --build-system native --product PHPScan`, then `.build/release/PHPScan <dir>`.

The scanner is `Sources/PHPKit`: the PHP lexer (ported from the Go spike, extended with `|>` from PHP 8.5) and a declaration scanner. It finds namespace, use, classes, interfaces, traits, enums, functions, methods, properties, constants and enum cases. Results are stored in flat arrays: one byte pool of names per file, plain structs for declarations. All results stay in memory, as an index would keep them.

## Corpora

- **nette/web-project** (`composer create-project … --no-scripts`): 776 files, 3.0 MB.
- **laravel/laravel** with `vendor/`: 8 234 files, 38.8 MB.
- **Synthetic** (`go run ./cmd/phpcorpus -n 30000`): 30 000 files, 173.5 MB, imitates vendor code.

## Results

| Corpus | Swift scan | Go scan (same corpus) | Results held (Swift) | Unbalanced braces |
|---|---|---|---|---|
| nette/web-project | **9 ms** (330 MB/s) | 11 ms (264 MB/s) | 0.5 MB, 741 B per file | 0 |
| laravel/laravel | **94 ms** (412 MB/s) | 99 ms (393 MB/s) | 5.0 MB, 633 B per file | 0 |
| Synthetic, 30 000 files | **333 ms** (522 MB/s) | 567 ms (306 MB/s) | 42.2 MB, 1 476 B per file | 0 |

- Declaration counts match the Go scanner exactly on all three corpora. For Laravel: 5 908 classes, 41 835 methods, 11 079 properties.
- The budget "30 000 files under 10 s" is met **30×**.
- Process footprint after the synthetic scan: 97 MB, including all results and the list of 30 000 paths.
- No trap on 39 000 real and synthetic files. 3 000 random mutations in the lexer test check that every byte belongs to exactly one token.

## Conclusions

- Swift is not slower than Go for this work. The flat layout (`UnsafeBufferPointer` reads guarded by bounds checks, 12-byte tokens, reused token buffer, no `String` until a name is requested) avoids reference counting in the hot path.
- **Decision for R5: the PHP parser stays in Swift, in-process** (ADR-4 confirmed).
- Directory walking with `FileManager.enumerator` takes longer than the scan itself (559 ms for 30 000 files). The file catalog in R3 uses `getattrlistbulk` and the persisted catalog instead.
- Results hold array capacity slack (doubling growth). The real index (R5b) should size arrays exactly or compact them after a file is indexed.

## Limits of this spike

- It is a declaration scanner, not the full parser. R5a must confirm the budget "common file < 2 ms" with a full AST in flat arrays. Here the slowest single file (Laravel's 1 MB `autoload_classmap.php`) took 8 ms, which also includes thread scheduling.
- The lexer and the highlighting lexer in `Highlight` are still separate. Merging them is part of R5a (ADR-4).
