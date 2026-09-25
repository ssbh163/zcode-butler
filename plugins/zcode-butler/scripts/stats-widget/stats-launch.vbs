' stats-launch.vbs (v0.2.0): node-spawned children die with the caller's Job in
' hook/exec environments (kill-on-job-close; powershell exits 0 without running).
' Routing through wscript + WScript.Shell.Run (ShellExecute) escapes the Job,
' same chain as widget/widget-launch.vbs. See repo dev-log v0.2.0.
CreateObject("WScript.Shell").Run "powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & Replace(WScript.ScriptFullName, "stats-launch.vbs", "stats-widget.ps1") & """", 0, False
