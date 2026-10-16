{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit prom_registry;
{ Thread-safe collection of metrics. Registration and scraping take a short
  lock only to copy the metric list; values are read lock-free. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, SyncObjs, prom_metrics, prom_exposition, prom_sketch;

type
  TPromRegistry = class
  private
    FLock: TCriticalSection;
    FMetrics: TList;
    FNames: TStringList;   // every name claimed by a registered metric (see PromClaimedNames)
  public
    constructor Create;
    destructor Destroy; override;
    { The registry takes ownership of M. Duplicate names raise EArgumentException. }
    function Register(M: TPromMetric): TPromMetric;
    function Counter(const Name, Help: string): TPromCounter; overload;
    function Counter(const Name, Help: string; const LabelNames: array of string): TPromCounter; overload;
    function Gauge(const Name, Help: string): TPromGauge; overload;
    function Gauge(const Name, Help: string; const LabelNames: array of string): TPromGauge; overload;
    function Histogram(const Name, Help: string; const Buckets: array of Double): TPromHistogram; overload;
    function Histogram(const Name, Help: string; const LabelNames: array of string;
      const Buckets: array of Double): TPromHistogram; overload;
    function Summary(const Name, Help: string): TPromSummary; overload;
    function Summary(const Name, Help: string; const LabelNames: array of string): TPromSummary; overload;
    { With quantiles (strictly ascending, 0..1; pass [] for LabelNames if there are none):
      windowed relative-error estimates, defaults from PromDefaultSketchOptions. }
    function Summary(const Name, Help: string; const LabelNames: array of string;
      const Quantiles: array of Double): TPromSummary; overload;
    function Summary(const Name, Help: string; const LabelNames: array of string;
      const Quantiles: array of Double; const Options: TPromSketchOptions): TPromSummary; overload;
    function Untyped(const Name, Help: string): TPromUntyped; overload;
    function Untyped(const Name, Help: string; const LabelNames: array of string): TPromUntyped; overload;
    function Info(const Name, Help: string; const LabelNames: array of string): TPromInfo;
    function Collect(AFormat: TPromFormat = pfText): string;
  end;

function DefaultRegistry: TPromRegistry;

implementation

var
  GDefault: TPromRegistry;

function DefaultRegistry: TPromRegistry;
begin
  Result := GDefault;
end;

constructor TPromRegistry.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FMetrics := TList.Create;
  FNames := TStringList.Create;
  FNames.CaseSensitive := True;
  FNames.Sorted := True;
  FNames.Duplicates := dupIgnore;
end;

destructor TPromRegistry.Destroy;
var
  I: Integer;
begin
  for I := 0 to FMetrics.Count - 1 do
    TObject(FMetrics[I]).Free;
  FMetrics.Free;
  FNames.Free;
  FLock.Free;
  inherited Destroy;
end;

function TPromRegistry.Register(M: TPromMetric): TPromMetric;
var
  I, Idx: Integer;
  MName, Clash: string;
  Claimed: TStringList;
begin
  MName := M.Name;          // M is freed on failure, so keep what the message needs
  Clash := '';
  Claimed := TStringList.Create;
  try
    PromClaimedNames(M.ExposedType, MName, Claimed);
    FLock.Enter;
    try
      for I := 0 to FMetrics.Count - 1 do
        if TPromMetric(FMetrics[I]).Name = MName then
          Clash := 'dup';
      if Clash = '' then
        for I := 0 to Claimed.Count - 1 do
          if FNames.Find(Claimed[I], Idx) then
          begin
            Clash := Claimed[I];
            Break;
          end;
      if Clash = '' then
      begin
        FMetrics.Add(M);
        for I := 0 to Claimed.Count - 1 do
          FNames.Add(Claimed[I]);
      end;
    finally
      FLock.Leave;
    end;
  finally
    Claimed.Free;
  end;
  if Clash <> '' then
  begin
    M.Free;
    if Clash = 'dup' then
      raise EArgumentException.CreateFmt('Metric "%s" already registered', [MName])
    else
      raise EArgumentException.CreateFmt(
        'Metric "%s" clashes with an existing metric on the name "%s" (OpenMetrics sample names)',
        [MName, Clash]);
  end;
  Result := M;
end;

function TPromRegistry.Counter(const Name, Help: string): TPromCounter;
begin
  Result := Counter(Name, Help, []);
end;

function TPromRegistry.Counter(const Name, Help: string;
  const LabelNames: array of string): TPromCounter;
begin
  Result := Register(TPromCounter.Create(Name, Help, LabelNames)) as TPromCounter;
end;

function TPromRegistry.Gauge(const Name, Help: string): TPromGauge;
begin
  Result := Gauge(Name, Help, []);
end;

function TPromRegistry.Gauge(const Name, Help: string;
  const LabelNames: array of string): TPromGauge;
begin
  Result := Register(TPromGauge.Create(Name, Help, LabelNames)) as TPromGauge;
end;

function TPromRegistry.Histogram(const Name, Help: string;
  const Buckets: array of Double): TPromHistogram;
begin
  Result := Histogram(Name, Help, [], Buckets);
end;

function TPromRegistry.Histogram(const Name, Help: string;
  const LabelNames: array of string; const Buckets: array of Double): TPromHistogram;
begin
  Result := Register(TPromHistogram.Create(Name, Help, LabelNames, Buckets)) as TPromHistogram;
end;

function TPromRegistry.Summary(const Name, Help: string): TPromSummary;
begin
  Result := Summary(Name, Help, []);
end;

function TPromRegistry.Summary(const Name, Help: string;
  const LabelNames: array of string): TPromSummary;
begin
  Result := Register(TPromSummary.Create(Name, Help, LabelNames)) as TPromSummary;
end;

function TPromRegistry.Summary(const Name, Help: string; const LabelNames: array of string;
  const Quantiles: array of Double): TPromSummary;
begin
  Result := Summary(Name, Help, LabelNames, Quantiles, PromDefaultSketchOptions);
end;

function TPromRegistry.Summary(const Name, Help: string; const LabelNames: array of string;
  const Quantiles: array of Double; const Options: TPromSketchOptions): TPromSummary;
begin
  Result := Register(TPromSummary.Create(Name, Help, LabelNames, Quantiles, Options)) as TPromSummary;
end;

function TPromRegistry.Untyped(const Name, Help: string): TPromUntyped;
begin
  Result := Untyped(Name, Help, []);
end;

function TPromRegistry.Untyped(const Name, Help: string;
  const LabelNames: array of string): TPromUntyped;
begin
  Result := Register(TPromUntyped.Create(Name, Help, LabelNames)) as TPromUntyped;
end;

function TPromRegistry.Info(const Name, Help: string;
  const LabelNames: array of string): TPromInfo;
begin
  Result := Register(TPromInfo.Create(Name, Help, LabelNames)) as TPromInfo;
end;

function TPromRegistry.Collect(AFormat: TPromFormat): string;
var
  Snapshot: TList;
  W: TPromTextWriter;
  I: Integer;
begin
  Snapshot := TList.Create;
  try
    FLock.Enter;
    try
      Snapshot.Assign(FMetrics);
    finally
      FLock.Leave;
    end;
    W := TPromTextWriter.Create(AFormat);
    try
      for I := 0 to Snapshot.Count - 1 do
        TPromMetric(Snapshot[I]).Collect(W);
      W.Finish;
      Result := W.Text;
    finally
      W.Free;
    end;
  finally
    Snapshot.Free;
  end;
end;

initialization
  GDefault := TPromRegistry.Create;

finalization
  GDefault.Free;

end.
