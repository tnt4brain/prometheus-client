{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
program fpweb_metrics;
{ /metrics inside an fpWeb application (fcl-web), next to the app's own routes.
  Run, then: curl http://127.0.0.1:8080/metrics
  Build: fpc -Mobjfpc -Fusrc -FUexamples/lib examples/fpweb_metrics.lpr }
{$mode objfpc}{$H+}
uses
  {$ifdef UNIX} cthreads, {$endif}
  Classes, SysUtils, fphttpapp, httpdefs, httproute,
  prom_registry, prom_metrics, prom_http, prom_collectors;

var
  Hits: TPromCounter;

procedure MetricsRoute(ARequest: TRequest; AResponse: TResponse);
var
  CT, Body: string;
  Stream: TStringStream;
begin
  Body := MetricsResponse(DefaultRegistry, ARequest.Accept, CT);
  AResponse.ContentType := CT;
  // not AResponse.Content: it is a TStrings and turns #10 into CRLF on Windows
  Stream := TStringStream.Create(Body);
  AResponse.ContentStream := Stream;
  AResponse.FreeContentStream := True;
  AResponse.ContentLength := Stream.Size;
  AResponse.SendContent;
end;

procedure HelloRoute(ARequest: TRequest; AResponse: TResponse);
begin
  Hits.Inc;
  AResponse.Content := 'hello';
end;

begin
  RegisterProcessMetrics(DefaultRegistry);
  RegisterHeapMetrics(DefaultRegistry);
  Hits := DefaultRegistry.Counter('hello_requests_total', 'Requests to /hello.');
  HTTPRouter.RegisterRoute('/metrics', rmGet, @MetricsRoute);
  HTTPRouter.RegisterRoute('/hello', rmGet, @HelloRoute);
  Application.Port := 8080;
  Application.Threaded := True;
  Application.Initialize;
  Application.Run;
end.
