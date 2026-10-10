# bubble-ui.ps1 - one floating bubble per Claude Code session.
# Dot-sourced by bubbles.ps1 (runs in its script scope). Keep this file ASCII-only.

$script:bubbles      = New-Object System.Collections.ArrayList
$script:bubbleSeq    = 0
$script:hookSessions = @{}
$script:notesCache   = @{}
$script:dismissed    = @{}     # session id -> true once you closed its bubble (cleared on that session's next prompt)
$script:seenFiles    = @{}
$script:dockSide = 'right'; $script:dockFrac = 0.4; $script:dockScreen = $null   # where the next bubble starts
$script:dictOn = $false; $script:activeSession = $null; $script:replyLocal = $null; $script:lastVoiceBubble = $null; $script:answerTarget = $null
$script:server = $null; $script:workArea = $null; $script:restoring = $false
$script:waveBars = @(1..5 | ForEach-Object { $win.FindName("W$_") })

$script:palette   = @(@('#A6F7E1', '#2FC4A3'), @('#D2C2FF', '#7B57F0'), @('#FFC9AA', '#F06A3C'), @('#B1D8FF', '#3A7BF0'), @('#FFBEDA', '#E44C8F'))
$script:amberPair = @('#FFE29A', '#EE9F1C')
$script:kindColor = @{ run = '#F6C453'; edit = '#86EBD3'; read = '#8AB4FF'; web = '#C79BFF'; agent = '#F29BC6'; ok = '#7EE08A'; warn = '#F6C453'; bad = '#FF8F8F'; info = '#8A8A96'; user = '#D6D6DE' }
$script:kindGlyph = @{ run = 0xE756; edit = 0xE70F; read = 0xE8A5; web = 0xE774; agent = 0xE99A; ok = 0xE73E; warn = 0xE7BA; bad = 0xE711; info = 0xE946; user = 0xE77B }
$script:mouthPaths = @{
    smile = 'M19.5,26.2 Q23,29.6 26.5,26.2'
    focus = 'M20.5,27 Q23,28.2 25.5,27'
    grin  = 'M18.6,25.4 Q23,32.4 27.4,25.4 Z'
    sleep = 'M21,27.2 Q23,28.2 25,27.2'
}
# The character's parts: the same names exist in the input pill and in every bubble.
$script:orbNames = @('Pill', 'PillScale', 'BlobHost', 'OrbScale', 'Aura', 'AuraC', 'AuraE', 'AuraScale', 'Ring', 'RingScale', 'Shock', 'ShockScale',
    'SpinHost', 'SpinRot', 'SpinArc', 'Jelly', 'JR1', 'JS', 'JR2', 'Body', 'BodyScale', 'Breath', 'BodyShift', 'G1', 'G2', 'G3', 'Spec', 'SpecShift',
    'Face', 'FaceShift', 'Cheeks', 'EyesIdle', 'EyesWide', 'EyeL', 'EyeR', 'EyesHappy', 'EyesSleep', 'Mouth', 'MouthO', 'Fx', 'Zzz', 'Z1', 'Z2', 'Z1T', 'Z2T')
$script:bubbleNames = $script:orbNames + @('PillShift', 'BadgeHost', 'BadgeScale', 'BadgeBg', 'BadgeText', 'LabelHost', 'LabelText', 'ColA', 'ColB', 'CloseX',
    'Col1', 'ColShift', 'TextCol', 'StatusCol', 'HeadRow', 'ProjText', 'TitleText', 'HdrBtns', 'StateChip', 'StateText', 'HdrMin', 'HdrClose',
    'StatusDot', 'ActText', 'MetaText', 'Shimmer', 'ShimmerShift', 'AlertPanel', 'AlertHead', 'AlertBox', 'AlertBody', 'BtnOpenClaude', 'BtnOpenIcon', 'BtnOpenText', 'BtnAllow', 'BtnDeny', 'AlertHint', 'QOptions', 'BtnSpeak', 'BtnAllowIcon', 'BtnAllowText',
    'LogPanel', 'LogCount', 'LogScroll', 'LogList', 'ThinkLabel', 'ThinkBox', 'ThinkBar', 'ThinkText', 'OpenBtn', 'ReplyBtn')

# Eye tracking and drag stretch run 30 times a second, so they live in compiled code (PowerShell would burn a core).
Add-Type -AssemblyName System.Xaml
Add-Type -ReferencedAssemblies @([System.Windows.Window].Assembly.Location, [System.Windows.Media.Visual].Assembly.Location,
    [System.Windows.DependencyObject].Assembly.Location, [System.Xaml.XamlSchemaContext].Assembly.Location) -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Media;
using System.Windows.Threading;

public class VcOrb {
    public FrameworkElement Host;
    public TranslateTransform Face, Spec;
    public ScaleTransform JS;
    public RotateTransform JR1, JR2, Spin;
    public string Mood = "idle";
    public bool Dragging, Hover, IsPill, Gone;
    public double Vx, Vy, FX, FY, WX, WY;
    public DateTime WanderAt = DateTime.MinValue;
    internal Point Center; internal bool HasCenter;
}

public static class VcGaze {
    [StructLayout(LayoutKind.Sequential)] struct POINT { public int X, Y; }
    [DllImport("user32.dll")] static extern bool GetCursorPos(out POINT p);
    public static List<VcOrb> Orbs = new List<VcOrb>();
    public static VcOrb Alert;
    public static DateTime AlertUntil = DateTime.MinValue;
    static DispatcherTimer timer;
    static Random rnd = new Random();

    public static void Start() {
        if (timer != null) return;
        timer = new DispatcherTimer();
        timer.Interval = TimeSpan.FromMilliseconds(33);
        timer.Tick += delegate { try { Tick(); } catch { } };
        timer.Start();
    }
    public static void Remove(VcOrb o) { if (o == null) return; o.Gone = true; Orbs.Remove(o); }
    static double Clamp(double v, double m) { return Math.Max(-m, Math.Min(m, v)); }
    static void Locate(VcOrb o) {
        o.HasCenter = false;
        if (o.Gone || o.Host == null || !o.Host.IsVisible || PresentationSource.FromVisual(o.Host) == null) return;
        o.Center = o.Host.PointToScreen(new Point(o.Host.ActualWidth / 2, o.Host.ActualHeight / 2));
        o.HasCenter = true;
    }
    static void Tick() {
        POINT cp; GetCursorPos(out cp);
        DateTime now = DateTime.Now;
        VcOrb drag = null;
        foreach (VcOrb o in Orbs) { Locate(o); if (o.Dragging && o.HasCenter) drag = o; }
        VcOrb alert = (Alert != null && !Alert.Gone && Alert.HasCenter && now < AlertUntil) ? Alert : null;
        foreach (VcOrb o in Orbs) {
            if (!o.HasCenter) continue;
            double sc = VisualTreeHelper.GetDpi(o.Host).DpiScaleX;
            double tx = 0, ty = 0, lx = 0, ly = 0; bool look = false;
            double dx = cp.X - o.Center.X, dy = cp.Y - o.Center.Y, d = Math.Sqrt(dx * dx + dy * dy);
            if (o.Dragging) { tx = Clamp(o.Vx * 3, 4); ty = Clamp(o.Vy * 3, 3); }
            else if (o.Mood == "sleep" && !o.Hover) { ty = 1.2; }
            else if (d < 360 * sc) { look = true; lx = dx; ly = dy; }
            else if (drag != null && drag != o) { look = true; lx = drag.Center.X - o.Center.X; ly = drag.Center.Y - o.Center.Y; }
            else if (alert != null && alert != o) { look = true; lx = alert.Center.X - o.Center.X; ly = alert.Center.Y - o.Center.Y; }
            else if (o.Mood == "working" && o.Spin != null) { double an = (o.Spin.Angle + 62) * Math.PI / 180; tx = Math.Cos(an) * 3.6; ty = Math.Sin(an) * 2.8; }
            else if (o.IsPill) { tx = 3.4; ty = 0.8; }
            else {
                if (now >= o.WanderAt) {
                    if (rnd.Next(3) == 0) { o.WX = 0; o.WY = 0; } else { o.WX = rnd.NextDouble() * 6 - 3; o.WY = rnd.NextDouble() * 4 - 2; }
                    o.WanderAt = now.AddMilliseconds(2500 + rnd.Next(5000));
                }
                tx = o.WX; ty = o.WY;
            }
            if (look) {
                double ld = Math.Max(1, Math.Sqrt(lx * lx + ly * ly));
                double k = Math.Min(1, ld / (70 * sc));
                tx = lx / ld * 4 * k; ty = ly / ld * 3 * k;
            }
            o.FX += (tx - o.FX) * 0.24; o.FY += (ty - o.FY) * 0.24;
            if (Math.Abs(o.Face.X - o.FX) > 0.03 || Math.Abs(o.Face.Y - o.FY) > 0.03) {
                o.Face.X = o.FX; o.Face.Y = o.FY; o.Spec.X = -o.FX * 0.35; o.Spec.Y = -o.FY * 0.35;
            }
            if (o.Dragging) {
                double sp = Math.Sqrt(o.Vx * o.Vx + o.Vy * o.Vy);
                double s = Math.Min(0.32, sp * 0.11);
                double an = Math.Atan2(o.Vy, o.Vx) * 180 / Math.PI;
                o.JR1.Angle = -an; o.JR2.Angle = an; o.JS.ScaleX = 1 + s; o.JS.ScaleY = 1 - s * 0.6;
                o.Vx *= 0.8; o.Vy *= 0.8;
            }
        }
    }
}
'@
function New-OrbLink($c, $isPill) {
    $o = New-Object VcOrb
    $o.Host = $c.BlobHost; $o.Face = $c.FaceShift; $o.Spec = $c.SpecShift; $o.JS = $c.JS; $o.JR1 = $c.JR1; $o.JR2 = $c.JR2; $o.Spin = $c.SpinRot
    $o.IsPill = [bool]$isPill
    [VcGaze]::Orbs.Add($o)
    $o
}

$script:ST = [System.Windows.Media.ScaleTransform]
$script:TT = [System.Windows.Media.TranslateTransform]
$script:RT = [System.Windows.Media.RotateTransform]
$script:OP = [System.Windows.UIElement]::OpacityProperty
$script:iconFont = New-Object System.Windows.Media.FontFamily 'Segoe Fluent Icons, Segoe MDL2 Assets'
$script:uiFont   = New-Object System.Windows.Media.FontFamily 'Segoe UI Variable Text, Segoe UI'
$script:monoFont = New-Object System.Windows.Media.FontFamily 'Consolas'

# ---------------------------------------------------------------- small helpers
function Cut-Text($t, $n) { $t = ([string]$t) -replace '\s+', ' '; if ($t.Length -gt $n) { $t.Substring(0, $n - 1) + '...' } else { $t } }
function Get-FileLeaf($p) { try { Split-Path -Leaf ([string]$p) } catch { [string]$p } }
function Get-WinScaleOf($w) {
    $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper $w).Handle
    $sc = 1.0
    try { $d = [VcNative]::GetDpiForWindow($hwnd); if ($d -gt 0) { $sc = $d / 96.0 } } catch {}
    $sc
}
function Test-InVisual($el, $anc) {
    $cur = $el
    for ($i = 0; $i -lt 80 -and $null -ne $cur; $i++) {
        if ([object]::ReferenceEquals($cur, $anc)) { return $true }
        if ($cur -is [System.Windows.Media.Visual]) { $cur = [System.Windows.Media.VisualTreeHelper]::GetParent($cur) }
        elseif ($cur -is [System.Windows.FrameworkContentElement]) { $cur = $cur.Parent }
        else { $cur = $null }
    }
    $false
}
function To-Color($hex, $a = -1) {
    $c = [System.Windows.Media.ColorConverter]::ConvertFromString($hex)
    if ($a -ge 0) { $c = [System.Windows.Media.Color]::FromArgb([byte]$a, $c.R, $c.G, $c.B) }
    $c
}
function Shade-Color($hex, $f) { $c = To-Color $hex; [System.Windows.Media.Color]::FromRgb([byte]($c.R * $f), [byte]($c.G * $f), [byte]($c.B * $f)) }
function Solid($hex, $a = -1) { $br = New-Object System.Windows.Media.SolidColorBrush (To-Color $hex $a); $br.Freeze(); $br }
$script:brushText = Solid '#F2F2F5'
$script:brushLine = Solid '#1FFFFFFF'

function Get-ToolKind($tool) {
    switch -regex ([string]$tool) {
        '^Bash$|^PowerShell$'                   { return 'run' }
        '^(Edit|MultiEdit|Write|NotebookEdit)$' { return 'edit' }
        '^(Read|Grep|Glob|LS)$'                 { return 'read' }
        '^(WebFetch|WebSearch)$'                { return 'web' }
        '^(Task|Agent)$'                        { return 'agent' }
        default                                 { return 'info' }
    }
}
function Describe-Tool($tool, $in) {
    switch -regex ($tool) {
        '^Bash$'             { return 'Running: ' + (Cut-Text $in.command 70) }
        '^PowerShell$'       { return 'Running: ' + (Cut-Text $in.command 70) }
        '^(Edit|MultiEdit)$' { return 'Editing ' + (Get-FileLeaf $in.file_path) }
        '^Write$'            { return 'Writing ' + (Get-FileLeaf $in.file_path) }
        '^NotebookEdit$'     { return 'Editing a notebook' }
        '^Read$'             { return 'Reading ' + (Get-FileLeaf $in.file_path) }
        '^(Grep|Glob)$'      { return 'Searching: ' + (Cut-Text $in.pattern 50) }
        '^WebFetch$'         { return 'Fetching ' + (Cut-Text $in.url 60) }
        '^WebSearch$'        { return 'Searching the web: ' + (Cut-Text $in.query 50) }
        '^(Task|Agent)$'     { return 'Delegating: ' + (Cut-Text $in.description 60) }
        '^TodoWrite$'        { return 'Updating the plan' }
        '^mcp__'             { $parts = $tool -split '__'; return 'Using ' + $parts[$parts.Count - 1] }
        default              { return 'Using ' + $tool }
    }
}
function Describe-Alert($p) {
    $t = [string]$p.tool_name; $in = $p.tool_input; $h = "Use $t"; $b = ''
    switch -regex ($t) {
        '^(Bash|PowerShell)$' { $h = 'Run a command'; $b = Cut-Text $in.command 500 }
        '^(Edit|MultiEdit)$'  { $h = 'Edit a file'; $b = [string]$in.file_path }
        '^Write$'             { $h = 'Write a file'; $b = [string]$in.file_path }
        '^NotebookEdit$'      { $h = 'Edit a notebook'; $b = [string]$in.notebook_path }
        '^(Read|Glob|Grep)$'  { $h = 'Read files'; $b = Cut-Text (@($in.file_path, $in.pattern, $in.path) | Where-Object { $_ } | Select-Object -First 1) 300 }
        '^AskUserQuestion$'   { $h = 'Claude has a question'; $b = Cut-Text (@($in.questions)[0].question) 300 }
        '^WebFetch$'          { $h = 'Open a web page'; $b = [string]$in.url }
        '^WebSearch$'         { $h = 'Search the web'; $b = [string]$in.query }
        '^(Task|Agent)$'      { $h = 'Start a sub-agent'; $b = Cut-Text $in.description 300 }
        default               { $h = 'Use ' + (($t -split '__')[-1]); $b = Cut-Text ($in | ConvertTo-Json -Compress -Depth 4) 400 }
    }
    [pscustomobject]@{ Head = $h; Body = $b }
}
function Get-CliId($localId) {
    try {
        $root = Join-Path $env:APPDATA 'Claude\claude-code-sessions'
        $fi = Get-ChildItem $root -Recurse -File -Filter "$localId.json" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($fi) { return [string](Get-Content $fi.FullName -Raw | ConvertFrom-Json).cliSessionId }
    } catch {}
    $null
}
function Get-LocalId($cli) {
    try {
        $root = Join-Path $env:APPDATA 'Claude\claude-code-sessions'
        foreach ($fi in (Get-ChildItem $root -Recurse -File -Filter 'local_*.json' -ErrorAction SilentlyContinue)) {
            $j = Get-Content $fi.FullName -Raw | ConvertFrom-Json
            if ([string]$j.cliSessionId -eq [string]$cli) { return [string]$j.sessionId }
        }
    } catch {}
    $null
}

