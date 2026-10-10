#requires -Version 5.1
<#
  Bubbles - press a hotkey, dictate (Windows voice typing, Win+H), press Enter.
  A new Claude Code session opens in the Claude desktop app with your words filled in.
  Settings live in config.json next to this script. Keep this file ASCII-only.
  Run with -DryRun to log the link instead of opening it.
#>
param([switch]$DryRun, [switch]$Preview, [string]$PreviewDir = '', [int]$PreviewScreen = -1)
$ErrorActionPreference = 'Stop'

$root    = Split-Path -Parent $MyInvocation.MyCommand.Path
$cfgPath = Join-Path $root 'config.json'
$logPath = Join-Path $root 'bubbles.log'
function Log($m) { if ($Preview) { return }; try { Add-Content -Path $logPath -Value ("{0:s} {1}" -f (Get-Date), $m) } catch {} }

$created = $false
$script:mutex = New-Object System.Threading.Mutex($true, $(if ($Preview) { 'Local\BubblesPreview' } else { 'Local\BubblesIsland' }), [ref]$created)
if (-not $created) { exit }

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing
$wb = [System.Windows.Interop.HwndSource].Assembly.Location
Add-Type -ReferencedAssemblies $wb -TypeDefinition @'
using System;
using System.Collections.Concurrent;
using System.IO;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Windows.Interop;

public static class VcNative {
    [DllImport("user32.dll")] public static extern bool RegisterHotKey(IntPtr h, int id, uint mod, uint vk);
    [DllImport("user32.dll")] public static extern bool UnregisterHotKey(IntPtr h, int id);
    [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
    [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vk);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr ctx);
    [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr h);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
}

public class VcHotkeySink {
    public Action<int> Fired;
    public HwndSourceHook Hook { get { return new HwndSourceHook(OnMsg); } }
    private IntPtr OnMsg(IntPtr hwnd, int msg, IntPtr w, IntPtr l, ref bool handled) {
        if (msg == 0x0312) { handled = true; if (Fired != null) Fired((int)w.ToInt64()); }
        return IntPtr.Zero;
    }
}

public class VcHookEvent {
    public string Name; public string Raw; public int Id;
}

// Watch-only listener on the pipe bubbles-hook.exe (built by install.ps1) sends Claude Code hook events to.
// It reads one line of JSON per connection, queues it, and closes. It never writes anything back,
// so it can never answer a permission request: Claude Code keeps asking in its own prompt.
public class VcPipeServer {
    public ConcurrentQueue<VcHookEvent> Queue = new ConcurrentQueue<VcHookEvent>();
    private string pipe; private volatile bool stop; private int counter;
    public VcPipeServer(string sid) { pipe = "bubbles-" + sid; }
    public string PipeName { get { return pipe; } }
    public void Start() { Thread t = new Thread(Loop); t.IsBackground = true; t.Start(); }
    public void Stop() {
        stop = true;
        try { using (NamedPipeClientStream c = new NamedPipeClientStream(".", pipe, PipeDirection.InOut)) { c.Connect(150); } } catch { }
    }
    private NamedPipeServerStream Create() {
        PipeSecurity ps = new PipeSecurity();
        ps.AddAccessRule(new PipeAccessRule(WindowsIdentity.GetCurrent().User, PipeAccessRights.FullControl, AccessControlType.Allow));
        return new NamedPipeServerStream(pipe, PipeDirection.InOut, NamedPipeServerStream.MaxAllowedServerInstances,
            PipeTransmissionMode.Byte, PipeOptions.None, 4096, 4096, ps);
    }
    private void Loop() {
        while (!stop) {
            NamedPipeServerStream s = null;
            try {
                s = Create(); s.WaitForConnection();
                NamedPipeServerStream c = s; s = null;
                ThreadPool.QueueUserWorkItem(delegate(object o) { Handle(c); });
            } catch { if (s != null) { try { s.Dispose(); } catch { } } Thread.Sleep(100); }
        }
    }
    private void Handle(NamedPipeServerStream s) {
        try {
            MemoryStream buf = new MemoryStream(); byte[] chunk = new byte[4096];
            while (true) {
                int n = s.Read(chunk, 0, chunk.Length);
                if (n <= 0) break;
                buf.Write(chunk, 0, n);
                if (Array.IndexOf(chunk, (byte)10, 0, n) >= 0 || buf.Length > (1 << 20)) break;
            }
            string raw = Encoding.UTF8.GetString(buf.ToArray());
            int nl = raw.IndexOf('\n'); if (nl >= 0) raw = raw.Substring(0, nl);
            if (raw.Length == 0) return;
            Match m = Regex.Match(raw, "\"hook_event_name\"\\s*:\\s*\"([^\"]+)\"");
            VcHookEvent ev = new VcHookEvent();
            ev.Name = m.Success ? m.Groups[1].Value : ""; ev.Raw = raw; ev.Id = Interlocked.Increment(ref counter);
            Queue.Enqueue(ev);
        } catch { }
        finally { try { s.Dispose(); } catch { } }
    }
}
'@

# Per-monitor DPI awareness (v2): crisp on every monitor instead of a stretched bitmap. Must run before any window exists.
try { [void][VcNative]::SetProcessDpiAwarenessContext([IntPtr](-4)) } catch {}

# ---------- config ----------
function Get-Config {
    $d = [ordered]@{ hotkey = 'Ctrl+Alt+V'; folder = $env:USERPROFILE; startDictation = $true; autoPaste = $true; autoSend = $true; bubbleMinutes = 0; showActivity = 'voice'; permSound = $true; restoreClipboard = $false; projects = @() }
    if (Test-Path $cfgPath) {
        try {
            $j = Get-Content $cfgPath -Raw | ConvertFrom-Json
            foreach ($k in @($d.Keys)) { if ($null -ne $j.$k) { $d[$k] = $j.$k } }
        } catch { Log "bad config.json: $_" }
    } else {
        $d | ConvertTo-Json | Set-Content $cfgPath -Encoding UTF8
    }
    $d
}

function ConvertTo-Hotkey($s) {
    $mod = 0x4000; $key = $null   # MOD_NOREPEAT
    foreach ($p in ($s -split '\+')) {
        $t = $p.Trim()
        if     ($t -match '^(ctrl|control)$')  { $mod = $mod -bor 2 }
        elseif ($t -match '^alt$')             { $mod = $mod -bor 1 }
        elseif ($t -match '^shift$')           { $mod = $mod -bor 4 }
        elseif ($t -match '^(win|windows)$')   { $mod = $mod -bor 8 }
        else   { $key = [System.Windows.Forms.Keys]$t }
    }
    if ($null -eq $key) { throw "Hotkey '$s' has no key in it." }
    [pscustomobject]@{ Mod = $mod; Vk = [int]$key }
}

