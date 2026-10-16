# prometheus_fpc

Prometheus client for Free Pascal / Lazarus with lock-free, thread-safe metrics.
Runtime-only package, FCL only (no LCL), so it works in console apps and services.

## Layout
- `docs/adr/` - architecture decision records
- `prometheus_fpc.lpk` - the package
- `src/prom_atomic` - CAS-based atomic Int64/Double
- `src/prom_exposition` - text format 0.0.4 (escaping, float format, name validation)
- `src/prom_metrics` - counter, gauge (with `SetToCurrentTime`, `TrackInProgress`), histogram, summary (sum/count only), untyped, info (optional labels), timer for histogram/summary
- `src/prom_clock` - monotonic clock
- `src/prom_registry` - thread-safe registry, `DefaultRegistry`
- `src/prom_http` - `MetricsBody` + content type; bring your own HTTP server
- `src/prom_collectors` - process and FPC heap metrics, labelled callback metrics, computed on scrape
- `tests/` - FPCUnit console tests (`lazbuild tests/prom_tests.lpi`)
- `examples/metrics_demo.lpr`

## Roadmap
1. ~~Labelled children~~ (done: `Labels(...)`, RW-locked lookup, cached children; no child removal yet)
2. ~~Shortest round-trip float formatting~~ (done)
3. ~~Process and FPC heap collectors~~ (done; tested on Windows x64 and Linux x86_64)
4. Optional bundled HTTP server unit
5. OpenMetrics output, striped counters for extreme contention

## Provenance
Designed and directed by Sergei Pechenko: the requirements, design decisions (recorded as
ADRs in [`docs/adr/`](docs/adr/)), reviews and acceptance. Most of the code, tests and docs were
written by Claude (Anthropic) from his prompts and decisions, and checked by the test suite
(Windows x64, Linux x86_64) and a heaptrc leak/use-after-free check. Because the code is largely
AI-generated, no warranty of originality is given beyond the license's disclaimer.

## License
BSD 3-Clause; see [`LICENSE`](LICENSE).
