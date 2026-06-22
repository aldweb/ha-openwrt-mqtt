program WindowsMetrics;

{$mode objfpc}{$H+}

// ============================================================
// WindowsMetrics - Publishes system metrics to Home Assistant
// via MQTT REST API. Compatible Windows 7+, i386 and x86_64.
// Configuration: WindowsMetrics.ini (same directory as .exe)
// Usage:
//   WindowsMetrics.exe              Collect and publish metrics
//   WindowsMetrics.exe --install    Create scheduled task
//   WindowsMetrics.exe --uninstall  Remove scheduled task
// ============================================================

uses
  SysUtils, Classes, Windows, WinSock;

// ---------- Toolhelp32 (not always exposed by FPC Windows unit) ----------

const
  TH32CS_SNAPPROCESS = $00000002;

type
  TProcessEntry32 = record
    dwSize              : DWORD;
    cntUsage            : DWORD;
    th32ProcessID       : DWORD;
    th32DefaultHeapID   : ULONG_PTR;
    th32ModuleID        : DWORD;
    cntThreads          : DWORD;
    th32ParentProcessID : DWORD;
    pcPriClassBase      : LONG;
    dwFlags             : DWORD;
    szExeFile           : array[0..MAX_PATH - 1] of Char;
  end;

function CreateToolhelp32Snapshot(dwFlags, th32ProcessID: DWORD): THandle;
  stdcall; external 'kernel32' name 'CreateToolhelp32Snapshot';
function Process32First(hSnapshot: THandle; var lppe: TProcessEntry32): BOOL;
  stdcall; external 'kernel32' name 'Process32First';
function Process32Next(hSnapshot: THandle; var lppe: TProcessEntry32): BOOL;
  stdcall; external 'kernel32' name 'Process32Next';

// ---------- Constants ----------

const
  CRLF         = #13#10;
  CONFIG_FILE  = 'WindowsMetrics.ini';
  TASK_NAME    = 'PublishWindowsMetrics';
  FIONBIO_CMD  = DWORD($8004667E); // non-blocking mode flag

// Redeclare ioctlsocket with DWORD cmd to avoid signed/unsigned range warning
function ioctlsocket_nb(s: TSocket; cmd: DWORD; var argp: u_long): Integer;
  stdcall; external 'ws2_32' name 'ioctlsocket';

// ---------- Configuration (loaded from .ini) ----------

var
  MQTT_URL          : string;
  MQTT_PORT         : string;
  HA_TOKEN          : string;
  MQTT_TOPIC_PREFIX : string;
  SCHEDULE_INTERVAL : Integer;
  IsInteractive     : Boolean;

// ---------- System info record ----------

type
  TSystemInfo = record
    Hostname       : string;
    Model          : string;
    TargetPlatform : string;
    Version        : string;
    Architecture   : string;
    UptimeSeconds  : Int64;
  end;

// ============================================================
// Detect whether launched interactively or by Task Scheduler
// by inspecting the parent process name.
// Defaults to True (interactive) if detection fails.
// ============================================================
function DetectInteractive: Boolean;
var
  Snapshot   : THandle;
  Entry      : TProcessEntry32;
  CurrentPID : DWORD;
  ParentPID  : DWORD;
  ParentName : string;
