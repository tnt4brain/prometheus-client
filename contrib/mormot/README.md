# mORMot 2 integration (optional)

Not part of the `prometheus_fpc` package: the package keeps no mORMot dependency. Add this
directory to the unit path of a program that uses mORMot 2.

| File | What |
|---|---|
| `prometheus_fpc_mormot.lpk` | Lazarus package (requires `prometheus_fpc` and mORMot's own `mormot2`) holding `prom_mormot` and `prom_mormot_http`. `prom_mormot_mm` is not compiled with it (x86_64 only, needs mORMot's memory manager first in the program); its directory is on the package's usage unit path, so just `uses` it. |
| `prometheus_fpc_mormot.lpk` | Lazarus package (requires `prometheus_fpc` and mORMot's `mormot2`) holding `prom_mormot` and `prom_mormot_http`. `prom_mormot_mm` is not compiled with it (x86_64 only, and mORMot's memory manager must be first in the program); the package directory is on its usage unit path, so a program just `uses` it. |
| `prom_mormot.pas` | `PromRegisterSynMonitor(Registry, Monitor, Prefix)`: publishes a `TSynMonitor` tree (e.g. an HTTP server's `TSynMonitorServer`) as metrics. |
| `prom_mormot_http.pas` | `PromMountMetrics(Server, Registry, Path)`: mounts our `/metrics` responder on a mORMot HTTP server via its router (`Route.Get`); any `THttpServerGeneric`: `THttpServer`, `THttpAsyncServer`, a `TRestHttpServer`'s `HttpServer`. |
| `prom_mormot_mm.pas` | `PromRegisterMormotHeapMetrics`: heap metrics for programs on `mormot.core.fpcx64mm`. |
| `mormot_bridge_test.lpr` | Smoke test of the monitor bridge. |
| `mormot_server_test.lpr` | Mounts `/metrics` on `THttpServer` and `THttpAsyncServer`, scrapes them, checks UTF-8, content negotiation, 404 elsewhere, and counters under 4 writer threads. |

Tested against the mORMot2 `2.4-stable` tag, not master (master of 2026-10-16 did not compile:
`DuckApplyScale` missing in the DuckDB unit). Install order: mORMot's `mormot2.lpk` (in its
`packages/lazarus`), then `prometheus_fpc.lpk`, then `prometheus_fpc_mormot.lpk`.

## Findings (mORMot 2.4, FPC 3.2.2, Windows x64)

- mORMot has **no Prometheus/OpenMetrics exporter** (`grep` over `src` finds none); its monitors
  report JSON/RTTI statistics. `prom_mormot` maps cumulative kinds (`smvMicroSec`, `smvBytes`,
  `smvCount`, `smvCount64`) to counters (microseconds become seconds) and instant kinds to gauges.
- **Mounting on mORMot works**: `PromMountMetrics(Server, Registry)` registers GET `/metrics` through the router. Accept negotiation works with mORMot's default header filtering (a single `Accept` header; mORMot's own HTTP client always adds `Accept: */*` first, so test negotiation over a raw socket). No unit-name clashes. Counters updated from 4 threads while scraped stay exact.
- **Text encoding is fine inside mORMot**: it sets `DefaultSystemCodePage` to CP_UTF8, so `string` is
  UTF-8 and label/HELP bytes reach the wire intact. Without mORMot (plain FPC console program on
  Windows) `string` is the ANSI code page and non-ASCII text is not UTF-8: set
  `DefaultSystemCodePage := CP_UTF8` yourself. Build `RawUtf8` test data from bytes
  (`FastSetString`), not from a literal: a literal with non-ASCII characters is converted from the
  source code page.
- **Memory manager**: with `mormot.core.fpcx64mm`, FPC's `GetFPCHeapStatus` reports used = size and
  free = 0, so `RegisterHeapMetrics` (`fpc_heap_*`) is misleading. Use `prom_mormot_mm` instead. The
  manager must be the first unit of the uses clause. `RegisterProcessMetrics` reads OS counters and is
  unaffected.

## Build the tests (Windows)

mORMot needs its prebuilt static objects (https://synopse.info/files/mormot2static.7z, unpack into
`mORMot2\static`). Paths relative to this repo; `-Fl` is needed because mORMot's `{$linklib}` is
relative to the working directory:

```
fpc -MObjFPC -Sh -Fl<mORMot2>\static\x86_64-win64 -Fu..\..\src -Fu. -Fu<mORMot2>\src\core ^
  -Fu<mORMot2>\src\lib -Fu<mORMot2>\src\net -Fu<mORMot2>\src\crypt -Fu<mORMot2>\src\db ^
  -Fi<mORMot2>\src -Fi<mORMot2>\src\core -FUlib [-dMORMOTMM] mormot_server_test.lpr
```

Not tested on Linux.
