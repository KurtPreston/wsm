//go:build windows

package windows

import (
	"os/exec"
	"syscall"
)

// createNoWindow is CREATE_NO_WINDOW: run the child console process without
// allocating a console. wsm-windows.exe ships built for the GUI subsystem
// (-H windowsgui), so it has no console of its own; without this flag each
// pwsh child would allocate — and briefly flash — its own console window.
const createNoWindow = 0x08000000

// hideWindow configures cmd so the child pwsh process runs headless.
//
// Deliberately only CreationFlags, NOT SysProcAttr.HideWindow: HideWindow sets
// STARTF_USESHOWWINDOW|SW_HIDE in the startup info, which Electron apps (Cursor)
// inherit and honor — so wm.ps1 would launch Cursor *hidden* and then time out
// polling for a visible window. CREATE_NO_WINDOW suppresses only the pwsh
// console and leaves grandchild GUI windows visible.
func hideWindow(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{CreationFlags: createNoWindow}
}
