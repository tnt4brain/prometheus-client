{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
program metrics_demo;
{ Smallest possible use: register metrics, update them, print the exposition text.
  Serve the same string from your HTTP server's GET /metrics handler. }

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  prom_metrics, prom_registry, prom_http;

var
  Requests: TPromCounter;
  InFlight: TPromGauge;
  Latency: TPromHistogram;

begin
  Requests := DefaultRegistry.Counter('demo_requests_total', 'Requests handled', ['method', 'code']);
  InFlight := DefaultRegistry.Gauge('demo_in_flight', 'Requests in flight');
  Latency := DefaultRegistry.Histogram('demo_latency_seconds', 'Request latency',
    [0.005, 0.05, 0.5, 5]);

  InFlight.Inc;
  Requests.Labels(['GET', '200']).Inc;
  Latency.Observe(0.042);
  InFlight.Dec;

  Write(MetricsBody);
end.