# ---------------------------------------------------------------- per-session hook state
function Get-HookSession($sid, $cwd) {
    if (-not $script:hookSessions.ContainsKey($sid)) {
        $c = [string]$cwd
        $script:hookSessions[$sid] = [pscustomobject]@{
            Id = $sid; Cwd = $c; Project = $(if ($c) { Split-Path -Leaf $c } else { '' })
            Start = Get-Date; Steps = 0; Activity = 'Starting...'; Working = $false; Done = $false
            DoneAt = $null; Reply = ''; Log = (New-Object System.Collections.ArrayList); Last = Get-Date
            Transcript = ''; Checked = Get-Date; Spoken = ''
        }
        Log "hook session seen: $($script:hookSessions[$sid].Project)"
    }
    $script:hookSessions[$sid]
}
function Add-LogLine($sess, $text, $kind = 'info') {
    [void]$sess.Log.Add([pscustomobject]@{ T = (Get-Date).ToString('HH:mm:ss'); Kind = $kind; Text = [string]$text })
    while ($sess.Log.Count -gt 80) { $sess.Log.RemoveAt(0) }
}
# Claude's own notes come from the session transcript: visible narration, and thinking when it is not empty.
function Get-TranscriptBlocks($sess) {
    $p = Join-Path $env:USERPROFILE (".claude\projects\" + ($sess.Cwd -replace '[^A-Za-z0-9]', '-') + "\$($sess.Id).jsonl")
    if (-not (Test-Path -LiteralPath $p)) { return @() }
    $stamp = (Get-Item -LiteralPath $p).LastWriteTimeUtc.Ticks
    $c = $script:notesCache[$sess.Id]
    if ($c -and $c.Stamp -eq $stamp) { return $c.Blocks }
    $blocks = @()
    foreach ($ln in (Get-Content -LiteralPath $p -Tail 150 -ErrorAction SilentlyContinue)) {
        try { $o = $ln | ConvertFrom-Json } catch { continue }
        if ($o.message.role -ne 'assistant') { continue }
        $cont = $o.message.content
        if ($cont -is [array]) {
            foreach ($bl in $cont) {
                if ($bl.type -eq 'thinking' -and ([string]$bl.thinking).Trim()) { $blocks += [pscustomobject]@{ Kind = 'thinking'; Text = ([string]$bl.thinking).Trim() } }
                elseif ($bl.type -eq 'text' -and ([string]$bl.text).Trim()) { $blocks += [pscustomobject]@{ Kind = 'text'; Text = ([string]$bl.text).Trim() } }
            }
        } elseif ($cont -is [string] -and $cont.Trim()) { $blocks += [pscustomobject]@{ Kind = 'text'; Text = $cont.Trim() } }
    }
    $script:notesCache[$sess.Id] = @{ Stamp = $stamp; Blocks = $blocks }
    $blocks
}
function Get-Notes($sess) {
    $bl = @(Get-TranscriptBlocks $sess | Select-Object -Last 2)
    if ($bl.Count -eq 0) { return '' }
    (($bl | ForEach-Object { Cut-Text ($_.Text -replace '[\*\#`>]', '') 240 }) -join "`n`n")
}
function Get-Summary($sess) {
    $t = @(Get-TranscriptBlocks $sess | Where-Object { $_.Kind -eq 'text' } | Select-Object -Last 1)
    if ($t.Count -eq 0) { return '' }
    $x = ($t[0].Text -replace '[\*\#`>]', '' -replace '\s+', ' ').Trim()
    $m = [regex]::Match($x, '^.{20,140}?[\.\!\?](\s|$)')
    if ($m.Success) { $m.Value.Trim() } else { Cut-Text $x 120 }
}

# ---------------------------------------------------------------- animation helpers
function New-Ease($kind, $mode = 'EaseOut') {
    switch ($kind) {
        'back'    { $e = New-Object System.Windows.Media.Animation.BackEase; $e.Amplitude = 0.5 }
        'elastic' { $e = New-Object System.Windows.Media.Animation.ElasticEase; $e.Oscillations = 2; $e.Springiness = 4 }
        'bouncy'  { $e = New-Object System.Windows.Media.Animation.ElasticEase; $e.Oscillations = 1; $e.Springiness = 3 }
        'sine'    { $e = New-Object System.Windows.Media.Animation.SineEase }
        default   { $e = New-Object System.Windows.Media.Animation.CubicEase }
    }
    $e.EasingMode = $mode
    $e
}
function Anim-To($target, $prop, $to, $ms, $ease = 'cubic', $mode = 'EaseOut') {
    $a = New-Object System.Windows.Media.Animation.DoubleAnimation
    $a.To = [double]$to; $a.Duration = [TimeSpan]::FromMilliseconds($ms)
    if ($ease) { $a.EasingFunction = New-Ease $ease $mode }
    $target.BeginAnimation($prop, $a)
}
function Anim-FromTo($target, $prop, $from, $to, $ms, $ease = 'cubic', $mode = 'EaseOut') {
    $a = New-Anim $from $to $ms
    if ($ease) { $a.EasingFunction = New-Ease $ease $mode }
    $target.BeginAnimation($prop, $a)
}
function Anim-Loop($target, $prop, $from, $to, $ms, $fps = 30, $reverse = $true, $ease = 'sine', $delay = 0) {
    $a = New-Anim $from $to $ms
    $a.AutoReverse = [bool]$reverse
    $a.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
    if ($ease) { $a.EasingFunction = New-Ease $ease 'EaseInOut' }
    if ($delay) { $a.BeginTime = [TimeSpan]::FromMilliseconds($delay) }
    [System.Windows.Media.Animation.Timeline]::SetDesiredFrameRate($a, $fps)
    $target.BeginAnimation($prop, $a)
}
function Anim-Scale($st, $to, $ms, $ease = 'cubic', $mode = 'EaseOut') {
    Anim-To $st $script:ST::ScaleXProperty $to $ms $ease $mode
    Anim-To $st $script:ST::ScaleYProperty $to $ms $ease $mode
}

# ---------------------------------------------------------------- the character (shared by the pill and the bubbles)
function Set-OrbColors($c, $pair) {
    $c.G1.Color = To-Color $pair[0]; $c.G2.Color = To-Color $pair[1]; $c.G3.Color = Shade-Color $pair[1] 0.5
    $c.AuraC.Color = To-Color $pair[1] 0x8C; $c.AuraE.Color = To-Color $pair[1] 0
    $c.Ring.Stroke = Solid $pair[1]
    $c.SpinArc.Stroke = Solid $pair[0]
}
# Sleeping z's step once a second from the housekeeping tick (a smooth animation per bubble costs real CPU).
function Set-Zzz($c, $on) {
    $c.Zzz.Visibility = $(if ($on) { 'Visible' } else { 'Collapsed' })
    $c.Z1T.X = 4; $c.Z1T.Y = -5
    $c.Z1.Opacity = 0; $c.Z2.Opacity = $(if ($on) { 0.9 } else { 0 })
}
function Step-Zzz($o) {
    $o.ZPhase = ([int]$o.ZPhase + 1) % 3
    $o.C.Z2.Opacity = $(if ($o.ZPhase -lt 2) { 0.9 } else { 0 })
    $o.C.Z1.Opacity = $(if ($o.ZPhase -eq 1) { 0.9 } else { 0 })
}
# Moods: idle, listen, working, alert, happy, done, sleep, drag. Each one sets the face, the breathing and the aura.
function Set-OrbMood($o, $mood) {
    if (-not $o -or -not $o.C -or $o.Mood -eq $mood) { return }
    $o.Mood = $mood
    if ($o.Orb) { $o.Orb.Mood = $mood }
    $c = $o.C
    $eyes = 'open'; $wx = 1.0; $wy = 1.0; $mouth = 'smile'; $oh = $false; $breath = 0; $spin = $false; $zz = $false; $aura = 0.6; $cheek = 0.55; $fps = 24
    switch ($mood) {
        'working' { $wy = 0.8; $mouth = 'focus'; $breath = 1500; $spin = $true; $aura = 0.75 }
        'alert'   { $wx = 1.16; $wy = 1.22; $oh = $true; $breath = 850; $aura = 1.0 }
        'happy'   { $eyes = 'happy'; $mouth = 'grin'; $breath = 1700; $aura = 0.9; $cheek = 1.0 }
        'done'    { $cheek = 0.8 }
        'sleep'   { $eyes = 'sleep'; $mouth = 'sleep'; $zz = $true; $aura = 0.22 }
        'listen'  { $wx = 1.05; $wy = 1.1; $breath = 2000; $aura = 0.8; $fps = 15 }
        'drag'    { $wx = 1.14; $wy = 1.2; $oh = $true; $aura = 0.9 }
    }
    $c.EyesIdle.Visibility  = $(if ($eyes -eq 'open') { 'Visible' } else { 'Collapsed' })
    $c.EyesHappy.Visibility = $(if ($eyes -eq 'happy') { 'Visible' } else { 'Collapsed' })
    $c.EyesSleep.Visibility = $(if ($eyes -eq 'sleep') { 'Visible' } else { 'Collapsed' })
    Anim-To $c.EyesWide $script:ST::ScaleXProperty $wx 220 'back'
    Anim-To $c.EyesWide $script:ST::ScaleYProperty $wy 220 'back'
    $c.Mouth.Visibility = $(if ($oh) { 'Collapsed' } else { 'Visible' })
    $c.MouthO.Visibility = $(if ($oh) { 'Visible' } else { 'Collapsed' })
    $c.Mouth.Data = [System.Windows.Media.Geometry]::Parse($script:mouthPaths[$mouth])
    $c.Mouth.Fill = $(if ($mouth -eq 'grin') { Solid '#1A1A2C' } else { $null })
    Anim-To $c.Cheeks $script:OP $cheek 300
    # breathing redraws the layered window every frame, so only active moods breathe; idle ones blink and glance instead
    if ($breath) {
        Anim-Loop $c.Breath $script:ST::ScaleYProperty 1 1.045 $breath $fps
        Anim-Loop $c.Breath $script:ST::ScaleXProperty 1 0.972 $breath $fps
    } else {
        Anim-To $c.Breath $script:ST::ScaleYProperty 1 300
        Anim-To $c.Breath $script:ST::ScaleXProperty 1 300
    }
    Anim-To $c.Aura $script:OP $aura 400
    if ($spin) {
        if ($c.SpinHost.Visibility -ne 'Visible') {
            $c.SpinHost.Visibility = 'Visible'
            Anim-Loop $c.SpinRot $script:RT::AngleProperty 0 360 1200 24 $false $null
            Anim-FromTo $c.SpinHost $script:OP 0 1 250
        }
    } elseif ($c.SpinHost.Visibility -eq 'Visible') {
        $c.SpinHost.Visibility = 'Collapsed'
        $c.SpinRot.BeginAnimation($script:RT::AngleProperty, $null)
    }
    Set-Zzz $c $zz
}
function Burst-Orb($o, $n = 16) {
    if (-not $o -or -not $o.C -or -not $o.C.Fx) { return }
    $fx = $o.C.Fx
    $cols = @('#A6F7E1', '#D2C2FF', '#FFC9AA', '#B1D8FF', '#FFBEDA', '#FFE29A', '#FFFFFF')
    for ($i = 0; $i -lt $n; $i++) {
        $ang = 2 * [math]::PI * $i / $n + (Get-Random -Minimum -0.25 -Maximum 0.25)
        $r = 30 + (Get-Random -Minimum 0 -Maximum 17)
        $sz = 3 + (Get-Random -Minimum 0.0 -Maximum 2.5)
        if ($i % 3 -eq 0) { $p = New-Object System.Windows.Shapes.Rectangle; $p.Width = $sz * 0.8; $p.Height = $sz * 1.9; $p.RadiusX = 1; $p.RadiusY = 1 }
        else { $p = New-Object System.Windows.Shapes.Ellipse; $p.Width = $sz; $p.Height = $sz }
        $p.Fill = Solid $cols[$i % $cols.Count]
        [System.Windows.Controls.Canvas]::SetLeft($p, -$p.Width / 2)
        [System.Windows.Controls.Canvas]::SetTop($p, -$p.Height / 2)
        $tg = New-Object System.Windows.Media.TransformGroup
        $rt = New-Object System.Windows.Media.RotateTransform (Get-Random -Maximum 360)
        $rt.CenterX = $p.Width / 2; $rt.CenterY = $p.Height / 2
        $tt = New-Object System.Windows.Media.TranslateTransform
        [void]$tg.Children.Add($rt); [void]$tg.Children.Add($tt)
        $p.RenderTransform = $tg
        [void]$fx.Children.Add($p)
        Anim-FromTo $tt $script:TT::XProperty 0 ([math]::Cos($ang) * $r) 760
        Anim-FromTo $tt $script:TT::YProperty 0 ([math]::Sin($ang) * $r + 7) 760
        Anim-FromTo $rt $script:RT::AngleProperty $rt.Angle ($rt.Angle + (Get-Random -Minimum -240 -Maximum 240)) 760 $null
        $ao = New-Anim 1 0 480; $ao.BeginTime = [TimeSpan]::FromMilliseconds(330)
        $p.BeginAnimation($script:OP, $ao)
    }
    $t = New-Object System.Windows.Threading.DispatcherTimer
    $t.Interval = [TimeSpan]::FromMilliseconds(900); $t.Tag = $fx
    $t.Add_Tick({ param($sender, $ea) $sender.Stop(); $sender.Tag.Children.Clear() })
    $t.Start()
}
function Orb-Shock($o, $hex) {
    $c = $o.C
    $c.Shock.Stroke = Solid $hex
    Anim-FromTo $c.ShockScale $script:ST::ScaleXProperty 0.95 1.8 650
    Anim-FromTo $c.ShockScale $script:ST::ScaleYProperty 0.95 1.8 650
    Anim-FromTo $c.Shock $script:OP 0.9 0 650
}
function Orb-Hop($o, $h = 9) {
    $a = New-Anim 0 (-$h) 140; $a.AutoReverse = $true; $a.EasingFunction = New-Ease 'cubic'
    $a.RepeatBehavior = New-Object System.Windows.Media.Animation.RepeatBehavior(2)
    $o.C.BodyShift.BeginAnimation($script:TT::YProperty, $a)
}
function Orb-Shake($o) {
    $a = New-Anim -2.6 2.6 55; $a.AutoReverse = $true
    $a.RepeatBehavior = New-Object System.Windows.Media.Animation.RepeatBehavior(3)
    $a.FillBehavior = 'Stop'
    $o.C.BodyShift.BeginAnimation($script:TT::XProperty, $a)
}
function Orb-Celebrate($o) {
    Orb-Hop $o 10
    Orb-Shock $o '#7EE08A'
    Burst-Orb $o
}
# ---------------------------------------------------------------- the input pill (top centre), pill-only helpers
function Get-TargetScreen {
    $all = [System.Windows.Forms.Screen]::AllScreens
    if ($Preview -and $PreviewScreen -ge 0 -and $PreviewScreen -lt $all.Count) { return $all[$PreviewScreen] }
    [System.Windows.Forms.Screen]::FromPoint([System.Windows.Forms.Cursor]::Position)
}
function Place-Window {
    $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper $win).Handle
    if ($hwnd -eq [IntPtr]::Zero -or -not $script:workArea) { return }
    $w = [int]($win.ActualWidth * (Get-WinScaleOf $win))
    if ($w -le 0) { return }
    $wa = $script:workArea
    $x = [int]($wa.Left + ($wa.Width - $w) / 2)
    $y = [int]($wa.Top + $(if ($null -ne $script:placeY) { $script:placeY } else { 2 }))
    [void][VcNative]::SetWindowPos($hwnd, [IntPtr]::Zero, $x, $y, 0, 0, 0x0015)
}
function Move-ToCursorScreen { $script:workArea = (Get-TargetScreen).WorkingArea; Place-Window }
$win.Add_SizeChanged({ if ($win.IsVisible) { Place-Window } })

function Set-Wave($on) {
    if ($script:waveTimer) { $script:waveTimer.Stop() }
    if (-not $on) { $wave.Visibility = 'Collapsed'; return }
    $wave.Visibility = 'Visible'
    $script:waveTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:waveTimer.Interval = [TimeSpan]::FromMilliseconds(140)
    $script:waveTimer.Add_Tick({
        foreach ($bar in $script:waveBars) {
            $a = New-Anim $bar.ScaleY ((Get-Random -Minimum 25 -Maximum 100) / 100.0) 130
            $bar.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, $a)
        }
    })
    $script:waveTimer.Start()
}
function Pop-In {
    $e = New-Object System.Windows.Media.Animation.CubicEase
    $e.EasingMode = 'EaseOut'
    $y = New-Anim -26 0 300; $y.EasingFunction = $e
    $sx = New-Anim 0.93 1 300; $sx.EasingFunction = $e
    $sy = New-Anim 0.93 1 300; $sy.EasingFunction = $e
    $pillShift.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $y)
    $pillScale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, $sx)
    $pillScale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, $sy)
    $win.BeginAnimation([System.Windows.UIElement]::OpacityProperty, (New-Anim 0 1 220))
    Anim-FromTo $script:pillOrb.C.OrbScale $script:ST::ScaleXProperty 0.4 1 650 'bouncy'
    Anim-FromTo $script:pillOrb.C.OrbScale $script:ST::ScaleYProperty 0.4 1 650 'bouncy'
}
function Stop-Dictation {
    Set-Wave $false
    if ($script:dictOn) { Send-WinH; $script:dictOn = $false; Start-Sleep -Milliseconds 150 }
}
function Select-ActiveSession {
    Open-Sessions
    for ($tries = 0; $tries -lt 2; $tries++) {
        $rows = @(Get-Rows)
        for ($i = 0; $i -lt $rows.Count; $i++) {
            if ($rows[$i].Kind -eq 'session' -and $rows[$i].S.Id -eq $script:activeSession) { $script:selPos = $i; Show-Sessions; return }
        }
        $script:sessShown = @($script:sessions).Count
    }
    Close-Sessions
}
function Focus-Claude {
    $pr = Get-Process -Name claude -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero } | Select-Object -First 1
    if ($pr) { [void][VcNative]::ShowWindow($pr.MainWindowHandle, 9); [void][VcNative]::SetForegroundWindow($pr.MainWindowHandle) }
    else { try { Start-Process 'claude://code/continue?session=last' } catch {} }
}

