// Package windows implements the wsm WindowManager on Windows by shelling out
// to a bundled PowerShell entry script (wm.ps1) that drives window
// enumeration, launching, and virtual-desktop placement via the Win32 API and
// the VirtualDesktop module. No OS build tags are used so the package (and
// apps/wsm-windows) keeps cross-compiling and vetting cleanly on CI's Linux
// runners; the pwsh invocations only need to actually succeed on Windows.
package windows

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/KurtPreston/wsm/libs/api"
	"github.com/KurtPreston/wsm/libs/webserver"
)

// notFoundExitCode is wm.ps1's exit code signaling "no matching window" for
// -Action focus; the Manager maps it to webserver.ErrWindowNotFound.
const notFoundExitCode = 44

// scriptTimeout bounds a single wm.ps1 invocation (list/open/focus). Open is
// the slowest path (it may launch Cursor and poll for its window), so this
// must comfortably exceed wm.ps1's own launch-retry budget.
const scriptTimeout = 60 * time.Second

// scriptsSubdir is the embedded root passed by apps/wsm-windows (see embed.go).
const scriptsSubdir = "powershell"

// Manager is the Windows WindowManager implementation.
type Manager struct {
	fsys fs.FS

	extractOnce sync.Once
	scriptDir   string
	extractErr  error
}

// New returns a Windows Manager that, on first use, extracts the PowerShell
// scripts embedded at "powershell" within fsys to a temp directory and
// invokes them there with pwsh.
func New(fsys fs.FS) *Manager {
	return &Manager{fsys: fsys}
}

var _ webserver.WindowManager = (*Manager)(nil)

// List enumerates windows of the profile's process.
func (m *Manager) List(ctx context.Context, profile webserver.IDEProfile) ([]api.Window, error) {
	args := []string{"-Action", "list", "-Process", processName(profile)}
	if profile.Exe != "" {
		args = append(args, "-Exe", profile.Exe)
	}
	out, err := m.run(ctx, args)
	if err != nil {
		return nil, err
	}
	var resp api.WindowsResponse
	if err := json.Unmarshal(out, &resp); err != nil {
		return nil, fmt.Errorf("parse wm.ps1 list output: %w", err)
	}
	return resp.Windows, nil
}

// Open launches (or adopts) the IDE window at the resolved URI, places it on
// a virtual desktop named after the workspace, and foregrounds it.
func (m *Manager) Open(ctx context.Context, cmd webserver.OpenCommand) (api.Result, error) {
	args := []string{"-Action", "open", "-Process", processName(cmd.Profile), "-Uri", cmd.URI, "-Name", cmd.Name}
	if cmd.Profile.Exe != "" {
		args = append(args, "-Exe", cmd.Profile.Exe)
	}
	if cmd.Host != "" {
		args = append(args, "-RemoteHost", cmd.Host)
	}
	out, err := m.run(ctx, args)
	if err != nil {
		return api.Result{}, err
	}
	return parseResult(out)
}

// Focus switches to the window's desktop (or the one named after it) and
// raises it. Returns webserver.ErrWindowNotFound when nothing matches.
func (m *Manager) Focus(ctx context.Context, cmd webserver.FocusCommand) (api.Result, error) {
	args := []string{"-Action", "focus", "-Process", processName(cmd.Profile)}
	if cmd.Profile.Exe != "" {
		args = append(args, "-Exe", cmd.Profile.Exe)
	}
	if cmd.Name != "" {
		args = append(args, "-Name", cmd.Name)
	}
	if cmd.ID != "" {
		args = append(args, "-Id", cmd.ID)
	}
	if cmd.Host != "" {
		args = append(args, "-RemoteHost", cmd.Host)
	}
	out, err := m.run(ctx, args)
	if err != nil {
		return api.Result{}, err
	}
	return parseResult(out)
}

func processName(p webserver.IDEProfile) string {
	if p.Process != "" {
		return p.Process
	}
	return "Cursor"
}

// scriptResult overlays wm.ps1's {ok,action,name} result with its
// {notFound:true} not-found signal, so a single decode covers both shapes.
type scriptResult struct {
	api.Result
	NotFound bool `json:"notFound,omitempty"`
}

