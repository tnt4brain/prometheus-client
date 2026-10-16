{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit prom_metrics;
{ Metric families: counter, gauge, histogram, each with optional labels.

  A family owns one child per distinct label-value combination. Children are
  created on first use. Remove/Clear retire a child instead of freeing it, so a
  child pointer from Labels() stays valid for the lifetime of the family (children that
  come and go can use Acquire/Release instead and are really freed). In hot code, cache
  the child:

    Ok := Requests.Labels(['GET', '200']);   // once
    Ok.Inc;                                  // lock-free, per request

  Labels() itself takes a read lock for the lookup (write lock only the first
  time a combination is seen). Value updates are always lock-free. }

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

uses
  SysUtils, Classes, SyncObjs, DateUtils, Math, prom_sketch, prom_atomic, prom_exposition, prom_clock;

const
  { Label value used on the shared child that absorbs combinations over MaxChildren. }
  PromOverflowLabelValue = '__overflow__';

type
  TPromMetric = class
  private
    FName: string;
    FHelp: string;
    FUnit: string;
    procedure SetUnit(const AUnit: string);
  public
    constructor Create(const AName, AHelp: string);
    procedure Collect(W: TPromTextWriter); virtual; abstract;
    { Logical type: counter, gauge, histogram, summary, untyped, info, stateset, ... }
    function ExposedType: string; virtual;
    property Name: string read FName;
    property Help: string read FHelp;
    { OpenMetrics "# UNIT" (ignored in the text format), e.g. 'seconds'. Set once, right
      after creating the metric: the family name must end with "_<unit>" (counters: without
      "_total"), and info / stateset metrics cannot have a unit. Raises EArgumentException for
      a unit that does not fit and EInvalidOperation if a unit was already set. }
    property MetricUnit: string read FUnit write SetUnit;
  end;

  { One time series (one label-value combination). }
  TPromChild = class
  private
    FPairs: string;   // preformatted, escaped: a="x",b="y"
    FCreated: Double; // Unix seconds from PromEpochSeconds, set when the family makes the child
    FExLock: TCriticalSection;   // the family's exemplar lock (not owned); guards exemplar slots
    FRefs: Int64;     // holders from Acquire and running scrapes; only changed by atomics
    FPinned: Int64;   // 1 once Labels() handed out an uncounted pointer: never freed before the family
  protected
    procedure CollectSamples(W: TPromTextWriter; const MetricName: string); virtual; abstract;
    { OpenMetrics only: the "<BaseName>_created" sample. }
    procedure WriteCreated(W: TPromTextWriter; const BaseName: string);
  end;

  TPromFamily = class(TPromMetric)
  private
    FLabelNames: array of string;
    FLock: TMultiReadExclusiveWriteSynchronizer;
    FChildren: TStringList;      // sorted by key; objects are owned
    FNoLabels: TPromChild;       // set for label-less families, immutable after Create
    FMaxChildren: Integer;       // 0 = unlimited; guarded by FLock
    FOverflow: TPromChild;       // shared child for combinations beyond the cap
    FRetired: TList;             // removed children that were handed out by Labels(): owned, freed only in Destroy
    FPending: TList;             // removed children only Acquire/scrapes saw: owned, freed by Sweep at refs = 0
    FExLock: TCriticalSection;   // shared by the children; only exemplar recording/scraping take it
    function GetRetiredCount: Integer;
    function FindOrCreate(const Values: array of string; Counted: Boolean): TPromChild;
    procedure Retire(C: TPromChild);      // caller holds the write lock
    procedure Sweep;                      // caller holds the write lock
    function MakeKey(const Values: array of string): string;
    procedure SetMaxChildren(Value: Integer);
    function GetOverflowed: Boolean;
    function OverflowChild: TPromChild;   // caller holds the write lock
    function NewChild: TPromChild;        // CreateChild + creation timestamp
  protected
    function CreateChild: TPromChild; virtual; abstract;
    function MetricType: string; virtual; abstract;
  public
    function ExposedType: string; override;
  protected
    function GetChild(const Values: array of string): TPromChild;
    function NoLabelChild: TPromChild;
  public
    constructor Create(const AName, AHelp: string; const ALabelNames: array of string);
    destructor Destroy; override;
    procedure Collect(W: TPromTextWriter); override;
    { Cardinality cap, 0 (the default) = unlimited. Once the family holds this many
      label combinations, Labels() for any new combination returns one shared child
      whose label values are all PromOverflowLabelValue; existing children are
      untouched and never evicted. Lowering the cap does not remove children. }
    property MaxChildren: Integer read FMaxChildren write SetMaxChildren;
    { Stop exposing the series for these label values; True if it existed. The child is
      retired, not freed (callers may still hold a cached pointer): it keeps accepting
      updates that no scrape sees, and its memory is released with the family. A later
      Labels() with the same values creates a fresh child starting from zero. }
    function Remove(const Values: array of string): Boolean;
    { Retire every child, including the overflow child; Overflowed becomes False. }
    procedure Clear;
    { Counted access, for label sets that come and go. Labels() returns a pointer that stays
      valid until the family is destroyed, so a child it handed out is never freed. Acquire
      returns the child with a reference taken (cast it, e.g. TPromCounterChild(F.Acquire([..])));
      the pointer is valid until the matching Release, and the series is freed only after it
      was removed (Remove/Clear) and every holder released it. Pass the same child to Release
      exactly once; using it afterwards is a bug. A child that was ever returned by Labels()
      is never freed, whatever Acquire does. Freeing happens in Remove, Clear, when a new
      child is created and in Reclaim, never in Release. }
    function Acquire(const Values: array of string): TPromChild;
    procedure Release(Child: TPromChild);
    { Free removed children nobody holds any more; returns how many were freed. }
    function Reclaim: Integer;
    { Number of removed children still in memory: those pinned by Labels() until the family
      is destroyed, plus those waiting for their last Release. }
    property RetiredCount: Integer read GetRetiredCount;
    { True once any combination has been diverted to the overflow child. }
    property Overflowed: Boolean read GetOverflowed;
  end;

  { Counter }

  TPromCounterChild = class(TPromChild)
  private
    FBits: Int64;               // the value when not striped
    FRaw: Pointer;              // striped: raw block, FCells is 64-byte aligned inside it
    FCells: PInt64;             // one cache line (8 Int64) per stripe; cell I is FCells[I * 8]
    FMask: Integer;             // stripe count - 1 (a power of two)
    FExemplar: TPromExemplar;   // latest exemplar; guarded by FExLock
    procedure Add(Delta: Double);
  protected
    procedure CollectSamples(W: TPromTextWriter; const MetricName: string); override;
  public
    constructor CreateStriped(AStripes: Integer);
    destructor Destroy; override;
    procedure Inc(Delta: Double = 1);
    { Inc plus an exemplar (alternating label name, value: ['trace_id', 'abc']) that is
      shown on the _total sample in OpenMetrics output. The exemplar is validated first:
      if it is rejected (EArgumentException) the counter is not incremented. The latest
      exemplar replaces the previous one. Takes a short lock; plain Inc stays lock-free. }
    procedure IncWithExemplar(Delta: Double; const ExemplarLabels: array of string);
    function Value: Double;
  end;

  TPromCounter = class(TPromFamily)
  private
    FStripes: Integer;
  protected
    function CreateChild: TPromChild; override;
    function MetricType: string; override;
  public
    constructor Create(const AName, AHelp: string; const ALabelNames: array of string); overload;
    { Stripes: 1 (the default) is a single atomic cell. Higher values (rounded up to a
      power of two, at most 64) give each child that many cache-line-sized cells and
      spread threads over them, trading 64 bytes per stripe per child for far less CAS
      contention on one hot counter. Value sums the cells, so it is monotonic but not
      an instantaneous snapshot while increments are in flight. }
    constructor Create(const AName, AHelp: string; const ALabelNames: array of string;
      AStripes: Integer); overload;
    function Labels(const Values: array of string): TPromCounterChild;
    { Shortcuts for a family without labels. }
    procedure Inc(Delta: Double = 1);
    procedure IncWithExemplar(Delta: Double; const ExemplarLabels: array of string);
    function Value: Double;
  end;

  { Gauge }

  TPromGaugeChild = class;

  { Returned by TrackInProgress; Done undoes the increment. A plain record: calling
    Done twice decrements twice. }
  TPromInProgress = record
  private
    FTarget: TPromGaugeChild;
  public
    procedure Done;
  end;

  TPromGaugeChild = class(TPromChild)
  private
    FBits: Int64;
  protected
    procedure CollectSamples(W: TPromTextWriter; const MetricName: string); override;
  public
    procedure Inc(Delta: Double = 1);
    procedure Dec(Delta: Double = 1);
    procedure SetValue(V: Double);
    { Unix time in seconds, with fraction (UTC). }
    procedure SetToCurrentTime;
    { Increments now; Done decrements, so the gauge counts operations in flight:

        P := InFlight.TrackInProgress;
        try
          Handle;
        finally
          P.Done;
        end; }
    function TrackInProgress: TPromInProgress;
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
    procedure SetToCurrentTime;
    function TrackInProgress: TPromInProgress;
    function Value: Double;
  end;

  { Histogram and summary share Observe and the timer. }

  TPromObserverChild = class;

  { Measures elapsed wall time with a monotonic clock and observes it, in seconds:

      T := Latency.StartTimer;      // or Latency.Labels([...]).StartTimer
      DoWork;
      T.ObserveDuration;

    A plain record: no allocation, nothing happens if ObserveDuration is not called. }
  TPromTimer = record
  private
    FTarget: TPromObserverChild;
    FStart: Double;
  public
    function ObserveDuration: Double;
  end;

  TPromObserverChild = class(TPromChild)
  public
    procedure Observe(V: Double); virtual; abstract;
    function StartTimer: TPromTimer;
  end;

  { Histogram }

  TPromHistogram = class;

  TPromHistogramChild = class(TPromObserverChild)
  private
    FOwner: TPromHistogram;
    FCounts: array of Int64;   // per bucket (not cumulative); last = +Inf
    FSumBits: Int64;
    FExemplars: array of TPromExemplar;   // one per bucket incl. +Inf, allocated on first use
    function BucketIndex(V: Double): Integer;
  protected
    procedure CollectSamples(W: TPromTextWriter; const MetricName: string); override;
  public
    constructor Create(AOwner: TPromHistogram);
    procedure Observe(V: Double); override;
    { Observe plus an exemplar stored in the bucket V falls into (latest per bucket wins)
      and shown on that bucket's sample in OpenMetrics output. Validated before anything
      is recorded. See TPromCounterChild.IncWithExemplar. }
    procedure ObserveWithExemplar(V: Double; const ExemplarLabels: array of string);
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
    procedure ObserveWithExemplar(V: Double; const ExemplarLabels: array of string);
    function StartTimer: TPromTimer;
  end;

  { Summary. Without quantiles it exposes only _sum and _count, which is a valid summary
    and enough for rates and averages (rate(x_sum) / rate(x_count)), and is cheaper than a
    histogram when the distribution does not matter. With quantiles each child also keeps a
    windowed log-bucket sketch (see prom_sketch: relative error, lock-free Observe) and
    exposes name{quantile="0.99"} lines before _sum and _count; _sum and _count stay
    cumulative while the quantiles cover the last MaxAge seconds. The "quantile" label is
    reserved. }

  TPromSummary = class;

  TPromSummaryChild = class(TPromObserverChild)
  private
    FCount: Int64;
    FSumBits: Int64;
    FOwner: TPromSummary;
    FSketch: TPromSketch;   // nil for a summary without quantiles
  protected
    procedure CollectSamples(W: TPromTextWriter; const MetricName: string); override;
  public
    constructor Create(AOwner: TPromSummary);
    destructor Destroy; override;
    procedure Observe(V: Double); override;
  end;

  TPromSummary = class(TPromFamily)
  private
    FQuantiles: TPromDoubleArray;
    FSketchOptions: TPromSketchOptions;
  protected
    function CreateChild: TPromChild; override;
    function MetricType: string; override;
  public
    constructor Create(const AName, AHelp: string; const ALabelNames: array of string); overload;
    { Quantiles: strictly ascending values in 0..1, e.g. [0.5, 0.9, 0.99]. }
    constructor Create(const AName, AHelp: string; const ALabelNames: array of string;
      const AQuantiles: array of Double; const AOptions: TPromSketchOptions); overload;
    function Labels(const Values: array of string): TPromSummaryChild;
    procedure Observe(V: Double);
    function StartTimer: TPromTimer;
  end;

  { Untyped: a gauge exposed with "# TYPE ... untyped", for values whose kind is
    unknown (typically bridged from another system). }
  TPromUntyped = class(TPromGauge)
  protected
    function MetricType: string; override;
  end;

  { Info: a constant 1 whose labels carry descriptive data such as a version.
    The name gets the conventional "_info" suffix if it is not there already.

      Info := Registry.Info('build', 'Build information.', ['version', 'commit']);
      Info.Publish(['1.4.2', 'bb2ba61']);   // exposes build_info with those labels, value 1 }

  TPromInfoChild = class(TPromChild)
  protected
    procedure CollectSamples(W: TPromTextWriter; const MetricName: string); override;
  end;

  TPromInfo = class(TPromFamily)
  protected
    function CreateChild: TPromChild; override;
    function MetricType: string; override;
  public
    { At least one label is required (an info metric without labels says nothing). }
    constructor Create(const AName, AHelp: string; const ALabelNames: array of string);
    function Publish(const Values: array of string): TPromInfoChild;
  end;

  { StateSet: a fixed list of named boolean states, e.g. the phases of a state machine.
    Every scrape writes one sample per state with value 0 or 1, the state name in a label
    named after the metric itself:

      Phase := Registry.StateSet('job_phase', 'Current phase.', [], ['idle', 'running', 'failed']);
      Phase.SetOnly('running');      // exactly one state true, changed atomically
      Phase.SetState('failed', True);   // or flip single states

    All states live in one atomic bitmask, so a scrape never sees a half-applied SetOnly.
    At most 63 states. The classic text format has no stateset type and gets a gauge. }

  TPromStateSet = class;

  TPromStateSetChild = class(TPromChild)
  private
    FOwner: TPromStateSet;
    FMask: Int64;   // bit I = state I is true
  protected
    procedure CollectSamples(W: TPromTextWriter; const MetricName: string); override;
  public
    constructor Create(AOwner: TPromStateSet);
    procedure SetState(const State: string; Value: Boolean);
    { Makes State the only true state in one atomic step. }
    procedure SetOnly(const State: string);
    { Makes every state false in one atomic step. }
    procedure ClearAll;
    function IsSet(const State: string): Boolean;
  end;

  TPromStateSet = class(TPromFamily)
  private
    FStates: array of string;
    function StateIndex(const State: string): Integer;
  protected
    function CreateChild: TPromChild; override;
    function MetricType: string; override;
  public
    { The metric name doubles as the state label's name, so it must be a valid label name
      (no colon) and must not also be one of ALabelNames. States: 1..63 distinct names. }
    constructor Create(const AName, AHelp: string; const ALabelNames: array of string;
      const AStates: array of string);
    function Labels(const Values: array of string): TPromStateSetChild;
    { Shortcuts for a family without labels. }
    procedure SetState(const State: string; Value: Boolean);
    procedure SetOnly(const State: string);
  end;

implementation

{ TPromMetric }

function TPromMetric.ExposedType: string;
begin
  Result := 'unknown';
end;

procedure TPromMetric.SetUnit(const AUnit: string);
var
  T, Family: string;
begin
  if AUnit = '' then
    Exit;
  if FUnit <> '' then   // set-once: a scrape may be reading the string right now
    raise EInvalidOperation.CreateFmt('Metric "%s" already has the unit "%s"', [FName, FUnit]);
  if not PromValidMetricName(AUnit) then
    raise EArgumentException.CreateFmt('Invalid unit "%s"', [AUnit]);
  T := ExposedType;
  if (T = 'info') or (T = 'stateset') then
    raise EArgumentException.CreateFmt('A %s metric cannot have a unit', [T]);
  Family := PromOpenMetricsFamilyName(T, FName);
  if (Length(Family) <= Length(AUnit) + 1) or
     (Copy(Family, Length(Family) - Length(AUnit), Length(AUnit) + 1) <> '_' + AUnit) then
    raise EArgumentException.CreateFmt('The unit "%s" must be a suffix of the metric name "%s"',
      [AUnit, Family]);
  FUnit := AUnit;
end;

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
  FRetired := TList.Create;
  FPending := TList.Create;
  FExLock := TCriticalSection.Create;
  if Length(FLabelNames) = 0 then
    FNoLabels := NewChild;   // subclasses must be ready for this before inherited Create
end;

destructor TPromFamily.Destroy;
var
  I: Integer;
begin
  if FRetired <> nil then
    for I := 0 to FRetired.Count - 1 do
      TObject(FRetired[I]).Free;
  FRetired.Free;
  if FPending <> nil then
    for I := 0 to FPending.Count - 1 do
      TObject(FPending[I]).Free;
  FPending.Free;
  FNoLabels.Free;
  FOverflow.Free;
  FChildren.Free;
  FLock.Free;
  FExLock.Free;   // last: children reference it
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

procedure TPromFamily.SetMaxChildren(Value: Integer);
begin
  if Value < 0 then
    raise EArgumentException.Create('MaxChildren cannot be negative');
  FLock.BeginWrite;
  try
    FMaxChildren := Value;
  finally
    FLock.EndWrite;
  end;
end;

function TPromFamily.GetOverflowed: Boolean;
begin
  FLock.BeginRead;
  try
    Result := FOverflow <> nil;
  finally
    FLock.EndRead;
  end;
end;

function TPromFamily.ExposedType: string;
begin
  Result := MetricType;
end;

function TPromFamily.NewChild: TPromChild;
begin
  Result := CreateChild;
  Result.FCreated := PromEpochSeconds;
  Result.FExLock := FExLock;
end;

procedure TPromChild.WriteCreated(W: TPromTextWriter; const BaseName: string);
begin
  if W.Format = pfOpenMetrics then
    W.WriteSample(BaseName + '_created', FPairs, FCreated);
end;

function TPromFamily.GetRetiredCount: Integer;
begin
  FLock.BeginRead;
  try
    Result := FRetired.Count + FPending.Count;
  finally
    FLock.EndRead;
  end;
end;

procedure TPromFamily.Retire(C: TPromChild);
begin
  // Pinned is only ever set under the read lock, so under the write lock it cannot change:
  // a pinned child may still be cached by a caller and lives until Destroy.
  if AtomicLoadInt64(C.FPinned) <> 0 then
    FRetired.Add(C)
  else
    FPending.Add(C);
end;

procedure TPromFamily.Sweep;
var
  I: Integer;
  C: TPromChild;
begin
  // Acquire and the scrape snapshot take their references under the read lock, which the
  // caller's write lock excludes: a pending child's count can only fall while we look at it,
  // so FRefs = 0 is final and nobody touches the child after their decrement.
  for I := FPending.Count - 1 downto 0 do
  begin
    C := TPromChild(FPending[I]);
    if AtomicLoadInt64(C.FRefs) = 0 then
    begin
      FPending.Delete(I);
      C.Free;
    end;
  end;
end;

function TPromFamily.Reclaim: Integer;
var
  Before: Integer;
begin
  FLock.BeginWrite;
  try
    Before := FPending.Count;
    Sweep;
    Result := Before - FPending.Count;
  finally
    FLock.EndWrite;
  end;
end;

function TPromFamily.Acquire(const Values: array of string): TPromChild;
begin
  Result := FindOrCreate(Values, True);
end;

procedure TPromFamily.Release(Child: TPromChild);
begin
  if Child = nil then
    raise EArgumentException.Create('Release needs a child returned by Acquire');
  if AtomicAddInt64(Child.FRefs, -1) < 0 then
  begin
    AtomicAddInt64(Child.FRefs, 1);
    raise EInvalidOperation.Create('Release without a matching Acquire');
  end;
end;

function TPromFamily.Remove(const Values: array of string): Boolean;
var
  Idx: Integer;
begin
  if Length(Values) <> Length(FLabelNames) then
    raise EArgumentException.CreateFmt('Metric "%s" expects %d label value(s), got %d',
      [FName, Length(FLabelNames), Length(Values)]);
  if FNoLabels <> nil then
    raise EInvalidOperation.CreateFmt('Metric "%s" has no labels; nothing to remove', [FName]);
  FLock.BeginWrite;
  try
    Result := FChildren.Find(MakeKey(Values), Idx);
    if Result then
    begin
      Retire(TPromChild(FChildren.Objects[Idx]));
      FChildren.Objects[Idx] := nil;   // OwnsObjects would free it on Delete
      FChildren.Delete(Idx);
      Sweep;
    end;
  finally
    FLock.EndWrite;
  end;
end;

procedure TPromFamily.Clear;
var
  I: Integer;
begin
  if FNoLabels <> nil then
    raise EInvalidOperation.CreateFmt('Metric "%s" has no labels; nothing to clear', [FName]);
  FLock.BeginWrite;
  try
    for I := 0 to FChildren.Count - 1 do
    begin
      Retire(TPromChild(FChildren.Objects[I]));
      FChildren.Objects[I] := nil;
    end;
    FChildren.Clear;
    if FOverflow <> nil then
    begin
      Retire(FOverflow);
      FOverflow := nil;
    end;
    Sweep;
  finally
    FLock.EndWrite;
  end;
end;

function TPromFamily.OverflowChild: TPromChild;
var
  Values: array of string;
  I: Integer;
begin
  if FOverflow = nil then
  begin
    SetLength(Values, Length(FLabelNames));
    for I := 0 to High(Values) do
      Values[I] := PromOverflowLabelValue;
    FOverflow := NewChild;
    FOverflow.FPairs := PromFormatLabelPairs(FLabelNames, Values);
  end;
  Result := FOverflow;
end;

function TPromFamily.NoLabelChild: TPromChild;
begin
  if FNoLabels = nil then
    raise EInvalidOperation.CreateFmt('Metric "%s" has labels; use Labels(...)', [FName]);
  Result := FNoLabels;
end;

function TPromFamily.GetChild(const Values: array of string): TPromChild;
begin
  Result := FindOrCreate(Values, False);
end;

function TPromFamily.FindOrCreate(const Values: array of string; Counted: Boolean): TPromChild;
var
  Key: string;
  Idx: Integer;

  // Called while the lock that found the child is still held: a removal (write lock)
  // cannot slip in between the lookup and the claim.
  procedure Claim(C: TPromChild);
  begin
    if Counted then
      AtomicAddInt64(C.FRefs, 1)
    else
      AtomicStoreInt64(C.FPinned, 1);
  end;

begin
  if Length(Values) <> Length(FLabelNames) then
    raise EArgumentException.CreateFmt('Metric "%s" expects %d label value(s), got %d',
      [FName, Length(FLabelNames), Length(Values)]);
  if FNoLabels <> nil then
  begin
    if Counted then
      AtomicAddInt64(FNoLabels.FRefs, 1);   // keeps Acquire/Release symmetric; never freed anyway
    Exit(FNoLabels);
  end;

  Key := MakeKey(Values);
  Result := nil;
  FLock.BeginRead;
  try
    if FChildren.Find(Key, Idx) then
      Result := TPromChild(FChildren.Objects[Idx])
    else if (FOverflow <> nil) and (FMaxChildren > 0) and (FChildren.Count >= FMaxChildren) then
      Result := FOverflow;   // already capped: stay on the read lock
    if Result <> nil then
      Claim(Result);
  finally
    FLock.EndRead;
  end;
  if Result <> nil then
    Exit;

  FLock.BeginWrite;
  try
    if FChildren.Find(Key, Idx) then   // another thread may have won the race
      Result := TPromChild(FChildren.Objects[Idx])
    else if (FMaxChildren > 0) and (FChildren.Count >= FMaxChildren) then
      Result := OverflowChild
    else
    begin
      Sweep;   // creating is a natural moment to free removed children nobody holds
      Result := NewChild;
      Result.FPairs := PromFormatLabelPairs(FLabelNames, Values);
      FChildren.AddObject(Key, Result);
    end;
    Claim(Result);
  finally
    FLock.EndWrite;
  end;
end;

procedure TPromFamily.Collect(W: TPromTextWriter);
var
  Snapshot: TList;
  I: Integer;
  SName: string;
begin
  W.WriteHeader(FName, FHelp, MetricType, FUnit);
  SName := W.SampleName(MetricType, FName);
  if FNoLabels <> nil then
  begin
    FNoLabels.CollectSamples(W, SName);
    Exit;
  end;
  Snapshot := TList.Create;
  try
    FLock.BeginRead;
    try
      for I := 0 to FChildren.Count - 1 do
        Snapshot.Add(FChildren.Objects[I]);
      if FOverflow <> nil then
        Snapshot.Add(FOverflow);
      // hold every child for the duration of the scrape: a Remove during it only retires
      for I := 0 to Snapshot.Count - 1 do
        AtomicAddInt64(TPromChild(Snapshot[I]).FRefs, 1);
    finally
      FLock.EndRead;
    end;
    try
      for I := 0 to Snapshot.Count - 1 do
        TPromChild(Snapshot[I]).CollectSamples(W, SName);
    finally
      for I := 0 to Snapshot.Count - 1 do
        AtomicAddInt64(TPromChild(Snapshot[I]).FRefs, -1);
    end;
  finally
    Snapshot.Free;
  end;
end;

{ Counter }

const
  CounterMaxStripes = 64;
  CounterCellBytes = 64;   // one cache line per stripe, so stripes never share a line

constructor TPromCounterChild.CreateStriped(AStripes: Integer);
var
  N: Integer;
begin
  inherited Create;
  if AStripes <= 1 then
    Exit;
  N := 2;
  while (N < AStripes) and (N < CounterMaxStripes) do
    N := N * 2;
  GetMem(FRaw, N * CounterCellBytes + CounterCellBytes - 1);
  FillChar(FRaw^, N * CounterCellBytes + CounterCellBytes - 1, 0);
  FCells := PInt64((PtrUInt(FRaw) + CounterCellBytes - 1) and not PtrUInt(CounterCellBytes - 1));
  FMask := N - 1;
end;

destructor TPromCounterChild.Destroy;
begin
  if FRaw <> nil then
    FreeMem(FRaw);
  inherited Destroy;
end;

procedure TPromCounterChild.Add(Delta: Double);
var
  H: QWord;
begin
  if FCells = nil then
    AtomicAddDouble(FBits, Delta)
  else
  begin
    {$PUSH}{$Q-}{$R-}
    H := (QWord(PtrUInt(GetCurrentThreadId)) * QWord($9E3779B97F4A7C15)) shr 40;
    {$POP}
    AtomicAddDouble(PInt64(PByte(FCells) + Integer(H and QWord(FMask)) * CounterCellBytes)^, Delta);
  end;
end;

procedure TPromCounterChild.Inc(Delta: Double);
begin
  if Delta < 0 then
    raise EArgumentException.Create('Counter cannot decrease');
  Add(Delta);
end;

function TPromCounterChild.Value: Double;
var
  I: Integer;
begin
  if FCells = nil then
    Exit(AtomicLoadDouble(FBits));
  Result := 0;
  for I := 0 to FMask do
    Result := Result + AtomicLoadDouble(PInt64(PByte(FCells) + I * CounterCellBytes)^);
end;

procedure TPromCounterChild.IncWithExemplar(Delta: Double; const ExemplarLabels: array of string);
var
  Ex: TPromExemplar;
begin
  if Delta < 0 then
    raise EArgumentException.Create('Counter cannot decrease');
  // validate and format before touching anything, so a rejected exemplar changes nothing
  Ex := PromMakeExemplar(ExemplarLabels, Delta, PromEpochSeconds);
  Add(Delta);
  FExLock.Enter;
  try
    FExemplar := Ex;
  finally
    FExLock.Leave;
  end;
end;

procedure TPromCounterChild.CollectSamples(W: TPromTextWriter; const MetricName: string);
var
  Ex: TPromExemplar;
begin
  Ex := PromNoExemplar;
  if W.Format = pfOpenMetrics then
  begin
    FExLock.Enter;
    try
      Ex := FExemplar;
    finally
      FExLock.Leave;
    end;
  end;
  W.WriteSample(MetricName, FPairs, Value, Ex);
  WriteCreated(W, PromStripSuffix(MetricName, '_total'));
end;

constructor TPromCounter.Create(const AName, AHelp: string; const ALabelNames: array of string);
begin
  Create(AName, AHelp, ALabelNames, 1);
end;

constructor TPromCounter.Create(const AName, AHelp: string; const ALabelNames: array of string;
  AStripes: Integer);
begin
  FStripes := AStripes;   // must be set before inherited Create builds the label-less child
  inherited Create(AName, AHelp, ALabelNames);
end;

function TPromCounter.CreateChild: TPromChild;
begin
  Result := TPromCounterChild.CreateStriped(FStripes);
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

procedure TPromCounter.IncWithExemplar(Delta: Double; const ExemplarLabels: array of string);
begin
  TPromCounterChild(NoLabelChild).IncWithExemplar(Delta, ExemplarLabels);
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

procedure TPromGauge.SetToCurrentTime;
begin
  TPromGaugeChild(NoLabelChild).SetToCurrentTime;
end;

function TPromGauge.TrackInProgress: TPromInProgress;
begin
  Result := TPromGaugeChild(NoLabelChild).TrackInProgress;
end;

procedure TPromGaugeChild.SetToCurrentTime;
begin
  SetValue(PromEpochSeconds);
end;

function TPromGaugeChild.TrackInProgress: TPromInProgress;
begin
  Inc;
  Result.FTarget := Self;
end;

procedure TPromInProgress.Done;
begin
  FTarget.Dec;
end;

{ Histogram }

constructor TPromHistogramChild.Create(AOwner: TPromHistogram);
begin
  inherited Create;
  FOwner := AOwner;
  SetLength(FCounts, Length(AOwner.FUpper) + 1);
end;

{ Index of the bucket V belongs to (the last one is +Inf). Shared by Observe and
  ObserveWithExemplar so they can never disagree. }
function TPromHistogramChild.BucketIndex(V: Double): Integer;
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
  Result := Lo;
end;

procedure TPromHistogramChild.Observe(V: Double);
begin
  AtomicAddInt64(FCounts[BucketIndex(V)], 1);
  AtomicAddDouble(FSumBits, V);
end;

procedure TPromHistogramChild.ObserveWithExemplar(V: Double; const ExemplarLabels: array of string);
var
  Ex: TPromExemplar;
  Idx: Integer;
begin
  Ex := PromMakeExemplar(ExemplarLabels, V, PromEpochSeconds);
  Idx := BucketIndex(V);
  AtomicAddInt64(FCounts[Idx], 1);
  AtomicAddDouble(FSumBits, V);
  FExLock.Enter;
  try
    if Length(FExemplars) = 0 then
      SetLength(FExemplars, Length(FCounts));
    FExemplars[Idx] := Ex;
  finally
    FExLock.Leave;
  end;
end;

procedure TPromHistogramChild.CollectSamples(W: TPromTextWriter; const MetricName: string);
var
  I: Integer;
  Cum: Int64;
  Sep: string;
  Exs: array of TPromExemplar;
begin
  if W.Format = pfOpenMetrics then
  begin
    FExLock.Enter;
    try
      Exs := Copy(FExemplars);   // snapshot; written out after the lock is released
    finally
      FExLock.Leave;
    end;
  end;
  if FPairs = '' then Sep := '' else Sep := FPairs + ',';
  Cum := 0;
  for I := 0 to High(FOwner.FUpper) do
  begin
    Cum := Cum + AtomicLoadInt64(FCounts[I]);
    if I < Length(Exs) then
      W.WriteSample(MetricName + '_bucket', Sep + 'le="' + W.FormatLe(FOwner.FUpper[I]) + '"', Cum, Exs[I])
    else
      W.WriteSample(MetricName + '_bucket', Sep + 'le="' + W.FormatLe(FOwner.FUpper[I]) + '"', Cum);
  end;
  Cum := Cum + AtomicLoadInt64(FCounts[High(FCounts)]);
  if Length(Exs) > 0 then
    W.WriteSample(MetricName + '_bucket', Sep + 'le="+Inf"', Cum, Exs[High(Exs)])
  else
    W.WriteSample(MetricName + '_bucket', Sep + 'le="+Inf"', Cum);
  W.WriteSample(MetricName + '_sum', FPairs, AtomicLoadDouble(FSumBits));
  W.WriteSample(MetricName + '_count', FPairs, Cum);
  WriteCreated(W, MetricName);
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

procedure TPromHistogram.ObserveWithExemplar(V: Double; const ExemplarLabels: array of string);
begin
  TPromHistogramChild(NoLabelChild).ObserveWithExemplar(V, ExemplarLabels);
end;

function TPromHistogram.StartTimer: TPromTimer;
begin
  Result := TPromHistogramChild(NoLabelChild).StartTimer;
end;

{ Summary }

constructor TPromSummaryChild.Create(AOwner: TPromSummary);
begin
  inherited Create;
  FOwner := AOwner;
  if Length(AOwner.FQuantiles) > 0 then
    FSketch := TPromSketch.Create(AOwner.FSketchOptions);
end;

destructor TPromSummaryChild.Destroy;
begin
  FSketch.Free;
  inherited Destroy;
end;

procedure TPromSummaryChild.Observe(V: Double);
begin
  AtomicAddInt64(FCount, 1);
  AtomicAddDouble(FSumBits, V);
  if FSketch <> nil then
    FSketch.Observe(V);
end;

procedure TPromSummaryChild.CollectSamples(W: TPromTextWriter; const MetricName: string);
var
  Est: TPromDoubleArray;
  I: Integer;
  Sep: string;
begin
  if FSketch <> nil then
  begin
    Est := FSketch.Quantiles(FOwner.FQuantiles);
    if FPairs = '' then Sep := '' else Sep := FPairs + ',';
    for I := 0 to High(Est) do
      W.WriteSample(MetricName, Sep + 'quantile="' + W.FormatLe(FOwner.FQuantiles[I]) + '"', Est[I]);
  end;
  W.WriteSample(MetricName + '_sum', FPairs, AtomicLoadDouble(FSumBits));
  W.WriteSample(MetricName + '_count', FPairs, AtomicLoadInt64(FCount));
  WriteCreated(W, MetricName);
end;

constructor TPromSummary.Create(const AName, AHelp: string; const ALabelNames: array of string);
begin
  Create(AName, AHelp, ALabelNames, [], PromDefaultSketchOptions);
end;

constructor TPromSummary.Create(const AName, AHelp: string; const ALabelNames: array of string;
  const AQuantiles: array of Double; const AOptions: TPromSketchOptions);
var
  I: Integer;
begin
  for I := 0 to High(ALabelNames) do
    if ALabelNames[I] = 'quantile' then
      raise EArgumentException.Create('Label name "quantile" is reserved for summaries');
  // quantiles and options must be ready before inherited Create builds the label-less child
  SetLength(FQuantiles, Length(AQuantiles));
  for I := 0 to High(AQuantiles) do
  begin
    // IsNan first: comparing a NaN raises EInvalidOp instead of returning False
    if IsNan(AQuantiles[I]) or not ((AQuantiles[I] >= 0) and (AQuantiles[I] <= 1)) then
      raise EArgumentException.Create('Summary quantiles must be between 0 and 1');
    if (I > 0) and (AQuantiles[I] <= AQuantiles[I - 1]) then
      raise EArgumentException.Create('Summary quantiles must be strictly ascending');
    FQuantiles[I] := AQuantiles[I];
  end;
  FSketchOptions := AOptions;
  if Length(FQuantiles) > 0 then
    PromCheckSketchOptions(AOptions);
  inherited Create(AName, AHelp, ALabelNames);
end;

function TPromSummary.CreateChild: TPromChild;
begin
  Result := TPromSummaryChild.Create(Self);
end;

function TPromSummary.MetricType: string;
begin
  Result := 'summary';
end;

function TPromSummary.Labels(const Values: array of string): TPromSummaryChild;
begin
  Result := TPromSummaryChild(GetChild(Values));
end;

procedure TPromSummary.Observe(V: Double);
begin
  TPromSummaryChild(NoLabelChild).Observe(V);
end;

function TPromSummary.StartTimer: TPromTimer;
begin
  Result := TPromSummaryChild(NoLabelChild).StartTimer;
end;

{ Timer }

function TPromObserverChild.StartTimer: TPromTimer;
begin
  Result.FTarget := Self;
  Result.FStart := PromMonotonicSeconds;
end;

function TPromTimer.ObserveDuration: Double;
begin
  Result := PromMonotonicSeconds - FStart;
  if Result < 0 then
    Result := 0;
  FTarget.Observe(Result);
end;

{ Untyped }

function TPromUntyped.MetricType: string;
begin
  Result := 'untyped';
end;

{ Info }

procedure TPromInfoChild.CollectSamples(W: TPromTextWriter; const MetricName: string);
begin
  W.WriteSample(MetricName, FPairs, 1);
end;

constructor TPromInfo.Create(const AName, AHelp: string; const ALabelNames: array of string);
var
  N: string;
begin
  if Length(ALabelNames) = 0 then
    raise EArgumentException.Create('An info metric needs at least one label');
  N := AName;
  if Copy(N, Length(N) - 4, 5) <> '_info' then
    N := N + '_info';
  inherited Create(N, AHelp, ALabelNames);
end;

function TPromInfo.CreateChild: TPromChild;
begin
  Result := TPromInfoChild.Create;
end;

function TPromInfo.MetricType: string;
begin
  Result := 'info';   // the writer emits a gauge in text format
end;

function TPromInfo.Publish(const Values: array of string): TPromInfoChild;
begin
  Result := TPromInfoChild(GetChild(Values));
end;

{ StateSet }

constructor TPromStateSetChild.Create(AOwner: TPromStateSet);
begin
  inherited Create;
  FOwner := AOwner;
end;

procedure TPromStateSetChild.SetState(const State: string; Value: Boolean);
var
  Bit, Old: Int64;
begin
  Bit := Int64(1) shl FOwner.StateIndex(State);   // Int64(): a plain 1 shl is 32 bits wide
  repeat
    Old := AtomicLoadInt64(FMask);
  until InterlockedCompareExchange64(FMask, (Old and not Bit) or (Ord(Value) * Bit), Old) = Old;
end;

procedure TPromStateSetChild.SetOnly(const State: string);
begin
  AtomicStoreInt64(FMask, Int64(1) shl FOwner.StateIndex(State));
end;

procedure TPromStateSetChild.ClearAll;
begin
  AtomicStoreInt64(FMask, 0);
end;

function TPromStateSetChild.IsSet(const State: string): Boolean;
begin
  Result := (AtomicLoadInt64(FMask) and (Int64(1) shl FOwner.StateIndex(State))) <> 0;
end;

procedure TPromStateSetChild.CollectSamples(W: TPromTextWriter; const MetricName: string);
var
  Mask: Int64;
  I: Integer;
  Sep, StateLabel: string;
begin
  Mask := AtomicLoadInt64(FMask);
  if FPairs = '' then Sep := '' else Sep := FPairs + ',';
  StateLabel := FOwner.Name + '="';
  for I := 0 to High(FOwner.FStates) do
    W.WriteSample(MetricName, Sep + StateLabel + PromEscapeLabelValue(FOwner.FStates[I]) + '"',
      (Mask shr I) and 1);
end;

constructor TPromStateSet.Create(const AName, AHelp: string; const ALabelNames: array of string;
  const AStates: array of string);
var
  I, J: Integer;
begin
  if not PromValidLabelName(AName) then
    raise EArgumentException.CreateFmt('A stateset name doubles as a label name and "%s" is not one', [AName]);
  for I := 0 to High(ALabelNames) do
    if ALabelNames[I] = AName then
      raise EArgumentException.CreateFmt('Label name "%s" is the stateset''s own name', [AName]);
  if (Length(AStates) < 1) or (Length(AStates) > 63) then
    raise EArgumentException.Create('A stateset needs between 1 and 63 states');
  // the states must be ready before inherited Create builds the label-less child
  SetLength(FStates, Length(AStates));
  for I := 0 to High(AStates) do
  begin
    for J := 0 to I - 1 do
      if FStates[J] = AStates[I] then
        raise EArgumentException.CreateFmt('Duplicate state "%s"', [AStates[I]]);
    FStates[I] := AStates[I];
  end;
  inherited Create(AName, AHelp, ALabelNames);
end;

function TPromStateSet.StateIndex(const State: string): Integer;
begin
  for Result := 0 to High(FStates) do
    if FStates[Result] = State then
      Exit;
  raise EArgumentException.CreateFmt('Unknown state "%s" for "%s"', [State, FName]);
end;

function TPromStateSet.CreateChild: TPromChild;
begin
  Result := TPromStateSetChild.Create(Self);
end;

function TPromStateSet.MetricType: string;
begin
  Result := 'stateset';
end;

function TPromStateSet.Labels(const Values: array of string): TPromStateSetChild;
begin
  Result := TPromStateSetChild(GetChild(Values));
end;

procedure TPromStateSet.SetState(const State: string; Value: Boolean);
begin
  TPromStateSetChild(NoLabelChild).SetState(State, Value);
end;

procedure TPromStateSet.SetOnly(const State: string);
begin
  TPromStateSetChild(NoLabelChild).SetOnly(State);
end;

end.
