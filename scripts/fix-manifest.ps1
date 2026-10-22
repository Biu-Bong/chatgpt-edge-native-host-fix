<#
  修复 Codex app-server 清单里「版本写死」的路径。

  适用症状：侧栏 Try again / 一直转圈，eh-proxy.log 里 codexRuntime/restart 返回
    {"error":{"data":{"type":"required_path_missing"},"message":"... missing required path nodePath"}}
    或同样格式的 resourcesPath。

  只改这一份 JSON：
    - resourcesPath 的 WindowsApps 版本目录 -> 当前实际安装版本
    - runtimes\cua_node\<hash> -> 当前完整的运行时目录
  改前自动备份，保留 CRLF 与原编码，不重排 JSON。
#>
[CmdletBinding()]
param(
  [string]$ManifestPath = 'D:\Codex\.codex\chrome-native-hosts-v2.json',
  [switch]$DryRun,
  [switch]$Restart
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $ManifestPath)) { throw "找不到清单: $ManifestPath" }

# --- 1. 当前安装的 ChatGPT 桌面端 ---
$pkg = Get-AppxPackage -Name OpenAI.Codex | Sort-Object Version -Descending | Select-Object -First 1
if (-not $pkg) { throw '找不到 OpenAI.Codex 应用包（Get-AppxPackage）' }
$resDir = Join-Path $pkg.InstallLocation 'app\resources'
if (-not (Test-Path $resDir)) { throw "应用 resources 不存在: $resDir" }

# --- 2. 完整的 node 运行时 ---
$rtRoot = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\runtimes\cua_node'
if (-not (Test-Path $rtRoot)) { throw "找不到运行时根目录: $rtRoot" }
$goodRt = Get-ChildItem $rtRoot -Directory |
  Where-Object {
    (Test-Path (Join-Path $_.FullName 'bin\node.exe')) -and
    (Test-Path (Join-Path $_.FullName 'bin\node_modules'))
  } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $goodRt) { throw "在 $rtRoot 下没有完整运行时（需 bin\node.exe + bin\node_modules）" }

Write-Host ("应用版本   : " + $pkg.Version)
Write-Host ("resources  : " + $resDir)
Write-Host ("运行时     : " + $goodRt.Name)

# --- 3. 文本级替换（不经过 ConvertTo-Json，避免重排格式与换行） ---
$text = [IO.File]::ReadAllText($ManifestPath)
$changes = New-Object System.Collections.Generic.List[string]

$verPattern = [regex]'OpenAI\.Codex_[0-9]+(?:\.[0-9]+)*_x64__'
$targetVer = "OpenAI.Codex_$($pkg.Version)_x64__"
foreach ($m in ($verPattern.Matches($text) | ForEach-Object { $_.Value } | Sort-Object -Unique)) {
  if ($m -ne $targetVer) {
    $text = $text.Replace($m, $targetVer)
    $changes.Add("resourcesPath  $m  ->  $targetVer")
  }
}

$hashPattern = [regex]'cua_node\\\\([0-9a-fA-F]{16})'
$hashes = $hashPattern.Matches($text) | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
foreach ($h in $hashes) {
  if ($h -eq $goodRt.Name) { continue }
  $dir = Join-Path $rtRoot $h
  $ok = (Test-Path (Join-Path $dir 'bin\node.exe')) -and (Test-Path (Join-Path $dir 'bin\node_modules'))
  if (-not $ok) {
    $text = $text.Replace($h, $goodRt.Name)
    $changes.Add("cua_node      $h  ->  $($goodRt.Name)")
  }
}

if ($changes.Count -eq 0) {
  Write-Host '清单里的路径都已对得上，无需修改。' -ForegroundColor Green
} else {
  Write-Host ''
  Write-Host ("需要修改 " + $changes.Count + " 类路径：") -ForegroundColor Yellow
  $changes | ForEach-Object { Write-Host ("  * " + $_) }
  if ($DryRun) {
    Write-Host 'DryRun：不写盘。' -ForegroundColor Yellow
  } else {
    $backup = "$ManifestPath.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Copy-Item $ManifestPath $backup -Force
    Write-Host ("已备份: " + $backup)
    $bytes = [IO.File]::ReadAllBytes($ManifestPath)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    [IO.File]::WriteAllText($ManifestPath, $text, (New-Object System.Text.UTF8Encoding($hasBom)))
    Write-Host ("已写入: " + $ManifestPath)
  }
}

# --- 4. 校验：清单里每个路径都必须真实存在 ---
Write-Host ''
Write-Host '=== 校验 ==='
$j = Get-Content $ManifestPath -Raw | ConvertFrom-Json
$bad = 0
foreach ($e in $j.entries) {
  foreach ($prop in $e.paths.PSObject.Properties) {
    $vals = @()
    if ($prop.Value -is [string]) { $vals = @($prop.Value) }
    elseif ($prop.Value -is [array]) { $vals = @($prop.Value) }
    else { continue }
    foreach ($v in $vals) {
      if ($v -isnot [string]) { continue }
      if ($v -notmatch '^[A-Za-z]:[\\/]') { continue }   # 跳过 win32 这类非路径值
      if (-not (Test-Path $v)) {
        Write-Host ("  缺失 [{0}] {1}" -f $prop.Name, $v) -ForegroundColor Red
        $bad++
      }
    }
  }
}
if ($bad -eq 0) { Write-Host '所有路径均存在。' -ForegroundColor Green }
else { Write-Host ("仍有 $bad 个路径缺失，需人工确认。") -ForegroundColor Yellow }

if ($Restart -and -not $DryRun) {
  Write-Host ''
  Write-Host '重启 ChatGPT 桌面端...'
  Get-Process extension-host, 'extension-host.real' -ErrorAction SilentlyContinue | Stop-Process -Force
  Get-Process ChatGPT -ErrorAction SilentlyContinue | Stop-Process -Force
  Start-Sleep 1
  Start-Process ("shell:AppsFolder\" + $pkg.PackageFamilyName + "!App")
  Start-Sleep 5
  Write-Host ("ChatGPT 进程数: " + @(Get-Process ChatGPT -ErrorAction SilentlyContinue).Count)
}
