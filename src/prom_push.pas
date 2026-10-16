{ Copyright (c) 2026, Sergei Pechenko. BSD 3-Clause License; see the LICENSE file. }
unit prom_push;
{ Pushgateway client, for short-lived programs (batch jobs, cron tasks) that exit before
  Prometheus can scrape them. Optional unit on top of fphttpclient; the core units do not
  depend on it. https:// URLs need an SSL library: add opensslsockets to the program's uses.

  Semantics follow the official clients:
    Push    PUT    replaces ALL metrics of the group (same job + grouping labels)
    PushAdd POST   replaces only the metrics with the same names in the group
    Delete  DELETE removes the whole group
  The text format 0.0.4 is sent (the Pushgateway does not take OpenMetrics). }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, prom_registry;

type
  EPromPush = class(Exception)
  private
    FStatus: Integer;
  public
    constructor CreateStatus(AStatus: Integer; const Msg: string);
    { HTTP status of the failed request, 0 when none was received. }
    property Status: Integer read FStatus;
  end;

  TPromPusher = class
  private
    FURL, FJob, FUserName, FPassword: string;
    FRegistry: TPromRegistry;
    FLabels: array of string;   // name, value, name, value, ...
    FTimeoutMs: Integer;
    function GroupURL: string;
    procedure Send(const Method: string; const Body: string);
  public
    { URL is the Pushgateway base, e.g. 'http://localhost:9091' (http:// is assumed when no
      scheme is given). Registry = nil uses DefaultRegistry. GroupingLabels (pass [] for none) are name, value
      pairs such as ['instance', 'host1']; 'job' is not allowed there. }
    constructor Create(const AURL, AJob: string; ARegistry: TPromRegistry;
      const AGroupingLabels: array of string);
    procedure Push;
    procedure PushAdd;
    procedure Delete;
    { Optional HTTP basic authentication. }
    property UserName: string read FUserName write FUserName;
    property Password: string read FPassword write FPassword;
    { Connect and I/O timeout in milliseconds, default 10000. }
    property TimeoutMs: Integer read FTimeoutMs write FTimeoutMs;
  end;

{ One-shot helpers. }
procedure PromPush(const URL, Job: string; Registry: TPromRegistry;
  const GroupingLabels: array of string);
procedure PromPushAdd(const URL, Job: string; Registry: TPromRegistry;
  const GroupingLabels: array of string);
procedure PromPushDelete(const URL, Job: string; const GroupingLabels: array of string);

{ Path component for one label, as the Pushgateway expects: percent-encoded value, or
  name@base64 + unpadded base64url value when it is empty or contains '/'. Exposed for tests. }
function PromPushPathPart(const LabelName, LabelValue: string): string;

implementation

uses
  base64, fphttpclient, prom_exposition, prom_http;

constructor EPromPush.CreateStatus(AStatus: Integer; const Msg: string);
begin
  inherited Create(Msg);
  FStatus := AStatus;
end;

function PercentEncode(const S: string): string;
var
  I: Integer;
begin
  Result := '';
  for I := 1 to Length(S) do
    if S[I] in ['A'..'Z', 'a'..'z', '0'..'9', '-', '.', '_', '~'] then
      Result := Result + S[I]
    else
      Result := Result + '%' + IntToHex(Ord(S[I]), 2);
end;

function Base64Url(const S: string): string;
begin
  Result := StringReplace(StringReplace(EncodeStringBase64(S), '+', '-', [rfReplaceAll]),
    '/', '_', [rfReplaceAll]);
  while (Result <> '') and (Result[Length(Result)] = '=') do
    SetLength(Result, Length(Result) - 1);
end;

function PromPushPathPart(const LabelName, LabelValue: string): string;
begin
  if (LabelValue = '') or (Pos('/', LabelValue) > 0) then
    // an empty value is the single base64 character "="
    if LabelValue = '' then
      Result := LabelName + '@base64/='
    else
      Result := LabelName + '@base64/' + Base64Url(LabelValue)
  else
    Result := LabelName + '/' + PercentEncode(LabelValue);
end;

