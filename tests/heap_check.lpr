{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
program heap_check;
{ Use-after-free and leak check for Acquire/Release, using FPC's heap tracer.

  Build (heaptrc is in the uses clause, so do NOT pass -gh; lazbuild is not needed):
    fpc -gl -Mobjfpc -Fu../src -FUlib/heapcheck heap_check.lpr
  Run:
    heap_check        exit 0 = no leak, no double free, no write to freed memory
    heap_check uaf    negative control: writes to a freed child on purpose, so the
                      heap tracer must object (non-zero exit or an error report)

  keepreleased makes heaptrc never reuse a freed block: it fills it with $F0, and a write
  into it (an Inc on a freed child) is reported when the program ends. HaltOnNotReleased
  turns a leaked block into a non-zero exit. }

{$mode objfpc}{$H+}

uses
  heaptrc,   // first, so it sees every allocation; cthreads must follow it
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, prom_metrics, prom_registry, prom_exposition;

const
  Workers = 4;
  TotalOps = 4000000;    // across all workers; HC_OPS=<n> overrides it for a quick run

var
  OpsPerWorker: Integer;

type
  TChurn = class(TThread)
  private
    FFamily: TPromCounter;
    FSeed: Integer;
  protected
    procedure Execute; override;
  public
    Failed: Boolean;
    constructor Create(AFamily: TPromCounter; ASeed: Integer);
  end;

constructor TChurn.Create(AFamily: TPromCounter; ASeed: Integer);
begin
  FFamily := AFamily;
  FSeed := ASeed;
  inherited Create(False);
end;

procedure TChurn.Execute;
var
  I, K: Integer;
  Ch: TPromCounterChild;
begin
  try
    RandSeed := FSeed;
    for I := 1 to OpsPerWorker do
    begin
      K := Random(6);
      case Random(5) of
        0: FFamily.Remove([IntToStr(K)]);
        1: if Random(50) = 0 then FFamily.Clear;
        2: FFamily.Reclaim;
      else
        begin
          Ch := TPromCounterChild(FFamily.Acquire([IntToStr(K)]));
          try
            Ch.Inc;   // a write into a freed child is what heaptrc reports
          finally
            FFamily.Release(Ch);
          end;
        end;
      end;
    end;
  except
    Failed := True;
  end;
end;

procedure RunChurn;
var
  R: TPromRegistry;
  C: TPromCounter;
  T: array[0..Workers - 1] of TChurn;
  I: Integer;
  Done, Bad: Boolean;
begin
  R := TPromRegistry.Create;
  try
    C := R.Counter('churn_total', 'x', ['k']);
    for I := 0 to Workers - 1 do
      T[I] := TChurn.Create(C, I + 1);
    repeat
      Done := True;
      for I := 0 to Workers - 1 do
        if not T[I].Finished then Done := False;
      R.Collect;
      R.Collect(pfOpenMetrics);
    until Done;
    Bad := False;
    for I := 0 to Workers - 1 do
    begin
      T[I].WaitFor;
      if T[I].Failed then Bad := True;
      T[I].Free;
    end;
    C.Reclaim;
    if Bad or (C.RetiredCount <> 0) then
    begin
      WriteLn('FAIL: worker failed or children left behind: ', C.RetiredCount);
      Halt(2);
    end;
  finally
    R.Free;
  end;
end;

procedure RunUseAfterFree;
var
  R: TPromRegistry;
  C: TPromCounter;
  Ch: TPromCounterChild;
begin
  R := TPromRegistry.Create;
  try
    C := R.Counter('uaf_total', 'x', ['k']);
    Ch := TPromCounterChild(C.Acquire(['a']));
    C.Release(Ch);
    C.Remove(['a']);   // unheld and unpinned: freed right here
    Ch.Inc;            // deliberate bug: write into the freed block
  finally
    R.Free;
  end;
end;

begin
  heaptrc.keepreleased := GetEnvironmentVariable('HC_NOKEEP') = '';
  heaptrc.HaltOnNotReleased := True;
  OpsPerWorker := StrToIntDef(GetEnvironmentVariable('HC_OPS'), TotalOps) div Workers;
  if (ParamCount > 0) and (ParamStr(1) = 'uaf') then
    RunUseAfterFree
  else
    RunChurn;
  WriteLn('done');
end.
