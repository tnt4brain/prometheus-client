{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit prom_exposition;
{ Prometheus text exposition format 0.0.4: escaping, number formatting and a
  small writer that metrics use to emit their samples. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Math;

const
  PromContentType = 'text/plain; version=0.0.4; charset=utf-8';

function PromEscapeLabelValue(const S: string): string;
function PromEscapeHelp(const S: string): string;
function PromFormatFloat(V: Double): string;
function PromValidMetricName(const S: string): Boolean;
function PromValidLabelName(const S: string): Boolean;
{ a="x",b="y" with values escaped; Names and Values must have equal length. }
function PromFormatLabelPairs(const Names, Values: array of string): string;

type
  TPromTextWriter = class
  private
    FOut: TStringStream;
  public
    constructor Create;
    destructor Destroy; override;
    procedure WriteHeader(const Name, Help, MetricType: string);
    { LabelPairs is already formatted, e.g. method="GET",code="200"; may be empty. }
    procedure WriteSample(const Name, LabelPairs: string; Value: Double);
    function Text: string;
  end;

implementation

var
  PromFormat: TFormatSettings;

function PromEscapeLabelValue(const S: string): string;
begin
  Result := StringReplace(S, '\', '\\', [rfReplaceAll]);
  Result := StringReplace(Result, '"', '\"', [rfReplaceAll]);
  Result := StringReplace(Result, #10, '\n', [rfReplaceAll]);
end;

function PromEscapeHelp(const S: string): string;
begin
  Result := StringReplace(S, '\', '\\', [rfReplaceAll]);
  Result := StringReplace(Result, #10, '\n', [rfReplaceAll]);
end;

function PromFormatFloat(V: Double): string;
begin
  if IsNan(V) then
    Result := 'NaN'
  else if IsInfinite(V) then
  begin
    if V > 0 then Result := '+Inf' else Result := '-Inf';
  end
  else
    Result := FloatToStr(V, PromFormat);  // TODO: shortest round-trip form
end;

function PromValidMetricName(const S: string): Boolean;
var
  I: Integer;
begin
  Result := (S <> '') and (S[1] in ['a'..'z', 'A'..'Z', '_', ':']);
  if Result then
    for I := 2 to Length(S) do
      if not (S[I] in ['a'..'z', 'A'..'Z', '0'..'9', '_', ':']) then
        Exit(False);
end;

function PromValidLabelName(const S: string): Boolean;
var
  I: Integer;
begin
  Result := (S <> '') and (S[1] in ['a'..'z', 'A'..'Z', '_']) and (Copy(S, 1, 2) <> '__');
  if Result then
    for I := 2 to Length(S) do
      if not (S[I] in ['a'..'z', 'A'..'Z', '0'..'9', '_']) then
        Exit(False);
end;

function PromFormatLabelPairs(const Names, Values: array of string): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(Names) do
  begin
    if I > 0 then
      Result := Result + ',';
    Result := Result + Names[I] + '="' + PromEscapeLabelValue(Values[I]) + '"';
  end;
end;

{ TPromTextWriter }

constructor TPromTextWriter.Create;
begin
  inherited Create;
  FOut := TStringStream.Create('');
end;

destructor TPromTextWriter.Destroy;
begin
  FOut.Free;
  inherited Destroy;
end;

procedure TPromTextWriter.WriteHeader(const Name, Help, MetricType: string);
begin
  if Help <> '' then
    FOut.WriteString('# HELP ' + Name + ' ' + PromEscapeHelp(Help) + #10);
  FOut.WriteString('# TYPE ' + Name + ' ' + MetricType + #10);
end;

procedure TPromTextWriter.WriteSample(const Name, LabelPairs: string; Value: Double);
begin
  if LabelPairs = '' then
    FOut.WriteString(Name + ' ' + PromFormatFloat(Value) + #10)
  else
    FOut.WriteString(Name + '{' + LabelPairs + '} ' + PromFormatFloat(Value) + #10);
end;

function TPromTextWriter.Text: string;
begin
  Result := FOut.DataString;
end;

initialization
  PromFormat := DefaultFormatSettings;
  PromFormat.DecimalSeparator := '.';
  PromFormat.ThousandSeparator := #0;

end.