# ---------- island UI ----------
$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        ShowInTaskbar="False" Topmost="True" ResizeMode="NoResize" UseLayoutRounding="True"
        SizeToContent="WidthAndHeight" ShowActivated="True">
  <Window.Resources>
    <Style x:Key="IconBtn" TargetType="Border">
      <Setter Property="Background" Value="#00FFFFFF"/>
      <Style.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="#26FFFFFF"/></Trigger></Style.Triggers>
    </Style>
    <Style x:Key="GhostBtn" TargetType="Border">
      <Setter Property="Background" Value="#0AFFFFFF"/>
      <Style.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="#1FFFFFFF"/></Trigger></Style.Triggers>
    </Style>
    <Style x:Key="PressBtn" TargetType="Border">
      <Setter Property="Opacity" Value="1"/>
      <Style.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter Property="Opacity" Value="0.86"/></Trigger></Style.Triggers>
    </Style>
  </Window.Resources>
  <Grid Margin="24">
    <Border x:Name="Pill" CornerRadius="28" Padding="14,12,22,13" BorderThickness="1" RenderTransformOrigin="0.5,0">
      <Border.Background>
        <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
          <GradientStop Color="#F71D1D25" Offset="0"/><GradientStop Color="#F80F0F14" Offset="1"/>
        </LinearGradientBrush>
      </Border.Background>
      <Border.BorderBrush>
        <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
          <GradientStop Color="#6086EBD3" Offset="0"/><GradientStop Color="#12FFFFFF" Offset="0.55"/>
        </LinearGradientBrush>
      </Border.BorderBrush>
      <Border.Effect><DropShadowEffect BlurRadius="34" ShadowDepth="8" Direction="270" Opacity="0.55" Color="Black"/></Border.Effect>
      <Border.RenderTransform>
        <TransformGroup>
          <ScaleTransform x:Name="PillScale" ScaleX="1" ScaleY="1"/>
          <TranslateTransform x:Name="PillShift" Y="0"/>
        </TransformGroup>
      </Border.RenderTransform>
      <Grid>
        <Grid.ColumnDefinitions><ColumnDefinition x:Name="ColA" Width="Auto"/><ColumnDefinition x:Name="ColB" Width="*"/></Grid.ColumnDefinitions>
        <Border x:Name="CloseX" Grid.ColumnSpan="2" Width="20" Height="20" CornerRadius="10" Background="#F5202028" BorderBrush="#40FFFFFF" BorderThickness="1"
                HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,-9,-13,0" Cursor="Hand" Visibility="Collapsed" Panel.ZIndex="9" ToolTip="Close">
          <Border.Effect><DropShadowEffect BlurRadius="8" ShadowDepth="1" Direction="270" Opacity="0.5" Color="Black"/></Border.Effect>
          <TextBlock Text="&#xE8BB;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="7.5" Foreground="#E0FFFFFF" HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Border>

        <!-- the character -->
        <Grid x:Name="BlobHost" Width="52" Height="52" Margin="0,0,14,0" VerticalAlignment="Top" RenderTransformOrigin="0.5,0.5">
          <Grid.RenderTransform><ScaleTransform x:Name="OrbScale" ScaleX="1" ScaleY="1"/></Grid.RenderTransform>
          <Ellipse x:Name="Aura" Margin="-14" IsHitTestVisible="False" Opacity="0.6" RenderTransformOrigin="0.5,0.5">
            <Ellipse.Fill>
              <RadialGradientBrush>
                <GradientStop x:Name="AuraC" Color="#882FC4A3" Offset="0.3"/>
                <GradientStop x:Name="AuraE" Color="#002FC4A3" Offset="1"/>
              </RadialGradientBrush>
            </Ellipse.Fill>
            <Ellipse.RenderTransform><ScaleTransform x:Name="AuraScale" ScaleX="1" ScaleY="1"/></Ellipse.RenderTransform>
          </Ellipse>
          <Ellipse Name="Ring" Width="46" Height="46" Stroke="#4FD1B5" StrokeThickness="2" Opacity="0" RenderTransformOrigin="0.5,0.5" IsHitTestVisible="False">
            <Ellipse.RenderTransform><ScaleTransform x:Name="RingScale" ScaleX="1" ScaleY="1"/></Ellipse.RenderTransform>
          </Ellipse>
          <Ellipse x:Name="Shock" Width="46" Height="46" Stroke="#7EE08A" StrokeThickness="3" Opacity="0" RenderTransformOrigin="0.5,0.5" IsHitTestVisible="False">
            <Ellipse.RenderTransform><ScaleTransform x:Name="ShockScale" ScaleX="1" ScaleY="1"/></Ellipse.RenderTransform>
          </Ellipse>
          <Grid x:Name="SpinHost" Margin="-3" Visibility="Collapsed" IsHitTestVisible="False" RenderTransformOrigin="0.5,0.5">
            <Grid.RenderTransform><RotateTransform x:Name="SpinRot" Angle="0"/></Grid.RenderTransform>
            <Ellipse Stroke="#1CFFFFFF" StrokeThickness="2.2"/>
            <Ellipse x:Name="SpinArc" Stroke="#A6F7E1" StrokeThickness="2.6" StrokeDashArray="13 70" StrokeDashCap="Round"/>
          </Grid>
          <Grid x:Name="Jelly" RenderTransformOrigin="0.5,0.5">
            <Grid.RenderTransform>
              <TransformGroup><RotateTransform x:Name="JR1" Angle="0"/><ScaleTransform x:Name="JS" ScaleX="1" ScaleY="1"/><RotateTransform x:Name="JR2" Angle="0"/></TransformGroup>
            </Grid.RenderTransform>
            <Grid x:Name="Body" Width="46" Height="44" RenderTransformOrigin="0.5,0.5">
              <Grid.RenderTransform>
                <TransformGroup>
                  <ScaleTransform x:Name="BodyScale" ScaleX="1" ScaleY="1"/>
                  <ScaleTransform x:Name="Breath" ScaleX="1" ScaleY="1"/>
                  <TranslateTransform x:Name="BodyShift" X="0" Y="0"/>
                </TransformGroup>
              </Grid.RenderTransform>
              <Grid.Effect><DropShadowEffect BlurRadius="14" ShadowDepth="4" Direction="270" Opacity="0.45" Color="Black"/></Grid.Effect>
              <Ellipse>
                <Ellipse.Fill>
                  <RadialGradientBrush GradientOrigin="0.34,0.26" Center="0.42,0.36" RadiusX="0.74" RadiusY="0.74">
                    <GradientStop x:Name="G1" Color="#A6F7E1" Offset="0"/>
                    <GradientStop x:Name="G2" Color="#2FC4A3" Offset="0.62"/>
                    <GradientStop x:Name="G3" Color="#176252" Offset="1"/>
                  </RadialGradientBrush>
                </Ellipse.Fill>
              </Ellipse>
              <Ellipse Width="30" Height="11" VerticalAlignment="Bottom" Margin="0,0,0,2" IsHitTestVisible="False">
                <Ellipse.Fill>
                  <RadialGradientBrush><GradientStop Color="#50FFFFFF" Offset="0"/><GradientStop Color="#00FFFFFF" Offset="1"/></RadialGradientBrush>
                </Ellipse.Fill>
              </Ellipse>
              <Ellipse StrokeThickness="1.2" IsHitTestVisible="False">
                <Ellipse.Stroke>
                  <LinearGradientBrush StartPoint="0.3,0" EndPoint="0.7,1">
                    <GradientStop Color="#90FFFFFF" Offset="0"/><GradientStop Color="#00FFFFFF" Offset="0.45"/><GradientStop Color="#2EFFFFFF" Offset="1"/>
                  </LinearGradientBrush>
                </Ellipse.Stroke>
              </Ellipse>
              <Grid x:Name="Spec" IsHitTestVisible="False">
                <Grid.RenderTransform><TranslateTransform x:Name="SpecShift" X="0" Y="0"/></Grid.RenderTransform>
                <Ellipse Width="21" Height="11" HorizontalAlignment="Left" VerticalAlignment="Top" Margin="7,5,0,0" RenderTransformOrigin="0.5,0.5">
                  <Ellipse.RenderTransform><RotateTransform Angle="-24"/></Ellipse.RenderTransform>
                  <Ellipse.Fill>
                    <RadialGradientBrush><GradientStop Color="#A8FFFFFF" Offset="0"/><GradientStop Color="#00FFFFFF" Offset="1"/></RadialGradientBrush>
                  </Ellipse.Fill>
                </Ellipse>
                <Ellipse Width="4.5" Height="3.5" Fill="#F0FFFFFF" HorizontalAlignment="Left" VerticalAlignment="Top" Margin="11.5,8.5,0,0"/>
              </Grid>
              <Canvas x:Name="Face" Width="46" Height="44" IsHitTestVisible="False">
                <Canvas.RenderTransform><TranslateTransform x:Name="FaceShift" X="0" Y="0"/></Canvas.RenderTransform>
                <Canvas x:Name="Cheeks" Opacity="0.55">
                  <Ellipse Canvas.Left="6.5" Canvas.Top="22" Width="8" Height="4.6">
                    <Ellipse.Fill><RadialGradientBrush><GradientStop Color="#C0FF7A9C" Offset="0"/><GradientStop Color="#00FF7A9C" Offset="1"/></RadialGradientBrush></Ellipse.Fill>
                  </Ellipse>
                  <Ellipse Canvas.Left="31.5" Canvas.Top="22" Width="8" Height="4.6">
                    <Ellipse.Fill><RadialGradientBrush><GradientStop Color="#C0FF7A9C" Offset="0"/><GradientStop Color="#00FF7A9C" Offset="1"/></RadialGradientBrush></Ellipse.Fill>
                  </Ellipse>
                </Canvas>
                <Canvas x:Name="EyesIdle">
                  <Canvas.RenderTransform><ScaleTransform x:Name="EyesWide" ScaleX="1" ScaleY="1" CenterX="23" CenterY="18"/></Canvas.RenderTransform>
                  <Grid Canvas.Left="13.25" Canvas.Top="13.5" Width="6.5" Height="9" RenderTransformOrigin="0.5,0.5">
                    <Grid.RenderTransform><ScaleTransform x:Name="EyeL" ScaleX="1" ScaleY="1"/></Grid.RenderTransform>
                    <Ellipse Fill="#1A1A2C"/>
                    <Ellipse Width="2.5" Height="2.5" Fill="#FFFFFF" HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,1.3,0.9,0"/>
                  </Grid>
                  <Grid Canvas.Left="26.25" Canvas.Top="13.5" Width="6.5" Height="9" RenderTransformOrigin="0.5,0.5">
                    <Grid.RenderTransform><ScaleTransform x:Name="EyeR" ScaleX="1" ScaleY="1"/></Grid.RenderTransform>
                    <Ellipse Fill="#1A1A2C"/>
                    <Ellipse Width="2.5" Height="2.5" Fill="#FFFFFF" HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,1.3,0.9,0"/>
                  </Grid>
                </Canvas>
                <Canvas x:Name="EyesHappy" Visibility="Collapsed">
                  <Path Data="M13.5,19.5 Q16.5,14 19.5,19.5" Stroke="#1A1A2C" StrokeThickness="2.4" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
                  <Path Data="M26.5,19.5 Q29.5,14 32.5,19.5" Stroke="#1A1A2C" StrokeThickness="2.4" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
                </Canvas>
                <Canvas x:Name="EyesSleep" Visibility="Collapsed">
                  <Path Data="M13.5,18 Q16.5,21 19.5,18" Stroke="#1A1A2C" StrokeThickness="2" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
                  <Path Data="M26.5,18 Q29.5,21 32.5,18" Stroke="#1A1A2C" StrokeThickness="2" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
                </Canvas>
                <Path x:Name="Mouth" Data="M19.5,26.2 Q23,29.6 26.5,26.2" Stroke="#1A1A2C" StrokeThickness="1.8" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"/>
                <Ellipse x:Name="MouthO" Canvas.Left="20.6" Canvas.Top="25" Width="4.8" Height="5.4" Fill="#1A1A2C" Visibility="Collapsed"/>
              </Canvas>
            </Grid>
          </Grid>
          <Canvas x:Name="Fx" HorizontalAlignment="Center" VerticalAlignment="Center" Width="0" Height="0" IsHitTestVisible="False"/>
          <Canvas x:Name="Zzz" HorizontalAlignment="Right" VerticalAlignment="Top" Width="0" Height="0" Margin="0,6,8,0" Visibility="Collapsed" IsHitTestVisible="False">
            <TextBlock x:Name="Z1" Text="z" FontSize="11" FontWeight="Bold" Foreground="#DDFFFFFF" FontFamily="Segoe UI Variable Display, Segoe UI" Opacity="0">
              <TextBlock.RenderTransform><TranslateTransform x:Name="Z1T"/></TextBlock.RenderTransform>
            </TextBlock>
            <TextBlock x:Name="Z2" Text="z" FontSize="8" FontWeight="Bold" Foreground="#DDFFFFFF" FontFamily="Segoe UI Variable Display, Segoe UI" Opacity="0" Canvas.Left="-3" Canvas.Top="3">
              <TextBlock.RenderTransform><TranslateTransform x:Name="Z2T"/></TextBlock.RenderTransform>
            </TextBlock>
          </Canvas>
          <Border x:Name="LabelHost" Background="#F2141418" BorderBrush="#30FFFFFF" BorderThickness="1" CornerRadius="7" Padding="5,0,5,1" HorizontalAlignment="Center" VerticalAlignment="Bottom" Margin="0,0,0,-8" IsHitTestVisible="False" Visibility="Collapsed" Panel.ZIndex="3">
            <TextBlock x:Name="LabelText" FontSize="9" FontWeight="Bold" Foreground="#E8E8EE" FontFamily="Segoe UI Variable Text, Segoe UI"/>
          </Border>
          <Grid x:Name="BadgeHost" Width="18" Height="18" HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,-1,-2,0" Visibility="Collapsed" RenderTransformOrigin="0.5,0.5" Panel.ZIndex="4">
            <Grid.RenderTransform><ScaleTransform x:Name="BadgeScale" ScaleX="1" ScaleY="1"/></Grid.RenderTransform>
            <Ellipse x:Name="BadgeBg" Fill="#7EE08A" Stroke="#141418" StrokeThickness="2.5"/>
            <TextBlock x:Name="BadgeText" Text="" FontSize="9" FontWeight="Bold" Foreground="#0B2A12" HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Grid>
        </Grid>

        <StackPanel x:Name="Col1" Grid.Column="1" VerticalAlignment="Top" HorizontalAlignment="Left">
          <StackPanel.RenderTransform><TranslateTransform x:Name="ColShift" X="0" Y="0"/></StackPanel.RenderTransform>
          <!-- input island -->
          <StackPanel x:Name="TextCol" Width="470" HorizontalAlignment="Left">
            <Grid>
              <TextBlock x:Name="Placeholder" Text="Say what you want Claude to do..." Foreground="#66FFFFFF"
                         FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="17" IsHitTestVisible="False" VerticalAlignment="Center"/>
              <TextBox x:Name="Input" Background="Transparent" Foreground="#F5F5F7" CaretBrush="#A6F7E1"
                       BorderThickness="0" FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="17" TextWrapping="Wrap"
                       AcceptsReturn="False" MaxHeight="110" VerticalScrollBarVisibility="Auto" Padding="0" Margin="0,0,46,0"/>
              <StackPanel x:Name="Wave" Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,5,2,0" Visibility="Collapsed">
                <Border Width="3" Height="18" CornerRadius="1.5" Background="#A6F7E1" Margin="1.5,0" RenderTransformOrigin="0.5,0.5"><Border.RenderTransform><ScaleTransform x:Name="W1" ScaleY="0.4"/></Border.RenderTransform></Border>
                <Border Width="3" Height="18" CornerRadius="1.5" Background="#86EBD3" Margin="1.5,0" RenderTransformOrigin="0.5,0.5"><Border.RenderTransform><ScaleTransform x:Name="W2" ScaleY="0.7"/></Border.RenderTransform></Border>
                <Border Width="3" Height="18" CornerRadius="1.5" Background="#5FD8BC" Margin="1.5,0" RenderTransformOrigin="0.5,0.5"><Border.RenderTransform><ScaleTransform x:Name="W3" ScaleY="1"/></Border.RenderTransform></Border>
                <Border Width="3" Height="18" CornerRadius="1.5" Background="#86EBD3" Margin="1.5,0" RenderTransformOrigin="0.5,0.5"><Border.RenderTransform><ScaleTransform x:Name="W4" ScaleY="0.6"/></Border.RenderTransform></Border>
                <Border Width="3" Height="18" CornerRadius="1.5" Background="#A6F7E1" Margin="1.5,0" RenderTransformOrigin="0.5,0.5"><Border.RenderTransform><ScaleTransform x:Name="W5" ScaleY="0.35"/></Border.RenderTransform></Border>
              </StackPanel>
            </Grid>
            <Grid Margin="0,6,0,0">
              <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
              <TextBlock x:Name="Hint" Text="" Foreground="#80FFFFFF" FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="11.5"
                         TextWrapping="Wrap" VerticalAlignment="Center"/>
              <Button x:Name="CopyBtn" Grid.Column="1" Content="Copy" Visibility="Collapsed" Focusable="False" Cursor="Hand"
                      Margin="10,0,0,0" Padding="10,2" FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="11.5"
                      Foreground="#F5F5F7" Background="#33FFFFFF" BorderThickness="0"/>
            </Grid>
            <WrapPanel x:Name="ProjectRow" Margin="0,10,0,0" Visibility="Collapsed"/>
            <ScrollViewer x:Name="SessionScroll" Margin="0,8,0,0" MaxHeight="176" VerticalScrollBarVisibility="Hidden" Visibility="Collapsed">
              <StackPanel x:Name="SessionList"/>
            </ScrollViewer>
          </StackPanel>

          <!-- bubble card: header + current activity -->
          <StackPanel x:Name="StatusCol" Visibility="Collapsed" HorizontalAlignment="Left" VerticalAlignment="Center">
            <Grid x:Name="HeadRow" Background="#00000000">
              <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
              <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                <TextBlock x:Name="ProjText" Foreground="#FFFFFF" FontFamily="Segoe UI Variable Display, Segoe UI" FontSize="13.5" FontWeight="SemiBold" VerticalAlignment="Center"/>
                <TextBlock x:Name="TitleText" Foreground="#7C7C88" FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="12" Margin="8,1,0,0" TextTrimming="CharacterEllipsis" MaxWidth="150" VerticalAlignment="Center"/>
              </StackPanel>
              <StackPanel x:Name="HdrBtns" Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center" Margin="10,0,0,0">
                <Border x:Name="StateChip" CornerRadius="8" Padding="7,1,7,2" Background="#2286EBD3" VerticalAlignment="Center">
                  <TextBlock x:Name="StateText" FontSize="9.5" FontWeight="Bold" Foreground="#86EBD3" FontFamily="Segoe UI Variable Text, Segoe UI"/>
                </Border>
                <Border x:Name="HdrMin" Style="{StaticResource IconBtn}" Width="22" Height="22" CornerRadius="11" Cursor="Hand" Margin="6,0,0,0" ToolTip="Collapse">
                  <TextBlock Text="&#xE921;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="9" Foreground="#A0A0AC" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                </Border>
                <Border x:Name="HdrClose" Style="{StaticResource IconBtn}" Width="22" Height="22" CornerRadius="11" Cursor="Hand" Margin="2,0,0,0" ToolTip="Close bubble">
                  <TextBlock Text="&#xE8BB;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="8.5" Foreground="#A0A0AC" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                </Border>
              </StackPanel>
            </Grid>
            <StackPanel Orientation="Horizontal" Margin="0,5,0,0">
              <Ellipse x:Name="StatusDot" Width="7" Height="7" Fill="#86EBD3" Margin="1,1,8,0" VerticalAlignment="Center"/>
              <TextBlock x:Name="ActText" Foreground="#F2F2F5" FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="13" TextTrimming="CharacterEllipsis" MaxWidth="300"/>
            </StackPanel>
            <TextBlock x:Name="MetaText" Foreground="#74747E" FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="11" Margin="16,2,0,0" TextTrimming="CharacterEllipsis" MaxWidth="300" HorizontalAlignment="Left"/>
            <Border x:Name="Shimmer" Height="2" CornerRadius="1" Background="#14FFFFFF" Margin="16,9,0,1" ClipToBounds="True" Visibility="Collapsed">
              <Border Width="90" CornerRadius="1" Background="#86EBD3" HorizontalAlignment="Left">
                <Border.RenderTransform><TranslateTransform x:Name="ShimmerShift" X="-90"/></Border.RenderTransform>
              </Border>
            </Border>
          </StackPanel>

          <!-- bubble card: Claude needs you -->
          <StackPanel x:Name="AlertPanel" Visibility="Collapsed" Margin="0,12,0,2" Width="330" HorizontalAlignment="Left">
            <Border Background="#22F0B94A" BorderBrush="#55F0B94A" BorderThickness="1" CornerRadius="14" Padding="12,10,12,11">
              <StackPanel>
                <StackPanel Orientation="Horizontal">
                  <TextBlock Text="&#xE7BA;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="13" Foreground="#F6C453" VerticalAlignment="Center" Margin="0,0,8,0"/>
                  <TextBlock x:Name="AlertHead" Foreground="#FBDB8C" FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="12.5" FontWeight="SemiBold" VerticalAlignment="Center"/>
                </StackPanel>
                <Border x:Name="AlertBox" Background="#40000000" CornerRadius="8" Padding="9,7" Margin="0,8,0,0">
                  <TextBlock x:Name="AlertBody" Foreground="#EFE6CC" FontFamily="Consolas" FontSize="11.5" TextWrapping="Wrap" MaxHeight="96"/>
                </Border>
              </StackPanel>
            </Border>
            <Border x:Name="BtnOpenClaude" Style="{StaticResource PressBtn}" Background="#F6C453" CornerRadius="15" Padding="13,6,16,7" Cursor="Hand" HorizontalAlignment="Right" Margin="0,10,0,0">
              <StackPanel Orientation="Horizontal">
                <TextBlock Text="&#xE8A7;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="11" Foreground="#3A2A05" VerticalAlignment="Center" Margin="0,1,7,0"/>
                <TextBlock Text="Open Claude to answer" Foreground="#3A2A05" FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="12" FontWeight="SemiBold"/>
              </StackPanel>
            </Border>
          </StackPanel>

          <!-- bubble card: activity timeline + Claude's words + actions -->
          <StackPanel x:Name="LogPanel" Visibility="Collapsed" Margin="0,12,0,2" Width="330" HorizontalAlignment="Left">
            <Border Height="1" Background="#14FFFFFF" Margin="0,0,0,10"/>
            <Grid>
              <TextBlock Text="ACTIVITY" Foreground="#5E5E6A" FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="9.5" FontWeight="Bold"/>
              <TextBlock x:Name="LogCount" HorizontalAlignment="Right" Foreground="#5E5E6A" FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="9.5"/>
            </Grid>
            <ScrollViewer x:Name="LogScroll" MaxHeight="176" VerticalScrollBarVisibility="Hidden" Margin="0,7,0,0">
              <StackPanel x:Name="LogList"/>
            </ScrollViewer>
            <TextBlock x:Name="ThinkLabel" Text="CLAUDE SAYS" Foreground="#5E5E6A" FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="9.5" FontWeight="Bold" Margin="0,12,0,0"/>
            <Border x:Name="ThinkBox" Background="#0CFFFFFF" CornerRadius="10" Margin="0,7,0,0">
              <Grid>
                <Border x:Name="ThinkBar" Width="3" CornerRadius="1.5" Background="#86EBD3" HorizontalAlignment="Left" Margin="0,9"/>
                <TextBlock x:Name="ThinkText" Margin="13,9,11,10" Foreground="#B9B9C4" FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="12" TextWrapping="Wrap" MaxHeight="98" TextTrimming="CharacterEllipsis"/>
              </Grid>
            </Border>
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,12,0,0">
              <Border x:Name="OpenBtn" Style="{StaticResource GhostBtn}" CornerRadius="15" Padding="12,6,14,7" Cursor="Hand" BorderThickness="1" BorderBrush="#24FFFFFF" Margin="0,0,8,0">
                <StackPanel Orientation="Horizontal">
                  <TextBlock Text="&#xE8A7;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="11" Foreground="#C8C8D2" VerticalAlignment="Center" Margin="0,1,7,0"/>
                  <TextBlock Text="Open in Claude" Foreground="#D6D6DE" FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="12"/>
                </StackPanel>
              </Border>
              <Border x:Name="ReplyBtn" Style="{StaticResource PressBtn}" CornerRadius="15" Padding="12,6,15,7" Cursor="Hand" Background="#A6F7E1">
                <StackPanel Orientation="Horizontal">
                  <TextBlock Text="&#xE720;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="11" Foreground="#10201C" VerticalAlignment="Center" Margin="0,1,7,0"/>
                  <TextBlock Text="Reply" Foreground="#10201C" FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="12" FontWeight="SemiBold"/>
                </StackPanel>
              </Border>
            </StackPanel>
          </StackPanel>
        </StackPanel>
      </Grid>
    </Border>
  </Grid>
