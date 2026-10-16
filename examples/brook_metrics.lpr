{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
program brook_metrics;
{ /metrics on a Brook Framework 5 TBrookHTTPServer (Brook needs the native libsagui-3 library next
  to the executable or on the path: https://github.com/risoflora/libsagui/releases).
  Run, then: curl http://127.0.0.1:8082/metrics
  Build (Brook sources in <brook>): fpc -MDelphi -Fusrc -Fu<brook>/Source -Fi<brook>/Source
    -FUexamples/lib examples/brook_metrics.lpr
  Brook is LGPL-2.1+; this example only calls its public API. }
{$MODE DELPHI}
uses
  SysUtils, BrookHTTPRequest, BrookHTTPResponse, BrookHTTPServer,
  prom_registry, prom_metrics, prom_http, prom_collectors;

type
  TMetricsServer = class(TBrookHTTPServer)
  protected
    procedure DoRequest(ASender: TObject; ARequest: TBrookHTTPRequest;
      AResponse: TBrookHTTPResponse); override;
  end;

var
  Hits: TPromCounter;

procedure TMetricsServer.DoRequest(ASender: TObject; ARequest: TBrookHTTPRequest;
  AResponse: TBrookHTTPResponse);
var
  Accept, CT, Body: string;
begin
  if ARequest.Path = '/metrics' then
  begin
    if not ARequest.Headers.TryValue('Accept', Accept) then
      Accept := '';
    Body := MetricsResponse(DefaultRegistry, Accept, CT);
    // SendBinary sends the exact bytes (Send would marshal the string again)
    AResponse.SendBinary(PAnsiChar(Body), Length(Body), CT, 200);
  end
  else if ARequest.Path = '/hello' then
  begin
    Hits.Inc;
    AResponse.Send('hello', 'text/plain; charset=utf-8', 200);
  end
  else
    AResponse.Send('not found', 'text/plain; charset=utf-8', 404);
end;

begin
  RegisterProcessMetrics(DefaultRegistry);
  RegisterHeapMetrics(DefaultRegistry);
  Hits := DefaultRegistry.Counter('hello_requests_total', 'Requests to /hello.');
  with TMetricsServer.Create(nil) do
  try
    Port := 8082;
    Open;
    if not Active then
      Exit;
    WriteLn('Listening on http://127.0.0.1:', Port, '/metrics - press Enter to stop');
    ReadLn;
  finally
    Free;
  end;
end.
