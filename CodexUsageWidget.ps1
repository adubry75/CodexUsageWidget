param([switch]$SelfTest)
# CodexUsageWidget.ps1
# Always-on-top desktop widget for Codex 5-hour + weekly limit usage.
# Data: documented Codex app-server account/rateLimits/read RPC.
# Read-only account query. Uses existing Codex CLI sign-in; no model turns.
#
# Run:  double-click "Start Codex Usage Widget.vbs"
#
# Drag to move.  Double-click body = refresh now.  Right-click = menu.
# Tray icon: double-click to show/hide, right-click for menu.
#
# Troubleshooting: %LOCALAPPDATA%\CodexUsageWidget.log  (right-click -> Open log)
#
# THEMING NOTE (this cost three broken builds, do not undo it):
# Brushes are assigned DIRECTLY to element properties, never through
# $win.Resources['Key'] + {DynamicResource}. A PowerShell function's return value
# enters an untyped IDictionary still wrapped in a PSObject; property setters
# unwrap it, dictionaries do not. WPF then throws InvalidCastException
# (PSObject -> Brush) on every single resource lookup, forever.
#
# ASCII-only on purpose: Windows PowerShell 5.1 reads .ps1 as ANSI without a BOM.

$ErrorActionPreference = 'Stop'

$script:LogPath   = Join-Path $PSScriptRoot 'CodexUsageWidget.log'
$script:LogCounts = @{}
$script:LogMax    = 25     # per distinct message, per run - stops runaway logs

