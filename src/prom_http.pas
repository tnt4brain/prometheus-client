{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit prom_http;
{ Transport-agnostic /metrics support. Hook MetricsBody into whatever HTTP server
  the host application uses (fphttpserver, fpWeb, Indy, ...) and send
  PromContentType as the Content-Type. A bundled server can be added later as a
  separate unit so this package keeps no networking dependency. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, prom_registry, prom_exposition;

{ Body for a GET /metrics response; Registry = nil uses DefaultRegistry. The format
  defaults to the classic text format 0.0.4. }
function MetricsBody(Registry: TPromRegistry = nil; Format: TPromFormat = pfText): string;

{ Picks the format from an Accept header value: the supported media type with the
  highest q wins (OpenMetrics on a tie with text/plain only when listed first);
  no header, "*/*" or anything unrecognised gives the text format. }
function PromNegotiateFormat(const Accept: string): TPromFormat;

{ Negotiated response: returns the body and sets ContentType to match. }
function MetricsResponse(Registry: TPromRegistry; const Accept: string;
  out ContentType: string): string;

implementation

function MetricsBody(Registry: TPromRegistry; Format: TPromFormat): string;
begin
  if Registry = nil then
    Registry := DefaultRegistry;
  Result := Registry.Collect(Format);
end;

function PromNegotiateFormat(const Accept: string): TPromFormat;
var
  L: TStringList;
  I, P: Integer;
  Item, Media, Param, QText: string;
  Q, BestQ: Double;
  Fmt: TPromFormat;
  Matched: Boolean;
  FS: TFormatSettings;
begin
  Result := pfText;
  BestQ := -1;
  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
  L := TStringList.Create;
  try
    L.Delimiter := ',';
    L.StrictDelimiter := True;
    L.DelimitedText := Accept;
    for I := 0 to L.Count - 1 do
    begin
      Item := Trim(L[I]);
      P := Pos(';', Item);
      if P > 0 then
        Media := Trim(Copy(Item, 1, P - 1))
      else
        Media := Item;
      Media := LowerCase(Media);
      Matched := True;
      if Media = 'application/openmetrics-text' then
        Fmt := pfOpenMetrics
      else if Media = 'text/plain' then
        Fmt := pfText
      else
        Matched := False;
      if not Matched then
        Continue;
      Q := 1;
      while P > 0 do
      begin
        Item := Copy(Item, P + 1, MaxInt);
        P := Pos(';', Item);
        if P > 0 then
          Param := Trim(Copy(Item, 1, P - 1))
        else
          Param := Trim(Item);
        if LowerCase(Copy(Param, 1, 2)) = 'q=' then
        begin
          QText := Copy(Param, 3, MaxInt);
          if not TryStrToFloat(QText, Q, FS) then
            Q := 0;
        end;
      end;
      if Q > BestQ then      // strictly greater: the first listed wins a tie
      begin
        BestQ := Q;
        Result := Fmt;
      end;
    end;
  finally
    L.Free;
  end;
  if BestQ <= 0 then
    Result := pfText;
end;

function MetricsResponse(Registry: TPromRegistry; const Accept: string;
  out ContentType: string): string;
var
  Fmt: TPromFormat;
begin
  Fmt := PromNegotiateFormat(Accept);
  if Fmt = pfOpenMetrics then
    ContentType := PromOpenMetricsContentType
  else
    ContentType := PromContentType;
  Result := MetricsBody(Registry, Fmt);
end;

end.
