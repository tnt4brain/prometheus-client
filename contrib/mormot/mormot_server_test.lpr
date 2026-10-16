{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
program mormot_server_test;
{ Mounts prometheus_fpc's /metrics on mORMot HTTP servers (THttpServer and THttpAsyncServer) via
  PromMountMetrics, scrapes them with mORMot's HTTP client and checks the result. Build with
  -dMORMOTMM to put mORMot's x64 memory manager first. Exit code 0 = every check passed. }
{$mode objfpc}{$H+}
uses
  {$ifdef MORMOTMM} mormot.core.fpcx64mm, {$endif}
  {$ifdef UNIX} cthreads, {$endif}
  SysUtils, Classes, mormot.core.base, mormot.core.os, mormot.core.text, mormot.net.server,
  mormot.net.async, mormot.net.client, mormot.net.sock, prom_registry, prom_metrics, prom_collectors,
  prom_mormot, prom_mormot_http{$ifdef MORMOTMM}, prom_mormot_mm{$endif};

type
  TStress = class(TThread)
    Cnt: TPromCounter;
    procedure Execute; override;
  end;

procedure TStress.Execute;
var
  I: Integer;
begin
  for I := 1 to 200000 do
    Cnt.Inc;
end;

const
  LabelBytes: array[0..4] of Byte = ($C3, $A9, $E2, $98, $83);  // e-acute, snowman
  HelpBytes: array[0..4] of Byte = ($C3, $AF, $E2, $98, $83);   // i-diaeresis, snowman

var
  Reg: TPromRegistry;
  Fails: Integer = 0;

procedure Check(OK: Boolean; const What: string);
begin
  if OK then
    WriteLn('ok    ', What)
  else
  begin
    WriteLn('FAIL  ', What);
    Inc(Fails);
  end;
end;

{ One request with exactly one Accept header (mORMot's HTTP client always adds its own). }
function RawGet(const Port, Accept: string): RawByteString;
var
  S: TCrtSocket;
  Part: RawByteString;
  HdrEnd, CL: Integer;
begin
  Result := '';
  S := TCrtSocket.Open('127.0.0.1', RawUtf8(Port));
  try
    S.SockSend(RawByteString('GET /metrics HTTP/1.1'#13#10'Host: 127.0.0.1'#13#10'Connection: close'#13#10'Accept: ' + Accept + #13#10#13#10));
    S.SockSendFlush('');
    repeat
      Part := S.SockReceiveString;
      Result := Result + Part;
      // the server may keep the connection open: stop once Content-Length bytes arrived
      HdrEnd := Pos(#13#10#13#10, string(Result));
      if HdrEnd > 0 then
      begin
        CL := Pos('Content-Length:', string(Result));
        if CL > 0 then
          CL := StrToIntDef(Trim(Copy(string(Result), CL + 15, Pos(#13, Copy(string(Result), CL, 40)) - 16)), -1)
        else
          CL := -1;
        if (CL >= 0) and (Length(Result) - (HdrEnd + 3) >= CL) then
          Break;
      end;
    until Part = '';
  finally
    S.Free;
  end;
end;

procedure RunAgainst(Srv: THttpServerGeneric; const Port, Name: string; Stress: TPromCounter);
var
  Body: RawByteString;
  Status, K: Integer;
  Hdr, URL, Label_, Help: RawUtf8;
  T: array[0..3] of TStress;
begin
  WriteLn('--- ', Name);
  PromMountMetrics(Srv, Reg);
  URL := RawUtf8('http://127.0.0.1:' + Port + '/metrics');
  FastSetString(Label_, @LabelBytes, SizeOf(LabelBytes));
  FastSetString(Help, @HelpBytes, SizeOf(HelpBytes));
  Body := HttpGet(URL, @Hdr, false, @Status);
  Check(Status = 200, 'GET /metrics -> 200 (got ' + IntToStr(Status) + ')');
  Check(Pos('text/plain; version=0.0.4', string(Hdr)) > 0, 'Content-Type is the text format');
  Check(Pos('process_resident_memory_bytes', string(Body)) > 0, 'process metrics present');
  Check(Pos({$ifdef MORMOTMM}'mormot_heap_sleep_total'{$else}'fpc_heap_used_bytes'{$endif},
    string(Body)) > 0, 'heap metrics present');
  Check(Pos(Label_, Body) > 0, 'UTF-8 label bytes intact on the wire');
  Check(Pos(Help, Body) > 0, 'UTF-8 HELP bytes intact on the wire');
  Body := RawGet(Port, 'application/openmetrics-text; version=1.0.0');
  Check(Pos('Content-Type: application/openmetrics-text', string(Body)) > 0, 'Accept negotiates OpenMetrics');
  Check(Pos('# EOF', string(Body)) > 0, 'OpenMetrics body ends with # EOF');
  Body := RawGet(Port, 'text/plain');
  Check(Pos('Content-Type: text/plain; version=0.0.4', string(Body)) > 0, 'Accept text/plain gets the text format');
  HttpGet(RawUtf8('http://127.0.0.1:' + Port + '/nope'), @Hdr, false, @Status);
  Check(Status = 404, 'other paths still 404 (got ' + IntToStr(Status) + ')');
  // 4 writer threads against repeated scrapes
  for K := 0 to 3 do
  begin
    T[K] := TStress.Create(True);
    T[K].Cnt := Stress;
    T[K].Start;
  end;
  for K := 1 to 20 do
    HttpGet(URL);
  for K := 0 to 3 do
  begin
    T[K].WaitFor;
    T[K].Free;
  end;
  Body := HttpGet(URL);
  Check(Pos('stress_total ', string(Body)) > 0, 'stress counter exposed');
end;

var
  Srv: THttpServerGeneric;
  Help, Lbl: RawUtf8;
  C, Stress: TPromCounter;
  Body: RawByteString;
begin
  Reg := TPromRegistry.Create;
  RegisterProcessMetrics(Reg);
  {$ifdef MORMOTMM} PromRegisterMormotHeapMetrics(Reg); {$else} RegisterHeapMetrics(Reg); {$endif}
  FastSetString(Help, @HelpBytes, SizeOf(HelpBytes));
  FastSetString(Lbl, @LabelBytes, SizeOf(LabelBytes));
  C := Reg.Counter('app_requests_total', string(Help), ['who']);
  C.Labels([string(Lbl)]).Inc;
  Stress := Reg.Counter('stress_total', 'Stress.');
  try
    Srv := THttpServer.Create('18765', nil, nil, 'prom', 4);
    try
      THttpServer(Srv).WaitStarted;
      RunAgainst(Srv, '18765', 'THttpServer', Stress);
    finally
      Srv.Free;
    end;
    Srv := THttpAsyncServer.Create('18766', nil, nil, 'prom', 2, 30000, []);
    try
      THttpAsyncServer(Srv).WaitStarted;
      RunAgainst(Srv, '18766', 'THttpAsyncServer', Stress);
    finally
      Srv.Free;
    end;
    // both runs incremented the same counter: 2 x 4 x 200000
    Body := '';
    Check(Stress.Value = 1600000, 'stress counter exact: ' + FloatToStr(Stress.Value));
  finally
    Reg.Free;
  end;
  if Fails > 0 then
    Halt(1);
  WriteLn('ALL OK');
end.
