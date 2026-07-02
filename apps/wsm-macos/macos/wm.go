// Package macos implements the wsm WindowManager on macOS via AppleScript
// (osascript) and the IDE's CLI/app launcher. It manages window focus only;
// macOS Spaces are never created or switched.
package macos

import (
	"context"
	"fmt"
	"os/exec"
	"strings"
	"time"

	"github.com/KurtPreston/wsm/libs/api"
	"github.com/KurtPreston/wsm/libs/webserver"
)

// Manager is the macOS WindowManager implementation.
type Manager struct{}

// New returns a macOS Manager.
func New() *Manager { return &Manager{} }

var _ webserver.WindowManager = (*Manager)(nil)

// List enumerates windows of the profile's process.
func (m *Manager) List(_ context.Context, profile webserver.IDEProfile) ([]api.Window, error) {
	proc := processName(profile)
	titles, err := listWindowTitles(proc)
	if err != nil {
		return nil, err
	}
	wins := make([]api.Window, 0, len(titles))
	for i, title := range titles {
		leaf, host := parseCursorTitle(title)
		id := leaf
		if id == "" {
			id = fmt.Sprintf("win-%d", i)
		}
		wins = append(wins, api.Window{ID: id, Title: title, App: proc, Host: host})
	}
	return wins, nil
}

// Open launches the IDE at the resolved URI and returns immediately. Focus runs
// in the background so HTTP callers (e.g. grove's webhook) are not blocked.
func (m *Manager) Open(_ context.Context, cmd webserver.OpenCommand) (api.Result, error) {
	if err := launchWorkspace(cmd.Profile, cmd.URI); err != nil {
		return api.Result{}, err
	}
	proc := processName(cmd.Profile)
	leaf := cmd.Name
	go focusWorkspaceWhenReady(proc, leaf)
	return api.Result{OK: true, Action: "opened", Name: cmd.Name}, nil
}

// OpenURL opens a URL in a browser window (window-only on macOS) and
// best-effort re-foregrounds the IDE workspace window named by cmd.Name.
func (m *Manager) OpenURL(_ context.Context, cmd webserver.OpenURLCommand) (api.Result, error) {
	if err := openBrowser(cmd.BrowserExe, cmd.URL); err != nil {
		return api.Result{}, err
	}
	proc := processName(cmd.Profile)
	_, _ = focusWindow(proc, cmd.Name)
	return api.Result{OK: true, Action: "opened", Name: cmd.Name}, nil
}

// Focus raises a window whose title contains the target name (or id).
func (m *Manager) Focus(_ context.Context, cmd webserver.FocusCommand) (api.Result, error) {
	target := cmd.Name
	if target == "" {
		target = cmd.ID
	}
	found, err := focusWindow(processName(cmd.Profile), target)
	if err != nil {
		return api.Result{}, err
	}
	if !found {
		return api.Result{}, fmt.Errorf("%w for %q", webserver.ErrWindowNotFound, target)
	}
	return api.Result{OK: true, Action: "focused", Name: target}, nil
}

func processName(p webserver.IDEProfile) string {
	if p.Process != "" {
		return p.Process
	}
	return "Cursor"
}

func escapeAppleScript(s string) string {
	s = strings.ReplaceAll(s, `\`, `\\`)
	s = strings.ReplaceAll(s, `"`, `\"`)
	return s
}

func runOsascript(script string) (string, error) {
	cmd := exec.Command("osascript", "-e", script)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("osascript: %w: %s", err, strings.TrimSpace(string(out)))
	}
	return strings.TrimSpace(string(out)), nil
}

func listWindowTitles(proc string) ([]string, error) {
	script := fmt.Sprintf(`
set titles to {}
tell application "System Events"
  repeat with p in (every process whose name is "%s")
    repeat with w in (windows of p)
      set end of titles to (name of w)
    end repeat
  end repeat
end tell
set AppleScript's text item delimiters to linefeed
return titles as text
`, escapeAppleScript(proc))
	out, err := runOsascript(script)
	if err != nil {
		return nil, err
	}
	if out == "" {
		return nil, nil
	}
	var titles []string
	for _, line := range strings.Split(out, "\n") {
		if line = strings.TrimSpace(line); line != "" {
			titles = append(titles, line)
		}
	}
	return titles, nil
}

