# Sets Bubbles up for this Windows user:
#   1. compiles hook.cs into bubbles-hook.exe (uses the C# compiler that ships with Windows)
#   2. adds that hook to Claude Code's hooks in ~/.claude/settings.json (a backup is saved first)
#   3. adds Bubbles shortcuts: Start menu and desktop (with its own icon), and Startup so it runs at login
# Run with -Remove to undo all of it. Run again any time; it never adds anything twice.
param([switch]$Remove, [switch]$NoStartup, [switch]$NoDesktop, [string]$SettingsFile = '')
$ErrorActionPreference = 'Stop'

$hookExe  = Join-Path $PSScriptRoot 'bubbles-hook.exe'
$icon     = Join-Path $PSScriptRoot 'bubbles.ico'
$settings = $(if ($SettingsFile) { $SettingsFile } else { Join-Path $env:USERPROFILE '.claude\settings.json' })
$startup  = [Environment]::GetFolderPath('Startup')
$lnk      = Join-Path $startup 'Bubbles.lnk'
$menuLnk  = Join-Path ([Environment]::GetFolderPath('Programs')) 'Bubbles.lnk'
$deskLnk  = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Bubbles.lnk'
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
        # keep the very first backup: later runs would only save our own edits
        if (-not (Test-Path "$settings.bubbles-backup")) { Copy-Item $settings "$settings.bubbles-backup" }
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
            # a permission request waits up to 110 s for an answer from a bubble
            $limit = $(if ($ev -eq 'PermissionRequest') { 120 } else { 10 })
            $groups += [pscustomobject]@{ hooks = @([pscustomobject]@{ type = 'command'; command = $cmd; timeout = $limit }) }
        }
        if ($groups.Count -gt 0) { $j.hooks | Add-Member $ev $groups -Force }
        elseif ($j.hooks.PSObject.Properties[$ev]) { $j.hooks.PSObject.Properties.Remove($ev) }
    }
    Save-Json $j $settings
}

# The Bubbles character as an icon: a mint orb with a highlight and two eyes, drawn at 256 px and stored
# as a PNG inside a single-image .ico (Windows scales it down for the Start menu and taskbar)
function New-BubblesIcon($path) {
    Add-Type -AssemblyName System.Drawing
    $n = 256
    $bmp = New-Object System.Drawing.Bitmap $n, $n
    $g = [System.Drawing.Graphics]::FromImage($bmp); $g.SmoothingMode = 'AntiAlias'
    $orb = New-Object System.Drawing.Rectangle 12, 16, 232, 228
    $gp = New-Object System.Drawing.Drawing2D.GraphicsPath; $gp.AddEllipse($orb)
    $fill = New-Object System.Drawing.Drawing2D.PathGradientBrush $gp
    $fill.CenterPoint = New-Object System.Drawing.PointF 100, 90
    $fill.CenterColor = [System.Drawing.Color]::FromArgb(206, 255, 241)
    $fill.SurroundColors = @([System.Drawing.Color]::FromArgb(26, 150, 122))
    $g.FillEllipse($fill, $orb)
    $g.FillEllipse((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(150, 255, 255, 255))), 58, 44, 74, 36)
    $eye = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(26, 26, 44))
    $g.FillEllipse($eye, 84, 104, 30, 52); $g.FillEllipse($eye, 144, 104, 30, 52)
    $shine = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(235, 255, 255, 255))
    $g.FillEllipse($shine, 94, 112, 11, 14); $g.FillEllipse($shine, 154, 112, 11, 14)
    $g.Dispose()
    $ms = New-Object System.IO.MemoryStream; $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
    $png = $ms.ToArray()
    $fs = [System.IO.File]::Create($path); $w = New-Object System.IO.BinaryWriter $fs
    $w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]1)              # icon file, one image
    $w.Write([byte]0); $w.Write([byte]0); $w.Write([byte]0); $w.Write([byte]0)  # 256x256 (0 means 256), no palette
    $w.Write([uint16]1); $w.Write([uint16]32); $w.Write([uint32]$png.Length); $w.Write([uint32]22)
    $w.Write($png); $w.Close()
}

function New-Shortcut($path) {
    $ws = New-Object -ComObject WScript.Shell
    $s = $ws.CreateShortcut($path)
    $s.TargetPath = (Get-Command powershell.exe).Source
    $s.Arguments = "-STA -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSScriptRoot\bubbles.ps1`""
    $s.WorkingDirectory = $PSScriptRoot
    $s.WindowStyle = 7   # minimized, so no console flashes up
    $s.Description = 'Talk to Claude Code by voice'
    if (Test-Path $icon) { $s.IconLocation = "$icon,0" }
    $s.Save()
}

if ($Remove) {
    Update-Hooks $false
    foreach ($l in $lnk, $menuLnk, $deskLnk) { if (Test-Path $l) { Remove-Item $l } }
    Write-Host 'Removed the Bubbles hooks and shortcuts.'
    Write-Host 'Delete bubbles-hook.exe yourself once Bubbles is closed.'
    return
}

# build next to the old exe, then swap: a running hook keeps its file locked, but a running exe can be renamed
$fresh = Join-Path $PSScriptRoot 'bubbles-hook.new.exe'   # must end in .exe or the compiler builds a library
if (Test-Path $fresh) { Remove-Item $fresh }
Add-Type -TypeDefinition ([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'hook.cs'))) -OutputAssembly $fresh -OutputType ConsoleApplication
if (Test-Path $hookExe) {
    $stale = "$hookExe.old"
    if (Test-Path $stale) { try { Remove-Item $stale } catch {} }
    try { Remove-Item $hookExe } catch { Move-Item $hookExe $stale -Force }
}
Move-Item $fresh $hookExe
Write-Host "Built $hookExe"

Update-Hooks $true
Write-Host "Added the Bubbles hook to $settings (backup: settings.json.bubbles-backup)"

New-BubblesIcon $icon
New-Shortcut $menuLnk
Write-Host "Added Start menu shortcut: $menuLnk"
if (-not $NoDesktop) { New-Shortcut $deskLnk; Write-Host "Added desktop shortcut: $deskLnk" }
if (-not $NoStartup) { New-Shortcut $lnk; Write-Host "Added startup shortcut: $lnk" }
Write-Host 'Done. Start Bubbles from the Start menu or the desktop shortcut. If a Claude Code session that was already open shows no live status, restart it.'