</Window>
'@
$win         = [System.Windows.Markup.XamlReader]::Parse($xaml)
$input_      = $win.FindName('Input')
$placeholder = $win.FindName('Placeholder')
$hint        = $win.FindName('Hint')
$copyBtn     = $win.FindName('CopyBtn')
$projectRow  = $win.FindName('ProjectRow')
$closeX      = $win.FindName('CloseX')
$pill        = $win.FindName('Pill')
$textCol     = $win.FindName('TextCol')
$statusCol   = $win.FindName('StatusCol')
$actText     = $win.FindName('ActText')
$metaText    = $win.FindName('MetaText')
$alertPanel  = $win.FindName('AlertPanel')
$alertHead   = $win.FindName('AlertHead')
$alertBody   = $win.FindName('AlertBody')
$statusDot   = $win.FindName('StatusDot')
$shimmer     = $win.FindName('Shimmer')
$shimmerShift = $win.FindName('ShimmerShift')
$pillScale   = $win.FindName('PillScale')
$wave        = $win.FindName('Wave')
$colA        = $win.FindName('ColA')
$colB        = $win.FindName('ColB')
$col1        = $win.FindName('Col1')
$blobHost    = $win.FindName('BlobHost')
$badgeHost   = $win.FindName('BadgeHost')
$badgeBg     = $win.FindName('BadgeBg')
$badgeText   = $win.FindName('BadgeText')
$btnOpen     = $win.FindName('BtnOpenClaude')
$logPanel    = $win.FindName('LogPanel')
$logScroll   = $win.FindName('LogScroll')
$logList     = $win.FindName('LogList')
$thinkLabel  = $win.FindName('ThinkLabel')
$thinkText   = $win.FindName('ThinkText')
$replyBtn    = $win.FindName('ReplyBtn')
$g1          = $win.FindName('G1')
$g2          = $win.FindName('G2')
$sessionList = $win.FindName('SessionList')
$sessScroll  = $win.FindName('SessionScroll')
$ring       = $win.FindName('Ring')
$ringScale   = $win.FindName('RingScale')
$bodyScale   = $win.FindName('BodyScale')
$bodyShift   = $win.FindName('BodyShift')
$pillShift   = $win.FindName('PillShift')
$eyeL        = $win.FindName('EyeL')
$eyeR        = $win.FindName('EyeR')
$eyesIdle    = $win.FindName('EyesIdle')
$eyesHappy   = $win.FindName('EyesHappy')