# ---------------------------------------------------------------- bubble windows
function Get-BubbleById($id) { foreach ($x in $script:bubbles) { if ($x.Id -eq $id) { return $x } }; $null }
function Find-Bubble($sid) { if (-not $sid) { return $null }; foreach ($x in $script:bubbles) { if ($x.Sid -eq $sid) { return $x } }; $null }

function Get-BubbleScreen($b) {
    $all = [System.Windows.Forms.Screen]::AllScreens
    if ($Preview -and $PreviewScreen -ge 0 -and $PreviewScreen -lt $all.Count) { return $all[$PreviewScreen] }
    if ($b.Screen) { foreach ($sc in $all) { if ($sc.DeviceName -eq $b.Screen) { return $sc } } }
    [System.Windows.Forms.Screen]::PrimaryScreen
}
function Get-BubbleTarget($b) {
    $w = $b.Win
    $sc = Get-WinScaleOf $w
    $pw = [int]($w.ActualWidth * $sc); $ph = [int]($w.ActualHeight * $sc)
    if ($pw -le 0 -or $ph -le 0 -or -not $b.Work) { return $null }
    $wa = $b.Work
    $vm = 8 * $sc; $wm = 24 * $sc; $dotH = 66 * $sc
    $x = $(if ($b.Side -eq 'left') { $wa.Left + $vm - $wm } else { $wa.Right - $pw - $vm + $wm })
    $y = $wa.Top + $vm - $wm + $b.Frac * [math]::Max(1, ($wa.Height - 2 * $vm - $dotH))
    foreach ($o in $script:bubbles) {
        if ($o.Id -ne $b.Id -and $o.CardOpen -and $o.Side -eq $b.Side -and $o.Screen -eq $b.Screen -and $o.Frac -lt $b.Frac -and $o.Win.IsVisible) {
            $y += [math]::Max(0, ($o.Win.ActualHeight - 116) * $sc)
        }
    }
    $y = [math]::Min($y, $wa.Bottom - $ph + $wm - $vm)
    $y = [math]::Max($y, $wa.Top - $wm + $vm)
    @{ X = [int]$x; Y = [int]$y }
}
function Stop-BubbleTween($b) { if ($b.Tw) { $b.Tw.Stop(); $b.Tw = $null }; $b.Suppress = $false }
# Glide with a small overshoot (ease-out-back) so the bubble lands on the edge like it is magnetic.
function Tween-Bubble($b, $sx, $sy, $tx, $ty, $ms, $land) {
    Stop-BubbleTween $b
    $b.Suppress = $true
    $b.TwFrom = @{ sx = $sx; sy = $sy; tx = $tx; ty = $ty; t0 = (Get-Date); ms = $ms; land = [bool]$land }
    $t = New-Object System.Windows.Threading.DispatcherTimer
    $t.Interval = [TimeSpan]::FromMilliseconds(15); $t.Tag = $b.Id
    $t.Add_Tick({
        param($sender, $ea)
        $bb = Get-BubbleById $sender.Tag
        if (-not $bb) { $sender.Stop(); return }
        $f = $bb.TwFrom
        $p = [math]::Min(1.0, ((Get-Date) - $f.t0).TotalMilliseconds / $f.ms)
        $q = $p - 1
        $k = 1 + 2.2 * $q * $q * $q + 1.2 * $q * $q
        $hw = (New-Object System.Windows.Interop.WindowInteropHelper $bb.Win).Handle
        [void][VcNative]::SetWindowPos($hw, [IntPtr]::Zero, [int]($f.sx + ($f.tx - $f.sx) * $k), [int]($f.sy + ($f.ty - $f.sy) * $k), 0, 0, 0x0015)
        if ($p -ge 1.0) { Stop-BubbleTween $bb; Place-Bubble $bb; if ($f.land) { Land-Wobble $bb } }
    })
    $b.Tw = $t; $t.Start()
}
function Land-Wobble($b) {
    $c = $b.C
    $c.JR1.Angle = 0; $c.JR2.Angle = 0
    Anim-FromTo $c.JS $script:ST::ScaleXProperty 0.84 1 750 'elastic'
    Anim-FromTo $c.JS $script:ST::ScaleYProperty 1.13 1 750 'elastic'
}
function Place-Bubble($b) {
    if ($b.Suppress -or $b.Closing) { return }
    $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper $b.Win).Handle
    if ($hwnd -eq [IntPtr]::Zero) { return }
    $t = Get-BubbleTarget $b
    if (-not $t) { return }
    [void][VcNative]::SetWindowPos($hwnd, [IntPtr]::Zero, $t.X, $t.Y, 0, 0, 0x0015)
}
# Stack bubbles down the edge: pick the nearest free slot on that side of that monitor.
function Resolve-Slot($b) {
    if (-not $b.Work) { return }
    $sc = Get-WinScaleOf $b.Win
    $vm = 8 * $sc; $dotH = 66 * $sc
    $step = [math]::Max(0.01, ($dotH + 14 * $sc) / [math]::Max(1, ($b.Work.Height - 2 * $vm - $dotH)))
    $others = @($script:bubbles | Where-Object { $_.Id -ne $b.Id -and $_.Side -eq $b.Side -and $_.Screen -eq $b.Screen })
    $base = [math]::Min(1.0, [math]::Max(0.0, $b.Frac))
    for ($k = 0; $k -lt 60; $k++) {
        $sign = $(if ($k % 2 -eq 1) { 1 } else { -1 })
        $cand = $(if ($k -eq 0) { $base } else { $base + $sign * [math]::Ceiling($k / 2.0) * $step })
        if ($cand -lt 0 -or $cand -gt 1) { continue }
        $clash = $false
        foreach ($o in $others) { if ([math]::Abs($o.Frac - $cand) -lt ($step * 0.97)) { $clash = $true; break } }
        if (-not $clash) { $b.Frac = $cand; return }
    }
}

function Get-FreeColor {
    $used = @($script:bubbles | ForEach-Object { $_.Color })
    for ($i = 0; $i -lt $script:palette.Count; $i++) { if ($used -notcontains $i) { return $i } }
    $script:bubbleSeq % $script:palette.Count
}
function New-Bubble($sid, $localId, $project, $title, $pendingCwd, $auto) {
    $script:bubbleSeq++
    $w = [System.Windows.Markup.XamlReader]::Parse($xaml)
    $c = @{}
    foreach ($n in $script:bubbleNames) { $c[$n] = $w.FindName($n) }
    $b = @{
        Id = $script:bubbleSeq; Win = $w; C = $c; Sid = $sid; LocalId = $localId; Project = [string]$project; Title = [string]$title
        PendingCwd = $pendingCwd; Auto = [bool]$auto; Created = (Get-Date); Last = (Get-Date)
        Color = (Get-FreeColor); ColorKey = $null; Mood = $null
        CardOpen = $false; LogOpen = $false; AutoOpened = $false; RetractAt = $null; Peek = $false; NoPeek = $false
        Hover = $false; HoverAt = $null; LeaveAt = $null; ViewExp = $false; ViewCard = $false
        Alerts = (New-Object System.Collections.ArrayList); Waiting = $true; WaitStart = (Get-Date); LastShake = $null
        Side = $script:dockSide; Frac = $script:dockFrac; Screen = $script:dockScreen; Work = $null
        Pressed = $false; Dragging = $false; DownCur = $null; DownL = 0; DownT = 0; DownR = 0; DownSrc = $null; DoubleDown = $false
        LastX = 0; LastY = 0; LastT = 0; Vx = 0.0; Vy = 0.0; FX = 0.0; FY = 0.0; WX = 0.0; WY = 0.0; WanderAt = $null; Scale = 1.0; ScaleAt = $null
        Suppress = $false; Tw = $null; TwFrom = $null; LogSig = ''; LogN = 0; PulseWanted = $null; BadgeShown = $null; Shining = $false
        Note = ''; NoteUntil = $null; MoodUntil = $null; Closing = $false; QuietSince = $null; PeekTimer = $null; ZPhase = 0
    }
    $b.Orb = New-OrbLink $c $false
    $w.Tag = $b.Id
    $w.ShowActivated = $false
    $c.TextCol.Visibility = 'Collapsed'
    $c.StatusCol.Visibility = 'Visible'
    # card chrome, made per bubble so its accent can change
    $bg = New-Object System.Windows.Media.LinearGradientBrush
    $bg.StartPoint = New-Object System.Windows.Point 0, 0; $bg.EndPoint = New-Object System.Windows.Point 0, 1
    [void]$bg.GradientStops.Add((New-Object System.Windows.Media.GradientStop (To-Color '#F71C1C24'), 0))
    [void]$bg.GradientStops.Add((New-Object System.Windows.Media.GradientStop (To-Color '#F90E0E12'), 1))
    $bd = New-Object System.Windows.Media.LinearGradientBrush
    $bd.StartPoint = New-Object System.Windows.Point 0, 0; $bd.EndPoint = New-Object System.Windows.Point 0, 1
    [void]$bd.GradientStops.Add((New-Object System.Windows.Media.GradientStop (To-Color '#702FC4A3'), 0))
    [void]$bd.GradientStops.Add((New-Object System.Windows.Media.GradientStop (To-Color '#12FFFFFF'), 0.55))
    $fx = New-Object System.Windows.Media.Effects.DropShadowEffect
    $fx.BlurRadius = 34; $fx.ShadowDepth = 9; $fx.Direction = 270; $fx.Opacity = 0.55; $fx.Color = [System.Windows.Media.Colors]::Black
    $b.CardBg = $bg; $b.CardBorder = $bd; $b.CardFx = $fx
    # shimmering text for the current action while Claude works
    $sh = New-Object System.Windows.Media.LinearGradientBrush
    $sh.StartPoint = New-Object System.Windows.Point 0, 0; $sh.EndPoint = New-Object System.Windows.Point 1, 0
    $baseC = To-Color '#B4B4BE'
    foreach ($st in @(@($baseC, 0), @($baseC, -0.4), @((To-Color '#FFFFFF'), -0.22), @($baseC, -0.04), @($baseC, 1))) {
        [void]$sh.GradientStops.Add((New-Object System.Windows.Media.GradientStop $st[0], $st[1]))
    }
    $b.Shine = $sh
    $sa = New-Anim -90 330 1500
    $sa.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
    [System.Windows.Media.Animation.Timeline]::SetDesiredFrameRate($sa, 30)
    $c.ShimmerShift.BeginAnimation($script:TT::XProperty, $sa)
    [void]$script:bubbles.Add($b)
    $null = (New-Object System.Windows.Interop.WindowInteropHelper $w).EnsureHandle()
    $w.Add_PreviewMouseLeftButtonDown({ param($sender, $ea) Bb-Down (Get-BubbleById $sender.Tag) $ea })
    $w.Add_PreviewMouseMove({ param($sender, $ea) Bb-Move (Get-BubbleById $sender.Tag) $ea })
    $w.Add_PreviewMouseLeftButtonUp({ param($sender, $ea) Bb-Up (Get-BubbleById $sender.Tag) $ea })
    $w.Add_MouseRightButtonUp({ param($sender, $ea) Show-BubbleMenu (Get-BubbleById $sender.Tag) })
    $w.Add_MouseEnter({ param($sender, $ea) $bb = Get-BubbleById $sender.Tag; if ($bb -and -not $bb.Closing) { Bb-Hover $bb $true } })
    $w.Add_MouseLeave({ param($sender, $ea) $bb = Get-BubbleById $sender.Tag; if ($bb -and -not $bb.Closing) { Bb-Hover $bb $false } })
    $c.CloseX.Add_MouseLeftButtonUp({ param($sender, $ea) $ea.Handled = $true; Close-Bubble (Get-BubbleById ([System.Windows.Window]::GetWindow($sender)).Tag) $true })
    $c.HdrClose.Add_MouseLeftButtonUp({ param($sender, $ea) $ea.Handled = $true; Close-Bubble (Get-BubbleById ([System.Windows.Window]::GetWindow($sender)).Tag) $true })
    $c.HdrMin.Add_MouseLeftButtonUp({ param($sender, $ea) $ea.Handled = $true; Toggle-BubbleCard (Get-BubbleById ([System.Windows.Window]::GetWindow($sender)).Tag) })
    $w.Add_SizeChanged({ param($sender, $ea) if ($sender.IsVisible) { foreach ($x in @($script:bubbles)) { Place-Bubble $x } } })
    $c.BtnOpenClaude.Add_MouseLeftButtonUp({ param($sender, $ea) $ea.Handled = $true; Open-BubbleSession (Get-BubbleById ([System.Windows.Window]::GetWindow($sender)).Tag) })
    $c.BtnAllow.Add_MouseLeftButtonUp({ param($sender, $ea) $ea.Handled = $true; Answer-Permission (Get-BubbleById ([System.Windows.Window]::GetWindow($sender)).Tag) 'allow' })
    $c.BtnSpeak.Add_MouseLeftButtonUp({ param($sender, $ea) $ea.Handled = $true; Speak-Answer (Get-BubbleById ([System.Windows.Window]::GetWindow($sender)).Tag) })
    $c.BtnDeny.Add_MouseLeftButtonUp({ param($sender, $ea) $ea.Handled = $true; Answer-Permission (Get-BubbleById ([System.Windows.Window]::GetWindow($sender)).Tag) 'deny' })
    $c.OpenBtn.Add_MouseLeftButtonUp({ param($sender, $ea) $ea.Handled = $true; Open-BubbleSession (Get-BubbleById ([System.Windows.Window]::GetWindow($sender)).Tag) })
    $c.ReplyBtn.Add_MouseLeftButtonUp({ param($sender, $ea) $ea.Handled = $true; Reply-ToBubble (Get-BubbleById ([System.Windows.Window]::GetWindow($sender)).Tag) })
    if ($sid) { $script:dismissed.Remove($sid) }
    if (-not $auto) { Save-Bubbles }
    $b
}
function Show-Bubble($b) {
    $b.Work = (Get-BubbleScreen $b).WorkingArea
    $b.Screen = (Get-BubbleScreen $b).DeviceName
    Resolve-Slot $b
    $b.Win.Opacity = 0
    Apply-BubbleView $b
    $b.Win.ShowActivated = $false
    $b.Win.Show()
    Place-Bubble $b
    $b.Win.BeginAnimation($script:OP, (New-Anim 0 1 200))
    Anim-FromTo $b.C.OrbScale $script:ST::ScaleXProperty 0.2 1 700 'bouncy'
    Anim-FromTo $b.C.OrbScale $script:ST::ScaleYProperty 0.2 1 700 'bouncy'
    Update-Bubble $b
    if (-not $b.Auto) { Save-Bubbles }
}
function Close-Bubble($b, $dismiss) {
    if (-not $b -or $b.Closing) { return }
    $b.Closing = $true
    if ($dismiss -and $b.Sid) { $script:dismissed[$b.Sid] = $true }
    Stop-BubbleTween $b
    if ($b.PeekTimer) { $b.PeekTimer.Stop() }
    [VcGaze]::Remove($b.Orb)
    foreach ($a in @($b.Alerts)) { Release-Alert $a }
    [void]$script:bubbles.Remove($b)
    Save-Bubbles
    if ($script:lastVoiceBubble -and $script:lastVoiceBubble.Id -eq $b.Id) { $script:lastVoiceBubble = $null }
    Anim-Scale $b.C.OrbScale 0 240 'back' 'EaseIn'
    Anim-Scale $b.C.PillScale 0.9 220 'cubic' 'EaseIn'
    $f = New-Anim 1 0 230; $f.BeginTime = [TimeSpan]::FromMilliseconds(40)
    $b.Win.BeginAnimation($script:OP, $f)
    $t = New-Object System.Windows.Threading.DispatcherTimer
    $t.Interval = [TimeSpan]::FromMilliseconds(290); $t.Tag = $b.Win
    $t.Add_Tick({ param($sender, $ea) $sender.Stop(); try { $sender.Tag.Close() } catch {} })
    $t.Start()
    foreach ($o in @($script:bubbles)) { Place-Bubble $o }
}
function Close-AllBubbles { foreach ($x in @($script:bubbles)) { Close-Bubble $x $false } }