// focusWindow raises the first window of proc whose title contains leaf.
// It returns (matched, error).
func focusWindow(proc, leaf string) (bool, error) {
	script := fmt.Sprintf(`
tell application "System Events"
  repeat with p in (every process whose name is "%s")
    repeat with w in (windows of p)
      if (name of w) contains "%s" then
        perform action "AXRaise" of w
        set frontmost of p to true
        return "1"
      end if
    end repeat
  end repeat
end tell
return "0"
`, escapeAppleScript(proc), escapeAppleScript(leaf))
	out, err := runOsascript(script)
	if err != nil {
		return false, err
	}
	return out == "1", nil
}

// launchWorkspace starts the IDE with the resolved folder URI, using the
// profile's explicit exe when set, else the IDE CLI on PATH, else `open -na`.
func launchWorkspace(profile webserver.IDEProfile, uri string) error {
	args := launchArgs(profile, uri)
	proc := processName(profile)

	switch {
	case profile.Exe != "":
		return exec.Command(profile.Exe, args...).Start()
	default:
		if path, err := exec.LookPath(cliName(proc)); err == nil {
			return exec.Command(path, args...).Start()
		}
		openArgs := append([]string{"-na", appName(proc), "--args"}, args...)
		return exec.Command("open", openArgs...).Start()
	}
}

// focusWorkspaceWhenReady polls until a window title contains leaf, then raises it.
func focusWorkspaceWhenReady(proc, leaf string) {
	const (
		openPollInterval = 200 * time.Millisecond
		openPollMax      = 25 * time.Second
	)
	deadline := time.Now().Add(openPollMax)
	for time.Now().Before(deadline) {
		if titles, _ := listWindowTitles(proc); len(titles) > 0 {
			for _, t := range titles {
				if strings.Contains(t, leaf) {
					_, _ = focusWindow(proc, leaf)
					return
				}
			}
		}
		time.Sleep(openPollInterval)
	}
}

// openBrowser launches a URL in a new browser window. When browserExe is set
// it is used via `open -na`; otherwise the system default browser is used.
func openBrowser(browserExe, url string) error {
	if browserExe != "" {
		return exec.Command("open", "-na", browserExe, "--args", "--new-window", url).Start()
	}
	return exec.Command("open", url).Start()
}

func launchArgs(profile webserver.IDEProfile, uri string) []string {
	tmpl := profile.LaunchArgs
	if len(tmpl) == 0 {
		tmpl = []string{"--new-window", "--folder-uri", "{uri}"}
	}
	out := make([]string, len(tmpl))
	for i, a := range tmpl {
		out[i] = strings.ReplaceAll(a, "{uri}", uri)
	}
	return out
}

// cliName maps a process name to its on-PATH CLI launcher.
func cliName(proc string) string {
	switch proc {
	case "Cursor":
		return "cursor"
	case "Code":
		return "code"
	default:
		return strings.ToLower(proc)
	}
}

// appName maps a process name to its .app bundle name for `open -na`.
func appName(proc string) string {
	switch proc {
	case "Code":
		return "Visual Studio Code"
	default:
		return proc
	}
}

// parseCursorTitle extracts the workspace leaf and optional SSH host from an
// IDE window title such as "file.ts - my-feature - Cursor" or
// "my-feature [SSH: devbox] - Cursor".
func parseCursorTitle(title string) (leaf, host string) {
	title = strings.TrimSpace(title)
	if title == "" {
		return "", ""
	}
	const marker = "[SSH:"
	if idx := strings.Index(title, marker); idx >= 0 {
		if end := strings.Index(title[idx:], "]"); end > 0 {
			host = strings.TrimSpace(title[idx+len(marker) : idx+end])
			pre := strings.TrimSpace(title[:idx])
			parts := strings.Split(pre, " - ")
			leaf = strings.TrimSpace(parts[len(parts)-1])
			return leaf, host
		}
	}
	core := strings.TrimSuffix(title, " - Cursor")
	parts := strings.Split(core, " - ")
	leaf = strings.TrimSpace(parts[len(parts)-1])
	if leaf == "Cursor" {
		leaf = ""
	}
	return leaf, host
}
