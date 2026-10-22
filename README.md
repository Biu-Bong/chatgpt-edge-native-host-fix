# chatgpt-edge-native-host-fix

**Repairs the ChatGPT / Codex browser extension side panel on Windows when it only shows "Try again".**

Works for both **Microsoft Edge** and **Google Chrome**. No reinstall of the app, no extension uninstall, no cookie clearing.

> Search terms this repo answers: ChatGPT Edge extension not working · Unable to connect to Codex app-server ·
> Native transport disconnected · side panel stuck on Try again · ws://127.0.0.1 · native messaging host ·
> `chrome-native-hosts-v2.json` · `required_path_missing` · Codex app-server manifest · ChatGPT 侧栏打不开

---

## Symptoms covered

- Side panel shows **Try again** or spins forever; Chrome works but Edge doesn't (or both are broken).
- Panel text: `Unable to connect to Codex app-server at ws://127.0.0.1:<port>`
- Panel text: `Open or update the ChatGPT desktop app` / `Native transport disconnected`
- `eh-proxy.log` shows `codexRuntime/restart` returning `required_path_missing` with `nodePath` or `resourcesPath`

## Two independent root causes

They often stack, and fixing one exposes the other.

| # | Root cause | Script |
|---|---|---|
| 1 | The browser can't reach the native messaging host. NMH is registered for Chrome but not Edge, an app update overwrote the wrapper `extension-host.exe`, the wrapper never answers `ping`, or `ProxyOverride` lost `<-loopback>` so `ws://127.0.0.1` goes through Clash | `apply-fix.ps1` |
| 2 | The Codex app-server manifest (`<codex-home>\chrome-native-hosts-v2.json`) holds **version-pinned paths that no longer exist**: `runtimes\cua_node\<hash>\bin\node.exe` or `WindowsApps\OpenAI.Codex_<version>\app\resources` | `fix-manifest.ps1` |

Rule of thumb: *"broke right after a Codex update"* → cause 2. *"Chrome fine, Edge not"* → cause 1.

## Quick start

```powershell
git clone https://github.com/Biu-Bong/chatgpt-edge-native-host-fix.git
cd chatgpt-edge-native-host-fix

# 1. Which layer is broken? (read-only, ~20s)
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\self-test.ps1

# 2a. Native messaging host / proxy bypass
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\apply-fix.ps1

# 2b. Stale manifest paths
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\fix-manifest.ps1 -DryRun
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\fix-manifest.ps1 -Restart
```

Then click the ChatGPT icon in the browser once. If `self-test` already reports **PASS** for both browsers, the
native channel is fine — clicking Try again is all that's left.

## `self-test.ps1` — locate before you fix

It impersonates the extension and walks the whole chain:

```
spawn wrapper extension-host.exe
  → native messaging  codexRuntime/hello
  → codexRuntime/restart            → localAppServerUrl
  → WebSocket handshake with the extension Origin  → expect HTTP/1.1 101
```

Read-only, no system changes. Output maps straight to an action:

| Result | Broken layer | Do |
|---|---|---|
| `hello` gives no response | Host never spawned: NMH missing / `path` wrong | `apply-fix.ps1` |
| `restart ERR required_path_missing` | Manifest points at deleted directories | `fix-manifest.ps1` |
| `restart` without `localAppServerUrl` | Desktop app not running, or app-server can't start | Start the app, then `fix-manifest.ps1` |
| `websocket` not `101` | Proxy bypass or rewritten Origin | `apply-fix.ps1` |
| all PASS | Native channel healthy | Click **Try again** |

Use `-Browser edge` or `-Browser chrome` to test only one.

## `fix-manifest.ps1` — why it exists

`codexRuntime/restart` validates **every** path in the selected manifest entry and fails with
`required_path_missing` naming the first missing one. The manifest is written at install time and is never
updated on app upgrade, so both of these go stale:

