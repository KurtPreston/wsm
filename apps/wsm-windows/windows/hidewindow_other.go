//go:build !windows

package windows

import "os/exec"

// hideWindow is a no-op off Windows. It exists so wm.go stays free of build
// tags and keeps cross-compiling and vetting cleanly on CI's Linux runners
// (see the package doc in wm.go).
func hideWindow(cmd *exec.Cmd) {}
