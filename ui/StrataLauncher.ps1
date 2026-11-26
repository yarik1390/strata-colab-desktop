<#
.SYNOPSIS
    Strata Colab Desktop - Native Windows WPF Launcher for strata-colab-cli.
.DESCRIPTION
    Provides one-click GPU auto-fallback launching, live runtime/CU status cards,
    Strata model/context configuration persisted to config.local.env, and live
    WSL console streaming without holding open a cluttered command window.
#>
[CmdletBinding()]
param(
    [switch]$SmokeTest
)

$ErrorActionPreference = 'Stop'

# Relaunch in STA mode if invoked from an MTA PowerShell host
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne [System.Threading.ApartmentState]::STA) {
    if ($SmokeTest) {
        throw "SmokeTest must be run under powershell.exe -STA"
    }
    $argsList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-WindowStyle', 'Hidden', '-File', "`"$PSCommandPath`"")
    Start-Process -FilePath 'powershell.exe' -ArgumentList $argsList
    exit 0
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Drawing

$csharpRunner = @'
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.Text;
using System.Text.RegularExpressions;

public sealed class StrataProcessSlot {
    public string Name { get; private set; }
    private readonly ConcurrentQueue<string> _queue = new ConcurrentQueue<string>();
    private readonly object _lock = new object();
    private Process _proc;
    private volatile bool _running;
    private volatile int _lastExitCode;
    private static readonly Regex AnsiRe = new Regex(@"\x1B\[[0-9;?]*[ -/]*[@-~]", RegexOptions.Compiled);

    public StrataProcessSlot(string name) {
        Name = name;
    }

    public bool IsRunning { get { return _running; } }
    public int LastExitCode { get { return _lastExitCode; } }

    public bool Start(string fileName, string arguments, string workingDir) {
        lock (_lock) {
            if (_running) return false;
            string discard;
            while (_queue.TryDequeue(out discard)) { }
            var psi = new ProcessStartInfo {
                FileName = fileName,
                Arguments = arguments,
                WorkingDirectory = workingDir,
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                RedirectStandardInput = true,
                CreateNoWindow = true,
                StandardOutputEncoding = Encoding.UTF8,
                StandardErrorEncoding = Encoding.UTF8
            };
            var p = new Process();
            p.StartInfo = psi;
            p.EnableRaisingEvents = true;
            p.OutputDataReceived += (s, e) => {
                if (e.Data != null) EnqueueLine(e.Data, false);
            };
            p.ErrorDataReceived += (s, e) => {
                if (e.Data != null) EnqueueLine(e.Data, true);
            };
            p.Exited += (s, e) => {
                try { p.WaitForExit(1500); } catch { }
                try { _lastExitCode = p.ExitCode; } catch { _lastExitCode = -1; }
                _running = false;
                _queue.Enqueue("EXIT:" + _lastExitCode);
            };
            _proc = p;
            _running = true;
            p.Start();
            try { p.StandardInput.Close(); } catch { }
            p.BeginOutputReadLine();
            p.BeginErrorReadLine();
            return true;
        }
    }

    private void EnqueueLine(string raw, bool isErr) {
        string clean = AnsiRe.Replace(raw, "").Replace("\r", "");
        _queue.Enqueue((isErr ? "ERR:" : "OUT:") + clean);
    }

    public string[] Drain() {
        var list = new List<string>();
        string item;
        while (_queue.TryDequeue(out item)) {
            list.Add(item);
        }
        return list.ToArray();
    }

    public void StopTree() {
        Process p;
        lock (_lock) { p = _proc; }
        if (p == null) return;
        try {
            if (!p.HasExited) {
                var ki = new ProcessStartInfo {
                    FileName = "taskkill.exe",
                    Arguments = "/PID " + p.Id + " /T /F",
                    UseShellExecute = false,
                    CreateNoWindow = true
                };
                using (var kp = Process.Start(ki)) {
                    if (kp != null) kp.WaitForExit(3000);
                }
            }
        } catch { }
    }
}
'@

if (-not ('StrataProcessSlot' -as [type])) {
    Add-Type -TypeDefinition $csharpRunner -Language CSharp
}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = (Resolve-Path (Join-Path $ScriptDir '..')).Path
$ConfigPath = Join-Path $RepoRoot 'config.env'
$LocalConfigPath = Join-Path $RepoRoot 'config.local.env'
$IconPath = Join-Path $ScriptDir 'strata-colab.ico'

# Ensure custom Strata .ico exists
function Ensure-StrataIcon {
    param([string]$OutPath)
    if (Test-Path $OutPath) { return }
    $sizes = @(16, 32, 48, 256)
    $pngBlobs = New-Object System.Collections.Generic.List[byte[]]
    foreach ($sz in $sizes) {
        $bmp = New-Object System.Drawing.Bitmap($sz, $sz, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.Clear([System.Drawing.Color]::Transparent)

        $pad = [float]($sz * 0.06)
        $box = [float]($sz - 2 * $pad)
        $rad = [float]($sz * 0.22)
        $path = New-Object System.Drawing.Drawing2D.GraphicsPath
        $d = $rad * 2.0
        $path.AddArc($pad, $pad, $d, $d, 180, 90)
        $path.AddArc($pad + $box - $d, $pad, $d, $d, 270, 90)
        $path.AddArc($pad + $box - $d, $pad + $box - $d, $d, $d, 0, 90)
        $path.AddArc($pad, $pad + $box - $d, $d, $d, 90, 90)
        $path.CloseFigure()

        $bgBrush = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
            (New-Object System.Drawing.PointF(0, 0)),
            (New-Object System.Drawing.PointF($sz, $sz)),
            [System.Drawing.Color]::FromArgb(255, 15, 23, 42),
            [System.Drawing.Color]::FromArgb(255, 30, 58, 138)
        )
        $g.FillPath($bgBrush, $path)

        $borderPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(220, 56, 189, 248), [Math]::Max(1.0, $sz * 0.045))
        $g.DrawPath($borderPen, $path)

        # Stylized S / compute nodes mark
        $fontSz = [float]($sz * 0.56)
        $font = New-Object System.Drawing.Font('Segoe UI', $fontSz, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
        $sf = New-Object System.Drawing.StringFormat
        $sf.Alignment = [System.Drawing.StringAlignment]::Center
        $sf.LineAlignment = [System.Drawing.StringAlignment]::Center
        $textBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 248, 250, 252))
        $rect = New-Object System.Drawing.RectangleF(0, ($sz * 0.02), $sz, $sz)
        $g.DrawString('S', $font, $textBrush, $rect, $sf)

        $dotSize = [Math]::Max(2.0, $sz * 0.16)
        $dotBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 56, 189, 248))
        $g.FillEllipse($dotBrush, [float]($sz * 0.68), [float]($sz * 0.18), [float]$dotSize, [float]$dotSize)

        $ms = New-Object System.IO.MemoryStream
        $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        $pngBlobs.Add($ms.ToArray())

        $ms.Dispose(); $dotBrush.Dispose(); $textBrush.Dispose(); $sf.Dispose(); $font.Dispose()
        $borderPen.Dispose(); $bgBrush.Dispose(); $path.Dispose(); $g.Dispose(); $bmp.Dispose()
    }

    $fs = [System.IO.File]::Open($OutPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
    $bw = New-Object System.IO.BinaryWriter($fs)
    $bw.Write([UInt16]0)
    $bw.Write([UInt16]1)
    $bw.Write([UInt16]$sizes.Count)

    $offset = 6 + 16 * $sizes.Count
    for ($i = 0; $i -lt $sizes.Count; $i++) {
        $dim = if ($sizes[$i] -ge 256) { [byte]0 } else { [byte]$sizes[$i] }
        $bytes = $pngBlobs[$i]
        $bw.Write($dim)
        $bw.Write($dim)
        $bw.Write([byte]0)
        $bw.Write([byte]0)
        $bw.Write([UInt16]1)
        $bw.Write([UInt16]32)
        $bw.Write([UInt32]$bytes.Length)
        $bw.Write([UInt32]$offset)
        $offset += $bytes.Length
    }
    foreach ($bytes in $pngBlobs) {
        $bw.Write($bytes)
    }
    $bw.Flush(); $bw.Dispose(); $fs.Dispose()
}