$script:visible = $false
$script:sending = $false
$script:cfg     = Get-Config
$DP = [System.Windows.DependencyProperty]

function New-Anim($from, $to, $ms) {
    $a = New-Object System.Windows.Media.Animation.DoubleAnimation
    $a.From = [double]$from; $a.To = [double]$to
    $a.Duration = [TimeSpan]::FromMilliseconds($ms)
    $a
}
function Set-Hint($text, $color) {
    $hint.Text = $text
    $hint.Foreground = (New-Object System.Windows.Media.BrushConverter).ConvertFromString($color)
    $copyBtn.Visibility = 'Collapsed'
}
function Get-ErrorReport($msg) {
    $probe = foreach ($p in 'HKCU:\Software\Classes\claude', 'HKLM:\Software\Classes\claude', 'Registry::HKEY_CLASSES_ROOT\claude\shell\open\command') {
        "$p = $(Test-Path $p)"
    }
    @(
        'Bubbles error',
        $msg,
        '',
        "hotkey=$($script:cfg.hotkey) folder=$($script:cfg.folder)",
        "64bit=$([Environment]::Is64BitProcess) powershell=$($PSVersionTable.PSVersion) os=$([Environment]::OSVersion.Version)"
    ) + $probe -join "`r`n"
}
function Show-Error($msg) {
    Log "error: $msg"
    $script:lastReport = Get-ErrorReport $msg
    Set-Hint $msg '#FFFF8F8F'
    $copyBtn.Content = 'Copy'
    $copyBtn.Visibility = 'Visible'
}
$statePath = Join-Path $root 'state.json'
$script:projects = @()
$script:projIdx  = 0
$script:pills    = @()

function New-Brush($hex) { (New-Object System.Windows.Media.BrushConverter).ConvertFromString($hex) }

# Each project gets spoken-name phrases. Phrases in 'open' work on their own ("storefront fix the header");
# 'trig' phrases (first word of a name) only work after a lead-in word ("in storefront fix the header").
function Get-Projects {
    $list = @()
    foreach ($p in @($script:cfg.projects)) {
        if ($p -and $p.folder) {
            $n = $(if ($p.name) { [string]$p.name } else { Split-Path -Leaf ([string]$p.folder) })
            $open = @(); $trig = @($n)
            if ($n.ToLower() -ne 'home') { $open += $n }
            foreach ($a in @($p.aliases)) { if ($a) { $open += [string]$a; $trig += [string]$a } }
            $first = ($n -split '\s+')[0]
            if ($first.Length -ge 4) { $trig += $first }
            $list += [pscustomobject]@{ Name = $n; Folder = [string]$p.folder; Open = $open; Trig = $trig }
        }
    }
    if ($list.Count -eq 0) {
        $list += [pscustomobject]@{ Name = 'Home'; Folder = [string]$script:cfg.folder; Open = @(); Trig = @('home') }
    }
    $list
}

function ConvertTo-PhraseRegex($phrase) {
    (($phrase.Trim() -split '\s+') | ForEach-Object { [regex]::Escape($_) }) -join '\s+'
}

# Returns @{ Index; Length } when the text starts with a project name (longest match wins), else $null.
function Find-ProjectPrefix($text) {
    $lead = '(?:(?:in|on|for|to|open|project|use|switch to|go to)\s+)'
    $best = $null
    for ($i = 0; $i -lt $script:projects.Count; $i++) {
        $p = $script:projects[$i]
        $tests = @()
        foreach ($ph in $p.Open) { $tests += "^\s*$lead?(?:the\s+)?($(ConvertTo-PhraseRegex $ph))\b[\s,:;.\-]*" }
        foreach ($ph in $p.Trig) { $tests += "^\s*$lead(?:the\s+)?($(ConvertTo-PhraseRegex $ph))\b[\s,:;.\-]*" }
        foreach ($pat in $tests) {
            $m = [regex]::Match($text, $pat, 'IgnoreCase')
            if ($m.Success -and ($null -eq $best -or $m.Length -gt $best.Length)) {
                $best = @{ Index = $i; Length = $m.Length }
            }
        }
    }
    $best
}

