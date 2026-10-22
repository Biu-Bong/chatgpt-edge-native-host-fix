# 部署 ChatGPT Edge 原生通道修复。会编译包装器、写 NMH、改代理绕过、启动桌面端。
$ErrorActionPreference = 'Stop'
$SkillDir = Split-Path (Split-Path $PSCommandPath -Parent) -Parent
$Src = Join-Path $PSCommandPath '..\extension-host-wrapper.cs' | Resolve-Path
$HostDir = 'D:\Codex\.codex\plugins\cache\openai-bundled\chrome\latest\extension-host\windows\x64'
$WrapperOut = Join-Path $HostDir 'extension-host.exe'
$Real = Join-Path $HostDir 'extension-host.real.exe'
$JsonPath = Join-Path $env:LOCALAPPDATA 'OpenAI\extension\com.openai.codexextension.json'
$Csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$ChromeOrigin = 'chrome-extension://hehggadaopoacecdllhhajmbjkdcmajg/'
$EdgeOrigin = 'chrome-extension://odlomjlbamekndcpllcnffbgeohgkmjh/'

if (-not (Test-Path $Csc)) { throw "找不到 csc.exe: $Csc" }
if (-not (Test-Path $HostDir)) { throw "找不到宿主目录: $HostDir" }

# 若官方覆盖了包装器，把大文件挪成 real
if (Test-Path $WrapperOut) {
  $len = (Get-Item $WrapperOut).Length
  if ($len -gt 100000 -and -not (Test-Path $Real)) {
    Move-Item $WrapperOut $Real -Force
    Write-Host "已把被覆盖的官方 extension-host.exe 改名为 real ($len bytes)"
  }
}
if (-not (Test-Path $Real)) { throw "缺少 extension-host.real.exe，无法包装" }

Write-Host '编译包装器...'
$tmpExe = 'D:\Codex\extension-host-wrapper.exe'
& $Csc /nologo /optimize /out:$tmpExe $Src
if ($LASTEXITCODE -ne 0) { throw 'csc 编译失败' }

Get-Process extension-host, 'extension-host.real' -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep 1
Copy-Item $tmpExe $WrapperOut -Force
Copy-Item $Src 'D:\Codex\extension-host-wrapper.cs' -Force
Write-Host "已部署 $WrapperOut"

$json = @{
  allowed_origins = @($ChromeOrigin, $EdgeOrigin)
  description = 'ChatGPT browser native messaging host'
  name = 'com.openai.codexextension'
  path = $WrapperOut
  type = 'stdio'
} | ConvertTo-Json
New-Item -ItemType Directory -Force -Path (Split-Path $JsonPath) | Out-Null
[IO.File]::WriteAllText($JsonPath, $json)
foreach ($reg in @(
  'HKCU:\Software\Google\Chrome\NativeMessagingHosts\com.openai.codexextension',
  'HKCU:\Software\Microsoft\Edge\NativeMessagingHosts\com.openai.codexextension'
)) {
  New-Item -Path $reg -Force | Out-Null
  Set-ItemProperty -Path $reg -Name '(default)' -Value $JsonPath
}
$edgeCopy = Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data\NativeMessagingHosts'
New-Item -ItemType Directory -Force -Path $edgeCopy | Out-Null
Copy-Item $JsonPath (Join-Path $edgeCopy 'com.openai.codexextension.json') -Force
Write-Host "NMH JSON $JsonPath"

$is = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
$cur = [string](Get-ItemProperty $is).ProxyOverride
$need = @('localhost','127.*','127.0.0.1','::1','<local>','<-loopback>')
$parts = @($cur -split ';' | Where-Object { $_ -and $_.Trim() })
foreach ($n in $need) { if ($parts -notcontains $n) { $parts += $n } }
Set-ItemProperty -Path $is -Name ProxyOverride -Value ($parts -join ';')
Write-Host "ProxyOverride $((Get-ItemProperty $is).ProxyOverride)"

$verge = Join-Path $env:APPDATA 'io.github.clash-verge-rev.clash-verge-rev\verge.yaml'
if (Test-Path $verge) {
  $yt = Get-Content $verge -Raw
  if ($yt -match 'system_proxy_bypass:\s*null') {
    $yt = $yt -replace 'system_proxy_bypass:\s*null', 'system_proxy_bypass: "localhost;127.*;127.0.0.1;::1;<local>;<-loopback>"'
    Set-Content -Path $verge -Value $yt -Encoding UTF8
    Write-Host '已写入 Clash Verge system_proxy_bypass'
  }
}

if (-not (Get-Process ChatGPT -ErrorAction SilentlyContinue)) {
  Start-Process 'shell:AppsFolder\OpenAI.Codex_2p2nqsd0c76g0!App'
  Write-Host '已启动 ChatGPT 桌面端'
  Start-Sleep 3
}

$edge = 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'
if (-not (Test-Path $edge)) { $edge = 'C:\Program Files\Microsoft\Edge\Application\msedge.exe' }
if (-not (Get-Process msedge -ErrorAction SilentlyContinue)) {
  Start-Process $edge -ArgumentList '--restore-last-session','--proxy-bypass-list=<-loopback>;127.0.0.1;localhost;::1','https://chatgpt.com/'
  Write-Host '已启动 Edge'
} else {
  Start-Process $edge 'https://chatgpt.com/'
  Write-Host 'Edge 已在运行，已打开 chatgpt.com 以唤醒扩展'
}

Write-Host '完成。看 D:\Codex\eh-proxy.log：应出现 rewrite spawn origin、inject pong；点侧栏后应有 hello/ensure 与 backend status 101。'
Write-Host "skill dir: $SkillDir"
