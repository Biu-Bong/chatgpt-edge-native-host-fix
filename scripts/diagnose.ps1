# ChatGPT Edge 原生通道诊断。只读，不改系统。
$ErrorActionPreference = 'Continue'
$ChromeId = 'hehggadaopoacecdllhhajmbjkdcmajg'
$EdgeId = 'odlomjlbamekndcpllcnffbgeohgkmjh'
$HostDir = 'D:\Codex\.codex\plugins\cache\openai-bundled\chrome\latest\extension-host\windows\x64'
$Json = Join-Path $env:LOCALAPPDATA 'OpenAI\extension\com.openai.codexextension.json'
$Log = 'D:\Codex\eh-proxy.log'

function Show($k, $v) { Write-Host ("{0,-28} {1}" -f $k, $v) }

Write-Host '=== 进程 ==='
foreach ($n in @('ChatGPT','msedge','chrome','extension-host','extension-host.real','clash-verge','verge-mihomo')) {
  $c = @(Get-Process $n -ErrorAction SilentlyContinue).Count
  Show $n $c
}

Write-Host '`n=== 宿主文件 ==='
$exe = Join-Path $HostDir 'extension-host.exe'
$real = Join-Path $HostDir 'extension-host.real.exe'
Show 'host.exe' $(if (Test-Path $exe) { '{0} bytes {1}' -f (Get-Item $exe).Length, (Get-Item $exe).LastWriteTime } else { 'MISSING' })
Show 'host.real.exe' $(if (Test-Path $real) { '{0} bytes' -f (Get-Item $real).Length } else { 'MISSING' })
if ((Test-Path $exe) -and (Get-Item $exe).Length -gt 100000) {
  Write-Host 'WARNING: extension-host.exe 体积像官方二进制，包装器可能被覆盖' -ForegroundColor Yellow
}

Write-Host '`n=== Native Messaging ==='
foreach ($p in @(
  'HKCU:\Software\Google\Chrome\NativeMessagingHosts\com.openai.codexextension',
  'HKCU:\Software\Microsoft\Edge\NativeMessagingHosts\com.openai.codexextension'
)) {
  if (Test-Path $p) { Show $p (Get-ItemProperty $p).'(default)' }
  else { Show $p 'MISSING' }
}
if (Test-Path $Json) {
  Show 'json' $Json
  Get-Content $Json -Raw
} else { Show 'json' 'MISSING' }

Write-Host '`n=== 代理 ==='
$is = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
Show 'ProxyEnable' $is.ProxyEnable
Show 'ProxyServer' $is.ProxyServer
Show 'ProxyOverride' $is.ProxyOverride
if ($is.ProxyOverride -notmatch '<-loopback>') {
  Write-Host 'WARNING: ProxyOverride 缺少 <-loopback>' -ForegroundColor Yellow
}

Write-Host '`n=== 扩展目录 ==='
$edgeExt = Join-Path $env:LOCALAPPDATA "Microsoft\Edge\User Data\Default\Extensions\$EdgeId"
$chromeExt = Join-Path $env:LOCALAPPDATA "Google\Chrome\User Data\Default\Extensions\$ChromeId"
Show 'Edge ext' $(if (Test-Path $edgeExt) { (Get-ChildItem $edgeExt | Select-Object -First 1 -ExpandProperty Name) } else { 'MISSING' })
Show 'Chrome ext' $(if (Test-Path $chromeExt) { (Get-ChildItem $chromeExt | Select-Object -First 1 -ExpandProperty Name) } else { 'not in Default' })

Write-Host '`n=== 日志尾 ==='
if (Test-Path $Log) {
  Get-Content $Log -Tail 25
  $t = Get-Content $Log -Raw
  Write-Host '`n标志: hello=' $( $t.Contains('codexRuntime/hello') ) ' ensure=' $( $t.Contains('codexRuntime/ensure') ) ' pong=' $( $t.Contains('inject pong') ) ' 101=' $( $t.Contains('HTTP/1.1 101') )
} else { Write-Host '无 eh-proxy.log' }
