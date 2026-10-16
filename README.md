# prometheus_fpc

Prometheus client for Free Pascal / Lazarus with lock-free, thread-safe metrics.
Runtime-only package, FCL only (no LCL), so it works in console apps and services.

## Layout
- `docs/GETTING_STARTED.md` - 10-minute tutorial: expose metrics, scrape them with Prometheus, query them (`examples/hello_metrics.lpr`)
- `docs/adr/` - architecture decision records
- `prometheus_fpc.lpk` - the package
- `src/prom_atomic` - CAS-based atomic Int64/Double
- `src/prom_exposition` - text format 0.0.4 (escaping, float format, name validation)
- `src/prom_metrics` - counter, gauge (with `SetToCurrentTime`, `TrackInProgress`), histogram, summary (sum/count only), untyped, info (optional labels), timer for histogram/summary
- `src/prom_clock` - monotonic clock
- `src/prom_registry` - thread-safe registry, `DefaultRegistry`
- `src/prom_http` - `MetricsBody` + content type; bring your own HTTP server
- `src/prom_collectors` - process and FPC heap metrics, labelled callback metrics, computed on scrape
- `src/prom_server` - optional `/metrics` HTTP server (fphttpserver), negotiates text 0.0.4 or OpenMetrics
- `src/prom_push` - optional Pushgateway client (`PromPush`, `PromPushAdd`, `PromPushDelete`, `TPromPusher` with basic auth and timeout) for short-lived jobs; checked against Pushgateway 1.11.4
- `tests/` - FPCUnit console tests (`lazbuild tests/prom_tests.lpi`)
- `examples/metrics_demo.lpr` - counter, gauge, histogram, quantile summary, StateSet, exemplars, both output formats
- `examples/push_demo.lpr` - a batch job pushing its metrics to a Pushgateway
- `examples/fpweb_metrics.lpr`, `examples/indy_metrics.lpr`, `examples/brook_metrics.lpr` - `/metrics` inside an fpWeb (fcl-web) app, on an Indy 10 `TIdHTTPServer` and on a Brook 5 `TBrookHTTPServer` (needs the native libsagui-3 library)
- `contrib/mormot/` - optional mORMot 2 integration, a separate package `prometheus_fpc_mormot.lpk`: mount `/metrics` on a mORMot HTTP server (`PromMountMetrics`), publish `TSynMonitor` statistics as metrics, heap metrics for mORMot's memory manager. Tested on Windows x64 against mORMot 2.4-stable; see its README

## Quick start
```pascal
uses prom_metrics, prom_registry, prom_exposition, prom_http;

var Req: TPromCounter; Dur: TPromSummary; Phase: TPromStateSet;
begin
  Req := DefaultRegistry.Counter('app_requests_total', 'Requests', ['code']);
  Dur := DefaultRegistry.Summary('app_duration_seconds', 'Duration', [], [0.5, 0.9, 0.99]);
  Phase := DefaultRegistry.StateSet('app_phase', 'Phase', [], ['starting', 'running']);

  Phase.SetOnly('running');                                            // atomic
  Req.Labels(['500']).IncWithExemplar(1, ['trace_id', 'abc123']);      // OpenMetrics only
  Dur.Observe(0.25);                                                   // lock-free

  Write(MetricsBody);                                  // text 0.0.4
  Write(DefaultRegistry.Collect(pfOpenMetrics));       // OpenMetrics 1.0
end.
```
Cache `Labels(...)` results in hot paths. That pointer stays valid until the family is freed, so removed series are
kept in memory. If label sets come and go (per-connection, per-job), use `Acquire` / `Release` instead and
`Remove` frees the series once nobody holds it:
```pascal
Ch := TPromCounterChild(Jobs.Acquire([JobId]));
try Ch.Inc; finally Jobs.Release(Ch); end;
Jobs.Remove([JobId]);        // freed now, or at the last Release + next Remove/Clear/new series/Reclaim
```
 Quantiles are windowed (10 min) estimates with 1% relative error.

## Roadmap
1. ~~Labelled children~~ (done: `Labels(...)`, RW-locked lookup, cached children, `Remove`/`Clear`, `MaxChildren` cap)
2. ~~Shortest round-trip float formatting~~ (done)
3. ~~Process and FPC heap collectors~~ (done; tested on Windows x64 and Linux x86_64)
4. ~~Optional bundled HTTP server unit~~ (done: `prom_server`, with Accept negotiation)
5. ~~OpenMetrics 1.0 text output~~ (done, complete: `_created`, exemplars, `# UNIT`, StateSet, GaugeHistogram, name-clash check)
6. ~~Summary quantiles~~ (done: windowed relative-error sketch, lock-free `Observe`)
7. ~~Striped counters~~ (done, opt-in: `Counter(name, help, labels, Stripes)`; about 50x faster with 8 contending threads)
8. ~~32-bit/ARM testing~~ (out of scope: the package targets 64-bit CPUs only; tested on Windows x64 and Linux x86_64)

## Provenance
Designed and directed by Sergei Pechenko: the requirements, design decisions (recorded as
ADRs in [`docs/adr/`](docs/adr/)), reviews and acceptance. Most of the code, tests and docs were
written by Claude (Anthropic) from his prompts and decisions, and checked by the test suite
(Windows x64, Linux x86_64) and a heaptrc leak/use-after-free check. Because the code is largely
AI-generated, no warranty of originality is given beyond the license's disclaimer.

## License
BSD 3-Clause; see [`LICENSE`](LICENSE).
