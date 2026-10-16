{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
program mormot_bridge_test;
{ Smoke test for prom_mormot: expects mORMot 2 sources on the unit path. Exit code 0 = pass. }
{$mode objfpc}{$H+}
uses
  {$ifdef UNIX} cthreads, {$endif}
  SysUtils, mormot.core.base, mormot.core.perf, prom_registry, prom_http, prom_mormot;

var
  R: TPromRegistry;
  M: TSynMonitorServer;
  Body: string;
  Fails: Integer = 0;

procedure Expect(const Needle: string);
begin
  if Pos(Needle, Body) = 0 then
  begin
    WriteLn('MISSING: ', Needle);
    Inc(Fails);
  end;
end;

begin
  R := TPromRegistry.Create;
  M := TSynMonitorServer.Create;
  try
    M.ProcessStartTask;
    Sleep(25);
    M.ProcessEnd;
    M.Input.Bytes := 1500;
    M.Output.Bytes := 48210;
    M.ProcessErrorNumber(404);
    WriteLn('registered: ', PromRegisterSynMonitor(R, M, 'mormot_http'));
    Body := MetricsBody(R);
    Write(Body);
    Expect('# TYPE mormot_http_task_count_total counter');
    Expect('mormot_http_task_count_total 1');
    Expect('# TYPE mormot_http_total_time_seconds_total counter');
    Expect('# TYPE mormot_http_clients_current gauge');
    Expect('mormot_http_input_bytes_total 1500');
    if Fails > 0 then Halt(1);
    WriteLn('OK');
  finally
    M.Free;
    R.Free;
  end;
end.
