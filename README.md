# docent

**docent** is a small, cross-platform (Windows + macOS) local daemon that listens
for webhooks and brings the right remote Cursor workspace into focus on **this**
machine. It is the *receiver* half of a loosely-coupled pair: the *sender* is
[grove](https://github.com/KurtPreston/grove) (command `wt`) running on a remote
dev box. The only contract between them is a webhook body — `{host, path, name}`.

```
 dev box (grove / wt)                         workstation (docent)
 ────────────────────                         ──────────────────────
 POST /open  ───────► 127.0.0.1:39787 ──┐
 {host,path,name}                        │  reverse SSH tunnel
                                         └─► 127.0.0.1:39787  docent serve
                                                    │
                                                    ▼
                                      open-or-focus a remote Cursor window
                                      (Windows: on a named virtual desktop;
                                       macOS: window raised, no Spaces)
```

Cursor + Windows virtual desktops are just the first backend, not the core idea.

## How it works

grove POSTs JSON to `http://127.0.0.1:<port>/open` (default port **39787**),
reaching this machine through a **reverse SSH tunnel**. The body is:

```json
{
  "host": "<ssh host alias>",
  "path": "<remote absolute worktree path>",
  "name": "<workspace / desktop name>"
}
```

- `host` — the Remote-SSH host alias docent connects to (e.g. `ubuntu`).
- `path` — the remote folder to open.
- `name` — the virtual-desktop name (Windows) / window label (macOS); also used
  to match an existing window for focus-vs-open.

docent builds the Remote-SSH folder URI as:

```
vscode-remote://ssh-remote+{host}{path}
```

and then **focuses** an existing Cursor window for that workspace, or **opens** a
new one. Because the path arrives in the payload, docent does **not** SSH out to
resolve anything — the sender already knows the remote path.

## Requirements

- **PowerShell 7+** (`pwsh`), cross-platform.
- **Windows:**
  [`VirtualDesktop`](https://github.com/MScholtes/PSVirtualDesktop) module plus
  the bundled Win32 interop:
  ```powershell
  Install-Module VirtualDesktop -Scope CurrentUser
  ```
  `Cursor.exe` is auto-detected at `…\AppData\Local\Programs\cursor\`.
- **macOS:** the `cursor` CLI (or `Cursor.app`) and **Accessibility permission**
  for whatever runs `osascript` (e.g. the terminal / pwsh host), so docent can
  raise windows via System Events.

## Quick start

1. Start the receiver:
   ```bash
   pwsh ./bin/docent.ps1 serve
   ```
   It binds `http://127.0.0.1:39787/` (127.0.0.1 only — never a public
   interface) and logs to stderr.

2. Health check:
   ```bash
   curl http://127.0.0.1:39787/health      # -> ok
   ```

3. Fire an open (normally grove does this):
   ```bash
   curl -X POST http://127.0.0.1:39787/open \
     -H 'content-type: application/json' \
     -d '{"host":"ubuntu","path":"/home/me/Code/salsa/my-feature","name":"my-feature"}'
   ```
   On Windows the new window lands on a virtual desktop named `my-feature`; on
   macOS the window is raised.

## Reverse SSH tunnel

The dev box must reach docent's localhost port. Add a `RemoteForward` to the
**workstation's** `~/.ssh/config` entry for the dev host:

```sshconfig
Host ubuntu
  HostName dev-box.example.com
  User me
  RemoteForward 39787 127.0.0.1:39787
```

Now when you SSH from the workstation to the dev box, the dev box's
`POST 127.0.0.1:39787` is forwarded back to docent on the workstation. (Set
`ExitOnForwardFailure yes` and an `autossh`/keepalive setup if you want the
tunnel to be resilient.)

## Shared secret (optional auth)

The `127.0.0.1` bind keeps docent off the network, but the reverse tunnel
exposes the port to the dev box's loopback — and on Linux every local user can
reach loopback. So on a shared dev box, *any* local process could `POST /open`.

Set a shared secret to require it. When a token is configured, `POST /open`
demands a matching `Authorization: Bearer <token>` header; `GET /health` stays
open for liveness probes. With no token set, docent runs as before and logs a
warning at startup.

Configure the token via the `DOCENT_TOKEN` env var (preferred — keeps it out of
the config file) or a `"token"` field in the config. The env var wins if both
are set.

```bash
# workstation: start docent with a secret
DOCENT_TOKEN='a-long-random-string' pwsh ./bin/docent.ps1 serve

# authenticated open
curl -X POST http://127.0.0.1:39787/open \
  -H 'authorization: Bearer a-long-random-string' \
  -H 'content-type: application/json' \
  -d '{"host":"ubuntu","path":"/home/me/Code/salsa/my-feature","name":"my-feature"}'
```

On the dev box, give grove the same secret via `GROVE_WEBHOOK_TOKEN`; its
`webhook` recipe sends the Bearer header automatically.
Comparison is constant-time, so a wrong token returns `401` without leaking
length/timing.

## Autostart

On Windows, prefer the **Scheduled Task** below: it needs no admin and adds
crash recovery. The Startup-folder `.vbs` is a simpler alternative if you don't
want auto-restart.

**Windows (no admin) — Scheduled Task with watchdog (recommended).** Starts
docent at logon and keeps it alive: a 1-minute repeating trigger re-launches it
if it ever dies, while `MultipleInstances=IgnoreNew` ensures a healthy docent is
never duplicated. (Task Scheduler's built-in *"restart on failure"* is
unreliable and often never fires — the repeating trigger is what actually
works.) Registering a task that runs as *you* needs no elevation.

The action runs the bundled **`bin/serve-hidden.vbs`** launcher via `wscript`,
which starts `docent serve` with **no console window** and *waits* on it. That
matters: a `cmd.exe`/`pwsh.exe` action would leave a console window open the
whole time docent runs (and flash a fresh one on every watchdog-triggered
restart). Because the launcher waits, the task instance stays "running", so the
watchdog skips via `IgnoreNew` instead of stacking duplicates. The launcher
derives the repo paths from its own location, passes `-Config` explicitly (the
task's cwd is not the repo, so otherwise docent silently runs on defaults — no
token, no links), and logs to `%TEMP%\docent.log`. Adjust `pwshPath` inside it
if PowerShell 7 lives elsewhere.

```powershell
$me  = "$env:USERDOMAIN\$env:USERNAME"
$vbs = 'C:\Users\me\Code\docent\bin\serve-hidden.vbs'
$action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument ('"{0}"' -f $vbs)

# At-logon start + a 1-min watchdog that repeats forever.
$tLogon = New-ScheduledTaskTrigger -AtLogOn -User $me
$tWatch = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 1)

# Interactive + limited: docent moves/focuses windows, so it must run in your
# logged-on session (NOT "whether logged on or not"). No time limit; skip a new
# run while one is already going.
$principal = New-ScheduledTaskPrincipal -UserId $me -LogonType Interactive -RunLevel Limited
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -StartWhenAvailable -Hidden

Register-ScheduledTask -TaskName 'docent' -Action $action -Trigger @($tLogon, $tWatch) `
    -Principal $principal -Settings $settings -Force
Start-ScheduledTask -TaskName 'docent'
Invoke-WebRequest http://127.0.0.1:39787/health -UseBasicParsing   # -> 200 ok
```

Manage it:

```powershell
Stop-ScheduledTask    -TaskName docent   # recycle: the watchdog relaunches a fresh process within ~1 min
Disable-ScheduledTask -TaskName docent   # turn OFF autostart + watchdog
Enable-ScheduledTask  -TaskName docent   # turn back on
Unregister-ScheduledTask -TaskName docent -Confirm:$false   # remove entirely
Get-ScheduledTask docent | Get-ScheduledTaskInfo            # last run time / result
```

Notes:

- **Restart after a config/code change:** `Stop-ScheduledTask -TaskName docent`
  — the watchdog brings up a fresh process (with the new config) within a
  minute; use `Stop-…; Start-…` for an instant recycle.
- Because the watchdog keeps docent alive, **don't stop it by killing the PID**
  (it just respawns) — use `Stop-`/`Disable-ScheduledTask`.
- Recovery only happens **while you're logged on** — by design, since docent
  needs your interactive desktop to manage windows.
- Recovery latency is up to ~1 min (the watchdog interval).

**Windows (no admin) — Startup folder launcher (simpler, no auto-restart).**
Drop a `docent.vbs` into your Startup folder (`Win+R` → `shell:startup`) that
runs `serve` with **no console window** and logs to `%TEMP%\docent.log`. Unlike
the task above, this does not restart docent if it crashes.

```vbs
' docent.vbs  -- starts docent serve at login, hidden, no admin.
Set shell = CreateObject("WScript.Shell")
q = Chr(34)
pwshPath   = "C:\Program Files\PowerShell\7\pwsh.exe"
scriptPath = "C:\Users\me\Code\docent\bin\docent.ps1"
configPath = "C:\Users\me\Code\docent\docent.config.jsonc"
logPath    = shell.ExpandEnvironmentStrings("%TEMP%\docent.log")

' Pass -Config EXPLICITLY. The Startup folder is not the repo, so without it
' config discovery falls back to ./docent.config.jsonc relative to the launch
' cwd, finds nothing, and docent silently runs on defaults (no token, no links).
' Doubled outer quotes are the cmd /c idiom for a spaced exe path + redirection.
cmd = "cmd /c " & q & q & pwshPath & q & " -NoLogo -NoProfile -File " & q & scriptPath & q & _
      " serve -Config " & q & configPath & q & " >> " & q & logPath & q & " 2>&1" & q
shell.Run cmd, 0, False   ' 0 = hidden window, False = don't wait
```

Create it from PowerShell (adjust `scriptPath`), then verify:

```powershell
# ...write the .vbs above to:
[Environment]::GetFolderPath('Startup')   # e.g. %APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup
wscript "$([Environment]::GetFolderPath('Startup'))\docent.vbs"   # start it now
Invoke-WebRequest http://127.0.0.1:39787/health -UseBasicParsing  # -> 200 ok
```

To stop it: `Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" | Where CommandLine -match 'docent\.ps1' | % { Stop-Process $_.ProcessId -Force }`.
To disable autostart: delete the `.vbs` from the Startup folder.

> A plain Startup-folder **shortcut** to `pwsh -NoLogo -File <repo>\bin\docent.ps1 serve`
> also works without admin, but flashes a console window at login; the `.vbs`
> avoids that.

**macOS** — a launchd LaunchAgent at `~/Library/LaunchAgents/com.docent.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.docent</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/local/bin/pwsh</string>
    <string>/Users/me/Code/docent/bin/docent.ps1</string>
    <string>serve</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardErrorPath</key><string>/tmp/docent.log</string>
</dict>
</plist>
```

```bash
launchctl load ~/Library/LaunchAgents/com.docent.plist
```

## CLI

`serve` is the primary entrypoint; the other commands drive the same open/focus
logic by hand.

```bash
# Start the webhook receiver (primary).
pwsh ./bin/docent.ps1 serve [-Port 39787] [-Config <path>]

# Open or focus one workspace explicitly (no SSH).
pwsh ./bin/docent.ps1 open -Host ubuntu -Path /home/me/Code/salsa/my-feature -Name my-feature

# Open a URL in a browser window on a named desktop (mainly for testing links).
pwsh ./bin/docent.ps1 open-url -Name my-feature -Url https://example.com/page

# Focus an already-open workspace.
pwsh ./bin/docent.ps1 focus -Path /home/me/Code/salsa/my-feature

# Close a workspace's window(s); on Windows optionally remove the desktop.
pwsh ./bin/docent.ps1 close -Name my-feature -RemoveDesktop

# Show what docent can see (windows; desktops on Windows).
pwsh ./bin/docent.ps1 status
```

Or import the module and call the cmdlets directly:

```powershell
Import-Module ./src/Docent.psd1
Start-DocentServer -Port 39787
Open-DocentWorkspace -Host ubuntu -Path /home/me/Code/salsa/my-feature -Name my-feature
```

Set `DOCENT_LOG_LEVEL=debug` for verbose tracing (all logs go to **stderr**;
command/HTTP results go to **stdout** / the response body).

## Config

`docent serve` runs fine on defaults — **the only thing it needs is a port**.
See [`docent.config.example.jsonc`](./docent.config.example.jsonc) for every
field. Discovery order (first hit wins): `-Config <path>`, `$DOCENT_CONFIG`,
`./docent.config.json(c)`, `$HOME/.config/docent/config.json(c)`.

| Field | Default | Purpose |
| --- | --- | --- |
| `port` | `39787` | localhost port the receiver binds |
| `processName` | `Cursor` | process name used to match windows |
| `cursorExe` | auto | explicit Cursor launcher (Win/macOS) |
| `desktopName` | `{name}` | desktop name (Win) / window label (macOS) |
| `uri` | `vscode-remote://ssh-remote+{host}{path}` | folder URI template |
| `links` | `[]` | companion URLs to open on the same desktop (see [Companion links](#companion-links)) |
| `browserExe` | auto | explicit browser launcher for links (Chrome/Edge/Brave on Win) |
| `browserProcessName` | auto | process name used to match browser windows (Win) |
| `launchTimeoutSec` / `launchRetries` / `launchDelaySec` | `25` / `2` / `2` | Windows folder-uri hang mitigations |

The JSONC loader strips `//` and `/* */` comments and trailing commas while
**preserving string literals**, so `vscode-remote://…` inside `uri` is never
mistaken for a comment.

## Companion links

docent can open **companion URLs on the same virtual desktop** as the Cursor
workspace — e.g. drop the matching issue tracker page next to your editor when a
worktree opens. This needs **no change to the webhook**: the URL is *derived*
from the `name` already in the `{host, path, name}` body. So whatever drives
docent (grove, the CLI, your own script) stays a pure description of the
worktree; the "what else to open on my workstation" policy lives here in config.

Configure a `links` array. Each entry is `{ pattern, url, upper? }`:

- `pattern` — a regex matched (case-insensitively) against `name`.
- `url` — a template where `$1`, `$2`, … are replaced by `pattern`'s capture
  groups (`$0` is the whole match).
- `upper` — when `true`, capture groups are upper-cased before substitution.

```jsonc
"links": [
  { "pattern": "^([a-z]+-\\d+)", "url": "https://jira.example.com/browse/$1", "upper": true }
]
```

With this, a worktree named `salsa-12345-contracts-widget-npe` opens
`https://jira.example.com/browse/SALSA-12345` in a browser window placed on the
`salsa-12345-contracts-widget-npe` desktop. A `name` that matches no `pattern`
behaves exactly as before — no extra window.

Notes:

- **Browser.** The link opens in a new window of the configured `browserExe`
  (auto-detected: Chrome → Edge → Brave on Windows). On Windows docent launches
  `--new-window <url>`, polls for the new window, and moves it onto the desktop.
- **Focus stays on Cursor.** Link windows are *placed* on the desktop but not
  brought to the foreground; docent re-foregrounds the Cursor window after.
- **Focus-or-open.** If a browser window already sits on that desktop, docent
  leaves it in place rather than stacking duplicates (so a re-open won't
  re-navigate an existing link window).
- **macOS** is window-only (no Spaces): the URL simply opens in a new browser
  window with no desktop placement.

## OS backends

docent selects a backend at runtime (`$IsWindows` / `$IsMacOS`). Both implement
the same handler operations (`src/Private/Backend.ps1`):

| Operation | Windows | macOS |
| --- | --- | --- |
| `EnsureWorkspaceTarget(name)` | find/create a virtual desktop | no-op |
| `OpenWindow(uri, leaf)` | launch `Cursor.exe`, poll for HWND | `cursor`/`open`, poll via osascript |
| `FindWindow(leaf)` | host-aware window title match | osascript title match |
| `FocusWindow(handle, name)` | switch desktop + foreground | `AXRaise` + frontmost |
| `PlaceWindow(handle, name)` | move window to desktop | no-op (window-only) |

The Windows backend preserves the original folder-uri hang mitigations:
non-blocking `Start-Process` launch, polling for the new window by title leaf,
and retry with a short delay. macOS is **window-only** — it never creates or
switches Spaces.

## Layout

```
bin/docent.ps1            # CLI dispatcher (serve / open / focus / close / status)
bin/serve-hidden.vbs      # Windows: launch `serve` hidden (no console) for the Scheduled Task
src/Docent.psd1           # module manifest
src/Docent.psm1           # loader (dot-sources Private + Public)
src/Private/
  Logging.ps1             # stderr logging (DOCENT_LOG_LEVEL)
  Config.ps1              # JSONC loader + templating
  Backend.ps1             # runtime OS-backend dispatch
  Backend.macos.ps1       # macOS window control via cursor CLI + osascript
  Desktop.ps1             # Windows virtual-desktop wrappers (VirtualDesktop)
  Window.ps1              # Windows Cursor launch + window matching
  Browser.ps1             # Windows browser launch + window matching (companion links)
  Native.ps1              # Windows Win32 interop (window enumeration/focus)
src/Public/
  Start-DocentServer.ps1  # HttpListener webhook receiver (serve)
  Open-DocentWorkspace.ps1
  Open-DocentUrl.ps1      # open a companion URL on a named desktop
  Focus-DocentWorkspace.ps1
  Close-DocentWorkspace.ps1
  Get-DocentStatus.ps1
```
