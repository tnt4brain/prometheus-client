{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
program indy_metrics;
{ /metrics on an Indy 10 TIdHTTPServer.
  Run, then: curl http://127.0.0.1:8081/metrics
  Build (Indy sources in <indy>): fpc -Mobjfpc -Fusrc -Fu<indy>/Lib -Fu<indy>/Lib/Core
    -Fu<indy>/Lib/Protocols -Fu<indy>/Lib/System -Fi<indy>/Lib -FUexamples/lib examples/indy_metrics.lpr
  With the indylaz package installed, just lazbuild a project that requires it. }
{$mode objfpc}{$H+}
uses
  {$ifdef UNIX} cthreads, {$endif}
  Classes, SysUtils, IdHTTPServer, IdContext, IdCustomHTTPServer, IdGlobal,
  prom_registry, prom_metrics, prom_http, prom_collectors;

type
  TMetricsHost = class
    Hits: TPromCounter;
    procedure CommandGet(AContext: TIdContext; ARequestInfo: TIdHTTPRequestInfo;
      AResponseInfo: TIdHTTPResponseInfo);
  end;

procedure TMetricsHost.CommandGet(AContext: TIdContext; ARequestInfo: TIdHTTPRequestInfo;
  AResponseInfo: TIdHTTPResponseInfo);
var
  CT, Body: string;
  Stream: TStringStream;
begin
  if ARequestInfo.Document = '/metrics' then
  begin
    Body := MetricsResponse(DefaultRegistry, ARequestInfo.Accept, CT);
    // send the exact bytes: ContentText would convert the string to the response charset
    Stream := TStringStream.Create(Body);
    AResponseInfo.ContentStream := Stream;      // freed by Indy (FreeContentStream is True)
    // Indy appends its own CharSet to ContentType, so split ours: type + CharSet
    AResponseInfo.ContentType := StringReplace(CT, '; charset=utf-8', '', []);
    AResponseInfo.CharSet := 'utf-8';
  end
  else if ARequestInfo.Document = '/hello' then
  begin
    Hits.Inc;
    AResponseInfo.ContentText := 'hello';
  end
  else
    AResponseInfo.ResponseNo := 404;
end;

var
  Server: TIdHTTPServer;
  Host: TMetricsHost;
begin
  RegisterProcessMetrics(DefaultRegistry);
  RegisterHeapMetrics(DefaultRegistry);
  Host := TMetricsHost.Create;
  Host.Hits := DefaultRegistry.Counter('hello_requests_total', 'Requests to /hello.');
  Server := TIdHTTPServer.Create(nil);
  try
    Server.DefaultPort := 8081;
    Server.OnCommandGet := @Host.CommandGet;
    Server.Active := True;
    WriteLn('Listening on http://127.0.0.1:8081/metrics - press Enter to stop');
    ReadLn;
  finally
    Server.Free;
    Host.Free;
  end;
end.
