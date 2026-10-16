{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit prom_mormot;
{ Optional bridge: publish mORMot 2 monitor objects (TSynMonitor and descendants, e.g. the
  TSynMonitorServer of a THttpServer / TRestServer) as Prometheus metrics.

  mORMot has no Prometheus exporter of its own; it reports JSON / RTTI statistics. This unit
  walks the published integer properties of a monitor (the same ones TSynMonitorUsage tracks)
  and registers one label-less callback metric per property in a TPromRegistry:

    cumulative kinds (smvMicroSec, smvBytes, smvCount, smvCount64) -> counter
    instant kinds    (smvOneMicroSec, smvOneBytes, smvOneCount, smvBytesPerSec) -> gauge

  Microseconds are exposed as seconds. Properties of nested monitor objects (Input, Output, ...)
  are included, named <prefix>_<object>_<property>.

  This unit is NOT part of the prometheus_fpc package, so the package keeps no mORMot
  dependency: add contrib/mormot to the unit path of a project that uses mORMot.

  The monitor and its nested objects must outlive every scrape of the registry. Values are read
  without the monitor's lock (aligned integer reads), so a scrape may see a counter a moment
  stale, never a torn one on a 64-bit CPU. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, prom_registry, prom_collectors,
  mormot.core.base, mormot.core.rtti, mormot.core.perf;

{ Registers the monitor's statistics under Prefix (e.g. 'mormot_http'). Returns the number of
  metrics registered. Raises if a name is already taken in R. Call once per monitor. }
function PromRegisterSynMonitor(R: TPromRegistry; Monitor: TSynMonitor;
  const Prefix: string): Integer;

{ The Prometheus name suffix and type that a TSynMonitor property kind maps to; exposed for
  tests. Returns False for kinds that are not exported. }
function PromMonitorKindInfo(Kind: TSynMonitorType; out Suffix, MetricType: string;
  out Scale: Double): Boolean;

{ 'TotalTime' -> 'total_time', 'InputThroughput' -> 'input_throughput'. }
function PromSnakeCase(const CamelName: string): string;

implementation

uses
  Classes, contnrs;

type
  TMormotReader = class
  private
    FInstance: TObject;
    FInfo: PRttiProp;
    FScale: Double;
  public
    constructor Create(AInstance: TObject; AInfo: PRttiProp; AScale: Double);
    procedure Fill(Samples: TPromSamples);
  end;

var
  Readers: TObjectList;

constructor TMormotReader.Create(AInstance: TObject; AInfo: PRttiProp; AScale: Double);
begin
  inherited Create;
  FInstance := AInstance;
  FInfo := AInfo;
  FScale := AScale;
end;

procedure TMormotReader.Fill(Samples: TPromSamples);
begin
  Samples.Add([], Double(FInfo^.GetInt64Value(FInstance)) * FScale);
end;

function PromSnakeCase(const CamelName: string): string;
var
  I: Integer;
  C: Char;
begin
  Result := '';
  for I := 1 to Length(CamelName) do
  begin
    C := CamelName[I];
    if C in ['A'..'Z'] then
    begin
      if (I > 1) and not (CamelName[I - 1] in ['A'..'Z']) then
        Result := Result + '_';
      Result := Result + Chr(Ord(C) + 32);
    end
    else
      Result := Result + C;
  end;
end;

function PromMonitorKindInfo(Kind: TSynMonitorType; out Suffix, MetricType: string;
  out Scale: Double): Boolean;
begin
  Result := True;
  Scale := 1;
  case Kind of
    smvMicroSec:
      begin Suffix := '_seconds_total'; MetricType := 'counter'; Scale := 1e-6; end;
    smvBytes:
      begin Suffix := '_bytes_total'; MetricType := 'counter'; end;
    smvCount, smvCount64:
      begin Suffix := '_total'; MetricType := 'counter'; end;
    smvOneMicroSec:
      begin Suffix := '_seconds'; MetricType := 'gauge'; Scale := 1e-6; end;
    smvOneBytes:
      begin Suffix := '_bytes'; MetricType := 'gauge'; end;
    smvOneCount:
      begin Suffix := ''; MetricType := 'gauge'; end;
    smvBytesPerSec:
      begin Suffix := '_bytes_per_second'; MetricType := 'gauge'; end;
  else
    Result := False;
  end;
end;

{ Human HELP text from the property path, e.g. 'input' + bytes -> 'Bytes received.',
  'total time' + micro-seconds -> 'Total time in seconds.', 'task count' -> 'Task count.' }
function PromMonitorHelp(const Words: string; Kind: TSynMonitorType): string;
begin
  if (Kind in [smvBytes, smvOneBytes]) and (Words = 'input') then
    Exit('Bytes received.');
  if (Kind in [smvBytes, smvOneBytes]) and (Words = 'output') then
    Exit('Bytes sent.');
  Result := UpCase(Words[1]) + Copy(Words, 2, MaxInt);
  case Kind of
    smvMicroSec, smvOneMicroSec: Result := Result + ' in seconds';
    smvBytes, smvOneBytes: Result := Result + ' in bytes';
    smvBytesPerSec: Result := Result + ' in bytes per second';
  end;
  Result := Result + '.';
end;

function RegisterObject(R: TPromRegistry; Instance: TObject; const Prefix, Words: string;
  Depth: Integer): Integer;
var
  C, Parent: TClass;
  I: PtrInt;
  Info: PRttiProp;
  Kind: TSynMonitorType;
  Suffix, MType, Base, W: string;
  Scale: Double;
  Reader: TMormotReader;
  Sub: TObject;
begin
  Result := 0;
  C := PClass(Instance)^;
  while C <> nil do
  begin
    Parent := GetClassParent(C);
    for I := 1 to GetRttiProp(C, Info) do
    begin
      Base := PromSnakeCase(string(Info^.Name^));
      Kind := MonitorPropUsageValue(Info);
      if Kind <> smvUndefined then
      begin
        if PromMonitorKindInfo(Kind, Suffix, MType, Scale) then
        begin
          Reader := TMormotReader.Create(Instance, Info, Scale);
          Readers.Add(Reader);
          if (Base = 'bytes') or (Base = 'micro_sec') then
          begin
            W := Words;  // the object path already names it
            Base := '';
          end
          else
          begin
            W := Trim(Words + ' ' + StringReplace(Base, '_', ' ', [rfReplaceAll]));
            Base := '_' + Base;
          end;
          R.Register(TPromCallbackFamily.Create(Prefix + Base + Suffix,
            PromMonitorHelp(W, Kind), MType, [],
            @Reader.Fill));
          Inc(Result);
        end;
      end
      else if (Depth < 3) and (Info^.TypeInfo^.Kind = rkClass) then
      begin
        Sub := Info^.GetObjProp(Instance);
        if (Sub <> nil) and Sub.InheritsFrom(TSynPersistent) then
          Inc(Result, RegisterObject(R, Sub, Prefix + '_' + Base, Trim(Words + ' ' + StringReplace(Base, '_', ' ', [rfReplaceAll])), Depth + 1));
      end;
      Info := Info^.Next;
    end;
    C := Parent;
  end;
end;

function PromRegisterSynMonitor(R: TPromRegistry; Monitor: TSynMonitor;
  const Prefix: string): Integer;
begin
  if (R = nil) or (Monitor = nil) then
    raise EArgumentException.Create('PromRegisterSynMonitor: nil argument');
  Result := RegisterObject(R, Monitor, Prefix, '', 0);
end;

initialization
  Readers := TObjectList.Create(True);

finalization
  Readers.Free;

end.