begin
  Result    := True; // safe default
  ParentPID := 0;
  CurrentPID := GetCurrentProcessId;

  Snapshot := CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  if Snapshot = THandle(INVALID_HANDLE_VALUE) then Exit;

  try
    FillChar(Entry, SizeOf(Entry), 0);
    Entry.dwSize := SizeOf(TProcessEntry32);

    // Pass 1: find our own entry to get the parent PID
    if Process32First(Snapshot, Entry) then
      repeat
        if Entry.th32ProcessID = CurrentPID then
        begin
          ParentPID := Entry.th32ParentProcessID;
          Break;
        end;
      until not Process32Next(Snapshot, Entry);

    if ParentPID = 0 then Exit;

    // Pass 2: resolve parent PID to a process name
    FillChar(Entry, SizeOf(Entry), 0);
    Entry.dwSize := SizeOf(TProcessEntry32);

    if Process32First(Snapshot, Entry) then
      repeat
        if Entry.th32ProcessID = ParentPID then
        begin
          ParentName := LowerCase(Entry.szExeFile);
          Result := not (
            (ParentName = 'taskeng.exe')   or  // Win 7 scheduler
            (ParentName = 'taskhost.exe')  or  // Win 8 scheduler
            (ParentName = 'taskhostw.exe') or  // Win 10/11 scheduler
            (ParentName = 'svchost.exe')        // service host
          );
          Break;
        end;
      until not Process32Next(Snapshot, Entry);
  finally
    CloseHandle(Snapshot);
  end;
end;

// Write to console only when running interactively.
procedure Log(const Msg: string);
begin
  if IsInteractive then WriteLn(Msg);
end;

// ============================================================
// Load configuration from WindowsMetrics.ini.
// Returns False if file is missing or HA_TOKEN is empty.
// ============================================================
function LoadConfiguration: Boolean;
var
  ConfigPath       : string;
  F                : TextFile;
  Line, Key, Value : string;
  P                : Integer;
begin
  Result := False;

  // Defaults
  MQTT_URL          := 'http://localhost';
  MQTT_PORT         := '8123';
  HA_TOKEN          := '';
  MQTT_TOPIC_PREFIX := 'windows';
  SCHEDULE_INTERVAL := 5;

  ConfigPath := ExtractFilePath(ParamStr(0)) + CONFIG_FILE;

  if not FileExists(ConfigPath) then
  begin
    Log('ERROR: Configuration file not found: ' + ConfigPath);
    Log('');
    Log('Please create a WindowsMetrics.ini file with:');
    Log('  MQTT_URL=http://your_homeassistant_ip');
    Log('  MQTT_PORT=8123');
    Log('  HA_TOKEN=your_long_lived_access_token');
    Log('  MQTT_TOPIC_PREFIX=windows');
    Log('  SCHEDULE_INTERVAL=5');
    Exit;
  end;

  try
    AssignFile(F, ConfigPath);
    Reset(F);
    while not Eof(F) do
    begin
      ReadLn(F, Line);
      Line := Trim(Line);

      // Skip blank lines and comments
      if (Line = '') or (Line[1] = '#') or (Line[1] = ';') then Continue;

      P := Pos('=', Line);
      if P = 0 then Continue;

      Key   := UpperCase(Trim(Copy(Line, 1, P - 1)));
      Value := Trim(Copy(Line, P + 1, Length(Line)));

      // Strip optional surrounding quotes
      if (Length(Value) >= 2) and (Value[1] = '"') and
         (Value[Length(Value)] = '"') then
        Value := Copy(Value, 2, Length(Value) - 2);

      if      Key = 'MQTT_URL'          then MQTT_URL          := Value
      else if Key = 'MQTT_PORT'         then MQTT_PORT         := Value
      else if Key = 'HA_TOKEN'          then HA_TOKEN          := Value
      else if Key = 'MQTT_TOPIC_PREFIX' then MQTT_TOPIC_PREFIX := Value
      else if Key = 'SCHEDULE_INTERVAL' then SCHEDULE_INTERVAL := StrToIntDef(Value, 5);
    end;
    CloseFile(F);
  except
    on E: Exception do
    begin
      Log('ERROR: Cannot read ' + CONFIG_FILE + ': ' + E.Message);
      Exit;
    end;
  end;

  if HA_TOKEN = '' then
  begin
    Log('ERROR: HA_TOKEN is not set in ' + CONFIG_FILE);
    Exit;
  end;

  Result := True;
end;

