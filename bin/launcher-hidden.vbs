' launcher-hidden.vbs -- start the docent launcher with NO visible console
' window. The launcher is a resident WPF app that registers a global hotkey
' (default Ctrl+Alt+Space) and stays hidden until summoned, so this wrapper just
' needs to spawn it once per logon without flashing a console.
'
' Intended as a Startup-folder item (Win+R -> shell:startup) so the hotkey is
' live at every logon. wscript itself is windowless; it launches pwsh hidden
' (window style 0) and does NOT wait (third arg False) so this process exits
' immediately while the launcher keeps running detached in the interactive
' session (required for a GUI hotkey window).
'
' Paths are derived from this script's own location: <repo>\bin\launcher-hidden.vbs
'   scriptPath = <repo>\launcher\docent-launcher.ps1
'   configPath = <repo>\docent.config.jsonc
' Adjust pwshPath if PowerShell 7 is installed elsewhere; set hotkey below.

Set fso   = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")
q = Chr(34)

binDir     = fso.GetParentFolderName(WScript.ScriptFullName)
repoRoot   = fso.GetParentFolderName(binDir)
pwshPath   = "C:\Program Files\PowerShell\7\pwsh.exe"
scriptPath = fso.BuildPath(repoRoot, "launcher\docent-launcher.ps1")
configPath = fso.BuildPath(repoRoot, "docent.config.jsonc")
hotkey     = "Ctrl+Alt+Space"
logPath    = shell.ExpandEnvironmentStrings("%TEMP%\docent-launcher.log")

' Run under cmd so cmd's 2>&1 captures the launcher's stderr into the log. The
' doubled outer quotes are the cmd /c idiom for a spaced exe path + redirection.
cmd = "cmd /c " & q & q & pwshPath & q & " -NoLogo -NoProfile -File " & q & scriptPath & q & _
      " -Hotkey " & q & hotkey & q & " -Config " & q & configPath & q & _
      " >> " & q & logPath & q & " 2>&1" & q

shell.Run cmd, 0, False   ' 0 = hidden window, False = don't wait (launcher stays resident)
