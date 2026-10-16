{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit prom_http;
{ Transport-agnostic /metrics support. Hook MetricsBody into whatever HTTP server
  the host application uses (fphttpserver, fpWeb, Indy, ...) and send
  PromContentType as the Content-Type. A bundled server can be added later as a
  separate unit so this package keeps no networking dependency. }

{$mode objfpc}{$H+}

interface

uses
  prom_registry, prom_exposition;

{ Body for a GET /metrics response; Registry = nil uses DefaultRegistry. }
function MetricsBody(Registry: TPromRegistry = nil): string;

implementation

function MetricsBody(Registry: TPromRegistry): string;
begin
  if Registry = nil then
    Registry := DefaultRegistry;
  Result := Registry.Collect;
end;

end.