// ============================================================
// Execute a shell command and return its stdout as a string.
// ============================================================
function RunCommand(const Cmd: string): string;
var
  SA        : TSecurityAttributes;
  ReadPipe  : THandle;
  WritePipe : THandle;
  SI        : TStartupInfo;
  PI        : TProcessInformation;
  Buffer    : array[0..4095] of Char;
  BytesRead : DWORD;
  Output    : string;
begin
  Result    := '';
  Output    := '';
  ReadPipe  := 0;
  WritePipe := 0;
  BytesRead := 0;
  FillChar(Buffer, SizeOf(Buffer), 0);
  FillChar(SI, SizeOf(SI), 0);
  FillChar(PI, SizeOf(PI), 0);

  SA.nLength              := SizeOf(TSecurityAttributes);
  SA.bInheritHandle       := True;
  SA.lpSecurityDescriptor := nil;

  if not CreatePipe(ReadPipe, WritePipe, @SA, 0) then Exit;

  try
    SI.cb          := SizeOf(TStartupInfo);
    SI.dwFlags     := STARTF_USESHOWWINDOW or STARTF_USESTDHANDLES;
    SI.wShowWindow := SW_HIDE;
    SI.hStdOutput  := WritePipe;
    SI.hStdError   := WritePipe;

    if CreateProcess(nil, PChar('cmd.exe /c ' + Cmd), nil, nil,
                     True, 0, nil, nil, SI, PI) then
    begin
      try
        CloseHandle(WritePipe);
        WritePipe := 0;
        while ReadFile(ReadPipe, Buffer, SizeOf(Buffer) - 1,
                       BytesRead, nil) and (BytesRead > 0) do
        begin
          Buffer[BytesRead] := #0;
          Output := Output + Buffer;
        end;
        WaitForSingleObject(PI.hProcess, INFINITE);
        Result := Trim(Output);
      finally
        CloseHandle(PI.hProcess);
        CloseHandle(PI.hThread);
      end;
    end;
  finally
    if WritePipe <> 0 then CloseHandle(WritePipe);
    CloseHandle(ReadPipe);
  end;
end;

// ============================================================
// Parse the first non-empty value from WMIC /value output.
// WMIC returns lines in the form "PropertyName=Value".
// ============================================================
function ExtractWMICValue(const Output: string): string;
var
  Lines : TStringList;
  I, P  : Integer;
  Value : string;
begin
  Result := '';
  Lines  := TStringList.Create;
  try
    Lines.Text := Output;
    for I := 0 to Lines.Count - 1 do
    begin
      P := Pos('=', Lines[I]);
      if P > 0 then
      begin
        Value := Trim(Copy(Lines[I], P + 1, Length(Lines[I])));
        if Value <> '' then
        begin
          Result := Value;
          Exit;
        end;
      end;
    end;
  finally
    Lines.Free;
  end;
end;

// ============================================================
// HTTP POST over raw WinSock. No external dependencies.
// Returns True on HTTP 2xx response.
// Connect timeout: 5 seconds (avoids long freeze on wrong host).
// ============================================================
function HTTPPost(const URL, AuthToken, JSONData: string): Boolean;
const
  CONNECT_TIMEOUT_SEC = 5;
var
  Sock          : TSocket;
  Host, Path    : string;
  Port          : Word;
  Addr          : TSockAddrIn;
  HostEnt       : PHostEnt;
  Request       : string;
  Buffer        : array[0..4095] of Char;
  P             : Integer;
  BytesSent     : Integer;
  BytesReceived : Integer;
  Mode          : u_long;
  TV            : TTimeVal;
  WriteSet      : TFDSet;
  ErrOpt        : Integer;
  ErrLen        : Integer;
