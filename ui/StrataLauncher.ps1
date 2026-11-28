<#
.SYNOPSIS
    Strata Colab Desktop - Native Windows WPF Launcher for strata-colab-cli.
.DESCRIPTION
    Provides one-click GPU auto-fallback launching, live 20s telemetry & CU burn
    tracking, Strata engine & custom Hugging Face configuration persisted to
    config.local.env, one-click coding-agent client setup, system tray support,
    and filterable live WSL console streaming.
#>
[CmdletBinding()]
param(
    [switch]$SmokeTest,
    [string]$CaptureScreenshot = ''
)

$ErrorActionPreference = 'Stop'

$IsTestRenderMode = [bool]($SmokeTest -or -not [string]::IsNullOrWhiteSpace($CaptureScreenshot))

# Relaunch in STA mode if invoked from an MTA PowerShell host
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne [System.Threading.ApartmentState]::STA) {
    if ($IsTestRenderMode) {
        throw 'SmokeTest and CaptureScreenshot must be run under powershell.exe -STA'
    }
    $argsList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-WindowStyle', 'Hidden', '-File', "`"$PSCommandPath`"")
    Start-Process -FilePath 'powershell.exe' -ArgumentList $argsList
    exit 0
}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = (Resolve-Path (Join-Path $ScriptDir '..')).Path
$StateDir = Join-Path $RepoRoot '.state'
$CrashLogPath = Join-Path $StateDir 'launcher-crash.log'
$script:NotifyIcon = $null
$script:PollTimer = $null
$script:TelemetryTimer = $null

