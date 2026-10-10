# Sets Bubbles up for this Windows user:
#   1. compiles hook.cs into bubbles-hook.exe (uses the C# compiler that ships with Windows)
#   2. adds that hook to Claude Code's hooks in ~/.claude/settings.json (a backup is saved first)
#   3. adds a Startup shortcut so Bubbles runs when you log in
# Run with -Remove to undo all three. Run again any time; it never adds anything twice.
param([switch]$Remove, [switch]$NoStartup, [string]$SettingsFile = '')
$ErrorActionPreference = 'Stop'

$hookExe  = Join-Path $PSScriptRoot 'bubbles-hook.exe'
$settings = $(if ($SettingsFile) { $SettingsFile } else { Join-Path $env:USERPROFILE '.claude\settings.json' })
$startup  = [Environment]::GetFolderPath('Startup')
$lnk      = Join-Path $startup 'Bubbles.lnk'
$events   = 'SessionStart', 'SessionEnd', 'UserPromptSubmit', 'PreToolUse', 'PostToolUse', 'PostToolUseFailure',
            'PermissionRequest', 'Notification', 'Stop', 'StopFailure'

function Save-Json($obj, $path) {
    # Claude Code reads this file with a strict JSON parser: write UTF-8 without a BOM
    [IO.File]::WriteAllText($path, ($obj | ConvertTo-Json -Depth 32), (New-Object Text.UTF8Encoding $false))
}

function Update-Hooks([bool]$add) {
    $j = [pscustomobject]@{}
    if (Test-Path $settings) {
        $text = [IO.File]::ReadAllText($settings)
        if ($text.Trim()) { $j = $text | ConvertFrom-Json }
        Copy-Item $settings "$settings.bubbles-backup" -Force
    } else {
        New-Item -ItemType Directory -Force (Split-Path $settings) | Out-Null
    }
    if (-not $j.PSObject.Properties['hooks']) { $j | Add-Member hooks ([pscustomobject]@{}) }
    $cmd = '"' + ($hookExe -replace '\\', '/') + '"'
    $names = @($events) + @($j.hooks.PSObject.Properties.Name) | Select-Object -Unique
    foreach ($ev in $names) {
        $groups = @()
        if ($j.hooks.PSObject.Properties[$ev]) {
            # drop any earlier Bubbles entry, keep everything else as it was
            foreach ($g in @($j.hooks.$ev)) {
                $keep = @($g.hooks | Where-Object { [string]$_.command -notmatch 'bubbles-hook\.exe' })
                if ($keep.Count -gt 0) { $g.hooks = $keep; $groups += $g }
            }
        }
        if ($add -and $ev -in $events) {
            $groups += [pscustomobject]@{ hooks = @([pscustomobject]@{ type = 'command'; command = $cmd; timeout = 10 }) }
        }
        if ($groups.Count -gt 0) { $j.hooks | Add-Member $ev $groups -Force }
        elseif ($j.hooks.PSObject.Properties[$ev]) { $j.hooks.PSObject.Properties.Remove($ev) }
    }
    Save-Json $j $settings
}

if ($Remove) {
    Update-Hooks $false
    if (Test-Path $lnk) { Remove-Item $lnk }
    Write-Host 'Removed the Bubbles hooks and the startup shortcut.'
    Write-Host 'Delete bubbles-hook.exe yourself once Bubbles is closed.'
    return
}

Add-Type -TypeDefinition ([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'hook.cs'))) -OutputAssembly $hookExe -OutputType ConsoleApplication
Write-Host "Built $hookExe"

Update-Hooks $true
Write-Host "Added the Bubbles hook to $settings (backup: settings.json.bubbles-backup)"

if (-not $NoStartup) {
    $ws = New-Object -ComObject WScript.Shell
    $s = $ws.CreateShortcut($lnk)
    $s.TargetPath = (Get-Command powershell.exe).Source
    $s.Arguments = "-STA -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSScriptRoot\bubbles.ps1`""
    $s.WorkingDirectory = $PSScriptRoot
    $s.Save()
    Write-Host "Added startup shortcut: $lnk"
}
Write-Host 'Done. Start it now with start-bubbles.cmd. If a Claude Code session that was already open shows no live status, restart it.'