begin
  Result        := False;
  BytesSent     := 0;
  BytesReceived := 0;
  FillChar(Addr,   SizeOf(Addr),   0);
  FillChar(Buffer, SizeOf(Buffer), 0);

  if Pos('http://', URL) <> 1 then Exit;

  // Parse host and path
  Host := Copy(URL, 8, Length(URL));
  P    := Pos('/', Host);
  if P > 0 then
  begin
    Path := Copy(Host, P, Length(Host));
    Host := Copy(Host, 1, P - 1);
  end
  else
    Path := '/';

  // Extract port if embedded (host:port)
  P := Pos(':', Host);
  if P > 0 then
  begin
    Port := StrToIntDef(Copy(Host, P + 1, Length(Host)), 8123);
    Host := Copy(Host, 1, P - 1);
  end
  else
    Port := 8123;

  Sock := socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
  if Sock = INVALID_SOCKET then Exit;

  try
    HostEnt := gethostbyname(PChar(Host));
    if HostEnt = nil then Exit;

    Addr.sin_family      := AF_INET;
    Addr.sin_port        := htons(Port);
    Addr.sin_addr.S_addr := PInAddr(HostEnt^.h_addr_list^)^.S_addr;

    // Switch to non-blocking mode for connect timeout
    Mode := 1;
    ioctlsocket_nb(Sock, FIONBIO_CMD, Mode);

    connect(Sock, Addr, SizeOf(Addr)); // returns WSAEWOULDBLOCK immediately

    // Wait up to CONNECT_TIMEOUT_SEC for the connection to complete
    FD_ZERO(WriteSet);
    FD_SET(Sock, WriteSet);
    TV.tv_sec  := CONNECT_TIMEOUT_SEC;
    TV.tv_usec := 0;

    if select(0, nil, @WriteSet, nil, @TV) <= 0 then Exit; // timeout or error

    // Verify the connection actually succeeded (select can fire on error too)
    ErrOpt := 0;
    ErrLen := SizeOf(ErrOpt);
    getsockopt(Sock, SOL_SOCKET, SO_ERROR, @ErrOpt, ErrLen);
    if ErrOpt <> 0 then Exit;

    // Switch back to blocking mode for send/recv
    Mode := 0;
    ioctlsocket_nb(Sock, FIONBIO_CMD, Mode);

    Request :=
      'POST ' + Path + ' HTTP/1.1' + CRLF +
      'Host: ' + Host + CRLF +
      'Authorization: Bearer ' + AuthToken + CRLF +
      'Content-Type: application/json' + CRLF +
      'Content-Length: ' + IntToStr(Length(JSONData)) + CRLF +
      'Connection: close' + CRLF + CRLF +
      JSONData;

    BytesSent := send(Sock, PChar(Request)^, Length(Request), 0);
    if BytesSent <= 0 then Exit;

    BytesReceived := recv(Sock, Buffer, SizeOf(Buffer) - 1, 0);
    if BytesReceived > 0 then
    begin
      Buffer[BytesReceived] := #0;
      Result := (Pos('HTTP/1.1 2', Buffer) > 0) or
                (Pos('HTTP/1.0 2', Buffer) > 0);
    end;
  finally
    closesocket(Sock);
  end;
end;

// ============================================================
// Publish a metric to MQTT via HA REST API.
// Full topic: {prefix}/{hostname}/{topic}
// ============================================================
procedure PublishMetric(const Hostname, Topic, Payload: string);
var
  JSONData: string;
begin
  JSONData :=
    '{"topic":"' + MQTT_TOPIC_PREFIX + '/' + Hostname + '/' + Topic + '",' +
    '"payload":"' + StringReplace(Payload, '"', '\"', [rfReplaceAll]) + '"}';

  HTTPPost(MQTT_URL + ':' + MQTT_PORT + '/api/services/mqtt/publish',
           HA_TOKEN, JSONData);

  Sleep(50); // throttle to avoid flooding HA
end;

// ============================================================
// CPU load % via typeperf using registry-resolved counter names.
// Takes 2 samples; the last value is retained (more accurate).
// Returns 0 if typeperf fails (e.g. some VMs).
// ============================================================
function GetCPULoad: Integer;
var
  ObjName, CounterName : string;
  CounterPath, TempFile: string;
  TempBuf : array[0..MAX_PATH] of Char;
  F       : TextFile;
  Line    : string;
  P, ErrCode : Integer;
  CpuVal  : Double;
