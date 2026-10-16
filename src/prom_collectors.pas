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
  SysUtils, Classes, prom_exposition, prom_metrics, prom_registry;

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
  end;

{ process_cpu_seconds_total, process_resident_memory_bytes, process_virtual_memory_bytes,
  process_start_time_seconds, process_open_fds. }
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
  BaseUnix, Unix;
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
  W.WriteHeader(Name, Help, FType);
  W.WriteSample(Name, '', V);
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
    W.WriteHeader(Name, Help, FType);
    for I := 0 to High(S.FPairs) do
      W.WriteSample(Name, S.FPairs[I], S.FValues[I]);
  finally
    S.Free;
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
    V := (FileTimeToInt64(K) + FileTimeToInt64(U)) / 1e7;
end;

function ProcStartTime(out V: Double): Boolean;
var
  C, E, K, U: TFileTime;
begin
  Result := GetProcessTimes(GetCurrentProcess, C, E, K, U);
  if Result then
    V := (FileTimeToInt64(C) - FileTimeUnixEpoch) / 1e7;
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
    UTime, STime, StartTime, VSize, RssPages: Int64;
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
  S.VSize := StrToInt64Def(Parts[20], 0);
  S.RssPages := StrToInt64Def(Parts[21], 0);
  Result := True;
end;

function ClockTicks: Double;
var
  T: Int64;
begin
  T := fpSysConf(2);  // _SC_CLK_TCK
  if T <= 0 then
    T := 100;
  Result := T;
end;

function ProcCpuSeconds(out V: Double): Boolean;
var
  S: TProcStat;
begin
  Result := ReadProcStat(S);
  if Result then
    V := (S.UTime + S.STime) / ClockTicks;
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
  V := BTime + S.StartTime / ClockTicks;
  Result := True;
end;

function ProcResidentBytes(out V: Double): Boolean;
var
  S: TProcStat;
begin
  Result := ReadProcStat(S);
  if Result then
    V := S.RssPages * Double(fpSysConf(30));  // _SC_PAGESIZE
end;

function ProcVirtualBytes(out V: Double): Boolean;
var
  S: TProcStat;
begin
  Result := ReadProcStat(S);
  if Result then
    V := S.VSize;
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
