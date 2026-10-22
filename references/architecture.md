# 架构与本机路径

## 调用链

```
Edge ChatGPT 侧栏 (扩展 ID odlomj…)
  → chrome.runtime.connectNative("com.openai.codexextension")
  → 包装器 extension-host.exe
       ├─ 把启动 Origin 改写成 Chrome ID
       ├─ 拉起 extension-host.real.exe
       ├─ 回复 jsonrpc ping
       └─ 把 localAppServerUrl 的端口改到本地代理口
  → 侧栏 WebSocket ws://127.0.0.1:<代理口>?token=...
  → 包装器转发到 real 的 ws 口（Origin 原样透传）
  → ChatGPT 桌面端 / Codex app-server
```

Chrome 走同一套 NMH，启动参数已是 Chrome ID，包装器原样转发。

## 扩展 ID

| 浏览器 | 扩展 ID | Origin |
|--------|---------|--------|
| Chrome | `hehggadaopoacecdllhhajmbjkdcmajg` | `chrome-extension://hehggadaopoacecdllhhajmbjkdcmajg/` |
| Edge | `odlomjlbamekndcpllcnffbgeohgkmjh` | `chrome-extension://odlomjlbamekndcpllcnffbgeohgkmjh/` |

清单 `allowed_origins` 必须同时包含两者（带尾斜杠）。浏览器按 Origin 决定是否允许拉起宿主；real 二进制启动时往往只接受 Chrome ID。

## Native Messaging 名称

`com.openai.codexextension`

注册位置（用户级）：

```
HKCU\Software\Google\Chrome\NativeMessagingHosts\com.openai.codexextension
HKCU\Software\Microsoft\Edge\NativeMessagingHosts\com.openai.codexextension
```

默认值指向 JSON 清单，例如：

`%LOCALAPPDATA%\OpenAI\extension\com.openai.codexextension.json`

也可再复制一份到：

`%LOCALAPPDATA%\Microsoft\Edge\User Data\NativeMessagingHosts\com.openai.codexextension.json`

`path` 必须是包装后的：

`D:\Codex\.codex\plugins\cache\openai-bundled\chrome\latest\extension-host\windows\x64\extension-host.exe`

同目录必须有 `extension-host.real.exe`（官方约 879KB 的 PE）。包装器本身约 11KB。

## ChatGPT 桌面端

开始菜单名是 **ChatGPT**，包名：

```
OpenAI.Codex_2p2nqsd0c76g0!App
```

启动：

```powershell
Start-Process "shell:AppsFolder\OpenAI.Codex_2p2nqsd0c76g0!App"
```

进程名 `ChatGPT`，安装目录类似：

`C:\Program Files\WindowsApps\OpenAI.Codex_<version>_x64__2p2nqsd0c76g0\app\ChatGPT.exe`

侧栏文案说 “desktop app”，不是必须再装一个叫 ChatGPT 的独立安装包。

## 参考路径（本机实测）

| 用途 | 路径 |
|------|------|
| Codex 插件缓存 | `D:\Codex\.codex\plugins\cache\openai-bundled\chrome\latest\` |
| 包装器源码（工作副本） | `D:\Codex\extension-host-wrapper.cs` |
| 包装器日志 | `D:\Codex\eh-proxy.log` |
| NMH JSON | `%LOCALAPPDATA%\OpenAI\extension\com.openai.codexextension.json` |
| Clash Verge | `%APPDATA%\io.github.clash-verge-rev.clash-verge-rev\verge.yaml` |
| Edge 扩展目录 | `%LOCALAPPDATA%\Microsoft\Edge\User Data\Default\Extensions\odlomjlbamekndcpllcnffbgeohgkmjh\` |
| Edge 扩展存储 | `...\Default\Local Extension Settings\odlomjlbamekndcpllcnffbgeohgkmjh\` |

`%USERPROFILE%\.codex` 也可能有一份缓存；以 NMH `path` 和正在运行的 `extension-host` 为准。

## 代理

系统代理常见 `127.0.0.1:7897`（Clash Verge mixed-port）。Chromium **不会**默认绕过 loopback，必须有 `<-loopback>`。

`HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings\ProxyOverride` 应包含：

`localhost;127.*;127.0.0.1;::1;<local>;<-loopback>`

Clash Verge `verge.yaml`：

```yaml
use_default_bypass: true
system_proxy_bypass: "localhost;127.*;127.0.0.1;::1;<local>;<-loopback>"
```

Edge 快捷方式可加：

`--proxy-bypass-list=<-loopback>;127.0.0.1;localhost;::1`

## 协议要点

- Native 消息：4 字节小端长度 + UTF-8 JSON
- 扩展会发 `{"jsonrpc":"2.0","method":"ping","id":N}`（id 为数字）；real 通常不回
- 随后 `codexRuntime/hello`、`codexRuntime/ensure` 或 `codexRuntime/restart`，id 形如 `native-host:1`
- hello 成功：`manifestSchemaVersion: 2`，`nativeHostProtocolVersion: 2`，`supportedProtocolVersions` 含 `2`
- ensure/restart 成功：`localAppServerUrl` = `ws://127.0.0.1:<port>?token=...`

## app-server 清单

`D:\Codex\.codex\chrome-native-hosts-v2.json`

```json
{ "schemaVersion": 2,
  "entries": [ { "entryId": "codex-runtime-...", "appVersion": "...", "cliVersion": "...",
                 "paths": { "nodePath": "...", "nodeModuleDirs": ["..."], "nodeReplPath": "...",
                            "codexCliPath": "...", "extensionHostPath": "...",
                            "resourcesPath": "...", "codexHome": "...", "platform": "win32" } } ] }
```

`codexRuntime/hello` 只回协议版本，不读这份清单；`codexRuntime/restart` / `ensure` 才按 entry 启动
app-server，并**逐项校验 `paths` 里每个路径是否存在**，缺哪个就报
`required_path_missing` + 字段名。所以先修 `nodePath`、再暴露 `resourcesPath` 是正常现象，不是改坏了。

两条路径都是版本写死的：

- `nodePath` → `%LOCALAPPDATA%\OpenAI\Codex\runtimes\cua_node\<hash>\bin\node.exe`
  完整运行时必须同时有 `bin\node.exe` 和 `bin\node_modules`；残缺目录可能只剩 `node_repl.exe`
- `resourcesPath` → `C:\Program Files\WindowsApps\OpenAI.Codex_<版本>_x64__<publisher>\app\resources`

升级后旧目录被删，清单不自动更新 → Try again。

## 更新后常见破坏

Codex / ChatGPT 更新会：

- 用官方 `extension-host.exe` 覆盖包装器
- 改 NMH `path` 指回官方文件或新缓存目录
- 只给 Chrome 写 NMH，漏掉 Edge
- Clash 刷新系统代理时丢掉 `<-loopback>`
- 重写 `chrome-native-hosts-v2.json`，`nodePath` / `resourcesPath` 指向已被删除的版本目录