begin
  Result := 0;

  FillChar(TempBuf, SizeOf(TempBuf), 0);
  GetTempPath(SizeOf(TempBuf), TempBuf);
  TempFile := TempBuf + 'wm_cpu.csv';

  RunCommand('typeperf "\238(_Total)\6" -sc 2 -o "' + TempFile + '"');
  if not FileExists(TempFile) then Exit;

  try
    AssignFile(F, TempFile);
    Reset(F);
    while not Eof(F) do
    begin
      ReadLn(F, Line);
      Line := Trim(Line);

      // Skip header and empty lines
      if (Line = '') or (Pos('"(PDH', Line) > 0) or
         (Pos(ObjName, Line) > 0) then Continue;

      // Data CSV: "timestamp","value" — take last comma field
      P := LastDelimiter(',', Line);
      if P > 0 then
      begin
        Line := Trim(Copy(Line, P + 1, Length(Line)));
        Line := StringReplace(Line, '"', '', [rfReplaceAll]);
        Line := StringReplace(Line, ',', '.', [rfReplaceAll]); // locale decimal
        Val(Line, CpuVal, ErrCode);
        if ErrCode = 0 then
          Result := Round(CpuVal); // keep last valid sample
      end;
    end;
    CloseFile(F);
    SysUtils.DeleteFile(TempFile);
  except
    Result := 0;
  end;
end;

// ============================================================
// CPU temperature in °C.
// Method 1: ACPI thermal zone (tenths of Kelvin).
// Method 2: Win32_TemperatureProbe (vendor-dependent).
// Returns -1 when unavailable (expected on VMs).
// ============================================================
function GetCPUTemperature: Integer;

  function TenthsKelvinToCelsius(Raw: Int64): Integer;
  begin
    Result := Round((Raw / 10.0) - 273.15);
  end;

  function IsValidTemp(T: Integer): Boolean;
  begin
    Result := (T >= -20) and (T <= 150);
  end;

var
  RawTemp: Int64;
begin
  Result := -1;

  // Method 1: MSAcpi_ThermalZoneTemperature
  RawTemp := StrToInt64Def(ExtractWMICValue(RunCommand(
    'wmic /namespace:\\root\wmi PATH ' +
    'MSAcpi_ThermalZoneTemperature get CurrentTemperature /value')), -1);
  if RawTemp > 0 then
  begin
    Result := TenthsKelvinToCelsius(RawTemp);
    if IsValidTemp(Result) then Exit;
    Result := -1;
  end;

  // Method 2: Win32_TemperatureProbe
  RawTemp := StrToInt64Def(ExtractWMICValue(RunCommand(
    'wmic /namespace:\\root\cimv2 PATH ' +
    'Win32_TemperatureProbe get CurrentReading /value')), -1);
  if RawTemp > 0 then
  begin
    if RawTemp > 1000 then Result := TenthsKelvinToCelsius(RawTemp)
    else                    Result := Integer(RawTemp);
    if not IsValidTemp(Result) then Result := -1;
  end;
end;

// ============================================================
// Collect all system information in a single procedure.
// ============================================================
procedure CollectSystemInfo(out Info: TSystemInfo);
var
  Buf          : array[0..255] of Char;
  BufSz        : DWORD;
  Manufacturer : string;
  Model        : string;
  BootStr      : string;
  BootTime     : TDateTime;
  Y, Mo, D, H, Mi, S : Word;
