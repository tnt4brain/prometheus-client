{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit prom_registry;
{ Thread-safe collection of metrics. Registration and scraping take a short
  lock only to copy the metric list; values are read lock-free. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, SyncObjs, prom_metrics, prom_exposition;

type
  TPromRegistry = class
  private
    FLock: TCriticalSection;
    FMetrics: TList;
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
    function Collect: string;
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
end;

destructor TPromRegistry.Destroy;
var
  I: Integer;
begin
  for I := 0 to FMetrics.Count - 1 do
    TObject(FMetrics[I]).Free;
  FMetrics.Free;
  FLock.Free;
  inherited Destroy;
end;

function TPromRegistry.Register(M: TPromMetric): TPromMetric;
var
  I: Integer;
begin
  FLock.Enter;
  try
    for I := 0 to FMetrics.Count - 1 do
      if TPromMetric(FMetrics[I]).Name = M.Name then
      begin
        M.Free;
        raise EArgumentException.CreateFmt('Metric "%s" already registered', [M.Name]);
      end;
    FMetrics.Add(M);
  finally
    FLock.Leave;
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

function TPromRegistry.Collect: string;
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
    W := TPromTextWriter.Create;
    try
      for I := 0 to Snapshot.Count - 1 do
        TPromMetric(Snapshot[I]).Collect(W);
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
