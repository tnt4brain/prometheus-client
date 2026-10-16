{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit prom_collectors;
{ Metrics computed at scrape time: process (CPU, memory, handles, start time) and
  FPC heap. They are ordinary TPromMetric descendants registered with
  TPromRegistry.Register, so the core has no dependency on this unit.

  Names follow the standard Prometheus process_* collector; the FPC heap
  metrics are fpc_heap_*. A value that cannot be read on the platform is
  omitted from the output (header included). }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Math, prom_exposition, prom_metrics, prom_registry, prom_sketch;

type
  { Returns False when the value is unavailable. }
  TPromValueFunc = function(out Value: Double): Boolean;

  { A label-less counter or gauge whose value is read by calling Func on each scrape. }
  TPromCallbackMetric = class(TPromMetric)
  private
    FType: string;
    FFunc: TPromValueFunc;
  public
    constructor Create(const AName, AHelp, AMetricType: string; AFunc: TPromValueFunc);
    procedure Collect(W: TPromTextWriter); override;
    function ExposedType: string; override;
  end;

  { Receives the samples of one scrape from a TPromCallbackFamily callback. }
  TPromSamples = class
  private
    FLabelNames: array of string;
    FPairs: array of string;
    FValues: array of Double;
  public
    { LabelValues must match the family's label names in number. }
    procedure Add(const LabelValues: array of string; Value: Double);
  end;

  TPromSamplesProc = procedure(Samples: TPromSamples) of object;

  { A counter or gauge with labels whose series are produced by Proc on each scrape,
    e.g. queue depth per queue. Proc may raise: the scrape then fails as a whole and
    nothing from this family is written. Proc runs on the scraping thread. }
  TPromCallbackFamily = class(TPromMetric)
  private
    FType: string;
    FLabelNames: array of string;
    FProc: TPromSamplesProc;
  public
    constructor Create(const AName, AHelp, AMetricType: string;
      const ALabelNames: array of string; AProc: TPromSamplesProc);
    procedure Collect(W: TPromTextWriter); override;
    function ExposedType: string; override;
  end;

  { Receives the series of one scrape from a TPromCallbackGaugeHistogram callback. }
  TPromGaugeHistogramData = class
  private
    FLabelNames: array of string;
    FPairs: array of string;
    FBounds: array of TPromDoubleArray;
    FCounts: array of array of Int64;
    FSums: array of Double;
  public
    { One histogram series. UpperBounds ascending and ending in +Inf (Infinity);
      CumulativeCounts has one entry per bound and never decreases (the last one is the
      total count). Raises EArgumentException for anything that breaks these rules. }
    procedure Add(const LabelValues: array of string; const UpperBounds: array of Double;
      const CumulativeCounts: array of Int64; Sum: Double);
  end;

  TPromGaugeHistogramProc = procedure(Data: TPromGaugeHistogramData) of object;

  { A GaugeHistogram (OpenMetrics): a distribution of a quantity that can go down again,
    e.g. how long the jobs currently queued have been waiting. It is the snapshot of a
    point in time, so it has no instrument; Proc supplies the buckets on each scrape
    (on the scraping thread; if it raises, the scrape fails). Samples are _bucket, _gcount
    and _gsum, without _created or exemplars. The classic text format has no such type and
    gets "# TYPE name gauge" with the same sample names. }
  TPromCallbackGaugeHistogram = class(TPromMetric)
  private
    FLabelNames: array of string;
    FProc: TPromGaugeHistogramProc;
  public
    constructor Create(const AName, AHelp: string; const ALabelNames: array of string;
      AProc: TPromGaugeHistogramProc);
    procedure Collect(W: TPromTextWriter); override;
    function ExposedType: string; override;
  end;

{ process_cpu_seconds_total, process_resident_memory_bytes, process_virtual_memory_bytes,
  process_start_time_seconds, process_open_fds, and process_max_fds (Unix only). }
procedure RegisterProcessMetrics(R: TPromRegistry);

{ fpc_heap_size_bytes, fpc_heap_used_bytes, fpc_heap_free_bytes. }
procedure RegisterHeapMetrics(R: TPromRegistry);

implementation

{$IFDEF MSWINDOWS}
uses
  Windows;
{$ENDIF}
{$IFDEF UNIX}
uses
  StrUtils;   // Math comes from the interface section
{$ENDIF}

constructor TPromCallbackMetric.Create(const AName, AHelp, AMetricType: string;
  AFunc: TPromValueFunc);
begin
  inherited Create(AName, AHelp);
  FType := AMetricType;
  FFunc := AFunc;
end;

procedure TPromCallbackMetric.Collect(W: TPromTextWriter);
var
  V: Double;
begin
  if not FFunc(V) then
    Exit;
  W.WriteHeader(Name, Help, FType, MetricUnit);
  W.WriteSample(W.SampleName(FType, Name), '', V);
end;

function TPromCallbackMetric.ExposedType: string;
begin
  Result := FType;
end;

{ TPromSamples }

procedure TPromSamples.Add(const LabelValues: array of string; Value: Double);
var
  N: Integer;
begin
  if Length(LabelValues) <> Length(FLabelNames) then
    raise EArgumentException.CreateFmt('Expected %d label value(s), got %d',
      [Length(FLabelNames), Length(LabelValues)]);
  N := Length(FPairs);
  SetLength(FPairs, N + 1);
  SetLength(FValues, N + 1);
  FPairs[N] := PromFormatLabelPairs(FLabelNames, LabelValues);
  FValues[N] := Value;
end;

{ TPromCallbackFamily }

constructor TPromCallbackFamily.Create(const AName, AHelp, AMetricType: string;
  const ALabelNames: array of string; AProc: TPromSamplesProc);
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
  FType := AMetricType;
  FProc := AProc;
end;

procedure TPromCallbackFamily.Collect(W: TPromTextWriter);
var
  S: TPromSamples;
  I: Integer;
begin
  S := TPromSamples.Create;
  try
    S.FLabelNames := FLabelNames;
    FProc(S);
    W.WriteHeader(Name, Help, FType, MetricUnit);
    for I := 0 to High(S.FPairs) do
      W.WriteSample(W.SampleName(FType, Name), S.FPairs[I], S.FValues[I]);
  finally
    S.Free;
  end;
end;

function TPromCallbackFamily.ExposedType: string;
begin
  Result := FType;
end;

{ TPromGaugeHistogramData }

procedure TPromGaugeHistogramData.Add(const LabelValues: array of string;
  const UpperBounds: array of Double; const CumulativeCounts: array of Int64; Sum: Double);
var
  I, N: Integer;
begin
  if Length(LabelValues) <> Length(FLabelNames) then
    raise EArgumentException.CreateFmt('Expected %d label value(s), got %d',
      [Length(FLabelNames), Length(LabelValues)]);
  if Length(UpperBounds) = 0 then
    raise EArgumentException.Create('A gauge histogram needs at least the +Inf bucket');
  if Length(CumulativeCounts) <> Length(UpperBounds) then
    raise EArgumentException.Create('UpperBounds and CumulativeCounts must have the same length');
  for I := 0 to High(UpperBounds) do
  begin
    // IsNan first: comparing a NaN raises EInvalidOp instead of returning False
    if IsNan(UpperBounds[I]) then
      raise EArgumentException.Create('A bucket bound cannot be NaN');
    if (I > 0) and not (UpperBounds[I] > UpperBounds[I - 1]) then
      raise EArgumentException.Create('Bucket bounds must be strictly ascending');
    if CumulativeCounts[I] < 0 then
      raise EArgumentException.Create('Bucket counts cannot be negative');
    if (I > 0) and (CumulativeCounts[I] < CumulativeCounts[I - 1]) then
      raise EArgumentException.Create('Cumulative bucket counts cannot decrease');
  end;
  if not (IsInfinite(UpperBounds[High(UpperBounds)]) and (UpperBounds[High(UpperBounds)] > 0)) then
    raise EArgumentException.Create('The last bucket bound must be +Inf');
  N := Length(FPairs);
  SetLength(FPairs, N + 1);
  SetLength(FBounds, N + 1);
  SetLength(FCounts, N + 1);
  SetLength(FSums, N + 1);
  FPairs[N] := PromFormatLabelPairs(FLabelNames, LabelValues);
  SetLength(FBounds[N], Length(UpperBounds));
  SetLength(FCounts[N], Length(UpperBounds));
  for I := 0 to High(UpperBounds) do
  begin
    FBounds[N][I] := UpperBounds[I];
    FCounts[N][I] := CumulativeCounts[I];
  end;
  FSums[N] := Sum;
end;

{ TPromCallbackGaugeHistogram }

constructor TPromCallbackGaugeHistogram.Create(const AName, AHelp: string;
  const ALabelNames: array of string; AProc: TPromGaugeHistogramProc);
var
  I, J: Integer;
begin
  inherited Create(AName, AHelp);
  SetLength(FLabelNames, Length(ALabelNames));
  for I := 0 to High(ALabelNames) do
  begin
    if not PromValidLabelName(ALabelNames[I]) then
      raise EArgumentException.CreateFmt('Invalid label name "%s"', [ALabelNames[I]]);
    if ALabelNames[I] = 'le' then
      raise EArgumentException.Create('Label name "le" is reserved for histograms');
    for J := 0 to I - 1 do
      if FLabelNames[J] = ALabelNames[I] then
        raise EArgumentException.CreateFmt('Duplicate label name "%s"', [ALabelNames[I]]);
    FLabelNames[I] := ALabelNames[I];
  end;
  FProc := AProc;
end;

function TPromCallbackGaugeHistogram.ExposedType: string;
begin
  Result := 'gaugehistogram';
end;

procedure TPromCallbackGaugeHistogram.Collect(W: TPromTextWriter);
var
  D: TPromGaugeHistogramData;
  I, J: Integer;
  Sep: string;
begin
  D := TPromGaugeHistogramData.Create;
  try
    D.FLabelNames := FLabelNames;
    FProc(D);
    W.WriteHeader(Name, Help, 'gaugehistogram', MetricUnit);
    for I := 0 to High(D.FPairs) do
    begin
      if D.FPairs[I] = '' then Sep := '' else Sep := D.FPairs[I] + ',';
      for J := 0 to High(D.FBounds[I]) do
        W.WriteSample(Name + '_bucket', Sep + 'le="' + W.FormatLe(D.FBounds[I][J]) + '"',
          D.FCounts[I][J]);
      W.WriteSample(Name + '_gcount', D.FPairs[I], D.FCounts[I][High(D.FCounts[I])]);
      W.WriteSample(Name + '_gsum', D.FPairs[I], D.FSums[I]);
    end;
  finally
    D.Free;
  end;
end;

{ ---- process, Windows ---- }

{$IFDEF MSWINDOWS}
type
  TProcessMemoryCounters = record
    cb, PageFaultCount: DWORD;
    PeakWorkingSetSize, WorkingSetSize, QuotaPeakPagedPoolUsage, QuotaPagedPoolUsage,
    QuotaPeakNonPagedPoolUsage, QuotaNonPagedPoolUsage, PagefileUsage,
    PeakPagefileUsage: PtrUInt;
  end;

function GetProcessMemoryInfo(Process: THandle; var Counters: TProcessMemoryCounters;
  cb: DWORD): BOOL; stdcall; external 'psapi.dll';
function GetProcessHandleCount(Process: THandle; var Count: DWORD): BOOL; stdcall;
  external 'kernel32.dll';

const
  FileTimeUnixEpoch = 116444736000000000;  // 1601-01-01 .. 1970-01-01 in 100 ns

function FileTimeToInt64(const FT: TFileTime): Int64;
begin
  Result := (Int64(FT.dwHighDateTime) shl 32) or FT.dwLowDateTime;
end;

function ProcCpuSeconds(out V: Double): Boolean;
var
  C, E, K, U: TFileTime;
begin
  Result := GetProcessTimes(GetCurrentProcess, C, E, K, U);
  if Result then
    V := Double(FileTimeToInt64(K) + FileTimeToInt64(U)) / 1e7;   // Double(): see ProcStartTime
end;

function ProcStartTime(out V: Double): Boolean;
var
  C, E, K, U: TFileTime;
begin
  Result := GetProcessTimes(GetCurrentProcess, C, E, K, U);
  if Result then
    // Double() matters: Int64 / 1e7 alone is evaluated in Single precision by FPC, which
    // rounds an epoch time to 128 s.
    V := Double(FileTimeToInt64(C) - FileTimeUnixEpoch) / 1e7;
end;

function ProcResidentBytes(out V: Double): Boolean;
var
  M: TProcessMemoryCounters;
begin
  M.cb := SizeOf(M);
  Result := GetProcessMemoryInfo(GetCurrentProcess, M, SizeOf(M));
  if Result then
    V := M.WorkingSetSize;
end;

function ProcVirtualBytes(out V: Double): Boolean;
var
  M: TProcessMemoryCounters;
begin
  M.cb := SizeOf(M);
  Result := GetProcessMemoryInfo(GetCurrentProcess, M, SizeOf(M));
  if Result then
    V := M.PagefileUsage;  // private commit charge; Windows has no "virtual size" figure
end;

function ProcOpenFds(out V: Double): Boolean;
var
  N: DWORD;
begin
  Result := GetProcessHandleCount(GetCurrentProcess, N);
  if Result then
    V := N;
end;
{$ENDIF}

{ ---- process, Unix (/proc; untested outside Linux) ---- }

{$IFDEF UNIX}
type
  TProcStat = record
    UTime, STime, StartTime: Int64;   // clock ticks
  end;

{ /proc/self/stat: the command name sits in parentheses and may contain spaces, so
  split after the last ')'. Fields after it start at number 3 (state). }
function ReadProcStat(out S: TProcStat): Boolean;
var
  L: TStringList;
  Line: string;
  Parts: TStringArray;
  P: Integer;
begin
  Result := False;
  L := TStringList.Create;
  try
    try
      L.LoadFromFile('/proc/self/stat');
    except
      Exit;
    end;
    if L.Count = 0 then
      Exit;
    Line := L[0];
  finally
    L.Free;
  end;
  P := RPos(')', Line);
  if P = 0 then
    Exit;
  Parts := Trim(Copy(Line, P + 1, MaxInt)).Split(' ');
  if Length(Parts) < 22 then
    Exit;
  // Parts[0] is field 3, so field N is Parts[N - 3]
  S.UTime := StrToInt64Def(Parts[11], 0);
  S.STime := StrToInt64Def(Parts[12], 0);
  S.StartTime := StrToInt64Def(Parts[19], 0);
  Result := True;
end;

{ The tick unit of /proc/self/stat is USER_HZ, which is 100 on every Linux
  architecture (the kernel ABI), so no sysconf(_SC_CLK_TCK) call is needed. }
function ClockTicks: Double;
begin
  Result := 100;
end;

{ A "Key:   1234 kB" line of /proc/self/status, returned in bytes. }
function ReadStatusBytes(const Key: string; out Bytes: Double): Boolean;
var
  L: TStringList;
  I: Integer;
  Kb: Int64;
begin
  Result := False;
  L := TStringList.Create;
  try
    try
      L.LoadFromFile('/proc/self/status');
    except
      Exit;
    end;
    for I := 0 to L.Count - 1 do
      if Copy(L[I], 1, Length(Key) + 1) = Key + ':' then
      begin
        Kb := StrToInt64Def(Trim(StringReplace(Copy(L[I], Length(Key) + 2, MaxInt), 'kB', '', [])), -1);
        if Kb < 0 then
          Exit;
        Bytes := Double(Kb) * 1024;
        Exit(True);
      end;
  finally
    L.Free;
  end;
end;

function ProcCpuSeconds(out V: Double): Boolean;
var
  S: TProcStat;
begin
  Result := ReadProcStat(S);
  if Result then
    V := Double(S.UTime + S.STime) / ClockTicks;
end;

function ProcStartTime(out V: Double): Boolean;
var
  S: TProcStat;
  L: TStringList;
  I: Integer;
  BTime: Int64;
begin
  Result := False;
  if not ReadProcStat(S) then
    Exit;
  BTime := 0;
  L := TStringList.Create;
  try
    try
      L.LoadFromFile('/proc/stat');
    except
      Exit;
    end;
    for I := 0 to L.Count - 1 do
      if Copy(L[I], 1, 6) = 'btime ' then
        BTime := StrToInt64Def(Trim(Copy(L[I], 7, MaxInt)), 0);
  finally
    L.Free;
  end;
  if BTime = 0 then
    Exit;
  V := Double(BTime) + Double(S.StartTime) / ClockTicks;
  Result := True;
end;

function ProcResidentBytes(out V: Double): Boolean;
begin
  Result := ReadStatusBytes('VmRSS', V);
end;

function ProcVirtualBytes(out V: Double): Boolean;
begin
  Result := ReadStatusBytes('VmSize', V);
end;

function ProcOpenFds(out V: Double): Boolean;
var
  SR: TSearchRec;
  N: Integer;
begin
  Result := FindFirst('/proc/self/fd/*', faAnyFile, SR) = 0;
  if not Result then
    Exit;
  N := 0;
  try
    repeat
      if (SR.Name <> '.') and (SR.Name <> '..') then
        Inc(N);
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
  V := N - 1;  // the directory handle used for this listing
end;

{ Soft limit from the "Max open files  <soft>  <hard>  files" line of /proc/self/limits;
  "unlimited" becomes +Inf. }
function ProcMaxFds(out V: Double): Boolean;
var
  L: TStringList;
  I: Integer;
  Tok: string;
  P: Integer;
begin
  Result := False;
  L := TStringList.Create;
  try
    try
      L.LoadFromFile('/proc/self/limits');
    except
      Exit;
    end;
    for I := 0 to L.Count - 1 do
      if Copy(L[I], 1, 14) = 'Max open files' then
      begin
        Tok := Trim(Copy(L[I], 15, MaxInt));
        P := Pos(' ', Tok);
        if P > 0 then
          Tok := Copy(Tok, 1, P - 1);
        if Tok = 'unlimited' then
          V := Infinity
        else if StrToInt64Def(Tok, -1) >= 0 then
          V := StrToInt64(Tok)
        else
          Exit;
        Exit(True);
      end;
  finally
    L.Free;
  end;
end;
{$ENDIF}

procedure RegisterProcessMetrics(R: TPromRegistry);
begin
  R.Register(TPromCallbackMetric.Create('process_cpu_seconds_total',
    'Total user and system CPU time spent in seconds.', 'counter', @ProcCpuSeconds));
  R.Register(TPromCallbackMetric.Create('process_resident_memory_bytes',
    'Resident memory size in bytes.', 'gauge', @ProcResidentBytes));
  R.Register(TPromCallbackMetric.Create('process_virtual_memory_bytes',
    'Virtual memory size in bytes.', 'gauge', @ProcVirtualBytes));
  R.Register(TPromCallbackMetric.Create('process_start_time_seconds',
    'Start time of the process since unix epoch in seconds.', 'gauge', @ProcStartTime));
  R.Register(TPromCallbackMetric.Create('process_open_fds',
    'Number of open file descriptors (handles on Windows).', 'gauge', @ProcOpenFds));
  {$IFDEF UNIX}
  R.Register(TPromCallbackMetric.Create('process_max_fds',
    'Maximum number of open file descriptors.', 'gauge', @ProcMaxFds));
  {$ENDIF}
end;

{ ---- FPC heap ---- }

function HeapSize(out V: Double): Boolean;
begin
  V := GetFPCHeapStatus.CurrHeapSize;
  Result := True;
end;

function HeapUsed(out V: Double): Boolean;
begin
  V := GetFPCHeapStatus.CurrHeapUsed;
  Result := True;
end;

function HeapFree(out V: Double): Boolean;
begin
  V := GetFPCHeapStatus.CurrHeapFree;
  Result := True;
end;

procedure RegisterHeapMetrics(R: TPromRegistry);
begin
  R.Register(TPromCallbackMetric.Create('fpc_heap_size_bytes',
    'Size of the FPC heap in bytes.', 'gauge', @HeapSize));
  R.Register(TPromCallbackMetric.Create('fpc_heap_used_bytes',
    'Bytes of the FPC heap in use.', 'gauge', @HeapUsed));
  R.Register(TPromCallbackMetric.Create('fpc_heap_free_bytes',
    'Free bytes inside the FPC heap.', 'gauge', @HeapFree));
end;

end.
