# Getting started: Prometheus in Free Pascal in 10 minutes

You will expose three metrics from a console program, scrape them with Prometheus, and
query them. Needs Free Pascal 3.2+ (64-bit) and this repository; nothing else.

## 1. The program

`examples/hello_metrics.lpr` is the whole thing. The core is three steps:

```pascal
uses prom_metrics, prom_registry, prom_server;

// 1. register once, at start-up
Jobs    := DefaultRegistry.Counter('hello_jobs_total', 'Jobs processed', ['result']);
Latency := DefaultRegistry.Histogram('hello_job_duration_seconds', 'Time per job',
             [0.01, 0.05, 0.1, 0.5, 1]);
// 2. serve
TPromServer.Create(9100).Start;           // GET http://localhost:9100/metrics
// 3. record, anywhere, from any thread
Jobs.Labels(['ok']).Inc;
Latency.Observe(0.042);
```

Build and run (from `examples/`):

```
fpc -Fu../src hello_metrics.lpr
./hello_metrics            # hello_metrics.exe on Windows
curl http://localhost:9100/metrics
```

## 2. What you see

```
# HELP hello_jobs_total Jobs processed
# TYPE hello_jobs_total counter
hello_jobs_total{result="ok"} 14
hello_jobs_total{result="error"} 1
# HELP hello_job_duration_seconds Time spent per job
# TYPE hello_job_duration_seconds histogram
hello_job_duration_seconds_bucket{le="0.01"} 1
hello_job_duration_seconds_bucket{le="0.05"} 4
...
hello_job_duration_seconds_bucket{le="+Inf"} 15
hello_job_duration_seconds_sum 1.93
hello_job_duration_seconds_count 15
```

The example also registers `RegisterProcessMetrics`, so `process_*` metrics (CPU, memory, ...) follow.

That text is all Prometheus needs. Send `Accept: application/openmetrics-text` and you get
OpenMetrics instead (also the only format that carries exemplars).

## 3. Which metric type?

| You measure | Type | Example |
|---|---|---|
| Something that only goes up (events, bytes) | Counter | requests, errors |
| A value that goes up and down | Gauge | queue length, temperature |
| How long / how big, to get percentiles | Histogram | request duration |
| Same, with client-side quantiles | Summary | job duration p99 |
| One of several states | StateSet | starting / running / stopping |

Counters end in `_total`, durations are in seconds, sizes in bytes. Never put an id, user
name or URL in a label: every distinct label set is a new time series held in memory
(`Acquire`/`Release` and `MaxChildren` exist for the cases that must come and go).

## 4. Scrape it with Prometheus

`prometheus.yml`:

```yaml
scrape_configs:
  - job_name: hello
    scrape_interval: 5s
    static_configs:
      - targets: ['localhost:9100']
```

Run `prometheus --config.file=prometheus.yml`, open http://localhost:9090 and try:

```
rate(hello_jobs_total[1m])                                   # jobs per second, by result
sum(rate(hello_jobs_total{result="error"}[5m]))
  / sum(rate(hello_jobs_total[5m]))                          # error ratio
histogram_quantile(0.95,
  sum by (le) (rate(hello_job_duration_seconds_bucket[5m]))) # p95 latency
```

## 5. Gotchas

- Windows: a plain FPC console program's `string` is the ANSI code page. If label values or
  HELP texts contain non-ASCII, set `DefaultSystemCodePage := CP_UTF8;` first.
- Unix: keep `cthreads` first in the program's `uses` (the example does).
- Short-lived jobs (cron, batch) die before Prometheus scrapes them: push to a Pushgateway
  instead, see `examples/push_demo.lpr` and `prom_push`.
- Already have an HTTP server? Skip `prom_server` and return `MetricsBody` (unit `prom_http`)
  from your `/metrics` handler; see the fpWeb, Indy, Brook and mORMot examples.

## Checked with

The example, the scrape config and the three queries above were run against Prometheus 3.15.0 and
VictoriaMetrics 1.154.0 (single-node, `-promscrape.config=prometheus.yml`, same YAML, same query results) on
Windows x64; `promtool check metrics` accepts the output. VictoriaMetrics needs a few seconds after start
before queries return data.