function Set-BubbleDockSide($b) {
    $c = $b.C
    $star = New-Object System.Windows.GridLength 1, 'Star'
    if ($b.Side -eq 'right') {
        $c.ColA.Width = $star; $c.ColB.Width = [System.Windows.GridLength]::Auto
        [System.Windows.Controls.Grid]::SetColumn($c.Col1, 0); [System.Windows.Controls.Grid]::SetColumn($c.BlobHost, 1)
    } else {
        $c.ColA.Width = [System.Windows.GridLength]::Auto; $c.ColB.Width = $star
        [System.Windows.Controls.Grid]::SetColumn($c.BlobHost, 0); [System.Windows.Controls.Grid]::SetColumn($c.Col1, 1)
    }
}
# Three looks: the orb alone, a peek (hover: name + what it is doing), and the full card (click).
# The orb never moves between them: its padding is 7 on the edge side and on top in every look.
function Apply-BubbleView($b) {
    $c = $b.C
    $b.Work = (Get-BubbleScreen $b).WorkingArea
    Set-BubbleDockSide $b
    $card = [bool]$b.CardOpen
    $exp = ($card -or $b.Peek)
    $left = ($b.Side -ne 'right')
    if (-not $exp) {
        $c.Col1.Visibility = 'Collapsed'
        $c.BlobHost.Margin = New-Object System.Windows.Thickness 0
        $c.Pill.Padding = New-Object System.Windows.Thickness 7
        $c.Pill.CornerRadius = New-Object System.Windows.CornerRadius 33
        $c.Pill.Background = [System.Windows.Media.Brushes]::Transparent
        $c.Pill.BorderBrush = [System.Windows.Media.Brushes]::Transparent
        $c.Pill.Effect = $null
    } else {
        $c.Col1.Visibility = 'Visible'; $c.TextCol.Visibility = 'Collapsed'; $c.StatusCol.Visibility = 'Visible'
        $c.Pill.Background = $b.CardBg; $c.Pill.BorderBrush = $b.CardBorder; $c.Pill.Effect = $b.CardFx
        $far = $(if ($card) { 16 } else { 20 }); $bot = $(if ($card) { 12 } else { 7 })
        $c.BlobHost.Margin = $(if ($left) { New-Object System.Windows.Thickness 0, 0, 13, 0 } else { New-Object System.Windows.Thickness 13, 0, 0, 0 })
        $c.Pill.Padding = $(if ($left) { New-Object System.Windows.Thickness 7, 7, $far, $bot } else { New-Object System.Windows.Thickness $far, 7, 7, $bot })
        $c.Pill.CornerRadius = New-Object System.Windows.CornerRadius $(if ($card) { 24 } else { 33 })
        $c.Col1.VerticalAlignment = $(if ($card) { 'Top' } else { 'Center' })
        $c.Col1.Margin = $(if ($card) { New-Object System.Windows.Thickness 0, 5, 0, 0 } else { New-Object System.Windows.Thickness 0 })
        $c.StatusCol.Width = $(if ($card) { 330 } else { [double]::NaN })
        $c.TitleText.Visibility = $(if ($card -and $b.Title) { 'Visible' } else { 'Collapsed' })
        $c.HdrMin.Visibility = $(if ($card) { 'Visible' } else { 'Collapsed' })
        $c.HdrClose.Visibility = $(if ($card) { 'Visible' } else { 'Collapsed' })
        $c.MetaText.Visibility = $(if ($card) { 'Visible' } else { 'Collapsed' })
        $c.ActText.MaxWidth = $(if ($card) { 300 } else { 240 })
        $c.LabelHost.Visibility = 'Collapsed'
        if (-not $b.ViewExp -or ($card -and -not $b.ViewCard)) {
            Anim-FromTo $c.ColShift $script:TT::XProperty $(if ($left) { -12 } else { 12 }) 0 260
            Anim-FromTo $c.Col1 $script:OP 0 1 220
            $b.CardBg.BeginAnimation([System.Windows.Media.Brush]::OpacityProperty, (New-Anim 0.3 1 180))
        }
    }
    $b.ViewExp = $exp; $b.ViewCard = $card
    # the floating close button sits on the side away from the screen edge
    if ($left) { $c.CloseX.HorizontalAlignment = 'Right'; $c.CloseX.Margin = New-Object System.Windows.Thickness 0, -9, -13, 0 }
    else       { $c.CloseX.HorizontalAlignment = 'Left';  $c.CloseX.Margin = New-Object System.Windows.Thickness -13, -9, 0, 0 }
    $c.CloseX.Visibility = $(if (-not $card -and $b.Hover -and -not $b.Dragging) { 'Visible' } else { 'Collapsed' })
    $b.PulseWanted = $null
    Update-Bubble $b
    Place-Bubble $b
    if ($exp) { Raise-Bubble $b }
    foreach ($o in @($script:bubbles)) { if ($o.Id -ne $b.Id) { Place-Bubble $o } }
}
function Raise-Bubble($b) {
    $hw = (New-Object System.Windows.Interop.WindowInteropHelper $b.Win).Handle
    if ($hw -ne [IntPtr]::Zero) { [void][VcNative]::SetWindowPos($hw, [IntPtr](-1), 0, 0, 0, 0, 0x0013) }
}

# ---------------------------------------------------------------- bubble visuals
function Set-BubbleColor($b, $amber) {
    $key = "$($b.Color)|$amber"
    if ($b.ColorKey -eq $key) { return }
    $b.ColorKey = $key
    $pair = $(if ($amber) { $script:amberPair } else { $script:palette[$b.Color] })
    $c = $b.C
    Set-OrbColors $c $pair
    $c.LabelText.Foreground = Solid $pair[0]
    $c.ThinkBar.Background = Solid $pair[1]
    $c.ReplyBtn.Background = Solid $pair[0]
    $c.StatusDot.Fill = Solid $pair[0]
    $sh = New-Object System.Windows.Media.LinearGradientBrush
    $sh.StartPoint = New-Object System.Windows.Point 0, 0; $sh.EndPoint = New-Object System.Windows.Point 1, 0
    [void]$sh.GradientStops.Add((New-Object System.Windows.Media.GradientStop (To-Color $pair[0] 0), 0))
    [void]$sh.GradientStops.Add((New-Object System.Windows.Media.GradientStop (To-Color $pair[0]), 0.5))
    [void]$sh.GradientStops.Add((New-Object System.Windows.Media.GradientStop (To-Color $pair[0] 0), 1))
    $c.Shimmer.Child.Background = $sh
    $b.CardBorder.GradientStops[0].Color = To-Color $pair[1] 0x80
}
function Bb-Pulse($b, $on) {
    $c = $b.C
    if ($on) {
        Anim-Loop $c.RingScale $script:ST::ScaleXProperty 0.95 1.5 1400 24 $false $null
        Anim-Loop $c.RingScale $script:ST::ScaleYProperty 0.95 1.5 1400 24 $false $null
        Anim-Loop $c.Ring $script:OP 0.7 0 1400 24 $false $null
    } else {
        $c.RingScale.BeginAnimation($script:ST::ScaleXProperty, $null)
        $c.RingScale.BeginAnimation($script:ST::ScaleYProperty, $null)
        $c.Ring.BeginAnimation($script:OP, $null)
        $c.Ring.Opacity = 0
    }
}
function Set-Shine($b, $on) {
    if ($b.Shining -eq $on) { return }
    $b.Shining = $on
    $stops = $b.Shine.GradientStops
    $k = 1
    foreach ($pair in @(@(-0.4, 1.0), @(-0.22, 1.18), @(-0.04, 1.36))) {
        if ($on) { Anim-Loop $stops[$k] ([System.Windows.Media.GradientStop]::OffsetProperty) $pair[0] $pair[1] 1700 30 $false $null }
        else { $stops[$k].BeginAnimation([System.Windows.Media.GradientStop]::OffsetProperty, $null) }
        $k++
    }
    $b.C.ActText.Foreground = $(if ($on) { $b.Shine } else { $script:brushText })
}
function Set-BubbleNote($b, $text, $secs = 25) { if ($b) { $b.Note = $text; $b.NoteUntil = (Get-Date).AddSeconds($secs); Update-Bubble $b } }

function New-LogRow($it, $first, $last, $fresh) {
    $kc = $(if ($script:kindColor.ContainsKey($it.Kind)) { $script:kindColor[$it.Kind] } else { '#8A8A96' })
    $gl = $(if ($script:kindGlyph.ContainsKey($it.Kind)) { $script:kindGlyph[$it.Kind] } else { 0xE946 })
    $g = New-Object System.Windows.Controls.Grid
    $g.Height = 25
    foreach ($wd in @((New-Object System.Windows.GridLength 26), (New-Object System.Windows.GridLength 1, 'Star'), [System.Windows.GridLength]::Auto)) {
        $cd = New-Object System.Windows.Controls.ColumnDefinition; $cd.Width = $wd; [void]$g.ColumnDefinitions.Add($cd)
    }
    if (-not ($first -and $last)) {
        $ln = New-Object System.Windows.Shapes.Rectangle
        $ln.Width = 1.5; $ln.Fill = $script:brushLine; $ln.HorizontalAlignment = 'Left'
        $ln.Margin = New-Object System.Windows.Thickness 8.25, $(if ($first) { 12 } else { 0 }), 0, $(if ($last) { 13 } else { 0 })
        [void]$g.Children.Add($ln)
    }
    $chip = New-Object System.Windows.Controls.Border
    $chip.Width = 18; $chip.Height = 18; $chip.CornerRadius = New-Object System.Windows.CornerRadius 6
    $chip.Background = Solid '#FF1A1A20'
    $chip.BorderBrush = Solid $kc 0x55; $chip.BorderThickness = New-Object System.Windows.Thickness 1
    $chip.HorizontalAlignment = 'Left'; $chip.VerticalAlignment = 'Center'
    $ic = New-Object System.Windows.Controls.TextBlock
    $ic.Text = [string][char]$gl; $ic.FontFamily = $script:iconFont; $ic.FontSize = 9
    $ic.Foreground = Solid $kc; $ic.HorizontalAlignment = 'Center'; $ic.VerticalAlignment = 'Center'
    $chip.Child = $ic
    [void]$g.Children.Add($chip)
    $tx = New-Object System.Windows.Controls.TextBlock
    $tx.Text = $it.Text; $tx.FontFamily = $script:uiFont; $tx.FontSize = 12
    $tx.Foreground = Solid $(if ($last) { '#F4F4F6' } else { '#9E9EAA' })
    $tx.TextTrimming = 'CharacterEllipsis'; $tx.VerticalAlignment = 'Center'
    $tx.Margin = New-Object System.Windows.Thickness 2, 0, 8, 0
    [System.Windows.Controls.Grid]::SetColumn($tx, 1)
    [void]$g.Children.Add($tx)
    $tm = New-Object System.Windows.Controls.TextBlock
    $tm.Text = $it.T; $tm.FontFamily = $script:monoFont; $tm.FontSize = 10
    $tm.Foreground = Solid '#55555F'; $tm.VerticalAlignment = 'Center'
    [System.Windows.Controls.Grid]::SetColumn($tm, 2)
    [void]$g.Children.Add($tm)
    if ($fresh) {
        $tt = New-Object System.Windows.Media.TranslateTransform
        $g.RenderTransform = $tt
        Anim-FromTo $tt $script:TT::YProperty 8 0 260
        Anim-FromTo $g $script:OP 0 1 260
    }
    $g
}
function Render-Log($b, $sess) {
    $items = @($sess.Log | Select-Object -Last 14)
    $sig = "$($sess.Id)|$($sess.Log.Count)|" + $(if ($items.Count -gt 0) { $items[$items.Count - 1].Text } else { '' })
    if ($sig -eq $b.LogSig) { return }
    $fresh = ($b.LogSig -and $b.LogSig.StartsWith("$($sess.Id)|") -and $sess.Log.Count -gt $b.LogN)
    $b.LogSig = $sig; $b.LogN = $sess.Log.Count
    $list = $b.C.LogList
    $list.Children.Clear()
    for ($i = 0; $i -lt $items.Count; $i++) {
        $last = ($i -eq $items.Count - 1)
        [void]$list.Children.Add((New-LogRow $items[$i] ($i -eq 0) $last ($fresh -and $last)))
    }
    $b.C.LogScroll.ScrollToEnd()
}