if (-not $SmokeTest) {
    try { Ensure-StrataIcon -OutPath $IconPath } catch { }
}

function Read-StrataConfig {
    $cfg = @{}
    foreach ($path in @($ConfigPath, $LocalConfigPath)) {
        if (-not (Test-Path $path)) { continue }
        foreach ($rawLine in [System.IO.File]::ReadAllLines($path)) {
            $line = $rawLine.Trim()
            if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#')) { continue }
            $idx = $line.IndexOf('=')
            if ($idx -lt 1) { continue }
            $key = $line.Substring(0, $idx).Trim()
            $val = $line.Substring($idx + 1).Trim()
            if ($val.StartsWith('"') -and $val.Length -ge 2) {
                $endQ = $val.IndexOf('"', 1)
                if ($endQ -gt 0) { $val = $val.Substring(1, $endQ - 1) }
            } elseif ($val.StartsWith("'") -and $val.Length -ge 2) {
                $endQ = $val.IndexOf("'", 1)
                if ($endQ -gt 0) { $val = $val.Substring(1, $endQ - 1) }
            } else {
                $hashIdx = $val.IndexOf('#')
                if ($hashIdx -ge 0) { $val = $val.Substring(0, $hashIdx).Trim() }
            }
            $cfg[$key] = $val
        }
    }
    return $cfg
}

