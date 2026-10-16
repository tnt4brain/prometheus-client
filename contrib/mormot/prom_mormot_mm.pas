{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit prom_mormot_mm;
{ Heap metrics for programs that use mORMot's x86_64 memory manager (mormot.core.fpcx64mm).

  Under that manager FPC's GetFPCHeapStatus (what RegisterHeapMetrics reads) reports "used" equal
  to "size" and "free" as 0, so the fpc_heap_* gauges are misleading: call
  PromRegisterMormotHeapMetrics instead of RegisterHeapMetrics.

  Kept apart from prom_mormot because merely using mormot.core.fpcx64mm installs the memory
  manager, and it must then be the FIRST unit of the program's uses clause (before cthreads on
  Unix). Use this unit only in programs that already do that. x86_64 only, like the manager. }

{$mode objfpc}{$H+}

interface

uses
  prom_registry;

{ Registers mormot_heap_small_blocks, mormot_heap_small_blocks_bytes,
  mormot_heap_reserved_bytes{arena="medium"|"large"} (gauges, bytes reserved from the OS) and
  mormot_heap_sleep_total (counter: allocator waits on a lock; should stay near 0). }
procedure PromRegisterMormotHeapMetrics(R: TPromRegistry);

implementation

uses
  prom_collectors, mormot.core.fpcx64mm;

type
  THeapSource = class
    procedure Reserved(Samples: TPromSamples);
  end;

var
  Source: THeapSource;

function SmallBlocks(out V: Double): Boolean;
begin
  V := CurrentHeapStatus.SmallBlocks;
  Result := True;
end;

function SmallBlocksSize(out V: Double): Boolean;
begin
  V := CurrentHeapStatus.SmallBlocksSize;
  Result := True;
end;

function SleepCount(out V: Double): Boolean;
begin
  V := CurrentHeapStatus.SleepCount;
  Result := True;
end;

procedure THeapSource.Reserved(Samples: TPromSamples);
var
  S: TMMStatus;
begin
  S := CurrentHeapStatus;
  Samples.Add(['medium'], S.Medium.CurrentBytes);
  Samples.Add(['large'], S.Large.CurrentBytes);
end;

procedure PromRegisterMormotHeapMetrics(R: TPromRegistry);
begin
  R.Register(TPromCallbackMetric.Create('mormot_heap_small_blocks',
    'Tiny/small memory blocks currently allocated.', 'gauge', @SmallBlocks));
  R.Register(TPromCallbackMetric.Create('mormot_heap_small_blocks_bytes',
    'Bytes in tiny/small memory blocks currently allocated.', 'gauge', @SmallBlocksSize));
  R.Register(TPromCallbackFamily.Create('mormot_heap_reserved_bytes',
    'Bytes currently reserved from the OS, per arena.', 'gauge', ['arena'], @Source.Reserved));
  R.Register(TPromCallbackMetric.Create('mormot_heap_sleep_total',
    'Times the memory manager slept waiting for a lock.', 'counter', @SleepCount));
end;

initialization
  Source := THeapSource.Create;

finalization
  Source.Free;

end.
