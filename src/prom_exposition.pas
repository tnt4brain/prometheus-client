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

  { An OpenMetrics exemplar: a sample plus the labels (e.g. trace_id) of one concrete
    observation. Pairs is preformatted and escaped; HasValue = False means "none". }
  TPromExemplar = record
    HasValue: Boolean;
    Pairs: string;
    Value: Double;
    Timestamp: Double;   // Unix seconds
  end;

const
  PromNoExemplar: TPromExemplar = (HasValue: False; Pairs: ''; Value: 0; Timestamp: 0);
  { Limit on the combined length of exemplar label names and values, in UTF-8 code points. }
  PromMaxExemplarRunes = 128;

function PromEscapeLabelValue(const S: string): string;
function PromEscapeHelp(const S: string): string;
function PromFormatFloat(V: Double): string;
{ Name without Suffix when it ends with it (and is longer), else Name unchanged. }
function PromStripSuffix(const Name, Suffix: string): string;
{ The metric family name used in OpenMetrics # TYPE/# UNIT/# HELP lines: a counter loses
  "_total", an info metric loses "_info". MetricType is the logical type string. }
function PromOpenMetricsFamilyName(const MetricType, Name: string): string;
function PromValidMetricName(const S: string): Boolean;
function PromValidLabelName(const S: string): Boolean;
{ a="x",b="y" with values escaped; Names and Values must have equal length. }
function PromFormatLabelPairs(const Names, Values: array of string): string;
{ Builds an exemplar from alternating name, value strings (['trace_id', 'abc']). Raises
  EArgumentException for an odd count, an invalid label name, or more than
  PromMaxExemplarRunes UTF-8 code points in all names and values together. }
function PromMakeExemplar(const NameValuePairs: array of string; Value, Timestamp: Double): TPromExemplar;

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
    { OpenMetrics order is TYPE, UNIT, HELP (the spec says SHOULD); the text format has
      HELP then TYPE and no UNIT. }
    procedure WriteHeader(const Name, Help, MetricType: string; const MetricUnit: string = '');
    { Name of the sample lines for a family registered as Name (counters: ..._total in
      OpenMetrics). Suffixes like _bucket/_sum/_count are appended by the caller. }
    function SampleName(const MetricType, Name: string): string;
    { Text of a histogram "le" label value: OpenMetrics wants a float, 1 becomes 1.0. }
    function FormatLe(V: Double): string;
    { LabelPairs is already formatted, e.g. method="GET",code="200"; may be empty. }
    procedure WriteSample(const Name, LabelPairs: string; Value: Double); overload;
    { Same, followed by the exemplar in OpenMetrics (ignored in the text format). }
    procedure WriteSample(const Name, LabelPairs: string; Value: Double;
      const Exemplar: TPromExemplar); overload;
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

function Utf8Length(const S: string): Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 1 to Length(S) do
    if (Ord(S[I]) and $C0) <> $80 then   // continuation bytes do not start a code point
      Result := Result + 1;
end;

function PromMakeExemplar(const NameValuePairs: array of string; Value, Timestamp: Double): TPromExemplar;
var
  I, Runes: Integer;
  Names, Values: array of string;
begin
  if Odd(Length(NameValuePairs)) then
    raise EArgumentException.Create('Exemplar labels must be name, value pairs');
  SetLength(Names, Length(NameValuePairs) div 2);
  SetLength(Values, Length(Names));
  Runes := 0;
  for I := 0 to High(Names) do
  begin
    Names[I] := NameValuePairs[2 * I];
    Values[I] := NameValuePairs[2 * I + 1];
    if not PromValidLabelName(Names[I]) then
      raise EArgumentException.CreateFmt('Invalid exemplar label name "%s"', [Names[I]]);
    Runes := Runes + Utf8Length(Names[I]) + Utf8Length(Values[I]);
  end;
  if Runes > PromMaxExemplarRunes then
    raise EArgumentException.CreateFmt('Exemplar labels exceed %d characters (%d)',
      [PromMaxExemplarRunes, Runes]);
  Result.HasValue := True;
  Result.Pairs := PromFormatLabelPairs(Names, Values);
  Result.Value := Value;
  Result.Timestamp := Timestamp;
end;

{ TPromTextWriter }

constructor TPromTextWriter.Create(AFormat: TPromFormat);
begin
  inherited Create;
  FFormat := AFormat;
  FOut := TStringStream.Create('');
end;

function PromStripSuffix(const Name, Suffix: string): string;
begin
  Result := Name;
  if (Length(Name) > Length(Suffix)) and
     (Copy(Name, Length(Name) - Length(Suffix) + 1, Length(Suffix)) = Suffix) then
    SetLength(Result, Length(Name) - Length(Suffix));
end;

function PromOpenMetricsFamilyName(const MetricType, Name: string): string;
begin
  if MetricType = 'counter' then
    Result := PromStripSuffix(Name, '_total')
  else if MetricType = 'info' then
    Result := PromStripSuffix(Name, '_info')
  else
    Result := Name;
end;

function TPromTextWriter.SampleName(const MetricType, Name: string): string;
begin
  if (FFormat = pfOpenMetrics) and (MetricType = 'counter') then
    Result := PromStripSuffix(Name, '_total') + '_total'
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

procedure TPromTextWriter.WriteHeader(const Name, Help, MetricType: string;
  const MetricUnit: string);
var
  N, T, H: string;
begin
  T := MetricType;
  if FFormat = pfOpenMetrics then
  begin
    N := PromOpenMetricsFamilyName(T, Name);
    if T = 'untyped' then
      T := 'unknown';
    H := PromEscapeLabelValue(Help);   // OpenMetrics HELP also escapes quotes
  end
  else
  begin
    N := Name;
    if T = 'info' then
      T := 'gauge';
    H := PromEscapeHelp(Help);
  end;
  if FFormat = pfOpenMetrics then
  begin
    FOut.WriteString('# TYPE ' + N + ' ' + T + #10);
    if MetricUnit <> '' then
      FOut.WriteString('# UNIT ' + N + ' ' + MetricUnit + #10);
    if Help <> '' then
      FOut.WriteString('# HELP ' + N + ' ' + H + #10);
  end
  else
  begin
    if Help <> '' then
      FOut.WriteString('# HELP ' + N + ' ' + H + #10);
    FOut.WriteString('# TYPE ' + N + ' ' + T + #10);
  end;
end;

procedure TPromTextWriter.WriteSample(const Name, LabelPairs: string; Value: Double;
  const Exemplar: TPromExemplar);
var
  Line: string;
begin
  if (FFormat <> pfOpenMetrics) or not Exemplar.HasValue then
  begin
    WriteSample(Name, LabelPairs, Value);
    Exit;
  end;
  if LabelPairs = '' then
    Line := Name + ' ' + PromFormatFloat(Value)
  else
    Line := Name + '{' + LabelPairs + '} ' + PromFormatFloat(Value);
  FOut.WriteString(Line + ' # {' + Exemplar.Pairs + '} ' + PromFormatFloat(Exemplar.Value) +
    ' ' + PromFormatFloat(Exemplar.Timestamp) + #10);
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
