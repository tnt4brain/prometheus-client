{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit prom_atomic;
{ Lock-free primitives for metric values. Doubles are stored as their Int64 bit
  pattern so they can be updated with compare-and-swap. }

{$mode objfpc}{$H+}

interface

{ Adds N to V atomically; returns the new value. }
function AtomicAddInt64(var V: Int64; N: Int64): Int64;

{ Atomic read of an Int64 (not torn on 32-bit targets). }
function AtomicLoadInt64(var V: Int64): Int64;

{ Atomic store of an Int64 (not torn on 32-bit targets). }
procedure AtomicStoreInt64(var V: Int64; N: Int64);

{ Publishes New into P if P still holds Expected; returns the value P held before. }
function AtomicCasPointer(var P: Pointer; New, Expected: Pointer): Pointer;

{ Double held in an Int64 bit pattern; Bits must start at 0 (= 0.0). }
procedure AtomicAddDouble(var Bits: Int64; Delta: Double);
procedure AtomicStoreDouble(var Bits: Int64; Value: Double);
function AtomicLoadDouble(var Bits: Int64): Double;

implementation

type
  TDoubleBits = record
    case Boolean of
      False: (D: Double);
      True: (I: Int64);
  end;

function ToBits(D: Double): Int64; inline;
var
  R: TDoubleBits;
begin
  R.D := D;
  Result := R.I;
end;

function FromBits(I: Int64): Double; inline;
var
  R: TDoubleBits;
begin
  R.I := I;
  Result := R.D;
end;

function AtomicLoadInt64(var V: Int64): Int64;
begin
  Result := InterlockedCompareExchange64(V, 0, 0);
end;

procedure AtomicStoreInt64(var V: Int64; N: Int64);
var
  Old: Int64;
begin
  repeat
    Old := AtomicLoadInt64(V);
  until InterlockedCompareExchange64(V, N, Old) = Old;
end;

function AtomicCasPointer(var P: Pointer; New, Expected: Pointer): Pointer;
begin
  Result := InterlockedCompareExchange(P, New, Expected);
end;

function AtomicAddInt64(var V: Int64; N: Int64): Int64;
var
  Old: Int64;
begin
  repeat
    Old := AtomicLoadInt64(V);
  until InterlockedCompareExchange64(V, Old + N, Old) = Old;
  Result := Old + N;
end;

function AtomicLoadDouble(var Bits: Int64): Double;
begin
  Result := FromBits(AtomicLoadInt64(Bits));
end;

procedure AtomicStoreDouble(var Bits: Int64; Value: Double);
var
  Old: Int64;
begin
  repeat
    Old := AtomicLoadInt64(Bits);
  until InterlockedCompareExchange64(Bits, ToBits(Value), Old) = Old;
end;

procedure AtomicAddDouble(var Bits: Int64; Delta: Double);
var
  Old: Int64;
begin
  repeat
    Old := AtomicLoadInt64(Bits);
  until InterlockedCompareExchange64(Bits, ToBits(FromBits(Old) + Delta), Old) = Old;
end;

end.
