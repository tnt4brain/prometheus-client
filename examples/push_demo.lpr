{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
program push_demo;
{ A short-lived job that pushes its metrics to a Pushgateway just before it exits.
  Usage: push_demo [gateway-url]   (default http://127.0.0.1:9091)
  Build: fpc -Mobjfpc -Fusrc -FUexamples/lib examples/push_demo.lpr }
{$mode objfpc}{$H+}
uses
  SysUtils, prom_registry, prom_metrics, prom_push;

var
  R: TPromRegistry;
  URL: string;
begin
  URL := 'http://127.0.0.1:9091';
  if ParamCount > 0 then
    URL := ParamStr(1);
  R := TPromRegistry.Create;
  try
    R.Counter('demo_records_processed_total', 'Records processed by the batch.').Inc(1234);
    R.Gauge('demo_last_success_unixtime', 'Time of the last successful run.').SetToCurrentTime;
    // PUT: replaces everything in the group "demo_batch / instance=host1 / path=/var/data"
    // (a value with a slash is sent as name@base64, handled by the library)
    PromPush(URL, 'demo_batch', R, ['instance', 'host1', 'path', '/var/data']);
    WriteLn('pushed to ', URL);
  finally
    R.Free;
  end;
end.