function Write-Log([string]$msg) {
    try {
        $key = $msg -replace '[0-9]+', 'N'
        $n = [int]$script:LogCounts[$key]
        $script:LogCounts[$key] = $n + 1
        if ($n -ge $script:LogMax) {
            if ($n -eq $script:LogMax) {
                Add-Content -LiteralPath $script:LogPath -Encoding UTF8 `
                    -Value ('{0}  [further identical messages suppressed] {1}' -f
                            (Get-Date).ToString('HH:mm:ss.fff'), $key)
            }
            return
        }
        Add-Content -LiteralPath $script:LogPath -Encoding UTF8 `
            -Value ('{0}  {1}' -f (Get-Date).ToString('HH:mm:ss.fff'), $msg)
    } catch { }
}

function Die([string]$where, $err) {
    $detail = if ($err -is [System.Management.Automation.ErrorRecord]) {
        "$($err.Exception.GetType().Name): $($err.Exception.Message)`r`n" +
        "at line $($err.InvocationInfo.ScriptLineNumber): $($err.InvocationInfo.Line.Trim())"
    } else { "$err" }
    Write-Log "FATAL [$where] $detail"
    try {
        Add-Type -AssemblyName System.Windows.Forms -EA SilentlyContinue
        [System.Windows.Forms.MessageBox]::Show(
            "Codex Usage Widget failed in: $where`r`n`r`n$detail`r`n`r`nLog:`r`n$script:LogPath",
            'Codex Usage Widget', 'OK', 'Error') | Out-Null
    } catch { }
    exit 1
}

try {
    if ((Test-Path $script:LogPath) -and (Get-Item $script:LogPath).Length -gt 200kb) {
        Remove-Item $script:LogPath -Force -EA SilentlyContinue
    }
} catch { }
Write-Log '--- start ---'

try {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase,
                           System.Windows.Forms, System.Drawing
    Add-Type @"
using System;
using System.Runtime.InteropServices;
public class W32 {
    [DllImport("user32.dll", SetLastError=true)]
    public static extern bool DestroyIcon(IntPtr handle);
}
"@
} catch { Die 'assembly load' $_ }

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$script:CfgPath   = Join-Path $PSScriptRoot 'CodexUsageWidget.json'
$script:ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:RunKey    = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$script:RunName   = 'CodexUsageWidget'

$script:Cfg = [ordered]@{
    Left = $null; Top = $null
    Interval = 1; Opacity = 0.96; Compact = $false; Topmost = $true
    AlertAt = 85; Skin = 'Clay'
}
$script:Buckets   = @{}
$script:LastAlert = @{}
$script:TrayIcon  = $null
$script:Busy      = $false

# ---------------------------------------------------------------- skins

$script:Skins = [ordered]@{
    'Clay' = @{
        BgA='#FF2A2D36'; BgB='#FF121318'; Border='#FF3F4553'; Shadow=0.55; Gloss='#24FFFFFF'
        Accent='#FFE08A64'; Dot='#FFC96442'
        Label='#FF9BA3B1'; Sub='#FF6E7684'; Val='#FFF6F7F9'; Track='#FF2E3440'
        Ok=@('#FF6EE7B7','#FF34D399'); Warn=@('#FFFCD34D','#FFF59E0B'); Crit=@('#FFFCA5A5','#FFEF4444')
    }
    'Midnight' = @{
        BgA='#FF223054'; BgB='#FF080D1B'; Border='#FF32436F'; Shadow=0.60; Gloss='#26FFFFFF'
        Accent='#FF7DD3FC'; Dot='#FF38BDF8'
        Label='#FF97A9CC'; Sub='#FF61719A'; Val='#FFEDF4FF'; Track='#FF24334F'
        Ok=@('#FF67E8F9','#FF22D3EE'); Warn=@('#FFFDE68A','#FFFBBF24'); Crit=@('#FFFDA4AF','#FFF43F5E')
    }
    'Synthwave' = @{
        BgA='#FF3A1578'; BgB='#FF0F0226'; Border='#FF8B46F0'; Shadow=0.65; Gloss='#30FFFFFF'
        Accent='#FFFF7AD9'; Dot='#FFF472B6'
        Label='#FFC9B6FF'; Sub='#FF8E7AD0'; Val='#FFFFF0FC'; Track='#FF3E1F7A'
        Ok=@('#FF67E8F9','#FFA855F7'); Warn=@('#FFFDE047','#FFFB7185'); Crit=@('#FFFFA0A0','#FFFF2D95')
    }
    'Nord' = @{
        BgA='#FF4A5467'; BgB='#FF272B34'; Border='#FF5E6B86'; Shadow=0.50; Gloss='#1EFFFFFF'
        Accent='#FF88C0D0'; Dot='#FF81A1C1'
        Label='#FFD8DEE9'; Sub='#FF97A5B9'; Val='#FFECEFF4'; Track='#FF3B4252'
        Ok=@('#FFA3BE8C','#FF8FBCBB'); Warn=@('#FFEBCB8B','#FFD08770'); Crit=@('#FFD08C94','#FFBF616A')
    }
    'Terminal' = @{
        BgA='#FF141A15'; BgB='#FF020402'; Border='#FF2A552F'; Shadow=0.70; Gloss='#1E7CFF9B'
        Accent='#FF4ADE80'; Dot='#FF22C55E'
        Label='#FF84C795'; Sub='#FF4E7F5B'; Val='#FFDCFFE4'; Track='#FF16281B'
        Ok=@('#FF86EFAC','#FF22C55E'); Warn=@('#FFFDE047','#FFEAB308'); Crit=@('#FFFCA5A5','#FFDC2626')
    }
    'Paper' = @{
        BgA='#FFFFFFFF'; BgB='#FFE8EBEF'; Border='#FFCFD4DC'; Shadow=0.28; Gloss='#00FFFFFF'
        Accent='#FFB4542F'; Dot='#FFC96442'
        Label='#FF4B5563'; Sub='#FF8A919C'; Val='#FF0F1116'; Track='#FFDCE1E8'
        Ok=@('#FF34D399','#FF059669'); Warn=@('#FFFBBF24','#FFD97706'); Crit=@('#FFF87171','#FFDC2626')
    }
}

function New-Color([string]$hex) {
    [Windows.Media.ColorConverter]::ConvertFromString($hex)
}

function New-Brush([string]$hex) {
    $b = New-Object Windows.Media.SolidColorBrush
    $b.Color = [Windows.Media.Color](New-Color $hex)
    $b.Freeze()
    $b
}

# ---------------------------------------------------------------- UI
# Every themed element is x:Named and painted in code. No DynamicResource.

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Codex Usage" Width="278" SizeToContent="Height"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" ResizeMode="NoResize"
        WindowStartupLocation="Manual">
  <!-- Margin gives the drop shadow room to render. Do not remove. -->
  <Border x:Name="Root" CornerRadius="13" BorderThickness="1" Margin="15,14,15,16"
          Padding="14,12,14,13" Background="#FF2A2D36" BorderBrush="#FF3F4553">
    <Grid>
      <Border x:Name="Gloss" Height="1" VerticalAlignment="Top" Margin="-13,-11,-13,0"
              Background="#24FFFFFF" CornerRadius="13,13,0,0"/>

      <StackPanel>
        <Grid Margin="0,0,0,11">
          <StackPanel Orientation="Horizontal">
            <Ellipse x:Name="Dot" Width="7" Height="7" Margin="0,0,7,0"
                     VerticalAlignment="Center" Fill="#FFC96442"/>
            <TextBlock x:Name="Title" Text="CODEX USAGE" FontFamily="Segoe UI" FontSize="9.5"
                       FontWeight="Bold" VerticalAlignment="Center" Foreground="#FFE08A64"/>
          </StackPanel>
          <TextBlock x:Name="Stamp" HorizontalAlignment="Right" FontFamily="Segoe UI"
                     FontSize="9.5" VerticalAlignment="Center" Foreground="#FF6E7684" Text="--:--"/>
        </Grid>

        <Grid Margin="0,0,0,5">
          <TextBlock x:Name="LblFh" Text="Session" FontFamily="Segoe UI" FontSize="11"
                     VerticalAlignment="Bottom" Foreground="#FF9BA3B1"/>
          <TextBlock x:Name="FhPct" HorizontalAlignment="Right" FontFamily="Segoe UI"
                     FontSize="15" FontWeight="SemiBold" Foreground="#FFF6F7F9" Text="--"/>
        </Grid>
        <Border x:Name="FhTrack" Height="8" CornerRadius="4" Background="#FF2E3440">
          <Border x:Name="FhBar" HorizontalAlignment="Left" Width="0" CornerRadius="4"/>
        </Border>
        <TextBlock x:Name="FhReset" FontFamily="Segoe UI" FontSize="9.5"
                   Foreground="#FF6E7684" Margin="0,4,0,0" Text=""/>

        <Grid Margin="0,13,0,5">
          <TextBlock x:Name="LblWk" Text="Weekly" FontFamily="Segoe UI" FontSize="11"
                     VerticalAlignment="Bottom" Foreground="#FF9BA3B1"/>
          <TextBlock x:Name="WkPct" HorizontalAlignment="Right" FontFamily="Segoe UI"
                     FontSize="15" FontWeight="SemiBold" Foreground="#FFF6F7F9" Text="--"/>
        </Grid>
        <Border x:Name="WkTrack" Height="8" CornerRadius="4" Background="#FF2E3440">
          <Border x:Name="WkBar" HorizontalAlignment="Left" Width="0" CornerRadius="4"/>
        </Border>
        <TextBlock x:Name="WkReset" FontFamily="Segoe UI" FontSize="9.5"
                   Foreground="#FF6E7684" Margin="0,4,0,0" Text=""/>

        <StackPanel x:Name="Detail">
          <StackPanel x:Name="OpusRow" Visibility="Collapsed" Margin="0,13,0,0">
            <Grid Margin="0,0,0,4">
              <TextBlock x:Name="LblOp" Text="Weekly - Opus" FontFamily="Segoe UI" FontSize="10"
                         Foreground="#FF9BA3B1"/>
              <TextBlock x:Name="OpPct" HorizontalAlignment="Right" FontFamily="Segoe UI"
                         FontSize="11.5" FontWeight="SemiBold" Foreground="#FFF6F7F9" Text="--"/>
            </Grid>
            <Border x:Name="OpTrack" Height="5" CornerRadius="3" Background="#FF2E3440">
              <Border x:Name="OpBar" HorizontalAlignment="Left" Width="0" CornerRadius="3"/>
            </Border>
          </StackPanel>

          <StackPanel x:Name="SonRow" Visibility="Collapsed" Margin="0,10,0,0">
            <Grid Margin="0,0,0,4">
              <TextBlock x:Name="LblSo" Text="Weekly - Sonnet" FontFamily="Segoe UI" FontSize="10"
                         Foreground="#FF9BA3B1"/>
              <TextBlock x:Name="SoPct" HorizontalAlignment="Right" FontFamily="Segoe UI"
                         FontSize="11.5" FontWeight="SemiBold" Foreground="#FFF6F7F9" Text="--"/>
            </Grid>
            <Border x:Name="SoTrack" Height="5" CornerRadius="3" Background="#FF2E3440">
              <Border x:Name="SoBar" HorizontalAlignment="Left" Width="0" CornerRadius="3"/>
            </Border>
          </StackPanel>

          <Grid x:Name="ExtraRow" Visibility="Collapsed" Margin="0,13,0,0">
            <TextBlock x:Name="LblEx" Text="Extra credits" FontFamily="Segoe UI" FontSize="10"
                       Foreground="#FF9BA3B1"/>
            <TextBlock x:Name="ExTxt" HorizontalAlignment="Right" FontFamily="Segoe UI"
                       FontSize="10" Foreground="#FF9BA3B1" Text=""/>
          </Grid>
        </StackPanel>

        <TextBlock x:Name="Err" Visibility="Collapsed" FontFamily="Segoe UI" FontSize="10"
                   TextWrapping="Wrap" Margin="0,11,0,0" Foreground="#FFEF4444" Text=""/>
      </StackPanel>
    </Grid>
  </Border>
</Window>
'@

try {
    $reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
    $win    = [Windows.Markup.XamlReader]::Load($reader)
    Write-Log 'xaml loaded'
} catch { Die 'XAML load' $_ }

$ui = @{}
try {
    'Root','Gloss','Dot','Title','Stamp',
    'LblFh','FhPct','FhTrack','FhBar','FhReset',
    'LblWk','WkPct','WkTrack','WkBar','WkReset',
    'Detail','OpusRow','LblOp','OpPct','OpTrack','OpBar',
    'SonRow','LblSo','SoPct','SoTrack','SoBar',
    'ExtraRow','LblEx','ExTxt','Err' |
        ForEach-Object {
            $el = $win.FindName($_)
            if ($null -eq $el) { throw "named element '$_' not found in XAML" }
            $ui[$_] = $el
        }
    Write-Log 'elements bound'
} catch { Die 'element binding' $_ }

# ---------------------------------------------------------------- config

function Test-Num($v) {
    if ($null -eq $v) { return $false }
    try { $d = [double]$v } catch { return $false }
    -not ([double]::IsNaN($d) -or [double]::IsInfinity($d))
}

function Load-Cfg {
    if (-not (Test-Path $script:CfgPath)) { Write-Log 'no config yet'; return }
    try {
        $j = Get-Content -LiteralPath $script:CfgPath -Raw | ConvertFrom-Json
        foreach ($k in @($script:Cfg.Keys)) { if ($null -ne $j.$k) { $script:Cfg[$k] = $j.$k } }
        if (-not (Test-Num $script:Cfg.Left) -or -not (Test-Num $script:Cfg.Top)) {
            Write-Log 'config position not numeric; ignoring'
            $script:Cfg.Left = $null; $script:Cfg.Top = $null
        }
        if (-not $script:Skins.Contains([string]$script:Cfg.Skin)) {
            Write-Log "unknown skin '$($script:Cfg.Skin)'; using Clay"
            $script:Cfg.Skin = 'Clay'
        }
        Write-Log "config loaded (skin=$($script:Cfg.Skin))"
    } catch { Write-Log "config load failed: $($_.Exception.Message)" }
}

function Save-Cfg {
    try {
        if ((Test-Num $win.Left) -and (Test-Num $win.Top)) {
            $script:Cfg.Left = [double]$win.Left
            $script:Cfg.Top  = [double]$win.Top
        }
        [pscustomobject]$script:Cfg | ConvertTo-Json |
            Set-Content -LiteralPath $script:CfgPath -Encoding UTF8
    } catch { Write-Log "config save failed: $($_.Exception.Message)" }
}

# ---------------------------------------------------------------- theming

function Get-Skin {
    $s = $script:Skins[[string]$script:Cfg.Skin]
    if (-not $s) { $s = $script:Skins['Clay'] }
    $s
}

function Apply-Skin {
    try {
        $s = Get-Skin

        $g = New-Object Windows.Media.LinearGradientBrush
        $g.StartPoint = New-Object Windows.Point 0, 0
        $g.EndPoint   = New-Object Windows.Point 0.6, 1
        $g.GradientStops.Add((New-Object Windows.Media.GradientStop (
            [Windows.Media.Color](New-Color $s.BgA), [double]0)))
        $g.GradientStops.Add((New-Object Windows.Media.GradientStop (
            [Windows.Media.Color](New-Color $s.BgB), [double]1)))
        $g.Freeze()

        $shadow = New-Object Windows.Media.Effects.DropShadowEffect
        $shadow.Color = [Windows.Media.Color](New-Color '#FF000000')
        $shadow.BlurRadius = 22; $shadow.ShadowDepth = 5; $shadow.Direction = 270
        $shadow.Opacity = [double]$s.Shadow

        $ui.Root.Background  = $g
        $ui.Root.BorderBrush = New-Brush $s.Border
        $ui.Root.Effect      = $shadow
        $ui.Gloss.Background = New-Brush $s.Gloss
        $ui.Dot.Fill         = New-Brush $s.Dot
        $ui.Title.Foreground = New-Brush $s.Accent
        $ui.Err.Foreground   = New-Brush ($s.Crit[1])

        foreach ($n in 'Stamp','FhReset','WkReset') { $ui[$n].Foreground = New-Brush $s.Sub }
        foreach ($n in 'LblFh','LblWk','LblOp','LblSo','LblEx','ExTxt') {
            $ui[$n].Foreground = New-Brush $s.Label
        }
        foreach ($n in 'FhPct','WkPct','OpPct','SoPct') { $ui[$n].Foreground = New-Brush $s.Val }
        foreach ($n in 'FhTrack','WkTrack','OpTrack','SoTrack') {
            $ui[$n].Background = New-Brush $s.Track
        }

        Repaint-Bars
        Write-Log "skin applied: $($script:Cfg.Skin)"
    } catch { Write-Log "APPLY-SKIN failed: $($_.Exception.Message)" }
}

# ---------------------------------------------------------------- data

function Get-Usage {
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = (Get-Command node.exe -ErrorAction Stop).Source
    $psi.Arguments = '"' + (Join-Path $PSScriptRoot 'usage-reader.cjs') + '"'
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $p = New-Object Diagnostics.Process; $p.StartInfo = $psi
    try {
        $null = $p.Start()
        $outTask = $p.StandardOutput.ReadToEndAsync()
        $errTask = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit(25000)) { $p.Kill(); throw 'Codex usage query timed out.' }
        if ($p.ExitCode -ne 0) { throw $errTask.Result.Trim() }
        $outTask.Result | ConvertFrom-Json
    } finally { $p.Dispose() }
}

function Get-Ramp([double]$p) {
    $s = Get-Skin
    if ($p -ge 85) { $s.Crit } elseif ($p -ge 60) { $s.Warn } else { $s.Ok }
}

function New-BarBrush($ramp) {
    $b = New-Object Windows.Media.LinearGradientBrush
    $b.StartPoint = New-Object Windows.Point 0, 0
    $b.EndPoint   = New-Object Windows.Point 1, 0
    $b.GradientStops.Add((New-Object Windows.Media.GradientStop (
        [Windows.Media.Color](New-Color $ramp[0]), [double]0)))
    $b.GradientStops.Add((New-Object Windows.Media.GradientStop (
        [Windows.Media.Color](New-Color $ramp[1]), [double]1)))
    $b.Freeze(); $b
}

# Track width is measured live; caching it at startup returned 0 and pinned
# every bar to the minimum sliver regardless of the real percentage.
function Paint-Bar($bar, $track, [double]$pct, [bool]$animate = $true) {
    try {
        $w = 0.0
        if ($track) { $w = [double]$track.ActualWidth }
        if (-not (Test-Num $w) -or $w -le 1) { $w = 278 - 30 - 28 }  # window - margin - padding

        $ramp = Get-Ramp $pct
        $bar.Background = New-BarBrush $ramp

        $glow = New-Object Windows.Media.Effects.DropShadowEffect
        $glow.Color = [Windows.Media.Color](New-Color ($ramp[1]))
        $glow.BlurRadius = 10; $glow.ShadowDepth = 0; $glow.Opacity = 0.75
        $bar.Effect = $glow

        $target = [Math]::Min(1.0, [Math]::Max(0.0, $pct / 100.0)) * $w
        if ($pct -gt 0 -and $target -lt 3) { $target = 3 }

        if ($animate) {
            $a = New-Object Windows.Media.Animation.DoubleAnimation
            $a.To = $target
            $a.Duration = New-Object Windows.Duration ([TimeSpan]::FromMilliseconds(700))
            $ease = New-Object Windows.Media.Animation.CubicEase
            $ease.EasingMode = 'EaseOut'
            $a.EasingFunction = $ease
            $bar.BeginAnimation([Windows.FrameworkElement]::WidthProperty, $a)
        } else {
            $bar.BeginAnimation([Windows.FrameworkElement]::WidthProperty, $null)
            $bar.Width = $target
        }
    } catch { Write-Log "PAINT-BAR failed: $($_.Exception.Message)" }
}

function Repaint-Bars {
    foreach ($p in @(
        @{ Bar=$ui.FhBar; Track=$ui.FhTrack; Key='FiveHour' },
        @{ Bar=$ui.WkBar; Track=$ui.WkTrack; Key='Weekly' },
        @{ Bar=$ui.OpBar; Track=$ui.OpTrack; Key='Opus' },
        @{ Bar=$ui.SoBar; Track=$ui.SoTrack; Key='Sonnet' })) {
        $b = $script:Buckets[$p.Key]
        if ($b) { Paint-Bar $p.Bar $p.Track ([double]$b.utilization) $false }
    }
}

function Format-Reset($iso) {
    if (-not $iso) { return '' }
    try {
        $d = ([DateTimeOffset]$iso).ToLocalTime() - [DateTimeOffset]::Now
        if ($d.TotalSeconds -le 0) { return 'resetting...' }
        if ($d.TotalHours -lt 1)  { return ('resets in {0}m {1}s' -f $d.Minutes, $d.Seconds) }
        if ($d.TotalHours -lt 24) { return ('resets in {0}h {1}m' -f $d.Hours, $d.Minutes) }
        'resets {0}' -f ([DateTimeOffset]$iso).ToLocalTime().ToString('ddd h:mm tt')
    } catch { '' }
}

function Set-Bucket($b, $pctBlock, $bar, $track) {
    if ($null -eq $b) { $pctBlock.Text = 'n/a'; Paint-Bar $bar $track 0; return }
    $p = [double]$b.utilization
    $pctBlock.Text = '{0:0}%' -f $p
    Paint-Bar $bar $track $p
}

# ---------------------------------------------------------------- tray

function New-GaugeIcon([double]$pct) {
    $ramp = Get-Ramp $pct
    $bmp  = New-Object System.Drawing.Bitmap 32, 32
    $g    = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.Clear([System.Drawing.Color]::Transparent)

    $tp = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(230, 52, 58, 70)), 5
    $g.DrawEllipse($tp, 4, 4, 24, 24)

    $rgb = '#' + $ramp[1].Substring(3)     # skin colors are #AARRGGBB, GDI+ wants #RRGGBB
    $pen = New-Object System.Drawing.Pen ([System.Drawing.ColorTranslator]::FromHtml($rgb)), 5
    $pen.StartCap = 'Round'; $pen.EndCap = 'Round'
    $g.DrawArc($pen, 4, 4, 24, 24, -90, [Math]::Max(8, [Math]::Min(359, $pct * 3.6)))

    $tp.Dispose(); $pen.Dispose(); $g.Dispose()
    $h = $bmp.GetHicon()
    $ico = [System.Drawing.Icon]::FromHandle($h).Clone()
    [W32]::DestroyIcon($h) | Out-Null
    $bmp.Dispose()
    $ico
}