function Write-LocalConfigOverrides {
    param([hashtable]$Overrides)
    $managedKeys = @($Overrides.Keys)
    $preserved = New-Object System.Collections.Generic.List[string]
    if (Test-Path $LocalConfigPath) {
        foreach ($rawLine in [System.IO.File]::ReadAllLines($LocalConfigPath)) {
            $t = $rawLine.Trim()
            if ($t -eq '# Managed by Strata Colab Desktop UI') { continue }
            $eq = $t.IndexOf('=')
            if ($eq -gt 0 -and -not $t.StartsWith('#')) {
                $k = $t.Substring(0, $eq).Trim()
                if ($managedKeys -contains $k) { continue }
            }
            if (-not [string]::IsNullOrWhiteSpace($rawLine)) {
                $preserved.Add($rawLine)
            }
        }
    }
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('# Managed by Strata Colab Desktop UI')
    foreach ($k in ($Overrides.Keys | Sort-Object)) {
        $v = [string]$Overrides[$k]
        if ($v -match '^[A-Za-z0-9._:/-]*$') {
            $lines.Add("$k=$v")
        } else {
            $escaped = $v.Replace('"', '\"')
            $lines.Add("$k=`"$escaped`"")
        }
    }
    foreach ($p in $preserved) {
        $lines.Add($p)
    }
    $content = ($lines -join "`n") + "`n"
    [System.IO.File]::WriteAllText($LocalConfigPath, $content, (New-Object System.Text.UTF8Encoding($false)))
}

function Build-WslArgs {
    param([string]$BashCommand)
    $parts = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($env:STRATA_WSL_DISTRO)) {
        $parts.Add('-d')
        $parts.Add(('"' + $env:STRATA_WSL_DISTRO.Replace('"', '') + '"'))
    }
    $parts.Add('--cd')
    $parts.Add(('"' + $RepoRoot + '"'))
    $parts.Add('--exec')
    $parts.Add('bash')
    $parts.Add('-lc')
    $parts.Add(('"' + $BashCommand.Replace('"', '\"') + '"'))
    return ($parts -join ' ')
}

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Strata Colab Desktop"
        Width="980" Height="730"
        MinWidth="840" MinHeight="600"
        WindowStartupLocation="CenterScreen"
        Background="#0B1120"
        Foreground="#F8FAFC"
        FontFamily="Segoe UI">
    <Window.Resources>
        <SolidColorBrush x:Key="CardBg" Color="#111827"/>
        <SolidColorBrush x:Key="CardBorder" Color="#1F2937"/>
        <SolidColorBrush x:Key="InputBg" Color="#1E293B"/>
        <SolidColorBrush x:Key="InputBorder" Color="#334155"/>
        <SolidColorBrush x:Key="AccentSky" Color="#38BDF8"/>
        <SolidColorBrush x:Key="TextMuted" Color="#94A3B8"/>

        <Style x:Key="ActionBtn" TargetType="Button">
            <Setter Property="Foreground" Value="#F8FAFC"/>
            <Setter Property="Background" Value="#1E293B"/>
            <Setter Property="BorderBrush" Value="#334155"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="14,8"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="Bd" Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                CornerRadius="8" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Bd" Property="Opacity" Value="0.88"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="Bd" Property="Opacity" Value="0.74"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="Bd" Property="Opacity" Value="0.42"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="PrimaryBtn" TargetType="Button" BasedOn="{StaticResource ActionBtn}">
            <Setter Property="Background" Value="#0284C7"/>
            <Setter Property="BorderBrush" Value="#38BDF8"/>
        </Style>

        <Style x:Key="DangerBtn" TargetType="Button" BasedOn="{StaticResource ActionBtn}">
            <Setter Property="Background" Value="#7F1D1D"/>
            <Setter Property="BorderBrush" Value="#DC2626"/>
        </Style>

        <Style x:Key="DarkCheck" TargetType="CheckBox">
            <Setter Property="Foreground" Value="#E2E8F0"/>
            <Setter Property="FontSize" Value="12.5"/>
            <Setter Property="VerticalContentAlignment" Value="Center"/>
            <Setter Property="Cursor" Value="Hand"/>
        </Style>

        <Style x:Key="DarkCombo" TargetType="ComboBox">
            <Setter Property="Foreground" Value="#F8FAFC"/>
            <Setter Property="Background" Value="#1E293B"/>
            <Setter Property="BorderBrush" Value="#334155"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="10,6"/>
            <Setter Property="FontSize" Value="12.5"/>
            <Setter Property="Height" Value="34"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ComboBox">
                        <Grid>
                            <ToggleButton x:Name="ToggleButton"
                                          Focusable="False"
                                          IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}"
                                          ClickMode="Press">
                                <ToggleButton.Template>
                                    <ControlTemplate TargetType="ToggleButton">
                                        <Border Background="#1E293B" BorderBrush="#334155" BorderThickness="1" CornerRadius="6">
                                            <Grid>
                                                <Grid.ColumnDefinitions>
                                                    <ColumnDefinition Width="*"/>
                                                    <ColumnDefinition Width="26"/>
                                                </Grid.ColumnDefinitions>
                                                <Path Grid.Column="1" HorizontalAlignment="Center" VerticalAlignment="Center"
                                                      Data="M 0 0 L 4.5 5 L 9 0 Z" Fill="#94A3B8"/>
                                            </Grid>
                                        </Border>
                                    </ControlTemplate>
                                </ToggleButton.Template>
                            </ToggleButton>
                            <ContentPresenter x:Name="ContentSite"
                                              IsHitTestVisible="False"
                                              Content="{TemplateBinding SelectionBoxItem}"
                                              ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"
                                              Margin="10,0,28,0"
                                              VerticalAlignment="Center" HorizontalAlignment="Left"/>
                            <Popup x:Name="Popup"
                                   Placement="Bottom"
                                   IsOpen="{TemplateBinding IsDropDownOpen}"
                                   AllowsTransparency="True"
                                   Focusable="False"
                                   PopupAnimation="Fade">
                                <Border Background="#1E293B" BorderBrush="#475569" BorderThickness="1"
                                        CornerRadius="6" Margin="0,2,0,0"
                                        MinWidth="{TemplateBinding ActualWidth}" MaxHeight="260">
                                    <ScrollViewer SnapsToDevicePixels="True">
                                        <ItemsPresenter KeyboardNavigation.DirectionalNavigation="Contained"/>
                                    </ScrollViewer>
                                </Border>
                            </Popup>
                        </Grid>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
            <Setter Property="ItemContainerStyle">
                <Setter.Value>
                    <Style TargetType="ComboBoxItem">
                        <Setter Property="Background" Value="#1E293B"/>
                        <Setter Property="Foreground" Value="#F8FAFC"/>
                        <Setter Property="Padding" Value="10,7"/>
                        <Setter Property="Template">
                            <Setter.Value>
                                <ControlTemplate TargetType="ComboBoxItem">
                                    <Border x:Name="ItemBd" Background="{TemplateBinding Background}" Padding="{TemplateBinding Padding}">
                                        <ContentPresenter/>
                                    </Border>
                                    <ControlTemplate.Triggers>
                                        <Trigger Property="IsMouseOver" Value="True">
                                            <Setter TargetName="ItemBd" Property="Background" Value="#334155"/>
                                        </Trigger>
                                        <Trigger Property="IsSelected" Value="True">
                                            <Setter TargetName="ItemBd" Property="Background" Value="#0369A1"/>
                                        </Trigger>
                                    </ControlTemplate.Triggers>
                                </ControlTemplate>
                            </Setter.Value>
                        </Setter>
                    </Style>
                </Setter.Value>
            </Setter>
        </Style>
    </Window.Resources>

    <Grid Margin="18,16,18,16">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
        </Grid.RowDefinitions>

        <!-- Header -->
        <Grid Grid.Row="0" Margin="0,0,0,14">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <StackPanel Orientation="Vertical">
                <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                    <Border Background="#0F172A" BorderBrush="#38BDF8" BorderThickness="1.5" CornerRadius="8"
                            Width="34" Height="34" Margin="0,0,12,0">
                        <TextBlock Text="S" FontSize="19" FontWeight="Bold" Foreground="#38BDF8"
                                   HorizontalAlignment="Center" VerticalAlignment="Center"/>
                    </Border>
                    <StackPanel VerticalAlignment="Center">
                        <TextBlock Text="Strata Colab Desktop" FontSize="20" FontWeight="Bold" Foreground="#F8FAFC"/>
                        <TextBlock Text="Google Colab GPU Allocator, Auto-Fallback &amp; Local Tunnel Launcher"
                                   FontSize="12" Foreground="#94A3B8"/>
                    </StackPanel>
                </StackPanel>
            </StackPanel>

            <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
                <Border x:Name="StateBadge" Background="#1E293B" BorderBrush="#334155" BorderThickness="1"
                        CornerRadius="14" Padding="12,5" Margin="0,0,10,0" VerticalAlignment="Center">
                    <TextBlock x:Name="StateBadgeText" Text="Checking status..." FontSize="12" FontWeight="SemiBold" Foreground="#38BDF8"/>
                </Border>
                <Button x:Name="BtnRefresh" Content="Refresh Status" Style="{StaticResource ActionBtn}" Margin="0,0,8,0"/>
                <Button x:Name="BtnColabWeb" Content="Colab Web" Style="{StaticResource ActionBtn}"/>
            </StackPanel>
        </Grid>

        <!-- Status Cards -->
        <UniformGrid Grid.Row="1" Columns="4" Margin="0,0,0,14">
            <Border Background="{StaticResource CardBg}" BorderBrush="{StaticResource CardBorder}" BorderThickness="1" CornerRadius="10" Padding="14,12" Margin="0,0,10,0">
                <StackPanel>
                    <TextBlock Text="COLAB GPU RUNTIME" FontSize="10.5" FontWeight="SemiBold" Foreground="#64748B"/>
                    <TextBlock x:Name="CardGpuValue" Text="--" FontSize="17" FontWeight="Bold" Foreground="#F8FAFC" Margin="0,4,0,2" TextTrimming="CharacterEllipsis"/>
                    <TextBlock x:Name="CardGpuSub" Text="No active runtime" FontSize="11.5" Foreground="#94A3B8" TextTrimming="CharacterEllipsis"/>
                </StackPanel>
            </Border>

            <Border Background="{StaticResource CardBg}" BorderBrush="{StaticResource CardBorder}" BorderThickness="1" CornerRadius="10" Padding="14,12" Margin="0,0,10,0">
                <StackPanel>
                    <TextBlock Text="STRATA ENGINE" FontSize="10.5" FontWeight="SemiBold" Foreground="#64748B"/>
                    <TextBlock x:Name="CardEngineValue" Text="--" FontSize="17" FontWeight="Bold" Foreground="#F8FAFC" Margin="0,4,0,2"/>
                    <TextBlock x:Name="CardEngineSub" Text="Idle" FontSize="11.5" Foreground="#94A3B8" TextTrimming="CharacterEllipsis"/>
                </StackPanel>
            </Border>

            <Border Background="{StaticResource CardBg}" BorderBrush="{StaticResource CardBorder}" BorderThickness="1" CornerRadius="10" Padding="14,12" Margin="0,0,10,0">
                <StackPanel>
                    <TextBlock Text="LOCAL SSH TUNNEL" FontSize="10.5" FontWeight="SemiBold" Foreground="#64748B"/>
                    <TextBlock x:Name="CardTunnelValue" Text="--" FontSize="17" FontWeight="Bold" Foreground="#F8FAFC" Margin="0,4,0,2"/>
                    <TextBlock x:Name="CardTunnelSub" Text="http://localhost:8080" FontSize="11.5" Foreground="#94A3B8" TextTrimming="CharacterEllipsis"/>
                </StackPanel>
            </Border>

            <Border Background="{StaticResource CardBg}" BorderBrush="{StaticResource CardBorder}" BorderThickness="1" CornerRadius="10" Padding="14,12">
                <StackPanel>
                    <TextBlock Text="COMPUTE UNITS" FontSize="10.5" FontWeight="SemiBold" Foreground="#64748B"/>
                    <TextBlock x:Name="CardCuValue" Text="--" FontSize="17" FontWeight="Bold" Foreground="#F8FAFC" Margin="0,4,0,2"/>
                    <TextBlock x:Name="CardCuSub" Text="Rate: --" FontSize="11.5" Foreground="#94A3B8" TextTrimming="CharacterEllipsis"/>
                </StackPanel>
            </Border>
        </UniformGrid>

        <!-- Configuration Card -->
        <Border Grid.Row="2" Background="{StaticResource CardBg}" BorderBrush="{StaticResource CardBorder}" BorderThickness="1" CornerRadius="10" Padding="16,14" Margin="0,0,0,14">
            <Grid>
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>

                <Grid Grid.Row="0" Margin="0,0,0,12">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="1.2*"/>
                        <ColumnDefinition Width="1.8*"/>
                        <ColumnDefinition Width="0.9*"/>
                        <ColumnDefinition Width="1.1*"/>
                        <ColumnDefinition Width="1.1*"/>
                    </Grid.ColumnDefinitions>

                    <StackPanel Grid.Column="0" Margin="0,0,10,0">
                        <TextBlock Text="GPU Selection" FontSize="11.5" FontWeight="SemiBold" Foreground="#94A3B8" Margin="0,0,0,5"/>
                        <ComboBox x:Name="CmbGpu" Style="{StaticResource DarkCombo}"/>
                    </StackPanel>

                    <StackPanel Grid.Column="1" Margin="0,0,10,0">
                        <TextBlock Text="Strata Model" FontSize="11.5" FontWeight="SemiBold" Foreground="#94A3B8" Margin="0,0,0,5"/>
                        <ComboBox x:Name="CmbModel" Style="{StaticResource DarkCombo}"/>
                    </StackPanel>

                    <StackPanel Grid.Column="2" Margin="0,0,10,0">
                        <TextBlock Text="Context Tokens" FontSize="11.5" FontWeight="SemiBold" Foreground="#94A3B8" Margin="0,0,0,5"/>
                        <ComboBox x:Name="CmbContext" Style="{StaticResource DarkCombo}"/>
                    </StackPanel>

                    <StackPanel Grid.Column="3" Margin="0,0,10,0">
                        <TextBlock Text="UI Mode" FontSize="11.5" FontWeight="SemiBold" Foreground="#94A3B8" Margin="0,0,0,5"/>
                        <ComboBox x:Name="CmbUiMode" Style="{StaticResource DarkCombo}"/>
                    </StackPanel>

                    <StackPanel Grid.Column="4">
                        <TextBlock Text="Tune On Start" FontSize="11.5" FontWeight="SemiBold" Foreground="#94A3B8" Margin="0,0,0,5"/>
                        <ComboBox x:Name="CmbTune" Style="{StaticResource DarkCombo}"/>
                    </StackPanel>
                </Grid>

                <Grid Grid.Row="1">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <WrapPanel Orientation="Horizontal" VerticalAlignment="Center">
                        <CheckBox x:Name="ChkDrive" Content="Mount Google Drive cache" Style="{StaticResource DarkCheck}" Margin="0,0,18,0"/>
                        <CheckBox x:Name="ChkHighMem" Content="High-RAM shape (auto-fallback to Standard)" Style="{StaticResource DarkCheck}" Margin="0,0,18,0"/>
                        <CheckBox x:Name="ChkMonitor" Content="Anti-idle kernel monitor" Style="{StaticResource DarkCheck}" Margin="0,0,18,0"/>
                        <CheckBox x:Name="ChkBrowser" Content="Open browser on ready" Style="{StaticResource DarkCheck}"/>
                    </WrapPanel>
                    <Button x:Name="BtnSaveConfig" Grid.Column="1" Content="Save Config" Style="{StaticResource ActionBtn}" Padding="12,5" FontSize="12"/>
                </Grid>
            </Grid>
        </Border>

        <!-- Action Buttons -->
        <Grid Grid.Row="3" Margin="0,0,0,12">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <WrapPanel Orientation="Horizontal">
                <Button x:Name="BtnStart" Content="Start Session" Style="{StaticResource PrimaryBtn}" Margin="0,0,8,0"/>
                <Button x:Name="BtnOpenUi" Content="Open Strata UI" Style="{StaticResource ActionBtn}" Margin="0,0,8,0"/>
                <Button x:Name="BtnTune" Content="Auto-Tune" Style="{StaticResource ActionBtn}" Margin="0,0,8,0"/>
                <Button x:Name="BtnRestart" Content="Restart Strata" Style="{StaticResource ActionBtn}" Margin="0,0,8,0"/>
                <Button x:Name="BtnDetach" Content="Detach Tunnel" Style="{StaticResource ActionBtn}" Margin="0,0,8,0" IsEnabled="False"/>
                <Button x:Name="BtnStopVm" Content="Stop VM &amp; Save CU" Style="{StaticResource DangerBtn}"/>
            </WrapPanel>

            <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
                <Button x:Name="BtnCopyLog" Content="Copy Log" Style="{StaticResource ActionBtn}" Padding="10,6" FontSize="12" Margin="0,0,6,0"/>
                <Button x:Name="BtnClearLog" Content="Clear Log" Style="{StaticResource ActionBtn}" Padding="10,6" FontSize="12"/>
            </StackPanel>
        </Grid>

        <!-- Console Output -->
        <Border Grid.Row="4" Background="#070B14" BorderBrush="{StaticResource CardBorder}" BorderThickness="1" CornerRadius="10" Padding="8">
            <TextBox x:Name="TxtLog"
                     Background="Transparent"
                     Foreground="#E2E8F0"
                     BorderThickness="0"
                     FontFamily="Consolas"
                     FontSize="12"
                     IsReadOnly="True"
                     TextWrapping="Wrap"
                     VerticalScrollBarVisibility="Auto"
                     HorizontalScrollBarVisibility="Disabled"
                     AcceptsReturn="True"/>
        </Border>
    </Grid>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [System.Windows.Markup.XamlReader]::Load($reader)

if (-not $SmokeTest -and (Test-Path $IconPath)) {
    try {
        $window.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create([Uri]::new($IconPath))
    } catch { }
}

# Bind Controls
$StateBadge = $window.FindName('StateBadge')
$StateBadgeText = $window.FindName('StateBadgeText')
$BtnRefresh = $window.FindName('BtnRefresh')
$BtnColabWeb = $window.FindName('BtnColabWeb')
$CardGpuValue = $window.FindName('CardGpuValue')
$CardGpuSub = $window.FindName('CardGpuSub')
$CardEngineValue = $window.FindName('CardEngineValue')
$CardEngineSub = $window.FindName('CardEngineSub')
$CardTunnelValue = $window.FindName('CardTunnelValue')
$CardTunnelSub = $window.FindName('CardTunnelSub')
$CardCuValue = $window.FindName('CardCuValue')
$CardCuSub = $window.FindName('CardCuSub')
$CmbGpu = $window.FindName('CmbGpu')
$CmbModel = $window.FindName('CmbModel')
$CmbContext = $window.FindName('CmbContext')
$CmbUiMode = $window.FindName('CmbUiMode')
$CmbTune = $window.FindName('CmbTune')
$ChkDrive = $window.FindName('ChkDrive')
$ChkHighMem = $window.FindName('ChkHighMem')
$ChkMonitor = $window.FindName('ChkMonitor')
$ChkBrowser = $window.FindName('ChkBrowser')
$BtnSaveConfig = $window.FindName('BtnSaveConfig')
$BtnStart = $window.FindName('BtnStart')
$BtnOpenUi = $window.FindName('BtnOpenUi')
$BtnTune = $window.FindName('BtnTune')
$BtnRestart = $window.FindName('BtnRestart')
$BtnDetach = $window.FindName('BtnDetach')
$BtnStopVm = $window.FindName('BtnStopVm')
$BtnCopyLog = $window.FindName('BtnCopyLog')
$BtnClearLog = $window.FindName('BtnClearLog')
$TxtLog = $window.FindName('TxtLog')

# Option tables (Label -> Value mappings)
$GpuOptions = @(
    @{ Label = 'AUTO (Best Available GPU)'; Value = 'AUTO' },
    @{ Label = 'G4 (RTX PRO 6000 98 GB)'; Value = 'G4' },
    @{ Label = 'H100 (80 GB VRAM)'; Value = 'H100' },
    @{ Label = 'A100 (40-80 GB VRAM)'; Value = 'A100' },
    @{ Label = 'L4 (23 GB VRAM)'; Value = 'L4' },
    @{ Label = 'T4 (15 GB VRAM)'; Value = 'T4' }
)

$ModelOptions = @(
    @{ Label = 'AUTO (Match GPU Memory)'; Model = 'AUTO'; Family = '' },
    @{ Label = 'Qwen3.8-Flash [IQ3_S] (G4/H100/A100)'; Model = 'IQ3_S'; Family = '' },
    @{ Label = 'Qwen3.8-Flash [IQ2_XS] (L4/A100)'; Model = 'IQ2_XS'; Family = '' },
    @{ Label = 'Qwen3.8-Flash [Q2_0] (Fast Flash)'; Model = 'Q2_0'; Family = '' },
    @{ Label = 'Qwen3.8-Coder [IQ1_M] (Coding)'; Model = 'IQ1_M'; Family = 'coder' },
    @{ Label = 'Qwen3.6-35B [UD-Q4_K_XL] (T4/L4)'; Model = 'UD-Q4_K_XL'; Family = 'qwen36' }
)

$ContextOptions = @('8192', '16384', '32768', '65536', '131072', '262144')
$UiModeOptions = @(
    @{ Label = 'desktop (Strata Web UI)'; Value = 'desktop' },
    @{ Label = 'cli (Headless OpenAI API)'; Value = 'cli' }
)
$TuneOptions = @(
    @{ Label = '0 - Fast start (load preset)'; Value = '0' },
    @{ Label = '1 - Auto-Tune on start'; Value = '1' }
)

foreach ($o in $GpuOptions) { $null = $CmbGpu.Items.Add($o.Label) }
foreach ($o in $ModelOptions) { $null = $CmbModel.Items.Add($o.Label) }
foreach ($c in $ContextOptions) { $null = $CmbContext.Items.Add($c) }
foreach ($o in $UiModeOptions) { $null = $CmbUiMode.Items.Add($o.Label) }
foreach ($o in $TuneOptions) { $null = $CmbTune.Items.Add($o.Label) }

# Load current config.env + config.local.env values
$cfg = Read-StrataConfig
$script:LocalPort = if ($cfg['LOCAL_PORT']) { $cfg['LOCAL_PORT'] } else { '8080' }
$CardTunnelSub.Text = "http://localhost:$($script:LocalPort)"

$cfgGpu = if ($cfg['GPU']) { $cfg['GPU'].ToUpper() } else { 'AUTO' }
$gpuIdx = 0
for ($i = 0; $i -lt $GpuOptions.Count; $i++) {
    if ($GpuOptions[$i].Value -eq $cfgGpu) { $gpuIdx = $i; break }
}
$CmbGpu.SelectedIndex = $gpuIdx

$cfgModel = if ($cfg['MODEL']) { $cfg['MODEL'] } else { 'AUTO' }
$cfgFamily = if ($cfg['MODEL_FAMILY']) { $cfg['MODEL_FAMILY'] } else { '' }
$modelIdx = 0
for ($i = 0; $i -lt $ModelOptions.Count; $i++) {
    if ($ModelOptions[$i].Model -ieq $cfgModel -and $ModelOptions[$i].Family -ieq $cfgFamily) {
        $modelIdx = $i; break
    }
}
$CmbModel.SelectedIndex = $modelIdx

$cfgCtx = if ($cfg['CONTEXT']) { $cfg['CONTEXT'] } else { '32768' }
$ctxIdx = [Array]::IndexOf($ContextOptions, $cfgCtx)
if ($ctxIdx -lt 0) {
    $null = $CmbContext.Items.Add($cfgCtx)
    $ctxIdx = $CmbContext.Items.Count - 1
}
$CmbContext.SelectedIndex = $ctxIdx

$cfgUi = if ($cfg['UI_MODE']) { $cfg['UI_MODE'].ToLower() } else { 'desktop' }
$CmbUiMode.SelectedIndex = if ($cfgUi -eq 'cli') { 1 } else { 0 }

$cfgTune = if ($cfg['TUNE_ON_START']) { $cfg['TUNE_ON_START'].Trim() } else { '0' }
$CmbTune.SelectedIndex = if ($cfgTune -eq '1') { 1 } else { 0 }

$ChkDrive.IsChecked = ($cfg['USE_DRIVE'] -ne '0')
$ChkHighMem.IsChecked = ($cfg['HIGH_MEM'] -ne '0')
$ChkMonitor.IsChecked = ($cfg['ACTIVE_WORKLOAD_MONITOR'] -ne '0')
$ChkBrowser.IsChecked = ($cfg['OPEN_BROWSER'] -ne '0')

if ($SmokeTest) {
    $window.ShowActivated = $false
    $window.ShowInTaskbar = $false
    $window.Add_ContentRendered({ $window.Close() })
    $null = $window.ShowDialog()
    Write-Output 'SMOKE_TEST_OK'
    exit 0
}

# Process Slots & State
$script:SessionSlot = New-Object StrataProcessSlot 'session'
$script:AuxSlot = New-Object StrataProcessSlot 'aux'
$script:StatusSlot = New-Object StrataProcessSlot 'status'
$script:StatusBuffer = New-Object System.Collections.Generic.List[string]
$script:ActiveMode = ''
$script:HasActiveRuntime = $false
$script:ForceClosing = $false

function Append-Log {
    param([string]$Line)
    if ($null -eq $Line) { return }
    $ts = (Get-Date).ToString('HH:mm:ss')
    $TxtLog.AppendText("[$ts] $Line`r`n")
    $TxtLog.ScrollToEnd()
}

function Set-Badge {
    param([string]$Text, [string]$ColorHex)
    $StateBadgeText.Text = $Text
    $brush = (New-Object System.Windows.Media.BrushConverter).ConvertFromString($ColorHex)
    $StateBadgeText.Foreground = $brush
}

function Get-UiSelection {
    $gpuVal = $GpuOptions[$CmbGpu.SelectedIndex].Value
    $mOpt = $ModelOptions[$CmbModel.SelectedIndex]
    $ctxVal = [string]$CmbContext.SelectedItem
    $uiVal = $UiModeOptions[$CmbUiMode.SelectedIndex].Value
    $tuneVal = $TuneOptions[$CmbTune.SelectedIndex].Value
    return @{
        GPU = $gpuVal
        MODEL = $mOpt.Model
        MODEL_FAMILY = $mOpt.Family
        CONTEXT = $ctxVal
        UI_MODE = $uiVal
        TUNE_ON_START = $tuneVal
        USE_DRIVE = if ($ChkDrive.IsChecked) { '1' } else { '0' }
        HIGH_MEM = if ($ChkHighMem.IsChecked) { '1' } else { '0' }
        ACTIVE_WORKLOAD_MONITOR = if ($ChkMonitor.IsChecked) { '1' } else { '0' }
        OPEN_BROWSER = if ($ChkBrowser.IsChecked) { '1' } else { '0' }
    }
}

function Update-ButtonStates {
    $sessBusy = $script:SessionSlot.IsRunning
    $auxBusy = $script:AuxSlot.IsRunning
    $BtnStart.IsEnabled = (-not $sessBusy)
    $BtnDetach.IsEnabled = ($sessBusy -or $auxBusy)
    $BtnRestart.IsEnabled = ((-not $sessBusy) -or ($script:ActiveMode -eq 'tunnel'))
    $BtnTune.IsEnabled = (-not $auxBusy)
    $BtnStopVm.IsEnabled = $true
}

function Apply-StatusOutput {
    param([string[]]$Lines)
    $full = ($Lines -join "`n")
    $cuBal = ''
    $cuRate = ''
    $eligGpus = ''
    $gpuHardware = ''
    $runtimeState = ''
    $strataState = ''
    $tunnelState = ''

    foreach ($ln in $Lines) {
        if ($ln -match 'Current balance:\s*([0-9.]+)\s*compute units') {
            $cuBal = "$($Matches[1]) CU"
        } elseif ($ln -match 'Usage rate:\s*([0-9.]+/hr)') {
            $cuRate = "Rate: $($Matches[1])"
        } elseif ($ln -match '^ELIGIBLE_GPUS=(.+)$') {
            $eligGpus = $Matches[1].Trim()
        } elseif ($ln -match 'No active (Colab )?runtime') {
            $runtimeState = 'None'
        } elseif ($ln -match '^\s*(NVIDIA|Tesla|Quadro|RTX|A100|H100|L4|T4|G4)[^,]*,\s*\d+\s*MiB,\s*\d+\s*MiB') {
            $gpuHardware = $ln.Trim()
        } elseif ($ln -match 'Strata Status:\s*(.+)$') {
            $strataState = $Matches[1].Trim()
        } elseif ($ln -match '^\s*Status:\s*(RUNNING|CONNECTING|ASSIGNED|.+)$') {
            $runtimeState = $Matches[1].Trim()
        } elseif ($ln -match 'Local SSH Tunnel:\s*(https?://\S+)') {
            $CardTunnelSub.Text = $Matches[1].Trim().TrimEnd('=')
        } elseif ($ln -match '^\s*Connected\s*$') {
            $tunnelState = 'Connected'
        } elseif ($ln -match '^\s*Not connected\s*$') {
            $tunnelState = 'Disconnected'
        }
    }

    if ($cuBal) { $CardCuValue.Text = $cuBal }
    $subParts = @()
    if ($cuRate) { $subParts += $cuRate }
    if ($eligGpus) { $subParts += "Eligible: $eligGpus" }
    if ($subParts.Count -gt 0) { $CardCuSub.Text = ($subParts -join ' | ') }

    if ($gpuHardware) {
        $script:HasActiveRuntime = $true
        $shortGpu = ($gpuHardware -split ',')[0].Trim()
        $vramPart = (($gpuHardware -split ',')[2] -replace '\s+', ' ').Trim()
        $CardGpuValue.Text = $shortGpu
        $CardGpuSub.Text = "VRAM total: $vramPart"
    } elseif ($runtimeState -eq 'None') {
        $script:HasActiveRuntime = $false
        $CardGpuValue.Text = 'None'
        $CardGpuSub.Text = 'No active Colab VM'
    } elseif ($runtimeState) {
        $script:HasActiveRuntime = $true
        $CardGpuValue.Text = $runtimeState
        $CardGpuSub.Text = 'Active session'
    }

    if ($strataState -match 'RUNNING') {
        $CardEngineValue.Text = 'RUNNING'
        $CardEngineValue.Foreground = (New-Object System.Windows.Media.BrushConverter).ConvertFromString('#22C55E')
        $CardEngineSub.Text = 'Healthy on Colab VM'
    } elseif ($runtimeState -eq 'None') {
        $CardEngineValue.Text = 'OFFLINE'
        $CardEngineValue.Foreground = (New-Object System.Windows.Media.BrushConverter).ConvertFromString('#94A3B8')
        $CardEngineSub.Text = 'Start session to launch'
    } elseif ($strataState) {
        $CardEngineValue.Text = 'STOPPED'
        $CardEngineValue.Foreground = (New-Object System.Windows.Media.BrushConverter).ConvertFromString('#F59E0B')
        $CardEngineSub.Text = $strataState
    }

    if ($tunnelState -eq 'Connected') {
        $CardTunnelValue.Text = 'Connected'
        $CardTunnelValue.Foreground = (New-Object System.Windows.Media.BrushConverter).ConvertFromString('#22C55E')
    } elseif ($tunnelState -eq 'Disconnected') {
        $CardTunnelValue.Text = 'Disconnected'
        $CardTunnelValue.Foreground = (New-Object System.Windows.Media.BrushConverter).ConvertFromString('#94A3B8')
    }

    if (-not $script:SessionSlot.IsRunning) {
        if ($tunnelState -eq 'Connected' -and $strataState -match 'RUNNING') {
            Set-Badge 'Running' '#22C55E'
        } elseif ($script:HasActiveRuntime) {
            Set-Badge 'VM Active' '#F59E0B'
        } else {
            Set-Badge 'Idle' '#38BDF8'
        }
    }
}

function Trigger-StatusRefresh {
    if ($script:StatusSlot.IsRunning) { return }
    $script:StatusBuffer.Clear()
    $cmd = '(set +e; py=$(source ./lib/common.sh && colab_python); [ -n "$py" ] && "$py" ./lib/colab-helper.py info) 2>/dev/null || true; bash ./status.sh 2>/dev/null || true'
    $null = $script:StatusSlot.Start('wsl.exe', (Build-WslArgs $cmd), $RepoRoot)
}

function Start-SessionTask {
    param([string]$ScriptName, [string]$Label)
    $sel = Get-UiSelection
    Write-LocalConfigOverrides -Overrides $sel
    $script:ActiveMode = 'starting'
    Set-Badge $Label '#38BDF8'
    Append-Log "=== $Label ($ScriptName) ==="

    $envPrefix = @(
        'ASK_GPU=0',
        'ASK_MODEL=0',
        "GPU=$($sel.GPU)",
        "MODEL=$($sel.MODEL)",
        "MODEL_FAMILY=$($sel.MODEL_FAMILY)",
        "CONTEXT=$($sel.CONTEXT)",
        "UI_MODE=$($sel.UI_MODE)",
        "TUNE_ON_START=$($sel.TUNE_ON_START)",
        "USE_DRIVE=$($sel.USE_DRIVE)",
        "HIGH_MEM=$($sel.HIGH_MEM)",
        "ACTIVE_WORKLOAD_MONITOR=$($sel.ACTIVE_WORKLOAD_MONITOR)",
        "OPEN_BROWSER=$($sel.OPEN_BROWSER)"
    ) -join ' '

    $bashCmd = "env $envPrefix bash ./$ScriptName"
    if ($script:SessionSlot.Start('wsl.exe', (Build-WslArgs $bashCmd), $RepoRoot)) {
        Update-ButtonStates
    } else {
        Append-Log '[UI] Another primary task is still running.'
    }
}

# Button Event Handlers
$BtnSaveConfig.Add_Click({
    $sel = Get-UiSelection
    Write-LocalConfigOverrides -Overrides $sel
    Append-Log "Saved UI settings to config.local.env (GPU=$($sel.GPU), MODEL=$($sel.MODEL), CONTEXT=$($sel.CONTEXT))."
})

$BtnRefresh.Add_Click({
    Set-Badge 'Refreshing...' '#38BDF8'
    Trigger-StatusRefresh
})

$BtnColabWeb.Add_Click({
    [System.Diagnostics.Process]::Start('https://colab.research.google.com/') | Out-Null
})

$BtnOpenUi.Add_Click({
    [System.Diagnostics.Process]::Start("http://localhost:$($script:LocalPort)") | Out-Null
})

$BtnStart.Add_Click({
    Start-SessionTask -ScriptName 'up.sh' -Label 'Starting Session'
})

$BtnRestart.Add_Click({
    if ($script:SessionSlot.IsRunning) {
        $script:SessionSlot.StopTree()
        Start-Sleep -Milliseconds 350
    }
    Start-SessionTask -ScriptName 'restart.sh' -Label 'Restarting Strata'
})

$BtnTune.Add_Click({
    if ($script:AuxSlot.IsRunning) {
        Append-Log '[UI] Auto-Tune is already running.'
        return
    }
    $sel = Get-UiSelection
    Write-LocalConfigOverrides -Overrides $sel
    Append-Log '=== Running Auto-Tune (./tune.sh thorough coding work) ==='
    $bashCmd = "env MODEL=$($sel.MODEL) MODEL_FAMILY=$($sel.MODEL_FAMILY) bash ./tune.sh thorough coding work"
    if ($script:AuxSlot.Start('wsl.exe', (Build-WslArgs $bashCmd), $RepoRoot)) {
        Update-ButtonStates
    }
})

$BtnDetach.Add_Click({
    if ($script:SessionSlot.IsRunning) {
        Append-Log '[UI] Detaching local WSL tunnel / task process...'
        $script:SessionSlot.StopTree()
        $null = Start-Process -FilePath 'wsl.exe' -ArgumentList (Build-WslArgs 'source ./lib/common.sh; stop_tunnel || true') -WindowStyle Hidden
    }
    if ($script:AuxSlot.IsRunning) {
        $script:AuxSlot.StopTree()
    }
    $script:ActiveMode = ''
    Update-ButtonStates
    Trigger-StatusRefresh
})

$BtnStopVm.Add_Click({
    if ($script:SessionSlot.IsRunning) {
        $script:SessionSlot.StopTree()
        Start-Sleep -Milliseconds 300
    }
    if ($script:AuxSlot.IsRunning) {
        $script:AuxSlot.StopTree()
        Start-Sleep -Milliseconds 200
    }
    $script:ActiveMode = 'stopping'
    Set-Badge 'Stopping VM...' '#F59E0B'
    Append-Log '=== Stopping Colab VM & Closing Tunnel (./down.sh) ==='
    if ($script:SessionSlot.Start('wsl.exe', (Build-WslArgs 'bash ./down.sh'), $RepoRoot)) {
        Update-ButtonStates
    }
})

$BtnCopyLog.Add_Click({
    try {
        [System.Windows.Clipboard]::SetText($TxtLog.Text)
    } catch { }
})

$BtnClearLog.Add_Click({
    $TxtLog.Clear()
})

# DispatcherTimer polls process queues cleanly on the UI thread (120ms)
$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(120)
$timer.Add_Tick({
    # 1. Session slot
    foreach ($item in $script:SessionSlot.Drain()) {
        if ($item.StartsWith('EXIT:')) {
            $code = $item.Substring(5)
            $wasMode = $script:ActiveMode
            $script:ActiveMode = ''
            Append-Log "[Process exited with code $code]"
            if ($code -eq '0') {
                Set-Badge 'Ready' '#22C55E'
            } elseif ($wasMode -ne 'stopping') {
                Set-Badge "Exited ($code)" '#EF4444'
            }
            Update-ButtonStates
            Trigger-StatusRefresh
        } else {
            $text = $item.Substring(4)
            Append-Log $text
            if ($text -match 'Local tunnel active|Press Ctrl\+C to stop|SSH tunnel running|is running') {
                $script:ActiveMode = 'tunnel'
                Set-Badge 'Tunnel Active' '#22C55E'
                Update-ButtonStates
                Trigger-StatusRefresh
            } elseif ($text -match 'Trying (G4|H100|A100|L4|T4)') {
                Set-Badge "Probing $($Matches[1])..." '#38BDF8'
            } elseif ($text -match 'Downloading|Extracting|Starting Strata|Preparing') {
                Set-Badge 'Starting Strata...' '#38BDF8'
            }
        }
    }

    # 2. Aux slot (Auto-Tune)
    foreach ($item in $script:AuxSlot.Drain()) {
        if ($item.StartsWith('EXIT:')) {
            Append-Log "[Auto-Tune exited with code $($item.Substring(5))]"
            Update-ButtonStates
            Trigger-StatusRefresh
        } else {
            Append-Log $item.Substring(4)
        }
    }

    # 3. Status slot
    foreach ($item in $script:StatusSlot.Drain()) {
        if ($item.StartsWith('EXIT:')) {
            Apply-StatusOutput -Lines $script:StatusBuffer.ToArray()
        } else {
            $script:StatusBuffer.Add($item.Substring(4))
        }
    }
})

$window.Add_Loaded({
    $timer.Start()
    Update-ButtonStates
    Append-Log "Strata Colab Desktop ready. Repository: $RepoRoot"
    Trigger-StatusRefresh
})

$window.Add_Closing({
    param($sender, $e)
    if ($script:ForceClosing) { return }
    if ($script:SessionSlot.IsRunning -or $script:HasActiveRuntime) {
        $msg = "Closing the launcher will disconnect the local SSH tunnel.`n`n" +
               "Do you also want to STOP the Google Colab VM so it stops consuming compute units?`n`n" +
               "  Yes    = Stop Colab VM (./down.sh) and exit`n" +
               "  No     = Exit launcher only (keep Colab VM running)`n" +
               "  Cancel = Keep launcher open"
        $ans = [System.Windows.MessageBox]::Show($msg, 'Strata Colab Desktop', [System.Windows.MessageBoxButton]::YesNoCancel, [System.Windows.MessageBoxImage]::Question)
        if ($ans -eq [System.Windows.MessageBoxResult]::Cancel) {
            $e.Cancel = $true
            return
        }
        $timer.Stop()
        if ($script:SessionSlot.IsRunning) { $script:SessionSlot.StopTree() }
        if ($script:AuxSlot.IsRunning) { $script:AuxSlot.StopTree() }
        if ($ans -eq [System.Windows.MessageBoxResult]::Yes) {
            $p = Start-Process -FilePath 'wsl.exe' -ArgumentList (Build-WslArgs 'bash ./down.sh') -WindowStyle Hidden -PassThru
            $null = $p.WaitForExit(15000)
        } else {
            $null = Start-Process -FilePath 'wsl.exe' -ArgumentList (Build-WslArgs 'source ./lib/common.sh; stop_tunnel || true') -WindowStyle Hidden
        }
    } else {
        $timer.Stop()
        if ($script:StatusSlot.IsRunning) { $script:StatusSlot.StopTree() }
    }
})

$null = $window.ShowDialog()
