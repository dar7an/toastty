# Benchmarking

The benchmark tools are split into two roles:

- `ghostty-gen` generates synthetic input data.
- `ghostty-bench` consumes existing input data and runs a benchmark.

## Workflow

- For timing comparisons, generate data first and benchmark it later.
- Do not pipe `ghostty-gen` directly into `ghostty-bench` when comparing
  performance. That mixes generation cost into the measurement and makes
  branch-to-branch comparisons noisy.
- Reuse the exact same generated files when comparing revisions.
- Prefer deterministic generation inputs such as fixed seeds when the
  generator supports them.
- Keep large generated benchmark corpora outside the repository unless the
  change explicitly requires checked-in test data.

## Running Benchmarks

- Prefer `hyperfine` to compare benchmark timings.
- Benchmark the `ghostty-bench` command line, not the generator.
- Use `ghostty-bench ... --data <path>` with pre-generated files.
- Run multiple warmups and repeated measurements so branch comparisons are
  based on medians instead of single runs.
- When comparing branches, keep all benchmark inputs and CLI flags the same,
  including terminal dimensions.
- Never run multiple benchmarks in parallel on the same machine, as they will
  interfere with each other and produce unreliable results.

## Building

- Build benchmark tools with `zig build -Demit-bench -Doptimize=ReleaseFast`.
- On macOS, add `-Demit-macos-app=false` to avoid building the macOS app.
- Make sure you specify `-Doptimize=ReleaseFast` when building benchmarks,
  otherwise the debug build will be very slow and not representative of real
  performance.

Use isolated checkouts/binaries for revision comparisons; do not switch a shared
working tree out from under another task. See [benchmark evidence](../../docs/development.md#engine-benchmarks)
for the comparison recipe.