function Update-Tray([double]$pct, [string]$tip) {
    if (-not $script:TrayIcon) { return }
    try {
        $old = $script:TrayIcon.Icon
        $script:TrayIcon.Icon = New-GaugeIcon $pct
        if ($old) { $old.Dispose() }
        $script:TrayIcon.Text = $tip.Substring(0, [Math]::Min(62, $tip.Length))
    } catch { Write-Log "tray update failed: $($_.Exception.Message)" }
}

# ---------------------------------------------------------------- refresh

function Update-Widget {
    if ($script:Busy) { return }
    $script:Busy = $true
    $ui.Dot.Opacity = 0.3
    try {
        $u = Get-Usage
        $ui.Err.Visibility = 'Collapsed'

        $script:Buckets = @{
            FiveHour = $u.five_hour; Weekly = $u.seven_day
            Opus = $u.seven_day_opus; Sonnet = $u.seven_day_sonnet
        }

        Set-Bucket $u.five_hour $ui.FhPct $ui.FhBar $ui.FhTrack
        Set-Bucket $u.seven_day $ui.WkPct $ui.WkBar $ui.WkTrack

        if ($u.seven_day_opus) {
            Set-Bucket $u.seven_day_opus $ui.OpPct $ui.OpBar $ui.OpTrack
            $ui.OpusRow.Visibility = 'Visible'
        } else { $ui.OpusRow.Visibility = 'Collapsed' }

        if ($u.seven_day_sonnet) {
            Set-Bucket $u.seven_day_sonnet $ui.SoPct $ui.SoBar $ui.SoTrack
            $ui.SonRow.Visibility = 'Visible'
        } else { $ui.SonRow.Visibility = 'Collapsed' }

        if ($u.extra_usage -and $u.extra_usage.is_enabled) {
            $ui.ExTxt.Text = '${0:0.00} / ${1:0}' -f `
                [double]$u.extra_usage.used_credits, [double]$u.extra_usage.monthly_limit
            $ui.ExtraRow.Visibility = 'Visible'
        } else { $ui.ExtraRow.Visibility = 'Collapsed' }

        Tick-Countdown

        $fh = if ($u.five_hour) { [double]$u.five_hour.utilization } else { 0 }
        $wk = if ($u.seven_day) { [double]$u.seven_day.utilization } else { 0 }
        Update-Tray $fh ('Session {0:0}%  |  Weekly {1:0}%' -f $fh, $wk)
        Check-Alert 'Session' $fh
        Check-Alert 'Weekly'  $wk

        $ui.Stamp.Text = (Get-Date).ToString('h:mm tt').ToLower()
        Write-Log ('refresh ok: session {0:0}% weekly {1:0}%' -f $fh, $wk)
    }
    catch {
        $msg = $_.Exception.Message
        if ($_.Exception.Response -and $_.Exception.Response.StatusCode.value__ -eq 429) {
            $msg = 'Rate limited - backing off until next poll.'
        }
        $ui.Err.Text = $msg
        $ui.Err.Visibility = 'Visible'
        $ui.Stamp.Text = (Get-Date).ToString('h:mm tt').ToLower()
        Write-Log "refresh failed: $msg"
    }
    finally {
        $ui.Dot.Opacity = 1
        $script:Busy = $false
    }
}

function Check-Alert([string]$name, [double]$pct) {
    $limit = [double]$script:Cfg.AlertAt
    $was   = [double]($script:LastAlert[$name])
    $script:LastAlert[$name] = $pct
    if ($pct -ge $limit -and $was -lt $limit -and $script:TrayIcon) {
        try {
            $script:TrayIcon.ShowBalloonTip(6000, 'Codex usage',
                ('{0} window at {1:0}%' -f $name, $pct),
                [System.Windows.Forms.ToolTipIcon]::Warning)
        } catch { }
    }
}

function Tick-Countdown {
    try {
        $f = $script:Buckets['FiveHour']; $w = $script:Buckets['Weekly']
        $ui.FhReset.Text = if ($f) { Format-Reset $f.resets_at } else { '' }
        $ui.WkReset.Text = if ($w) { Format-Reset $w.resets_at } else { '' }
        foreach ($b in @($f, $w)) {
            if ($b -and $b.resets_at -and ([DateTimeOffset]$b.resets_at) -lt [DateTimeOffset]::UtcNow) {
                Update-Widget; break
            }
        }
    } catch { Write-Log "ticker failed: $($_.Exception.Message)" }
}

# ---------------------------------------------------------------- layout

# Exact check against real monitor working areas. The virtual-screen bounding
# box is not enough: an L-shaped arrangement leaves dead rectangles inside it,
# and a window parked there is running, on no monitor, invisible.
function Test-OnScreen([double]$l, [double]$t) {
    try {
        foreach ($sc in [System.Windows.Forms.Screen]::AllScreens) {
            $wa = $sc.WorkingArea
            if ($l -ge ($wa.Left - 40) -and $l -le ($wa.Right - 80) -and
                $t -ge ($wa.Top - 10)  -and $t -le ($wa.Bottom - 40)) { return $true }
        }
    } catch { return $true }
    $false
}

function Snap-Corner([string]$corner) {
    $wa = [Windows.SystemParameters]::WorkArea
    $m = 2
    switch ($corner) {
        'TL' { $win.Left = $wa.Left + $m; $win.Top = $wa.Top + $m }
        'TR' { $win.Left = $wa.Right - $win.ActualWidth - $m; $win.Top = $wa.Top + $m }
        'BL' { $win.Left = $wa.Left + $m; $win.Top = $wa.Bottom - $win.ActualHeight - $m }
        'BR' { $win.Left = $wa.Right - $win.ActualWidth - $m
               $win.Top = $wa.Bottom - $win.ActualHeight - $m }
    }
}

function Apply-Cfg {
    $win.Topmost = [bool]$script:Cfg.Topmost
    $ui.Root.Opacity = [double]$script:Cfg.Opacity
    $v = if ($script:Cfg.Compact) { 'Collapsed' } else { 'Visible' }
    $ui.Detail.Visibility = $v
    $ui.FhReset.Visibility = $v
    $ui.WkReset.Visibility = $v
}

# ---------------------------------------------------------------- menu

function New-MenuItem([string]$header, [scriptblock]$action, [bool]$checkable = $false, [bool]$checked = $false) {
    $mi = New-Object Windows.Controls.MenuItem
    $mi.Header = $header; $mi.IsCheckable = $checkable; $mi.IsChecked = $checked
    if ($action) { $mi.Add_Click($action) }
    $mi
}

try {
$menu = New-Object Windows.Controls.ContextMenu
$menu.Items.Add((New-MenuItem 'Refresh now' { Update-Widget })) | Out-Null

$mSkin = New-MenuItem 'Skin'
foreach ($name in $script:Skins.Keys) {
    $mi = New-MenuItem $name $null $true ($script:Cfg.Skin -eq $name)
    $mi.Tag = $name
    $mi.Add_Click({
        param($s, $e)
        $script:Cfg.Skin = [string]$s.Tag
        Apply-Skin
        foreach ($x in $mSkin.Items) { $x.IsChecked = ($x.Tag -eq $s.Tag) }
        Save-Cfg
    })
    $mSkin.Items.Add($mi) | Out-Null
}
$menu.Items.Add($mSkin) | Out-Null

$miCompact = New-MenuItem 'Compact mode' $null $true ([bool]$script:Cfg.Compact)
$miCompact.Add_Click({ $script:Cfg.Compact = $miCompact.IsChecked; Apply-Cfg; Save-Cfg })
$menu.Items.Add($miCompact) | Out-Null

$miTop = New-MenuItem 'Always on top' $null $true ([bool]$script:Cfg.Topmost)
$miTop.Add_Click({ $script:Cfg.Topmost = $miTop.IsChecked; Apply-Cfg; Save-Cfg })
$menu.Items.Add($miTop) | Out-Null

$menu.Items.Add((New-Object Windows.Controls.Separator)) | Out-Null

$mInt = New-MenuItem 'Poll every'
foreach ($n in 1, 5, 10, 15, 30, 60) {
    $mi = New-MenuItem "$n minutes" $null $true ($script:Cfg.Interval -eq $n)
    $mi.Tag = $n
    $mi.Add_Click({
        param($s, $e)
        $script:Cfg.Interval = [int]$s.Tag
        $script:Timer.Interval = [TimeSpan]::FromMinutes($script:Cfg.Interval)
        foreach ($x in $mInt.Items) { $x.IsChecked = ($x.Tag -eq $s.Tag) }
        Save-Cfg
    })
    $mInt.Items.Add($mi) | Out-Null
}
$menu.Items.Add($mInt) | Out-Null

$mOp = New-MenuItem 'Opacity'
foreach ($o in 1.0, 0.9, 0.75, 0.6) {
    $mi = New-MenuItem ('{0:P0}' -f $o) $null $true ([Math]::Abs($script:Cfg.Opacity - $o) -lt 0.01)
    $mi.Tag = $o
    $mi.Add_Click({
        param($s, $e)
        $script:Cfg.Opacity = [double]$s.Tag; Apply-Cfg
        foreach ($x in $mOp.Items) { $x.IsChecked = ($x.Tag -eq $s.Tag) }
        Save-Cfg
    })
    $mOp.Items.Add($mi) | Out-Null
}
$menu.Items.Add($mOp) | Out-Null

$mSnap = New-MenuItem 'Snap to'
foreach ($pair in @(@('Top left','TL'), @('Top right','TR'), @('Bottom left','BL'), @('Bottom right','BR'))) {
    $mi = New-MenuItem $pair[0]
    $mi.Tag = $pair[1]
    $mi.Add_Click({ param($s, $e) Snap-Corner ([string]$s.Tag); Save-Cfg })
    $mSnap.Items.Add($mi) | Out-Null
}
$menu.Items.Add($mSnap) | Out-Null

$startupOn = $null -ne (Get-ItemProperty -Path $script:RunKey -Name $script:RunName -EA SilentlyContinue)
$miStart = New-MenuItem 'Start with Windows' $null $true $startupOn
$miStart.Add_Click({
    try {
        if ($miStart.IsChecked) {
            $vbs = Join-Path $script:ScriptDir 'Start Codex Usage Widget.vbs'
            Set-ItemProperty -Path $script:RunKey -Name $script:RunName -Value "wscript.exe `"$vbs`""
        } else {
            Remove-ItemProperty -Path $script:RunKey -Name $script:RunName -EA SilentlyContinue
        }
    } catch { Write-Log "startup toggle failed: $($_.Exception.Message)" }
})
$menu.Items.Add($miStart) | Out-Null

