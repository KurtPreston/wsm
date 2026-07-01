package windows

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
	"testing/fstest"

	"github.com/KurtPreston/wsm/libs/webserver"
)

func TestProcessNameDefault(t *testing.T) {
	if got := processName(webserver.IDEProfile{}); got != "Cursor" {
		t.Fatalf("processName(empty) = %q, want %q", got, "Cursor")
	}
	if got := processName(webserver.IDEProfile{Process: "Code"}); got != "Code" {
		t.Fatalf("processName(Code) = %q, want %q", got, "Code")
	}
}

func TestParseResultOK(t *testing.T) {
	res, err := parseResult([]byte(`{"ok":true,"action":"focused","name":"proj"}`))
	if err != nil {
		t.Fatalf("parseResult: %v", err)
	}
	if !res.OK || res.Action != "focused" || res.Name != "proj" {
		t.Fatalf("parseResult = %+v, want ok/focused/proj", res)
	}
}

func TestParseResultNotFound(t *testing.T) {
	_, err := parseResult([]byte(`{"notFound":true}`))
	if !errors.Is(err, webserver.ErrWindowNotFound) {
		t.Fatalf("parseResult notFound: err = %v, want ErrWindowNotFound", err)
	}
}

func TestParseResultInvalidJSON(t *testing.T) {
	if _, err := parseResult([]byte("not json")); err == nil {
		t.Fatal("parseResult(invalid) = nil error, want error")
	}
}

func TestEnsureScriptsExtractsEmbeddedFiles(t *testing.T) {
	fsys := fstest.MapFS{
		"powershell/wm.ps1":      {Data: []byte("# entry point")},
		"powershell/Window.ps1":  {Data: []byte("# window helpers")},
		"powershell/Desktop.ps1": {Data: []byte("# desktop helpers")},
	}
	m := New(fsys)

	dir, err := m.ensureScripts()
	if err != nil {
		t.Fatalf("ensureScripts: %v", err)
	}
	defer os.RemoveAll(dir)

	for _, name := range []string{"wm.ps1", "Window.ps1", "Desktop.ps1"} {
		p := filepath.Join(dir, name)
		if _, err := os.Stat(p); err != nil {
			t.Errorf("expected extracted file %s: %v", p, err)
		}
	}

	// Extraction is memoized; a second call must return the same directory.
	dir2, err := m.ensureScripts()
	if err != nil {
		t.Fatalf("ensureScripts (2nd call): %v", err)
	}
	if dir2 != dir {
		t.Fatalf("ensureScripts not memoized: %q != %q", dir2, dir)
	}
}

func TestPwshPathMissing(t *testing.T) {
	t.Setenv("PATH", "")
	t.Setenv("ProgramFiles", filepath.Join(t.TempDir(), "does-not-exist"))
	if _, err := pwshPath(); err == nil {
		t.Fatal("pwshPath() = nil error, want error when pwsh is unavailable")
	}
}