constructor TPromPusher.Create(const AURL, AJob: string; ARegistry: TPromRegistry;
  const AGroupingLabels: array of string);
var
  I: Integer;
begin
  inherited Create;
  if AJob = '' then
    raise EArgumentException.Create('Pushgateway job name must not be empty');
  if Odd(Length(AGroupingLabels)) then
    raise EArgumentException.Create('Grouping labels must be name, value pairs');
  for I := 0 to Length(AGroupingLabels) div 2 - 1 do
    if (AGroupingLabels[2 * I] = 'job') or not PromValidLabelName(AGroupingLabels[2 * I]) then
      raise EArgumentException.CreateFmt('Invalid grouping label name "%s"',
        [AGroupingLabels[2 * I]]);
  FURL := AURL;
  if Pos('://', FURL) = 0 then
    FURL := 'http://' + FURL;
  while (FURL <> '') and (FURL[Length(FURL)] = '/') do
    SetLength(FURL, Length(FURL) - 1);
  FJob := AJob;
  FRegistry := ARegistry;
  SetLength(FLabels, Length(AGroupingLabels));
  for I := 0 to High(AGroupingLabels) do
    FLabels[I] := AGroupingLabels[I];
  FTimeoutMs := 10000;
end;

function TPromPusher.GroupURL: string;
var
  I: Integer;
begin
  Result := FURL + '/metrics/' + PromPushPathPart('job', FJob);
  for I := 0 to Length(FLabels) div 2 - 1 do
    Result := Result + '/' + PromPushPathPart(FLabels[2 * I], FLabels[2 * I + 1]);
end;

procedure TPromPusher.Send(const Method: string; const Body: string);
var
  Client: TFPHTTPClient;
  Req: TMemoryStream;
  Resp: TStringStream;
begin
  Client := TFPHTTPClient.Create(nil);
  Resp := TStringStream.Create('');
  Req := nil;
  try
    Client.ConnectTimeout := FTimeoutMs;
    Client.IOTimeout := FTimeoutMs;
    Client.UserName := FUserName;
    Client.Password := FPassword;
    if Body <> '' then
    begin
      Req := TMemoryStream.Create;
      Req.WriteBuffer(Pointer(Body)^, Length(Body));  // exact bytes, no code page conversion
      Req.Position := 0;
      Client.RequestBody := Req;
      Client.AddHeader('Content-Type', PromContentType);
    end;
    try
      Client.HTTPMethod(Method, GroupURL, Resp, [200, 202]);
    except
      on E: EHTTPClient do
        raise EPromPush.CreateStatus(Client.ResponseStatusCode,
          Format('Pushgateway %s %s failed: %s', [Method, GroupURL, E.Message]));
      on E: Exception do
        raise EPromPush.CreateStatus(0,
          Format('Pushgateway %s %s failed: %s', [Method, GroupURL, E.Message]));
    end;
  finally
    Req.Free;
    Resp.Free;
    Client.Free;
  end;
end;

procedure TPromPusher.Push;
begin
  Send('PUT', MetricsBody(FRegistry, pfText));
end;

procedure TPromPusher.PushAdd;
begin
  Send('POST', MetricsBody(FRegistry, pfText));
end;

procedure TPromPusher.Delete;
begin
  Send('DELETE', '');
end;

procedure PromPush(const URL, Job: string; Registry: TPromRegistry;
  const GroupingLabels: array of string);
var
  P: TPromPusher;
begin
  P := TPromPusher.Create(URL, Job, Registry, GroupingLabels);
  try
    P.Push;
  finally
    P.Free;
  end;
end;

procedure PromPushAdd(const URL, Job: string; Registry: TPromRegistry;
  const GroupingLabels: array of string);
var
  P: TPromPusher;
begin
  P := TPromPusher.Create(URL, Job, Registry, GroupingLabels);
  try
    P.PushAdd;
  finally
    P.Free;
  end;
end;

procedure PromPushDelete(const URL, Job: string; const GroupingLabels: array of string);
var
  P: TPromPusher;
begin
  P := TPromPusher.Create(URL, Job, nil, GroupingLabels);
  try
    P.Delete;
  finally
    P.Free;
  end;
end;

end.