$menu.Items.Add((New-MenuItem 'Open log' {
    try { Start-Process notepad.exe $script:LogPath } catch { }
})) | Out-Null

$menu.Items.Add((New-Object Windows.Controls.Separator)) | Out-Null
$menu.Items.Add((New-MenuItem 'Hide to tray' { $win.Hide() })) | Out-Null
$menu.Items.Add((New-MenuItem 'Exit' { $win.Close() })) | Out-Null
$win.ContextMenu = $menu
Write-Log 'menu built'
} catch { Die 'menu construction' $_ }

# ---------------------------------------------------------------- tray icon

try {
    $script:TrayIcon = New-Object System.Windows.Forms.NotifyIcon
    $script:TrayIcon.Icon = New-GaugeIcon 0
    $script:TrayIcon.Text = 'Codex Usage'
    $script:TrayIcon.Visible = $true

    $cms = New-Object System.Windows.Forms.ContextMenuStrip
    $cms.Items.Add('Show / hide').Add_Click({
        if ($win.IsVisible) { $win.Hide() } else { $win.Show(); $win.Activate() }
    })
    $cms.Items.Add('Bring to corner').Add_Click({
        $win.Dispatcher.Invoke([action]{ $win.Show(); Snap-Corner 'TR'; $win.Activate(); Save-Cfg })
    })
    $cms.Items.Add('Refresh now').Add_Click({ $win.Dispatcher.Invoke([action]{ Update-Widget }) })
    $cms.Items.Add('-') | Out-Null
    $cms.Items.Add('Exit').Add_Click({ $win.Dispatcher.Invoke([action]{ $win.Close() }) })
    $script:TrayIcon.ContextMenuStrip = $cms

    $script:TrayIcon.Add_DoubleClick({
        if ($win.IsVisible) { $win.Hide() } else { $win.Show(); $win.Activate() }
    })
    Write-Log 'tray ready'
} catch {
    $script:TrayIcon = $null
    Write-Log "tray setup failed: $($_.Exception.Message)"
}

