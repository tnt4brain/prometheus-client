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
  PromOpenMetricsContentType = 'application/openmetrics-text; version=1.0.0; charset=utf-8';

type
  TPromFormat = (pfText, pfOpenMetrics);

function PromEscapeLabelValue(const S: string): string;
function PromEscapeHelp(const S: string): string;
function PromFormatFloat(V: Double): string;
function PromValidMetricName(const S: string): Boolean;
function PromValidLabelName(const S: string): Boolean;
{ a="x",b="y" with values escaped; Names and Values must have equal length. }
function PromFormatLabelPairs(const Names, Values: array of string): string;

type
  { MetricType is the logical type: counter, gauge, histogram, summary, untyped or info.
    The writer maps it to the chosen format: untyped is "unknown" and info a gauge in
    OpenMetrics resp. text format; a counter's family name loses "_total" in OpenMetrics
    (its samples keep/gain it), an info family's name loses "_info". }
  TPromTextWriter = class
  private
    FOut: TStringStream;
    FFormat: TPromFormat;
  public
    constructor Create(AFormat: TPromFormat = pfText);
    destructor Destroy; override;
    procedure WriteHeader(const Name, Help, MetricType: string);
    { Name of the sample lines for a family registered as Name (counters: ..._total in
      OpenMetrics). Suffixes like _bucket/_sum/_count are appended by the caller. }
    function SampleName(const MetricType, Name: string): string;
    { Text of a histogram "le" label value: OpenMetrics wants a float, 1 becomes 1.0. }
    function FormatLe(V: Double): string;
    { LabelPairs is already formatted, e.g. method="GET",code="200"; may be empty. }
    procedure WriteSample(const Name, LabelPairs: string; Value: Double);
    { Terminates the document (# EOF in OpenMetrics, nothing in text format). }
    procedure Finish;
    function Text: string;
    property Format: TPromFormat read FFormat;
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

{ Shortest decimal text that parses back to the same Double. Str() with a width
  yields exactly P significant digits (FloatToStrF caps Double at 15); 15 digits
  with trailing zeros stripped is already the shortest form when it round-trips,
  and 17 always does. }
function PromFormatFloat(V: Double): string;
var
  P, E, N, K: Integer;
  S, Digits, Sign: string;
  Back: Double;
begin
  if IsNan(V) then
    Exit('NaN');
  if IsInfinite(V) then
  begin
    if V > 0 then Exit('+Inf') else Exit('-Inf');
  end;
  for P := 15 to 17 do
  begin
    Str(V:(P + 7), S);  // ' d.dddE+xxx' (sign or space first)
    S := Trim(S);
    if (P = 17) or (TryStrToFloat(S, Back, PromFormat) and (Back = V)) then
      Break;
  end;
  Sign := '';
  if S[1] = '-' then
  begin
    Sign := '-';
    Delete(S, 1, 1);
  end;
  K := Pos('E', S);
  E := StrToInt(Copy(S, K + 1, MaxInt));
  Digits := S[1] + Copy(S, 3, K - 3);
  N := Length(Digits);
  while (N > 1) and (Digits[N] = '0') do
    Dec(N);
  SetLength(Digits, N);
  if (E >= 0) and (E < 21) then
  begin
    if N <= E + 1 then
      Result := Digits + StringOfChar('0', E + 1 - N)
    else
      Result := Copy(Digits, 1, E + 1) + '.' + Copy(Digits, E + 2, MaxInt);
  end
  else if (E < 0) and (E >= -7) then
    Result := '0.' + StringOfChar('0', -E - 1) + Digits
  else
  begin
    Result := Digits[1];
    if N > 1 then
      Result := Result + '.' + Copy(Digits, 2, MaxInt);
    Result := Result + 'e' + IntToStr(E);
    if E > 0 then
      Insert('+', Result, Pos('e', Result) + 1);
  end;
  Result := Sign + Result;
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

constructor TPromTextWriter.Create(AFormat: TPromFormat);
begin
  inherited Create;
  FFormat := AFormat;
  FOut := TStringStream.Create('');
end;

function StripSuffix(const Name, Suffix: string): string;
begin
  Result := Name;
  if (Length(Name) > Length(Suffix)) and
     (Copy(Name, Length(Name) - Length(Suffix) + 1, Length(Suffix)) = Suffix) then
    SetLength(Result, Length(Name) - Length(Suffix));
end;

function TPromTextWriter.SampleName(const MetricType, Name: string): string;
begin
  if (FFormat = pfOpenMetrics) and (MetricType = 'counter') then
    Result := StripSuffix(Name, '_total') + '_total'
  else
    Result := Name;
end;

function TPromTextWriter.FormatLe(V: Double): string;
begin
  Result := PromFormatFloat(V);
  if (FFormat = pfOpenMetrics) and not IsInfinite(V) and not IsNan(V) and
     (Pos('.', Result) = 0) and (Pos('e', Result) = 0) then
    Result := Result + '.0';
end;

destructor TPromTextWriter.Destroy;
begin
  FOut.Free;
  inherited Destroy;
end;

procedure TPromTextWriter.WriteHeader(const Name, Help, MetricType: string);
var
  N, T, H: string;
begin
  N := Name;
  T := MetricType;
  if FFormat = pfOpenMetrics then
  begin
    if T = 'counter' then
      N := StripSuffix(N, '_total')
    else if T = 'info' then
      N := StripSuffix(N, '_info')
    else if T = 'untyped' then
      T := 'unknown';
    H := PromEscapeLabelValue(Help);   // OpenMetrics HELP also escapes quotes
  end
  else
  begin
    if T = 'info' then
      T := 'gauge';
    H := PromEscapeHelp(Help);
  end;
  if Help <> '' then
    FOut.WriteString('# HELP ' + N + ' ' + H + #10);
  FOut.WriteString('# TYPE ' + N + ' ' + T + #10);
end;

procedure TPromTextWriter.Finish;
begin
  if FFormat = pfOpenMetrics then
    FOut.WriteString('# EOF' + #10);
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
