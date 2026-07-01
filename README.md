# wsm — workspace-management API

**wsm** is a small, cross-platform daemon (`wsmd`) that exposes a
workspace-management API: clients can **open**, **focus**, and **list**
workspaces (IDE windows) on the machine where it runs. Which IDE is opened and
how is **config-driven** — the out-of-the-box profiles target **Cursor** and
**VSCode**.

It is the *receiver* half of a loosely-coupled setup: senders such as
[grove](https://github.com/KurtPreston/grove) and
[docent](https://github.com/KurtPreston/docent) call the API to bring the right
remote workspace up on your workstation. The only contract is the OpenAPI spec
in [`openapi/v1/openapi.yaml`](./openapi/v1/openapi.yaml).

```
 dev box (grove / docent)                     workstation (wsmd)
 ────────────────────────                      ──────────────────────
 POST /open  ───────► 127.0.0.1:39788 ──┐
 {host,path,name}                        │  reverse SSH tunnel
                                         └─► 127.0.0.1:39788  wsmd
                                                    │
                                                    ▼
                            open-or-focus a workspace window
                            (Windows: on a named virtual desktop;
                             macOS: window raised, no Spaces)
```

## Architecture

`wsmd` is a Go binary per platform. A shared library owns everything
transport/security related; each app supplies only the platform-specific window
control.

- [`libs/webserver`](./libs/webserver) — routing, Bearer auth, CORS, TLS, and
  mode enforcement. Defines the `WindowManager` interface the apps implement.
- [`libs/api`](./libs/api) — the Go mirror of the OpenAPI wire types.
- [`libs/wmclient`](./libs/wmclient) — the canonical Go client (used by grove/docent).
- [`apps/wsm-macos`](./apps/wsm-macos) — window ops via AppleScript (osascript).
- [`apps/wsm-windows`](./apps/wsm-windows) — a Go daemon that shells out to the
  bundled PowerShell helpers for window + virtual-desktop control.

## API

See [`openapi/v1/openapi.yaml`](./openapi/v1/openapi.yaml) for the authoritative
contract. Every endpoint except `GET /health` requires a Bearer token.

| Method + path | Auth | Purpose |
| --- | --- | --- |
| `GET /health` | none | liveness probe (returns `ok`) |
| `GET /windows` | token | list open workspace windows |
| `POST /open` | token | open (or adopt) a workspace: `{host, path, name?, uri?}` |
| `POST /focus` | token | focus an existing window: `{id?, name?, host?}` (404 if none) |

## Modes

`wsmd` runs in one of three modes (set `mode` in config):

- **local** — binds `127.0.0.1`, plain HTTP, Bearer token required.
- **ssh** — binds `127.0.0.1`, reached via an SSH reverse tunnel, token required.
- **network** — configurable bind, **HTTPS required** (`tls.cert`/`tls.key`),
  explicit opt-in. The server refuses to start on a non-loopback bind unless it
  is in network mode with TLS.

A token is **required in all modes**. Prefer the `$WSM_TOKEN` env var (keeps the
secret out of the config file); it overrides the config `token`.

## Config

`wsmd` reads a JSONC config. Discovery order (first hit wins): `-config <path>`,
`$WSM_CONFIG`, `./wsm.config.json(c)`, `$HOME/.config/wsm/config.json(c)`. See
[`config/wsm.config.example.jsonc`](./config/wsm.config.example.jsonc).

### Config-driven IDE opening

`POST /open` behavior comes from the selected IDE **profile**, not hardcoded
logic. `cursor` and `vscode` ship out of the box (see
[`config/profiles/`](./config/profiles)); add or override entries under
`profiles`. The folder URI is built from `remoteUri` when a `host` is present,
else `localUri` (a client-supplied `uri` overrides both); `{uri}` in
`launchArgs` is replaced with the result.

```jsonc
"profiles": {
  "cursor": {
    "process": "Cursor",
    "exe": "",                       // "" = per-OS auto-detection
    "launchArgs": ["--new-window", "--folder-uri", "{uri}"],
    "localUri":  "file://{path}",
    "remoteUri": "vscode-remote://ssh-remote+{host}{path}"
  }
}
```

## Quick start

```bash
# build + run locally (needs a token in config or $WSM_TOKEN)
go run ./apps/wsm-macos   -config ./wsm.config.jsonc     # macOS
go run ./apps/wsm-windows -config ./wsm.config.jsonc     # Windows

# health check
curl http://127.0.0.1:39788/health      # -> ok

# open a remote workspace (normally grove/docent does this)
curl -X POST http://127.0.0.1:39788/open \
  -H 'authorization: Bearer <token>' \
  -H 'content-type: application/json' \
  -d '{"host":"devbox","path":"/home/me/Code/proj","name":"proj"}'
```

## Reverse SSH tunnel (ssh mode)

The dev box reaches `wsmd`'s loopback port through a reverse tunnel. In the
**workstation's** `~/.ssh/config` for the dev host:

```sshconfig
Host devbox
  HostName dev-box.example.com
  User me
  RemoteForward 39788 127.0.0.1:39788
```

Now the dev box's `POST 127.0.0.1:39788` is forwarded back to `wsmd`.

## Install / autostart

- **macOS** — `scripts/install-macos.sh` builds the binary and registers a
  launchd LaunchAgent (`com.wsm.wsmd`).
- **Windows** — `scripts/install-windows.ps1` builds the binary and registers a
  Scheduled Task (`wsmd`) that runs at logon with a watchdog. Requires the
  [`VirtualDesktop`](https://github.com/MScholtes/PSVirtualDesktop) module. The
  binary is built for the GUI subsystem (`-ldflags -H=windowsgui`) so it runs
  **headless** — no console window when the task launches it at logon. Because
  that discards stderr, the task passes `-log`, so the daemon writes to
  `%LOCALAPPDATA%\wsm\wsmd.log` (which also captures the PowerShell helpers'
  output). A plain `go build`/`go run` keeps the console so you still get live
  logs while developing.

## Repo layout

```
openapi/v1/openapi.yaml       # OpenAPI 3.1 contract (source of truth)
apps/wsm-macos/               # Go daemon: AppleScript window ops
apps/wsm-windows/             # Go daemon: shells out to PowerShell helpers
libs/webserver/               # shared HTTP layer: modes, auth, TLS, router, iface
libs/api/                     # request/response types matching the spec
libs/wmclient/                # Go client used by grove/docent
config/                       # example config + out-of-box IDE profiles
scripts/                      # install-macos.sh, install-windows.ps1
```

## Development

```bash
go build ./apps/...        # build both daemons
go test ./...              # unit + OpenAPI contract tests
go vet ./...
```

The contract test in `libs/webserver` validates live responses against
`openapi/v1/openapi.yaml`, so the server can never silently drift from the spec.