function Update-Pills {
    for ($k = 0; $k -lt $script:pills.Count; $k++) {
        $sel = ($k -eq $script:projIdx)
        $script:pills[$k].Background       = New-Brush $(if ($sel) { '#4086EBD3' } else { '#16FFFFFF' })
        $script:pills[$k].Child.Foreground = New-Brush $(if ($sel) { '#FFB8F5E6' } else { '#B0FFFFFF' })
    }
}
function Build-Pills {
    $projectRow.Children.Clear(); $script:pills = @()
    $projectRow.Visibility = 'Visible'
    for ($i = 0; $i -lt $script:projects.Count; $i++) {
        $tb = New-Object System.Windows.Controls.TextBlock
        $tb.Text = $(if ($i -lt 9) { "$($i + 1)  " } else { '' }) + $script:projects[$i].Name
        $tb.FontFamily = New-Object System.Windows.Media.FontFamily 'Segoe UI Variable Text, Segoe UI'
        $tb.FontSize = 11.5
        $b = New-Object System.Windows.Controls.Border
        $b.Child = $tb
        $b.CornerRadius = New-Object System.Windows.CornerRadius 10
        $b.Padding = New-Object System.Windows.Thickness 9, 2, 9, 2
        $b.Margin  = New-Object System.Windows.Thickness 0, 0, 6, 5
        $b.Cursor  = [System.Windows.Input.Cursors]::Hand
        $b.Tag = $i
        $b.Add_MouseLeftButtonUp({ param($s, $e) Set-Project ([int]$s.Tag); [void]$input_.Focus() })
        [void]$projectRow.Children.Add($b)
        $script:pills += $b
    }
    $stb = New-Object System.Windows.Controls.TextBlock
    $stb.Text = 'Sessions ' + [string][char]0x25BE
    $stb.FontFamily = New-Object System.Windows.Media.FontFamily 'Segoe UI Variable Text, Segoe UI'
    $stb.FontSize = 11.5; $stb.Foreground = New-Brush '#86EBD3'
    $sb = New-Object System.Windows.Controls.Border
    $sb.Child = $stb
    $sb.CornerRadius = New-Object System.Windows.CornerRadius 10
    $sb.Padding = New-Object System.Windows.Thickness 9, 2, 9, 2
    $sb.Margin  = New-Object System.Windows.Thickness 0, 0, 6, 5
    $sb.BorderThickness = New-Object System.Windows.Thickness 1
    $sb.BorderBrush = New-Brush '#5586EBD3'
    $sb.Cursor = [System.Windows.Input.Cursors]::Hand
    $sb.Add_MouseLeftButtonUp({
        if ($script:sessOpen) { Close-Sessions; Set-Hint 'New session in the selected project. Enter sends.' '#80FFFFFF' } else { Open-Sessions }
        [void]$input_.Focus()
    })
    [void]$projectRow.Children.Add($sb)
}
function Set-Project($i) {
    $n = $script:projects.Count
    $script:projIdx = (($i % $n) + $n) % $n
    Update-Pills
}
function Step-Project($d) { Set-Project ($script:projIdx + $d) }
function Save-State {
    if ($Preview) { return }
    try {
        $o = [ordered]@{}
        try { $j = Get-Content $statePath -Raw -ErrorAction Stop | ConvertFrom-Json; foreach ($pr in $j.PSObject.Properties) { $o[$pr.Name] = $pr.Value } } catch {}
        if ($script:projects -and $script:projects.Count -gt $script:projIdx) { $o['last'] = $script:projects[$script:projIdx].Name }
        $o['dockSide'] = $script:dockSide; $o['dockFrac'] = [math]::Round($script:dockFrac, 4); $o['dockScreen'] = $script:dockScreen
        if ($null -ne $script:bubbles) {
            $o['bubbles'] = @($script:bubbles | Where-Object { -not $_.Auto -and ($_.Sid -or $_.LocalId) } | ForEach-Object {
                [ordered]@{ sid = $_.Sid; localId = $_.LocalId; project = $_.Project; title = $_.Title; color = $_.Color; side = $_.Side; frac = [math]::Round($_.Frac, 4); screen = $_.Screen } })
        }
        ($o | ConvertTo-Json -Depth 5) | Set-Content $statePath -Encoding ASCII
    } catch { Log "state save: $_" }
}
function Save-LastProject { Save-State }
function Load-Dock {
    try {
        $j = Get-Content $statePath -Raw -ErrorAction Stop | ConvertFrom-Json
        if ($j.dockSide -eq 'left' -or $j.dockSide -eq 'right') { $script:dockSide = [string]$j.dockSide }
        if ($null -ne $j.dockFrac) { $script:dockFrac = [math]::Min(1, [math]::Max(0, [double]$j.dockFrac)) }
        if ($j.dockScreen) { $script:dockScreen = [string]$j.dockScreen }
    } catch {}
}
function Restore-LastProject {
    $script:projects = @(Get-Projects)
    Build-Pills
    $i = 0
    try {
        $last = (Get-Content $statePath -Raw -ErrorAction Stop | ConvertFrom-Json).last
        for ($k = 0; $k -lt $script:projects.Count; $k++) { if ($script:projects[$k].Name -eq $last) { $i = $k } }
    } catch {}
    Set-Project $i
}
$copyBtn.Add_Click({
    $ok = $false
    for ($i = 0; $i -lt 5 -and -not $ok; $i++) {
        try { [System.Windows.Clipboard]::SetText([string]$script:lastReport); $ok = $true }
        catch { Start-Sleep -Milliseconds 60 }
    }
    $copyBtn.Content = $(if ($ok) { 'Copied' } else { 'Failed' })
})
function Set-Mood($happy) { Set-OrbMood $script:pillOrb $(if ($happy) { 'happy' } else { 'listen' }) }
function Start-Pulse {
    $s = New-Anim 0.9 1.45 1100; $s.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
    $o = New-Anim 0.7 0 1100;    $o.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
    $ringScale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, $s)
    $ringScale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, $s)
    $ring.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $o)
}
function Stop-Pulse {
    $ringScale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, $null)
    $ringScale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, $null)
    $ring.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
    $ring.Opacity = 0
}
function Blink {
    foreach ($t in @($eyeL, $eyeR)) {
        $a = New-Anim 1 0.1 90; $a.AutoReverse = $true
        $t.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, $a)
    }
}
function Wiggle {
    $a = New-Anim 1 1.09 110; $a.AutoReverse = $true
    $bodyScale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, $a)
    $bodyScale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, $a)
}
function Jump {
    $a = New-Anim 0 -9 130; $a.AutoReverse = $true; $a.RepeatBehavior = New-Object System.Windows.Media.Animation.RepeatBehavior(2)
    $bodyShift.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $a)
    Burst-Orb $script:pillOrb
}

$blinkTimer = New-Object System.Windows.Threading.DispatcherTimer
$blinkTimer.Interval = [TimeSpan]::FromSeconds(3)
$blinkTimer.Add_Tick({
    if ($script:visible -and -not $script:sending) { Blink }
    $blinkTimer.Interval = [TimeSpan]::FromMilliseconds(2200 + (Get-Random -Maximum 3200))
})
$blinkTimer.Start()

# ---------- sessions: continue an existing Code session ----------
$script:sessions  = $null
$script:sessShown = 5
$script:selPos    = 0
$script:sessOpen  = $false

