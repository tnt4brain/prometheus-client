{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit prom_mormot_http;
{ Mounts our /metrics responder on a mORMot 2 HTTP server through its URI router.

  Works with any THttpServerGeneric descendant: THttpServer, THttpAsyncServer, and the server a
  TRestHttpServer wraps (its HttpServer property). The format (Prometheus text 0.0.4 or
  OpenMetrics) is negotiated from the request's Accept header, as MetricsResponse does. }

{$mode objfpc}{$H+}

interface

uses
  prom_registry, mormot.core.base, mormot.net.server;

{ GET Path (default '/metrics') on Server answers with Registry's exposition (the default
  registry when nil). The registry must outlive the server; the mount itself is freed when the
  program ends. Call before or after the server starts. }
procedure PromMountMetrics(Server: THttpServerGeneric; Registry: TPromRegistry = nil;
  const Path: RawUtf8 = '/metrics');

implementation

uses
  Classes, contnrs, mormot.core.unicode, mormot.net.http, prom_http;

type
  TMetricsMount = class
    Registry: TPromRegistry;
    function Serve(Ctxt: THttpServerRequestAbstract): cardinal;
  end;

var
  Mounts: TObjectList;

function TMetricsMount.Serve(Ctxt: THttpServerRequestAbstract): cardinal;
var
  CT, Body: string;
  Raw: RawByteString;
begin
  Body := MetricsResponse(Registry,
    string(FindNameValue(pointer(Ctxt.InHeaders), 'ACCEPT:')), CT);
  // exact bytes, no code page conversion
  SetString(Raw, PAnsiChar(Body), Length(Body));
  Ctxt.OutContent := Raw;
  Ctxt.OutContentType := RawUtf8(CT);
  Result := 200;
end;

procedure PromMountMetrics(Server: THttpServerGeneric; Registry: TPromRegistry;
  const Path: RawUtf8);
var
  M: TMetricsMount;
begin
  M := TMetricsMount.Create;
  M.Registry := Registry;
  Mounts.Add(M);
  Server.Route.Get(Path, @M.Serve);
end;

initialization
  Mounts := TObjectList.Create(True);

finalization
  Mounts.Free;

end.