- `nodePath` / `nodeModuleDirs` / `nodeReplPath` → `%LOCALAPPDATA%\OpenAI\Codex\runtimes\cua_node\<hash>\bin\`
- `resourcesPath` → `C:\Program Files\WindowsApps\OpenAI.Codex_<version>_x64__<publisher>\app\resources`

The script finds the currently installed app version and the newest **complete** runtime (one that has both
`bin\node.exe` and `bin\node_modules` — half-installed runtimes with only `node_repl.exe` exist), then does a
text-level replacement so CRLF and the original encoding survive. A `.bak-<timestamp>` copy is always written first.

## Requirements

- Windows 10 / 11
- Windows PowerShell 5.1 (built in; `pwsh` not required)
- ChatGPT desktop app installed as an MSIX package (`OpenAI.Codex`, from the Microsoft Store)
- The Codex bundled browser extension (`com.openai.codexextension`)

## What it changes on your machine

Read this before running. Nothing here is hidden, and nothing leaves your machine — no network calls, no telemetry.

| Action | Where |
|---|---|
| Register native messaging host | `HKCU\Software\Google\Chrome\NativeMessagingHosts\com.openai.codexextension`<br>`HKCU\Software\Microsoft\Edge\NativeMessagingHosts\com.openai.codexextension` |
| Write host manifest | `%LOCALAPPDATA%\OpenAI\extension\com.openai.codexextension.json` + a copy under Edge's `User Data` |
| Replace the host binary | renames `extension-host.exe` → `extension-host.real.exe`, deploys a compiled C# wrapper named `extension-host.exe` inside the Codex plugin cache |
| Proxy bypass | appends `<-loopback>` etc. to `HKCU\...\Internet Settings\ProxyOverride`; patches Clash Verge `verge.yaml` only if `system_proxy_bypass` is `null` |
| Processes | stops `extension-host` / `extension-host.real`, starts `ChatGPT` and possibly `msedge` |
| Manifest repair | edits `chrome-native-hosts-v2.json` **after** writing `.bak-<timestamp>` |

Undo: restore `extension-host.real.exe` → `extension-host.exe`, delete the two NMH registry keys, remove
`<-loopback>` from `ProxyOverride`, then restore the newest `.bak-*` of the manifest.

## It breaks again after every Codex update

The manifest is version-pinned, so an app update recreates the same dead references. Symptoms are identical.
Repeat `self-test.ps1` → `fix-manifest.ps1`. Takes about a minute.

## Repository layout

```
SKILL.md                     agent skill manifest (Claude / Codex / WorkBuddy skill format)
scripts/self-test.ps1        locate the broken layer, read-only
scripts/apply-fix.ps1        native messaging host + wrapper + proxy bypass
scripts/fix-manifest.ps1     stale nodePath / resourcesPath repair (-DryRun, -Restart)
scripts/diagnose.ps1         legacy read-only dump (processes, NMH, proxy, log tail)
scripts/extension-host-wrapper.cs   C# shim compiled by apply-fix.ps1
references/architecture.md   call chain, extension IDs, registry layout, manifest schema
references/symptoms.md       error-message → cause → action table
```

## How the wrapper works

`extension-host.real.exe` refuses to start when it is spawned by Edge (it only accepts the Chrome extension ID),
and it never answers the extension's `ping`. The wrapper is a ~13 KB C# shim that:

1. rewrites the inbound Origin argument `chrome-extension://odlomjlb…` → `chrome-extension://hehggad…` before spawning the real host;
2. replies to `{"method":"ping"}` itself;
3. opens a local TCP port, rewrites the `localAppServerUrl` the host returns to point at itself, and proxies the
   WebSocket to the real port **passing the original Origin through** (rewriting it there breaks the token check).

Compiled with the in-box `csc.exe`, no build tooling needed.

## Known limitations

- `D:\Codex` is the Codex home on the machine this was developed on. If yours is `%USERPROFILE%\.codex`, adjust
  `$HostDir` at the top of `apply-fix.ps1`.
- `self-test.ps1` sends a hardcoded `extensionVersion`. It is informational today; if the backend ever validates
  it, read the version from the extension folder instead.
- `fix-manifest.ps1` picks the newest complete runtime. If you ever legitimately have two complete runtimes and
  need a specific one, pin it instead.
- Assumes x64 and a single `OpenAI.Codex` package. Arm64 / side-by-side installs are untested.

## 中文说明

Windows 上 ChatGPT/Codex 浏览器扩展（Edge 和 Chrome）侧栏只显示 **Try again**、或报
`Unable to connect to Codex app-server`、`Native transport disconnected` 时用这个。

两类根因：① 浏览器到原生宿主这一层断了（NMH 没给 Edge 注册、包装器被官方更新覆盖、`ProxyOverride` 少了
`<-loopback>`）；② Codex 的 app-server 清单里 `nodePath` / `resourcesPath` 指向已被删除的版本目录。

先跑 `self-test.ps1` 定位（只读），再跑 `apply-fix.ps1` 或 `fix-manifest.ps1` 对症下药。
**每次 Codex 更新后会复发**，重跑这两条命令即可，约一分钟。

改动范围：HKCU 下两个 NMH 注册项、`%LOCALAPPDATA%\OpenAI\extension` 下的清单、Codex 插件缓存里的
`extension-host.exe`（原文件保留为 `extension-host.real.exe`）、`ProxyOverride`。清单修改前自动备份。
不联网、不上报。

## License

MIT — see [LICENSE](LICENSE).