function Update-Bubble($b) {
    if (-not $b -or $b.Closing) { return }
    $c = $b.C
    $sess = $null; if ($b.Sid -and $script:hookSessions.ContainsKey($b.Sid)) { $sess = $script:hookSessions[$b.Sid] }
    $sep = '  ' + [string][char]0xB7 + '  '
    $accent = $script:palette[$b.Color][0]
    $now = Get-Date
    $want = $false; $shim = $false; $badge = $null; $amber = $false; $mood = 'idle'; $shine = $false
    $state = 'READY'; $stateCol = '#9A9AA6'
    if ($b.Alerts.Count -gt 0) {
        $a = $b.Alerts[0]
        $live = Test-Answerable $a
        $q = $(if ($live) { Get-CurrentQuestion $a } else { $null })
        $mode = $(if ($q) { 'q' } elseif ($live) { 'perm' } else { 'off' })
        $more = $(if ($b.Alerts.Count -gt 1) { "+$($b.Alerts.Count - 1) more waiting" } else { $null })
        if ($q) {
            $nq = @($a.Q).Count
            $c.ActText.Text = 'Claude asks: ' + (Cut-Text $q.question 70)
            $c.MetaText.Text = $(if ($more) { $more } else { 'Answer here, or in Claude' })
            $c.AlertHead.Text = $(if ([string]$q.header) { [string]$q.header } else { 'Claude has a question' }) + $(if ($nq -gt 1) { "   $($a.QIndex + 1) of $nq" } else { '' })
            $c.AlertBody.Text = [string]$q.question
            $c.AlertBox.Visibility = 'Visible'
        } else {
            $c.ActText.Text = $a.Head
            $c.MetaText.Text = $(if ($more) { $more } elseif ($live) { 'Allow or deny here, or answer in Claude' } else { 'Answer it in Claude - I clear myself after' })
            $c.AlertHead.Text = $a.Head; $c.AlertBody.Text = $a.Body
            $c.AlertBox.Visibility = $(if ($a.Body) { 'Visible' } else { 'Collapsed' })
        }
        if ($b.AlertMode -ne $mode) {
            # answerable: the answer buttons lead and "open Claude" shrinks to an icon
            $b.AlertMode = $mode
            $on = ($mode -ne 'off')
            $c.BtnAllow.Visibility = $(if ($mode -eq 'perm') { 'Visible' } else { 'Collapsed' })
            $c.BtnAllowText.Text = 'Allow'; $c.BtnAllowIcon.Text = [string][char]0xE73E
            $c.BtnDeny.Visibility = $(if ($mode -eq 'perm') { 'Visible' } else { 'Collapsed' })
            $c.BtnSpeak.Visibility = $(if ($mode -eq 'q') { 'Visible' } else { 'Collapsed' })
            $c.AlertHint.Visibility = $(if ($on) { 'Visible' } else { 'Collapsed' })
            $c.AlertHint.Text = 'or say ' + [char]0x201C + 'allow' + [char]0x201D + ' / ' + [char]0x201C + 'deny' + [char]0x201D
            # a question reads as prose, a command as code
            $c.AlertBody.FontFamily = $(if ($mode -eq 'q') { 'Segoe UI Variable Text, Segoe UI' } else { 'Consolas' })
            $c.AlertBody.FontSize = $(if ($mode -eq 'q') { 12.5 } else { 11.5 })
            $c.BtnOpenText.Visibility = $(if ($on) { 'Collapsed' } else { 'Visible' })
            $c.BtnOpenIcon.Margin = $(if ($on) { '0,1,0,0' } else { '0,1,7,0' })
            $c.BtnOpenIcon.Foreground = Solid $(if ($on) { '#E6E6EC' } else { '#3A2A05' })
            $c.BtnOpenClaude.Background = Solid $(if ($on) { '#26FFFFFF' } else { '#F6C453' })
            $c.BtnOpenClaude.Padding = $(if ($on) { '10,7,10,7' } else { '13,6,16,7' })
        }
        # options are rebuilt only when the question or the picks change, not every tick
        $qsig = $(if ($q) { "$($a.Ev.Id)|$($a.QIndex)|" + (@($a.Picked) -join ',') } else { '' })
        if ($b.QSig -ne $qsig) { $b.QSig = $qsig; Render-QOptions $b $a $q }
        $c.AlertPanel.Visibility = $(if ($b.CardOpen) { 'Visible' } else { 'Collapsed' })
        $amber = $true; $want = $true; $badge = '!'; $mood = 'alert'; $state = 'NEEDS YOU'; $stateCol = '#F6C453'
    } else {
        $c.AlertPanel.Visibility = 'Collapsed'
        $working = ($sess -and $sess.Working -and (($now - $sess.Last).TotalSeconds -lt 180))
        if ($b.Note -and $b.Waiting -and $b.NoteUntil -and $now -lt $b.NoteUntil) {
            $c.ActText.Text = $b.Note; $c.MetaText.Text = 'I start following as soon as you send it'
            $want = $true; $mood = 'listen'; $state = 'WAITING'; $stateCol = $accent
        } elseif ($working) {
            $c.ActText.Text = $sess.Activity
            $c.MetaText.Text = ($now - $sess.Start).ToString('m\:ss') + $sep + "$($sess.Steps) steps"
            $shim = $true; $shine = $true; $mood = 'working'; $state = 'WORKING'; $stateCol = $accent
        } elseif ($sess -and $sess.Done -and -not $b.Waiting) {
            $c.ActText.Text = $(if ($sess.Reply) { $sess.Reply } else { 'All done' })
            $c.MetaText.Text = 'finished in ' + ($sess.DoneAt - $sess.Start).ToString('m\:ss') + $sep + "$($sess.Steps) steps"
            $badge = [string][char]0x2713; $mood = 'done'; $state = 'DONE'; $stateCol = '#7EE08A'
        } elseif ($sess -and $sess.Working -and -not $b.Waiting) {
            $c.ActText.Text = 'Gone quiet'
            $c.MetaText.Text = 'nothing for ' + [int](($now - $sess.Last).TotalMinutes) + ' min'
            $state = 'QUIET'
        } elseif ($b.Waiting) {
            $c.ActText.Text = 'Waiting for your message in Claude...'
            $c.MetaText.Text = 'send it there and I will follow along'
            $want = $true; $mood = 'listen'; $state = 'WAITING'; $stateCol = $accent
        } else {
            $c.ActText.Text = 'Ready when you are'
            $c.MetaText.Text = 'Reply to talk to this session'
        }
    }
    # quiet bubbles nod off after a while; hovering wakes them up
    $lastAct = $b.Last; if ($sess -and $sess.Last -gt $lastAct) { $lastAct = $sess.Last }
    if (($mood -eq 'idle' -or $mood -eq 'done') -and -not $b.Hover -and -not $b.CardOpen -and (($now - $lastAct).TotalMinutes -ge 4)) { $mood = 'sleep'; if ($state -ne 'DONE') { $state = 'ASLEEP' } }
    if ($b.MoodUntil -and $now -lt $b.MoodUntil) { $mood = 'happy' }
    if ($b.Dragging) { $mood = 'drag' }
    Set-BubbleColor $b $amber
    Set-OrbMood $b $mood
    Set-Shine $b ($shine -and $b.CardOpen)
    $c.ProjText.Text = $(if ($b.Project) { $b.Project } else { 'Claude' })
    $c.TitleText.Text = Cut-Text $b.Title 34
    if ($c.StateText.Text -ne $state) {
        $c.StateText.Text = $state
        $c.StateText.Foreground = Solid $stateCol
        $c.StateChip.Background = Solid $stateCol 0x26
    }
    $ini = Get-Initials $b.Project
    $c.LabelText.Text = $ini
    $c.LabelHost.Visibility = $(if ($ini -and -not $b.ViewExp) { 'Visible' } else { 'Collapsed' })
    $c.Shimmer.Visibility = $(if ($shim -and $b.CardOpen) { 'Visible' } else { 'Collapsed' })
    if ($b.BadgeShown -ne $badge) {
        $b.BadgeShown = $badge
        if ($badge) {
            $c.BadgeHost.Visibility = 'Visible'; $c.BadgeText.Text = $badge
            $c.BadgeBg.Fill = Solid $(if ($badge -eq '!') { '#F6C453' } else { '#7EE08A' })
            $c.BadgeText.Foreground = Solid $(if ($badge -eq '!') { '#3A2A05' } else { '#0B2A12' })
            Anim-FromTo $c.BadgeScale $script:ST::ScaleXProperty 0 1 600 'bouncy'
            Anim-FromTo $c.BadgeScale $script:ST::ScaleYProperty 0 1 600 'bouncy'
        } else { $c.BadgeHost.Visibility = 'Collapsed' }
    }
    if ($b.CardOpen -and $b.LogOpen) {
        $c.LogPanel.Visibility = 'Visible'
        if ($sess) {
            Render-Log $b $sess
            $c.LogCount.Text = "$($sess.Steps) steps" + $sep + ($(if ($sess.Done -and $sess.DoneAt) { $sess.DoneAt } else { $now }) - $sess.Start).ToString('m\:ss')
            $n = Get-Notes $sess
            $c.ThinkText.Text = $n
            $vis = $(if ($n) { 'Visible' } else { 'Collapsed' })
            $c.ThinkLabel.Visibility = $vis; $c.ThinkBox.Visibility = $vis
        } else {
            if ($c.LogList.Children.Count -eq 0 -or $b.LogSig) {
                $c.LogList.Children.Clear(); $b.LogSig = ''
                [void]$c.LogList.Children.Add((New-LogRow ([pscustomobject]@{ T = ''; Kind = 'info'; Text = 'Nothing yet - I light up when Claude starts' }) $true $true $false))
            }
            $c.LogCount.Text = ''
            $c.ThinkLabel.Visibility = 'Collapsed'; $c.ThinkBox.Visibility = 'Collapsed'
        }
    } else { $c.LogPanel.Visibility = 'Collapsed' }
    $c.Pill.ToolTip = $null
    if ($b.PulseWanted -ne $want) { $b.PulseWanted = $want; Bb-Pulse $b $want }
}

# ---------------------------------------------------------------- mouse: hover, drag, click, snap
function Test-InButton($b, $src) {
    foreach ($n in @('BtnOpenClaude', 'BtnAllow', 'BtnDeny', 'BtnSpeak', 'QOptions', 'ReplyBtn', 'OpenBtn', 'CloseX', 'HdrMin', 'HdrClose')) { if (Test-InVisual $src $b.C[$n]) { return $true } }
    $false
}
function Bb-Hover($b, $on) {
    $c = $b.C
    if ($on) {
        if (-not $b.Hover) { $b.HoverAt = Get-Date }
        $b.Hover = $true; $b.Orb.Hover = $true
        if (-not $b.CardOpen -and -not $b.Dragging) { $c.CloseX.Visibility = 'Visible' }
        if (-not $b.Dragging -and -not $b.Pressed) { Anim-Scale $c.OrbScale 1.08 280 'back' }
        if ($b.Mood -eq 'sleep') { Update-Bubble $b; Orb-Hop $b 5 }
        Schedule-Peek $b 170
    } else {
        if ($b.Dragging) { return }
        $b.Hover = $false; $b.Orb.Hover = $false; $b.LeaveAt = Get-Date; $b.NoPeek = $false
        if (-not $b.CardOpen) { $c.CloseX.Visibility = 'Collapsed' }
        Anim-Scale $c.OrbScale 1 280 'back'
        Schedule-Peek $b 300
    }
}
# Open the peek after a short hover, close it a moment after the mouse leaves (the grace stops flicker while the window resizes).
function Schedule-Peek($b, $ms) {
    if ($b.PeekTimer) { $b.PeekTimer.Stop() }
    $t = New-Object System.Windows.Threading.DispatcherTimer
    $t.Interval = [TimeSpan]::FromMilliseconds($ms); $t.Tag = $b.Id
    $t.Add_Tick({ param($sender, $ea) $sender.Stop(); $bb = Get-BubbleById $sender.Tag; if ($bb -and -not $bb.Closing) { Step-Peek $bb (Get-Date) } })
    $b.PeekTimer = $t; $t.Start()
}
function Step-Peek($b, $now) {
    if ($b.CardOpen -or $b.Pressed -or $b.Dragging -or $b.Suppress) { return }
    if ($b.Hover -and -not $b.Peek -and -not $b.NoPeek -and $b.HoverAt -and ($now - $b.HoverAt).TotalMilliseconds -gt 140) { $b.Peek = $true; Apply-BubbleView $b }
    elseif ($b.Peek -and -not $b.Hover -and $b.LeaveAt -and ($now - $b.LeaveAt).TotalMilliseconds -gt 250) { $b.Peek = $false; Apply-BubbleView $b }
}
function Bb-Down($b, $e) {
    if (-not $b) { return }
    $b.Pressed = $true; $b.Dragging = $false
    $b.DoubleDown = ($e.ClickCount -ge 2)
    $b.DownCur = [System.Windows.Forms.Cursor]::Position
    $hw = (New-Object System.Windows.Interop.WindowInteropHelper $b.Win).Handle
    $rc0 = New-Object VcNative+RECT
    [void][VcNative]::GetWindowRect($hw, [ref]$rc0)
    $b.DownL = $rc0.Left; $b.DownT = $rc0.Top; $b.DownR = $rc0.Right; $b.DownSrc = $e.OriginalSource
    $b.LastX = $b.DownCur.X; $b.LastY = $b.DownCur.Y; $b.LastT = [Environment]::TickCount; $b.Vx = 0.0; $b.Vy = 0.0
    if (-not (Test-InButton $b $e.OriginalSource) -and (Test-InVisual $e.OriginalSource $b.C.BlobHost)) {
        Anim-To $b.C.BodyScale $script:ST::ScaleXProperty 1.08 90
        Anim-To $b.C.BodyScale $script:ST::ScaleYProperty 0.86 90
    }
}
function Bb-Move($b, $e) {
    if (-not $b -or -not $b.Pressed -or $e.LeftButton -ne 'Pressed') { return }
    $cur = [System.Windows.Forms.Cursor]::Position
    $dx = $cur.X - $b.DownCur.X; $dy = $cur.Y - $b.DownCur.Y
    if (-not $b.Dragging) {
        if (([math]::Abs($dx) + [math]::Abs($dy)) -lt 7) { return }
        if (Test-InButton $b $b.DownSrc) { return }
        $b.Dragging = $true; $b.Orb.Dragging = $true; Stop-BubbleTween $b
        $c = $b.C
        if ($b.Peek -and -not $b.CardOpen) {
            # fold the peek away first and keep the orb under the cursor
            $b.Peek = $false; $b.NoPeek = $true
            $b.Suppress = $true; Apply-BubbleView $b; $b.Win.UpdateLayout()
            if ($b.Side -eq 'right') { $b.DownL = $b.DownR - [int]($b.Win.ActualWidth * (Get-WinScaleOf $b.Win)) }
        }
        $b.Suppress = $true
        $c.CloseX.Visibility = 'Collapsed'
        foreach ($p in @($script:ST::ScaleXProperty, $script:ST::ScaleYProperty)) { $c.JS.BeginAnimation($p, $null) }
        $c.JS.ScaleX = 1; $c.JS.ScaleY = 1
        Anim-Scale $c.BodyScale 1 160
        Anim-Scale $c.OrbScale 1.12 200 'back'
        Update-Bubble $b
        [void]$b.Win.CaptureMouse()
    }
    $t = [Environment]::TickCount
    $dt = [math]::Max(1, $t - $b.LastT)
    $b.Vx = $b.Vx * 0.5 + (($cur.X - $b.LastX) / $dt) * 0.5
    $b.Vy = $b.Vy * 0.5 + (($cur.Y - $b.LastY) / $dt) * 0.5
    $b.LastX = $cur.X; $b.LastY = $cur.Y; $b.LastT = $t
    $b.Orb.Vx = $b.Vx; $b.Orb.Vy = $b.Vy
    $hw = (New-Object System.Windows.Interop.WindowInteropHelper $b.Win).Handle
    [void][VcNative]::SetWindowPos($hw, [IntPtr]::Zero, $b.DownL + $dx, $b.DownT + $dy, 0, 0, 0x0015)
}
function Bb-Up($b, $e) {
    if (-not $b -or -not $b.Pressed) { return }
    $b.Pressed = $false
    Anim-Scale $b.C.BodyScale 1 650 'elastic'
    if ($b.Dragging) {
        $b.Dragging = $false; $b.Orb.Dragging = $false; $b.Win.ReleaseMouseCapture(); $e.Handled = $true
        Anim-To $b.C.JS $script:ST::ScaleXProperty 1 600 'elastic'
        Anim-To $b.C.JS $script:ST::ScaleYProperty 1 600 'elastic'
        Anim-Scale $b.C.OrbScale $(if ($b.Hover) { 1.08 } else { 1 }) 300 'back'
        Snap-Bubble $b
        Update-Bubble $b
        return
    }
    $src = $b.DownSrc
    if (Test-InButton $b $src) { return }
    Bb-Click $b $src
    if ($b.DoubleDown) { $b.DoubleDown = $false; Open-BubbleSession $b }
}
# After a drag: nearest side of the monitor under the bubble, nearest free slot, glide there.
function Snap-Bubble($b) {
    $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper $b.Win).Handle
    $rc = New-Object VcNative+RECT
    [void][VcNative]::GetWindowRect($hwnd, [ref]$rc)
    $cx = [int](($rc.Left + $rc.Right) / 2); $cy = [int](($rc.Top + $rc.Bottom) / 2)
    $scr = [System.Windows.Forms.Screen]::FromPoint((New-Object System.Drawing.Point $cx, $cy))
    $wa = $scr.WorkingArea
    $sc = Get-WinScaleOf $b.Win
    $vm = 8 * $sc; $wm = 24 * $sc; $dotH = 66 * $sc
    $b.Frac = [math]::Min(1.0, [math]::Max(0.0, ((($rc.Top + $wm) - ($wa.Top + $vm)) / [math]::Max(1, ($wa.Height - 2 * $vm - $dotH)))))
    $b.Side = $(if ($cx -lt ($wa.Left + $wa.Width / 2)) { 'left' } else { 'right' })
    $b.Screen = $scr.DeviceName; $b.Work = $wa
    Resolve-Slot $b
    $script:dockSide = $b.Side; $script:dockFrac = $b.Frac; $script:dockScreen = $b.Screen
    Save-State
    $b.Suppress = $true
    Apply-BubbleView $b
    $b.Win.UpdateLayout()
    $b.Suppress = $false
    $t = Get-BubbleTarget $b
    if ($t) { Tween-Bubble $b $rc.Left $rc.Top $t.X $t.Y 430 $true }
}
function Bb-Click($b, $src) {
    $b.Last = Get-Date
    if (-not $b.CardOpen) {
        $b.CardOpen = $true; $b.AutoOpened = $false
        $b.LogOpen = ($b.Alerts.Count -eq 0)
        Apply-BubbleView $b
        return
    }
    if ((Test-InVisual $src $b.C.BlobHost) -or (Test-InVisual $src $b.C.StatusCol)) {
        $b.CardOpen = $false; $b.AutoOpened = $false; $b.Peek = $false; $b.NoPeek = $true
        Apply-BubbleView $b
    }
}
function Reply-ToBubble($b) {
    if (-not $b) { return }
    $lid = $b.LocalId
    if (-not $lid -and $b.Sid) { $lid = Get-LocalId $b.Sid; $b.LocalId = $lid }
    $script:replyLocal = $lid
    $script:lastVoiceBubble = $b
    Show-Island
}