function Write-LauncherCrashLog {
    param([System.Management.Automation.ErrorRecord]$ErrorRecord)
    try {
        if (-not (Test-Path -LiteralPath $StateDir)) {
            New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
        }
        $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        $entry = @(
            '===================================================================='
            "Timestamp : $ts"
            "PSVersion : $($PSVersionTable.PSVersion)"
            "Message   : $($ErrorRecord.Exception.Message)"
            'Exception :'
            $ErrorRecord.Exception.ToString()
            'ScriptStackTrace:'
            $ErrorRecord.ScriptStackTrace
            ''
        ) -join "`r`n"
        [System.IO.File]::AppendAllText($CrashLogPath, $entry, (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
}

try {

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Drawing
if (-not $IsTestRenderMode) {
    Add-Type -AssemblyName System.Windows.Forms
}

Import-Module (Join-Path $ScriptDir 'StrataHelpers.psm1') -Force -DisableNameChecking

$csharpRunner = @'
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

public sealed class StrataProcessSlot {
    public string Name { get; private set; }
    private readonly ConcurrentQueue<string> _queue = new ConcurrentQueue<string>();
    private readonly object _lock = new object();
    private Process _proc;
    private volatile bool _running;
    private volatile int _lastExitCode;
    private long _generation = 0;
    private static readonly Regex AnsiRe = new Regex(@"\x1B\[[0-9;?]*[ -/]*[@-~]", RegexOptions.Compiled);

    public StrataProcessSlot(string name) {
        Name = name;
    }

    public bool IsRunning { get { return _running; } }
    public int LastExitCode { get { return _lastExitCode; } }
    public long Generation { get { return Interlocked.Read(ref _generation); } }

    public bool Start(string fileName, string arguments, string workingDir) {
        return Start(fileName, arguments, workingDir, false);
    }

    public bool Start(string fileName, string arguments, string workingDir, bool keepStdinOpen) {
        lock (_lock) {
            if (_running) return false;
            string discard;
            while (_queue.TryDequeue(out discard)) { }

            long gen = Interlocked.Increment(ref _generation);
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
            psi.EnvironmentVariables["WSL_UTF8"] = "1";

            var p = new Process();
            p.StartInfo = psi;
            p.EnableRaisingEvents = true;
            p.OutputDataReceived += (s, e) => {
                if (e.Data != null && Interlocked.Read(ref _generation) == gen) {
                    EnqueueLine(e.Data, false);
                }
            };
            p.ErrorDataReceived += (s, e) => {
                if (e.Data != null && Interlocked.Read(ref _generation) == gen) {
                    EnqueueLine(e.Data, true);
                }
            };
            p.Exited += (s, e) => {
                try { p.WaitForExit(1500); } catch { }
                int code = -1;
                try { code = p.ExitCode; } catch { code = -1; }
                lock (_lock) {
                    if (Interlocked.Read(ref _generation) == gen) {
                        _lastExitCode = code;
                        _running = false;
                        _proc = null;
                        _queue.Enqueue("EXIT:" + code);
                    }
                }
            };

            _proc = p;
            _running = true;
            try {
                p.Start();
            } catch (Exception ex) {
                _running = false;
                _proc = null;
                Interlocked.Increment(ref _generation);
                try { p.Dispose(); } catch { }
                EnqueueLine("Failed to start " + fileName + ": " + ex.Message, true);
                return false;
            }

            if (!keepStdinOpen) {
                try { p.StandardInput.Close(); } catch { }
            }
            p.BeginOutputReadLine();
            p.BeginErrorReadLine();
            return true;
        }
    }

    public bool SendLine(string text) {
        lock (_lock) {
            if (_proc == null || !_running) return false;
            try {
                _proc.StandardInput.WriteLine(text ?? "");
                _proc.StandardInput.Flush();
                return true;
            } catch {
                return false;
            }
        }
    }

    private void EnqueueLine(string raw, bool isErr) {
        if (raw == null) return;
        string clean = AnsiRe.Replace(raw.Replace("\0", ""), "").Replace("\r", "");
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
        lock (_lock) {
            p = _proc;
            Interlocked.Increment(ref _generation);
            _running = false;
            _proc = null;
        }
        if (p == null) return;
        try { p.StandardInput.Close(); } catch { }
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
                try { p.WaitForExit(3000); } catch { }
            }
        } catch {
        } finally {
            try { p.Dispose(); } catch { }
        }
    }
}
'@

if (-not ('StrataProcessSlot' -as [type])) {
    Add-Type -TypeDefinition $csharpRunner -Language CSharp
}

$ConfigPath = Join-Path $RepoRoot 'config.env'
$LocalConfigPath = Join-Path $RepoRoot 'config.local.env'
$IconPath = Join-Path $ScriptDir 'strata-colab.ico'

if (-not $SmokeTest) {
    try { Write-StrataIconFile -OutPath $IconPath } catch { }
}

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Strata Colab Desktop"
        Width="1060" Height="800"
        MinWidth="880" MinHeight="640"
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
            <Setter Property="Padding" Value="12,7"/>
            <Setter Property="FontSize" Value="12.5"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="Bd" Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                CornerRadius="7" Padding="{TemplateBinding Padding}">
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
                                <Setter TargetName="Bd" Property="Opacity" Value="0.40"/>
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

        <Style x:Key="AccentOutlineBtn" TargetType="Button" BasedOn="{StaticResource ActionBtn}">
            <Setter Property="Background" Value="#0F2942"/>
            <Setter Property="BorderBrush" Value="#38BDF8"/>
            <Setter Property="Foreground" Value="#E0F2FE"/>
        </Style>

        <Style x:Key="DangerBtn" TargetType="Button" BasedOn="{StaticResource ActionBtn}">
            <Setter Property="Background" Value="#7F1D1D"/>
            <Setter Property="BorderBrush" Value="#DC2626"/>
        </Style>

        <Style x:Key="DarkToggleBtn" TargetType="ToggleButton">
            <Setter Property="Foreground" Value="#CBD5E1"/>
            <Setter Property="Background" Value="#1E293B"/>
            <Setter Property="BorderBrush" Value="#334155"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="9,4"/>
            <Setter Property="FontSize" Value="11.5"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ToggleButton">
                        <Border x:Name="Bd" Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                CornerRadius="6" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsChecked" Value="True">
                                <Setter TargetName="Bd" Property="Background" Value="#451A03"/>
                                <Setter TargetName="Bd" Property="BorderBrush" Value="#F59E0B"/>
                                <Setter Property="Foreground" Value="#FDE68A"/>
                            </Trigger>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Bd" Property="Opacity" Value="0.88"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="DarkCheck" TargetType="CheckBox">
            <Setter Property="Foreground" Value="#E2E8F0"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="VerticalContentAlignment" Value="Center"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Style.Triggers>
                <Trigger Property="IsEnabled" Value="False">
                    <Setter Property="Opacity" Value="0.45"/>
                </Trigger>
            </Style.Triggers>
        </Style>

        <Style x:Key="DarkTextBox" TargetType="TextBox">
            <Setter Property="Foreground" Value="#F8FAFC"/>
            <Setter Property="Background" Value="#1E293B"/>
            <Setter Property="BorderBrush" Value="#334155"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="8,5"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="CaretBrush" Value="#38BDF8"/>
            <Setter Property="SelectionBrush" Value="#0284C7"/>
            <Setter Property="VerticalContentAlignment" Value="Center"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="TextBox">
                        <Border x:Name="Bd" Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                CornerRadius="6">
                            <ScrollViewer x:Name="PART_ContentHost" Margin="2,0,2,0" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsKeyboardFocused" Value="True">
                                <Setter TargetName="Bd" Property="BorderBrush" Value="#38BDF8"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="DarkExpander" TargetType="Expander">
            <Setter Property="Foreground" Value="#94A3B8"/>
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Expander">
                        <Border Background="#0D1526" BorderBrush="#1E293B" BorderThickness="1" CornerRadius="8">
                            <DockPanel>
                                <ToggleButton x:Name="HeaderSite" DockPanel.Dock="Top"
                                              IsChecked="{Binding IsExpanded, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}"
                                              Cursor="Hand" Background="Transparent" BorderThickness="0">
                                    <ToggleButton.Template>
                                        <ControlTemplate TargetType="ToggleButton">
                                            <Border Background="Transparent" Padding="10,7">
                                                <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                                                    <Path x:Name="Arrow" Data="M 0 0 L 5 4 L 0 8 Z" Fill="#38BDF8"
                                                          VerticalAlignment="Center" Margin="0,0,8,0"/>
                                                    <ContentPresenter Content="{Binding Header, RelativeSource={RelativeSource AncestorType=Expander}}"
                                                                      VerticalAlignment="Center"/>
                                                </StackPanel>
                                            </Border>
                                            <ControlTemplate.Triggers>
                                                <Trigger Property="IsChecked" Value="True">
                                                    <Setter TargetName="Arrow" Property="Data" Value="M 0 2 L 8 2 L 4 7 Z"/>
                                                </Trigger>
                                            </ControlTemplate.Triggers>
                                        </ControlTemplate>
                                    </ToggleButton.Template>
                                </ToggleButton>
                                <ContentPresenter x:Name="ExpandSite" Visibility="Collapsed" Margin="10,2,10,10"/>
                            </DockPanel>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsExpanded" Value="True">
                                <Setter TargetName="ExpandSite" Property="Visibility" Value="Visible"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="DarkCombo" TargetType="ComboBox">
            <Setter Property="Foreground" Value="#F8FAFC"/>
            <Setter Property="Background" Value="#1E293B"/>
            <Setter Property="BorderBrush" Value="#334155"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="10,6"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="Height" Value="32"/>
            <Setter Property="ToolTip" Value="{Binding SelectedItem, RelativeSource={RelativeSource Self}}"/>
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
                            <TextBlock x:Name="ContentSite"
                                       IsHitTestVisible="False"
                                       Text="{TemplateBinding SelectionBoxItem}"
                                       Foreground="{TemplateBinding Foreground}"
                                       TextTrimming="CharacterEllipsis"
                                       Margin="10,0,28,0"
                                       VerticalAlignment="Center"/>
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

    <Border Background="#0B1120" Padding="16,14,16,14">
    <Grid>
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*" MinHeight="160"/>
        </Grid.RowDefinitions>

        <!-- Header -->
        <Grid Grid.Row="0" Margin="0,0,0,12">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                <Border Background="#0F172A" BorderBrush="#38BDF8" BorderThickness="1.5" CornerRadius="8"
                        Width="34" Height="34" Margin="0,0,11,0">
                    <TextBlock Text="S" FontSize="19" FontWeight="Bold" Foreground="#38BDF8"
                               HorizontalAlignment="Center" VerticalAlignment="Center"/>
                </Border>
                <StackPanel VerticalAlignment="Center">
                    <TextBlock Text="Strata Colab Desktop" FontSize="19" FontWeight="Bold" Foreground="#F8FAFC"/>
                    <TextBlock Text="Google Colab GPU Allocator, Auto-Fallback, Telemetry &amp; Local Tunnel Launcher"
                               FontSize="11.5" Foreground="#94A3B8"/>
                </StackPanel>
            </StackPanel>

            <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
                <Border x:Name="StateBadge" Background="#1E293B" BorderBrush="#334155" BorderThickness="1"
                        CornerRadius="13" Padding="11,5" Margin="0,0,8,0" VerticalAlignment="Center">
                    <TextBlock x:Name="StateBadgeText" Text="Checking status..." FontSize="12" FontWeight="SemiBold" Foreground="#38BDF8"/>
                </Border>
                <Button x:Name="BtnConnect" Content="Connect Client" Style="{StaticResource AccentOutlineBtn}" Margin="0,0,7,0"/>
                <Button x:Name="BtnRefresh" Content="Refresh" Style="{StaticResource ActionBtn}" Margin="0,0,7,0"/>
                <Button x:Name="BtnColabWeb" Content="Colab Web" Style="{StaticResource ActionBtn}"/>
            </StackPanel>
        </Grid>

        <!-- Status & Telemetry Cards -->
        <UniformGrid Grid.Row="1" Columns="4" Margin="0,0,0,12">
            <Border Background="{StaticResource CardBg}" BorderBrush="{StaticResource CardBorder}" BorderThickness="1" CornerRadius="10" Padding="13,10" Margin="0,0,9,0">
                <StackPanel>
                    <TextBlock Text="COLAB GPU RUNTIME" FontSize="10" FontWeight="SemiBold" Foreground="#64748B"/>
                    <TextBlock x:Name="CardGpuValue" Text="--" FontSize="15.5" FontWeight="Bold" Foreground="#F8FAFC" Margin="0,3,0,2" TextTrimming="CharacterEllipsis"/>
                    <TextBlock x:Name="CardGpuSub" Text="No active runtime" FontSize="11" Foreground="#94A3B8" TextTrimming="CharacterEllipsis"/>
                    <ProgressBar x:Name="VramProgressBar" Height="4" Minimum="0" Maximum="100" Value="0"
                                 Margin="0,6,0,0" Background="#1E293B" Foreground="#38BDF8" BorderThickness="0"/>
                </StackPanel>
            </Border>

            <Border Background="{StaticResource CardBg}" BorderBrush="{StaticResource CardBorder}" BorderThickness="1" CornerRadius="10" Padding="13,10" Margin="0,0,9,0">
                <StackPanel>
                    <TextBlock Text="STRATA ENGINE" FontSize="10" FontWeight="SemiBold" Foreground="#64748B"/>
                    <TextBlock x:Name="CardEngineValue" Text="--" FontSize="15.5" FontWeight="Bold" Foreground="#F8FAFC" Margin="0,3,0,2" TextTrimming="CharacterEllipsis"/>
                    <TextBlock x:Name="CardEngineSub" Text="Idle" FontSize="11" Foreground="#94A3B8" TextTrimming="CharacterEllipsis"/>
                    <TextBlock x:Name="CardEngineMeta" Text="Telemetry: auto-refresh 20s" FontSize="10" Foreground="#64748B" Margin="0,4,0,0" TextTrimming="CharacterEllipsis"/>
                </StackPanel>
            </Border>

            <Border Background="{StaticResource CardBg}" BorderBrush="{StaticResource CardBorder}" BorderThickness="1" CornerRadius="10" Padding="13,10" Margin="0,0,9,0">
                <StackPanel>
                    <TextBlock Text="LOCAL SSH TUNNEL" FontSize="10" FontWeight="SemiBold" Foreground="#64748B"/>
                    <TextBlock x:Name="CardTunnelValue" Text="--" FontSize="15.5" FontWeight="Bold" Foreground="#F8FAFC" Margin="0,3,0,2"/>
                    <TextBlock x:Name="CardTunnelSub" Text="http://localhost:8080" FontSize="11" Foreground="#94A3B8" TextTrimming="CharacterEllipsis"/>
                    <TextBlock x:Name="CardTunnelMeta" Text="OpenAI /v1 &amp; Anthropic /v1/messages" FontSize="10" Foreground="#64748B" Margin="0,4,0,0" TextTrimming="CharacterEllipsis"/>
                </StackPanel>
            </Border>

            <Border x:Name="CardCuBorder" Background="{StaticResource CardBg}" BorderBrush="{StaticResource CardBorder}" BorderThickness="1" CornerRadius="10" Padding="13,10">
                <StackPanel>
                    <TextBlock Text="COMPUTE UNITS" FontSize="10" FontWeight="SemiBold" Foreground="#64748B"/>
                    <TextBlock x:Name="CardCuValue" Text="--" FontSize="15.5" FontWeight="Bold" Foreground="#F8FAFC" Margin="0,3,0,2"/>
                    <TextBlock x:Name="CardCuSub" Text="Rate: --" FontSize="11" Foreground="#94A3B8" TextTrimming="CharacterEllipsis"/>
                    <TextBlock x:Name="CardCuMeta" Text="Session: idle" FontSize="10" Foreground="#64748B" Margin="0,4,0,0" TextTrimming="CharacterEllipsis"/>
                </StackPanel>
            </Border>
        </UniformGrid>

        <!-- Error / Setup Hint Banner -->
        <Border x:Name="ErrorBanner" Grid.Row="2" Visibility="Collapsed"
                Background="#2A1215" BorderBrush="#DC2626" BorderThickness="1"
                CornerRadius="8" Padding="12,8" Margin="0,0,0,10">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock x:Name="ErrorBannerText" Text="" Foreground="#FECACA" FontSize="12"
                           TextWrapping="Wrap" VerticalAlignment="Center" Margin="0,0,10,0"/>
                <Button x:Name="BtnDismissError" Grid.Column="1" Content="Dismiss" Style="{StaticResource ActionBtn}" Padding="9,4" FontSize="11.5"/>
            </Grid>
        </Border>

        <!-- Configuration Card -->
        <Border Grid.Row="3" Background="{StaticResource CardBg}" BorderBrush="{StaticResource CardBorder}" BorderThickness="1" CornerRadius="10" Padding="14,12" Margin="0,0,0,10">
            <Grid>
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>

                <Grid Grid.Row="0" Margin="0,0,0,10">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="1.4*"/>
                        <ColumnDefinition Width="1.95*"/>
                        <ColumnDefinition Width="0.72*"/>
                        <ColumnDefinition Width="1.15*"/>
                        <ColumnDefinition Width="1.15*"/>
                    </Grid.ColumnDefinitions>

                    <StackPanel Grid.Column="0" Margin="0,0,9,0">
                        <TextBlock Text="GPU Selection" FontSize="11" FontWeight="SemiBold" Foreground="#94A3B8" Margin="0,0,0,4"/>
                        <ComboBox x:Name="CmbGpu" Style="{StaticResource DarkCombo}"/>
                    </StackPanel>

                    <StackPanel Grid.Column="1" Margin="0,0,9,0">
                        <TextBlock Text="Strata Model" FontSize="11" FontWeight="SemiBold" Foreground="#94A3B8" Margin="0,0,0,4"/>
                        <ComboBox x:Name="CmbModel" Style="{StaticResource DarkCombo}"/>
                    </StackPanel>

                    <StackPanel Grid.Column="2" Margin="0,0,9,0">
                        <TextBlock Text="Context Tokens" FontSize="11" FontWeight="SemiBold" Foreground="#94A3B8" Margin="0,0,0,4"/>
                        <ComboBox x:Name="CmbContext" Style="{StaticResource DarkCombo}"/>
                    </StackPanel>

                    <StackPanel Grid.Column="3" Margin="0,0,9,0">
                        <TextBlock Text="UI Mode" FontSize="11" FontWeight="SemiBold" Foreground="#94A3B8" Margin="0,0,0,4"/>
                        <ComboBox x:Name="CmbUiMode" Style="{StaticResource DarkCombo}"/>
                    </StackPanel>

                    <StackPanel Grid.Column="4">
                        <TextBlock Text="Tune On Start" FontSize="11" FontWeight="SemiBold" Foreground="#94A3B8" Margin="0,0,0,4"/>
                        <ComboBox x:Name="CmbTune" Style="{StaticResource DarkCombo}"/>
                    </StackPanel>
                </Grid>

                <Grid Grid.Row="1" Margin="0,0,0,9">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <WrapPanel Orientation="Horizontal" VerticalAlignment="Center">
                        <CheckBox x:Name="ChkDrive" Content="Mount Google Drive (presets)" Style="{StaticResource DarkCheck}" Margin="0,2,14,2"/>
                        <CheckBox x:Name="ChkDriveModelCache" Content="Cache GGUF in Drive" Style="{StaticResource DarkCheck}" Margin="0,2,14,2"/>
                        <CheckBox x:Name="ChkHighMem" Content="High-RAM (auto-fallback)" Style="{StaticResource DarkCheck}" Margin="0,2,14,2"/>
                        <CheckBox x:Name="ChkMonitor" Content="Anti-idle monitor" Style="{StaticResource DarkCheck}" Margin="0,2,14,2"/>
                        <CheckBox x:Name="ChkBrowser" Content="Open browser" Style="{StaticResource DarkCheck}" Margin="0,2,14,2"/>
                        <CheckBox x:Name="ChkTray" Content="Minimize to tray" Style="{StaticResource DarkCheck}" Margin="0,2,0,2"/>
                    </WrapPanel>
                    <Button x:Name="BtnSaveConfig" Grid.Column="1" Content="Save Config" Style="{StaticResource ActionBtn}" Padding="11,5" FontSize="12"/>
                </Grid>

                <!-- Collapsible Advanced Engine & Custom HF -->
                <Expander x:Name="ExpAdvanced" Grid.Row="2" Style="{StaticResource DarkExpander}" IsExpanded="False">
                    <Expander.Header>
                        <TextBlock Text="Advanced Engine &amp; Custom HF (KV Cache, Vision, Drafter, Idle Auto-Stop, Custom GGUF)"
                                   FontSize="11.5" FontWeight="SemiBold" Foreground="#CBD5E1"/>
                    </Expander.Header>
                    <Grid Margin="0,4,0,0">
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                        </Grid.RowDefinitions>

                        <Grid Grid.Row="0" Margin="0,0,0,8">
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="1*"/>
                                <ColumnDefinition Width="1*"/>
                                <ColumnDefinition Width="1*"/>
                                <ColumnDefinition Width="1*"/>
                            </Grid.ColumnDefinitions>
                            <StackPanel Grid.Column="0" Margin="0,0,9,0">
                                <TextBlock Text="KV Cache (STRATA_KV_CACHE)" FontSize="10.5" Foreground="#94A3B8" Margin="0,0,0,3"/>
                                <ComboBox x:Name="CmbKvCache" Style="{StaticResource DarkCombo}"/>
                            </StackPanel>
                            <StackPanel Grid.Column="1" Margin="0,0,9,0">
                                <TextBlock Text="Vision (STRATA_VISION)" FontSize="10.5" Foreground="#94A3B8" Margin="0,0,0,3"/>
                                <ComboBox x:Name="CmbVision" Style="{StaticResource DarkCombo}"/>
                            </StackPanel>
                            <StackPanel Grid.Column="2" Margin="0,0,9,0">
                                <TextBlock Text="Drafter (STRATA_DRAFTER)" FontSize="10.5" Foreground="#94A3B8" Margin="0,0,0,3"/>
                                <ComboBox x:Name="CmbDrafter" Style="{StaticResource DarkCombo}"/>
                            </StackPanel>
                            <StackPanel Grid.Column="3">
                                <TextBlock Text="Idle Auto-Stop Min (0 = off)" FontSize="10.5" Foreground="#94A3B8" Margin="0,0,0,3"/>
                                <TextBox x:Name="TxtAutoStopIdle" Style="{StaticResource DarkTextBox}" Height="32" ToolTip="Minutes of idle time before auto-stopping Colab VM (0 disables)."/>
                            </StackPanel>
                        </Grid>

                        <Grid Grid.Row="1">
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="1.3*"/>
                                <ColumnDefinition Width="1.0*"/>
                                <ColumnDefinition Width="1.2*"/>
                            </Grid.ColumnDefinitions>
                            <StackPanel Grid.Column="0" Margin="0,0,9,0">
                                <TextBlock Text="Custom HF Repo (MODEL_REPO)" FontSize="10.5" Foreground="#94A3B8" Margin="0,0,0,3"/>
                                <TextBox x:Name="TxtModelRepo" Style="{StaticResource DarkTextBox}" Height="30" ToolTip="Example: unsloth/Qwen3.8-Flash-Next-GGUF (empty = official Strata models)"/>
                            </StackPanel>
                            <StackPanel Grid.Column="1" Margin="0,0,9,0">
                                <TextBlock Text="HF File Glob (MODEL_FILES)" FontSize="10.5" Foreground="#94A3B8" Margin="0,0,0,3"/>
                                <TextBox x:Name="TxtModelFiles" Style="{StaticResource DarkTextBox}" Height="30" ToolTip="Optional glob pattern, e.g. *IQ3_S*.gguf"/>
                            </StackPanel>
                            <StackPanel Grid.Column="2">
                                <TextBlock Text="Extra Engine Args (STRATA_EXTRA_ARGS)" FontSize="10.5" Foreground="#94A3B8" Margin="0,0,0,3"/>
                                <TextBox x:Name="TxtExtraArgs" Style="{StaticResource DarkTextBox}" Height="30" ToolTip="Extra flags forwarded to Strata setup.sh"/>
                            </StackPanel>
                        </Grid>
                    </Grid>
                </Expander>
            </Grid>
        </Border>

        <!-- Action Toolbar -->
        <Grid Grid.Row="4" Margin="0,0,0,10">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <WrapPanel Orientation="Horizontal">
                <Button x:Name="BtnStart" Content="Start Session" Style="{StaticResource PrimaryBtn}" Margin="0,0,7,4"/>
                <Button x:Name="BtnOpenUi" Content="Open Strata UI" Style="{StaticResource ActionBtn}" Margin="0,0,7,4" IsEnabled="False"/>
                <Button x:Name="BtnTune" Content="Auto-Tune" Style="{StaticResource ActionBtn}" Margin="0,0,7,4"/>
                <Button x:Name="BtnRestart" Content="Restart Strata" Style="{StaticResource ActionBtn}" Margin="0,0,7,4"/>
                <Button x:Name="BtnDetach" Content="Detach Tunnel" Style="{StaticResource ActionBtn}" Margin="0,0,7,4" IsEnabled="False"/>
                <Button x:Name="BtnStopVm" Content="Stop VM &amp; Save CU" Style="{StaticResource DangerBtn}" Margin="0,0,7,4"/>
            </WrapPanel>

            <WrapPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Top">
                <Button x:Name="BtnOpenSsh" Content="Open SSH" Style="{StaticResource ActionBtn}" Padding="10,7" FontSize="12" Margin="0,0,6,4"/>
                <Button x:Name="BtnRemoteLogs" Content="Remote Logs" Style="{StaticResource ActionBtn}" Padding="10,7" FontSize="12" Margin="0,0,6,4"/>
                <Button x:Name="BtnExportDiag" Content="Export Diagnostics" Style="{StaticResource ActionBtn}" Padding="10,7" FontSize="12" Margin="0,0,0,4"/>
            </WrapPanel>
        </Grid>

        <!-- Drive OAuth Banner -->
        <Border x:Name="AuthBanner" Grid.Row="5" Visibility="Collapsed"
                Background="#1F160A" BorderBrush="#F59E0B" BorderThickness="1"
                CornerRadius="8" Padding="12,9" Margin="0,0,0,10">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock Text="Google Drive authorization opened in your browser. Click Allow in Google, then click Continue."
                           Foreground="#FDE68A" FontSize="12" FontWeight="SemiBold"
                           VerticalAlignment="Center" TextWrapping="Wrap" Margin="0,0,12,0"/>
                <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
                    <Button x:Name="BtnAuthContinue" Content="I've Granted Access - Continue" Style="{StaticResource PrimaryBtn}" Padding="11,6" FontSize="12" Margin="0,0,7,0"/>
                    <Button x:Name="BtnAuthOpen" Content="Open Auth Page" Style="{StaticResource ActionBtn}" Padding="9,6" FontSize="12" Margin="0,0,6,0"/>
                    <Button x:Name="BtnAuthCopy" Content="Copy URL" Style="{StaticResource ActionBtn}" Padding="9,6" FontSize="12"/>
                </StackPanel>
            </Grid>
        </Border>

        <!-- Console Output Panel -->
        <Border Grid.Row="6" Background="#070B14" BorderBrush="{StaticResource CardBorder}" BorderThickness="1" CornerRadius="10" Padding="10,8" MinHeight="160">
            <Grid>
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="*"/>
                </Grid.RowDefinitions>

                <Grid Grid.Row="0" Margin="0,0,0,7">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                        <TextBlock Text="LIVE CONSOLE" FontSize="10.5" FontWeight="Bold" Foreground="#64748B" VerticalAlignment="Center"/>
                        <TextBlock x:Name="TxtLogCount" Text="0 lines" FontSize="11" Foreground="#475569" Margin="10,0,0,0" VerticalAlignment="Center"/>
                    </StackPanel>
                    <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
                        <TextBlock Text="Filter:" FontSize="11.5" Foreground="#94A3B8" VerticalAlignment="Center" Margin="0,0,6,0"/>
                        <TextBox x:Name="TxtLogFilter" Style="{StaticResource DarkTextBox}" Width="175" Height="26" FontSize="11.5" Margin="0,0,4,0" ToolTip="Filter live console output (case-insensitive)"/>
                        <Button x:Name="BtnClearFilter" Content="x" Style="{StaticResource ActionBtn}" Padding="7,3" FontSize="11" Margin="0,0,8,0" ToolTip="Clear log filter"/>
                        <ToggleButton x:Name="BtnPauseScroll" Content="Pause Scroll" Style="{StaticResource DarkToggleBtn}" Margin="0,0,6,0"/>
                        <Button x:Name="BtnCopyLog" Content="Copy" Style="{StaticResource ActionBtn}" Padding="9,4" FontSize="11.5" Margin="0,0,6,0"/>
                        <Button x:Name="BtnClearLog" Content="Clear" Style="{StaticResource ActionBtn}" Padding="9,4" FontSize="11.5"/>
                    </StackPanel>
                </Grid>

                <TextBox x:Name="TxtLog" Grid.Row="1"
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
            </Grid>
        </Border>
    </Grid>
    </Border>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [System.Windows.Markup.XamlReader]::Load($reader)

if (-not $SmokeTest -and (Test-Path -LiteralPath $IconPath)) {
    try {
        $window.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create([Uri]::new($IconPath))
    } catch { }
}

# Bind Controls
$StateBadge = $window.FindName('StateBadge')
$StateBadgeText = $window.FindName('StateBadgeText')
$BtnConnect = $window.FindName('BtnConnect')
$BtnRefresh = $window.FindName('BtnRefresh')
$BtnColabWeb = $window.FindName('BtnColabWeb')
$CardGpuValue = $window.FindName('CardGpuValue')
$CardGpuSub = $window.FindName('CardGpuSub')
$VramProgressBar = $window.FindName('VramProgressBar')
$CardEngineValue = $window.FindName('CardEngineValue')
$CardEngineSub = $window.FindName('CardEngineSub')
$CardEngineMeta = $window.FindName('CardEngineMeta')
$CardTunnelValue = $window.FindName('CardTunnelValue')
$CardTunnelSub = $window.FindName('CardTunnelSub')
$CardTunnelMeta = $window.FindName('CardTunnelMeta')
$CardCuBorder = $window.FindName('CardCuBorder')
$CardCuValue = $window.FindName('CardCuValue')
$CardCuSub = $window.FindName('CardCuSub')
$CardCuMeta = $window.FindName('CardCuMeta')
$ErrorBanner = $window.FindName('ErrorBanner')
$ErrorBannerText = $window.FindName('ErrorBannerText')
$BtnDismissError = $window.FindName('BtnDismissError')
$CmbGpu = $window.FindName('CmbGpu')
$CmbModel = $window.FindName('CmbModel')
$CmbContext = $window.FindName('CmbContext')
$CmbUiMode = $window.FindName('CmbUiMode')
$CmbTune = $window.FindName('CmbTune')
$ChkDrive = $window.FindName('ChkDrive')
$ChkDriveModelCache = $window.FindName('ChkDriveModelCache')
$ChkHighMem = $window.FindName('ChkHighMem')
$ChkMonitor = $window.FindName('ChkMonitor')
$ChkBrowser = $window.FindName('ChkBrowser')
$ChkTray = $window.FindName('ChkTray')
$BtnSaveConfig = $window.FindName('BtnSaveConfig')
$ExpAdvanced = $window.FindName('ExpAdvanced')
$CmbKvCache = $window.FindName('CmbKvCache')
$CmbVision = $window.FindName('CmbVision')
$CmbDrafter = $window.FindName('CmbDrafter')
$TxtAutoStopIdle = $window.FindName('TxtAutoStopIdle')
$TxtModelRepo = $window.FindName('TxtModelRepo')
$TxtModelFiles = $window.FindName('TxtModelFiles')
$TxtExtraArgs = $window.FindName('TxtExtraArgs')
$BtnStart = $window.FindName('BtnStart')
$BtnOpenUi = $window.FindName('BtnOpenUi')
$BtnTune = $window.FindName('BtnTune')
$BtnRestart = $window.FindName('BtnRestart')
$BtnDetach = $window.FindName('BtnDetach')
$BtnStopVm = $window.FindName('BtnStopVm')
$BtnOpenSsh = $window.FindName('BtnOpenSsh')
$BtnRemoteLogs = $window.FindName('BtnRemoteLogs')
$BtnExportDiag = $window.FindName('BtnExportDiag')
$AuthBanner = $window.FindName('AuthBanner')
$BtnAuthContinue = $window.FindName('BtnAuthContinue')
$BtnAuthOpen = $window.FindName('BtnAuthOpen')
$BtnAuthCopy = $window.FindName('BtnAuthCopy')
$TxtLogCount = $window.FindName('TxtLogCount')
$TxtLogFilter = $window.FindName('TxtLogFilter')
$BtnClearFilter = $window.FindName('BtnClearFilter')
$BtnPauseScroll = $window.FindName('BtnPauseScroll')
$BtnCopyLog = $window.FindName('BtnCopyLog')
$BtnClearLog = $window.FindName('BtnClearLog')
$TxtLog = $window.FindName('TxtLog')

# Option tables (mutable Lists so unknown/custom config values are preserved dynamically)
$GpuOptions = New-Object System.Collections.Generic.List[hashtable]
@(
    @{ Label = 'AUTO (Best Available GPU)'; Value = 'AUTO' },
    @{ Label = 'G4 (RTX PRO 6000 98 GB)'; Value = 'G4' },
    @{ Label = 'H100 (80 GB VRAM)'; Value = 'H100' },
    @{ Label = 'A100 (40-80 GB VRAM)'; Value = 'A100' },
    @{ Label = 'L4 (23 GB VRAM)'; Value = 'L4' },
    @{ Label = 'T4 (15 GB VRAM)'; Value = 'T4' }
) | ForEach-Object { $GpuOptions.Add($_) }

$ModelOptions = New-Object System.Collections.Generic.List[hashtable]
@(
    @{ Label = 'AUTO (Match GPU Memory)'; Model = 'AUTO'; Family = '' },
    @{ Label = 'Qwen3.8-Flash [NVFP4] (G4 Blackwell)'; Model = 'NVFP4'; Family = 'nvfp4' },
    @{ Label = 'Qwen3.8-Flash [IQ3_S] (G4/H100/A100)'; Model = 'IQ3_S'; Family = '' },
    @{ Label = 'Qwen3.8-Flash [IQ2_XS] (L4/A100)'; Model = 'IQ2_XS'; Family = '' },
    @{ Label = 'Qwen3.8-Flash [Q2_0] (Fast Flash)'; Model = 'Q2_0'; Family = '' },
    @{ Label = 'Qwen3.8-Coder [IQ1_M] (Coding)'; Model = 'IQ1_M'; Family = 'coder' },
    @{ Label = 'Qwen3.6-35B [UD-Q4_K_XL] (T4/L4)'; Model = 'UD-Q4_K_XL'; Family = 'qwen36' }
) | ForEach-Object { $ModelOptions.Add($_) }

$ContextOptions = New-Object System.Collections.Generic.List[string]
@('8192', '16384', '32768', '65536', '131072', '262144') | ForEach-Object { $ContextOptions.Add($_) }

$UiModeOptions = @(
    @{ Label = 'desktop (Strata Web UI)'; Value = 'desktop' },
    @{ Label = 'cli (Headless OpenAI API)'; Value = 'cli' }
)
$TuneOptions = @(
    @{ Label = '0 - Fast start (load preset)'; Value = '0' },
    @{ Label = '1 - Auto-Tune on start'; Value = '1' }
)

$KvOptions = New-Object System.Collections.Generic.List[hashtable]
@(
    @{ Label = 'Default (auto)'; Value = '' },
    @{ Label = 'int8'; Value = 'int8' },
    @{ Label = 'q4_0'; Value = 'q4_0' },
    @{ Label = 'k8v4'; Value = 'k8v4' },
    @{ Label = 'fp16'; Value = 'fp16' }
) | ForEach-Object { $KvOptions.Add($_) }

$VisionOptions = New-Object System.Collections.Generic.List[hashtable]
@(
    @{ Label = 'Default (auto)'; Value = '' },
    @{ Label = 'yes'; Value = 'yes' },
    @{ Label = 'no'; Value = 'no' },
    @{ Label = 'none'; Value = 'none' },
    @{ Label = 'gpu'; Value = 'gpu' },
    @{ Label = 'cpu'; Value = 'cpu' }
) | ForEach-Object { $VisionOptions.Add($_) }

$DrafterOptions = New-Object System.Collections.Generic.List[hashtable]
@(
    @{ Label = 'Default (auto)'; Value = '' },
    @{ Label = 'mtp'; Value = 'mtp' },
    @{ Label = 'dflash2'; Value = 'dflash2' }
) | ForEach-Object { $DrafterOptions.Add($_) }

foreach ($o in $GpuOptions) { $null = $CmbGpu.Items.Add($o.Label) }
foreach ($o in $ModelOptions) { $null = $CmbModel.Items.Add($o.Label) }
foreach ($c in $ContextOptions) { $null = $CmbContext.Items.Add($c) }
foreach ($o in $UiModeOptions) { $null = $CmbUiMode.Items.Add($o.Label) }
foreach ($o in $TuneOptions) { $null = $CmbTune.Items.Add($o.Label) }
foreach ($o in $KvOptions) { $null = $CmbKvCache.Items.Add($o.Label) }
foreach ($o in $VisionOptions) { $null = $CmbVision.Items.Add($o.Label) }
foreach ($o in $DrafterOptions) { $null = $CmbDrafter.Items.Add($o.Label) }

function Select-OrAddOption {
    param(
        [System.Windows.Controls.ComboBox]$Combo,
        [System.Collections.Generic.List[hashtable]]$OptionsList,
        [string]$Value,
        [string]$CustomPrefix = 'Custom'
    )
    $val = if ($null -eq $Value) { '' } else { $Value.Trim() }
    for ($i = 0; $i -lt $OptionsList.Count; $i++) {
        if ($OptionsList[$i].Value -ieq $val) {
            $Combo.SelectedIndex = $i
            return
        }
    }
    $label = if ($val) { "${CustomPrefix}: $val" } else { 'Default (auto)' }
    $OptionsList.Add(@{ Label = $label; Value = $val })
    $null = $Combo.Items.Add($label)
    $Combo.SelectedIndex = $OptionsList.Count - 1
}

# Load current config.env + config.local.env values
$cfg = Read-StrataConfig -ConfigPath $ConfigPath -LocalConfigPath $LocalConfigPath
$script:LocalPort = if ($cfg['LOCAL_PORT']) { $cfg['LOCAL_PORT'] } else { '8080' }
$script:ApiKey = if ($cfg['API_KEY']) { $cfg['API_KEY'] } else { '' }
$CardTunnelSub.Text = "http://localhost:$($script:LocalPort)"

$cfgGpu = if ($cfg['GPU']) { $cfg['GPU'].ToUpper() } else { 'AUTO' }
Select-OrAddOption -Combo $CmbGpu -OptionsList $GpuOptions -Value $cfgGpu -CustomPrefix 'Custom GPU'

# Dynamically preserve unknown/custom MODEL/MODEL_FAMILY values (never silently overwrite to AUTO)
$cfgModel = if ($cfg['MODEL']) { $cfg['MODEL'].Trim() } else { 'AUTO' }
$cfgFamily = if ($cfg['MODEL_FAMILY']) { $cfg['MODEL_FAMILY'].Trim() } else { '' }
$modelIdx = -1
for ($i = 0; $i -lt $ModelOptions.Count; $i++) {
    if ($ModelOptions[$i].Model -ieq $cfgModel -and $ModelOptions[$i].Family -ieq $cfgFamily) {
        $modelIdx = $i
        break
    }
}
if ($modelIdx -lt 0) {
    $customLabel = if ($cfgFamily) { "Custom: $cfgFamily / $cfgModel" } else { "Custom: $cfgModel" }
    $ModelOptions.Add(@{ Label = $customLabel; Model = $cfgModel; Family = $cfgFamily })
    $null = $CmbModel.Items.Add($customLabel)
    $modelIdx = $ModelOptions.Count - 1
}
$CmbModel.SelectedIndex = $modelIdx

$cfgCtx = if ($cfg['CONTEXT']) { $cfg['CONTEXT'].Trim() } else { '262144' }
$ctxIdx = $ContextOptions.IndexOf($cfgCtx)
if ($ctxIdx -lt 0) {
    $ContextOptions.Add($cfgCtx)
    $null = $CmbContext.Items.Add($cfgCtx)
    $ctxIdx = $CmbContext.Items.Count - 1
}
$CmbContext.SelectedIndex = $ctxIdx

$cfgUi = if ($cfg['UI_MODE']) { $cfg['UI_MODE'].ToLower() } else { 'desktop' }
$CmbUiMode.SelectedIndex = if ($cfgUi -eq 'cli') { 1 } else { 0 }

$cfgTune = if ($cfg['TUNE_ON_START']) { $cfg['TUNE_ON_START'].Trim() } else { '0' }
$CmbTune.SelectedIndex = if ($cfgTune -eq '1') { 1 } else { 0 }

$ChkDrive.IsChecked = ($cfg['USE_DRIVE'] -ne '0')
$ChkDriveModelCache.IsChecked = ($cfg['DRIVE_MODEL_CACHE'] -eq '1')
$ChkDriveModelCache.IsEnabled = [bool]$ChkDrive.IsChecked
$ChkHighMem.IsChecked = ($cfg['HIGH_MEM'] -ne '0')
$ChkMonitor.IsChecked = ($cfg['ACTIVE_WORKLOAD_MONITOR'] -ne '0')
$ChkBrowser.IsChecked = ($cfg['OPEN_BROWSER'] -ne '0')
$ChkTray.IsChecked = $true

# Load Advanced Engine & Custom HF fields
Select-OrAddOption -Combo $CmbKvCache -OptionsList $KvOptions -Value ([string]$cfg['STRATA_KV_CACHE']) -CustomPrefix 'Custom'
Select-OrAddOption -Combo $CmbVision -OptionsList $VisionOptions -Value ([string]$cfg['STRATA_VISION']) -CustomPrefix 'Custom'
Select-OrAddOption -Combo $CmbDrafter -OptionsList $DrafterOptions -Value ([string]$cfg['STRATA_DRAFTER']) -CustomPrefix 'Custom'
$TxtAutoStopIdle.Text = if ($cfg['AUTO_STOP_IDLE_MIN']) { $cfg['AUTO_STOP_IDLE_MIN'] } else { '0' }
$TxtModelRepo.Text = if ($cfg['MODEL_REPO']) { $cfg['MODEL_REPO'] } else { '' }
$TxtModelFiles.Text = if ($cfg['MODEL_FILES']) { $cfg['MODEL_FILES'] } else { '' }
$TxtExtraArgs.Text = if ($cfg['STRATA_EXTRA_ARGS']) { $cfg['STRATA_EXTRA_ARGS'] } else { '' }

# Auto-expand Advanced panel if any custom HF or engine override is already active
if ($TxtModelRepo.Text -or $TxtModelFiles.Text -or $TxtExtraArgs.Text -or
    ($CmbKvCache.SelectedIndex -gt 0) -or ($CmbVision.SelectedIndex -gt 0) -or
    ($CmbDrafter.SelectedIndex -gt 0) -or ($TxtAutoStopIdle.Text -and $TxtAutoStopIdle.Text -ne '0')) {
    $ExpAdvanced.IsExpanded = $true
}

# Shared UI Brush Helper
$script:BrushConverter = New-Object System.Windows.Media.BrushConverter
function Get-Brush {
    param([string]$Hex)
    return $script:BrushConverter.ConvertFromString($Hex)
}

function Set-Badge {
    param([string]$Text, [string]$ColorHex)
    $StateBadgeText.Text = $Text
    $StateBadgeText.Foreground = Get-Brush $ColorHex
}

# Console state (batched + 4,000-line cap + live filter + pause auto-scroll)
$script:MaxLogLines = 4000
$script:LogLines = New-Object System.Collections.Generic.List[string]
$script:PauseAutoScroll = $false
$script:LogFilter = ''

function Update-LogCountLabel {
    param([int]$VisibleCount = -1)
    $total = $script:LogLines.Count
    if ([string]::IsNullOrWhiteSpace($script:LogFilter)) {
        $TxtLogCount.Text = "$total lines"
    } else {
        if ($VisibleCount -lt 0) {
            $VisibleCount = 0
            foreach ($ln in $script:LogLines) {
                if ($ln.IndexOf($script:LogFilter, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                    $VisibleCount++
                }
            }
        }
        $TxtLogCount.Text = "$VisibleCount / $total lines (filtered)"
    }
}

function Refresh-LogView {
    $sb = New-Object System.Text.StringBuilder
    $flt = $script:LogFilter
    $hasFilter = -not [string]::IsNullOrWhiteSpace($flt)
    $shown = 0
    foreach ($ln in $script:LogLines) {
        if (-not $hasFilter -or $ln.IndexOf($flt, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            $null = $sb.Append($ln)
            $null = $sb.Append("`r`n")
            $shown++
        }
    }
    $TxtLog.Text = $sb.ToString()
    Update-LogCountLabel -VisibleCount $shown
    if (-not $script:PauseAutoScroll) {
        $TxtLog.ScrollToEnd()
    }
}

function Append-LogBatch {
    param([string[]]$Lines)
    if ($null -eq $Lines -or $Lines.Count -eq 0) { return }
    $ts = (Get-Date).ToString('HH:mm:ss')
    $flt = $script:LogFilter
    $hasFilter = -not [string]::IsNullOrWhiteSpace($flt)
    $sb = New-Object System.Text.StringBuilder

    foreach ($raw in $Lines) {
        if ($null -eq $raw) { continue }
        $formatted = "[$ts] $raw"
        $script:LogLines.Add($formatted)
        if (-not $hasFilter -or $formatted.IndexOf($flt, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            $null = $sb.Append($formatted)
            $null = $sb.Append("`r`n")
        }
    }

    if ($script:LogLines.Count -gt $script:MaxLogLines) {
        $excess = $script:LogLines.Count - $script:MaxLogLines
        $script:LogLines.RemoveRange(0, $excess)
        Refresh-LogView
        return
    }

    if ($sb.Length -gt 0) {
        $TxtLog.AppendText($sb.ToString())
        if (-not $script:PauseAutoScroll) {
            $TxtLog.ScrollToEnd()
        }
    }
    Update-LogCountLabel
}

function Append-Log {
    param([string]$Line)
    if ($null -eq $Line) { return }
    Append-LogBatch -Lines @($Line)
}

# SmokeTest mode: renders & closes without tray icon or WSL calls
if ($SmokeTest) {
    $window.ShowActivated = $false
    $window.ShowInTaskbar = $false
    $window.Add_ContentRendered({ $window.Close() })
    $null = $window.ShowDialog()
    Write-Output 'SMOKE_TEST_OK'
    exit 0
}

# CaptureScreenshot mode: populates clean sample telemetry/config state, saves full-window PNG, closes cleanly
if (-not [string]::IsNullOrWhiteSpace($CaptureScreenshot)) {
    Set-Badge 'Tunnel Active' '#22C55E'
    $CardGpuValue.Text = 'NVIDIA RTX PRO 6000'
    $CardGpuSub.Text = 'VRAM: 64.2 / 98.0 GB | 74% | 58 C'
    $VramProgressBar.Value = 65.5
    $VramProgressBar.Foreground = Get-Brush '#38BDF8'
    $CardEngineValue.Text = 'RUNNING'
    $CardEngineValue.Foreground = Get-Brush '#22C55E'
    $CardEngineSub.Text = 'Model: nvfp4-nvfp4 | Drive: synced'
    $CardEngineMeta.Text = 'Workload monitor: active | Auto-refresh 20s'
    $CardTunnelValue.Text = 'Connected'
    $CardTunnelValue.Foreground = Get-Brush '#22C55E'
    $CardTunnelSub.Text = "http://localhost:$($script:LocalPort)"
    $CardCuValue.Text = '86.40 CU'
    $CardCuSub.Text = 'Rate: 7.40/hr | Eligible: G4 H100 A100 L4 T4'
    $CardCuMeta.Text = 'Session: 00:38 (~4.69 CU est.)'

    # Select NVFP4 preset for screenshot showcase if present
    for ($i = 0; $i -lt $ModelOptions.Count; $i++) {
        if ($ModelOptions[$i].Model -eq 'NVFP4') {
            $CmbModel.SelectedIndex = $i
            break
        }
    }
    $BtnOpenUi.IsEnabled = $true
    $BtnDetach.IsEnabled = $true

    Append-LogBatch -Lines @(
        "Strata Colab Desktop ready. Repository: $RepoRoot"
        '=== Starting Session (up.sh) ==='
        '[STRATA_STATE:probing:G4] Probing G4 (RTX PRO 6000 Blackwell)...'
        'Allocated G4 (HIGH_RAM shape). Verifying SSH tunnel...'
        'Google Drive mounted (presets & configs restored in 0.4s).'
        '[STRATA_STATE:starting] Starting Strata (NVFP4 native Blackwell FP4, 262144 ctx)...'
        'Strata is ready! [STRATA_STATE:tunnel_ready]'
        "Strata Desktop / WebUI : http://localhost:$($script:LocalPort)"
        "OpenAI-Compatible API  : http://localhost:$($script:LocalPort)/v1"
        "Anthropic Messages API : http://localhost:$($script:LocalPort)"
        'Telemetry refresh: 64.2 / 98.0 GB VRAM used, GPU 74%, 58 C, 86.40 CU remaining.'
    )

    $window.ShowActivated = $false
    $window.ShowInTaskbar = $false
    $window.Add_ContentRendered({
        $window.Dispatcher.Invoke([Action]{
            $window.UpdateLayout()
            $target = $window.Content
            $w = [int][Math]::Ceiling($target.ActualWidth)
            $h = [int][Math]::Ceiling($target.ActualHeight)
            if ($w -lt 100) { $w = 1060 }
            if ($h -lt 100) { $h = 800 }

            $dv = New-Object System.Windows.Media.DrawingVisual
            $dc = $dv.RenderOpen()
            try {
                $dc.DrawRectangle((Get-Brush '#0B1120'), $null, (New-Object System.Windows.Rect(0, 0, $w, $h)))
                $vb = New-Object System.Windows.Media.VisualBrush($target)
                $dc.DrawRectangle($vb, $null, (New-Object System.Windows.Rect(0, 0, $w, $h)))
            } finally {
                $dc.Close()
            }

            $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($w, $h, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
            $rtb.Render($dv)

            $outParent = Split-Path -Parent $CaptureScreenshot
            if ($outParent -and -not (Test-Path -LiteralPath $outParent)) {
                New-Item -ItemType Directory -Path $outParent -Force | Out-Null
            }
            $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
            $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
            $fs = [System.IO.File]::Open($CaptureScreenshot, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
            try {
                $enc.Save($fs)
            } finally {
                $fs.Dispose()
            }
            $window.Close()
        }, [System.Windows.Threading.DispatcherPriority]::ContextIdle)
    })
    $null = $window.ShowDialog()
    Write-Output "SCREENSHOT_OK: $CaptureScreenshot"
    exit 0
}

# Process Slots & Live Runtime State
$script:SessionSlot = New-Object StrataProcessSlot 'session'
$script:AuxSlot = New-Object StrataProcessSlot 'aux'
$script:StatusSlot = New-Object StrataProcessSlot 'status'
$script:StatusOutBuffer = New-Object System.Collections.Generic.List[string]
$script:StatusErrBuffer = New-Object System.Collections.Generic.List[string]
$script:ActiveMode = ''
$script:AuxMode = ''
$script:HasActiveRuntime = $false
$script:TunnelConnected = $false
$script:ForceClosing = $false
$script:PendingAuthUrl = ''
$script:SessionStartedAt = $null
$script:LastCuRate = $null
$script:LastActiveModel = ''
$script:LastStatusSnapshot = $null
$script:TrayMinimizeNotified = $false

# Local WSL cleanup command (uses [b]ash / [c]olab trick so pkill never kills itself)
$script:WslCleanupCmd = "pkill -TERM -f '[b]ash \./up\.sh' 2>/dev/null || true; pkill -TERM -f '[b]ash \./restart\.sh' 2>/dev/null || true; pkill -TERM -f '[c]olab-helper\.py' 2>/dev/null || true; pkill -TERM -f '[c]olab drivemount -s' 2>/dev/null || true; source ./lib/common.sh 2>/dev/null && stop_tunnel 2>/dev/null || true"

function Invoke-WslCleanupSync {
    param([int]$TimeoutMs = 8000)
    try {
        $wslArgs = Build-WslArgs -BashCommand $script:WslCleanupCmd -RepoRoot $RepoRoot -Distro ([string]$env:STRATA_WSL_DISTRO)
        $p = Start-Process -FilePath 'wsl.exe' -ArgumentList $wslArgs -WindowStyle Hidden -PassThru
        if ($p) {
            $null = $p.WaitForExit($TimeoutMs)
            try { $p.Dispose() } catch { }
        }
    } catch { }
}

function Show-TrayBalloon {
    param(
        [string]$Title,
        [string]$Body,
        [ValidateSet('Info', 'Warning', 'Error', 'None')]
        [string]$Icon = 'Info'
    )
    if ($null -eq $script:NotifyIcon) { return }
    if ([string]::IsNullOrWhiteSpace($Body)) { return }
    try {
        $tipIcon = switch ($Icon) {
            'Warning' { [System.Windows.Forms.ToolTipIcon]::Warning }
            'Error'   { [System.Windows.Forms.ToolTipIcon]::Error }
            'None'    { [System.Windows.Forms.ToolTipIcon]::None }
            default   { [System.Windows.Forms.ToolTipIcon]::Info }
        }
        $safeBody = if ($Body.Length -gt 240) { $Body.Substring(0, 237) + '...' } else { $Body }
        $script:NotifyIcon.ShowBalloonTip(5000, $Title, $safeBody, $tipIcon)
    } catch { }
}

function Get-UiSelection {
    $gpuVal = $GpuOptions[$CmbGpu.SelectedIndex].Value
    $mOpt = $ModelOptions[$CmbModel.SelectedIndex]
    $ctxVal = [string]$CmbContext.SelectedItem
    $uiVal = $UiModeOptions[$CmbUiMode.SelectedIndex].Value
    $tuneVal = $TuneOptions[$CmbTune.SelectedIndex].Value
    $kvVal = $KvOptions[$CmbKvCache.SelectedIndex].Value
    $visVal = $VisionOptions[$CmbVision.SelectedIndex].Value
    $draftVal = $DrafterOptions[$CmbDrafter.SelectedIndex].Value

    $idleRaw = $TxtAutoStopIdle.Text.Trim()
    $idleVal = if ($idleRaw -match '^\d+$') { $idleRaw } else { '0' }

    $driveOn = [bool]$ChkDrive.IsChecked
    $driveCacheVal = if ($driveOn -and $ChkDriveModelCache.IsChecked) { '1' } else { '0' }

    return @{
        GPU                     = $gpuVal
        MODEL                   = $mOpt.Model
        MODEL_FAMILY            = $mOpt.Family
        CONTEXT                 = $ctxVal
        UI_MODE                 = $uiVal
        TUNE_ON_START           = $tuneVal
        USE_DRIVE               = if ($driveOn) { '1' } else { '0' }
        DRIVE_MODEL_CACHE       = $driveCacheVal
        HIGH_MEM                = if ($ChkHighMem.IsChecked) { '1' } else { '0' }
        ACTIVE_WORKLOAD_MONITOR = if ($ChkMonitor.IsChecked) { '1' } else { '0' }
        OPEN_BROWSER            = if ($ChkBrowser.IsChecked) { '1' } else { '0' }
        STRATA_KV_CACHE         = $kvVal
        STRATA_VISION           = $visVal
        STRATA_DRAFTER          = $draftVal
        AUTO_STOP_IDLE_MIN      = $idleVal
        MODEL_REPO              = $TxtModelRepo.Text.Trim()
        MODEL_FILES             = $TxtModelFiles.Text.Trim()
        STRATA_EXTRA_ARGS       = $TxtExtraArgs.Text.Trim()
    }
}

function Update-ButtonStates {
    $sessBusy = $script:SessionSlot.IsRunning
    $auxBusy = $script:AuxSlot.IsRunning
    $uiMode = if ($CmbUiMode.SelectedIndex -ge 0) { $UiModeOptions[$CmbUiMode.SelectedIndex].Value } else { 'desktop' }
    $tunnelUp = ($script:TunnelConnected -or ($script:ActiveMode -eq 'tunnel'))

    $BtnStart.IsEnabled = (-not $sessBusy)
    $BtnOpenUi.IsEnabled = ($tunnelUp -and $uiMode -ne 'cli')
    $BtnDetach.IsEnabled = ($sessBusy -or $auxBusy)
    $BtnRestart.IsEnabled = ((-not $sessBusy) -or ($script:ActiveMode -eq 'tunnel'))
    $BtnTune.IsEnabled = (-not $auxBusy)
    $BtnStopVm.IsEnabled = $true
    $BtnRemoteLogs.Content = if ($auxBusy -and $script:AuxMode -eq 'logs') { 'Stop Logs' } else { 'Remote Logs' }
    $BtnRemoteLogs.IsEnabled = ((-not $auxBusy) -or ($script:AuxMode -eq 'logs'))

    if ($null -ne $script:TrayOpenUiItem) {
        $script:TrayOpenUiItem.Enabled = $BtnOpenUi.IsEnabled
    }
}

function Update-SessionBurnDisplay {
    if ($null -ne $script:SessionStartedAt) {
        $elapsed = (Get-Date) - $script:SessionStartedAt
        $hh = [int][Math]::Floor($elapsed.TotalHours)
        $mm = $elapsed.Minutes
        $elapsedStr = ('{0:D2}:{1:D2}' -f $hh, $mm)
        if ($null -ne $script:LastCuRate -and $script:LastCuRate -gt 0) {
            $estBurn = $elapsed.TotalHours * $script:LastCuRate
            $CardCuMeta.Text = ('Session: {0} (~{1:F2} CU est.)' -f $elapsedStr, $estBurn)
        } else {
            $CardCuMeta.Text = "Session: $elapsedStr elapsed"
        }
    } else {
        $CardCuMeta.Text = 'Session: idle'
    }
}

function Apply-StatusOutput {
    param(
        [string[]]$OutLines,
        [string[]]$ErrLines
    )
    $allLines = New-Object System.Collections.Generic.List[string]
    foreach ($l in $OutLines) { $allLines.Add($l) }
    foreach ($l in $ErrLines) { $allLines.Add($l) }

    $st = Parse-StatusPayload -Lines $allLines.ToArray()
    $script:LastStatusSnapshot = $st

    if ($st.error_hint) {
        $ErrorBannerText.Text = "WSL / Colab status issue: $($st.error_hint)"
        $ErrorBanner.Visibility = 'Visible'
    } elseif ($st.source -ne 'empty') {
        $ErrorBanner.Visibility = 'Collapsed'
    }

    if ($null -ne $st.local_port -and $st.local_port -gt 0) {
        $script:LocalPort = [string]$st.local_port
    }
    if ($st.tunnel_url) {
        $CardTunnelSub.Text = $st.tunnel_url
    } else {
        $CardTunnelSub.Text = "http://localhost:$($script:LocalPort)"
    }

    # Card 4: Compute Units & Session Burn
    if ($null -ne $st.cu_balance) {
        $CardCuValue.Text = ('{0:F2} CU' -f $st.cu_balance)
    }
    if ($null -ne $st.cu_rate) {
        $script:LastCuRate = $st.cu_rate
    }
    $cuParts = New-Object System.Collections.Generic.List[string]
    if ($null -ne $st.cu_rate) {
        $cuParts.Add(('Rate: {0:F2}/hr' -f $st.cu_rate))
    }
    if ($st.eligible_gpus.Count -gt 0) {
        $cuParts.Add("Eligible: $($st.eligible_gpus -join ' ')")
    }
    if ($cuParts.Count -gt 0) {
        $CardCuSub.Text = ($cuParts -join ' | ')
    }
    $CardCuBorder.ToolTip = "Last status refresh: $((Get-Date).ToString('HH:mm:ss')) (source: $($st.source))"

    # Card 1: Colab GPU Runtime & Live VRAM/Util/Temp
    if ($st.gpu_name) {
        $script:HasActiveRuntime = $true
        $CardGpuValue.Text = $st.gpu_name
        $gpuSubParts = New-Object System.Collections.Generic.List[string]
        if ($null -ne $st.vram_used_mib -and $null -ne $st.vram_total_mib -and $st.vram_total_mib -gt 0) {
            $usedGb = $st.vram_used_mib / 1024.0
            $totalGb = $st.vram_total_mib / 1024.0
            $pct = [Math]::Min(100.0, [Math]::Max(0.0, ($st.vram_used_mib * 100.0) / $st.vram_total_mib))
            $gpuSubParts.Add(('VRAM: {0:F1}/{1:F1} GB' -f $usedGb, $totalGb))
            $VramProgressBar.Value = $pct
            $VramProgressBar.Foreground = if ($pct -ge 92) { Get-Brush '#EF4444' } elseif ($pct -ge 78) { Get-Brush '#F59E0B' } else { Get-Brush '#38BDF8' }
        } elseif ($null -ne $st.vram_total_mib -and $st.vram_total_mib -gt 0) {
            $gpuSubParts.Add(('VRAM: {0:F1} GB' -f ($st.vram_total_mib / 1024.0)))
            $VramProgressBar.Value = 0
        }
        if ($null -ne $st.gpu_util_pct) { $gpuSubParts.Add("$($st.gpu_util_pct)%") }
        if ($null -ne $st.gpu_temp_c) { $gpuSubParts.Add("$($st.gpu_temp_c) C") }
        $CardGpuSub.Text = if ($gpuSubParts.Count -gt 0) { $gpuSubParts -join ' | ' } else { 'Active GPU runtime' }
    } elseif ($st.runtime_known -and -not $st.runtime_active) {
        $script:HasActiveRuntime = $false
        $CardGpuValue.Text = 'None'
        $CardGpuSub.Text = 'No active Colab VM'
        $VramProgressBar.Value = 0
    } elseif ($st.runtime_active) {
        $script:HasActiveRuntime = $true
        $CardGpuValue.Text = if ($st.runtime_state) { $st.runtime_state } else { 'ACTIVE' }
        $CardGpuSub.Text = 'Active session'
    }

    # Session start/stop clock
    if ($script:HasActiveRuntime) {
        if ($null -eq $script:SessionStartedAt) {
            $script:SessionStartedAt = Get-Date
        }
    } elseif ($st.runtime_known) {
        $script:SessionStartedAt = $null
    }
    Update-SessionBurnDisplay

    # Card 2: Strata Engine & Active Model
    if ($st.active_model) {
        $script:LastActiveModel = $st.active_model
    }
    if ($st.strata_running) {
        $CardEngineValue.Text = 'RUNNING'
        $CardEngineValue.Foreground = Get-Brush '#22C55E'
        $engSub = New-Object System.Collections.Generic.List[string]
        if ($st.active_model) { $engSub.Add("Model: $($st.active_model)") } else { $engSub.Add('Healthy on Colab VM') }
        if ($st.drive_sync) { $engSub.Add("Drive: $($st.drive_sync)") }
        $CardEngineSub.Text = ($engSub -join ' | ')
    } elseif ($st.runtime_known -and -not $st.runtime_active) {
        $CardEngineValue.Text = 'OFFLINE'
        $CardEngineValue.Foreground = Get-Brush '#94A3B8'
        $CardEngineSub.Text = 'Start session to launch'
        $script:LastActiveModel = ''
    } elseif ($st.strata_state) {
        $CardEngineValue.Text = 'STOPPED'
        $CardEngineValue.Foreground = Get-Brush '#F59E0B'
        $CardEngineSub.Text = $st.strata_state
    }
    $wlText = if ($st.workload_active) { 'Workload monitor: active' } else { 'Workload monitor: idle' }
    $CardEngineMeta.Text = "$wlText | Updated $((Get-Date).ToString('HH:mm:ss'))"

    # Card 3: Tunnel
    if ($st.tunnel_known) {
        $script:TunnelConnected = [bool]$st.tunnel_connected
        if ($st.tunnel_connected) {
            $CardTunnelValue.Text = 'Connected'
            $CardTunnelValue.Foreground = Get-Brush '#22C55E'
        } else {
            $CardTunnelValue.Text = 'Disconnected'
            $CardTunnelValue.Foreground = Get-Brush '#94A3B8'
        }
    }

    if (-not $script:SessionSlot.IsRunning) {
        if ($script:TunnelConnected -and $st.strata_running) {
            Set-Badge 'Running' '#22C55E'
        } elseif ($script:HasActiveRuntime) {
            Set-Badge 'VM Active' '#F59E0B'
        } else {
            Set-Badge 'Idle' '#38BDF8'
        }
    }

    if ($null -ne $script:NotifyIcon) {
        $tip = "Strata Colab Desktop - $($StateBadgeText.Text)"
        if ($tip.Length -gt 63) { $tip = $tip.Substring(0, 63) }
        try { $script:NotifyIcon.Text = $tip } catch { }
    }
    Update-ButtonStates
}

function Trigger-StatusRefresh {
    if ($script:StatusSlot.IsRunning) { return }
    $script:StatusOutBuffer.Clear()
    $script:StatusErrBuffer.Clear()
    # Prefer fast single-pass JSON status; gracefully falls back to text output if older status.sh ignores --json
    $cmd = 'bash ./status.sh --json'
    $wslArgs = Build-WslArgs -BashCommand $cmd -RepoRoot $RepoRoot -Distro ([string]$env:STRATA_WSL_DISTRO)
    $null = $script:StatusSlot.Start('wsl.exe', $wslArgs, $RepoRoot)
}

function Start-SessionTask {
    param([string]$ScriptName, [string]$Label)
    $sel = Get-UiSelection
    Write-LocalConfigOverrides -LocalConfigPath $LocalConfigPath -Overrides $sel
    $script:ActiveMode = 'starting'
    $script:PendingAuthUrl = ''
    $AuthBanner.Visibility = 'Collapsed'
    Set-Badge $Label '#38BDF8'
    Append-Log "=== $Label ($ScriptName) ==="

    $bashCmd = Build-SessionEnvCommand -ScriptName $ScriptName -Selection $sel
    $wslArgs = Build-WslArgs -BashCommand $bashCmd -RepoRoot $RepoRoot -Distro ([string]$env:STRATA_WSL_DISTRO)
    if ($script:SessionSlot.Start('wsl.exe', $wslArgs, $RepoRoot, $true)) {
        Update-ButtonStates
        return $true
    } else {
        $script:ActiveMode = ''
        Set-Badge 'Start Failed' '#EF4444'
        Append-Log "[ERROR] Could not start $ScriptName - primary process slot is still busy."
        Update-ButtonStates
        return $false
    }
}

# One-Click Connect Client Dialog (Claude Code, Cursor/Cline/Continue, OpenAI Python SDK)
function Show-ConnectClientDialog {
    $freshCfg = Read-StrataConfig -ConfigPath $ConfigPath -LocalConfigPath $LocalConfigPath
    $port = if ($freshCfg['LOCAL_PORT']) { $freshCfg['LOCAL_PORT'] } else { $script:LocalPort }
    $apiKey = if ($freshCfg['API_KEY']) { $freshCfg['API_KEY'] } else { '' }
    $snippets = Get-ClientConnectSnippets -LocalPort $port -ApiKey $apiKey -ActiveModel $script:LastActiveModel

    [xml]$dlgXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Connect Client - Strata Colab Desktop"
        Width="740" Height="520"
        MinWidth="640" MinHeight="440"
        WindowStartupLocation="CenterOwner"
        Background="#0B1120"
        Foreground="#F8FAFC"
        FontFamily="Segoe UI">
    <Window.Resources>
        <Style x:Key="DlgBtn" TargetType="Button">
            <Setter Property="Foreground" Value="#F8FAFC"/>
            <Setter Property="Background" Value="#1E293B"/>
            <Setter Property="BorderBrush" Value="#334155"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="12,7"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="Bd" Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                CornerRadius="7" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Bd" Property="Opacity" Value="0.88"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="DlgPrimaryBtn" TargetType="Button" BasedOn="{StaticResource DlgBtn}">
            <Setter Property="Background" Value="#0284C7"/>
            <Setter Property="BorderBrush" Value="#38BDF8"/>
        </Style>
        <Style TargetType="TabItem">
            <Setter Property="Foreground" Value="#94A3B8"/>
            <Setter Property="Background" Value="#111827"/>
            <Setter Property="Padding" Value="14,7"/>
            <Setter Property="FontSize" Value="12.5"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="TabItem">
                        <Border x:Name="TabBd" Background="{TemplateBinding Background}"
                                BorderBrush="#1F2937" BorderThickness="1,1,1,0"
                                CornerRadius="7,7,0,0" Margin="0,0,4,0" Padding="{TemplateBinding Padding}">
                            <ContentPresenter ContentSource="Header" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsSelected" Value="True">
                                <Setter TargetName="TabBd" Property="Background" Value="#1E293B"/>
                                <Setter TargetName="TabBd" Property="BorderBrush" Value="#38BDF8"/>
                                <Setter Property="Foreground" Value="#F8FAFC"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </Window.Resources>

    <Grid Margin="16">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <StackPanel Grid.Row="0" Margin="0,0,0,12">
            <TextBlock Text="Connect Coding Agents &amp; SDKs" FontSize="17" FontWeight="Bold" Foreground="#F8FAFC"/>
            <TextBlock x:Name="LblEndpoints" Text="" FontSize="12" Foreground="#94A3B8" Margin="0,3,0,0"/>
        </StackPanel>

        <TabControl Grid.Row="1" Background="#111827" BorderBrush="#1F2937" BorderThickness="1">
            <TabItem Header="Claude Code">
                <Grid Margin="12">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                        <RowDefinition Height="Auto"/>
                    </Grid.RowDefinitions>
                    <TextBlock Grid.Row="0" TextWrapping="Wrap" FontSize="12" Foreground="#CBD5E1" Margin="0,0,0,8"
                               Text="Add this to ~/.claude/settings.json. CLAUDE_CODE_ATTRIBUTION_HEADER is set to 0 so Claude Code's per-request header does not invalidate Strata's KV prefix cache."/>
                    <TextBox x:Name="TxtClaude" Grid.Row="1" IsReadOnly="True" FontFamily="Consolas" FontSize="12.5"
                             Background="#070B14" Foreground="#E2E8F0" BorderBrush="#1F2937" BorderThickness="1"
                             Padding="10" VerticalScrollBarVisibility="Auto" TextWrapping="NoWrap"/>
                    <StackPanel Grid.Row="2" Orientation="Horizontal" Margin="0,10,0,0">
                        <Button x:Name="BtnCopyClaude" Content="Copy JSON" Style="{StaticResource DlgPrimaryBtn}" Margin="0,0,8,0"/>
                        <Button x:Name="BtnWriteClaude" Content="Write ~/.claude/settings.json" Style="{StaticResource DlgBtn}" Margin="0,0,10,0"/>
                        <TextBlock x:Name="LblClaudeStatus" Text="" Foreground="#22C55E" FontSize="12" VerticalAlignment="Center"/>
                    </StackPanel>
                </Grid>
            </TabItem>

            <TabItem Header="Cursor / Cline / Continue">
                <Grid Margin="12">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                        <RowDefinition Height="Auto"/>
                    </Grid.RowDefinitions>
                    <TextBlock Grid.Row="0" TextWrapping="Wrap" FontSize="12" Foreground="#CBD5E1" Margin="0,0,0,8"
                               Text="Point Cursor, Cline, Roo Code, or Continue to Strata's OpenAI-compatible /v1 endpoint through the local SSH tunnel."/>
                    <TextBox x:Name="TxtCursor" Grid.Row="1" IsReadOnly="True" FontFamily="Consolas" FontSize="12.5"
                             Background="#070B14" Foreground="#E2E8F0" BorderBrush="#1F2937" BorderThickness="1"
                             Padding="10" VerticalScrollBarVisibility="Auto" TextWrapping="NoWrap"/>
                    <StackPanel Grid.Row="2" Orientation="Horizontal" Margin="0,10,0,0">
                        <Button x:Name="BtnCopyBaseUrl" Content="Copy /v1 Base URL" Style="{StaticResource DlgPrimaryBtn}" Margin="0,0,8,0"/>
                        <Button x:Name="BtnCopyCursor" Content="Copy Snippet" Style="{StaticResource DlgBtn}" Margin="0,0,10,0"/>
                        <TextBlock x:Name="LblCursorStatus" Text="" Foreground="#22C55E" FontSize="12" VerticalAlignment="Center"/>
                    </StackPanel>
                </Grid>
            </TabItem>

            <TabItem Header="OpenAI Python SDK">
                <Grid Margin="12">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                        <RowDefinition Height="Auto"/>
                    </Grid.RowDefinitions>
                    <TextBlock Grid.Row="0" TextWrapping="Wrap" FontSize="12" Foreground="#CBD5E1" Margin="0,0,0,8"
                               Text="Call Strata directly from Python using the standard OpenAI client against your local forwarded port."/>
                    <TextBox x:Name="TxtPython" Grid.Row="1" IsReadOnly="True" FontFamily="Consolas" FontSize="12.5"
                             Background="#070B14" Foreground="#E2E8F0" BorderBrush="#1F2937" BorderThickness="1"
                             Padding="10" VerticalScrollBarVisibility="Auto" TextWrapping="NoWrap"/>
                    <StackPanel Grid.Row="2" Orientation="Horizontal" Margin="0,10,0,0">
                        <Button x:Name="BtnCopyPython" Content="Copy Python Snippet" Style="{StaticResource DlgPrimaryBtn}" Margin="0,0,10,0"/>
                        <TextBlock x:Name="LblPythonStatus" Text="" Foreground="#22C55E" FontSize="12" VerticalAlignment="Center"/>
                    </StackPanel>
                </Grid>
            </TabItem>
        </TabControl>

        <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,12,0,0">
            <Button x:Name="BtnDlgClose" Content="Close" Style="{StaticResource DlgBtn}" Width="90"/>
        </StackPanel>
    </Grid>
</Window>
'@

    $dlgReader = New-Object System.Xml.XmlNodeReader $dlgXaml
    $dlg = [System.Windows.Markup.XamlReader]::Load($dlgReader)
    $dlg.Owner = $window
    if (Test-Path -LiteralPath $IconPath) {
        try { $dlg.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create([Uri]::new($IconPath)) } catch { }
    }

    $dlg.FindName('LblEndpoints').Text = "Anthropic API: $($snippets.BaseUrl)  |  OpenAI API: $($snippets.OpenAiBaseUrl)"
    $txtClaude = $dlg.FindName('TxtClaude')
    $txtCursor = $dlg.FindName('TxtCursor')
    $txtPython = $dlg.FindName('TxtPython')
    $lblClaudeStatus = $dlg.FindName('LblClaudeStatus')
    $lblCursorStatus = $dlg.FindName('LblCursorStatus')
    $lblPythonStatus = $dlg.FindName('LblPythonStatus')

    $txtClaude.Text = $snippets.ClaudeJson
    $txtCursor.Text = $snippets.CursorCline
    $txtPython.Text = $snippets.PythonSdk

    $dlg.FindName('BtnCopyClaude').Add_Click({
        try {
            [System.Windows.Clipboard]::SetText($txtClaude.Text)
            $lblClaudeStatus.Text = 'Copied Claude Code JSON to clipboard.'
        } catch { }
    })

    $dlg.FindName('BtnWriteClaude').Add_Click({
        $claudeDir = Join-Path $env:USERPROFILE '.claude'
        $settingsPath = Join-Path $claudeDir 'settings.json'
        $confirmMsg = "Update Claude Code settings at:`n$settingsPath`n`nThis will merge ANTHROPIC_BASE_URL, ANTHROPIC_AUTH_TOKEN, and CLAUDE_CODE_ATTRIBUTION_HEADER=0 into env (preserving existing settings and creating a .bak backup if the file exists). Continue?"
        $ans = [System.Windows.MessageBox]::Show($confirmMsg, 'Write Claude Code Settings', [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Question)
        if ($ans -ne [System.Windows.MessageBoxResult]::Yes) { return }
        try {
            $existing = ''
            if (Test-Path -LiteralPath $settingsPath) {
                $existing = [System.IO.File]::ReadAllText($settingsPath)
                Copy-Item -LiteralPath $settingsPath -Destination "$settingsPath.bak" -Force
            }
            $merged = Merge-ClaudeSettingsJson -ExistingJson $existing -LocalPort $port -ApiKey $apiKey
            if (-not (Test-Path -LiteralPath $claudeDir)) {
                New-Item -ItemType Directory -Path $claudeDir -Force | Out-Null
            }
            [System.IO.File]::WriteAllText($settingsPath, $merged + "`n", (New-Object System.Text.UTF8Encoding($false)))
            $lblClaudeStatus.Text = "Saved to $settingsPath"
            Append-Log "[UI] Updated Claude Code settings at $settingsPath"
        } catch {
            [System.Windows.MessageBox]::Show("Failed to update ${settingsPath}:`n$($_.Exception.Message)", 'Write Failed', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error) | Out-Null
        }
    })

    $dlg.FindName('BtnCopyBaseUrl').Add_Click({
        try {
            [System.Windows.Clipboard]::SetText($snippets.OpenAiBaseUrl)
            $lblCursorStatus.Text = "Copied $($snippets.OpenAiBaseUrl)"
        } catch { }
    })

    $dlg.FindName('BtnCopyCursor').Add_Click({
        try {
            [System.Windows.Clipboard]::SetText($txtCursor.Text)
            $lblCursorStatus.Text = 'Copied Cursor / Cline / Continue snippet.'
        } catch { }
    })

    $dlg.FindName('BtnCopyPython').Add_Click({
        try {
            [System.Windows.Clipboard]::SetText($txtPython.Text)
            $lblPythonStatus.Text = 'Copied OpenAI Python snippet.'
        } catch { }
    })

    $dlg.FindName('BtnDlgClose').Add_Click({ $dlg.Close() })
    $null = $dlg.ShowDialog()
}

# System Tray NotifyIcon & Context Menu (disabled in SmokeTest/CaptureScreenshot)
$script:TrayOpenUiItem = $null
function Initialize-SystemTray {
    try {
        $ni = New-Object System.Windows.Forms.NotifyIcon
        if (Test-Path -LiteralPath $IconPath) {
            $ni.Icon = New-Object System.Drawing.Icon($IconPath)
        } else {
            $ni.Icon = [System.Drawing.SystemIcons]::Application
        }
        $ni.Text = 'Strata Colab Desktop'
        $ni.Visible = $true

        $menu = New-Object System.Windows.Forms.ContextMenuStrip

        $itemShow = New-Object System.Windows.Forms.ToolStripMenuItem('Show Window')
        $itemShow.Font = New-Object System.Drawing.Font($itemShow.Font, [System.Drawing.FontStyle]::Bold)
        $itemShow.Add_Click({
            $window.Show()
            $window.ShowInTaskbar = $true
            $window.WindowState = 'Normal'
            $null = $window.Activate()
        })
        $null = $menu.Items.Add($itemShow)

        $itemOpenUi = New-Object System.Windows.Forms.ToolStripMenuItem('Open Strata UI')
        $itemOpenUi.Enabled = $false
        $itemOpenUi.Add_Click({
            if ($BtnOpenUi.IsEnabled) {
                try { [System.Diagnostics.Process]::Start("http://localhost:$($script:LocalPort)") | Out-Null } catch { }
            }
        })
        $script:TrayOpenUiItem = $itemOpenUi
        $null = $menu.Items.Add($itemOpenUi)

        $itemRefresh = New-Object System.Windows.Forms.ToolStripMenuItem('Refresh Status')
        $itemRefresh.Add_Click({
            $window.Dispatcher.Invoke([Action]{ Trigger-StatusRefresh })
        })
        $null = $menu.Items.Add($itemRefresh)

        $null = $menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

        $itemStopExit = New-Object System.Windows.Forms.ToolStripMenuItem('Stop VM & Exit')
        $itemStopExit.Add_Click({
            $window.Dispatcher.Invoke([Action]{
                $script:ForceClosing = $true
                if ($script:PollTimer) { $script:PollTimer.Stop() }
                if ($script:TelemetryTimer) { $script:TelemetryTimer.Stop() }
                if ($script:SessionSlot.IsRunning) { $script:SessionSlot.StopTree() }
                if ($script:AuxSlot.IsRunning) { $script:AuxSlot.StopTree() }
                if ($script:StatusSlot.IsRunning) { $script:StatusSlot.StopTree() }
                try {
                    $stopCmd = "$($script:WslCleanupCmd); bash ./down.sh"
                    $wslArgs = Build-WslArgs -BashCommand $stopCmd -RepoRoot $RepoRoot -Distro ([string]$env:STRATA_WSL_DISTRO)
                    $p = Start-Process -FilePath 'wsl.exe' -ArgumentList $wslArgs -WindowStyle Hidden -PassThru
                    if ($p) {
                        $null = $p.WaitForExit(45000)
                        try { $p.Dispose() } catch { }
                    }
                } catch { }
                $window.Close()
            })
        })
        $null = $menu.Items.Add($itemStopExit)

        $ni.ContextMenuStrip = $menu
        $ni.Add_DoubleClick({
            $window.Dispatcher.Invoke([Action]{
                $window.Show()
                $window.ShowInTaskbar = $true
                $window.WindowState = 'Normal'
                $null = $window.Activate()
            })
        })

        $script:NotifyIcon = $ni
    } catch {
        $script:NotifyIcon = $null
    }
}

function Dispose-SystemTray {
    if ($null -ne $script:NotifyIcon) {
        try {
            $script:NotifyIcon.Visible = $false
            if ($script:NotifyIcon.ContextMenuStrip) {
                $script:NotifyIcon.ContextMenuStrip.Dispose()
            }
            if ($script:NotifyIcon.Icon) {
                $script:NotifyIcon.Icon.Dispose()
            }
            $script:NotifyIcon.Dispose()
        } catch { }
        $script:NotifyIcon = $null
    }
}

# Control Event Handlers
$ChkDrive.Add_Checked({
    $ChkDriveModelCache.IsEnabled = $true
})
$ChkDrive.Add_Unchecked({
    $ChkDriveModelCache.IsChecked = $false
    $ChkDriveModelCache.IsEnabled = $false
})

$CmbUiMode.Add_SelectionChanged({
    Update-ButtonStates
})

$BtnDismissError.Add_Click({
    $ErrorBanner.Visibility = 'Collapsed'
})

$BtnConnect.Add_Click({
    Show-ConnectClientDialog
})

$BtnSaveConfig.Add_Click({
    $sel = Get-UiSelection
    Write-LocalConfigOverrides -LocalConfigPath $LocalConfigPath -Overrides $sel
    $reloaded = Read-StrataConfig -ConfigPath $ConfigPath -LocalConfigPath $LocalConfigPath
    $script:LocalPort = if ($reloaded['LOCAL_PORT']) { $reloaded['LOCAL_PORT'] } else { '8080' }
    $script:ApiKey = if ($reloaded['API_KEY']) { $reloaded['API_KEY'] } else { '' }
    $CardTunnelSub.Text = "http://localhost:$($script:LocalPort)"
    Append-Log "Saved UI settings to config.local.env (GPU=$($sel.GPU), MODEL=$($sel.MODEL), FAMILY=$($sel.MODEL_FAMILY), CONTEXT=$($sel.CONTEXT), LOCAL_PORT=$($script:LocalPort))."
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
    $null = Start-SessionTask -ScriptName 'up.sh' -Label 'Starting Session'
})

$BtnRestart.Add_Click({
    if ($script:SessionSlot.IsRunning) {
        $script:SessionSlot.StopTree()
        Invoke-WslCleanupSync -TimeoutMs 6000
    }
    $ok = Start-SessionTask -ScriptName 'restart.sh' -Label 'Restarting Strata'
    if (-not $ok) {
        [System.Windows.MessageBox]::Show(
            'Could not launch restart.sh because a previous session process did not exit cleanly. Click Detach Tunnel and try again.',
            'Strata Colab Desktop',
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Warning
        ) | Out-Null
    }
})

$BtnTune.Add_Click({
    if ($script:AuxSlot.IsRunning) {
        Append-Log '[UI] Another auxiliary task (Auto-Tune or Remote Logs) is already running.'
        return
    }
    $sel = Get-UiSelection
    Write-LocalConfigOverrides -LocalConfigPath $LocalConfigPath -Overrides $sel
    Append-Log '=== Running Auto-Tune (./tune.sh thorough coding work) ==='
    $script:AuxMode = 'tune'
    $mVal = Format-BashEnvValue -Value $sel.MODEL
    $fVal = Format-BashEnvValue -Value $sel.MODEL_FAMILY
    $bashCmd = "env MODEL=$mVal MODEL_FAMILY=$fVal bash ./tune.sh thorough coding work"
    $wslArgs = Build-WslArgs -BashCommand $bashCmd -RepoRoot $RepoRoot -Distro ([string]$env:STRATA_WSL_DISTRO)
    if ($script:AuxSlot.Start('wsl.exe', $wslArgs, $RepoRoot)) {
        Update-ButtonStates
    } else {
        $script:AuxMode = ''
        Append-Log '[ERROR] Could not start Auto-Tune process.'
    }
})

$BtnDetach.Add_Click({
    $AuthBanner.Visibility = 'Collapsed'
    $script:PendingAuthUrl = ''
    if ($script:SessionSlot.IsRunning) {
        Append-Log '[UI] Detaching local WSL tunnel / task process...'
        $script:SessionSlot.StopTree()
    }
    if ($script:AuxSlot.IsRunning) {
        $script:AuxSlot.StopTree()
        $script:AuxMode = ''
    }
    Invoke-WslCleanupSync -TimeoutMs 8000
    $script:ActiveMode = ''
    $script:TunnelConnected = $false
    Set-Badge 'Detached' '#94A3B8'
    Update-ButtonStates
    Trigger-StatusRefresh
})

$BtnStopVm.Add_Click({
    $AuthBanner.Visibility = 'Collapsed'
    $script:PendingAuthUrl = ''
    if ($script:SessionSlot.IsRunning) {
        $script:SessionSlot.StopTree()
    }
    if ($script:AuxSlot.IsRunning) {
        $script:AuxSlot.StopTree()
        $script:AuxMode = ''
    }
    $script:ActiveMode = 'stopping'
    Set-Badge 'Stopping VM...' '#F59E0B'
    Append-Log '=== Stopping Colab VM & Closing Tunnel (./down.sh) ==='
    $stopCmd = "$($script:WslCleanupCmd); bash ./down.sh"
    $wslArgs = Build-WslArgs -BashCommand $stopCmd -RepoRoot $RepoRoot -Distro ([string]$env:STRATA_WSL_DISTRO)
    if ($script:SessionSlot.Start('wsl.exe', $wslArgs, $RepoRoot)) {
        Update-ButtonStates
    } else {
        $script:ActiveMode = ''
        Set-Badge 'Stop Failed' '#EF4444'
        Append-Log '[ERROR] Failed to start ./down.sh! Please stop the VM manually via stop.bat or Colab Web to avoid CU charges.'
        Show-TrayBalloon -Title 'Failed to Stop Colab VM' -Body 'Could not start ./down.sh. Run stop.bat or stop the runtime in Colab Web.' -Icon 'Error'
        [System.Windows.MessageBox]::Show(
            'Could not launch ./down.sh because the session slot could not be acquired. Please run stop.bat or check Colab Web immediately so compute units are not billed.',
            'Strata Colab Desktop - Stop VM Error',
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Error
        ) | Out-Null
        Update-ButtonStates
    }
})

$BtnOpenSsh.Add_Click({
    try {
        $wslArgs = Build-WslArgs -BashCommand 'bash ./ssh.sh' -RepoRoot $RepoRoot -Distro ([string]$env:STRATA_WSL_DISTRO)
        Start-Process -FilePath 'wsl.exe' -ArgumentList $wslArgs -WorkingDirectory $RepoRoot | Out-Null
        Append-Log '[UI] Opened interactive WSL SSH window (./ssh.sh).'
    } catch {
        Append-Log "[ERROR] Failed to launch SSH window: $($_.Exception.Message)"
    }
})

$BtnRemoteLogs.Add_Click({
    if ($script:AuxSlot.IsRunning -and $script:AuxMode -eq 'logs') {
        $script:AuxSlot.StopTree()
        $script:AuxMode = ''
        Append-Log '[UI] Stopped remote log stream.'
        Update-ButtonStates
        return
    }
    if ($script:AuxSlot.IsRunning) {
        Append-Log '[UI] Wait for the active Auto-Tune task to finish before streaming remote logs.'
        return
    }
    Append-Log '=== Streaming Remote VM Logs (./logs.sh) ==='
    $script:AuxMode = 'logs'
    $wslArgs = Build-WslArgs -BashCommand 'bash ./logs.sh' -RepoRoot $RepoRoot -Distro ([string]$env:STRATA_WSL_DISTRO)
    if ($script:AuxSlot.Start('wsl.exe', $wslArgs, $RepoRoot)) {
        Update-ButtonStates
    } else {
        $script:AuxMode = ''
        Append-Log '[ERROR] Could not start remote log stream.'
    }
})

$BtnExportDiag.Add_Click({
    try {
        $desktopDir = [Environment]::GetFolderPath('Desktop')
        if ([string]::IsNullOrWhiteSpace($desktopDir) -or -not (Test-Path -LiteralPath $desktopDir)) {
            $desktopDir = $StateDir
            if (-not (Test-Path -LiteralPath $desktopDir)) {
                New-Item -ItemType Directory -Path $desktopDir -Force | Out-Null
            }
        }
        $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
        $outPath = Join-Path $desktopDir "strata-diagnostics-$stamp.txt"
        $sb = New-Object System.Text.StringBuilder
        $null = $sb.AppendLine('=== Strata Colab Desktop Diagnostics (Redacted) ===')
        $null = $sb.AppendLine("Generated : $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz'))")
        $null = $sb.AppendLine("RepoRoot  : $RepoRoot")
        $null = $sb.AppendLine("PSVersion : $($PSVersionTable.PSVersion)")
        $null = $sb.AppendLine("OSVersion : $([System.Environment]::OSVersion.VersionString)")
        $null = $sb.AppendLine("Badge     : $($StateBadgeText.Text)")
        $null = $sb.AppendLine("LocalPort : $($script:LocalPort)")
        $null = $sb.AppendLine('')

        if ($null -ne $script:LastStatusSnapshot) {
            $null = $sb.AppendLine('--- Latest Status Snapshot ---')
            $null = $sb.AppendLine(($script:LastStatusSnapshot | ConvertTo-Json -Depth 4))
            $null = $sb.AppendLine('')
        }

        foreach ($cfgFile in @($ConfigPath, $LocalConfigPath)) {
            if (Test-Path -LiteralPath $cfgFile) {
                $null = $sb.AppendLine("--- $(Split-Path -Leaf $cfgFile) ---")
                $null = $sb.AppendLine([System.IO.File]::ReadAllText($cfgFile))
                $null = $sb.AppendLine('')
            }
        }

        $wlLog = Join-Path $StateDir 'workload-monitor.log'
        if (Test-Path -LiteralPath $wlLog) {
            $null = $sb.AppendLine('--- .state/workload-monitor.log (tail 100) ---')
            $tail = Get-Content -LiteralPath $wlLog -Tail 100 -ErrorAction SilentlyContinue
            if ($tail) { $null = $sb.AppendLine(($tail -join "`r`n")) }
            $null = $sb.AppendLine('')
        }

        if (Test-Path -LiteralPath $CrashLogPath) {
            $null = $sb.AppendLine('--- .state/launcher-crash.log (tail 80) ---')
            $ctail = Get-Content -LiteralPath $CrashLogPath -Tail 80 -ErrorAction SilentlyContinue
            if ($ctail) { $null = $sb.AppendLine(($ctail -join "`r`n")) }
            $null = $sb.AppendLine('')
        }

        $null = $sb.AppendLine('--- Launcher Console Log ---')
        $null = $sb.AppendLine(($script:LogLines -join "`r`n"))

        $redacted = Redact-DiagnosticsText -Text $sb.ToString()
        [System.IO.File]::WriteAllText($outPath, $redacted, (New-Object System.Text.UTF8Encoding($false)))
        Append-Log "[UI] Exported redacted diagnostics bundle to: $outPath"
        [System.Windows.MessageBox]::Show("Redacted diagnostics saved to:`n$outPath", 'Export Diagnostics', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information) | Out-Null
    } catch {
        Append-Log "[ERROR] Failed to export diagnostics: $($_.Exception.Message)"
    }
})

$BtnAuthContinue.Add_Click({
    if ($script:SessionSlot.SendLine('')) {
        Append-Log '[UI] Sent Enter to continue Google Drive mount...'
        $AuthBanner.Visibility = 'Collapsed'
        Set-Badge 'Authorizing Drive...' '#38BDF8'
    } else {
        Append-Log '[UI] Could not send Enter to session process.'
    }
})

$BtnAuthOpen.Add_Click({
    if ($script:PendingAuthUrl) {
        try { [System.Diagnostics.Process]::Start($script:PendingAuthUrl) | Out-Null } catch { }
    }
})

$BtnAuthCopy.Add_Click({
    if ($script:PendingAuthUrl) {
        try { [System.Windows.Clipboard]::SetText($script:PendingAuthUrl) } catch { }
    }
})

$TxtLogFilter.Add_TextChanged({
    $script:LogFilter = $TxtLogFilter.Text
    Refresh-LogView
})

$BtnClearFilter.Add_Click({
    $TxtLogFilter.Clear()
})

$BtnPauseScroll.Add_Checked({
    $script:PauseAutoScroll = $true
    $BtnPauseScroll.Content = 'Scroll Paused'
})

$BtnPauseScroll.Add_Unchecked({
    $script:PauseAutoScroll = $false
    $BtnPauseScroll.Content = 'Pause Scroll'
    $TxtLog.ScrollToEnd()
})

$BtnCopyLog.Add_Click({
    try {
        [System.Windows.Clipboard]::SetText($TxtLog.Text)
    } catch { }
})

$BtnClearLog.Add_Click({
    $script:LogLines.Clear()
    $TxtLog.Clear()
    Update-LogCountLabel -VisibleCount 0
})

# Minimize-to-tray handling
$window.Add_StateChanged({
    if ($window.WindowState -eq 'Minimized' -and $ChkTray.IsChecked -and $null -ne $script:NotifyIcon) {
        $window.Hide()
        $window.ShowInTaskbar = $false
        if (-not $script:TrayMinimizeNotified) {
            $script:TrayMinimizeNotified = $true
            Show-TrayBalloon -Title 'Strata Colab Desktop' -Body 'Running in the system tray. Double-click the tray icon to restore.' -Icon 'Info'
        }
    }
})

# 120ms UI DispatcherTimer for batched console draining and event dispatch
$script:PollTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:PollTimer.Interval = [TimeSpan]::FromMilliseconds(120)
$script:PollTimer.Add_Tick({
    $batch = New-Object System.Collections.Generic.List[string]

    # 1. Session slot
    foreach ($item in $script:SessionSlot.Drain()) {
        if ($item.StartsWith('EXIT:')) {
            $code = $item.Substring(5)
            $wasMode = $script:ActiveMode
            $script:ActiveMode = ''
            $AuthBanner.Visibility = 'Collapsed'
            $script:PendingAuthUrl = ''
            $batch.Add("[Process exited with code $code]")
            if ($code -eq '0') {
                if ($wasMode -eq 'stopping') {
                    $script:HasActiveRuntime = $false
                    $script:TunnelConnected = $false
                    $script:SessionStartedAt = $null
                    Set-Badge 'Stopped' '#38BDF8'
                } else {
                    Set-Badge 'Ready' '#22C55E'
                }
            } elseif ($wasMode -ne 'stopping') {
                Set-Badge "Exited ($code)" '#EF4444'
                Show-TrayBalloon -Title 'Strata Session Error' -Body "Session process exited with code $code. Check console log for details." -Icon 'Error'
            }
            Update-ButtonStates
            Trigger-StatusRefresh
        } else {
            $text = $item.Substring(4)
            $batch.Add($text)
            $evt = Classify-LogLine -Line $text -CurrentMode $script:ActiveMode
            switch ($evt.Event) {
                'DriveAuthRequired' {
                    $script:PendingAuthUrl = $evt.AuthUrl
                    $AuthBanner.Visibility = 'Visible'
                    Set-Badge $evt.BadgeText $evt.BadgeColor
                    try { [System.Diagnostics.Process]::Start($script:PendingAuthUrl) | Out-Null } catch { }
                    $batch.Add('[UI] Opened Google Drive authorization page in your Windows browser. After granting access, click "I''ve Granted Access - Continue".')
                    Show-TrayBalloon -Title $evt.NotifyTitle -Body $evt.NotifyBody -Icon $evt.NotifyIcon
                }
                'DriveAuthDone' {
                    $AuthBanner.Visibility = 'Collapsed'
                    $script:PendingAuthUrl = ''
                }
                'TunnelReady' {
                    $wasTunnel = ($script:ActiveMode -eq 'tunnel')
                    $script:ActiveMode = 'tunnel'
                    $script:TunnelConnected = $true
                    if ($null -eq $script:SessionStartedAt) { $script:SessionStartedAt = Get-Date }
                    $AuthBanner.Visibility = 'Collapsed'
                    $script:PendingAuthUrl = ''
                    Set-Badge $evt.BadgeText $evt.BadgeColor
                    Update-ButtonStates
                    if (-not $wasTunnel) {
                        Show-TrayBalloon -Title $evt.NotifyTitle -Body $evt.NotifyBody -Icon $evt.NotifyIcon
                        Trigger-StatusRefresh
                    }
                }
                'Probing' {
                    Set-Badge $evt.BadgeText $evt.BadgeColor
                }
                'Starting' {
                    Set-Badge $evt.BadgeText $evt.BadgeColor
                }
                'Error' {
                    Show-TrayBalloon -Title $evt.NotifyTitle -Body $evt.NotifyBody -Icon $evt.NotifyIcon
                }
            }
        }
    }

    # 2. Aux slot (Auto-Tune or Remote Logs)
    foreach ($item in $script:AuxSlot.Drain()) {
        if ($item.StartsWith('EXIT:')) {
            $code = $item.Substring(5)
            $wasAux = $script:AuxMode
            $script:AuxMode = ''
            if ($wasAux -eq 'tune') {
                $batch.Add("[Auto-Tune exited with code $code]")
                if ($code -eq '0') {
                    Show-TrayBalloon -Title 'Strata Auto-Tune Done' -Body 'Hardware calibration completed and presets were saved.' -Icon 'Info'
                } else {
                    Show-TrayBalloon -Title 'Strata Auto-Tune Error' -Body "Auto-Tune exited with code $code." -Icon 'Error'
                }
                Trigger-StatusRefresh
            } else {
                $batch.Add("[Remote Logs exited with code $code]")
            }
            Update-ButtonStates
        } else {
            $text = $item.Substring(4)
            $batch.Add($text)
            if ($script:AuxMode -eq 'tune') {
                $evt = Classify-LogLine -Line $text -CurrentMode $script:ActiveMode
                if ($evt.Event -eq 'TuneDone') {
                    Show-TrayBalloon -Title $evt.NotifyTitle -Body $evt.NotifyBody -Icon $evt.NotifyIcon
                }
            }
        }
    }

    if ($batch.Count -gt 0) {
        Append-LogBatch -Lines $batch.ToArray()
    }

    # 3. Status slot
    foreach ($item in $script:StatusSlot.Drain()) {
        if ($item.StartsWith('EXIT:')) {
            Apply-StatusOutput -OutLines $script:StatusOutBuffer.ToArray() -ErrLines $script:StatusErrBuffer.ToArray()
        } elseif ($item.StartsWith('ERR:')) {
            $script:StatusErrBuffer.Add($item.Substring(4))
        } else {
            $script:StatusOutBuffer.Add($item.Substring(4))
        }
    }
})

# 20-second Live Auto-Refresh Telemetry Timer
$script:TelemetryTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:TelemetryTimer.Interval = [TimeSpan]::FromSeconds(20)
$script:TelemetryTimer.Add_Tick({
    Update-SessionBurnDisplay
    if ($script:ActiveMode -ne 'stopping' -and -not $script:StatusSlot.IsRunning) {
        Trigger-StatusRefresh
    }
})

$window.Add_Loaded({
    Initialize-SystemTray
    $script:PollTimer.Start()
    $script:TelemetryTimer.Start()
    Update-ButtonStates
    Append-Log "Strata Colab Desktop ready. Repository: $RepoRoot"
    Trigger-StatusRefresh
})

$window.Add_Closing({
    param($sender, $e)
    if ($script:ForceClosing) {
        if ($script:PollTimer) { $script:PollTimer.Stop() }
        if ($script:TelemetryTimer) { $script:TelemetryTimer.Stop() }
        Dispose-SystemTray
        return
    }
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
        if ($script:PollTimer) { $script:PollTimer.Stop() }
        if ($script:TelemetryTimer) { $script:TelemetryTimer.Stop() }
        if ($script:SessionSlot.IsRunning) { $script:SessionSlot.StopTree() }
        if ($script:AuxSlot.IsRunning) { $script:AuxSlot.StopTree() }
        if ($script:StatusSlot.IsRunning) { $script:StatusSlot.StopTree() }
        if ($ans -eq [System.Windows.MessageBoxResult]::Yes) {
            $stopCmd = "$($script:WslCleanupCmd); bash ./down.sh"
            $wslArgs = Build-WslArgs -BashCommand $stopCmd -RepoRoot $RepoRoot -Distro ([string]$env:STRATA_WSL_DISTRO)
            $p = Start-Process -FilePath 'wsl.exe' -ArgumentList $wslArgs -WindowStyle Hidden -PassThru
            if ($p) {
                $null = $p.WaitForExit(45000)
                try { $p.Dispose() } catch { }
            }
        } else {
            Invoke-WslCleanupSync -TimeoutMs 8000
        }
    } else {
        if ($script:PollTimer) { $script:PollTimer.Stop() }
        if ($script:TelemetryTimer) { $script:TelemetryTimer.Stop() }
        if ($script:AuxSlot.IsRunning) { $script:AuxSlot.StopTree() }
        if ($script:StatusSlot.IsRunning) { $script:StatusSlot.StopTree() }
    }
    Dispose-SystemTray
})

$null = $window.ShowDialog()

} catch {
    Write-LauncherCrashLog -ErrorRecord $_
    if ($IsTestRenderMode) {
        Write-Error $_.Exception.ToString()
        exit 1
    } else {
        try {
            Add-Type -AssemblyName PresentationFramework -ErrorAction SilentlyContinue
            [System.Windows.MessageBox]::Show(
                "Strata Colab Desktop failed to start:`n`n$($_.Exception.Message)`n`nDetails were logged to:`n$CrashLogPath",
                'Strata Colab Desktop - Startup Error',
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Error
            ) | Out-Null
        } catch { }
        exit 1
    }
} finally {
    if ($script:PollTimer) { try { $script:PollTimer.Stop() } catch { } }
    if ($script:TelemetryTimer) { try { $script:TelemetryTimer.Stop() } catch { } }
    if (Get-Command Dispose-SystemTray -ErrorAction SilentlyContinue) {
        Dispose-SystemTray
    }
}