# ---------------------------------------------------------------- wiring

# A throw inside a WPF handler would otherwise take the dispatcher down.
# Write-Log is rate-limited per message, so a repeating fault cannot spin
# the CPU writing a multi-megabyte log the way the resource-cast bug did.
$win.Dispatcher.Add_UnhandledException({
    param($s, $e)
    Write-Log "DISPATCHER: $($e.Exception.GetType().Name): $($e.Exception.Message)"
    $e.Handled = $true
})

$win.Add_MouseLeftButtonDown({
    param($s, $e)
    if ($e.ClickCount -eq 2) { Update-Widget } else { $win.DragMove() }
})
$win.Add_MouseEnter({ $ui.Root.Opacity = 1.0 })
$win.Add_MouseLeave({ $ui.Root.Opacity = [double]$script:Cfg.Opacity })

$script:Timer = New-Object Windows.Threading.DispatcherTimer
$script:Timer.Add_Tick({ Update-Widget })

$script:Ticker = New-Object Windows.Threading.DispatcherTimer
$script:Ticker.Interval = [TimeSpan]::FromSeconds(1)
$script:Ticker.Add_Tick({ Tick-Countdown })

$win.Add_SourceInitialized({
    Load-Cfg
    Apply-Skin
    Apply-Cfg

    try {
        $mons = ([System.Windows.Forms.Screen]::AllScreens | ForEach-Object {
            $_.WorkingArea.ToString() }) -join ' | '
        Write-Log "monitors: $mons"
    } catch { }

    $placed = $false
    if ((Test-Num $script:Cfg.Left) -and (Test-Num $script:Cfg.Top)) {
        $l = [double]$script:Cfg.Left; $t = [double]$script:Cfg.Top
        if (Test-OnScreen $l $t) { $win.Left = $l; $win.Top = $t; $placed = $true }
        else { Write-Log "saved position $l,$t is on no monitor; using default corner" }
    }
    if (-not $placed) {
        $wa = [Windows.SystemParameters]::WorkArea
        $win.Left = $wa.Right - 278 - 2; $win.Top = $wa.Top + 2
    }
    Write-Log ("positioned at {0},{1}" -f $win.Left, $win.Top)

    $miCompact.IsChecked = [bool]$script:Cfg.Compact
    $miTop.IsChecked     = [bool]$script:Cfg.Topmost
})