function Get-Sessions {
    $root = Join-Path $env:APPDATA 'Claude\claude-code-sessions'
    $list = New-Object System.Collections.ArrayList
    if (Test-Path $root) {
        Get-ChildItem $root -Recurse -File -Filter 'local_*.json' -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                $j = Get-Content $_.FullName -Raw | ConvertFrom-Json
                if ($j.sessionId -and -not $j.isArchived -and ([string]$j.sessionId) -match '^local_[A-Za-z0-9-]{1,64}$') {
                    $t = ([string]$j.title).Trim(); if (-not $t) { $t = '(untitled)' }
                    $cwd = [string]$j.cwd
                    [void]$list.Add([pscustomobject]@{
                        Id = [string]$j.sessionId; Title = $t
                        Project = $(if ($cwd) { Split-Path -Leaf $cwd } else { '' })
                        Last = [int64]$j.lastActivityAt })
                }
            } catch { Log "session read: $_" }
        }
    }
    @($list | Sort-Object Last -Descending)
}
function Format-Ago([int64]$ms) {
    $span = [DateTime]::UtcNow - [DateTimeOffset]::FromUnixTimeMilliseconds($ms).UtcDateTime
    if ($span.TotalMinutes -lt 1)  { return 'now' }
    if ($span.TotalMinutes -lt 60) { return "$([int]$span.TotalMinutes)m ago" }
    if ($span.TotalHours   -lt 24) { return "$([int]$span.TotalHours)h ago" }
    if ($span.TotalDays    -lt 30) { return "$([int]$span.TotalDays)d ago" }
    "$([int]($span.TotalDays / 30))mo ago"
}
function Get-Rows {
    $rows = @([pscustomobject]@{ Kind = 'new' })
    $n = [Math]::Min($script:sessShown, @($script:sessions).Count)
    for ($i = 0; $i -lt $n; $i++) { $rows += [pscustomobject]@{ Kind = 'session'; S = $script:sessions[$i] } }
    if (@($script:sessions).Count -gt $n) { $rows += [pscustomobject]@{ Kind = 'more'; Remaining = @($script:sessions).Count - $n } }
    $rows
}
function Get-SelectedRow {
    if (-not $script:sessOpen) { return $null }
    $rows = @(Get-Rows)
    if ($script:selPos -lt $rows.Count) { $rows[$script:selPos] } else { $null }
}
function Update-SessionMode {
    $row = Get-SelectedRow
    if ($row -and $row.Kind -eq 'session') {
        $projectRow.Opacity = 0.35
        Set-Hint $(if ($script:cfg.autoPaste) { "Continue this session - Enter pastes your text into it" } else { "Continue this session - your text is copied, then paste with Ctrl+V" }) '#8886EBD3'
    } else {
        $projectRow.Opacity = 1
        if ($row -and $row.Kind -eq 'more') { Set-Hint "Enter loads $([Math]::Min(5, $row.Remaining)) more" '#80FFFFFF' }
        elseif ($row) { Set-Hint 'New session in the selected project. Enter sends.' '#80FFFFFF' }
    }
}
function Show-Sessions {
    $sessionList.Children.Clear()
    $rows = @(Get-Rows); $selBorder = $null
    for ($i = 0; $i -lt $rows.Count; $i++) {
        $r = $rows[$i]; $sel = ($i -eq $script:selPos)
        $tb = New-Object System.Windows.Controls.TextBlock
        $tb.FontFamily = New-Object System.Windows.Media.FontFamily 'Segoe UI Variable Text, Segoe UI'
        $tb.FontSize = 12
        $tb.TextTrimming = 'CharacterEllipsis'
        $main = New-Object System.Windows.Documents.Run
        $dim  = New-Object System.Windows.Documents.Run
        $dim.FontSize = 10.5; $dim.Foreground = New-Brush '#80FFFFFF'
        if ($r.Kind -eq 'new')       { $main.Text = '+  New session' }
        elseif ($r.Kind -eq 'more')  { $main.Text = "Load more  ($($r.Remaining) left)" }
        else {
            $main.Text = $r.S.Title
            $dim.Text  = "    $($r.S.Project)  -  $(Format-Ago $r.S.Last)"
        }
        [void]$tb.Inlines.Add($main); [void]$tb.Inlines.Add($dim)
        $b = New-Object System.Windows.Controls.Border
        $b.Child = $tb
        $b.CornerRadius = New-Object System.Windows.CornerRadius 8
        $b.Padding = New-Object System.Windows.Thickness 10, 4, 10, 4
        $b.Margin  = New-Object System.Windows.Thickness 0, 0, 0, 3
        $b.Cursor  = [System.Windows.Input.Cursors]::Hand
        $b.Tag = $i
        $b.Background = New-Brush $(if ($sel) { '#3386EBD3' } else { '#12FFFFFF' })
        $main.Foreground = New-Brush $(if ($sel) { '#FFEFFFFA' } else { '#D0FFFFFF' })
        $b.Add_MouseLeftButtonUp({
            param($s, $e)
            $script:selPos = [int]$s.Tag
            $row = Get-SelectedRow
            if ($row -and $row.Kind -eq 'more') { $script:sessShown += 5 }
            Show-Sessions; [void]$input_.Focus()
        })
        [void]$sessionList.Children.Add($b)
        if ($sel) { $selBorder = $b }
    }
    if ($selBorder) { $selBorder.BringIntoView() }
    Update-SessionMode
}
function Open-Sessions {
    if ($null -eq $script:sessions) { $script:sessions = @(Get-Sessions) }
    $script:sessOpen = $true
    Log "sessions opened: $(@($script:sessions).Count) found"
    $sessScroll.Visibility = 'Visible'
    $script:selPos = $(if (@($script:sessions).Count -gt 0) { 1 } else { 0 })
    Show-Sessions
}
function Close-Sessions {
    $script:sessOpen = $false; $script:selPos = 0
    $sessScroll.Visibility = 'Collapsed'
    $projectRow.Opacity = 1
}
function Move-Session($d) {
    if (-not $script:sessOpen) { if ($d -gt 0) { Open-Sessions }; return }
    $rows = @(Get-Rows)
    $p = $script:selPos + $d
    if ($p -lt 0) { Close-Sessions; Set-Hint 'New session in the selected project. Enter sends.' '#80FFFFFF'; return }
    if ($p -ge $rows.Count) { $p = $rows.Count - 1 }
    $script:selPos = $p
    Show-Sessions
}
# ---------- stay open until the message is really sent in Claude ----------
function Get-SessionStamps {
    $stamps = @{}
    $root = Join-Path $env:APPDATA 'Claude\claude-code-sessions'
    if (Test-Path $root) {
        Get-ChildItem $root -Recurse -File -Filter 'local_*.json' -ErrorAction SilentlyContinue | ForEach-Object { $stamps[$_.FullName] = $_.LastWriteTimeUtc.Ticks }
    }
    $stamps
}
. (Join-Path $root 'bubble-ui.ps1')
. (Join-Path $root 'commands.ps1')

function Send-WinH {
    [VcNative]::keybd_event(0x5B, 0, 0, [UIntPtr]::Zero)
    [VcNative]::keybd_event(0x48, 0, 0, [UIntPtr]::Zero)
    [VcNative]::keybd_event(0x48, 0, 2, [UIntPtr]::Zero)
    [VcNative]::keybd_event(0x5B, 0, 2, [UIntPtr]::Zero)
}
function Test-ModifiersUp($vk) {
    foreach ($k in @(0x10, 0x11, 0x12, 0x5B, 0x5C, $vk)) {
        if (([VcNative]::GetAsyncKeyState($k) -band 0x8000) -ne 0) { return $false }
    }
    $true
}

function Show-Island {
    if ($script:visible) { return }
    $script:cfg = Get-Config
    if ($Preview) { $script:cfg.startDictation = $false; $script:cfg.permSound = $false }
    $script:visible = $true; $script:sending = $false
    $input_.Text = ''; $placeholder.Visibility = 'Visible'
    Set-Mood $false
    Set-Wave $false
    Restore-LastProject
    Close-Sessions; $script:sessions = $null; $script:sessShown = 5
    $closeX.Visibility = 'Collapsed'
    Set-Hint 'Starting...' '#80FFFFFF'
    # Reply target: the bubble you clicked Reply on, else the session you last sent to.
    $target = $script:replyLocal; $script:replyLocal = $null
    if (-not $target -and $script:lastVoiceBubble -and -not $script:lastVoiceBubble.Closing) { $target = $script:lastVoiceBubble.LocalId }
    if ($target) { $script:activeSession = $target; Select-ActiveSession }

    $win.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
    $win.Opacity = 0
    $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper $win).Handle
    Move-ToCursorScreen
    $win.ShowActivated = $true; $win.Show(); $win.Activate()
    Place-Window
    [void][VcNative]::SetForegroundWindow($hwnd)
    [void]$input_.Focus()

    Pop-In
    Start-Pulse

    $script:dictTicks = 0
    $script:dictTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:dictTimer.Interval = [TimeSpan]::FromMilliseconds(80)
    $script:dictTimer.Add_Tick({
        $script:dictTicks++
        $vk = $script:hk.Vk
        if ($script:dictTicks -lt 4) { return }
        if ((Test-ModifiersUp $vk) -or $script:dictTicks -gt 30) {
            $script:dictTimer.Stop()
            if (-not $script:visible) { return }
            [void]$input_.Focus()
            if ($script:cfg.startDictation) {
                Send-WinH; $script:dictOn = $true; Set-Wave $true
                if ($script:sessOpen) { Update-SessionMode }
                else { Set-Hint 'Listening - start with a project name, or press Down for sessions. Enter sends.' '#8886EBD3' }
            } else {
                if ($script:sessOpen) { Update-SessionMode }
                else { Set-Hint 'Type your message - start with a project name, or press Down for sessions. Enter sends.' '#80FFFFFF' }
            }
        }
    })
    $script:dictTimer.Start()
}

function Hide-Island {
    if (-not $script:visible) { return }
    if ($script:dictTimer) { $script:dictTimer.Stop() }
    if ($script:pillHideTimer) { $script:pillHideTimer.Stop() }
    Stop-Dictation
    $closeX.Visibility = 'Collapsed'
    $f = New-Anim 1 0 160
    $f.Add_Completed({ $win.Hide(); $script:visible = $false; Stop-Pulse })
    $win.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $f)
}
function Schedule-PillHide($ms) {
    if ($script:pillHideTimer) { $script:pillHideTimer.Stop() }
    $script:pillHideTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:pillHideTimer.Interval = [TimeSpan]::FromMilliseconds($ms)
    $script:pillHideTimer.Add_Tick({ $script:pillHideTimer.Stop(); Hide-Island })
    $script:pillHideTimer.Start()
}

