# Terminal Compression

Guidance for the codecs and the compressed page representation
(`Page.zig`) in this directory. These compress terminal page backing
memory (`terminal.Page`).

## Priorities

When making tradeoffs, in order:

1. **Compression ratio on page-shaped data.** Encoded bytes are retained
   scrollback memory, and raw `terminal.Page` backing memory is the only
   thing we actually compress. Ratio on text files or synthetic data is a
   secondary signal.
2. **Decompression throughput.** Pages are compressed once when they go
   cold but restored on demand (scrollback access, search, inspection), so
   restore latency is felt directly.
3. **Compression throughput.** Runs on idle pages in the background; being
   fast is nice, being slow is tolerable.

## Testing

- Targeted tests: `zig build test -Dtest-filter=<codec>`
- Prefer `zig build test-lib-vt -Dtest-filter=<codec>` when practical;
  this code ships in libghostty-vt.
- Codecs must keep building for `wasm32-freestanding` (libghostty-vt):
  no libc, no `src/simd` (Highway) dependencies. Verify with
  `zig build -Demit-lib-vt -Dtarget=wasm32-freestanding -Doptimize=ReleaseSmall`.
- Every codec needs a differential property suite: round-trip identity,
  an independent format walker, wrong-size output rejection, and
  corruption/truncation decoding. Keep a light version in normal unit
  tests and gate the exhaustive version behind an environment variable so
  the default test suite stays fast.

## Verifying Correctness

- Decoders must be memory-safe for arbitrary input bytes. Every blind or
  wide copy needs a stated margin argument bounding it by the output
  buffer; keep those arguments in comments next to the code.
- Writing scratch bytes past a copy's logical end is safe only inside the
  output buffer, because in-order decoding rewrites them before any match
  can read them back. Do not weaken the exact-size output contract.
- When a change should not alter compressor output, prove it: compare
  encoded sizes (or a sequence-count fingerprint) on the same corpus
  before and after. Ratio drift is a functional change, not noise.

## Benchmark evidence

Use `ghostty-bench +page-compression` for codec work and
`ghostty-bench +scrollback-compression` for PageList transitions. Prefer raw real
page backing-memory corpora, with text/random bytes as supplementary cases.
Follow [the benchmark guide](../../benchmark/AGENTS.md) and
[comparison procedure](../../../docs/development.md#engine-benchmarks): build
ReleaseFast, reuse identical corpora/dimensions, measure serially with repeated
runs, and verify round-trips. Machine-dependent microbenchmark results are
evidence to recheck, not unconditional coding rules.

## LZ4 Specific

- The codec is `lz4.zig`, an allocation-free raw block (not frame)
  implementation. Blocks do not carry their decoded size; callers supply
  an exact-size output buffer.
- Tests: `zig build test -Dtest-filter=lz4`. The differential suite is
  `lz4_differential.zig`; run the exhaustive version for any codec
  change:
  `GHOSTTY_LZ4_SLOW=1 zig build test -Dtest-filter="lz4 differential"`
- The compressor must keep the standard format restrictions (final five
  bytes literal, matches start at least twelve bytes before the end) so
  blocks stay consumable by optimized external decoders. The differential
  walker checks this.
