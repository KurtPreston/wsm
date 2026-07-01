package main

import "embed"

// powershellFS embeds the PowerShell bridge (wm.ps1 + its dot-sourced
// helpers) so the daemon is a single self-contained binary. go:embed can only
// see files at or below this file's directory, so the embed directive lives
// here (package main) rather than in the windows package; the resulting fs.FS
// is handed to windows.New, which extracts it to a temp dir on first use.
//
//go:embed powershell
var powershellFS embed.FS