function Get-ForegroundProcessName {
    $h = [VcNative]::GetForegroundWindow()
    if ($h -eq [IntPtr]::Zero) { return '' }
    [uint32]$procId = 0
    [void][VcNative]::GetWindowThreadProcessId($h, [ref]$procId)
    try { (Get-Process -Id $procId -ErrorAction Stop).ProcessName } catch { '' }
}
function Send-CtrlV {
    [VcNative]::keybd_event(0x11, 0, 0, [UIntPtr]::Zero)
    [VcNative]::keybd_event(0x56, 0, 0, [UIntPtr]::Zero)
    [VcNative]::keybd_event(0x56, 0, 2, [UIntPtr]::Zero)
    [VcNative]::keybd_event(0x11, 0, 2, [UIntPtr]::Zero)
}
function Submit-ToSession($sess, $text) {
    $cv = Convert-SpokenCommand $text $null
    if ($cv) { $text = $cv.Text; Log "slash: $($cv.Command) known=$($cv.Known)" }
    $prev = $null
    if ($text) {
        try { if ([System.Windows.Clipboard]::ContainsText()) { $prev = [System.Windows.Clipboard]::GetText() } } catch {}
        $copied = $false
        for ($i = 0; $i -lt 5 -and -not $copied; $i++) {
            try { [System.Windows.Clipboard]::SetText($text); $copied = $true } catch { Start-Sleep -Milliseconds 60 }
        }
        if (-not $copied) { Show-Error 'Could not copy your text to the clipboard.'; return }
    }
    Stop-Dictation
    $url = 'claude://code/continue?session=' + [uri]::EscapeDataString($sess.Id)
    if ($DryRun) { Log "DRYRUN $url (clipboard $($text.Length) chars)" }
    else {
        try { Start-Process $url -ErrorAction Stop }
        catch { Show-Error "Could not open the session: $($_.Exception.Message)"; return }
        Log "continue $($sess.Id) clipboard=$($text.Length)"
    }
    $cli = Get-CliId $sess.Id
    $bub = Find-Bubble $cli
    if (-not $bub) {
        $bub = New-Bubble $cli $sess.Id $sess.Project $sess.Title $null $false
        Show-Bubble $bub
    }
    $bub.LocalId = $sess.Id; $bub.Title = [string]$sess.Title; $bub.Waiting = [bool]$text; $bub.WaitStart = Get-Date; $bub.Last = Get-Date
    $script:lastVoiceBubble = $bub
    $auto = ($text -and -not $DryRun -and $script:cfg.autoPaste)
    if ($auto) { Start-AutoSend $text $bub $true $prev }
    Set-BubbleNote $bub $(if (-not $text) { 'Session opened' } elseif ($auto -and $script:cfg.autoSend) { 'Sending it to Claude...' } elseif ($auto) { 'Opening - I will paste your text when it is ready' } else { 'Opened - your text is copied: press Ctrl+V, then Enter' }) 40
    $script:sending = $true
    Stop-Pulse; Set-Mood $true; Jump
    Set-Hint 'Sent - the bubble follows this session' '#8886EBD3'
    Schedule-PillHide 900
}

function Submit-Island {
    if (-not $script:visible -or $script:sending) { return }
    $row = Get-SelectedRow
    if ($row -and $row.Kind -eq 'more') { $script:sessShown += 5; Show-Sessions; return }
    $text = ($input_.Text -replace '\s+', ' ').Trim()
    if ($row -and $row.Kind -eq 'session') { Submit-ToSession $row.S $text; return }
    if (-not $text) { Hide-Island; return }
    $m = Find-ProjectPrefix $text
    if ($m -and $m.Index -eq $script:projIdx) {
        $text = $text.Substring($m.Length).Trim()
        if (-not $text) {
            $input_.Text = ''
            Set-Hint "Project set to $($script:projects[$script:projIdx].Name) - now say what to do" '#8886EBD3'
            return
        }
    }
    if ($text.Length -gt 13000) { $text = $text.Substring(0, 13000) }
    $proj   = $script:projects[$script:projIdx]
    $folder = $proj.Folder
    $cv = Convert-SpokenCommand $text $folder
    if ($cv) { $text = $cv.Text; Log "slash: $($cv.Command) known=$($cv.Known)" }
    if (-not (Test-Path -LiteralPath $folder -PathType Container)) {
        Show-Error "Folder not found for '$($proj.Name)': $folder (edit config.json)"; return
    }
    Save-LastProject
    Stop-Dictation
    $url = 'claude://code/new?q=' + [uri]::EscapeDataString($text) + '&folder=' + [uri]::EscapeDataString($folder)
    if ($DryRun) {
        Log "DRYRUN $url"
    } else {
        try { Start-Process $url -ErrorAction Stop }
        catch { Show-Error "Could not open Claude: $($_.Exception.Message)"; return }
        Log "sent $($text.Length) chars"
    }
    $bub = New-Bubble $null $null $proj.Name '' $folder $false
    Show-Bubble $bub
    $script:lastVoiceBubble = $bub
    if (-not $DryRun -and $script:cfg.autoSend) {
        Start-AutoSend $text $bub $false $null
        Set-BubbleNote $bub 'Sending it to Claude...' 60
    } else { Set-BubbleNote $bub 'Opened in Claude - confirm the folder, then press Enter there.' 120 }
    $script:sending = $true
    Stop-Pulse; Set-Mood $true; Jump
    Set-Hint 'Opened in Claude - a bubble now follows this session' '#8886EBD3'
    Schedule-PillHide 1100
}