begin
  // Hostname via WinAPI (no WMIC round-trip needed)
  BufSz := SizeOf(Buf);
  if GetComputerName(Buf, BufSz) then Info.Hostname := Buf
  else                                 Info.Hostname := 'Unknown';

  // Model = Manufacturer + Model
  Manufacturer := ExtractWMICValue(RunCommand(
    'wmic computersystem get manufacturer /value'));
  Model        := ExtractWMICValue(RunCommand(
    'wmic computersystem get model /value'));
  Info.Model   := Trim(Manufacturer + ' ' + Model);

  // Target platform (baseboard product; falls back to model)
  Info.TargetPlatform := ExtractWMICValue(RunCommand(
    'wmic baseboard get product /value'));
  if Info.TargetPlatform = '' then Info.TargetPlatform := Model;

  Info.Version      := ExtractWMICValue(RunCommand('wmic os get caption /value'));
  Info.Architecture := ExtractWMICValue(RunCommand('wmic os get osarchitecture /value'));

  // Uptime: LastBootUpTime → elapsed seconds
  BootStr            := ExtractWMICValue(RunCommand('wmic os get lastbootuptime /value'));
  Info.UptimeSeconds := 0;
  if Length(BootStr) >= 14 then
  begin
    Y  := StrToIntDef(Copy(BootStr,  1, 4), 0);
    Mo := StrToIntDef(Copy(BootStr,  5, 2), 0);
    D  := StrToIntDef(Copy(BootStr,  7, 2), 0);
    H  := StrToIntDef(Copy(BootStr,  9, 2), 0);
    Mi := StrToIntDef(Copy(BootStr, 11, 2), 0);
    S  := StrToIntDef(Copy(BootStr, 13, 2), 0);
    try
      BootTime := EncodeDate(Y, Mo, D) + EncodeTime(H, Mi, S, 0);
      Info.UptimeSeconds := Round((Now - BootTime) * 86400.0);
    except
      Info.UptimeSeconds := 0;
    end;
  end;
end;

// ============================================================
// Memory in KB from WMIC OS properties.
// ============================================================
procedure GetMemoryInfo(out Total, Free, Used, Percent: Int64);
begin
  Total := StrToInt64Def(ExtractWMICValue(RunCommand(
    'wmic os get totalvisiblememorysize /value')), 0);
  Free  := StrToInt64Def(ExtractWMICValue(RunCommand(
    'wmic os get freephysicalmemory /value')), 0);
  Used  := Total - Free;
  if Total > 0 then Percent := (Used * 100) div Total
  else              Percent := 0;
end;

// ============================================================
// Disk info in KB for the given drive letter (e.g. 'C').
// ============================================================
procedure GetDiskInfo(const Drive: string;
                      out Total, Free, Used, Percent: Int64);
var
  SizeBytes, FreeBytes: Int64;
begin
  Total := 0; Free := 0; Used := 0; Percent := 0;

  SizeBytes := StrToInt64Def(ExtractWMICValue(RunCommand(
    'wmic logicaldisk where DeviceID="' + Drive + ':" get size /value')), 0);
  FreeBytes := StrToInt64Def(ExtractWMICValue(RunCommand(
    'wmic logicaldisk where DeviceID="' + Drive + ':" get freespace /value')), 0);

  if SizeBytes = 0 then Exit;
  Total   := SizeBytes div 1024;
  Free    := FreeBytes  div 1024;
  Used    := Total - Free;
  Percent := (Used * 100) div Total;
end;

// ============================================================
// TCP ESTABLISHED connection count via netstat.
// ============================================================
function GetTCPConnections: Integer;
begin
  Result := StrToIntDef(
    Trim(RunCommand('netstat -an | find /c "ESTABLISHED"')), 0);
end;

// ============================================================
// Shared helper: run a schtasks command and return success.
// ============================================================
function RunSchtasks(const Args: string): Boolean;
var
  SI       : TStartupInfo;
  PI       : TProcessInformation;
  ExitCode : DWORD;
