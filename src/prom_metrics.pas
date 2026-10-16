{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit prom_metrics;
{ Metric families: counter, gauge, histogram, each with optional labels.

  A family owns one child per distinct label-value combination. Children are
  created on first use and never removed, so a child pointer stays valid for the
  lifetime of the family. In hot code, cache the child:

    Ok := Requests.Labels(['GET', '200']);   // once
    Ok.Inc;                                  // lock-free, per request

  Labels() itself takes a read lock for the lookup (write lock only the first
  time a combination is seen). Value updates are always lock-free. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, prom_atomic, prom_exposition;

type
  TPromMetric = class
  private
    FName: string;
    FHelp: string;
  public
    constructor Create(const AName, AHelp: string);
    procedure Collect(W: TPromTextWriter); virtual; abstract;
    property Name: string read FName;
    property Help: string read FHelp;
  end;

  { One time series (one label-value combination). }
  TPromChild = class
  private
    FPairs: string;   // preformatted, escaped: a="x",b="y"
  protected
    procedure CollectSamples(W: TPromTextWriter; const MetricName: string); virtual; abstract;
  end;

  TPromFamily = class(TPromMetric)
  private
    FLabelNames: array of string;
    FLock: TMultiReadExclusiveWriteSynchronizer;
    FChildren: TStringList;      // sorted by key; objects are owned
    FNoLabels: TPromChild;       // set for label-less families, immutable after Create
    function MakeKey(const Values: array of string): string;
  protected
    function CreateChild: TPromChild; virtual; abstract;
    function MetricType: string; virtual; abstract;
    function GetChild(const Values: array of string): TPromChild;
    function NoLabelChild: TPromChild;
  public
    constructor Create(const AName, AHelp: string; const ALabelNames: array of string);
    destructor Destroy; override;
    procedure Collect(W: TPromTextWriter); override;
  end;

  { Counter }

  TPromCounterChild = class(TPromChild)
  private
    FBits: Int64;
  protected
    procedure CollectSamples(W: TPromTextWriter; const MetricName: string); override;
  public
    procedure Inc(Delta: Double = 1);
    function Value: Double;
  end;

  TPromCounter = class(TPromFamily)
  protected
    function CreateChild: TPromChild; override;
    function MetricType: string; override;
  public
    function Labels(const Values: array of string): TPromCounterChild;
    { Shortcuts for a family without labels. }
    procedure Inc(Delta: Double = 1);
    function Value: Double;
  end;

  { Gauge }

  TPromGaugeChild = class(TPromChild)
  private
    FBits: Int64;
  protected
    procedure CollectSamples(W: TPromTextWriter; const MetricName: string); override;
  public
    procedure Inc(Delta: Double = 1);
    procedure Dec(Delta: Double = 1);
    procedure SetValue(V: Double);
    function Value: Double;
  end;

  TPromGauge = class(TPromFamily)
  protected
    function CreateChild: TPromChild; override;
    function MetricType: string; override;
  public
    function Labels(const Values: array of string): TPromGaugeChild;
    procedure Inc(Delta: Double = 1);
    procedure Dec(Delta: Double = 1);
    procedure SetValue(V: Double);
    function Value: Double;
  end;

  { Histogram }

  TPromHistogram = class;

  TPromHistogramChild = class(TPromChild)
  private
    FOwner: TPromHistogram;
    FCounts: array of Int64;   // per bucket (not cumulative); last = +Inf
    FSumBits: Int64;
  protected
    procedure CollectSamples(W: TPromTextWriter; const MetricName: string); override;
  public
    constructor Create(AOwner: TPromHistogram);
    procedure Observe(V: Double);
  end;

  TPromHistogram = class(TPromFamily)
  private
    FUpper: array of Double;   // strictly ascending upper bounds, without +Inf
  protected
    function CreateChild: TPromChild; override;
    function MetricType: string; override;
  public
    constructor Create(const AName, AHelp: string; const ALabelNames: array of string;
      const Buckets: array of Double);
    function Labels(const Values: array of string): TPromHistogramChild;
    procedure Observe(V: Double);
  end;

implementation

{ TPromMetric }

constructor TPromMetric.Create(const AName, AHelp: string);
begin
  inherited Create;
  if not PromValidMetricName(AName) then
    raise EArgumentException.CreateFmt('Invalid metric name "%s"', [AName]);
  FName := AName;
  FHelp := AHelp;
end;

{ TPromFamily }

constructor TPromFamily.Create(const AName, AHelp: string; const ALabelNames: array of string);
var
  I, J: Integer;
begin
  inherited Create(AName, AHelp);
  SetLength(FLabelNames, Length(ALabelNames));
  for I := 0 to High(ALabelNames) do
  begin
    if not PromValidLabelName(ALabelNames[I]) then
      raise EArgumentException.CreateFmt('Invalid label name "%s"', [ALabelNames[I]]);
    for J := 0 to I - 1 do
      if FLabelNames[J] = ALabelNames[I] then
        raise EArgumentException.CreateFmt('Duplicate label name "%s"', [ALabelNames[I]]);
    FLabelNames[I] := ALabelNames[I];
  end;
  FLock := TMultiReadExclusiveWriteSynchronizer.Create;
  FChildren := TStringList.Create;
  FChildren.CaseSensitive := True;
  FChildren.Sorted := True;
  FChildren.OwnsObjects := True;
  if Length(FLabelNames) = 0 then
    FNoLabels := CreateChild;   // subclasses must be ready for this before inherited Create
end;

destructor TPromFamily.Destroy;
begin
  FNoLabels.Free;
  FChildren.Free;
  FLock.Free;
  inherited Destroy;
end;

function TPromFamily.MakeKey(const Values: array of string): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(Values) do
    Result := Result + IntToStr(Length(Values[I])) + ':' + Values[I];
end;

function TPromFamily.NoLabelChild: TPromChild;
begin
  if FNoLabels = nil then
    raise EInvalidOperation.CreateFmt('Metric "%s" has labels; use Labels(...)', [FName]);
  Result := FNoLabels;
end;

function TPromFamily.GetChild(const Values: array of string): TPromChild;
var
  Key: string;
  Idx: Integer;
begin
  if Length(Values) <> Length(FLabelNames) then
    raise EArgumentException.CreateFmt('Metric "%s" expects %d label value(s), got %d',
      [FName, Length(FLabelNames), Length(Values)]);
  if FNoLabels <> nil then
    Exit(FNoLabels);

  Key := MakeKey(Values);
  Result := nil;
  FLock.BeginRead;
  try
    if FChildren.Find(Key, Idx) then
      Result := TPromChild(FChildren.Objects[Idx]);
  finally
    FLock.EndRead;
  end;
  if Result <> nil then
    Exit;

  FLock.BeginWrite;
  try
    if FChildren.Find(Key, Idx) then   // another thread may have won the race
      Result := TPromChild(FChildren.Objects[Idx])
    else
    begin
      Result := CreateChild;
      Result.FPairs := PromFormatLabelPairs(FLabelNames, Values);
      FChildren.AddObject(Key, Result);
    end;
  finally
    FLock.EndWrite;
  end;
end;

procedure TPromFamily.Collect(W: TPromTextWriter);
var
  Snapshot: TList;
  I: Integer;
begin
  W.WriteHeader(FName, FHelp, MetricType);
  if FNoLabels <> nil then
  begin
    FNoLabels.CollectSamples(W, FName);
    Exit;
  end;
  Snapshot := TList.Create;
  try
    FLock.BeginRead;
    try
      for I := 0 to FChildren.Count - 1 do
        Snapshot.Add(FChildren.Objects[I]);
    finally
      FLock.EndRead;
    end;
    for I := 0 to Snapshot.Count - 1 do
      TPromChild(Snapshot[I]).CollectSamples(W, FName);
  finally
    Snapshot.Free;
  end;
end;

{ Counter }

procedure TPromCounterChild.Inc(Delta: Double);
begin
  if Delta < 0 then
    raise EArgumentException.Create('Counter cannot decrease');
  AtomicAddDouble(FBits, Delta);
end;

function TPromCounterChild.Value: Double;
begin
  Result := AtomicLoadDouble(FBits);
end;

procedure TPromCounterChild.CollectSamples(W: TPromTextWriter; const MetricName: string);
begin
  W.WriteSample(MetricName, FPairs, Value);
end;

function TPromCounter.CreateChild: TPromChild;
begin
  Result := TPromCounterChild.Create;
end;

function TPromCounter.MetricType: string;
begin
  Result := 'counter';
end;

function TPromCounter.Labels(const Values: array of string): TPromCounterChild;
begin
  Result := TPromCounterChild(GetChild(Values));
end;

procedure TPromCounter.Inc(Delta: Double);
begin
  TPromCounterChild(NoLabelChild).Inc(Delta);
end;

function TPromCounter.Value: Double;
begin
  Result := TPromCounterChild(NoLabelChild).Value;
end;

{ Gauge }

procedure TPromGaugeChild.Inc(Delta: Double);
begin
  AtomicAddDouble(FBits, Delta);
end;

procedure TPromGaugeChild.Dec(Delta: Double);
begin
  AtomicAddDouble(FBits, -Delta);
end;

procedure TPromGaugeChild.SetValue(V: Double);
begin
  AtomicStoreDouble(FBits, V);
end;

function TPromGaugeChild.Value: Double;
begin
  Result := AtomicLoadDouble(FBits);
end;

procedure TPromGaugeChild.CollectSamples(W: TPromTextWriter; const MetricName: string);
begin
  W.WriteSample(MetricName, FPairs, Value);
end;

function TPromGauge.CreateChild: TPromChild;
begin
  Result := TPromGaugeChild.Create;
end;

function TPromGauge.MetricType: string;
begin
  Result := 'gauge';
end;

function TPromGauge.Labels(const Values: array of string): TPromGaugeChild;
begin
  Result := TPromGaugeChild(GetChild(Values));
end;

procedure TPromGauge.Inc(Delta: Double);
begin
  TPromGaugeChild(NoLabelChild).Inc(Delta);
end;

procedure TPromGauge.Dec(Delta: Double);
begin
  TPromGaugeChild(NoLabelChild).Dec(Delta);
end;

procedure TPromGauge.SetValue(V: Double);
begin
  TPromGaugeChild(NoLabelChild).SetValue(V);
end;

function TPromGauge.Value: Double;
begin
  Result := TPromGaugeChild(NoLabelChild).Value;
end;

{ Histogram }

constructor TPromHistogramChild.Create(AOwner: TPromHistogram);
begin
  inherited Create;
  FOwner := AOwner;
  SetLength(FCounts, Length(AOwner.FUpper) + 1);
end;

procedure TPromHistogramChild.Observe(V: Double);
var
  Lo, Hi, Mid: Integer;
begin
  Lo := 0;
  Hi := Length(FOwner.FUpper);   // index of the +Inf bucket
  while Lo < Hi do
  begin
    Mid := (Lo + Hi) div 2;
    if V <= FOwner.FUpper[Mid] then Hi := Mid else Lo := Mid + 1;
  end;
  AtomicAddInt64(FCounts[Lo], 1);
  AtomicAddDouble(FSumBits, V);
end;

procedure TPromHistogramChild.CollectSamples(W: TPromTextWriter; const MetricName: string);
var
  I: Integer;
  Cum: Int64;
  Sep: string;
begin
  if FPairs = '' then Sep := '' else Sep := FPairs + ',';
  Cum := 0;
  for I := 0 to High(FOwner.FUpper) do
  begin
    Cum := Cum + AtomicLoadInt64(FCounts[I]);
    W.WriteSample(MetricName + '_bucket', Sep + 'le="' + PromFormatFloat(FOwner.FUpper[I]) + '"', Cum);
  end;
  Cum := Cum + AtomicLoadInt64(FCounts[High(FCounts)]);
  W.WriteSample(MetricName + '_bucket', Sep + 'le="+Inf"', Cum);
  W.WriteSample(MetricName + '_sum', FPairs, AtomicLoadDouble(FSumBits));
  W.WriteSample(MetricName + '_count', FPairs, Cum);
end;

constructor TPromHistogram.Create(const AName, AHelp: string;
  const ALabelNames: array of string; const Buckets: array of Double);
var
  I: Integer;
begin
  // FUpper must be ready before inherited Create, which builds the label-less child.
  SetLength(FUpper, Length(Buckets));
  for I := 0 to High(Buckets) do
  begin
    if (I > 0) and (Buckets[I] <= Buckets[I - 1]) then
      raise EArgumentException.Create('Histogram buckets must be strictly ascending');
    FUpper[I] := Buckets[I];
  end;
  for I := 0 to High(ALabelNames) do
    if ALabelNames[I] = 'le' then
      raise EArgumentException.Create('Label name "le" is reserved for histograms');
  inherited Create(AName, AHelp, ALabelNames);
end;

function TPromHistogram.CreateChild: TPromChild;
begin
  Result := TPromHistogramChild.Create(Self);
end;

function TPromHistogram.MetricType: string;
begin
  Result := 'histogram';
end;

function TPromHistogram.Labels(const Values: array of string): TPromHistogramChild;
begin
  Result := TPromHistogramChild(GetChild(Values));
end;

procedure TPromHistogram.Observe(V: Double);
begin
  TPromHistogramChild(NoLabelChild).Observe(V);
end;

end.