$closeX.Add_MouseLeftButtonUp({ Hide-Island })
$input_.Add_TextChanged({
    $placeholder.Visibility = $(if ($input_.Text.Length -gt 0) { 'Collapsed' } else { 'Visible' })
    if ($script:visible -and -not $script:sending) {
        Wiggle
        $m = Find-ProjectPrefix $input_.Text
        if ($m -and $m.Index -ne $script:projIdx) { Set-Project $m.Index }
        $body = $input_.Text; if ($m) { $body = $body.Substring([math]::Min($body.Length, $m.Length)) }
        $cv = Convert-SpokenCommand $body $script:projects[$script:projIdx].Folder
        if ($cv -and $cv.Command) {
            Set-Hint ('Sends:  ' + (Cut-Text $cv.Text 80) + $(if ($cv.Known) { '' } else { '   (not a command I know)' })) $(if ($cv.Known) { '#FFA6F7E1' } else { '#FFF6C453' })
            $script:cmdHint = $true
        } elseif ($script:cmdHint) {
            $script:cmdHint = $false
            if ($script:sessOpen) { Update-SessionMode } else { Set-Hint 'Start with a project name, or say "slash" for a command. Enter sends.' '#80FFFFFF' }
        }
    }
})
$win.Add_PreviewKeyDown({
    param($s, $e)
    if ($e.Key -eq 'Return') {
        if (([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Shift) -eq 0) {
            $e.Handled = $true; Submit-Island
        }
    } elseif ($e.Key -eq 'Escape') { $e.Handled = $true; Hide-Island }
    elseif ($e.Key -eq 'Down') { $e.Handled = $true; Move-Session 1 }
    elseif ($e.Key -eq 'Up')   { $e.Handled = $true; Move-Session -1 }
    elseif ($e.Key -eq 'Tab') {
        $e.Handled = $true
        if (([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Shift) -ne 0) { Step-Project -1 } else { Step-Project 1 }
    }
    elseif (([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control) -ne 0 -and "$($e.Key)" -match '^D([1-9])$') {
        $e.Handled = $true
        $idx = [int]$Matches[1] - 1
        if ($idx -lt $script:projects.Count) { Set-Project $idx }
    }
})

Load-Dock
# ---------- preview mode: render every state with sample data and save screenshots ----------
if ($Preview) {
    $null = (New-Object System.Windows.Interop.WindowInteropHelper $win).EnsureHandle()
    $script:cfg = Get-Config; $script:cfg.startDictation = $false; $script:cfg.permSound = $false
    $script:hk = ConvertTo-Hotkey 'Ctrl+Alt+V'
    function Snap($name) {
        $list = @()
        if ($win.IsVisible) { $list += ,@('pill', $win) }
        foreach ($bb in $script:bubbles) { if ($bb.Win.IsVisible) { $list += ,@("b$($bb.Id)", $bb.Win) } }
        foreach ($pair in $list) {
            $hw = (New-Object System.Windows.Interop.WindowInteropHelper $pair[1]).Handle
            $rc = New-Object VcNative+RECT
            [void][VcNative]::GetWindowRect($hw, [ref]$rc)
            $w = $rc.Right - $rc.Left; $h = $rc.Bottom - $rc.Top
            Add-Content (Join-Path $PreviewDir 'rects.txt') ("{0}-{1}: rect={2},{3} {4}x{5}" -f $name, $pair[0], $rc.Left, $rc.Top, $w, $h)
            $bmp = New-Object System.Drawing.Bitmap $w, $h
            $g = [System.Drawing.Graphics]::FromImage($bmp)
            $g.CopyFromScreen($rc.Left, $rc.Top, 0, 0, (New-Object System.Drawing.Size $w, $h))
            $bmp.Save((Join-Path $PreviewDir "$name-$($pair[0]).png")); $g.Dispose(); $bmp.Dispose()
        }
    }
    function Fake($name, $obj) { Handle-HookEvent ([pscustomobject]@{ Name = $name; Raw = ($obj | ConvertTo-Json -Compress -Depth 6) }) }
    $cwdA = 'C:\Projects\Storefront'; $cwdB = 'C:\Projects\Bubbles'; $cwdC = 'C:\Projects\Notebook'
    $steps = @(
        @{ N = '1-listening'; Do = { Show-Island; $input_.Text = 'storefront fix the header spacing on mobile'; Set-Wave $true; Set-Hint 'Listening - start with a project name, or press Down for sessions. Enter sends.' '#8886EBD3' } },
        @{ N = '2-three-bubbles'; Do = {
            Hide-Island
            $script:pvA = New-Bubble 'pv-a' 'local_a' 'Storefront' 'Fix the header spacing' $null $false; Show-Bubble $script:pvA
            $script:pvB = New-Bubble 'pv-b' 'local_b' 'Bubbles' 'Install size' $null $false; Show-Bubble $script:pvB
            $script:pvC = New-Bubble $null $null 'Notebook' '' $cwdC $false; Show-Bubble $script:pvC
            Fake 'UserPromptSubmit' @{ session_id = 'pv-a'; cwd = $cwdA; prompt = 'fix the header spacing on mobile' }
            Fake 'PreToolUse' @{ session_id = 'pv-a'; cwd = $cwdA; tool_name = 'Edit'; tool_input = @{ file_path = "$cwdA\src\header.css" } }
            Fake 'UserPromptSubmit' @{ session_id = 'pv-b'; cwd = $cwdB; prompt = 'how big is the install' }
            Fake 'Stop' @{ session_id = 'pv-b'; cwd = $cwdB }
            $script:hookSessions['pv-b'].Reply = 'It installs at about 8.8 MB on Windows.'
            Update-Bubble $script:pvB } },
        @{ N = '3-peek-B'; Do = {
            $script:pvB.Hover = $true; $script:pvB.Peek = $true; Apply-BubbleView $script:pvB } },
        @{ N = '4-card-A'; Do = {
            $script:pvB.Hover = $false; $script:pvB.Peek = $false; Apply-BubbleView $script:pvB
            Fake 'PostToolUse' @{ session_id = 'pv-a'; cwd = $cwdA }
            Fake 'PreToolUse' @{ session_id = 'pv-a'; cwd = $cwdA; tool_name = 'Read'; tool_input = @{ file_path = "$cwdA\src\layout.tsx" } }
            Fake 'PostToolUse' @{ session_id = 'pv-a'; cwd = $cwdA }
            Fake 'PreToolUse' @{ session_id = 'pv-a'; cwd = $cwdA; tool_name = 'WebSearch'; tool_input = @{ query = 'css safe-area-inset mobile header' } }
            Fake 'PostToolUse' @{ session_id = 'pv-a'; cwd = $cwdA }
            Fake 'PreToolUse' @{ session_id = 'pv-a'; cwd = $cwdA; tool_name = 'Bash'; tool_input = @{ command = 'npm run build && npm test -- --watch=false' } }
            $script:pvA.CardOpen = $true; $script:pvA.LogOpen = $true; Apply-BubbleView $script:pvA } },
        @{ N = '5-alert-on-B'; Do = {
            Fake 'PermissionRequest' @{ session_id = 'pv-b'; cwd = $cwdB; tool_name = 'Bash'; tool_input = @{ command = 'npm install --save-dev vitest' } } } },
        @{ N = '6-A-celebrates'; Wait = 260; Do = {
            $script:pvA.CardOpen = $false; Apply-BubbleView $script:pvA
            Fake 'Stop' @{ session_id = 'pv-a'; cwd = $cwdA } } },
        @{ N = '7-C-jelly-drag'; Wait = 70; Do = {
            $script:pvC.Dragging = $true; $script:pvC.Orb.Dragging = $true; $script:pvC.Orb.Vx = 2.6; $script:pvC.Orb.Vy = -0.9; Update-Bubble $script:pvC } },
        @{ N = '8-C-snapped'; Do = {
            $script:pvC.Dragging = $false; $script:pvC.Orb.Dragging = $false; Update-Bubble $script:pvC
            $hw = (New-Object System.Windows.Interop.WindowInteropHelper $script:pvC.Win).Handle
            $wa = $script:pvC.Work
            [void][VcNative]::SetWindowPos($hw, [IntPtr]::Zero, [int]($wa.Left + $wa.Width * 0.3), [int]($wa.Top + $wa.Height * 0.45), 0, 0, 0x0015)
            Snap-Bubble $script:pvC } },
        @{ N = '9-resolved-and-asleep'; Do = {
            Fake 'PostToolUse' @{ session_id = 'pv-b'; cwd = $cwdB }
            Fake 'Stop' @{ session_id = 'pv-b'; cwd = $cwdB }
            $script:pvB.CardOpen = $false; $script:pvB.AutoOpened = $false; Apply-BubbleView $script:pvB
            $script:pvC.Waiting = $false; $script:pvC.Note = ''; $script:pvC.Last = (Get-Date).AddMinutes(-9); Update-Bubble $script:pvC } },
        @{ N = '7-tray-menu'; Do = {
            $m = New-Object System.Windows.Forms.ContextMenuStrip
            Build-TrayMenu $m
            $lines = foreach ($it in $m.Items) { $it.Text; foreach ($d in @($it.DropDownItems)) { '    ' + $d.Text } }
            Set-Content (Join-Path $PreviewDir 'tray.txt') $lines } }
    )
    $script:placeY = 430
    $script:pi = -1
    $script:ptimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:ptimer.Interval = [TimeSpan]::FromMilliseconds(1700)
    $script:ptimer.Add_Tick({
        try {
            if ($script:pi -ge 0) { Snap $steps[$script:pi].N }
            $script:pi++
            if ($script:pi -ge $steps.Count) { $script:ptimer.Stop(); $app.Shutdown(); return }
            & $steps[$script:pi].Do
            if ($win.IsVisible) { Place-Window }
            $script:ptimer.Interval = [TimeSpan]::FromMilliseconds($(if ($steps[$script:pi].Wait) { $steps[$script:pi].Wait } else { 1700 }))
        } catch { Set-Content (Join-Path $PreviewDir 'error.txt') "$_`n$($_.ScriptStackTrace)"; $script:ptimer.Stop(); $app.Shutdown() }
    })
    $app = New-Object System.Windows.Application
    $app.ShutdownMode = 'OnExplicitShutdown'
    $script:ptimer.Start()
    [void]$app.Run()
    exit 0
}
# ---------- hotkey ----------
$script:hk = ConvertTo-Hotkey ([string]$script:cfg.hotkey)
$hwnd = (New-Object System.Windows.Interop.WindowInteropHelper $win).EnsureHandle()
$src  = [System.Windows.Interop.HwndSource]::FromHwnd($hwnd)
$script:sink = New-Object VcHotkeySink
$script:sink.Fired = [Action[int]]{ param($hid) try { if ($script:visible) { Submit-Island } else { Show-Island } } catch { Log "hotkey handler: $_" } }
$src.AddHook($script:sink.Hook)
if (-not [VcNative]::RegisterHotKey($hwnd, 1, $script:hk.Mod, $script:hk.Vk)) {
    [void][System.Windows.MessageBox]::Show("Could not register hotkey '$($script:cfg.hotkey)'. Another app is using it.`nEdit config.json and restart.", 'Bubbles')
    exit 1
}

# ---------- tray ----------
$bmp = New-Object System.Drawing.Bitmap 32, 32
$g = [System.Drawing.Graphics]::FromImage($bmp); $g.SmoothingMode = 'AntiAlias'
$orbRect = New-Object System.Drawing.Rectangle 2, 3, 28, 27
$g.FillEllipse((New-Object System.Drawing.Drawing2D.LinearGradientBrush $orbRect, ([System.Drawing.Color]::FromArgb(166, 247, 225)), ([System.Drawing.Color]::FromArgb(28, 140, 116)), 90.0), $orbRect)
$g.FillEllipse((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(150, 255, 255, 255))), 7, 6, 10, 5)
$eyeBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(26, 26, 44))
$g.FillEllipse($eyeBrush, 10, 12, 4, 7); $g.FillEllipse($eyeBrush, 18, 12, 4, 7); $g.Dispose()
$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
$tray.Text = "Bubbles ($($script:cfg.hotkey))"
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$menu.Add_Opening({ Build-TrayMenu $menu })
$tray.ContextMenuStrip = $menu
$tray.Add_MouseClick({ param($s, $e) if ($e.Button -eq 'Left') { Show-Island } })
$tray.Visible = $true

$sidStr = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
if (Test-Path "\\.\pipe\bubbles-$sidStr") {
    Log 'hook pipe is already served by another program - live status is off'
    $tray.ShowBalloonTip(6000, 'Bubbles', 'Another program is using the Bubbles hook pipe (is Bubbles already running?), so live status is off.', 'Warning')
} else {
    $script:server = New-Object VcPipeServer $sidStr
    $script:server.Start()
    Log "listening for hook events on $($script:server.PipeName)"
}
foreach ($k in (Get-SessionStamps).Keys) { $script:seenFiles[$k] = $true }
Restore-Bubbles
$hookTimer = New-Object System.Windows.Threading.DispatcherTimer
$hookTimer.Interval = [TimeSpan]::FromMilliseconds(100)
$hookTimer.Add_Tick({
    if (-not $script:server) { return }
    $ev = $null; $n = 0
    while ($n -lt 50 -and $script:server.Queue.TryDequeue([ref]$ev)) { $n++; try { Handle-HookEvent $ev } catch { Log "hook event error: $_" } }
})
$hookTimer.Start()
$statusTimer = New-Object System.Windows.Threading.DispatcherTimer
$statusTimer.Interval = [TimeSpan]::FromSeconds(1)
$statusTimer.Add_Tick({ try { Tick-Bubbles } catch { Log "status tick: $_" } })
$statusTimer.Start()

Log "started; hotkey=$($script:cfg.hotkey) folder=$($script:cfg.folder) dryrun=$DryRun"
$app = New-Object System.Windows.Application
$app.ShutdownMode = 'OnExplicitShutdown'
$app.Add_DispatcherUnhandledException({ param($s, $e) Log "ui error: $($e.Exception.Message)"; $e.Handled = $true })
[void]$app.Run()

