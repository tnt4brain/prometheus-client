{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit prom_clock;
{ Monotonic clock for timers. Resolution: QueryPerformanceCounter on Windows,
  clock_gettime(CLOCK_MONOTONIC) on Linux, millisecond ticks elsewhere. }

{$mode objfpc}{$H+}

interface

{ Seconds since an arbitrary fixed point; only differences are meaningful. }
function PromMonotonicSeconds: Double;

type
  TPromEpochClock = function: Double;

var
  { Source of "created" timestamps and Gauge.SetToCurrentTime. Replace it to make
    output deterministic (tests); assign nil to restore the system clock. }
  PromEpochClock: TPromEpochClock = nil;

{ Unix time in seconds (UTC) from PromEpochClock, or the system clock. }
function PromEpochSeconds: Double;

implementation

uses
  SysUtils, DateUtils
  {$IFDEF MSWINDOWS}, Windows{$ENDIF}
  {$IFDEF LINUX}, Linux, UnixType{$ENDIF};

function PromEpochSeconds: Double;
begin
  if Assigned(PromEpochClock) then
    Result := PromEpochClock()
  else
    Result := (LocalTimeToUniversal(Now) - UnixDateDelta) * SecsPerDay;
end;

{$IFDEF MSWINDOWS}
var
  Frequency: Int64;

function PromMonotonicSeconds: Double;
var
  Counter: Int64;
begin
  if (Frequency <> 0) and QueryPerformanceCounter(Counter) then
    Result := Counter / Frequency
  else
    Result := Double(GetTickCount64) / 1000;
end;

initialization
  if not QueryPerformanceFrequency(Frequency) then
    Frequency := 0;
{$ELSE}
function PromMonotonicSeconds: Double;
{$IFDEF LINUX}
var
  TS: timespec;
begin
  if clock_gettime(CLOCK_MONOTONIC, @TS) = 0 then
  begin
    // Double() casts: "Int64 + Int64 / 1e9" is evaluated in Single precision by FPC
    Result := Double(TS.tv_sec);
    Result := Result + Double(TS.tv_nsec) / 1e9;
  end
  else
    Result := Double(GetTickCount64) / 1000;
end;
{$ELSE}
begin
  Result := Double(GetTickCount64) / 1000;
end;
{$ENDIF}
{$ENDIF}

end.
