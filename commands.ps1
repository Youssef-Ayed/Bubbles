# commands.ps1 - say "slash <name> ..." and it becomes "/<name> ...", plus auto-send into Claude.
# Dot-sourced by bubbles.ps1 (runs in its script scope). Keep this file ASCII-only.

Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes

$script:cmdCache = $null; $script:cmdCacheAt = $null; $script:cmdCacheDir = $null
$script:builtinCommands = @('compact', 'clear', 'context', 'init', 'review', 'code-review', 'security-review', 'model', 'cost', 'usage', 'memory', 'help', 'status', 'agents', 'mcp', 'plugin', 'skills', 'effort', 'resume')

function ConvertTo-CmdKey($s) { ([string]$s).ToLowerInvariant() -replace '[^a-z0-9]', '' }
function Get-SkillName($dir) {
    $md = Join-Path $dir 'SKILL.md'
    if (Test-Path -LiteralPath $md) {
        foreach ($ln in (Get-Content -LiteralPath $md -TotalCount 12 -ErrorAction SilentlyContinue)) {
            if ($ln -match '^\s*name:\s*["'']?([A-Za-z0-9_:.\-]+)') { return $Matches[1] }
        }
    }
    Split-Path -Leaf $dir
}
# Every slash command Claude Code knows here: project, then personal, then built in, then plugins (first one wins on a clash).
function Get-SlashCommands($folder) {
    if ($script:cmdCache -and $script:cmdCacheDir -eq $folder -and ((Get-Date) - $script:cmdCacheAt).TotalSeconds -lt 60) { return $script:cmdCache }
    $list = New-Object System.Collections.ArrayList
    $seen = @{}
    $add = {
        param($name, $short)
        if (-not $name -or $seen.ContainsKey($name)) { return }
        $seen[$name] = $true
        $keys = @(ConvertTo-CmdKey $name)
        if ($short -and (ConvertTo-CmdKey $short) -ne $keys[0]) { $keys += ConvertTo-CmdKey $short }
        [void]$list.Add([pscustomobject]@{ Name = $name; Keys = $keys })
    }
    $roots = @()
    if ($folder) { $roots += (Join-Path $folder '.claude') }
    $roots += (Join-Path $env:USERPROFILE '.claude')
    foreach ($r in $roots) {
        $cd = Join-Path $r 'commands'
        if (Test-Path -LiteralPath $cd) {
            foreach ($f in (Get-ChildItem -LiteralPath $cd -Recurse -Filter *.md -File -ErrorAction SilentlyContinue)) {
                $rel = $f.FullName.Substring($cd.Length + 1) -replace '\.md$', '' -replace '[\\/]', ':'
                & $add $rel $f.BaseName
            }
        }
        $sd = Join-Path $r 'skills'
        if (Test-Path -LiteralPath $sd) { foreach ($d in (Get-ChildItem -LiteralPath $sd -Directory -ErrorAction SilentlyContinue)) { & $add (Get-SkillName $d.FullName) $null } }
    }
    foreach ($b in $script:builtinCommands) { & $add $b $null }
    try {
        $enabled = (Get-Content (Join-Path $env:USERPROFILE '.claude\settings.json') -Raw | ConvertFrom-Json).enabledPlugins
        $inst = (Get-Content (Join-Path $env:USERPROFILE '.claude\plugins\installed_plugins.json') -Raw | ConvertFrom-Json).plugins
        foreach ($p in $inst.PSObject.Properties) {
            if ($enabled -and $enabled.($p.Name) -eq $false) { continue }
            $ip = [string](@($p.Value)[0].installPath)
            $pn = ($p.Name -split '@')[0]
            if (-not $ip -or -not (Test-Path -LiteralPath $ip)) { continue }
            foreach ($d in (Get-ChildItem -LiteralPath (Join-Path $ip 'skills') -Directory -ErrorAction SilentlyContinue)) {
                $sn = Get-SkillName $d.FullName
                & $add ($(if ($sn -match ':') { $sn } else { "${pn}:$sn" })) ($sn -replace '^.*:', '')
            }
            foreach ($f in (Get-ChildItem -LiteralPath (Join-Path $ip 'commands') -Filter *.md -File -ErrorAction SilentlyContinue)) { & $add "${pn}:$($f.BaseName)" $f.BaseName }
        }
    } catch { Log "slash commands: $_" }
    $script:cmdCache = @($list); $script:cmdCacheAt = Get-Date; $script:cmdCacheDir = $folder
    $script:cmdCache
}
function Get-EditDistance([string]$a, [string]$b) {
    $n = $a.Length; $m = $b.Length
    if ($n -eq 0) { return $m }; if ($m -eq 0) { return $n }
    $prev = New-Object int[] ($m + 1); $cur = New-Object int[] ($m + 1)
    for ($j = 0; $j -le $m; $j++) { $prev[$j] = $j }
    for ($i = 1; $i -le $n; $i++) {
        $cur[0] = $i
        for ($j = 1; $j -le $m; $j++) {
            $cost = $(if ($a[$i - 1] -eq $b[$j - 1]) { 0 } else { 1 })
            $cur[$j] = [math]::Min([math]::Min($prev[$j] + 1, $cur[$j - 1] + 1), $prev[$j - 1] + $cost)
        }
        $t = $prev; $prev = $cur; $cur = $t
    }
    $prev[$m]
}
# "Slash, code review the auth module." -> @{ Command = 'code-review'; Text = '/code-review the auth module.' }
# Returns $null when the text does not start with "slash" or "/".
function Convert-SpokenCommand($text, $folder) {
    $m = [regex]::Match([string]$text, '^\s*(?:(?:forward\s+)?slash\b|/)\s*[,.:;]?\s*(.*)$', 'IgnoreCase, Singleline')
    if (-not $m.Success) { return $null }
    $rest = $m.Groups[1].Value.Trim()
    $words = @($rest -split '\s+' | Where-Object { $_ })
    if ($words.Count -eq 0) { return [pscustomobject]@{ Command = ''; Known = $false; Text = '/' } }
    $cmds = Get-SlashCommands $folder
    $best = $null; $bestK = 0; $bestScore = 0.0
    $maxK = [math]::Min(5, $words.Count)
    for ($k = $maxK; $k -ge 1 -and -not $best; $k--) {
        $spoken = ConvertTo-CmdKey (($words[0..($k - 1)]) -join '')
        if (-not $spoken) { continue }
        foreach ($c in $cmds) { if ($c.Keys -contains $spoken) { $best = $c; $bestK = $k; $bestScore = 1.0; break } }
    }
    if (-not $best) {
        for ($k = 1; $k -le [math]::Min(4, $words.Count); $k++) {
            $spoken = ConvertTo-CmdKey (($words[0..($k - 1)]) -join '')
            if ($spoken.Length -lt 4) { continue }
            foreach ($c in $cmds) {
                foreach ($key in $c.Keys) {
                    if ($key.Length -lt 4) { continue }
                    $s = 1.0 - (Get-EditDistance $spoken $key) / [double][math]::Max($spoken.Length, $key.Length)
                    if ($s -gt $bestScore) { $bestScore = $s; $best = $c; $bestK = $k }
                }
            }
        }
        if ($bestScore -lt 0.78) { $best = $null }
    }
    if ($best) { $name = $best.Name; $known = $true; $used = $bestK }
    else { $name = ($words[0] -replace '[^A-Za-z0-9:_\-]', '').ToLowerInvariant(); $known = $false; $used = 1 }
    $args_ = $(if ($words.Count -gt $used) { ($words[$used..($words.Count - 1)]) -join ' ' } else { '' })
    $args_ = $args_ -replace '^[,.:;\-]+\s*', ''
    if (-not $args_) { $args_ = '' }
    [pscustomobject]@{ Command = $name; Known = $known; Text = ('/' + $name + $(if ($args_) { ' ' + $args_ } else { '' })) }
}

