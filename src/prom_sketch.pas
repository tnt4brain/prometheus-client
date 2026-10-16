{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit prom_sketch;
{ Windowed quantile sketch for summaries: a log-bucket histogram with a bounded
  RELATIVE error (DDSketch style), kept in a ring of time slots.

  * Bucket i covers (MinValue*g^(i-1), MinValue*g^i] with g = (1+a)/(1-a), a = Accuracy,
    so any estimate is within a (default 1%) of the true value for values inside
    [MinValue, MaxValue]. Values outside that range, zero and negative values are clamped
    into the lowest / highest bucket (quantiles assume non-negative data); NaN is ignored.
  * Observe is lock-free: a bucket index computation and one atomic add. Counters live in
    pages of 64 buckets that are allocated on first use and published with a pointer CAS
    (the loser frees its page, which was never visible), so memory follows the value range
    actually seen, not the configured range.
  * Window: AgeSlots slots of MaxAge/AgeSlots seconds each. An observation goes into the slot
    of the current tick; the thread that finds the slot stamped with an older tick wins a CAS
    on the slot's epoch and zeroes it. An increment racing with that reset can be lost or
    land in the new window: a tiny error at slot boundaries, by design. A scrape merges the
    slots whose epoch is inside the window; quantiles of an empty window are NaN.
  * Results are rounded to 6 significant digits (far below the sketch error), so exposition
    output does not depend on last-bit differences of Ln/Exp between platforms. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Math, prom_atomic, prom_clock;

type
  TPromSketchOptions = record
    Accuracy: Double;    // relative error, 0 < Accuracy < 0.5
    MinValue: Double;    // smallest distinguishable positive value
    MaxValue: Double;
    MaxAge: Double;      // window length in seconds
    AgeSlots: Integer;   // number of slots the window is cut into
  end;

  TPromDoubleArray = array of Double;

const
  PromSketchPageBits = 6;
  PromSketchPageSize = 1 shl PromSketchPageBits;

{ 1% accuracy, 1e-9..1e9, 10 minute window in 5 slots (like the Go client's defaults). }
function PromDefaultSketchOptions: TPromSketchOptions;
{ Raises EArgumentException when the options are unusable. }
procedure PromCheckSketchOptions(const O: TPromSketchOptions);

type
  TPromSketchPage = array[0..PromSketchPageSize - 1] of Int64;
  PPromSketchPage = ^TPromSketchPage;

  TPromSketchSlot = class
  private
    FEpoch: Int64;                    // tick this slot holds; 0 = never used
    FPages: array of Pointer;         // PPromSketchPage, nil until first use
  public
    constructor Create(APageCount: Integer);
    destructor Destroy; override;
    procedure Add(BucketIndex: Integer);
    procedure Clear;
  end;

  TPromSketch = class
  private
    FOpt: TPromSketchOptions;
    FGamma, FLnGamma, FLnMin: Double;
    FBuckets: Integer;
    FSlotLen: Double;
    FSlots: array of TPromSketchSlot;
    function BucketOf(V: Double): Integer;
    function BucketValue(I: Integer): Double;
    function TickOf(Now: Double): Int64;
  public
    constructor Create(const AOptions: TPromSketchOptions);
    destructor Destroy; override;
    { Lock-free. Now is a monotonic time in seconds (PromMonotonicSeconds). }
    procedure ObserveAt(V, Now: Double);
    procedure Observe(V: Double);
    { Estimates for the given quantiles (0..1, any order) over the window ending at Now;
      NaN for every quantile when the window holds no observations. }
    function QuantilesAt(const Qs: array of Double; Now: Double): TPromDoubleArray;
    function Quantiles(const Qs: array of Double): TPromDoubleArray;
    { Number of observations currently inside the window. }
    function CountAt(Now: Double): Int64;
    property Buckets: Integer read FBuckets;
  end;

implementation

function PromDefaultSketchOptions: TPromSketchOptions;
begin
  Result.Accuracy := 0.01;
  Result.MinValue := 1e-9;
  Result.MaxValue := 1e9;
  Result.MaxAge := 600;
  Result.AgeSlots := 5;
end;

procedure PromCheckSketchOptions(const O: TPromSketchOptions);
begin
  // IsNan first: comparing a NaN raises EInvalidOp instead of returning False
  if IsNan(O.Accuracy) or IsNan(O.MinValue) or IsNan(O.MaxValue) or IsNan(O.MaxAge) or
     IsInfinite(O.MaxValue) or IsInfinite(O.MaxAge) then
    raise EArgumentException.Create('Summary options must be finite numbers');
  if not ((O.Accuracy > 0) and (O.Accuracy < 0.5)) then
    raise EArgumentException.Create('Summary accuracy must be in (0, 0.5)');
  if not ((O.MinValue > 0) and (O.MaxValue > O.MinValue)) then
    raise EArgumentException.Create('Summary range needs 0 < MinValue < MaxValue');
  if not (O.MaxAge > 0) then
    raise EArgumentException.Create('Summary MaxAge must be positive');
  if (O.AgeSlots < 1) or (O.AgeSlots > 120) then
    raise EArgumentException.Create('Summary AgeSlots must be between 1 and 120');
end;

{ Rounds to 6 significant digits via text, which is exact and platform independent. }
function RoundSignificant(V: Double): Double;
var
  S: string;
  FS: TFormatSettings;
begin
  if IsNan(V) or IsInfinite(V) or (V = 0) then
    Exit(V);
  Str(V:13, S);   // ' d.ddddddE+xxx': 6 significant digits
  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
  if not TryStrToFloat(Trim(S), Result, FS) then
    Result := V;
end;

{ TPromSketchSlot }

constructor TPromSketchSlot.Create(APageCount: Integer);
begin
  inherited Create;
  SetLength(FPages, APageCount);
end;

destructor TPromSketchSlot.Destroy;
var
  I: Integer;
begin
  for I := 0 to High(FPages) do
    if FPages[I] <> nil then
      FreeMem(FPages[I]);
  inherited Destroy;
end;

procedure TPromSketchSlot.Add(BucketIndex: Integer);
var
  Page, Fresh: PPromSketchPage;
  Slot: Integer;
begin
  Slot := BucketIndex shr PromSketchPageBits;
  Page := PPromSketchPage(FPages[Slot]);
  if Page = nil then
  begin
    GetMem(Fresh, SizeOf(TPromSketchPage));
    FillChar(Fresh^, SizeOf(TPromSketchPage), 0);
    Page := PPromSketchPage(AtomicCasPointer(FPages[Slot], Fresh, nil));
    if Page = nil then
      Page := Fresh                 // we published it
    else
      FreeMem(Fresh);               // somebody else won; ours was never visible
  end;
  AtomicAddInt64(Page^[BucketIndex and (PromSketchPageSize - 1)], 1);
end;

procedure TPromSketchSlot.Clear;
var
  I, J: Integer;
  Page: PPromSketchPage;
begin
  for I := 0 to High(FPages) do
  begin
    Page := PPromSketchPage(FPages[I]);
    if Page <> nil then
      for J := 0 to PromSketchPageSize - 1 do
        AtomicStoreInt64(Page^[J], 0);
  end;
end;

{ TPromSketch }

constructor TPromSketch.Create(const AOptions: TPromSketchOptions);
var
  I, Pages: Integer;
begin
  inherited Create;
  PromCheckSketchOptions(AOptions);
  FOpt := AOptions;
  FGamma := (1 + FOpt.Accuracy) / (1 - FOpt.Accuracy);
  FLnGamma := Ln(FGamma);
  FLnMin := Ln(FOpt.MinValue);
  FBuckets := Ceil((Ln(FOpt.MaxValue) - FLnMin) / FLnGamma) + 1;
  FSlotLen := FOpt.MaxAge / FOpt.AgeSlots;
  Pages := (FBuckets + PromSketchPageSize - 1) div PromSketchPageSize;
  SetLength(FSlots, FOpt.AgeSlots);
  for I := 0 to High(FSlots) do
    FSlots[I] := TPromSketchSlot.Create(Pages);
end;

destructor TPromSketch.Destroy;
var
  I: Integer;
begin
  for I := 0 to High(FSlots) do
    FSlots[I].Free;
  inherited Destroy;
end;

function TPromSketch.BucketOf(V: Double): Integer;
begin
  if not (V > FOpt.MinValue) then       // also zero and negative values
    Exit(0);
  if V >= FOpt.MaxValue then
    Exit(FBuckets - 1);
  Result := Ceil((Ln(V) - FLnMin) / FLnGamma);
  if Result < 0 then Result := 0;
  if Result > FBuckets - 1 then Result := FBuckets - 1;
end;

{ Representative value of bucket I = (U/g, U], U = MinValue*g^I, chosen so that the
  relative error is at most Accuracy for every value in the bucket. }
function TPromSketch.BucketValue(I: Integer): Double;
begin
  Result := 2 * FOpt.MinValue * Exp(I * FLnGamma) / (FGamma + 1);
end;

function TPromSketch.TickOf(Now: Double): Int64;
begin
  Result := Trunc(Now / FSlotLen) + 1;   // >= 1, so epoch 0 can mean "unused"
end;

procedure TPromSketch.ObserveAt(V, Now: Double);
var
  Tick, E: Int64;
  Slot: TPromSketchSlot;
begin
  if IsNan(V) then
    Exit;
  Tick := TickOf(Now);
  Slot := FSlots[Tick mod Length(FSlots)];
  E := AtomicLoadInt64(Slot.FEpoch);
  if E < Tick then
    if InterlockedCompareExchange64(Slot.FEpoch, Tick, E) = E then
      Slot.Clear;           // we advanced the epoch, so we reset the slot
  Slot.Add(BucketOf(V));
end;

procedure TPromSketch.Observe(V: Double);
begin
  ObserveAt(V, PromMonotonicSeconds);
end;

function TPromSketch.CountAt(Now: Double): Int64;
var
  Tick, E: Int64;
  I, J, K: Integer;
  Page: PPromSketchPage;
begin
  Result := 0;
  Tick := TickOf(Now);
  for I := 0 to High(FSlots) do
  begin
    E := AtomicLoadInt64(FSlots[I].FEpoch);
    if (E <= Tick - Length(FSlots)) or (E > Tick) then
      Continue;
    for J := 0 to High(FSlots[I].FPages) do
    begin
      Page := PPromSketchPage(FSlots[I].FPages[J]);
      if Page <> nil then
        for K := 0 to PromSketchPageSize - 1 do
          Result := Result + AtomicLoadInt64(Page^[K]);
    end;
  end;
end;

function TPromSketch.QuantilesAt(const Qs: array of Double; Now: Double): TPromDoubleArray;
var
  Merged: array of Int64;
  Tick, E, Total, Cum, C: Int64;
  I, J, K, B, Q: Integer;
  Page: PPromSketchPage;
  Rank: Double;
begin
  SetLength(Result, Length(Qs));
  SetLength(Merged, FBuckets);
  Total := 0;
  Tick := TickOf(Now);
  for I := 0 to High(FSlots) do
  begin
    E := AtomicLoadInt64(FSlots[I].FEpoch);
    if (E <= Tick - Length(FSlots)) or (E > Tick) then
      Continue;                         // outside the window
    for J := 0 to High(FSlots[I].FPages) do
    begin
      Page := PPromSketchPage(FSlots[I].FPages[J]);
      if Page = nil then
        Continue;
      for K := 0 to PromSketchPageSize - 1 do
      begin
        B := J * PromSketchPageSize + K;
        if B >= FBuckets then
          Break;
        C := AtomicLoadInt64(Page^[K]);
        if C > 0 then
        begin
          Merged[B] := Merged[B] + C;
          Total := Total + C;
        end;
      end;
    end;
  end;
  for Q := 0 to High(Qs) do
  begin
    if Total = 0 then
    begin
      Result[Q] := NaN;
      Continue;
    end;
    Rank := Qs[Q] * (Total - 1);
    Cum := 0;
    Result[Q] := BucketValue(FBuckets - 1);
    for B := 0 to FBuckets - 1 do
    begin
      Cum := Cum + Merged[B];
      if Cum > Rank then
      begin
        Result[Q] := RoundSignificant(BucketValue(B));
        Break;
      end;
    end;
  end;
end;

function TPromSketch.Quantiles(const Qs: array of Double): TPromDoubleArray;
begin
  Result := QuantilesAt(Qs, PromMonotonicSeconds);
end;

end.
