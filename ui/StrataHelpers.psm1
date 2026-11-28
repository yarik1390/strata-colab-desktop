<#
.SYNOPSIS
    Shared helper functions for Strata Colab Desktop (icon generation, config I/O,
    WSL command building, status payload parsing, log classification, diagnostics,
    and coding-agent client configuration snippets).
#>

Set-StrictMode -Version Latest

function Write-StrataIconFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$OutPath,
        [switch]$Force
    )

    if (-not $Force -and (Test-Path -LiteralPath $OutPath)) {
        return
    }

    Add-Type -AssemblyName System.Drawing
    $sizes = @(16, 32, 48, 256)
    $pngBlobs = New-Object System.Collections.Generic.List[byte[]]

    foreach ($sz in $sizes) {
        $bmp = $null; $g = $null; $path = $null; $bgBrush = $null
        $borderPen = $null; $font = $null; $sf = $null; $textBrush = $null
        $dotBrush = $null; $ms = $null
        try {
            $bmp = New-Object System.Drawing.Bitmap($sz, $sz, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
            $g = [System.Drawing.Graphics]::FromImage($bmp)
            $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
            $g.Clear([System.Drawing.Color]::Transparent)

            $pad = [float]($sz * 0.06)
            $box = [float]($sz - 2 * $pad)
            $rad = [float]($sz * 0.22)
            $d = $rad * 2.0
            $path = New-Object System.Drawing.Drawing2D.GraphicsPath
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

            $borderPen = New-Object System.Drawing.Pen(
                [System.Drawing.Color]::FromArgb(225, 56, 189, 248),
                [Math]::Max(1.0, $sz * 0.05)
            )
            $g.DrawPath($borderPen, $path)

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
        } finally {
            if ($ms) { $ms.Dispose() }
            if ($dotBrush) { $dotBrush.Dispose() }
            if ($textBrush) { $textBrush.Dispose() }
            if ($sf) { $sf.Dispose() }
            if ($font) { $font.Dispose() }
            if ($borderPen) { $borderPen.Dispose() }
            if ($bgBrush) { $bgBrush.Dispose() }
            if ($path) { $path.Dispose() }
            if ($g) { $g.Dispose() }
            if ($bmp) { $bmp.Dispose() }
        }
    }

    $parentDir = Split-Path -Parent $OutPath
    if ($parentDir -and -not (Test-Path -LiteralPath $parentDir)) {
        New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
    }

    $fs = $null; $bw = $null
    try {
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
        $bw.Flush()
    } finally {
        if ($bw) { $bw.Dispose() }
        if ($fs) { $fs.Dispose() }
    }
}

function Format-BashEnvValue {
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [AllowNull()]
        [string]$Value
    )

    if ($null -eq $Value -or $Value.Length -eq 0) {
        return "''"
    }
    if ($Value -match '^[A-Za-z0-9._:/-]+$') {
        return $Value
    }
    # Bash-safe single-quote escaping: no $VAR, backtick, or glob expansion
    $escaped = $Value.Replace("'", "'\''")
    return "'$escaped'"
}

