<#
  不打开浏览器就能判断「侧栏为什么连不上」。
  以扩展的身份走一遍完整链路：
    spawn 包装器 -> native messaging hello -> codexRuntime/restart
    -> 拿 localAppServerUrl -> 用扩展 Origin 做 WS 握手，期望 HTTP/1.1 101
  只读：不发任何修改型请求，不改系统配置。
#>
[CmdletBinding()]
param(
  [ValidateSet('edge', 'chrome', 'both')]
  [string]$Browser = 'both',
  [string]$ManifestPath = 'D:\Codex\.codex\chrome-native-hosts-v2.json'
)

$ErrorActionPreference = 'Stop'

$ids = @{
  edge   = 'odlomjlbamekndcpllcnffbgeohgkmjh'
  chrome = 'hehggadaopoacecdllhhajmbjkdcmajg'
}

# 宿主路径：优先用清单里登记的包装器
$hostExe = $null
if (Test-Path $ManifestPath) {
  try {
    $j = Get-Content $ManifestPath -Raw | ConvertFrom-Json
    $hostExe = ($j.entries.paths.extensionHostPath | Where-Object { $_ -like '*extension-host.exe' } | Select-Object -First 1)
  } catch {}
}
if (-not $hostExe) { $hostExe = 'D:\Codex\.codex\plugins\cache\openai-bundled\chrome\latest\extension-host\windows\x64\extension-host.exe' }
if (-not (Test-Path $hostExe)) { throw "找不到宿主: $hostExe" }

if (-not (Get-Process ChatGPT -ErrorAction SilentlyContinue)) {
  Write-Host '提醒：ChatGPT 桌面端没在运行，restart 很可能失败。' -ForegroundColor Yellow
}

function Test-One([string]$name) {
  $extId = $ids[$name]
  Write-Host ''
  Write-Host ("=== " + $name + " (" + $extId + ") ===") -ForegroundColor Cyan

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $hostExe
  $psi.Arguments = '"chrome-extension://' + $extId + '" "--parent-window=0"'
  $psi.UseShellExecute = $false
  $psi.RedirectStandardInput = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.CreateNoWindow = $true

  $p = [System.Diagnostics.Process]::Start($psi)
  $in = $p.StandardInput.BaseStream
  $out = $p.StandardOutput.BaseStream
  Start-Sleep -Milliseconds 600

  $send = {
    param($obj)
    $json = $obj | ConvertTo-Json -Compress -Depth 10
    $b = [Text.Encoding]::UTF8.GetBytes($json)
    $l = [BitConverter]::GetBytes([int]$b.Length)
    $in.Write($l, 0, 4); $in.Write($b, 0, $b.Length); $in.Flush()
  }

  $recv = {
    param([int]$timeoutMs = 20000)
    $hdr = New-Object byte[] 4
    $t = $out.ReadAsync($hdr, 0, 4)
    if (-not $t.Wait($timeoutMs)) { return $null }
    if ($t.Result -le 0) { return $null }
    $n = [BitConverter]::ToInt32($hdr, 0)
    $buf = New-Object byte[] $n
    $off = 0
    while ($off -lt $n) {
      $t2 = $out.ReadAsync($buf, $off, $n - $off)
      if (-not $t2.Wait($timeoutMs)) { return $null }
      if ($t2.Result -le 0) { return $null }
      $off += $t2.Result
    }
    return ([Text.Encoding]::UTF8.GetString($buf) | ConvertFrom-Json)
  }

  $cons = @{
    extensionBuildChannel      = 'prod'
    extensionId                = $extId
    extensionVersion           = '1.26.1006.11559'
    nativeHostName             = 'com.openai.codexextension'
    nativeHostProtocolVersion  = 2
  }

  & $send @{ jsonrpc = '2.0'; id = 'selftest:1'; method = 'codexRuntime/hello'; params = @{ constraints = $cons } }
  $hello = & $recv
  if ($hello -and $hello.result) { Write-Host '  hello      OK' -ForegroundColor Green }
  elseif ($hello -and $hello.error) { Write-Host ("  hello      ERR " + ($hello.error | ConvertTo-Json -Compress)) -ForegroundColor Red }
  else { Write-Host '  hello      无响应（宿主没起来？）' -ForegroundColor Red }

  & $send @{ jsonrpc = '2.0'; id = 'selftest:2'; method = 'codexRuntime/restart'; params = @{ constraints = $cons } }
  $restart = & $recv

  $verdict = 'FAIL'
  if ($restart -and $restart.result -and $restart.result.localAppServerUrl) {
    Write-Host ("  restart    OK  " + $restart.result.localAppServerUrl) -ForegroundColor Green
    $u = [uri]$restart.result.localAppServerUrl
    try {
      $tc = New-Object System.Net.Sockets.TcpClient
      $tc.Connect('127.0.0.1', $u.Port)
      $s = $tc.GetStream()
      $req = "GET " + $u.PathAndQuery + " HTTP/1.1`r`n" +
             "Host: 127.0.0.1:" + $u.Port + "`r`n" +
             "Upgrade: websocket`r`nConnection: Upgrade`r`n" +
             "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==`r`n" +
             "Sec-WebSocket-Version: 13`r`n" +
             "Origin: chrome-extension://" + $extId + "`r`n`r`n"
      $rb = [Text.Encoding]::ASCII.GetBytes($req)
      $s.Write($rb, 0, $rb.Length); $s.Flush()
      $acc = New-Object System.Text.StringBuilder
      $deadline = (Get-Date).AddSeconds(8)
      while ((Get-Date) -lt $deadline) {
        $b2 = New-Object byte[] 512
        $r = $s.ReadAsync($b2, 0, 512)
        if (-not $r.Wait(2000)) { break }
        if ($r.Result -le 0) { break }
        [void]$acc.Append([Text.Encoding]::ASCII.GetString($b2, 0, $r.Result))
        if ($acc.ToString().Contains("`r`n")) { break }
      }
      $first = ($acc.ToString() -split "`r`n")[0]
      if ($first -match '101') { Write-Host ("  websocket  OK  " + $first) -ForegroundColor Green; $verdict = 'PASS' }
      else { Write-Host ("  websocket  FAIL  " + $first) -ForegroundColor Red }
      $tc.Close()
    } catch { Write-Host ("  websocket  异常 " + $_.Exception.Message) -ForegroundColor Red }
  } elseif ($restart -and $restart.error) {
    Write-Host ("  restart    ERR " + ($restart.error | ConvertTo-Json -Compress)) -ForegroundColor Red
  } else {
    Write-Host '  restart    无响应' -ForegroundColor Red
  }

  try { $p.StandardInput.Close() } catch {}
  Start-Sleep -Milliseconds 400
  if (-not $p.HasExited) { $p.Kill() }
  return $verdict
}

$targets = if ($Browser -eq 'both') { @('edge', 'chrome') } else { @($Browser) }
$results = @{}
foreach ($t in $targets) { $results[$t] = Test-One $t }

Write-Host ''
Write-Host '=== 结论 ==='
foreach ($t in $targets) {
  $c = if ($results[$t] -eq 'PASS') { 'Green' } else { 'Red' }
  Write-Host ("  " + $t.PadRight(7) + $results[$t]) -ForegroundColor $c
}
Write-Host ''
Write-Host 'PASS 说明原生通道与 app-server 都正常；浏览器里点 Try again 即可。'
Write-Host '若 restart 报 required_path_missing -> 跑 fix-manifest.ps1。'