# ---------------------------------------------------------------- hook events -> the right bubble
function Bind-Pending($sid, $cwd) {
    $n = ([string]$cwd).TrimEnd('\')
    foreach ($x in $script:bubbles) {
        if (-not $x.Sid -and $x.PendingCwd -and (((Get-Date) - $x.Created).TotalMinutes -lt 5) -and (([string]$x.PendingCwd).TrimEnd('\') -ieq $n)) { $x.Sid = $sid; Save-Bubbles; return $x }
    }
    $null
}
# ---------------------------------------------------------------- speaking updates
# Off unless config "speak" is true (tray: Speak updates). Never talks while the pill is open: the microphone
# would type it. Stays quiet while Claude itself is the window in front, since you can already see it.
# Voice: a Piper voice from the voices folder when there is one (natural, offline), else Windows text-to-speech.
# Sentences queue up so updates never talk over each other; Stop-Speaking (stop hotkey, tray, opening the pill)
# drops the queue and cuts the current one off.
$script:tts = $null
$script:voiceDir = Join-Path $root 'voices'
$script:sayQueue = New-Object System.Collections.Queue
$script:sayProc = $null; $script:sayFile = $null; $script:sayStarted = $null; $script:sayText = ''; $script:saySeq = 0
$script:mp = New-Object System.Windows.Media.MediaPlayer
$script:mp.Add_MediaEnded({ End-Utterance })
$script:mp.Add_MediaFailed({ Log 'speech playback failed'; End-Utterance })
$script:sayTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:sayTimer.Interval = [TimeSpan]::FromMilliseconds(80)
$script:sayTimer.Add_Tick({ Step-Piper })
function Get-PiperExe { $x = Join-Path $script:voiceDir 'piper\piper.exe'; if (Test-Path -LiteralPath $x) { $x } else { $null } }
function Get-PiperVoices { if (Test-Path -LiteralPath $script:voiceDir) { @(Get-ChildItem -LiteralPath $script:voiceDir -Filter '*.onnx' | ForEach-Object { $_.BaseName }) } else { @() } }
# config "piperVoice": a voice file name without .onnx, "" for the first one found, or "off" for Windows voices
function Get-PiperModel {
    $want = [string]$script:cfg.piperVoice
    if ($want -eq 'off' -or -not (Get-PiperExe)) { return $null }
    $all = @(Get-PiperVoices)   # @() so a single voice stays a list, not one string
    if ($all.Count -eq 0) { return $null }
    $name = $(if ($want -and ($all -contains $want)) { $want } else { $all[0] })
    Join-Path $script:voiceDir "$name.onnx"
}
function Start-Utterance {
    if ($script:sayProc -or $script:sayFile -or $script:sayQueue.Count -eq 0) { return }
    $text = [string]$script:sayQueue.Dequeue()
    $model = Get-PiperModel
    if (-not $model) { Say-Windows $text; return }
    $script:saySeq++
    $file = Join-Path $env:TEMP "bubbles-say-$PID-$($script:saySeq).wav"
    # speechRate 1 is a touch faster than normal; Piper's length scale is the inverse of speed
    $scale = [math]::Max(0.5, [math]::Min(1.6, 1 - 0.06 * [double]$script:cfg.speechRate))
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo (Get-PiperExe)
        $psi.Arguments = '--model "{0}" --output_file "{1}" --length_scale {2}' -f $model, $file, $scale.ToString([Globalization.CultureInfo]::InvariantCulture)
        $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.RedirectStandardInput = $true
        $psi.WorkingDirectory = Split-Path (Get-PiperExe)
        $p = [System.Diagnostics.Process]::Start($psi)
        # .NET Framework cannot set the stdin encoding, so write UTF-8 bytes ourselves (accents, French)
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($text + "`n")
        $p.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length); $p.StandardInput.Close()
        $script:sayProc = $p; $script:sayFile = $file; $script:sayStarted = Get-Date; $script:sayText = $text
        $script:sayTimer.Start()
    } catch { Log "piper: $_"; Say-Windows $text }
}
function Step-Piper {
    $p = $script:sayProc
    if (-not $p) { $script:sayTimer.Stop(); return }
    if (-not $p.HasExited) {
        if (((Get-Date) - $script:sayStarted).TotalSeconds -gt 20) { try { $p.Kill() } catch {}; Log 'piper took too long' }
        return
    }
    $script:sayTimer.Stop(); $script:sayProc = $null
    if ($p.ExitCode -eq 0 -and (Test-Path -LiteralPath $script:sayFile)) {
        $script:mp.Open([uri]$script:sayFile); $script:mp.Play()
    } else {
        Log "piper failed (exit $($p.ExitCode)) - using the Windows voice"
        $f = $script:sayFile; $script:sayFile = $null; Remove-SayFile $f
        Say-Windows $script:sayText
    }
}
function End-Utterance {
    $f = $script:sayFile; $script:sayFile = $null
    try { $script:mp.Close() } catch {}
    Remove-SayFile $f
    Start-Utterance
}
function Remove-SayFile($f) { if ($f) { try { [System.IO.File]::Delete($f) } catch {} } }
function Say-Windows($text) {
    $t = Get-Tts
    if ($t) { try { [void]$t.SpeakAsync([string]$text) } catch { Log "speak: $_" } }
    Start-Utterance
}
function Get-Tts {
    if ($script:tts) { return $script:tts }
    try {
        Add-Type -AssemblyName System.Speech
        $t = New-Object System.Speech.Synthesis.SpeechSynthesizer
        $t.SetOutputToDefaultAudioDevice()
        if ([string]$script:cfg.speechVoice) { try { $t.SelectVoice([string]$script:cfg.speechVoice) } catch { Log "no voice named '$($script:cfg.speechVoice)'" } }
        try { $t.Rate = [math]::Max(-10, [math]::Min(10, [int]$script:cfg.speechRate)) } catch {}
        $script:tts = $t
    } catch { Log "speech unavailable: $_" }
    $script:tts
}
function Test-ClaudeInFront {
    $pid0 = [uint32]0
    [void][VcNative]::GetWindowThreadProcessId([VcNative]::GetForegroundWindow(), [ref]$pid0)
    try { (Get-Process -Id $pid0 -ErrorAction Stop).ProcessName -eq 'claude' } catch { $false }
}
# -Force (voice samples from the tray) speaks even with updates off or Claude in front
function Say($text, [switch]$Force) {
    if (-not $text -or $Preview -or $script:visible) { return }
    if (-not $Force -and (-not $script:cfg.speak -or (Test-ClaudeInFront))) { return }
    # a backlog of stale news is worse than silence
    while ($script:sayQueue.Count -ge 3) { [void]$script:sayQueue.Dequeue() }
    $script:sayQueue.Enqueue([string]$text)
    Start-Utterance
}
function Stop-Speaking {
    $script:sayQueue.Clear()
    $script:sayTimer.Stop()
    if ($script:sayProc) { try { if (-not $script:sayProc.HasExited) { $script:sayProc.Kill() } } catch {}; $script:sayProc = $null }
    try { $script:mp.Stop(); $script:mp.Close() } catch {}
    $f = $script:sayFile; $script:sayFile = $null; Remove-SayFile $f
    if ($script:tts) { try { $script:tts.SpeakAsyncCancelAll() } catch {} }
}
function Set-Voice($piper, $windows) {
    Stop-Speaking
    if ($null -ne $piper) { Set-ConfigValue 'piperVoice' $piper }
    if ($null -ne $windows) { Set-ConfigValue 'speechVoice' $windows; if ($script:tts) { try { $script:tts.Dispose() } catch {}; $script:tts = $null } }
    Say 'Hi, this is my new voice.' -Force
}
# "StoreFront" / "my_app-v2" -> "Store Front" / "my app v2", so the voice says names properly
function Get-SpokenName($b) {
    $n = [string]$b.Project
    if (-not $n) { return 'Claude' }
    ($n -creplace '([a-z])([A-Z])', '$1 $2' -replace '[_\-\.]+', ' ').Trim()
}
# Markdown and code read aloud badly: keep the words, drop the formatting, and cut at a sentence end
function Get-SpeechText($t, $max = 200) {
    $x = [string]$t
    $x = [regex]::Replace($x, '(?s)```.*?```', ' ')
    $x = [regex]::Replace($x, '\[([^\]]+)\]\([^)]*\)', '$1')
    $x = [regex]::Replace($x, 'https?://\S+', 'a link')
    $x = $x -replace '`', '' -replace '(?m)^\s*([-*+]|\d+\.)\s+', '' -replace '[*_#>|~]', '' -replace '\s+', ' '
    $x = $x.Trim()
    if ($x.Length -le $max) { return $x }
    $m = [regex]::Match($x.Substring(0, $max), '^.*[\.\!\?](?=\s|$)')
    if ($m.Success -and $m.Value.Length -ge 30) { return $m.Value }
    $x.Substring(0, $max).Trim() + '...'
}

# ---------------------------------------------------------------- dictated prompts get a note for Claude
# Prompts sent from the pill while voice typing was on are remembered for a few minutes. When Claude Code
# reports that exact prompt (UserPromptSubmit), the hook adds a note so Claude reads it for intent.
$script:voiceSent = New-Object System.Collections.ArrayList
$script:dictationNote = 'Note from Bubbles: the user dictated this message with Windows voice typing, so it may contain speech-recognition errors - misheard or similar-sounding words, wrong homophones, missing punctuation, or garbled names and technical terms. Read it for the intended meaning and quietly correct obvious recognition mistakes; ask only if the intent is genuinely unclear.'
function Get-PromptKey($t) { (([string]$t).ToLowerInvariant() -replace '\s+', ' ').Trim() }
function Remember-VoicePrompt($text) {
    if (-not $text -or -not $script:dictOn) { return }
    [void]$script:voiceSent.Add(@{ Key = (Get-PromptKey $text); At = (Get-Date) })
}
function Get-DictationNote($prompt) {
    if ($script:cfg.dictationNote -eq $false) { return $null }
    $k = Get-PromptKey $prompt
    $now = Get-Date; $hit = $false
    for ($i = $script:voiceSent.Count - 1; $i -ge 0; $i--) {
        $v = $script:voiceSent[$i]
        if (($now - $v.At).TotalMinutes -gt 5) { $script:voiceSent.RemoveAt($i); continue }
        if (-not $hit -and $k -and ($k -eq $v.Key -or ($v.Key.Length -ge 12 -and $k.Contains($v.Key)))) { $script:voiceSent.RemoveAt($i); $hit = $true }
    }
    # a bare slash command has nothing dictated in it worth a note
    if (-not $hit -or $k -match '^/\S+$') { return $null }
    $script:dictationNote
}

# ---------------------------------------------------------------- answering permission requests
# A PermissionRequest alert can carry the hook's open connection (Ev). Allow/Deny on the card, or a spoken
# "allow"/"deny", writes the answer to it. Claude's own prompt stays up too; whichever answers first wins.
function Test-Answerable($a) { [bool]($a -and $a.Ev -and -not $a.Ev.Answered) }
function Release-Alert($a) { if ($a -and $a.Ev) { [void][VcPipeServer]::Answer($a.Ev, 'pass') } }
function Remove-Alerts($b, [scriptblock]$which) {
    for ($i = $b.Alerts.Count - 1; $i -ge 0; $i--) {
        $a = $b.Alerts[$i]
        if (& $which $a) { Release-Alert $a; $b.Alerts.RemoveAt($i) }
    }
}
function Get-ToolSig($p) { [string]$p.tool_name + '|' + (Cut-Text ($p.tool_input | ConvertTo-Json -Compress -Depth 6) 2000) }
function Find-LivePermission {
    $best = $null
    foreach ($b in @($script:bubbles)) {
        if ($b.Closing) { continue }
        foreach ($a in $b.Alerts) {
            if ((Test-Answerable $a) -and (-not $best -or $a.Since -gt $best.A.Since)) { $best = [pscustomobject]@{ B = $b; A = $a } }
        }
    }
    $best
}
# The hook prints whatever follows "json:" as its output for Claude Code
function Send-HookReply($ev, $obj) { [VcPipeServer]::Answer($ev, 'json:' + ($obj | ConvertTo-Json -Compress -Depth 30)) }
function Get-BubbleSess($b) { if ($b -and $b.Sid -and $script:hookSessions.ContainsKey($b.Sid)) { $script:hookSessions[$b.Sid] } else { $null } }
function Get-LiveAlert($b) { if ($b) { foreach ($x in $b.Alerts) { if (Test-Answerable $x) { return $x } } }; $null }
# Our answer could not be delivered (the hook already went away): leave it to Claude's own prompt
function Lose-Alert($b, $a) { $a.Ev = $null; Set-BubbleNote $b 'Too late here - answer it in Claude' 6; Update-Bubble $b }
function Answer-Permission($b, $reply) {
    $a = Get-LiveAlert $b
    if (-not $a) { return $false }
    if ($a.Q) { if ($reply -eq 'allow') { Send-MultiPick $b }; return $true }
    if ($reply -eq 'allow') {
        # echo the original input back: older Claude versions reject an allow without it
        $dec = @{ behavior = 'allow'; updatedInput = $a.P.tool_input }
    } else {
        $dec = @{ behavior = 'deny'; message = 'The user denied this from Bubbles.' }
    }
    $ok = Send-HookReply $a.Ev @{ hookSpecificOutput = @{ hookEventName = 'PermissionRequest'; decision = $dec } }
    if (-not $ok) { Lose-Alert $b $a; return $false }
    [void]$b.Alerts.Remove($a)
    Log "permission $reply for $($a.Head)"
    $sess = Get-BubbleSess $b
    if ($sess) {
        if ($reply -eq 'allow') { Add-LogLine $sess ('You allowed: ' + $a.Head) 'ok'; $sess.Activity = $a.Head }
        else { Add-LogLine $sess ('You denied: ' + $a.Head) 'bad' }
    }
    if ($reply -eq 'allow') { Orb-Hop $b 6 } else { Orb-Shake $b }
    Update-Bubble $b
    $true
}

# ---------------------------------------------------------------- answering Claude's questions (AskUserQuestion)
# Claude asks 1-4 questions with 2-4 options each. The card shows one question at a time; the answers go back
# as the tool's input: { questions, answers = { "<question text>": "<label>" } } (multi-select: labels joined ", ").
function Get-CurrentQuestion($a) { if ($a -and $a.Q -and $a.QIndex -lt @($a.Q).Count) { @($a.Q)[$a.QIndex] } else { $null } }
function Pick-Option($b, $i) {
    $a = Get-LiveAlert $b; $q = Get-CurrentQuestion $a
    if (-not $q) { return }
    if ($q.multiSelect) {
        if ($a.Picked.Contains($i)) { $a.Picked.Remove($i) } else { [void]$a.Picked.Add($i) }
        Update-Bubble $b
        return
    }
    Commit-Answer $b $a ([string]@($q.options)[$i].label)
}
function Send-MultiPick($b) {
    $a = Get-LiveAlert $b; $q = Get-CurrentQuestion $a
    if (-not $q) { return }
    if ($a.Picked.Count -eq 0) { Orb-Shake $b; return }
    $labels = @($a.Picked | Sort-Object | ForEach-Object { [string]@($q.options)[$_].label })
    Commit-Answer $b $a ($labels -join ', ')
}
function Commit-Answer($b, $a, $value) {
    $q = Get-CurrentQuestion $a
    $a.Answers[[string]$q.question] = [string]$value
    $a.Picked.Clear(); $a.QIndex++
    if ($a.QIndex -lt @($a.Q).Count) { Orb-Hop $b 4; Update-Bubble $b; return }
    $upd = @{ questions = $a.P.tool_input.questions; answers = $a.Answers }
    $ok = Send-HookReply $a.Ev @{ hookSpecificOutput = @{ hookEventName = 'PermissionRequest'; decision = @{ behavior = 'allow'; updatedInput = $upd } } }
    if (-not $ok) { Lose-Alert $b $a; return }
    [void]$b.Alerts.Remove($a)
    $said = ($a.Answers.Values | ForEach-Object { $_ }) -join ' / '
    Log "answered question: $said"
    $sess = Get-BubbleSess $b
    if ($sess) { Add-LogLine $sess ('You answered: ' + (Cut-Text $said 70)) 'ok'; $sess.Activity = 'Thinking...' }
    Orb-Hop $b 6
    Update-Bubble $b
}
# Which option(s) a spoken answer names: "two", "the second one", "option 3", "one and three", or the label itself
function Match-SpokenOption($q, $text) {
    $t = (([string]$text).ToLowerInvariant() -replace '[^a-z0-9 ]', ' ' -replace '\s+', ' ').Trim()
    if (-not $t) { return $null }
    $opts = @($q.options)
    $nums = @{ 'one' = 1; 'first' = 1; '1' = 1; 'two' = 2; 'second' = 2; '2' = 2; 'to' = 2; 'too' = 2; 'three' = 3; 'third' = 3; '3' = 3; 'four' = 4; 'fourth' = 4; 'for' = 4; '4' = 4 }
    $fill = 'option', 'options', 'number', 'the', 'and', 'or', 'please', 'choice', 'pick', 'answer', 'i', 'choose', 'want', 'go', 'with', 'take', 'both'
    $words = @($t -split ' ')
    # numbers only count when every word is a number or filler ("the first one", "one and three")
    $picked = New-Object System.Collections.ArrayList
    $other = $false; $prevNum = $false
    foreach ($w in $words) {
        if ($w -eq 'one' -and $prevNum) { $prevNum = $false; continue }   # "the second one": that 'one' is filler
        if ($nums.ContainsKey($w)) {
            $n = $nums[$w]; if ($n -le $opts.Count -and -not $picked.Contains($n - 1)) { [void]$picked.Add($n - 1) }
            $prevNum = $true
        } else {
            $prevNum = $false
            if ($w -notin $fill) { $other = $true }
        }
    }
    # the leading comma keeps a one-item array from being unrolled into a bare 0 (which reads as false)
    if (-not $other -and $picked.Count -gt 0) { if (-not $q.multiSelect) { return ,@($picked[0]) }; return ,@($picked.ToArray()) }
    # otherwise the labels themselves, said exactly or contained in what was said ("header and footer")
    $hits = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $opts.Count; $i++) {
        $l = (([string]$opts[$i].label).ToLowerInvariant() -replace '[^a-z0-9 ]', ' ' -replace '\s+', ' ').Trim()
        if (-not $l) { continue }
        if ($t -eq $l -or ($l.Length -ge 3 -and (" $t ").Contains(" $l "))) { [void]$hits.Add($i) }
    }
    if ($hits.Count -eq 0) { return $null }
    if (-not $q.multiSelect) { return ,@($hits[0]) }
    ,@($hits.ToArray())
}
# Answer the current question with something spoken in the pill: an option, or (when asked for) free text
function Answer-ByVoice($b, $text, [bool]$freeText) {
    $a = Get-LiveAlert $b; $q = Get-CurrentQuestion $a
    if (-not $q) { return $false }
    $m = Match-SpokenOption $q $text
    if ($null -ne $m) {
        if ($q.multiSelect) { $a.Picked.Clear(); foreach ($i in $m) { [void]$a.Picked.Add($i) }; Send-MultiPick $b }
        else { Commit-Answer $b $a ([string]@($q.options)[$m[0]].label) }
        return $true
    }
    if ($freeText) { Commit-Answer $b $a $text; return $true }
    $false
}
# What Enter will do with the pill's text when a request is waiting (shown as the pill's hint while you speak)
function Get-AnswerPreview($text) {
    $t = (([string]$text) -replace '\s+', ' ').Trim()
    if (-not $t) { return $null }
    $free = [bool]$script:answerTarget
    $target = $(if ($free) { [pscustomobject]@{ B = $script:answerTarget; A = (Get-LiveAlert $script:answerTarget) } } else { Find-LivePermission })
    if (-not $target -or -not $target.A) { return $null }
    $q = Get-CurrentQuestion $target.A
    if ($q) {
        if (-not $free -and ($t -split ' ').Count -gt 6) { return $null }
        $m = Match-SpokenOption $q $t
        if ($null -ne $m) { return @{ Text = 'Answers:  ' + ((@($m) | ForEach-Object { [string]@($q.options)[$_].label }) -join ', '); Color = '#FFA6F7E1' } }
        if ($free) { return @{ Text = 'Answers:  "' + (Cut-Text $t 70) + '"'; Color = '#FFA6F7E1' } }
        return $null
    }
    if ($free) { return $null }
    $va = Get-VoiceAnswer $t
    if (-not $va) { return $null }
    @{ Text = $(if ($va -eq 'allow') { 'Allows:  ' } else { 'Denies:  ' }) + "$($target.A.Head) in $($target.B.Project)"; Color = $(if ($va -eq 'allow') { '#FFA6F7E1' } else { '#FFFFB3B3' }) }
}
function Speak-Answer($b) {
    if (-not (Get-CurrentQuestion (Get-LiveAlert $b))) { return }
    $script:answerTarget = $b
    Show-Island
}
function Render-QOptions($b, $a, $q) {
    $c = $b.C; $panel = $c.QOptions
    $panel.Children.Clear()
    if (-not $q) { $panel.Visibility = 'Collapsed'; return }
    $panel.Visibility = 'Visible'
    $multi = [bool]$q.multiSelect
    $opts = @($q.options)
    for ($i = 0; $i -lt $opts.Count; $i++) {
        $o = $opts[$i]; $sel = ($multi -and $a.Picked.Contains($i))
        $row = New-Object System.Windows.Controls.Border
        $row.CornerRadius = 10; $row.Padding = '9,7,10,7'; $row.BorderThickness = 1; $row.Cursor = 'Hand'
        $row.Margin = $(if ($i -lt $opts.Count - 1) { '0,0,0,5' } else { '0' })
        $row.Background = Solid $(if ($sel) { '#33F6C453' } else { '#12FFFFFF' })
        $row.BorderBrush = Solid $(if ($sel) { '#88F6C453' } else { '#1FFFFFFF' })
        $row.Tag = @{ I = $i; Sel = $sel }
        if ($o.description) { $row.ToolTip = [string]$o.description }
        $g = New-Object System.Windows.Controls.Grid
        $c0 = New-Object System.Windows.Controls.ColumnDefinition; $c0.Width = 'Auto'; $g.ColumnDefinitions.Add($c0)
        $g.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
        $dot = New-Object System.Windows.Controls.Border
        $dot.Width = 18; $dot.Height = 18; $dot.CornerRadius = 9; $dot.Margin = '0,1,9,0'; $dot.VerticalAlignment = 'Top'
        $dot.Background = Solid $(if ($sel) { '#F6C453' } else { '#24FFFFFF' })
        $dt = New-Object System.Windows.Controls.TextBlock
        $dt.HorizontalAlignment = 'Center'; $dt.VerticalAlignment = 'Center'
        if ($sel) { $dt.Text = [string][char]0xE73E; $dt.FontFamily = 'Segoe Fluent Icons, Segoe MDL2 Assets'; $dt.FontSize = 9; $dt.Foreground = Solid '#3A2A05' }
        else { $dt.Text = [string]($i + 1); $dt.FontFamily = 'Segoe UI Variable Text, Segoe UI'; $dt.FontSize = 10.5; $dt.FontWeight = 'SemiBold'; $dt.Foreground = Solid '#D8D8E0' }
        $dot.Child = $dt
        [void]$g.Children.Add($dot)
        $sp = New-Object System.Windows.Controls.StackPanel
        [System.Windows.Controls.Grid]::SetColumn($sp, 1)
        $lt = New-Object System.Windows.Controls.TextBlock
        $lt.Text = [string]$o.label; $lt.TextWrapping = 'Wrap'; $lt.FontFamily = 'Segoe UI Variable Text, Segoe UI'; $lt.FontSize = 12.5; $lt.FontWeight = 'SemiBold'; $lt.Foreground = Solid '#F2F2F5'
        [void]$sp.Children.Add($lt)
        if ($o.description) {
            $ds = New-Object System.Windows.Controls.TextBlock
            $ds.Text = [string]$o.description; $ds.TextWrapping = 'Wrap'; $ds.TextTrimming = 'CharacterEllipsis'; $ds.MaxHeight = 30
            $ds.FontFamily = 'Segoe UI Variable Text, Segoe UI'; $ds.FontSize = 11; $ds.Foreground = Solid '#8C8C96'; $ds.Margin = '0,1,0,0'
            [void]$sp.Children.Add($ds)
        }
        [void]$g.Children.Add($sp)
        $row.Child = $g
        $row.Add_MouseEnter({ param($sender, $ea) if (-not $sender.Tag.Sel) { $sender.Background = Solid '#22FFFFFF' } })
        $row.Add_MouseLeave({ param($sender, $ea) if (-not $sender.Tag.Sel) { $sender.Background = Solid '#12FFFFFF' } })
        $row.Add_MouseLeftButtonUp({ param($sender, $ea) $ea.Handled = $true; Pick-Option (Get-BubbleById ([System.Windows.Window]::GetWindow($sender)).Tag) $sender.Tag.I })
        [void]$panel.Children.Add($row)
    }
    # multi-select needs a send step; single-select sends on the click itself
    $last = ($a.QIndex -ge @($a.Q).Count - 1)
    $c.BtnAllow.Visibility = $(if ($multi) { 'Visible' } else { 'Collapsed' })
    $c.BtnAllowText.Text = $(if ($last) { 'Send' } else { 'Next' })
    $c.BtnAllowIcon.Text = [string][char]$(if ($last) { 0xE724 } else { 0xE72A })
    $c.AlertHint.Text = $(if ($multi) { 'tick any, then Send - or say them' } else { 'click one, or say a number' })
}
# The hook went away without our answer: Claude was answered directly, or the wait ran out
function Permission-Gone($id) {
    foreach ($b in @($script:bubbles)) {
        for ($i = $b.Alerts.Count - 1; $i -ge 0; $i--) {
            $a = $b.Alerts[$i]
            if (-not $a.Ev -or $a.Ev.Id -ne $id) { continue }
            # before our own 110 s wait ran out it was answered in Claude; after, Claude may still be asking
            if (((Get-Date) - $a.Since).TotalSeconds -lt 100) { $b.Alerts.RemoveAt($i) } else { $a.Ev = $null }
            Update-Bubble $b
            return
        }
    }
}
# Short spoken answers only, so a real prompt that starts with "no, ..." is never taken as an answer
function Get-VoiceAnswer($text) {
    $w = @((([string]$text).ToLowerInvariant() -replace "[^a-z' ]", ' ').Trim() -split '\s+' | Where-Object { $_ })
    if ($w.Count -eq 0 -or $w.Count -gt 4) { return $null }
    $yes = 'allow', 'allowed', 'approve', 'approved', 'accept', 'yes', 'yeah', 'yep', 'ok', 'okay', 'sure', 'go', 'ahead', 'do'
    $no = 'deny', 'denied', 'reject', 'no', 'nope', 'refuse', "don't", 'dont', 'not'
    $fill = 'it', 'that', 'this', 'please', 'the', 'one', 'command'
    $y = 0; $n = 0
    foreach ($x in $w) {
        if ($x -in $no) { $n++ } elseif ($x -in $yes) { $y++ } elseif ($x -notin $fill) { return $null }
    }
    if ($n -gt 0) { return 'deny' }
    if ($y -gt 0) { return 'allow' }
    $null
}
function Add-BubbleAlert($sid, $sess, $head, $body, $kind, $ev = $null, $sig = '', $p = $null) {
    $b = Find-Bubble $sid
    if (-not $b) { $b = New-Bubble $sid $null $sess.Project '' $null $true; Show-Bubble $b }
    foreach ($a in $b.Alerts) {
        if ($a.Kind -eq $kind -and $a.Head -eq $head -and $a.Body -eq $body) {
            # the same request again (Claude retried, or PreToolUse came first): keep one alert, holding the newest connection
            if ($ev) { Release-Alert $a; $a.Ev = $ev; $a.Since = Get-Date; if ($p) { $a.P = $p }; Update-Bubble $b }
            return
        }
    }
    $anyBefore = @($script:bubbles | Where-Object { $_.Alerts.Count -gt 0 }).Count
    $qs = $null; if ($p -and [string]$p.tool_name -eq 'AskUserQuestion' -and $p.tool_input.questions) { $qs = @($p.tool_input.questions) }
    [void]$b.Alerts.Add([pscustomobject]@{
        Head = $head; Body = $body; Since = (Get-Date); Kind = $kind; Ev = $ev; Sig = $sig; P = $p
        Q = $qs; QIndex = 0; Answers = [ordered]@{}; Picked = (New-Object System.Collections.ArrayList)
    })
    $who = Get-SpokenName $b
    if ($qs) { Say ("$who asks: " + (Get-SpeechText ([string]$qs[0].question) 160)) }
    elseif ($kind -eq 'idle') { Say "$who is waiting for you." }
    else { Say ("$who needs your OK to " + $head.Substring(0, 1).ToLowerInvariant() + $head.Substring(1) + '.') }
    Add-LogLine $sess ('Needs you: ' + $head) 'warn'
    $b.Last = Get-Date
    if (-not $b.CardOpen) { $b.CardOpen = $true; $b.LogOpen = $false; $b.AutoOpened = $true; Apply-BubbleView $b }
    if ($anyBefore -eq 0 -and $script:cfg.permSound) { try { [System.Media.SystemSounds]::Asterisk.Play() } catch {} }
    Update-Bubble $b
    Orb-Shake $b; Orb-Shock $b '#F6C453'; $b.LastShake = Get-Date
    [VcGaze]::Alert = $b.Orb; [VcGaze]::AlertUntil = (Get-Date).AddSeconds(6)
}
function Handle-HookEvent($ev) {
    if ($ev.Name -eq '_HookGone') { Permission-Gone $ev.Id; return }
    try { $p = $ev.Raw | ConvertFrom-Json } catch { if ($ev.Pipe) { [void][VcPipeServer]::Answer($ev, 'pass') }; return }
    $sid = [string]$p.session_id
    if (-not $sid) { if ($ev.Pipe) { [void][VcPipeServer]::Answer($ev, 'pass') }; return }
    if ($ev.Name -eq 'SubagentStart' -or $ev.Name -eq 'SubagentStop') { return }
    $sess = Get-HookSession $sid $p.cwd
    $sess.Last = Get-Date
    if ($p.transcript_path) { $sess.Transcript = [string]$p.transcript_path }
    if ($ev.Name -ne 'PreToolUse' -and $ev.Name -ne 'PostToolUse') { Log ("evt {0} {1}" -f $ev.Name, $sid.Substring(0, [math]::Min(8, $sid.Length))) }
    $b = Find-Bubble $sid
    if (-not $b -and $ev.Name -eq 'UserPromptSubmit') { $b = Bind-Pending $sid $p.cwd }
    switch ($ev.Name) {
        'UserPromptSubmit' {
            # answer first: the hook holds the prompt until we reply (or 1.5 s pass)
            if ($ev.Pipe) {
                $note = Get-DictationNote ([string]$p.prompt)
                if ($note) { [void](Send-HookReply $ev @{ hookSpecificOutput = @{ hookEventName = 'UserPromptSubmit'; additionalContext = $note } }); Log 'dictation note added' }
                else { [void][VcPipeServer]::Answer($ev, 'pass') }
            }
            $sess.Start = Get-Date; $sess.Steps = 0; $sess.Working = $true; $sess.Done = $false; $sess.Activity = 'Thinking...'
            $sess.Log.Clear(); Add-LogLine $sess ('You: ' + (Cut-Text $p.prompt 80)) 'user'
            $script:dismissed.Remove($sid)
        }
        'PreToolUse' {
            $sess.Working = $true; $sess.Done = $false; $sess.Activity = Describe-Tool ([string]$p.tool_name) $p.tool_input; Add-LogLine $sess $sess.Activity (Get-ToolKind ([string]$p.tool_name))
            # a question always waits for you: show it now; the PermissionRequest that follows makes it answerable
            if ([string]$p.tool_name -eq 'AskUserQuestion') { $d = Describe-Alert $p; Add-BubbleAlert $sid $sess $d.Head $d.Body 'perm' $null (Get-ToolSig $p) $p }
        }
        'PostToolUse' { $sess.Steps++ }
        'PostToolUseFailure' { $sess.Steps++; Add-LogLine $sess ('Failed: ' + (Cut-Text $p.tool_name 30)) 'bad' }
        'Notification' {
            if ($p.message) {
                Add-LogLine $sess ('Note: ' + (Cut-Text $p.message 90))
                if (([string]$p.message) -match 'waiting for your input|needs your (attention|input)') { Add-BubbleAlert $sid $sess 'Claude is waiting for you' (Cut-Text $p.message 200) 'idle' }
            }
        }
        'Stop' {
            $sess.Working = $false; $sess.Done = $true; $sess.DoneAt = Get-Date; $sess.Activity = 'Done'
            # Stop carries Claude's final words; the transcript may not have them yet
            $last = [string]$p.last_assistant_message
            $sess.Reply = $(if ($last.Trim()) { Get-SpeechText $last 140 } else { Get-Summary $sess })
            $sess.Spoken = $(if ($last.Trim()) { Get-SpeechText $last 220 } else { $sess.Reply })
            Add-LogLine $sess 'Finished' 'ok'
        }
        'StopFailure' {
            $sess.Working = $false; $sess.Done = $true; $sess.DoneAt = Get-Date; $sess.Activity = 'Stopped with an error'
            $sess.Reply = 'Stopped with an error - check Claude'
            Add-LogLine $sess 'Stopped with an error' 'bad'
        }
        'SessionStart' {
            # /compact and /clear end without a Stop event; an auto-compact mid-turn resumes via PreToolUse
            $src = [string]$p.source
            if ($src -in 'compact', 'clear') {
                $sess.Working = $false; $sess.Done = $false
                $sess.Activity = $(if ($src -eq 'compact') { 'Context compacted' } else { 'Conversation cleared' })
                Add-LogLine $sess $sess.Activity 'ok'
            }
        }
        'SessionEnd' { $script:hookSessions.Remove($sid); $nb = Find-Bubble $sid; if ($nb) { Remove-Alerts $nb { $true } }; return }
        'PermissionRequest' {
            $d = Describe-Alert $p
            Add-BubbleAlert $sid $sess $d.Head $d.Body 'perm' $ev (Get-ToolSig $p) $p
            return
        }
    }
    $b = Find-Bubble $sid
    if ($b) {
        if ($ev.Name -in 'Stop', 'StopFailure', 'UserPromptSubmit') {
            Remove-Alerts $b { $true }
        } elseif ($ev.Name -in 'PostToolUse', 'PostToolUseFailure') {
            # only the request for this tool call is settled; others may still be waiting
            $sig = Get-ToolSig $p
            Remove-Alerts $b { param($a) $a.Kind -ne 'perm' -or $a.Sig -eq $sig }
        } elseif ($ev.Name -eq 'PreToolUse') {
            Remove-Alerts $b { param($a) $a.Kind -eq 'idle' }
        }
    } elseif ($script:cfg.showActivity -eq 'all' -and $ev.Name -in 'UserPromptSubmit', 'PreToolUse', 'Stop' -and -not $script:dismissed.ContainsKey($sid)) {
        $b = New-Bubble $sid $null $sess.Project '' $null $true
        Show-Bubble $b
    }
    if ($b) {
        $b.Last = Get-Date
        if ($ev.Name -eq 'UserPromptSubmit') { $b.Waiting = $false; Orb-Hop $b 6 }
        if ($ev.Name -eq 'Stop') {
            $b.MoodUntil = (Get-Date).AddSeconds(2.6); Orb-Celebrate $b
            Say ((Get-SpokenName $b) + ' is done.' + $(if ($sess.Spoken) { ' ' + $sess.Spoken } else { '' }))
        }
        if ($ev.Name -eq 'StopFailure') { Orb-Shake $b; Orb-Shock $b '#FF8F8F'; Say ((Get-SpokenName $b) + ' stopped with an error.') }
        Update-Bubble $b
    }
}

# ---------------------------------------------------------------- once a second: housekeeping
function Claim-NewSessions {
    $now = Get-SessionStamps
    $pending = @($script:bubbles | Where-Object { -not $_.LocalId -and $_.PendingCwd })
    foreach ($k in $now.Keys) {
        if ($script:seenFiles.ContainsKey($k)) { continue }
        $script:seenFiles[$k] = $true
        if ($pending.Count -eq 0) { continue }
        try { $j = Get-Content $k -Raw | ConvertFrom-Json } catch { continue }
        $cwd = ([string]$j.cwd).TrimEnd('\')
        $m = $pending | Where-Object { ([string]$_.PendingCwd).TrimEnd('\') -ieq $cwd } | Select-Object -First 1
        if (-not $m -and $pending.Count -eq 1) { $m = $pending[0] }
        if ($m) {
            $m.LocalId = [string]$j.sessionId
            $cli = [string]$j.cliSessionId; if ($cli -and -not $m.Sid) { $m.Sid = $cli }
            if ([string]$j.title) { $m.Title = ([string]$j.title).Trim() }
            $m.Waiting = $false
            $pending = @($pending | Where-Object { $_.Id -ne $m.Id })
            Log "bubble $($m.Id) bound to $($m.LocalId)"
            Save-Bubbles
        }
    }
}
# Esc in Claude ends a turn without any hook; the transcript records it instead
function Test-Interrupted($sess) {
    $f = $sess.Transcript
    if (-not $f -or -not (Test-Path -LiteralPath $f)) { return $false }
    try {
        $fs = [System.IO.File]::Open($f, 'Open', 'Read', 'ReadWrite')
        try {
            $n = [math]::Min($fs.Length, 32768); $fs.Seek(-$n, 'End') | Out-Null
            $buf = New-Object byte[] $n; [void]$fs.Read($buf, 0, $n)
        } finally { $fs.Close() }
    } catch { return $false }
    $lines = [System.Text.Encoding]::UTF8.GetString($buf) -split "`n"
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        $l = $lines[$i]
        if ($l -match '"type":"assistant"') { return $false }
        if ($l -match '"type":"user"') {
            if ($l -match '"text":"\[Request interrupted by user') { return $true }
            if ($l -notmatch '"tool_result"') { return $false }
        }
    }
    $false
}
function Check-Interrupts($now) {
    foreach ($sess in @($script:hookSessions.Values)) {
        if (-not $sess.Working -or ($now - $sess.Last).TotalSeconds -lt 4 -or ($now - $sess.Checked).TotalSeconds -lt 3) { continue }
        $sess.Checked = $now
        if (-not (Test-Interrupted $sess)) { continue }
        $sess.Working = $false; $sess.Done = $false; $sess.Activity = 'Stopped by you'
        Add-LogLine $sess 'Stopped by you' 'info'
        Log "interrupt seen $($sess.Id.Substring(0, 8))"
    }
}
function Tick-Bubbles {
    $now = Get-Date
    Claim-NewSessions
    Check-Interrupts $now
    $mins = 0; try { if ($script:cfg.bubbleMinutes) { $mins = [double]$script:cfg.bubbleMinutes } } catch {}
    foreach ($b in @($script:bubbles)) {
        Remove-Alerts $b { param($a) ($now - $a.Since).TotalMinutes -ge 10 }
        if ($b.AutoOpened -and $b.CardOpen -and $b.Alerts.Count -eq 0) {
            if (-not $b.RetractAt) { $b.RetractAt = $now.AddSeconds(1.5) }
            elseif ($now -ge $b.RetractAt) { $b.RetractAt = $null; $b.AutoOpened = $false; $b.CardOpen = $false; Apply-BubbleView $b }
        } else { $b.RetractAt = $null }
        if ($b.Waiting -and (($now - $b.WaitStart).TotalMinutes -ge 10)) { $b.Waiting = $false }
        if ($b.Alerts.Count -gt 0 -and (-not $b.LastShake -or ($now - $b.LastShake).TotalSeconds -ge 4)) { $b.LastShake = $now; Orb-Shake $b }
        Update-Bubble $b
        if ($b.Mood -eq 'sleep') { Step-Zzz $b }
        $sess = $null; if ($b.Sid -and $script:hookSessions.ContainsKey($b.Sid)) { $sess = $script:hookSessions[$b.Sid] }
        if ($b.Auto -and -not $b.CardOpen -and $b.Alerts.Count -eq 0) {
            $busy = ($sess -and $sess.Working -and (($now - $sess.Last).TotalSeconds -lt 60))
            if ($busy) { $b.QuietSince = $null }
            elseif (-not $b.QuietSince) { $b.QuietSince = $now }
            elseif (($now - $b.QuietSince).TotalSeconds -gt 20) { Close-Bubble $b $false; continue }
        } else { $b.QuietSince = $null }
        if ($mins -gt 0 -and -not $b.Auto -and -not $b.CardOpen -and -not $b.Waiting -and $b.Alerts.Count -eq 0 -and (($now - $b.Last).TotalMinutes -ge $mins)) { Close-Bubble $b $false }
    }
}
$script:bblinkTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:bblinkTimer.Interval = [TimeSpan]::FromSeconds(3.4)
$script:bblinkTimer.Add_Tick({
    foreach ($bb in @($script:bubbles)) {
        if ($bb.Mood -eq 'sleep' -or (Get-Random -Maximum 4) -eq 0) { continue }
        $twice = ((Get-Random -Maximum 5) -eq 0)
        foreach ($tr in @($bb.C.EyeL, $bb.C.EyeR)) {
            $a = New-Anim 1 0.1 85; $a.AutoReverse = $true
            if ($twice) { $a.RepeatBehavior = New-Object System.Windows.Media.Animation.RepeatBehavior(2) }
            $tr.BeginAnimation($script:ST::ScaleYProperty, $a)
        }
    }
    $script:bblinkTimer.Interval = [TimeSpan]::FromMilliseconds(1800 + (Get-Random -Maximum 2600))
})
$script:bblinkTimer.Start()

# ---------------------------------------------------------------- managing bubbles
function Get-Initials($name) {
    $n = [string]$name
    if (-not $n) { return '' }
    $words = @([regex]::Matches($n, '[A-Z]?[a-z0-9]+|[A-Z]+(?![a-z])') | ForEach-Object { $_.Value })
    if ($words.Count -ge 2) { return ($words[0].Substring(0, 1) + $words[1].Substring(0, 1)).ToUpper() }
    if ($n.Length -ge 2) { return $n.Substring(0, 2).ToUpper() }
    $n.ToUpper()
}
function Get-BubbleStateText($b) {
    $sess = $null; if ($b.Sid -and $script:hookSessions.ContainsKey($b.Sid)) { $sess = $script:hookSessions[$b.Sid] }
    if ($b.Alerts.Count -gt 0) { return 'needs you' }
    if ($b.Waiting) { return 'waiting for your message' }
    if ($sess -and $sess.Working -and (((Get-Date) - $sess.Last).TotalSeconds -lt 180)) { return 'working' }
    if ($sess -and $sess.Done) { return 'done' }
    'idle'
}
function Save-Bubbles { if (-not $script:restoring) { Save-State } }
function Restore-Bubbles {
    try { $j = Get-Content $statePath -Raw -ErrorAction Stop | ConvertFrom-Json } catch { return }
    $script:restoring = $true
    try {
        foreach ($sv in @($j.bubbles)) {
            if (-not $sv -or (-not $sv.sid -and -not $sv.localId)) { continue }
            if ($sv.localId) {
                $found = @(Get-ChildItem (Join-Path $env:APPDATA 'Claude\claude-code-sessions') -Recurse -File -Filter "$($sv.localId).json" -ErrorAction SilentlyContinue).Count
                if ($found -eq 0) { continue }
            }
            if ($sv.sid -and (Find-Bubble ([string]$sv.sid))) { continue }
            $b = New-Bubble $(if ($sv.sid) { [string]$sv.sid } else { $null }) $(if ($sv.localId) { [string]$sv.localId } else { $null }) ([string]$sv.project) ([string]$sv.title) $null $false
            $b.Waiting = $false
            if ($null -ne $sv.color) {
                $others = @($script:bubbles | Where-Object { $_.Id -ne $b.Id } | ForEach-Object { $_.Color })
                if ($others -notcontains [int]$sv.color) { $b.Color = [int]$sv.color }
            }
            if ($sv.side) { $b.Side = [string]$sv.side }
            if ($null -ne $sv.frac) { $b.Frac = [double]$sv.frac }
            if ($sv.screen) { $b.Screen = [string]$sv.screen }
            Show-Bubble $b
        }
    } catch { Log "restore bubbles: $_" }
    $script:restoring = $false
    if ($script:bubbles.Count -gt 0) { Save-State }
    Log "restored $($script:bubbles.Count) bubble(s)"
}
function Toggle-BubbleCard($b) {
    if (-not $b) { return }
    $b.Last = Get-Date; $b.AutoOpened = $false
    if ($b.CardOpen) { $b.CardOpen = $false; $b.Peek = $false; $b.NoPeek = $b.Hover } else { $b.CardOpen = $true; $b.LogOpen = ($b.Alerts.Count -eq 0) }
    Apply-BubbleView $b
}
function Open-BubbleSession($b) {
    if (-not $b) { return }
    $lid = $b.LocalId
    if (-not $lid -and $b.Sid) { $lid = Get-LocalId $b.Sid; $b.LocalId = $lid }
    if ($lid) { try { Start-Process ('claude://code/continue?session=' + [uri]::EscapeDataString($lid)) } catch {} } else { Focus-Claude }
}
# One place to act on a bubble: used by its right-click menu and by the tray's Bubbles list.
function Add-BubbleActions($items, $b) {
    $id = $b.Id
    $defs = @(
        @($(if ($b.CardOpen) { 'Collapse' } else { 'Show details' }), { param($sender, $ea) Toggle-BubbleCard (Get-BubbleById $sender.Tag) }),
        @('Reply (type or speak)', { param($sender, $ea) Reply-ToBubble (Get-BubbleById $sender.Tag) }),
        @('Open session in Claude', { param($sender, $ea) Open-BubbleSession (Get-BubbleById $sender.Tag) }),
        @('Close bubble', { param($sender, $ea) Close-Bubble (Get-BubbleById $sender.Tag) $true })
    )
    foreach ($d in $defs) {
        $mi = New-Object System.Windows.Forms.ToolStripMenuItem ([string]$d[0])
        $mi.Tag = $id
        $mi.Add_Click($d[1])
        [void]$items.Add($mi)
    }
}
function Show-BubbleMenu($b) {
    if (-not $b -or $b.Closing) { return }
    $m = New-Object System.Windows.Forms.ContextMenuStrip
    $hdr = $m.Items.Add($b.Project + $(if ($b.Title) { ' - ' + (Cut-Text $b.Title 30) } else { '' }) + '  [' + (Get-BubbleStateText $b) + ']')
    $hdr.Enabled = $false
    [void]$m.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    Add-BubbleActions $m.Items $b
    [void]$m.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    [void]$m.Items.Add('Close all bubbles', $null, { Close-AllBubbles })
    $m.Show([System.Windows.Forms.Cursor]::Position)
}
function Build-TrayMenu($menu) {
    $menu.Items.Clear()
    [void]$menu.Items.Add('Dictate now', $null, { Show-Island })
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $hdr = $menu.Items.Add("Bubbles ($($script:bubbles.Count))")
    $hdr.Enabled = $false
    foreach ($b in @($script:bubbles)) {
        $label = $b.Project + $(if ($b.Title) { ' - ' + (Cut-Text $b.Title 28) } else { '' }) + '  [' + (Get-BubbleStateText $b) + ']'
        $it = New-Object System.Windows.Forms.ToolStripMenuItem $label
        Add-BubbleActions $it.DropDownItems $b
        [void]$menu.Items.Add($it)
    }
    if ($script:bubbles.Count -gt 0) {
        [void]$menu.Items.Add('Close finished bubbles', $null, {
            foreach ($x in @($script:bubbles)) { if ((Get-BubbleStateText $x) -eq 'done') { Close-Bubble $x $true } } })
        [void]$menu.Items.Add('Close all bubbles', $null, { Close-AllBubbles })
    }
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $sp = New-Object System.Windows.Forms.ToolStripMenuItem 'Speak updates'
    $sp.Checked = [bool]$script:cfg.speak
    $sp.Add_Click({ $on = -not [bool]$script:cfg.speak; Set-ConfigValue 'speak' $on; if (-not $on) { Stop-Speaking } else { Say 'Bubbles will speak updates.' } })
    [void]$menu.Items.Add($sp)
    # Voice: Piper voices from the voices folder first (natural), then the Windows ones; picking one plays a sample
    $vm = New-Object System.Windows.Forms.ToolStripMenuItem 'Voice'
    $usePiper = [bool](Get-PiperModel)
    $curPiper = $(if ($usePiper) { [IO.Path]::GetFileNameWithoutExtension((Get-PiperModel)) } else { '' })
    foreach ($n in (Get-PiperVoices)) {
        $mi = New-Object System.Windows.Forms.ToolStripMenuItem ($n + '  (natural)')
        $mi.Tag = $n; $mi.Checked = ($usePiper -and $n -eq $curPiper)
        $mi.Add_Click({ param($sender, $ea) Set-Voice $sender.Tag $null })
        [void]$vm.DropDownItems.Add($mi)
    }
    try {
        Add-Type -AssemblyName System.Speech
        $syn = New-Object System.Speech.Synthesis.SpeechSynthesizer
        $winVoices = @($syn.GetInstalledVoices() | Where-Object { $_.Enabled } | ForEach-Object { $_.VoiceInfo.Name })
        $syn.Dispose()
    } catch { $winVoices = @() }
    if ($vm.DropDownItems.Count -gt 0 -and $winVoices.Count -gt 0) { [void]$vm.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator)) }
    foreach ($n in $winVoices) {
        $mi = New-Object System.Windows.Forms.ToolStripMenuItem ('Windows: ' + ($n -replace '^Microsoft ', '' -replace ' Desktop$', ''))
        $mi.Tag = $n; $mi.Checked = (-not $usePiper -and ([string]$script:cfg.speechVoice -eq $n -or (-not [string]$script:cfg.speechVoice -and $n -eq $winVoices[0])))
        $mi.Add_Click({ param($sender, $ea) Set-Voice 'off' $sender.Tag })
        [void]$vm.DropDownItems.Add($mi)
    }
    [void]$menu.Items.Add($vm)
    $stopLabel = 'Stop speaking' + $(if ([string]$script:cfg.stopSpeechHotkey) { "  ($($script:cfg.stopSpeechHotkey))" } else { '' })
    [void]$menu.Items.Add($stopLabel, $null, { Stop-Speaking })
    $dn = New-Object System.Windows.Forms.ToolStripMenuItem 'Tell Claude when I dictate'
    $dn.Checked = ($script:cfg.dictationNote -ne $false)
    $dn.Add_Click({ Set-ConfigValue 'dictationNote' (-not ($script:cfg.dictationNote -ne $false)) })
    [void]$menu.Items.Add($dn)
    [void]$menu.Items.Add('Edit config', $null, { Start-Process notepad.exe $cfgPath })
    [void]$menu.Items.Add('Quit', $null, {
        if ($script:server) { $script:server.Stop() }
        $tray.Visible = $false; $tray.Dispose()
        [void][VcNative]::UnregisterHotKey($hwnd, 1); [void][VcNative]::UnregisterHotKey($hwnd, 2)
        Stop-Speaking
        $app.Shutdown()
    })
}

# ---------------------------------------------------------------- bring the pill's character to life, start the gaze loop
$script:pillOrb = @{ C = @{}; Mood = $null; Win = $win; FX = 0.0; FY = 0.0; IsPill = $true; Hover = $false; Dragging = $false; Vx = 0.0; Vy = 0.0; Scale = 1.0; ScaleAt = $null }
foreach ($n in $script:orbNames) { $script:pillOrb.C[$n] = $win.FindName($n) }
$script:pillOrb.Orb = New-OrbLink $script:pillOrb.C $true
Set-OrbColors $script:pillOrb.C $script:palette[0]
Set-OrbMood $script:pillOrb 'listen'

[VcGaze]::Start()
