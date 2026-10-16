{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
program metrics_demo;
{ Register metrics, update them, print the exposition text in both formats.
  Serve the same strings from your HTTP server's GET /metrics handler (or use prom_server). }

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  prom_metrics, prom_registry, prom_exposition, prom_http;

var
  Requests: TPromCounter;
  InFlight: TPromGauge;
  Latency: TPromHistogram;
  Duration: TPromSummary;
  Phase: TPromStateSet;
  T: TPromTimer;
  I: Integer;

begin
  Requests := DefaultRegistry.Counter('demo_requests_total', 'Requests handled', ['method', 'code']);
  InFlight := DefaultRegistry.Gauge('demo_in_flight', 'Requests in flight');
  Latency := DefaultRegistry.Histogram('demo_latency_seconds', 'Request latency',
    [0.005, 0.05, 0.5, 5]);
  // Summary with quantiles: windowed estimates (1% relative error), lock-free Observe.
  Duration := DefaultRegistry.Summary('demo_duration_seconds', 'Job duration', [],
    [0.5, 0.9, 0.99]);
  // StateSet: exactly one phase is true at a time; SetOnly changes it atomically.
  Phase := DefaultRegistry.StateSet('demo_phase', 'Current phase', [],
    ['starting', 'running', 'stopping']);

  Phase.SetOnly('running');
  InFlight.Inc;
  Requests.Labels(['GET', '200']).Inc;
  // Exemplars link a sample to a trace; they show up in OpenMetrics output only.
  Requests.Labels(['GET', '500']).IncWithExemplar(1, ['trace_id', 'abc123']);
  Latency.ObserveWithExemplar(0.042, ['trace_id', 'abc123']);
  for I := 1 to 100 do
    Duration.Observe(I / 100);
  T := Latency.StartTimer;     // times a block and observes the elapsed seconds
  T.ObserveDuration;
  InFlight.Dec;

  WriteLn('--- Prometheus text 0.0.4 ---');
  Write(MetricsBody);
  WriteLn;
  WriteLn('--- OpenMetrics 1.0 ---');
  Write(DefaultRegistry.Collect(pfOpenMetrics));
end.
