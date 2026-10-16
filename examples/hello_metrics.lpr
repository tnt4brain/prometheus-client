{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
program hello_metrics;
{ Prometheus 101: a program that does some "work" and exposes it on http://localhost:9100/metrics.
  Build: fpc -Fu../src hello_metrics.lpr
  Run, then: curl http://localhost:9100/metrics   See docs/GETTING_STARTED.md. }

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, prom_metrics, prom_registry, prom_collectors, prom_server;

var
  Jobs: TPromCounter;
  Queue: TPromGauge;
  Latency: TPromHistogram;
  Server: TPromServer;
  T: TPromTimer;
  Failed: Boolean;

begin
  // 1. Register metrics once, at start-up. Names: snake_case, a unit suffix, _total for counters.
  Jobs := DefaultRegistry.Counter('hello_jobs_total', 'Jobs processed', ['result']);
  Queue := DefaultRegistry.Gauge('hello_queue_length', 'Jobs waiting');
  Latency := DefaultRegistry.Histogram('hello_job_duration_seconds', 'Time spent per job',
    [0.01, 0.05, 0.1, 0.5, 1]);
  RegisterProcessMetrics(DefaultRegistry);   // CPU, memory, open files, start time

  // 2. Serve them. Prometheus scrapes this URL.
  Server := TPromServer.Create(9100);
  Server.Start;
  WriteLn('Metrics on http://localhost:9100/metrics, Ctrl+C to stop');

  // 3. Do the work and record it.
  Randomize;
  repeat
    Queue.SetValue(Random(10));
    T := Latency.StartTimer;
    Sleep(Random(200));                       // the "job"
    T.ObserveDuration;
    Failed := Random(10) = 0;
    if Failed then
      Jobs.Labels(['error']).Inc
    else
      Jobs.Labels(['ok']).Inc;
  until False;
end.
