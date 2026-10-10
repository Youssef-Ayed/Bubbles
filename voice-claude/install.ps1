# Adds (or with -Remove, deletes) a Startup shortcut so Voice to Claude runs when you log in.
param([switch]$Remove)
$lnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'Voice to Claude.lnk'
if ($Remove) {
    Remove-Item $lnk -ErrorAction SilentlyContinue
    Write-Host 'Removed the startup shortcut.'
    return
}
$ws = New-Object -ComObject WScript.Shell
$s = $ws.CreateShortcut($lnk)
$s.TargetPath = (Get-Command powershell.exe).Source
$s.Arguments = "-STA -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSScriptRoot\voice-claude.ps1`""
$s.WorkingDirectory = $PSScriptRoot
$s.Save()
Write-Host "Added startup shortcut: $lnk"