func parseResult(out []byte) (api.Result, error) {
	var res scriptResult
	if err := json.Unmarshal(out, &res); err != nil {
		return api.Result{}, fmt.Errorf("parse wm.ps1 result: %w", err)
	}
	if res.NotFound {
		return api.Result{}, webserver.ErrWindowNotFound
	}
	return res.Result, nil
}

// run extracts the embedded scripts (once) and invokes wm.ps1 with args,
// returning its stdout. stderr is logged line-by-line via the daemon's
// logger. A non-zero exit maps to an error, except notFoundExitCode which
// maps to webserver.ErrWindowNotFound regardless of the action (only
// -Action focus is expected to produce it).
func (m *Manager) run(ctx context.Context, args []string) ([]byte, error) {
	dir, err := m.ensureScripts()
	if err != nil {
		return nil, err
	}
	pwsh, err := pwshPath()
	if err != nil {
		return nil, err
	}

	ctx, cancel := context.WithTimeout(ctx, scriptTimeout)
	defer cancel()

	script := filepath.Join(dir, "wm.ps1")
	fullArgs := append([]string{"-NoLogo", "-NoProfile", "-File", script}, args...)

	cmd := exec.CommandContext(ctx, pwsh, fullArgs...)
	hideWindow(cmd) // keep the pwsh child headless (no console flash on Windows)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	runErr := cmd.Run()
	logStderr(stderr.Bytes())

	if runErr != nil {
		var exitErr *exec.ExitError
		if errors.As(runErr, &exitErr) && exitErr.ExitCode() == notFoundExitCode {
			return nil, webserver.ErrWindowNotFound
		}
		if ctx.Err() == context.DeadlineExceeded {
			return nil, fmt.Errorf("wm.ps1 %v timed out after %s", args, scriptTimeout)
		}
		return nil, fmt.Errorf("wm.ps1 %v: %w", args, runErr)
	}
	return stdout.Bytes(), nil
}

func logStderr(b []byte) {
	sc := bufio.NewScanner(bytes.NewReader(b))
	for sc.Scan() {
		if line := sc.Text(); line != "" {
			log.Printf("wsm-windows: %s", line)
		}
	}
}

// pwshPath prefers pwsh on PATH, falling back to the standard per-machine
// install location for PowerShell 7.
func pwshPath() (string, error) {
	if p, err := exec.LookPath("pwsh"); err == nil {
		return p, nil
	}
	if pf := os.Getenv("ProgramFiles"); pf != "" {
		if p := filepath.Join(pf, "PowerShell", "7", "pwsh.exe"); fileExists(p) {
			return p, nil
		}
	}
	return "", errors.New("pwsh (PowerShell 7) not found on PATH; install it or add it to PATH")
}

func fileExists(p string) bool {
	info, err := os.Stat(p)
	return err == nil && !info.IsDir()
}

// ensureScripts extracts the embedded powershell/ tree to a temp directory on
// first use and returns its path on every call thereafter.
func (m *Manager) ensureScripts() (string, error) {
	m.extractOnce.Do(func() {
		dir, err := os.MkdirTemp("", "wsm-windows-ps-*")
		if err != nil {
			m.extractErr = fmt.Errorf("create temp dir for powershell scripts: %w", err)
			return
		}
		if err := extractFS(m.fsys, scriptsSubdir, dir); err != nil {
			m.extractErr = fmt.Errorf("extract powershell scripts: %w", err)
			return
		}
		m.scriptDir = dir
	})
	return m.scriptDir, m.extractErr
}

// extractFS copies every file under root in fsys into destDir, preserving
// relative structure. root and fs.WalkDir's name always use forward slashes
// (the fs.FS convention, regardless of host OS); destDir is a native path.
func extractFS(fsys fs.FS, root, destDir string) error {
	return fs.WalkDir(fsys, root, func(name string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			return nil
		}
		rel := strings.TrimPrefix(name, root+"/")
		data, err := fs.ReadFile(fsys, name)
		if err != nil {
			return err
		}
		dest := filepath.Join(destDir, filepath.FromSlash(rel))
		if err := os.MkdirAll(filepath.Dir(dest), 0o755); err != nil {
			return err
		}
		return os.WriteFile(dest, data, 0o644)
	})
}
