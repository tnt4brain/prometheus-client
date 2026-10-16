{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit test_push;
{ prom_push against a fake Pushgateway (fphttpserver on localhost). }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry, fphttpserver, httpdefs, prom_registry,
  prom_metrics, prom_push;

type
  TServeThread = class(TThread)
  private
    FServer: TFPHTTPServer;
  protected
    procedure Execute; override;
  public
    constructor Create(AServer: TFPHTTPServer);
  end;

  TTestPush = class(TTestCase)
  private
    FServer: TFPHTTPServer;
    FThread: TServeThread;
    FReply: Integer;
    FMethod, FURL, FContentType, FAuth, FBody: string;
    procedure Handle(Sender: TObject; var ARequest: TFPHTTPConnectionRequest;
      var AResponse: TFPHTTPConnectionResponse);
    function Base: string;
    procedure CheckRejected(const Msg, AJob: string; const ALabels: array of string);
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestPathParts;
    procedure TestPushIsPut;
    procedure TestPushAddIsPost;
    procedure TestDelete;
    procedure TestGroupingLabelsInPath;
    procedure TestBasicAuth;
    procedure TestErrorStatus;
    procedure TestConnectionRefused;
    procedure TestBadArguments;
    procedure TestSchemeAndSlashNormalised;
  end;

implementation

const
  Port = 18791;

constructor TServeThread.Create(AServer: TFPHTTPServer);
begin
  FServer := AServer;
  inherited Create(False);
end;

procedure TServeThread.Execute;
begin
  try
    FServer.Active := True;   // blocks until Active := False
  except
  end;
end;

procedure TTestPush.SetUp;
var
  I: Integer;
begin
  FReply := 200;
  FMethod := '';
  FURL := '';
  FBody := '';
  FServer := TFPHTTPServer.Create(nil);
  FServer.Port := Port;
  FServer.Threaded := True;
  FServer.AcceptIdleTimeout := 200;   // lets the accept loop notice shutdown
  FServer.OnRequest := @Handle;
  FThread := TServeThread.Create(FServer);
  for I := 1 to 100 do
  begin
    if FServer.Active then
      Break;
    Sleep(20);
  end;
  AssertTrue('fake gateway up', FServer.Active);
end;

procedure TTestPush.TearDown;
begin
  FServer.Active := False;
  FThread.WaitFor;
  FThread.Free;
  FServer.Free;
end;

function TTestPush.Base: string;
begin
  Result := 'http://127.0.0.1:' + IntToStr(Port);
end;

procedure TTestPush.Handle(Sender: TObject; var ARequest: TFPHTTPConnectionRequest;
  var AResponse: TFPHTTPConnectionResponse);
begin
  FMethod := ARequest.Method;
  FURL := ARequest.URL;
  FContentType := ARequest.ContentType;
  FAuth := ARequest.Authorization;
  FBody := ARequest.Content;
  AResponse.Code := FReply;
  AResponse.ContentLength := 0;
  AResponse.SendContent;
end;

procedure TTestPush.TestPathParts;
begin
  AssertEquals('job/batch', PromPushPathPart('job', 'batch'));
  AssertEquals('a/x%20y', PromPushPathPart('a', 'x y'));
  AssertEquals('a/%C3%A9', PromPushPathPart('a', #$C3#$A9));          // UTF-8 e-acute
  AssertEquals('a@base64/YS9i', PromPushPathPart('a', 'a/b'));        // value with a slash
  AssertEquals('a@base64/=', PromPushPathPart('a', ''));              // empty value
end;

procedure TTestPush.TestPushIsPut;
var
  R: TPromRegistry;
begin
  R := TPromRegistry.Create;
  try
    R.Counter('jobs_done_total', 'Jobs.').Inc(3);
    PromPush(Base, 'nightly', R, []);
    AssertEquals('PUT', FMethod);
    AssertEquals('/metrics/job/nightly', FURL);
    AssertTrue('text format', Pos('version=0.0.4', FContentType) > 0);
    AssertTrue('counter in body', Pos('jobs_done_total 3', FBody) > 0);
    AssertTrue('no OpenMetrics terminator', Pos('# EOF', FBody) = 0);
  finally
    R.Free;
  end;
end;

procedure TTestPush.TestPushAddIsPost;
var
  R: TPromRegistry;
begin
  R := TPromRegistry.Create;
  try
    R.Gauge('last_success', 'Time.').SetValue(1);
    FReply := 202;                       // the gateway may answer 202 too
    PromPushAdd(Base, 'nightly', R, []);
    AssertEquals('POST', FMethod);
    AssertTrue(Pos('last_success 1', FBody) > 0);
  finally
    R.Free;
  end;
end;

procedure TTestPush.TestDelete;
begin
  PromPushDelete(Base, 'nightly', ['instance', 'h1']);
  AssertEquals('DELETE', FMethod);
  AssertEquals('/metrics/job/nightly/instance/h1', FURL);
  AssertEquals('', FBody);
end;

procedure TTestPush.TestGroupingLabelsInPath;
var
  R: TPromRegistry;
begin
  R := TPromRegistry.Create;
  try
    PromPush(Base, 'j/1', R, ['instance', 'host 1', 'env', '']);
    AssertEquals('/metrics/job@base64/ai8x/instance/host%201/env@base64/=', FURL);
  finally
    R.Free;
  end;
end;

procedure TTestPush.TestBasicAuth;
var
  P: TPromPusher;
  R: TPromRegistry;
begin
  R := TPromRegistry.Create;
  P := TPromPusher.Create(Base, 'j', R, []);
  try
    P.UserName := 'user';
    P.Password := 'secret';
    P.Push;
    AssertEquals('Basic dXNlcjpzZWNyZXQ=', FAuth);
  finally
    P.Free;
    R.Free;
  end;
end;

procedure TTestPush.TestErrorStatus;
var
  R: TPromRegistry;
  Raised: Boolean;
begin
  R := TPromRegistry.Create;
  try
    FReply := 400;
    Raised := False;
    try
      PromPush(Base, 'j', R, []);
    except
      on E: EPromPush do
      begin
        Raised := True;
        AssertEquals(400, E.Status);
      end;
    end;
    AssertTrue('EPromPush raised', Raised);
  finally
    R.Free;
  end;
end;

procedure TTestPush.TestConnectionRefused;
var
  R: TPromRegistry;
  P: TPromPusher;
  Raised: Boolean;
begin
  R := TPromRegistry.Create;
  P := TPromPusher.Create('http://127.0.0.1:18792', 'j', R, []);   // nothing listens here
  try
    P.TimeoutMs := 2000;
    Raised := False;
    try
      P.Push;
    except
      on E: EPromPush do
      begin
        Raised := True;
        AssertEquals(0, E.Status);
      end;
    end;
    AssertTrue('EPromPush raised', Raised);
  finally
    P.Free;
    R.Free;
  end;
end;

procedure TTestPush.CheckRejected(const Msg, AJob: string; const ALabels: array of string);
var
  Raised: Boolean;
  P: TPromPusher;
begin
  Raised := False;
  try
    P := TPromPusher.Create(Base, AJob, nil, ALabels);
    P.Free;
  except
    on EArgumentException do
      Raised := True;
  end;
  AssertTrue(Msg, Raised);
end;

procedure TTestPush.TestBadArguments;
begin
  CheckRejected('empty job', '', []);
  CheckRejected('odd label list', 'j', ['odd']);
  CheckRejected('job as grouping label', 'j', ['job', 'x']);
  CheckRejected('invalid label name', 'j', ['bad-name', 'x']);
end;

procedure TTestPush.TestSchemeAndSlashNormalised;
var
  R: TPromRegistry;
begin
  R := TPromRegistry.Create;
  try
    PromPush('127.0.0.1:' + IntToStr(Port) + '/', 'j', R, []);   // no scheme, trailing slash
    AssertEquals('/metrics/job/j', FURL);
  finally
    R.Free;
  end;
end;

initialization
  RegisterTest(TTestPush);

end.