# ---------------------------------------------------------------- auto-send: press Enter only once our text is really in Claude's prompt box
function Send-Enter {
    [VcNative]::keybd_event(0x0D, 0, 0, [UIntPtr]::Zero)
    [VcNative]::keybd_event(0x0D, 0, 2, [UIntPtr]::Zero)
}
# Looks inside the Claude window (it must be in front): the prompt box holding our words (focused one first),
# and whether the app's "Trust workspace" check is showing. That check is yours to answer, so we never click it.
function Get-ClaudePrompt($want) {
    $h = [VcNative]::GetForegroundWindow()
    if ($h -eq [IntPtr]::Zero -or (Get-ForegroundProcessName) -ne 'claude') { return $null }
    try {
        $A = [System.Windows.Automation.AutomationElement]
        $root = $A::FromHandle($h)
        $trust = $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
            (New-Object System.Windows.Automation.PropertyCondition ($A::NameProperty), 'Trust workspace'))
        $cond = New-Object System.Windows.Automation.AndCondition @(
            (New-Object System.Windows.Automation.PropertyCondition ($A::ControlTypeProperty), ([System.Windows.Automation.ControlType]::Edit)),
            (New-Object System.Windows.Automation.PropertyCondition ($A::NameProperty), 'Prompt'))
        $pick = $null; $pickV = ''
        foreach ($e in $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond)) {
            $v = ''
            try { $v = [string]$e.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value } catch {}
            $hasIt = ($want -and (ConvertTo-CmdKey $v).Contains($want))
            if ($e.Current.HasKeyboardFocus -or ($hasIt -and -not $pick)) { $pick = $e; $pickV = $v; if ($e.Current.HasKeyboardFocus) { break } }
        }
        [pscustomobject]@{ El = $pick; Value = $pickV; Key = (ConvertTo-CmdKey $pickV); Focus = [bool]($pick -and $pick.Current.HasKeyboardFocus); Trust = [bool]$trust }
    } catch { $null }
}
# Phase 1: wait for Claude in front (and paste, when $paste). Phase 2: see our words in the focused prompt, press Enter.
# Phase 3: if the box still holds them (a slash menu took the first Enter), press Enter once more.
function Start-AutoSend($text, $bubble, $paste, $previousClip) {
    if ($script:sendTimer) { $script:sendTimer.Stop() }
    $want = ConvertTo-CmdKey $text
    $script:snd = @{ Text = $text; Want = $want.Substring(0, [math]::Min(24, $want.Length)); Bubble = $bubble; Paste = [bool]$paste; Prev = $previousClip
        Ticks = 0; Seen = 0; Phase = 1; Enters = 0; At = $null }
    $script:sendTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:sendTimer.Interval = [TimeSpan]::FromMilliseconds(150)
    $script:sendTimer.Add_Tick({
        $s = $script:snd
        $s.Ticks++
        try {
            if ($s.Phase -eq 1) {
                if ($s.Ticks -gt 60) { $script:sendTimer.Stop(); Log 'autosend: Claude never came to the front'; Set-BubbleNote $s.Bubble $(if ($s.Paste) { 'Could not paste - press Ctrl+V then Enter in Claude' } else { 'Press Enter in Claude to send' }) 40; return }
                if ((Get-ForegroundProcessName) -eq 'claude') { $s.Seen++ } else { $s.Seen = 0 }
                if ($s.Seen -ge 6) {
                    if ($s.Paste) { Send-CtrlV; Log 'autopaste: pasted' }
                    if (-not $script:cfg.autoSend) {
                        $script:sendTimer.Stop()
                        Set-BubbleNote $s.Bubble $(if ($s.Paste) { 'Pasted - press Enter in Claude to send' } else { 'Ready in Claude - press Enter to send' }) 40
                        Restore-Clip $s.Prev; return
                    }
                    $s.Phase = 2; $s.Ticks = 0
                }
                return
            }
            if ($s.Phase -eq 2) {
                # a pasted follow-up shows up within seconds; a new session may first wait for you to answer "Trust workspace"
                $limit = $(if ($s.Paste) { 24 } else { 600 })
                if ($s.Ticks -gt $limit) {
                    $script:sendTimer.Stop(); Log 'autosend: text never showed up in the prompt box'
                    Set-BubbleNote $s.Bubble 'Check Claude - press Enter there to send' 40; Restore-Clip $s.Prev; return
                }
                if ($s.TrustNoted -and ($s.Ticks % 3) -ne 0) { return }
                $p = Get-ClaudePrompt $s.Want
                if (-not $p) { return }
                if ($p.Trust) {
                    if (-not $s.TrustNoted) { $s.TrustNoted = $true; Log 'autosend: waiting for Trust workspace'; Set-BubbleNote $s.Bubble 'Click "Trust workspace" in Claude - I send it right after' 90 }
                    return
                }
                if ($p.El -and $s.Want -and $p.Key.Contains($s.Want)) {
                    if (-not $p.Focus) { try { $p.El.SetFocus() } catch {}; return }
                    Send-Enter; $s.Enters++; $s.Phase = 3; $s.Ticks = 0
                    Log "autosend: enter ($($s.Text.Length) chars)"
                }
                return
            }
            if ($s.Phase -eq 3 -and $s.Ticks -ge 5) {
                $p = Get-ClaudePrompt $s.Want
                if ($p -and $p.Key -and $s.Enters -lt 2 -and ($p.Key.Contains($s.Want) -or $s.Want.StartsWith($p.Key))) {
                    Send-Enter; $s.Enters++; $s.Ticks = 0; Log 'autosend: second enter'
                    return
                }
                $script:sendTimer.Stop()
                Set-BubbleNote $s.Bubble 'Sent - I am following along' 6
                Restore-Clip $s.Prev
            }
        } catch { $script:sendTimer.Stop(); Log "autosend error: $_" }
    })
    $script:sendTimer.Start()
}
function Restore-Clip($prev) {
    if (-not $script:cfg.restoreClipboard -or -not $prev) { return }
    try { [System.Windows.Clipboard]::SetText([string]$prev) } catch {}
}
