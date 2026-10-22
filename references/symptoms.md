# 报错对照

按侧栏原文对号入座。可同时存在多层问题，按表从上往下修。

## Unable to connect to Codex app-server at ws://127.0.0.1:PORT

扩展连的是**已经失效**的本地端口。

常见原因：

- ChatGPT / extension-host 重启后换了端口，Edge 扩展 storage 仍记着旧 URL
- 系统代理把 `ws://127.0.0.1` 拐到 Clash，没有 `<-loopback>`
- Edge 未注册 Native Messaging，只能拿过期缓存硬连

动作：

1. `Get-Process ChatGPT, extension-host`；没有就启动桌面端
2. 看 `Get-NetTCPConnection` 当前 listen 端口是否等于报错端口
3. 不等则清 Edge 扩展存储：
   `...\Edge\User Data\Default\Local Extension Settings\odlomjlbamekndcpllcnffbgeohgkmjh`
   （先停 Edge，再改名备份）
4. 补 Edge NMH + 代理 bypass
5. 重新打开侧栏，让它走 native 拿新 URL

## Open or update the ChatGPT desktop app / Native transport disconnected

原生管道断了，或根本没连上桌面端。

常见原因：

- 桌面端没开（进程名 `ChatGPT`，包 `OpenAI.Codex`）
- Edge 没有 `HKCU\...\Edge\NativeMessagingHosts\com.openai.codexextension`
- 包装器未把 Edge 启动 Origin 改成 Chrome ID → `extension-host.real` 立刻退出
- 包装器未回复 jsonrpc `ping` → 扩展认为 transport 死了
- 反复 `connectNative` 会杀掉上一根管道（不要连续开多个侧栏页）

动作：

1. `Start-Process "shell:AppsFolder\OpenAI.Codex_2p2nqsd0c76g0!App"`
2. 确认 NMH JSON 的 `allowed_origins` 含 Edge ID，`path` 指向包装器
3. 部署 `scripts/extension-host-wrapper.cs` 编译结果
4. 看 `D:\Codex\eh-proxy.log`：应有 `rewrite spawn origin`、`inject pong`、`child pid`

## 侧栏只剩 Try again / 一直转圈，日志里 pong 正常

原生消息层是通的（`inject pong`、`hello` 都有），断在 app-server 启动：

```json
{"error":{"code":1,"data":{"type":"required_path_missing"},
 "message":"Codex app-server manifest entry is missing required path nodePath"}}
```

同一个位置报 `resourcesPath` 是**下一层**问题——宿主按固定顺序校验，改完第一个才会暴露第二个。

清单：`D:\Codex\.codex\chrome-native-hosts-v2.json`（`schemaVersion: 2`，`entries[].paths`）

| 字段 | 为什么失效 |
|---|---|
| `nodePath` / `nodeModuleDirs` / `nodeReplPath` | 指向 `runtimes\cua_node\<hash>\bin\`，Codex 换运行时后旧 hash 目录被删，或只装了半套（有 `node_repl.exe` 没有 `node.exe`） |
| `resourcesPath` | 指向 `WindowsApps\OpenAI.Codex_<版本>_x64__...\app\resources`，应用升级后旧版本目录被删 |

判定「运行时完整」：`bin\node.exe` 与 `bin\node_modules` 同时存在。残缺目录里往往只剩 `node_repl.exe`。

动作：跑 `scripts\fix-manifest.ps1`（先 `-DryRun` 看改动，再 `-Restart`）。
手改时注意：**不要用 `ConvertTo-Json` 重写**，会丢掉 CRLF 并重排全文。

## 侧栏空白 / 一直转圈，Chrome 正常

优先查：

- Clash `ProxyOverride` 无 `<-loopback>`
- Edge 快捷方式未带 `--proxy-bypass-list=<-loopback>`
- uBlock 等拦截 `127.0.0.1`（次要）

## hello/ensure 成功但侧栏仍失败

日志有 `localAppServerUrl` 和 `fwd backend=`，但没有 `backend status HTTP/1.1 101`。

原因几乎总是 **WebSocket Origin 被改成 Chrome ID**，而 token 是 Edge `ensure` 签发的。

动作：包装器 WS 转发必须**透传 Origin**，只改 Host。不要 `Origin: chrome-extension://hehggadao...`。

## 更新 ChatGPT / Codex 之后突然全挂

官方覆盖了 `extension-host.exe`，并重写了 app-server 清单。

动作：

1. 若当前 `extension-host.exe` 体积约 800KB+，把它改名为 `extension-host.real.exe`（若 real 已存在则先确认哈希）
2. 重新编译包装器覆盖 `extension-host.exe`
3. 核对 NMH `path` 仍指向该包装器
4. 结束所有 `extension-host` / `extension-host.real` 再连
5. **再跑一次 `scripts\fix-manifest.ps1`**：清单里的 `nodePath` / `resourcesPath` 一定已指向被删的旧目录

## 诊断时不要被这些带偏

- `curl http://127.0.0.1:PORT` 返回 403：正常，那是 WS 服务，不是 HTTP 站点
- Edge `edge://flags` 的 Local Network Access：可作辅助，不是主因
- 给 Policies 写 `NativeMessagingUserLevelHosts` 常会 Access Denied，用户级 HKCU NMH 足够
- 打开 `codex-sidepanel/index.html` 当普通标签，不一定会发 `hello`；真正侧栏或点 Try again 才会
