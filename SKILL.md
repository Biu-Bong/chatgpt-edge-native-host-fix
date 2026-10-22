---
name: chatgpt-edge-native-host-fix
description: >
  修复 Windows 上 ChatGPT/Codex 浏览器扩展侧栏打不开：Unable to connect、Native transport disconnected、
  Try again、一直转圈、ws://127.0.0.1、Codex app-server。覆盖两类根因：① Native Messaging 包装器缺失或代理
  绕过不成对；② app-server 清单里 nodePath / resourcesPath 指向已失效的版本目录。Chrome 能用 Edge 不能用、
  或 Codex 更新后突然全挂时使用。先跑 self-test 定位，再跑对应脚本，不要一上来清 cookie。
---

# ChatGPT 侧栏连不上 — 先定位，再对症

**不要**一上来清 cookie、装 CORS 插件、改 Edge flags、翻 references。先定位。

## 第 1 步：定位（20 秒）

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<this-skill>\scripts\self-test.ps1"
```

它冒充扩展走完整链路：spawn 包装器 → native messaging `hello` → `codexRuntime/restart`
→ 拿 `localAppServerUrl` → 用扩展 Origin 做 WebSocket 握手。只读，不改系统。

| self-test 结果 | 断在哪 | 去做 |
|---|---|---|
| `hello 无响应` | 宿主没被拉起：NMH 没注册 / `path` 指错 | 第 2 步 |
| `restart ERR required_path_missing` | 清单里 `nodePath` 或 `resourcesPath` 指向不存在的目录 | 第 3 步 |
| `restart` 没有 `localAppServerUrl` | 桌面端没开，或 app-server 起不来 | 先开桌面端，仍失败→第 3 步 |
| `websocket` 非 `101` | 代理绕过缺失，或 WS Origin 被改写 | 第 2 步 |
| 全部 PASS | 原生通道正常 | 在浏览器里点 **Try again** 即可 |

只报了某一种浏览器时用 `-Browser edge` 或 `-Browser chrome`。

## 第 2 步：修 Native Messaging + 代理

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<this-skill>\scripts\apply-fix.ps1"
```

编译包装器、注册 Edge/Chrome NMH、加 `<-loopback>`、启动 ChatGPT 桌面端、必要时拉起 Edge。

## 第 3 步：修清单里版本写死的路径

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<this-skill>\scripts\fix-manifest.ps1" -DryRun   # 先看要改什么
powershell -NoProfile -ExecutionPolicy Bypass -File "<this-skill>\scripts\fix-manifest.ps1" -Restart  # 确认后执行
```

只改 `D:\Codex\.codex\chrome-native-hosts-v2.json`：`resourcesPath` → 当前安装的 app 版本目录；
`nodePath` / `nodeModuleDirs` / `nodeReplPath` → 当前**完整**的 `runtimes\cua_node\<hash>`
（判定标准：`bin\node.exe` 与 `bin\node_modules` 都在）。改前自动备份，保留 CRLF 与原编码，不重排 JSON。

## 会复发

Codex 每次更新都会重写这份清单，`nodePath`（运行时哈希）和 `resourcesPath`（WindowsApps 版本目录）
必然再次指向旧目录。**症状还是 Try again**。复发时直接跑第 1 步 → 第 3 步，通常 1 分钟。

## 不要做

- 不要先跑 `diagnose.ps1` 再去围观日志；`self-test.ps1` 直接给结论
- 不要清 cookie / 清扩展存储 / 装 CORS 插件 / 改 Edge flags，这批动作与这两类根因无关
- 不要用 `ConvertTo-Json` 重写清单：会把 CRLF 换掉、把整个文件重排，出问题难回滚
- 不要手工改 `extension-host-wrapper.cs` 的逻辑

## 脚本失败时（才看）

| 现象 | 动作 |
|------|------|
| 缺 `extension-host.real.exe` | 若 `extension-host.exe` >100KB，改名为 `.real.exe` 再重跑 `apply-fix.ps1` |
| 日志无 `inject pong` / 无 `rewrite spawn origin` | 包装器没被用上；确认 NMH `path` 指向 `D:\Codex\.codex\...\extension-host.exe` |
| 有 `fwd` 无 `101` | Origin 被改错；WS 必须透传 Origin，只改 Host |
| 仍报旧 `ws://127.0.0.1:端口` | 停 Edge，把 `...\Edge\User Data\Default\Local Extension Settings\odlomjlbamekndcpllcnffbgeohgkmjh` 改名备份，重跑 |
| `fix-manifest.ps1` 说找不到完整运行时 | `runtimes\cua_node` 下确实没有 `bin\node.exe`，需重装 ChatGPT 桌面端 |

细节：`references/architecture.md`、`references/symptoms.md`。

## 系统前提

Windows PowerShell 5.1 **按本地代码页解码无 BOM 的 .ps1**。本 skill 的脚本均已带 UTF-8 BOM，
手工改写脚本时不要去掉，否则中文串会变乱码并触发语法错误。
