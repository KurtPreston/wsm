' serve-hidden.vbs -- launch `docent serve` with NO visible console window and
' block until it exits. Intended as the *action* for the docent Scheduled Task:
' wscript itself is windowless, and it runs the cmd/pwsh pipeline hidden (window
' style 0) while WAITING on it (third arg True), so this process stays alive for
' docent's whole lifetime. That keeps the task instance "running", which lets the
' task's 1-minute watchdog trigger skip via MultipleInstances=IgnoreNew instead
' of stacking duplicates -- and when docent dies, this exits so the watchdog can
' relaunch it. (Running cmd.exe directly as the task action flashes/holds a
' console window every time; this avoids that entirely.)
'
' Paths are derived from this script's own location: <repo>\bin\serve-hidden.vbs
'   scriptPath = <repo>\bin\docent.ps1
'   configPath = <repo>\docent.config.jsonc
' Adjust pwshPath if PowerShell 7 is installed elsewhere.

Set fso   = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")
q = Chr(34)

binDir     = fso.GetParentFolderName(WScript.ScriptFullName)
repoRoot   = fso.GetParentFolderName(binDir)
pwshPath   = "C:\Program Files\PowerShell\7\pwsh.exe"
scriptPath = fso.BuildPath(binDir, "docent.ps1")
configPath = fso.BuildPath(repoRoot, "docent.config.jsonc")
logPath    = shell.ExpandEnvironmentStrings("%TEMP%\docent.log")

' Run under cmd so cmd's 2>&1 captures docent's native stderr into the log. The
' doubled outer quotes are the cmd /c idiom for a spaced exe path + redirection.
cmd = "cmd /c " & q & q & pwshPath & q & " -NoLogo -NoProfile -File " & q & scriptPath & q & _
      " serve -Config " & q & configPath & q & " >> " & q & logPath & q & " 2>&1" & q

shell.Run cmd, 0, True   ' 0 = hidden window, True = WAIT until docent exits