function ConvertFrom-BashEnvValue {
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [AllowNull()]
        [string]$RawValue
    )

    if ($null -eq $RawValue) { return '' }
    $s = $RawValue.Trim()
    if ($s.Length -eq 0) { return '' }

    $sb = New-Object System.Text.StringBuilder
    $i = 0
    $len = $s.Length
    $inSingle = $false
    $inDouble = $false

    while ($i -lt $len) {
        $ch = $s[$i]
        if ($inSingle) {
            if ($ch -eq "'") {
                $inSingle = $false
            } else {
                $null = $sb.Append($ch)
            }
            $i++
            continue
        }
        if ($inDouble) {
            if ($ch -eq '\' -and ($i + 1) -lt $len) {
                $next = $s[$i + 1]
                if ($next -eq '"' -or $next -eq '\' -or $next -eq '$' -or $next -eq '`') {
                    $null = $sb.Append($next)
                    $i += 2
                    continue
                }
            }
            if ($ch -eq '"') {
                $inDouble = $false
            } else {
                $null = $sb.Append($ch)
            }
            $i++
            continue
        }

        # Outside quotes
        if ($ch -eq '#') {
            # Unquoted comment starts here
            break
        }
        if ($ch -eq "'") {
            $inSingle = $true
            $i++
            continue
        }
        if ($ch -eq '"') {
            $inDouble = $true
            $i++
            continue
        }
        if ($ch -eq '\' -and ($i + 1) -lt $len) {
            $null = $sb.Append($s[$i + 1])
            $i += 2
            continue
        }
        if ([char]::IsWhiteSpace($ch)) {
            # Check if trailing comment or trailing whitespace follows
            $rest = $s.Substring($i).TrimStart()
            if ($rest.Length -eq 0 -or $rest.StartsWith('#')) {
                break
            }
            $null = $sb.Append($ch)
            $i++
            continue
        }
        $null = $sb.Append($ch)
        $i++
    }

    return $sb.ToString()
}

function Read-StrataConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath,
        [string]$LocalConfigPath = ''
    )

    $cfg = @{}
    $paths = New-Object System.Collections.Generic.List[string]
    $paths.Add($ConfigPath)
    if (-not [string]::IsNullOrWhiteSpace($LocalConfigPath)) {
        $paths.Add($LocalConfigPath)
    }

    foreach ($path in $paths) {
        if (-not (Test-Path -LiteralPath $path)) { continue }
        foreach ($rawLine in [System.IO.File]::ReadAllLines($path)) {
            $line = $rawLine.Trim()
            if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#')) { continue }
            if ($line.StartsWith('export ')) {
                $line = $line.Substring(7).Trim()
            }
            $idx = $line.IndexOf('=')
            if ($idx -lt 1) { continue }
            $key = $line.Substring(0, $idx).Trim()
            if ($key -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { continue }
            $rawVal = $line.Substring($idx + 1)
            $cfg[$key] = ConvertFrom-BashEnvValue -RawValue $rawVal
        }
    }
    return $cfg
}

function Write-LocalConfigOverrides {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$LocalConfigPath,
        [Parameter(Mandatory = $true)]
        [hashtable]$Overrides
    )

    $managedKeys = @($Overrides.Keys)
    $preserved = New-Object System.Collections.Generic.List[string]
    if (Test-Path -LiteralPath $LocalConfigPath) {
        foreach ($rawLine in [System.IO.File]::ReadAllLines($LocalConfigPath)) {
            $t = $rawLine.Trim()
            if ($t -eq '# Managed by Strata Colab Desktop UI') { continue }
            $checkLine = if ($t.StartsWith('export ')) { $t.Substring(7).Trim() } else { $t }
            $eq = $checkLine.IndexOf('=')
            if ($eq -gt 0 -and -not $t.StartsWith('#')) {
                $k = $checkLine.Substring(0, $eq).Trim()
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
        $v = if ($null -eq $Overrides[$k]) { '' } else { [string]$Overrides[$k] }
        $formatted = Format-BashEnvValue -Value $v
        $lines.Add("$k=$formatted")
    }
    foreach ($p in $preserved) {
        $lines.Add($p)
    }

    $parentDir = Split-Path -Parent $LocalConfigPath
    if ($parentDir -and -not (Test-Path -LiteralPath $parentDir)) {
        New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
    }
    $content = ($lines -join "`n") + "`n"
    [System.IO.File]::WriteAllText($LocalConfigPath, $content, (New-Object System.Text.UTF8Encoding($false)))
}

function ConvertTo-Win32Arg {
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [string]$Value
    )

    if ($null -eq $Value -or $Value.Length -eq 0) {
        return '""'
    }
    $escaped = [System.Text.RegularExpressions.Regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $escaped = [System.Text.RegularExpressions.Regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}

function Build-WslArgs {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BashCommand,
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,
        [string]$Distro = ''
    )

    $parts = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($Distro)) {
        $parts.Add('-d')
        $parts.Add((ConvertTo-Win32Arg -Value $Distro.Trim()))
    }
    $parts.Add('--cd')
    $parts.Add((ConvertTo-Win32Arg -Value $RepoRoot))
    $parts.Add('--exec')
    $parts.Add('bash')
    $parts.Add('-lc')
    $parts.Add((ConvertTo-Win32Arg -Value $BashCommand))
    return ($parts -join ' ')
}

function Build-SessionEnvCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptName,
        [Parameter(Mandatory = $true)]
        [hashtable]$Selection,
        [hashtable]$ExtraEnv = @{}
    )

    $orderedKeys = @(
        'GPU', 'MODEL', 'MODEL_FAMILY', 'CONTEXT', 'UI_MODE',
        'TUNE_ON_START', 'USE_DRIVE', 'DRIVE_MODEL_CACHE', 'HIGH_MEM',
        'ACTIVE_WORKLOAD_MONITOR', 'OPEN_BROWSER',
        'STRATA_KV_CACHE', 'STRATA_VISION', 'STRATA_DRAFTER',
        'AUTO_STOP_IDLE_MIN', 'MODEL_REPO', 'MODEL_FILES', 'STRATA_EXTRA_ARGS'
    )

    $tokens = New-Object System.Collections.Generic.List[string]
    $tokens.Add('STRATA_UI_HOST=1')
    $tokens.Add('ASK_GPU=0')
    $tokens.Add('ASK_MODEL=0')

    foreach ($k in $orderedKeys) {
        if ($Selection.ContainsKey($k)) {
            $val = if ($null -eq $Selection[$k]) { '' } else { [string]$Selection[$k] }
            $tokens.Add("$k=$(Format-BashEnvValue -Value $val)")
        }
    }
    foreach ($k in ($ExtraEnv.Keys | Sort-Object)) {
        $val = if ($null -eq $ExtraEnv[$k]) { '' } else { [string]$ExtraEnv[$k] }
        $tokens.Add("$k=$(Format-BashEnvValue -Value $val)")
    }

    $safeScript = Format-BashEnvValue -Value ("./$ScriptName")
    return "env $($tokens -join ' ') bash $safeScript"
}

function Parse-StatusPayload {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()]
        [string[]]$Lines = @()
    )

    $result = @{
        source           = 'empty'
        runtime_active   = $false
        runtime_known    = $false
        runtime_state    = ''
        gpu_name         = ''
        vram_used_mib    = $null
        vram_total_mib   = $null
        gpu_util_pct     = $null
        gpu_temp_c       = $null
        strata_running   = $false
        strata_state     = ''
        active_model     = ''
        tunnel_connected = $false
        tunnel_known     = $false
        local_port       = $null
        tunnel_url       = ''
        cu_balance       = $null
        cu_rate          = $null
        eligible_gpus    = @()
        drive_sync       = ''
        workload_active  = $false
        error_hint       = ''
    }

    if ($null -eq $Lines -or $Lines.Count -eq 0) {
        return $result
    }

    # Detect WSL / colab setup errors in output
    foreach ($ln in $Lines) {
        if ($ln -match 'colab: command not found|Run \./setup-wsl\.sh|WslRegisterDistribution|has no installed distributions|not recognized as an internal') {
            $result.error_hint = $ln.Trim()
            break
        } elseif ($ln -match 'not logged in|authenticate|OAuth|credentials.*expired|colab auth') {
            if (-not $result.error_hint) { $result.error_hint = $ln.Trim() }
        }
    }

    # 1. Try JSON parsing (contract: bash ./status.sh --json prints a single JSON object)
    $jsonCandidate = ''
    for ($i = $Lines.Count - 1; $i -ge 0; $i--) {
        $t = $Lines[$i].Trim()
        if ($t.StartsWith('{') -and $t.EndsWith('}')) {
            $jsonCandidate = $t
            break
        }
    }
    if (-not $jsonCandidate) {
        $joined = (($Lines | ForEach-Object { $_.Trim() }) -join "`n").Trim()
        if ($joined.StartsWith('{') -and $joined.EndsWith('}')) {
            $jsonCandidate = $joined
        }
    }

    if ($jsonCandidate) {
        try {
            $obj = $jsonCandidate | ConvertFrom-Json -ErrorAction Stop
            $props = $obj.PSObject.Properties.Name
            if ($props -contains 'runtime_active' -or $props -contains 'tunnel_connected' -or $props -contains 'strata_running') {
                $result.source = 'json'
                if ($props -contains 'runtime_active' -and $null -ne $obj.runtime_active) {
                    $result.runtime_active = [bool]$obj.runtime_active
                    $result.runtime_known = $true
                    $result.runtime_state = if ($result.runtime_active) { 'RUNNING' } else { 'None' }
                }
                if ($props -contains 'gpu_name' -and $null -ne $obj.gpu_name) {
                    $result.gpu_name = [string]$obj.gpu_name
                }
                if ($props -contains 'vram_used_mib' -and $null -ne $obj.vram_used_mib -and "$($obj.vram_used_mib)" -ne '') {
                    $result.vram_used_mib = [int]$obj.vram_used_mib
                }
                if ($props -contains 'vram_total_mib' -and $null -ne $obj.vram_total_mib -and "$($obj.vram_total_mib)" -ne '') {
                    $result.vram_total_mib = [int]$obj.vram_total_mib
                }
                if ($props -contains 'gpu_util_pct' -and $null -ne $obj.gpu_util_pct -and "$($obj.gpu_util_pct)" -ne '') {
                    $result.gpu_util_pct = [int]$obj.gpu_util_pct
                }
                if ($props -contains 'gpu_temp_c' -and $null -ne $obj.gpu_temp_c -and "$($obj.gpu_temp_c)" -ne '') {
                    $result.gpu_temp_c = [int]$obj.gpu_temp_c
                }
                if ($props -contains 'strata_running' -and $null -ne $obj.strata_running) {
                    $result.strata_running = [bool]$obj.strata_running
                    $result.strata_state = if ($result.strata_running) { 'RUNNING' } elseif ($result.runtime_active) { 'STOPPED' } else { 'OFFLINE' }
                }
                if ($props -contains 'active_model' -and $null -ne $obj.active_model) {
                    $result.active_model = [string]$obj.active_model
                }
                if ($props -contains 'tunnel_connected' -and $null -ne $obj.tunnel_connected) {
                    $result.tunnel_connected = [bool]$obj.tunnel_connected
                    $result.tunnel_known = $true
                }
                if ($props -contains 'local_port' -and $null -ne $obj.local_port -and "$($obj.local_port)" -ne '') {
                    $result.local_port = [int]$obj.local_port
                    $result.tunnel_url = "http://localhost:$($result.local_port)"
                }
                if ($props -contains 'cu_balance' -and $null -ne $obj.cu_balance -and "$($obj.cu_balance)" -ne '') {
                    $result.cu_balance = [double]$obj.cu_balance
                }
                if ($props -contains 'cu_rate' -and $null -ne $obj.cu_rate -and "$($obj.cu_rate)" -ne '') {
                    $result.cu_rate = [double]$obj.cu_rate
                }
                if ($props -contains 'eligible_gpus' -and $null -ne $obj.eligible_gpus) {
                    $result.eligible_gpus = @($obj.eligible_gpus | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
                }
                if ($props -contains 'drive_sync' -and $null -ne $obj.drive_sync) {
                    $result.drive_sync = [string]$obj.drive_sync
                }
                if ($props -contains 'workload_active' -and $null -ne $obj.workload_active) {
                    $result.workload_active = [bool]$obj.workload_active
                }
                return $result
            }
        } catch {
            # Fall through cleanly to legacy text parsing
        }
    }

    # 2. Graceful fallback: parse human-readable status.sh text output
    $result.source = 'text'
    foreach ($ln in $Lines) {
        if ($ln -match 'Current balance:\s*([0-9.]+)\s*compute units') {
            $result.cu_balance = [double]$Matches[1]
        } elseif ($ln -match 'Usage rate:\s*([0-9.]+)\s*/\s*hr') {
            $result.cu_rate = [double]$Matches[1]
        } elseif ($ln -match '^ELIGIBLE_GPUS=(.+)$') {
            $result.eligible_gpus = @($Matches[1].Trim() -split '\s+' | Where-Object { $_ })
        } elseif ($ln -match 'No active (Colab )?runtime') {
            $result.runtime_active = $false
            $result.runtime_known = $true
            $result.runtime_state = 'None'
        } elseif ($ln -match '^\s*(NVIDIA|Tesla|Quadro|RTX|A100|H100|L4|T4|G4)[^,]*,\s*(\d+)\s*MiB,\s*(\d+)\s*MiB(?:,\s*(\d+)\s*%(?:,\s*(\d+))?)?') {
            $parts = $ln.Trim() -split ','
            $result.runtime_active = $true
            $result.runtime_known = $true
            $result.runtime_state = 'RUNNING'
            $result.gpu_name = $parts[0].Trim()
            $result.vram_used_mib = [int]$Matches[2]
            $result.vram_total_mib = [int]$Matches[3]
            if ($Matches[4]) { $result.gpu_util_pct = [int]$Matches[4] }
            if ($Matches[5]) { $result.gpu_temp_c = [int]$Matches[5] }
        } elseif ($ln -match 'Strata Status:\s*(.+)$') {
            $st = $Matches[1].Trim()
            $result.strata_state = $st
            $result.strata_running = ($st -match 'RUNNING')
        } elseif ($ln -match 'Active Model:\s*(.+)$') {
            $result.active_model = $Matches[1].Trim()
        } elseif ($ln -match '^\s*Status:\s*(RUNNING|CONNECTING|ASSIGNED|.+)$') {
            $st = $Matches[1].Trim()
            $result.runtime_state = $st
            $result.runtime_active = ($st -notmatch 'NONE|STOPPED|TERMINATED')
            $result.runtime_known = $true
        } elseif ($ln -match 'Local SSH Tunnel:\s*(https?://\S+)') {
            $url = $Matches[1].Trim().TrimEnd('=')
            $result.tunnel_url = $url
            if ($url -match ':(\d+)') {
                $result.local_port = [int]$Matches[1]
            }
        } elseif ($ln -match '^\s*Connected\s*$') {
            $result.tunnel_connected = $true
            $result.tunnel_known = $true
        } elseif ($ln -match '^\s*Not connected\s*$') {
            $result.tunnel_connected = $false
            $result.tunnel_known = $true
        } elseif ($ln -match 'Sync status:\s*(.+)$') {
            $result.drive_sync = $Matches[1].Trim()
        } elseif ($ln -match 'Config sync:\s*(.+)$') {
            if (-not $result.drive_sync) { $result.drive_sync = $Matches[1].Trim() }
        } elseif ($ln -match 'Active \(streaming via colab exec\)') {
            $result.workload_active = $true
        }
    }

    return $result
}

function Classify-LogLine {
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [string]$Line,
        [string]$CurrentMode = ''
    )

    $evt = @{
        Event       = 'None'
        BadgeText   = ''
        BadgeColor  = ''
        AuthUrl     = ''
        Gpu         = ''
        NextMode    = $CurrentMode
        NotifyTitle = ''
        NotifyBody  = ''
        NotifyIcon  = 'Info'
    }

    if ([string]::IsNullOrWhiteSpace($Line)) {
        return $evt
    }

    # 1. Google Drive OAuth URL
    if ($Line -match '(https://accounts\.google\.com/o/oauth2/\S+)') {
        $evt.Event = 'DriveAuthRequired'
        $evt.AuthUrl = $Matches[1]
        $evt.BadgeText = 'Authorize Drive'
        $evt.BadgeColor = '#F59E0B'
        $evt.NotifyTitle = 'Google Drive OAuth Required'
        $evt.NotifyBody = 'Authorize Google Drive in your browser, then click Continue in Strata Colab Desktop.'
        $evt.NotifyIcon = 'Warning'
        return $evt
    }

    # 2. Drive mount completed
    if ($Line -match 'Credentials propagated|Mounted at|Google Drive already mounted') {
        $evt.Event = 'DriveAuthDone'
        return $evt
    }

    # 3. Tunnel ready (strict contract markers + exact ready lines; no overly broad "is running")
    if ($Line -match '\[STRATA_STATE:tunnel_ready\]|Strata is ready!|Press Ctrl\+C to disconnect|Local tunnel active|SSH tunnel running') {
        $evt.Event = 'TunnelReady'
        $evt.NextMode = 'tunnel'
        $evt.BadgeText = 'Tunnel Active'
        $evt.BadgeColor = '#22C55E'
        if ($CurrentMode -ne 'tunnel') {
            $evt.NotifyTitle = 'Strata Tunnel Ready'
            $evt.NotifyBody = 'Colab GPU session is live and your local Strata tunnel is connected.'
            $evt.NotifyIcon = 'Info'
        }
        return $evt
    }

    # 4. Probing GPU (never regress once tunnel is active)
    if ($Line -match '\[STRATA_STATE:probing:([A-Za-z0-9_-]+)\]') {
        if ($CurrentMode -ne 'tunnel') {
            $evt.Event = 'Probing'
            $evt.Gpu = $Matches[1]
            $evt.BadgeText = "Probing $($Matches[1])..."
            $evt.BadgeColor = '#38BDF8'
        }
        return $evt
    }
    if ($Line -match 'Trying (G4|H100|A100|L4|T4)\b') {
        if ($CurrentMode -ne 'tunnel') {
            $evt.Event = 'Probing'
            $evt.Gpu = $Matches[1]
            $evt.BadgeText = "Probing $($Matches[1])..."
            $evt.BadgeColor = '#38BDF8'
        }
        return $evt
    }

    # 5. Starting / downloading (never regress once tunnel is active)
    if ($Line -match '\[STRATA_STATE:starting\]|Downloading|Extracting|Starting Strata|Preparing Strata') {
        if ($CurrentMode -ne 'tunnel') {
            $evt.Event = 'Starting'
            $evt.BadgeText = 'Starting Strata...'
            $evt.BadgeColor = '#38BDF8'
        }
        return $evt
    }

    # 6. Auto-Tune finished
    if ($Line -match 'Strata tuning finished!') {
        $evt.Event = 'TuneDone'
        $evt.NotifyTitle = 'Strata Auto-Tune Complete'
        $evt.NotifyBody = 'Hardware calibration finished and presets were synced.'
        $evt.NotifyIcon = 'Info'
        return $evt
    }

    # 7. Notable fatal error lines
    if ($Line -match '^(?:\[ERROR\]|ERROR:|FATAL:)|Startup failed after \d+ retries|Insufficient disk space:|Cannot connect over SSH|No capacity available right now') {
        $evt.Event = 'Error'
        $evt.NotifyTitle = 'Strata Colab Error'
        $evt.NotifyBody = $Line.Trim()
        $evt.NotifyIcon = 'Error'
        return $evt
    }

    return $evt
}

function Redact-DiagnosticsText {
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [AllowNull()]
        [string]$Text
    )

    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $out = $Text
    # Redact .env style secrets
    $out = [System.Text.RegularExpressions.Regex]::Replace(
        $out,
        '(?im)^(\s*(?:export\s+)?(?:API_KEY|HF_TOKEN|HUGGING_FACE_HUB_TOKEN|ANTHROPIC_API_KEY|ANTHROPIC_AUTH_TOKEN|OPENAI_API_KEY)\s*=\s*)(.+)$',
        '$1<REDACTED>'
    )
    # Redact JSON api_key / apiKey / token fields
    $out = [System.Text.RegularExpressions.Regex]::Replace(
        $out,
        '(?i)("(?:api_key|apiKey|hf_token|access_token|refresh_token|ANTHROPIC_AUTH_TOKEN|ANTHROPIC_API_KEY)"\s*:\s*")([^"]*)(")',
        '$1<REDACTED>$3'
    )
    # Redact Authorization Bearer headers and common token prefixes
    $out = [System.Text.RegularExpressions.Regex]::Replace($out, '(?i)(Bearer\s+)[A-Za-z0-9._~+/=-]{8,}', '$1<REDACTED>')
    $out = [System.Text.RegularExpressions.Regex]::Replace($out, '\bhf_[A-Za-z0-9]{10,}\b', '<REDACTED_HF_TOKEN>')
    $out = [System.Text.RegularExpressions.Regex]::Replace($out, '\bsk-[A-Za-z0-9_-]{12,}\b', '<REDACTED_API_KEY>')
    $out = [System.Text.RegularExpressions.Regex]::Replace($out, '(?i)([?&](?:code|access_token|refresh_token)=)[^&\s]+', '$1<REDACTED>')
    return $out
}

function Get-ClientConnectSnippets {
    [CmdletBinding()]
    param(
        [string]$LocalPort = '8080',
        [string]$ApiKey = '',
        [string]$ActiveModel = ''
    )

    $port = if ([string]::IsNullOrWhiteSpace($LocalPort)) { '8080' } else { $LocalPort.Trim() }
    $baseUrl = "http://localhost:$port"
    $openaiBase = "$baseUrl/v1"
    $tokenVal = if ([string]::IsNullOrWhiteSpace($ApiKey)) { 'strata-local' } else { $ApiKey }
    $modelVal = if ([string]::IsNullOrWhiteSpace($ActiveModel)) { 'strata' } else { $ActiveModel }

    $claudeJson = @"
{
  "env": {
    "ANTHROPIC_BASE_URL": "$baseUrl",
    "ANTHROPIC_AUTH_TOKEN": "$tokenVal",
    "CLAUDE_CODE_ATTRIBUTION_HEADER": "0"
  }
}
"@

    $cursorCline = @"
# OpenAI-Compatible Endpoint (Cursor / Cline / Continue / Roo Code)
Base URL  : $openaiBase
API Key   : $tokenVal
Model ID  : $modelVal

# Anthropic Messages API Endpoint
Base URL  : $baseUrl

# Continue (~/.continue/config.yaml) example:
models:
  - name: Strata Colab ($modelVal)
    provider: openai
    model: $modelVal
    apiBase: $openaiBase
    apiKey: $tokenVal
"@

    $pythonSdk = @"
from openai import OpenAI

client = OpenAI(
    base_url="$openaiBase",
    api_key="$tokenVal",
)

resp = client.chat.completions.create(
    model="$modelVal",
    messages=[{"role": "user", "content": "Hello from Strata on Google Colab!"}],
)
print(resp.choices[0].message.content)
"@

    return @{
        BaseUrl       = $baseUrl
        OpenAiBaseUrl = $openaiBase
        ClaudeJson    = $claudeJson.Trim()
        CursorCline   = $cursorCline.Trim()
        PythonSdk     = $pythonSdk.Trim()
    }
}

function Merge-ClaudeSettingsJson {
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [AllowNull()]
        [string]$ExistingJson = '',
        [string]$LocalPort = '8080',
        [string]$ApiKey = ''
    )

    $port = if ([string]::IsNullOrWhiteSpace($LocalPort)) { '8080' } else { $LocalPort.Trim() }
    $baseUrl = "http://localhost:$port"
    $tokenVal = if ([string]::IsNullOrWhiteSpace($ApiKey)) { 'strata-local' } else { $ApiKey }

    $root = [ordered]@{}
    if (-not [string]::IsNullOrWhiteSpace($ExistingJson)) {
        $parsed = $ExistingJson | ConvertFrom-Json -ErrorAction Stop
        foreach ($prop in $parsed.PSObject.Properties) {
            $root[$prop.Name] = $prop.Value
        }
    }

    $envMap = [ordered]@{}
    if ($root.Contains('env') -and $null -ne $root['env']) {
        foreach ($prop in $root['env'].PSObject.Properties) {
            $envMap[$prop.Name] = $prop.Value
        }
    }

    $envMap['ANTHROPIC_BASE_URL'] = $baseUrl
    $envMap['ANTHROPIC_AUTH_TOKEN'] = $tokenVal
    $envMap['CLAUDE_CODE_ATTRIBUTION_HEADER'] = '0'
    $root['env'] = $envMap

    return ($root | ConvertTo-Json -Depth 10)
}

Export-ModuleMember -Function @(
    'Write-StrataIconFile',
    'Format-BashEnvValue',
    'ConvertFrom-BashEnvValue',
    'Read-StrataConfig',
    'Write-LocalConfigOverrides',
    'ConvertTo-Win32Arg',
    'Build-WslArgs',
    'Build-SessionEnvCommand',
    'Parse-StatusPayload',
    'Classify-LogLine',
    'Redact-DiagnosticsText',
    'Get-ClientConnectSnippets',
    'Merge-ClaudeSettingsJson'
)
