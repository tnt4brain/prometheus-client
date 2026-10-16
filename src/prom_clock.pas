{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit prom_clock;
{ Monotonic clock for timers. Resolution: QueryPerformanceCounter on Windows,
  clock_gettime(CLOCK_MONOTONIC) on Linux, millisecond ticks elsewhere. }

{$mode objfpc}{$H+}

interface

{ Seconds since an arbitrary fixed point; only differences are meaningful. }
function PromMonotonicSeconds: Double;

implementation

uses
  SysUtils
  {$IFDEF MSWINDOWS}, Windows{$ENDIF}
  {$IFDEF LINUX}, Linux, UnixType{$ENDIF};

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
    Result := GetTickCount64 / 1000;
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
    Result := TS.tv_sec + TS.tv_nsec / 1e9
  else
    Result := GetTickCount64 / 1000;
end;
{$ELSE}
begin
  Result := GetTickCount64 / 1000;
end;
{$ENDIF}
{$ENDIF}

end.
