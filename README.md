# remote-cursor-desktops (`rcd`)

A Windows-side tool that manages **one remote Cursor window per workspace, each
pinned to its own named Windows virtual desktop**. It launches `Cursor.exe`
locally on Windows and lets Remote-SSH connect each window to a folder on a
remote host.

The tool has **no git/worktree knowledge baked in**. How a workspace identifier
maps to a remote folder path is *configuration* — a command run over SSH whose
stdout is the folder path. A literal path or any script that prints a path works
identically.

## Requirements

- Native **Windows PowerShell 5.1+** (or PowerShell 7+).
- [`VirtualDesktop`](https://github.com/MScholtes/PSVirtualDesktop) module:
  ```powershell
  Install-Module VirtualDesktop -Scope CurrentUser
  ```
- `Cursor.exe` installed (auto-detected at `…\AppData\Local\Programs\cursor\`).
- **Key-based SSH** to the remote host (the resolver runs non-interactively).

## Setup

1. Copy the example config and edit it:
   ```powershell
   Copy-Item rcd.config.example.jsonc rcd.config.jsonc
   ```
   Or place it at `$HOME\.config\rcd\config.jsonc`, or point `$env:RCD_CONFIG`
   at any path.

2. (Optional) Add `bin\` to your `PATH`, or call the dispatcher directly.

## Usage

```powershell
# Open one workspace: resolve -> ensure desktop -> launch window -> place + switch
./bin/rcd.ps1 open my-feature

# Different project than the config default, don't switch to it
./bin/rcd.ps1 open my-feature -Project salsa -NoSwitch

# Open every workspace returned by the `list` template, one desktop each
./bin/rcd.ps1 open-all

# Jump to a workspace's desktop (and foreground its window)
./bin/rcd.ps1 focus my-feature

# Close a workspace's window(s); optionally remove the desktop too
./bin/rcd.ps1 close my-feature -RemoveDesktop

# Show ref -> desktop -> window mapping
./bin/rcd.ps1 status
```

Or import the module and call the cmdlets directly:

```powershell
Import-Module ./src/RemoteCursorDesktops.psd1
Open-RcdWorkspace -Ref my-feature
```

Set `RCD_LOG_LEVEL=debug` for verbose tracing (all logs go to **stderr**;
command results go to **stdout**).

## Config

See [`rcd.config.example.jsonc`](./rcd.config.example.jsonc) for every field and
its default. Required fields: `host`, `resolve`. Templates support `{host}`,
`{project}`, `{ref}`, and (for `uri`) `{path}`.

## Status / the folder-uri no-op

Validated on real Windows hardware (Windows 11, PowerShell 7) against a Linux
remote. The headline risk — the
[`--folder-uri vscode-remote://` no-op](https://forum.cursor.com/t/remote-workspace-folder-uri-vscode-remote-does-nothing-script-hangs-when-cursor-already-open/153009)
when a Cursor instance is already running — was reproduced and fixed:

- **Reproduced:** re-opening a workspace that is *already open* makes
  `--new-window --folder-uri <same folder>` a no-op. Cursor just refocuses the
  existing window; no new window is ever created, so new-window polling waits
  out the full timeout on every retry and then fails.
- **Fix — idempotent adopt:** before launching, `open` checks for an existing
  window for that workspace (host-aware title match) and, if present, adopts it
  (moves it to the named desktop + focuses) instead of trying to spawn a
  duplicate Cursor refuses to create. Opening a *new* folder still launches
  normally.

Launch of a genuinely-new window is still made robust by:

- non-blocking launch via `Start-Process` (won't hang the script),
- polling for the **new** window whose title matches the workspace,
- retry with a short delay (`launchRetries` / `launchDelaySec`).

Because adoption handles the already-open case directly, the previously-planned
`--file-uri`/`.code-workspace` and kill-relaunch fallbacks proved unnecessary.

## Layout

```
bin/rcd.ps1                     # CLI dispatcher
src/RemoteCursorDesktops.psd1   # module manifest
src/RemoteCursorDesktops.psm1   # loader (dot-sources Private + Public)
src/Private/                    # Logging, Native interop, Config, Resolver, Desktop, Window
src/Public/                     # Open/Open-All/Focus/Close/Status cmdlets
```
