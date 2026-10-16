{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit test_metrics;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry, prom_atomic, prom_metrics, prom_registry,
  prom_exposition, prom_collectors, Math, DateUtils;

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

  TTestCollectors = class(TTestCase)
  published
    procedure TestHeapMetrics;
    procedure TestProcessMetrics;
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

initialization
  RegisterTest(TTestAtomic);
  RegisterTest(TTestLabels);
  RegisterTest(TTestExposition);
  RegisterTest(TTestCollectors);
  RegisterTest(TTestMoreTypes);

end.