begin
  Result   := False;
  ExitCode := 1;
  FillChar(SI, SizeOf(SI), 0);
  FillChar(PI, SizeOf(PI), 0);
  SI.cb          := SizeOf(TStartupInfo);
  SI.dwFlags     := STARTF_USESHOWWINDOW;
  SI.wShowWindow := SW_HIDE;

  if CreateProcess(nil, PChar('cmd.exe /c schtasks ' + Args),
                   nil, nil, False, 0, nil, nil, SI, PI) then
  begin
    try
      WaitForSingleObject(PI.hProcess, INFINITE);
      GetExitCodeProcess(PI.hProcess, ExitCode);
      Result := (ExitCode = 0);
    finally
      CloseHandle(PI.hProcess);
      CloseHandle(PI.hThread);
    end;
  end;
end;

function CreateScheduledTask: Boolean;
begin
  Log('  Task     : ' + TASK_NAME);
  Log('  Interval : every ' + IntToStr(SCHEDULE_INTERVAL) + ' minute(s)');
  Log('  Exe      : ' + ParamStr(0));
  Result := RunSchtasks(
    '/create /tn "' + TASK_NAME + '" ' +
    '/tr "\"' + ParamStr(0) + '\"" ' +
    '/sc minute /mo ' + IntToStr(SCHEDULE_INTERVAL) +
    ' /ru SYSTEM /f');
  if Result then Log('  SUCCESS')
  else           Log('  FAILED — run as administrator?');
end;

function RemoveScheduledTask: Boolean;
begin
  Log('  Task: ' + TASK_NAME);
  Result := RunSchtasks('/delete /tn "' + TASK_NAME + '" /f');
  if Result then Log('  SUCCESS')
  else           Log('  FAILED — task not found or insufficient rights.');
end;

// ============================================================
// Main
// ============================================================
var
  Info    : TSystemInfo;
  Uptime  : Int64;
  MemTotal, MemFree, MemUsed, MemPct : Int64;
  DskTotal, DskFree, DskUsed, DskPct : Int64;
  CPULoad : Integer;
  CPUTemp : Integer;
  TCPConn : Integer;
  WSAData : TWSAData;

