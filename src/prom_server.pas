{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit prom_server;
{ Optional stand-alone /metrics HTTP server on top of fphttpserver. It runs its own
  accept thread; the core units do not depend on this one. On Unix the host program
  needs cthreads first in its uses clause. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fphttpserver, httpdefs,
  prom_registry, prom_exposition, prom_http;

type
  TPromServer = class
  private
    FRegistry: TPromRegistry;
    FPath: string;
    FPort: Word;
    FServer: TFPHTTPServer;
    FThread: TThread;
    procedure HandleRequest(Sender: TObject;
      var ARequest: TFPHTTPConnectionRequest;
      var AResponse: TFPHTTPConnectionResponse);
    function GetActive: Boolean;
  public
    { Registry = nil uses DefaultRegistry (resolved per request). Port 0 is not supported. }
    constructor Create(APort: Word; ARegistry: TPromRegistry = nil;
      const APath: string = '/metrics');
    destructor Destroy; override;
    procedure Start;
    procedure Stop;
    property Active: Boolean read GetActive;
    property Port: Word read FPort;
    property Path: string read FPath;
  end;

implementation

type
  TServeThread = class(TThread)
  private
    FServer: TFPHTTPServer;
  protected
    procedure Execute; override;
  public
    constructor Create(AServer: TFPHTTPServer);
  end;

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
    // port in use etc.: the thread just ends; Active then reports False
  end;
end;

constructor TPromServer.Create(APort: Word; ARegistry: TPromRegistry;
  const APath: string);
begin
  inherited Create;
  FPort := APort;
  FRegistry := ARegistry;
  FPath := APath;
end;

destructor TPromServer.Destroy;
begin
  Stop;
  inherited Destroy;
end;

function TPromServer.GetActive: Boolean;
begin
  Result := (FServer <> nil) and FServer.Active;
end;

procedure TPromServer.HandleRequest(Sender: TObject;
  var ARequest: TFPHTTPConnectionRequest;
  var AResponse: TFPHTTPConnectionResponse);
var
  Body, CType: string;
  Code: Integer;
begin
  Code := 200;
  CType := PromContentType;
  if ARequest.URL <> FPath then
  begin
    Code := 404;
    CType := 'text/plain; charset=utf-8';
    Body := 'Not found. Try ' + FPath + #10;
  end
  else if (ARequest.Method <> 'GET') and (ARequest.Method <> 'HEAD') then
  begin
    Code := 405;
    AResponse.SetCustomHeader('Allow', 'GET, HEAD');
    CType := 'text/plain; charset=utf-8';
    Body := 'Method not allowed' + #10;
  end
  else
  begin
    try
      Body := MetricsBody(FRegistry);
    except
      on E: Exception do
      begin
        Code := 500;
        CType := 'text/plain; charset=utf-8';
        Body := 'Collect failed: ' + E.Message + #10;
      end;
    end;
  end;
  AResponse.Code := Code;
  AResponse.ContentType := CType;
  // ContentStream, not Content: Content is a TStrings and would rewrite #10 as
  // LineEnding (CRLF on Windows), which breaks the exposition format.
  AResponse.FreeContentStream := True;
  AResponse.ContentStream := TStringStream.Create(Body);
  AResponse.ContentLength := Length(Body);
  AResponse.SendContent;
end;

procedure TPromServer.Start;
begin
  if FServer <> nil then
    Exit;
  FServer := TFPHTTPServer.Create(nil);
  FServer.Port := FPort;
  FServer.Threaded := True;          // each connection on its own thread
  FServer.AcceptIdleTimeout := 200;  // lets the accept loop notice Stop
  FServer.OnRequest := @HandleRequest;
  FThread := TServeThread.Create(FServer);
  // wait until listening (or the thread died, e.g. port in use)
  while (not FServer.Active) and (not FThread.Finished) do
    Sleep(5);
  if not FServer.Active then
  begin
    Stop;
    raise Exception.CreateFmt('prom_server: cannot listen on port %d', [FPort]);
  end;
end;

procedure TPromServer.Stop;
begin
  if FServer = nil then
    Exit;
  FServer.Active := False;
  if FThread <> nil then
  begin
    FThread.WaitFor;
    FreeAndNil(FThread);
  end;
  FreeAndNil(FServer);
end;

end.
