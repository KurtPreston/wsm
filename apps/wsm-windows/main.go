// Command wsm-windows is the Windows workspace-management daemon (wsmd).
//
// It serves the wsm workspace-management API and drives Cursor/VSCode windows
// (and virtual desktops) by shelling out to the bundled PowerShell helpers in
// ./powershell. The HTTP layer, auth, and mode enforcement are provided by
// libs/webserver; this binary supplies the Windows WindowManager implementation.
// Wired up in a later phase.
package main

func main() {}