$win.Add_ContentRendered({
    $script:Timer.Interval = [TimeSpan]::FromMinutes([int]$script:Cfg.Interval)
    Update-Widget
    $script:Timer.Start()
    $script:Ticker.Start()
    Write-Log 'running'
})

$win.Add_Closed({
    $script:Timer.Stop(); $script:Ticker.Stop()
    Save-Cfg
    if ($script:TrayIcon) { $script:TrayIcon.Visible = $false; $script:TrayIcon.Dispose() }
    Write-Log '--- closed ---'
    [Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown()
})


if ($SelfTest) {
    $script:CaptureTimer = New-Object Windows.Threading.DispatcherTimer
    $script:CaptureTimer.Interval = [TimeSpan]::FromMilliseconds(1000)
    $script:CaptureTimer.Add_Tick({
        $script:CaptureTimer.Stop()
        try {
            Tick-Countdown
            $win.UpdateLayout()
            $bmp = New-Object Windows.Media.Imaging.RenderTargetBitmap ([int]$win.ActualWidth), ([int]$win.ActualHeight), 96, 96, ([Windows.Media.PixelFormats]::Pbgra32)
            $bmp.Render($win)
            $png = New-Object Windows.Media.Imaging.PngBitmapEncoder
            $png.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bmp))
            $stream = [IO.File]::Create((Join-Path $PSScriptRoot 'preview.png'))
            try { $png.Save($stream) } finally { $stream.Dispose() }
            $report = [ordered]@{
                Background = $ui.Root.Background.GetType().Name
                Shadow = $ui.Root.Effect.GetType().Name
                Glow = $ui.FhBar.Effect.GetType().Name
                BarGradient = $ui.FhBar.Background.GetType().Name
                Skins = @($script:Skins.Keys)
                MenuItems = @($menu.Items | ForEach-Object { if($_.Header){[string]$_.Header} })
                Error = $ui.Err.Text
                FiveHour = $ui.FhPct.Text
                Weekly = $ui.WkPct.Text
            }
            $report | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $PSScriptRoot 'verification.json')
        } finally { $win.Close() }
    })
    $win.Add_ContentRendered({ $script:CaptureTimer.Start() })
}

try {
    $win.Show() | Out-Null
    $win.Activate() | Out-Null
    [Windows.Threading.Dispatcher]::Run()
} catch { Die 'main loop' $_ }
