{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit test_metrics;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry, prom_atomic, prom_metrics, prom_registry,
  prom_exposition, prom_collectors, prom_clock, prom_server, fphttpclient, Math, DateUtils;

type
  TTestAtomic = class(TTestCase)
  published
    procedure TestAddDoubleConcurrent;
  end;

  TTestLabels = class(TTestCase)
  published
    procedure TestLabeledCounterOutput;
    procedure TestSameChildForSameValues;
    procedure TestValueCountMismatch;
    procedure TestInvalidLabelNames;
    procedure TestLabeledHistogramOutput;
    procedure TestEscapedLabelValue;
    procedure TestConcurrentLabels;
    procedure TestMaxChildrenOverflow;
    procedure TestMaxChildrenConcurrent;
  end;

  TTestMoreTypes = class(TTestCase)
  private
    FFail: Boolean;
    procedure FillQueues(Samples: TPromSamples);
  published
    procedure TestUntyped;
    procedure TestInfo;
    procedure TestInfoNeedsLabels;
    procedure TestTimer;
    procedure TestLabeledTimer;
    procedure TestCallbackFamily;
    procedure TestCallbackFamilyErrors;
    procedure TestSummary;
    procedure TestSummaryLabelsAndTimer;
    procedure TestSummaryReservedLabel;
    procedure TestSetToCurrentTime;
    procedure TestTrackInProgress;
  end;

  { Every metric type hammered from several threads while another thread scrapes. }
  TTestStress = class(TTestCase)
  published
    procedure TestAllTypesConcurrentWithScrapes;
  end;

  TTestServer = class(TTestCase)
  published
    procedure TestServeMetrics;
  end;

  TTestCollectors = class(TTestCase)
  published
    procedure TestHeapMetrics;
    procedure TestProcessMetrics;
    procedure TestStartTimePrecision;
    procedure TestMonotonicClock;
  end;

  TTestExposition = class(TTestCase)
  published
    procedure TestEscape;
    procedure TestNames;
    procedure TestCounterAndHistogramOutput;
    procedure TestFormatFloat;
  end;

implementation

const
  ThreadCount = 8;
  Iterations = 20000;

type
  TAdder = class(TThread)
  private
    FBits: PInt64;
  protected
    procedure Execute; override;
  public
    constructor Create(ABits: PInt64);
  end;

constructor TAdder.Create(ABits: PInt64);
begin
  FBits := ABits;
  inherited Create(False);
end;

procedure TAdder.Execute;
var
  I: Integer;
begin
  for I := 1 to Iterations do
    AtomicAddDouble(FBits^, 1.0);
end;

procedure TTestAtomic.TestAddDoubleConcurrent;
var
  Bits: Int64;
  T: array[0..ThreadCount - 1] of TAdder;
  I: Integer;
begin
  Bits := 0;
  for I := 0 to ThreadCount - 1 do
    T[I] := TAdder.Create(@Bits);
  for I := 0 to ThreadCount - 1 do
  begin
    T[I].WaitFor;
    T[I].Free;
  end;
  AssertEquals('sum', Double(ThreadCount * Iterations), AtomicLoadDouble(Bits));
end;

procedure TTestMoreTypes.FillQueues(Samples: TPromSamples);
begin
  if FFail then
    raise Exception.Create('boom');
  Samples.Add(['mail'], 3);
  Samples.Add(['sms'], 0.5);
end;

procedure TTestMoreTypes.TestUntyped;
var
  R: TPromRegistry;
  S: string;
begin
  R := TPromRegistry.Create;
  try
    R.Untyped('legacy', 'From elsewhere.').SetValue(7);
    S := R.Collect;
    AssertEquals('# HELP legacy From elsewhere.' + #10 + '# TYPE legacy untyped' + #10 +
      'legacy 7' + #10, S);
  finally
    R.Free;
  end;
end;

procedure TTestMoreTypes.TestInfo;
var
  R: TPromRegistry;
  S: string;
begin
  R := TPromRegistry.Create;
  try
    R.Info('build', 'Build info.', ['version', 'commit']).Publish(['1.4', 'abc']);
    R.Info('app_info', 'App.', ['name']).Publish(['x"y']);
    S := R.Collect;
    AssertTrue(S, Pos('# TYPE build_info gauge' + #10 +
      'build_info{version="1.4",commit="abc"} 1' + #10, S) > 0);
    AssertTrue(S, Pos('app_info{name="x\"y"} 1' + #10, S) > 0);  // no double suffix
  finally
    R.Free;
  end;
end;

procedure TTestMoreTypes.TestInfoNeedsLabels;
var
  R: TPromRegistry;
  Raised: Boolean;
begin
  R := TPromRegistry.Create;
  try
    Raised := False;
    try
      R.Info('x', 'x', []);
    except
      on EArgumentException do Raised := True;
    end;
    AssertTrue(Raised);
  finally
    R.Free;
  end;
end;

procedure TTestMoreTypes.TestTimer;
var
  R: TPromRegistry;
  H: TPromHistogram;
  T: TPromTimer;
  D: Double;
  S: string;
begin
  R := TPromRegistry.Create;
  try
    H := R.Histogram('work_seconds', 'Work.', [0.001, 10]);
    T := H.StartTimer;
    Sleep(30);
    D := T.ObserveDuration;
    AssertTrue('duration ' + FloatToStr(D), (D >= 0.025) and (D < 5));
    S := R.Collect;
    AssertTrue(S, Pos('work_seconds_bucket{le="0.001"} 0' + #10, S) > 0);
    AssertTrue(S, Pos('work_seconds_bucket{le="10"} 1' + #10, S) > 0);
    AssertTrue(S, Pos('work_seconds_count 1' + #10, S) > 0);
  finally
    R.Free;
  end;
end;

procedure TTestMoreTypes.TestLabeledTimer;
var
  R: TPromRegistry;
  H: TPromHistogram;
  T: TPromTimer;
  S: string;
begin
  R := TPromRegistry.Create;
  try
    H := R.Histogram('rpc_seconds', 'RPC.', ['method'], [10]);
    T := H.Labels(['get']).StartTimer;
    T.ObserveDuration;
    S := R.Collect;
    AssertTrue(S, Pos('rpc_seconds_count{method="get"} 1' + #10, S) > 0);
  finally
    R.Free;
  end;
end;

procedure TTestMoreTypes.TestCallbackFamily;
var
  R: TPromRegistry;
  S: string;
begin
  R := TPromRegistry.Create;
  try
    R.Register(TPromCallbackFamily.Create('queue_depth', 'Depth.', 'gauge', ['queue'],
      @FillQueues));
    S := R.Collect;
    AssertEquals('# HELP queue_depth Depth.' + #10 + '# TYPE queue_depth gauge' + #10 +
      'queue_depth{queue="mail"} 3' + #10 + 'queue_depth{queue="sms"} 0.5' + #10, S);
  finally
    R.Free;
  end;
end;

procedure TTestMoreTypes.TestCallbackFamilyErrors;
var
  R: TPromRegistry;
  Raised: Boolean;
begin
  R := TPromRegistry.Create;
  try
    R.Register(TPromCallbackFamily.Create('q', 'q', 'gauge', ['queue'], @FillQueues));
    FFail := True;
    Raised := False;
    try
      R.Collect;
    except
      on Exception do Raised := True;
    end;
    AssertTrue('callback error propagates', Raised);
    Raised := False;
    try
      TPromCallbackFamily.Create('q2', 'q', 'gauge', ['a', 'a'], @FillQueues).Free;
    except
      on EArgumentException do Raised := True;
    end;
    AssertTrue('duplicate label names rejected', Raised);
  finally
    R.Free;
  end;
end;

procedure TTestMoreTypes.TestSummary;
var
  R: TPromRegistry;
  S: TPromSummary;
begin
  R := TPromRegistry.Create;
  try
    S := R.Summary('size_bytes', 'Sizes.');
    S.Observe(100);
    S.Observe(50.5);
    AssertEquals('# HELP size_bytes Sizes.' + #10 + '# TYPE size_bytes summary' + #10 +
      'size_bytes_sum 150.5' + #10 + 'size_bytes_count 2' + #10, R.Collect);
  finally
    R.Free;
  end;
end;

procedure TTestMoreTypes.TestSummaryLabelsAndTimer;
var
  R: TPromRegistry;
  S: TPromSummary;
  T: TPromTimer;
  Text: string;
begin
  R := TPromRegistry.Create;
  try
    S := R.Summary('job_seconds', 'Jobs.', ['kind']);
    S.Labels(['a']).Observe(2);
    T := S.Labels(['b']).StartTimer;
    T.ObserveDuration;
    Text := R.Collect;
    AssertTrue(Text, Pos('job_seconds_sum{kind="a"} 2' + #10, Text) > 0);
    AssertTrue(Text, Pos('job_seconds_count{kind="a"} 1' + #10, Text) > 0);
    AssertTrue(Text, Pos('job_seconds_count{kind="b"} 1' + #10, Text) > 0);
  finally
    R.Free;
  end;
end;

procedure TTestMoreTypes.TestSummaryReservedLabel;
var
  R: TPromRegistry;
  Raised: Boolean;
begin
  R := TPromRegistry.Create;
  try
    Raised := False;
    try
      R.Summary('x', 'x', ['quantile']);
    except
      on EArgumentException do Raised := True;
    end;
    AssertTrue(Raised);
  finally
    R.Free;
  end;
end;

procedure TTestMoreTypes.TestSetToCurrentTime;
var
  R: TPromRegistry;
  G: TPromGauge;
  Expected: Double;
begin
  R := TPromRegistry.Create;
  try
    G := R.Gauge('last_success_seconds', 'Last success.');
    G.SetToCurrentTime;
    Expected := (LocalTimeToUniversal(Now) - UnixDateDelta) * SecsPerDay;
    AssertTrue('epoch seconds', (G.Value > 1.7e9) and (Abs(G.Value - Expected) < 5));
  finally
    R.Free;
  end;
end;

procedure TTestMoreTypes.TestTrackInProgress;
var
  R: TPromRegistry;
  G: TPromGauge;
  P, Q: TPromInProgress;
begin
  R := TPromRegistry.Create;
  try
    G := R.Gauge('inflight', 'In flight.', ['pool']);
    P := G.Labels(['a']).TrackInProgress;
    Q := G.Labels(['a']).TrackInProgress;
    AssertEquals(2, G.Labels(['a']).Value);
    P.Done;
    AssertEquals(1, G.Labels(['a']).Value);
    Q.Done;
    AssertEquals(0, G.Labels(['a']).Value);
    G := R.Gauge('inflight2', 'x');
    P := G.TrackInProgress;
    AssertEquals(1, G.Value);
    P.Done;
    AssertEquals(0, G.Value);
  finally
    R.Free;
  end;
end;

{ FPC evaluates "Int64 / 1e7" in Single precision; at an epoch time of 1.8e9 that rounds
  to a multiple of 128 s. Regression test for exactly that. }
procedure TTestCollectors.TestStartTimePrecision;
var
  R: TPromRegistry;
  Text, Raw: string;
  P, Q: Integer;
  V, Now_: Double;
  FS: TFormatSettings;
begin
  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
  R := TPromRegistry.Create;
  try
    RegisterProcessMetrics(R);
    Text := R.Collect;
  finally
    R.Free;
  end;
  P := Pos(#10 + 'process_start_time_seconds ', Text);
  AssertTrue(Text, P > 0);
  P := P + Length(#10 + 'process_start_time_seconds ');
  Q := P;
  while (Q <= Length(Text)) and (Text[Q] <> #10) do
    Inc(Q);
  Raw := Copy(Text, P, Q - P);
  AssertTrue('parse ' + Raw, TryStrToFloat(Raw, V, FS));
  Now_ := (LocalTimeToUniversal(Now) - UnixDateDelta) * SecsPerDay;
  AssertTrue('start time near now: ' + Raw, (V <= Now_ + 5) and (V > Now_ - 86400));
  AssertFalse('start time must not be Single-rounded: ' + Raw,
    (Frac(V) = 0) and (Trunc(V) mod 128 = 0));
end;

procedure TTestCollectors.TestMonotonicClock;
var
  A, B: Double;
begin
  A := PromMonotonicSeconds;
  Sleep(30);
  B := PromMonotonicSeconds;
  AssertTrue('30 ms sleep measured as ' + FloatToStr(B - A), (B - A >= 0.025) and (B - A < 5));
end;

procedure TTestCollectors.TestHeapMetrics;
var
  R: TPromRegistry;
  S: string;
begin
  R := TPromRegistry.Create;
  try
    RegisterHeapMetrics(R);
    S := R.Collect;
    AssertTrue(S, Pos('# TYPE fpc_heap_used_bytes gauge' + #10 + 'fpc_heap_used_bytes ', S) > 0);
    AssertTrue(S, Pos('fpc_heap_size_bytes ', S) > 0);
    AssertTrue(S, Pos('fpc_heap_free_bytes ', S) > 0);
  finally
    R.Free;
  end;
end;

procedure TTestCollectors.TestProcessMetrics;
var
  R: TPromRegistry;
  S: string;
begin
  R := TPromRegistry.Create;
  try
    RegisterProcessMetrics(R);
    S := R.Collect;
    AssertTrue(S, Pos('# TYPE process_cpu_seconds_total counter', S) > 0);
    AssertTrue(S, Pos(#10 + 'process_resident_memory_bytes ', S) > 0);
    AssertTrue(S, Pos(#10 + 'process_virtual_memory_bytes ', S) > 0);
    AssertTrue(S, Pos(#10 + 'process_start_time_seconds 1', S) > 0);  // epoch seconds, 10 digits
    AssertTrue(S, Pos(#10 + 'process_open_fds ', S) > 0);
    {$IFDEF UNIX}
    AssertTrue(S, Pos(#10 + 'process_max_fds ', S) > 0);
    {$ELSE}
    AssertTrue(S, Pos('process_max_fds', S) = 0);
    {$ENDIF}
  finally
    R.Free;
  end;
end;

procedure TTestExposition.TestEscape;
begin
  AssertEquals('a\\b\"c\nd', PromEscapeLabelValue('a\b"c' + #10 + 'd'));
  AssertEquals('x\\y\nz', PromEscapeHelp('x\y' + #10 + 'z'));
end;

procedure TTestExposition.TestFormatFloat;
const
  Samples: array[0..7] of Double = (0.1, 0.5, 123456789.123456789, 1e-300,
    1.7976931348623157e308, 5e-324, 2.5, -0.30000000000000004);
var
  I: Integer;
  S: string;
  Back, Third: Double;
  FS: TFormatSettings;
begin
  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
  Third := 1.0;
  Third := Third / 3.0;  // runtime: a folded constant would be Single precision
  AssertEquals('0.3333333333333333', PromFormatFloat(Third));
  AssertEquals('0', PromFormatFloat(0.0));
  AssertEquals('100', PromFormatFloat(100.0));
  AssertEquals('1e+21', PromFormatFloat(1e21));
  AssertEquals('1e-8', PromFormatFloat(1e-8));
  AssertEquals('0.00001', PromFormatFloat(1e-5));
  AssertEquals('-1.5', PromFormatFloat(-1.5));
  AssertEquals('0.1', PromFormatFloat(0.1));
  AssertEquals('2.5', PromFormatFloat(2.5));
  AssertEquals('1', PromFormatFloat(1.0));
  AssertEquals('NaN', PromFormatFloat(NaN));
  AssertEquals('+Inf', PromFormatFloat(Infinity));
  AssertEquals('-Inf', PromFormatFloat(NegInfinity));
  for I := Low(Samples) to High(Samples) do
  begin
    S := PromFormatFloat(Samples[I]);
    AssertTrue('parse ' + S, TryStrToFloat(S, Back, FS));
    AssertTrue('round-trip ' + S, Back = Samples[I]);
  end;
end;

procedure TTestExposition.TestNames;
begin
  AssertTrue(PromValidMetricName('http_requests_total'));
  AssertFalse(PromValidMetricName('1abc'));
  AssertFalse(PromValidLabelName('__reserved'));
  AssertTrue(PromValidLabelName('code'));
end;

procedure TTestExposition.TestCounterAndHistogramOutput;
var
  R: TPromRegistry;
  H: TPromHistogram;
  S: string;
begin
  R := TPromRegistry.Create;
  try
    R.Counter('jobs_total', 'Jobs done').Inc(2.5);
    H := R.Histogram('latency_seconds', 'Latency', [0.1, 1]);
    H.Observe(0.05);
    H.Observe(0.5);
    H.Observe(5);
    S := R.Collect;
    AssertTrue(S, Pos('jobs_total 2.5' + #10, S) > 0);
    AssertTrue(S, Pos('latency_seconds_bucket{le="0.1"} 1' + #10, S) > 0);
    AssertTrue(S, Pos('latency_seconds_bucket{le="1"} 2' + #10, S) > 0);
    AssertTrue(S, Pos('latency_seconds_bucket{le="+Inf"} 3' + #10, S) > 0);
    AssertTrue(S, Pos('latency_seconds_count 3' + #10, S) > 0);
  finally
    R.Free;
  end;
end;

{ TTestLabels }

type
  TLabelWorker = class(TThread)
  private
    FCounter: TPromCounter;
  protected
    procedure Execute; override;
  public
    constructor Create(ACounter: TPromCounter);
  end;

constructor TLabelWorker.Create(ACounter: TPromCounter);
begin
  FCounter := ACounter;
  inherited Create(False);
end;

procedure TLabelWorker.Execute;
var
  I: Integer;
begin
  for I := 1 to Iterations do
    FCounter.Labels(['k' + IntToStr(I mod 7)]).Inc;
end;

procedure TTestLabels.TestLabeledCounterOutput;
var
  R: TPromRegistry;
  C: TPromCounter;
  S: string;
begin
  R := TPromRegistry.Create;
  try
    C := R.Counter('http_requests_total', 'Requests', ['method', 'code']);
    C.Labels(['GET', '200']).Inc(3);
    C.Labels(['POST', '500']).Inc;
    S := R.Collect;
    AssertTrue(S, Pos('http_requests_total{method="GET",code="200"} 3' + #10, S) > 0);
    AssertTrue(S, Pos('http_requests_total{method="POST",code="500"} 1' + #10, S) > 0);
    AssertEquals('one TYPE header', 0, Pos('# TYPE', Copy(S, Pos('# TYPE', S) + 1, MaxInt)));
  finally
    R.Free;
  end;
end;

procedure TTestLabels.TestSameChildForSameValues;
var
  R: TPromRegistry;
  C: TPromCounter;
begin
  R := TPromRegistry.Create;
  try
    C := R.Counter('c_total', 'c', ['a', 'b']);
    AssertTrue(C.Labels(['x', 'y']) = C.Labels(['x', 'y']));
    AssertTrue(C.Labels(['x', 'y']) <> C.Labels(['xy', '']));
    AssertTrue(C.Labels(['1', '23']) <> C.Labels(['12', '3']));
  finally
    R.Free;
  end;
end;

procedure TTestLabels.TestValueCountMismatch;
var
  R: TPromRegistry;
  C: TPromCounter;
  Raised: Boolean;
begin
  R := TPromRegistry.Create;
  try
    C := R.Counter('c_total', 'c', ['a']);
    Raised := False;
    try
      C.Labels(['1', '2']);
    except
      on EArgumentException do Raised := True;
    end;
    AssertTrue('wrong count', Raised);
    Raised := False;
    try
      C.Inc;   // a labelled family has no default child
    except
      on EInvalidOperation do Raised := True;
    end;
    AssertTrue('unlabelled use of labelled family', Raised);
  finally
    R.Free;
  end;
end;

procedure TTestLabels.TestMaxChildrenOverflow;
var
  R: TPromRegistry;
  C: TPromCounter;
  Over: TPromCounterChild;
  S: string;
  Raised: Boolean;
begin
  R := TPromRegistry.Create;
  try
    C := R.Counter('capped_total', 'Capped', ['a', 'b']);
    C.MaxChildren := 2;
    C.Labels(['1', 'x']).Inc;
    C.Labels(['2', 'y']).Inc;
    AssertFalse('not overflowed yet', C.Overflowed);
    Over := C.Labels(['3', 'z']);
    Over.Inc(5);
    AssertTrue('overflowed', C.Overflowed);
    AssertTrue('shared overflow child', Over = C.Labels(['4', 'w']));
    C.Labels(['4', 'w']).Inc(2);
    AssertEquals(7, Over.Value, 0);
    // existing combinations keep working and are not diverted
    C.Labels(['1', 'x']).Inc;
    S := R.Collect;
    AssertTrue(S, Pos('capped_total{a="1",b="x"} 2' + #10, S) > 0);
    AssertTrue(S, Pos('capped_total{a="2",b="y"} 1' + #10, S) > 0);
    AssertTrue(S, Pos('capped_total{a="__overflow__",b="__overflow__"} 7' + #10, S) > 0);
    // raising the cap lets new combinations through again
    C.MaxChildren := 3;
    C.Labels(['5', 'v']).Inc;
    S := R.Collect;
    AssertTrue(S, Pos('capped_total{a="5",b="v"} 1' + #10, S) > 0);
    Raised := False;
    try
      C.MaxChildren := -1;
    except
      on EArgumentException do Raised := True;
    end;
    AssertTrue('negative cap rejected', Raised);
  finally
    R.Free;
  end;
end;

{ Sum of the values of all exposition lines that start with Prefix. }
function SumSeries(const Text, Prefix: string): Double;
var
  L: TStringList;
  I, P: Integer;
begin
  Result := 0;
  L := TStringList.Create;
  try
    L.Text := Text;
    for I := 0 to L.Count - 1 do
      if Copy(L[I], 1, Length(Prefix)) = Prefix then
      begin
        P := LastDelimiter(' ', L[I]);
        Result := Result + StrToFloat(Copy(L[I], P + 1, MaxInt), DefaultFormatSettings);
      end;
  finally
    L.Free;
  end;
end;

type
  TCapThread = class(TThread)
  private
    FFamily: TPromCounter;
    FSeed: Integer;
  protected
    procedure Execute; override;
  public
    constructor Create(AFamily: TPromCounter; ASeed: Integer);
  end;

constructor TCapThread.Create(AFamily: TPromCounter; ASeed: Integer);
begin
  FFamily := AFamily;
  FSeed := ASeed;
  inherited Create(False);
end;

procedure TCapThread.Execute;
var
  I: Integer;
begin
  for I := 0 to 4999 do
    FFamily.Labels([IntToStr(FSeed * 100000 + I)]).Inc;
end;

procedure TTestLabels.TestMaxChildrenConcurrent;
const
  Cap = 100;
var
  R: TPromRegistry;
  C: TPromCounter;
  T: array[0..3] of TCapThread;
  I, Lines: Integer;
  S: string;
  P: Integer;
  Sum: Double;
begin
  R := TPromRegistry.Create;
  try
    C := R.Counter('cap_conc_total', 'x', ['id']);
    C.MaxChildren := Cap;
    for I := 0 to 3 do
      T[I] := TCapThread.Create(C, I);
    for I := 0 to 3 do
    begin
      T[I].WaitFor;
      T[I].Free;
    end;
    S := R.Collect;
    Lines := 0;
    P := Pos(#10 + 'cap_conc_total{', S);
    while P > 0 do
    begin
      Inc(Lines);
      P := Pos(#10 + 'cap_conc_total{', S, P + 1);
    end;
    AssertEquals('series = cap + overflow', Cap + 1, Lines);
    AssertTrue('overflowed', C.Overflowed);
    // no increment lost: every Labels() call landed on some child
    Sum := 0;
    for I := 0 to 3 do
      Sum := Sum + 5000;
    AssertTrue(S, Pos('cap_conc_total{id="__overflow__"} ', S) > 0);
    AssertEquals(Sum, SumSeries(S, 'cap_conc_total{'), 0);
  finally
    R.Free;
  end;
end;

procedure TTestLabels.TestInvalidLabelNames;
var
  R: TPromRegistry;
  N: Integer;

  procedure Expect(const Names: array of string);
  var
    Raised: Boolean;
  begin
    Raised := False;
    try
      R.Counter('m' + IntToStr(N) + '_total', 'x', Names);
    except
      on EArgumentException do Raised := True;
    end;
    AssertTrue('label names rejected #' + IntToStr(N), Raised);
    N := N + 1;
  end;

begin
  R := TPromRegistry.Create;
  try
    N := 0;
    Expect(['__reserved']);
    Expect(['bad-name']);
    Expect(['a', 'a']);
  finally
    R.Free;
  end;
end;

procedure TTestLabels.TestLabeledHistogramOutput;
var
  R: TPromRegistry;
  H: TPromHistogram;
  S: string;
begin
  R := TPromRegistry.Create;
  try
    H := R.Histogram('rpc_seconds', 'RPC', ['svc'], [0.1, 1]);
    H.Labels(['a']).Observe(0.05);
    H.Labels(['a']).Observe(2);
    S := R.Collect;
    AssertTrue(S, Pos('rpc_seconds_bucket{svc="a",le="0.1"} 1' + #10, S) > 0);
    AssertTrue(S, Pos('rpc_seconds_bucket{svc="a",le="+Inf"} 2' + #10, S) > 0);
    AssertTrue(S, Pos('rpc_seconds_count{svc="a"} 2' + #10, S) > 0);
    AssertTrue(S, Pos('rpc_seconds_sum{svc="a"} 2.05' + #10, S) > 0);
  finally
    R.Free;
  end;
end;

procedure TTestLabels.TestEscapedLabelValue;
var
  R: TPromRegistry;
  S: string;
begin
  R := TPromRegistry.Create;
  try
    R.Gauge('g', 'g', ['path']).Labels(['a"b\c' + #10]).SetValue(1);
    S := R.Collect;
    AssertTrue(S, Pos('g{path="a\"b\\c\n"} 1' + #10, S) > 0);
  finally
    R.Free;
  end;
end;

procedure TTestLabels.TestConcurrentLabels;
var
  R: TPromRegistry;
  C: TPromCounter;
  T: array[0..ThreadCount - 1] of TLabelWorker;
  I: Integer;
  Total: Double;
begin
  R := TPromRegistry.Create;
  try
    C := R.Counter('c_total', 'c', ['k']);
    for I := 0 to ThreadCount - 1 do
      T[I] := TLabelWorker.Create(C);
    for I := 0 to ThreadCount - 1 do
    begin
      T[I].WaitFor;
      T[I].Free;
    end;
    Total := 0;
    for I := 0 to 6 do
      Total := Total + C.Labels(['k' + IntToStr(I)]).Value;
    AssertEquals('total', Double(ThreadCount * Iterations), Total);
  finally
    R.Free;
  end;
end;

const
  StressIterations = 100000;   // divisible by 4 (label buckets)

type
  TStressRig = class
  public
    Registry: TPromRegistry;
    Counter: TPromCounter;
    Gauge: TPromGauge;
    InFlight: TPromGauge;
    Hist: TPromHistogram;
    Summ: TPromSummary;
    Labeled: TPromCounter;
    Stop: LongInt;   // set with InterlockedExchange
    constructor Create;
    destructor Destroy; override;
  end;

  { Base: remembers the first exception so the test thread can report it. }
  TStressThread = class(TThread)
  protected
    FRig: TStressRig;
    procedure Run; virtual; abstract;
    procedure Execute; override;
  public
    Error: string;
    constructor Create(ARig: TStressRig);
  end;

  TStressWorker = class(TStressThread)
  protected
    procedure Run; override;
  end;

  TStressScraper = class(TStressThread)
  protected
    procedure Run; override;
  public
    Scrapes: Integer;
  end;

constructor TStressRig.Create;
begin
  inherited Create;
  Registry := TPromRegistry.Create;
  Counter := Registry.Counter('stress_total', 'c');
  Gauge := Registry.Gauge('stress_gauge', 'g');
  InFlight := Registry.Gauge('stress_inflight', 'g');
  Hist := Registry.Histogram('stress_hist', 'h', [0.25, 1]);
  Summ := Registry.Summary('stress_summary', 's');
  Labeled := Registry.Counter('stress_labeled_total', 'l', ['k']);
end;

destructor TStressRig.Destroy;
begin
  Registry.Free;
  inherited Destroy;
end;

constructor TStressThread.Create(ARig: TStressRig);
begin
  FRig := ARig;
  inherited Create(True);   // started together by the test for maximum contention
end;

procedure TStressThread.Execute;
begin
  try
    Run;
  except
    on E: Exception do
      Error := E.ClassName + ': ' + E.Message;
  end;
end;

procedure TStressWorker.Run;
var
  I: Integer;
  P: TPromInProgress;
begin
  for I := 1 to StressIterations do
  begin
    FRig.Counter.Inc;
    FRig.Gauge.Inc(2);
    FRig.Gauge.Dec(1);                 // net +1 per iteration
    P := FRig.InFlight.TrackInProgress;
    P.Done;                            // net 0
    FRig.Hist.Observe(0.5);            // lands in the le="1" bucket; sums stay exact
    FRig.Summ.Observe(0.25);
    FRig.Labeled.Labels([IntToStr(I mod 4)]).Inc;   // lookup path, 4 shared children
  end;
end;

procedure TStressScraper.Run;
var
  Text: string;
  Last, Cur: Double;
  P, Q: Integer;
  FS: TFormatSettings;
begin
  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
  Last := -1;
  repeat
    Text := FRig.Registry.Collect;
    Inc(Scrapes);
    if Pos('# TYPE stress_hist histogram' + #10, Text) = 0 then
      raise Exception.Create('scrape lost a family');
    P := Pos(#10 + 'stress_total ', Text);
    if P = 0 then
      raise Exception.Create('scrape lost stress_total');
    P := P + Length(#10 + 'stress_total ');
    Q := P;
    while (Q <= Length(Text)) and (Text[Q] <> #10) do
      Inc(Q);
    if not TryStrToFloat(Copy(Text, P, Q - P), Cur, FS) then
      raise Exception.Create('unparsable counter: ' + Copy(Text, P, Q - P));
    if Cur < Last then
      raise Exception.CreateFmt('counter went backwards: %g -> %g', [Last, Cur]);
    Last := Cur;
    Sleep(0);   // yield only: Sleep(1) is ~15 ms on Windows and would hide most of the run
  until InterlockedCompareExchange(FRig.Stop, 0, 0) <> 0;
end;

procedure TTestStress.TestAllTypesConcurrentWithScrapes;
var
  Rig: TStressRig;
  Workers: array[0..ThreadCount - 1] of TStressWorker;
  Scraper: TStressScraper;
  I, K: Integer;
  Total: Int64;
  Text: string;
begin
  Total := Int64(ThreadCount) * StressIterations;
  Rig := TStressRig.Create;
  try
    Scraper := TStressScraper.Create(Rig);
    for I := 0 to ThreadCount - 1 do
      Workers[I] := TStressWorker.Create(Rig);
    try
      Scraper.Start;
      for I := 0 to ThreadCount - 1 do
        Workers[I].Start;
      for I := 0 to ThreadCount - 1 do
        Workers[I].WaitFor;
      InterlockedExchange(Rig.Stop, 1);
      Scraper.WaitFor;
      for I := 0 to ThreadCount - 1 do
        AssertEquals('worker ' + IntToStr(I), '', Workers[I].Error);
      AssertEquals('scraper', '', Scraper.Error);
      // ~5000 scrapes were seen on the dev machine; 100 proves real overlap with the writers
      AssertTrue('scrapes overlapped the run: ' + IntToStr(Scraper.Scrapes),
        Scraper.Scrapes >= 100);
    finally
      for I := 0 to ThreadCount - 1 do
        Workers[I].Free;
      Scraper.Free;
    end;

    AssertEquals('counter', Double(Total), Rig.Counter.Value);
    AssertEquals('gauge net', Double(Total), Rig.Gauge.Value);
    AssertEquals('in flight back to 0', 0.0, Rig.InFlight.Value);

    Text := Rig.Registry.Collect;
    AssertTrue(Text, Pos('stress_hist_bucket{le="0.25"} 0' + #10, Text) > 0);
    AssertTrue(Text, Pos('stress_hist_bucket{le="1"} ' + IntToStr(Total) + #10, Text) > 0);
    AssertTrue(Text, Pos('stress_hist_bucket{le="+Inf"} ' + IntToStr(Total) + #10, Text) > 0);
    AssertTrue(Text, Pos('stress_hist_sum ' + PromFormatFloat(0.5 * Total) + #10, Text) > 0);
    AssertTrue(Text, Pos('stress_hist_count ' + IntToStr(Total) + #10, Text) > 0);
    AssertTrue(Text, Pos('stress_summary_sum ' + PromFormatFloat(0.25 * Total) + #10, Text) > 0);
    AssertTrue(Text, Pos('stress_summary_count ' + IntToStr(Total) + #10, Text) > 0);
    for K := 0 to 3 do
      AssertTrue(Text, Pos('stress_labeled_total{k="' + IntToStr(K) + '"} ' +
        IntToStr(Total div 4) + #10, Text) > 0);
  finally
    Rig.Free;
  end;
end;

procedure TTestServer.TestServeMetrics;
const
  TestPort = 19187;
var
  R: TPromRegistry;
  Srv: TPromServer;
  Client: TFPHTTPClient;
  Body: string;
  Failed404: Boolean;
  Gauge: TPromUntyped;
begin
  R := TPromRegistry.Create;
  Srv := TPromServer.Create(TestPort, R);
  try
    Gauge := R.Untyped('served', 'Over HTTP.');
    Gauge.SetValue(42);
    Srv.Start;
    AssertTrue('active', Srv.Active);
    Client := TFPHTTPClient.Create(nil);
    try
      Body := Client.Get('http://127.0.0.1:' + IntToStr(TestPort) + '/metrics');
      AssertEquals(200, Client.ResponseStatusCode);
      AssertTrue(Client.GetHeader(Client.ResponseHeaders, 'Content-Type'),
        Pos('version=0.0.4', Client.GetHeader(Client.ResponseHeaders, 'Content-Type')) > 0);
      AssertTrue('first, tail bytes ' + IntToStr(Ord(Body[Length(Body)])) + ',' +
        IntToStr(Ord(Body[Length(Body) - 1])) + ',' + IntToStr(Ord(Body[Length(Body) - 2])) +
        ' len ' + IntToStr(Length(Body)), Pos('served 42' + #10, Body) > 0);
      // a second scrape on the same server sees updated values
      Gauge.SetValue(43);
      Body := Client.Get('http://127.0.0.1:' + IntToStr(TestPort) + '/metrics');
      AssertTrue('second: ' + Body, Pos('served 43' + #10, Body) > 0);
      Failed404 := False;
      try
        Client.Get('http://127.0.0.1:' + IntToStr(TestPort) + '/nope');
      except
        on EHTTPClient do
          Failed404 := True;
      end;
      AssertTrue('404 raised', Failed404);
      AssertEquals(404, Client.ResponseStatusCode);
    finally
      Client.Free;
    end;
    Srv.Stop;
    AssertFalse('stopped', Srv.Active);
  finally
    Srv.Free;
    R.Free;
  end;
end;

initialization
  RegisterTest(TTestServer);
  RegisterTest(TTestStress);
  RegisterTest(TTestAtomic);
  RegisterTest(TTestLabels);
  RegisterTest(TTestExposition);
  RegisterTest(TTestCollectors);
  RegisterTest(TTestMoreTypes);

end.