begin
  IsInteractive := DetectInteractive;
  if not IsInteractive then
    ShowWindow(GetConsoleWindow, SW_HIDE);

  Log('WindowsMetrics — Home Assistant MQTT publisher');
  Log('==============================================');
  Log('');

  if not LoadConfiguration then Halt(1);

  Log('  MQTT         : ' + MQTT_URL + ':' + MQTT_PORT);
  Log('  Topic prefix : ' + MQTT_TOPIC_PREFIX);
  Log('  Schedule     : every ' + IntToStr(SCHEDULE_INTERVAL) + ' min');
  Log('');

  // --install / --uninstall
  if ParamCount > 0 then
  begin
    if UpperCase(ParamStr(1)) = '--INSTALL' then
    begin
      Log('Installing scheduled task...');
      if CreateScheduledTask then
        Log('Done. Metrics will be published every ' +
            IntToStr(SCHEDULE_INTERVAL) + ' minute(s).')
      else
        Log('ERROR: could not create task.');
      Halt(0);
    end
    else if UpperCase(ParamStr(1)) = '--UNINSTALL' then
    begin
      Log('Removing scheduled task...');
      if RemoveScheduledTask then
        Log('Done. Automatic publishing stopped.')
      else
        Log('ERROR: could not remove task.');
      Halt(0);
    end
    else
    begin
      Log('Unknown parameter: ' + ParamStr(1));
      Log('');
      Log('Usage:');
      Log('  WindowsMetrics.exe              Collect and publish metrics');
      Log('  WindowsMetrics.exe --install    Create scheduled task');
      Log('  WindowsMetrics.exe --uninstall  Remove scheduled task');
      Halt(1);
    end;
  end;

  // WinSock initialisation
  FillChar(WSAData, SizeOf(WSAData), 0);
  if WSAStartup(MAKEWORD(2, 2), WSAData) <> 0 then
  begin
    Log('ERROR: WinSock initialisation failed.');
    Halt(1);
  end;

  try
    // ---- System ----
    Log('========== SYSTEM ==========');
    CollectSystemInfo(Info);
    Uptime := Info.UptimeSeconds;

    Log('  Hostname : ' + Info.Hostname);
    Log('  Model    : ' + Info.Model);
    Log('  Platform : ' + Info.TargetPlatform);
    Log('  OS       : ' + Info.Version);
    Log('  Arch     : ' + Info.Architecture);
    Log('  Uptime   : ' + IntToStr(Uptime) + ' s  (' +
        IntToStr(Uptime div 86400) + 'd ' +
        IntToStr((Uptime mod 86400) div 3600) + 'h ' +
        IntToStr((Uptime mod 3600) div 60) + 'm)');

    PublishMetric(Info.Hostname, 'system/hostname',        Info.Hostname);
    PublishMetric(Info.Hostname, 'system/model',           Info.Model);
    PublishMetric(Info.Hostname, 'system/target_platform', Info.TargetPlatform);
    PublishMetric(Info.Hostname, 'system/version',         Info.Version);
    PublishMetric(Info.Hostname, 'system/architecture',    Info.Architecture);
    PublishMetric(Info.Hostname, 'system/uptime',          IntToStr(Uptime));
    Log('');

    // ---- CPU ----
    Log('========== CPU ==========');
    CPULoad := GetCPULoad;
    CPUTemp := GetCPUTemperature;
    Log('  Load : ' + IntToStr(CPULoad) + '%');
    if CPUTemp >= 0 then Log('  Temp : ' + IntToStr(CPUTemp) + ' C')
    else                 Log('  Temp : N/A');

    PublishMetric(Info.Hostname, 'cpu/load_percent', 'value:' + IntToStr(CPULoad));
    if CPUTemp >= 0 then
      PublishMetric(Info.Hostname, 'cpu/temperature', 'value:' + IntToStr(CPUTemp));
    Log('');

    // ---- Memory ----
    Log('========== MEMORY ==========');
    GetMemoryInfo(MemTotal, MemFree, MemUsed, MemPct);
    Log('  Total : ' + IntToStr(MemTotal div 1024) + ' MB');
    Log('  Free  : ' + IntToStr(MemFree  div 1024) + ' MB');
    Log('  Used  : ' + IntToStr(MemUsed  div 1024) + ' MB  (' + IntToStr(MemPct) + '%)');

    PublishMetric(Info.Hostname, 'memory/memory-total',         'value:' + IntToStr(MemTotal));
    PublishMetric(Info.Hostname, 'memory/memory-free',          'value:' + IntToStr(MemFree));
    PublishMetric(Info.Hostname, 'memory/memory-used',          'value:' + IntToStr(MemUsed));
    PublishMetric(Info.Hostname, 'memory/memory-usage-percent', 'value:' + IntToStr(MemPct));
    Log('');

    // ---- Disk C: ----
    Log('========== DISK (C:) ==========');
    GetDiskInfo('C', DskTotal, DskFree, DskUsed, DskPct);
    Log('  Total : ' + IntToStr(DskTotal div 1048576) + ' GB');
    Log('  Free  : ' + IntToStr(DskFree  div 1048576) + ' GB');
    Log('  Used  : ' + IntToStr(DskUsed  div 1048576) + ' GB  (' + IntToStr(DskPct) + '%)');

    PublishMetric(Info.Hostname, 'disk/total',   'value:' + IntToStr(DskTotal));
    PublishMetric(Info.Hostname, 'disk/free',    'value:' + IntToStr(DskFree));
    PublishMetric(Info.Hostname, 'disk/used',    'value:' + IntToStr(DskUsed));
    PublishMetric(Info.Hostname, 'disk/percent', 'value:' + IntToStr(DskPct));
    Log('');

    // ---- Network ----
    Log('========== NETWORK ==========');
    TCPConn := GetTCPConnections;
    Log('  TCP established : ' + IntToStr(TCPConn));
    PublishMetric(Info.Hostname, 'conntrack/total', 'value:' + IntToStr(TCPConn));
    Log('');

    Log('Done.');
  finally
    WSACleanup;
  end;
end.
