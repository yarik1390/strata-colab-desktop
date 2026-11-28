<#
.SYNOPSIS
    Self-contained PowerShell 5.1 test suite for Strata Colab Desktop helpers
    and WPF launcher smoke test. Requires zero external modules.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$TestsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = (Resolve-Path (Join-Path $TestsDir '..')).Path
$UiDir = Join-Path $RepoRoot 'ui'
$HelpersPath = Join-Path $UiDir 'StrataHelpers.psm1'
$LauncherPath = Join-Path $UiDir 'StrataLauncher.ps1'
$ShortcutPath = Join-Path $UiDir 'Create-Shortcut.ps1'
$SelfPath = $MyInvocation.MyCommand.Path

$script:PassedCount = 0
$script:FailedCount = 0
$script:Failures = New-Object System.Collections.Generic.List[string]

function Fail-Assertion {
    param([string]$Message)
    throw [System.Exception]::new("Assertion failed: $Message")
}

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message = 'Expected condition to be True'
    )
    if (-not $Condition) {
        Fail-Assertion $Message
    }
}

function Assert-False {
    param(
        [bool]$Condition,
        [string]$Message = 'Expected condition to be False'
    )
    if ($Condition) {
        Fail-Assertion $Message
    }
}

function Assert-Equal {
    param(
        $Expected,
        $Actual,
        [string]$Message = ''
    )
    $equal = $false
    if ($null -eq $Expected -and $null -eq $Actual) {
        $equal = $true
    } elseif ($null -ne $Expected -and $null -ne $Actual) {
        if ($Expected -is [string] -and $Actual -is [string]) {
            $equal = [string]::Equals($Expected, $Actual, [System.StringComparison]::Ordinal)
        } else {
            $equal = ($Expected -eq $Actual)
        }
    }
    if (-not $equal) {
        $prefix = if ($Message) { "$Message - " } else { '' }
        Fail-Assertion "${prefix}Expected <$Expected> but got <$Actual>"
    }
}

function Assert-Null {
    param(
        $Value,
        [string]$Message = 'Expected value to be null'
    )
    if ($null -ne $Value) {
        Fail-Assertion "$Message - got <$Value>"
    }
}

function Assert-Match {
    param(
        [string]$Text,
        [string]$Pattern,
        [string]$Message = ''
    )
    if ($Text -notmatch $Pattern) {
        $prefix = if ($Message) { "$Message - " } else { '' }
        Fail-Assertion "${prefix}Expected <$Text> to match regex <$Pattern>"
    }
}

function Assert-Contains {
    param(
        [string]$Text,
        [string]$Substring,
        [string]$Message = ''
    )
    if ($null -eq $Text -or -not $Text.Contains($Substring)) {
        $prefix = if ($Message) { "$Message - " } else { '' }
        Fail-Assertion "${prefix}Expected text to contain <$Substring>"
    }
}

function Assert-NotContains {
    param(
        [string]$Text,
        [string]$Substring,
        [string]$Message = ''
    )
    if ($null -ne $Text -and $Text.Contains($Substring)) {
        $prefix = if ($Message) { "$Message - " } else { '' }
        Fail-Assertion "${prefix}Expected text NOT to contain <$Substring>"
    }
}

function Invoke-TestCase {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Body
    )
    try {
        & $Body
        $script:PassedCount++
        Write-Output "  [PASS] $Name"
    } catch {
        $script:FailedCount++
        $detail = $_.Exception.Message
        $script:Failures.Add("${Name}: $detail")
        Write-Output "  [FAIL] ${Name}: $detail"
    }
}

function New-TempTestDir {
    $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("strata-ps-test-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    return $dir
}

Write-Output "=== Strata Colab Desktop PowerShell Test Suite (PS $($PSVersionTable.PSVersion)) ==="

# ------------------------------------------------------------------------------
# 1. PowerShell 5.1 AST Syntax Validation
# ------------------------------------------------------------------------------
$astTargets = @(
    @{ Name = 'ui\StrataHelpers.psm1';        Path = $HelpersPath },
    @{ Name = 'ui\StrataLauncher.ps1';        Path = $LauncherPath },
    @{ Name = 'ui\Create-Shortcut.ps1';       Path = $ShortcutPath },
    @{ Name = 'tests\StrataHelpers.Tests.ps1'; Path = $SelfPath }
)

foreach ($target in $astTargets) {
    $tName = $target.Name
    $tPath = $target.Path
    Invoke-TestCase -Name "AST parse: $tName" -Body {
        Assert-True (Test-Path -LiteralPath $tPath) "File missing: $tPath"
        $tokens = $null
        $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($tPath, [ref]$tokens, [ref]$errors)
        if ($errors -and $errors.Count -gt 0) {
            $summary = ($errors | ForEach-Object { "L$($_.Extent.StartLineNumber): $($_.Message)" }) -join '; '
            Fail-Assertion "Parse errors in ${tName}: $summary"
        }
        Assert-Equal 0 $errors.Count "Expected 0 AST parse errors in $tName"
    }
}

# Import helper module under test
Import-Module $HelpersPath -Force -DisableNameChecking

Invoke-TestCase -Name 'Module exports all 13 helper functions' -Body {
    $expected = @(
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
    $mod = Get-Module -Name 'StrataHelpers'
    Assert-True ($null -ne $mod) 'StrataHelpers module not loaded'
    $exported = @($mod.ExportedCommands.Keys)
    foreach ($fn in $expected) {
        Assert-True ($exported -contains $fn) "Missing exported function: $fn"
    }
    Assert-Equal $expected.Count $exported.Count 'Unexpected number of exported helper functions'
}

# ------------------------------------------------------------------------------
# 2. Write-StrataIconFile
# ------------------------------------------------------------------------------
Invoke-TestCase -Name 'Write-StrataIconFile creates valid ICO magic bytes and respects -Force' -Body {
    $tmp = New-TempTestDir
    try {
        $icoPath = Join-Path $tmp 'nested\strata-test.ico'
        Write-StrataIconFile -OutPath $icoPath
        Assert-True (Test-Path -LiteralPath $icoPath) 'ICO file was not created'
        $bytes = [System.IO.File]::ReadAllBytes($icoPath)
        Assert-True ($bytes.Length -gt 200) "ICO file unexpectedly small: $($bytes.Length) bytes"
        Assert-Equal ([byte]0x00) $bytes[0] 'ICO header byte 0'
        Assert-Equal ([byte]0x00) $bytes[1] 'ICO header byte 1'
        Assert-Equal ([byte]0x01) $bytes[2] 'ICO header byte 2 (icon type)'
        Assert-Equal ([byte]0x00) $bytes[3] 'ICO header byte 3'
        Assert-Equal ([byte]0x04) $bytes[4] 'ICO image count low byte (4 sizes)'
        Assert-Equal ([byte]0x00) $bytes[5] 'ICO image count high byte'

        # Without -Force, existing file should not be overwritten
        $sentinel = [byte[]]@(0x41, 0x42, 0x43)
        [System.IO.File]::WriteAllBytes($icoPath, $sentinel)
        Write-StrataIconFile -OutPath $icoPath
        $afterNoForce = [System.IO.File]::ReadAllBytes($icoPath)
        Assert-Equal 3 $afterNoForce.Length 'Expected existing file to remain untouched without -Force'

        # With -Force, existing file should be regenerated
        Write-StrataIconFile -OutPath $icoPath -Force
        $afterForce = [System.IO.File]::ReadAllBytes($icoPath)
        Assert-True ($afterForce.Length -gt 200) 'Expected -Force to regenerate ICO file'
        Assert-Equal ([byte]0x01) $afterForce[2] 'Expected regenerated ICO header'
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ------------------------------------------------------------------------------
# 3. Format-BashEnvValue & ConvertFrom-BashEnvValue
# ------------------------------------------------------------------------------
Invoke-TestCase -Name 'Format-BashEnvValue and ConvertFrom-BashEnvValue escape and round-trip safely' -Body {
    Assert-Equal 'AUTO' (Format-BashEnvValue -Value 'AUTO') 'Simple token unquoted'
    Assert-Equal "''" (Format-BashEnvValue -Value '') 'Empty string formatted as single quotes'
    Assert-Equal "''" (Format-BashEnvValue -Value $null) 'Null string formatted as single quotes'
    Assert-Equal "'hello world'" (Format-BashEnvValue -Value 'hello world') 'Spaces single-quoted'
    Assert-Equal "'`$HOME/*.gguf'" (Format-BashEnvValue -Value '$HOME/*.gguf') 'Dollar and glob single-quoted'

    $tricky = "it's a `$HOME `test` with ""quotes"" and spaces"
    $formatted = Format-BashEnvValue -Value $tricky
    Assert-Contains $formatted "'\''" 'Single quote must be bash-escaped'
    $roundTrip = ConvertFrom-BashEnvValue -RawValue $formatted
    Assert-Equal $tricky $roundTrip 'Round-trip of tricky value'

    Assert-Equal '' (ConvertFrom-BashEnvValue -RawValue "''") 'Empty single quotes decode to empty string'
    Assert-Equal 'AUTO' (ConvertFrom-BashEnvValue -RawValue 'AUTO # inline comment') 'Inline comment stripped'
    Assert-Equal 'foo "bar" $baz' (ConvertFrom-BashEnvValue -RawValue '"foo \"bar\" \$baz"') 'Double-quoted escapes decoded'
}

# ------------------------------------------------------------------------------
# 4. Read-StrataConfig & Write-LocalConfigOverrides
# ------------------------------------------------------------------------------
Invoke-TestCase -Name 'Read-StrataConfig & Write-LocalConfigOverrides escape, preserve unmanaged keys, and round-trip' -Body {
    $tmp = New-TempTestDir
    try {
        $baseCfg = Join-Path $tmp 'config.env'
        $localCfg = Join-Path $tmp 'config.local.env'
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)

        $baseLines = @(
            '# Base config',
            'GPU=AUTO # best available',
            'MODEL=AUTO',
            "MODEL_FAMILY=''",
            'export LOCAL_PORT=8080',
            'CONTEXT=262144'
        ) -join "`n"
        [System.IO.File]::WriteAllText($baseCfg, $baseLines + "`n", $utf8NoBom)

        $existingLocal = @(
            '# User custom comment',
            'HF_TOKEN=custom_unmanaged_placeholder',
            'USER_CUSTOM_FLAG=enabled',
            'GPU=L4'
        ) -join "`n"
        [System.IO.File]::WriteAllText($localCfg, $existingLocal + "`n", $utf8NoBom)

        $initial = Read-StrataConfig -ConfigPath $baseCfg -LocalConfigPath $localCfg
        Assert-Equal 'L4' $initial['GPU'] 'Local config must override base config'
        Assert-Equal '' $initial['MODEL_FAMILY'] 'Empty MODEL_FAMILY parsed cleanly'
        Assert-Equal '8080' $initial['LOCAL_PORT'] 'Exported key parsed cleanly'
        Assert-Equal 'custom_unmanaged_placeholder' $initial['HF_TOKEN'] 'Unmanaged HF_TOKEN read'

        $extraArgs = "--vision yes --note 'don't expand `$HOME'"
        $overrides = @{
            GPU               = 'G4'
            MODEL_FAMILY      = ''
            STRATA_EXTRA_ARGS = $extraArgs
        }
        Write-LocalConfigOverrides -LocalConfigPath $localCfg -Overrides $overrides
        # Write a second time to verify managed header does not duplicate
        Write-LocalConfigOverrides -LocalConfigPath $localCfg -Overrides $overrides

        $rawBytes = [System.IO.File]::ReadAllBytes($localCfg)
        Assert-False ($rawBytes.Length -ge 3 -and $rawBytes[0] -eq 0xEF -and $rawBytes[1] -eq 0xBB -and $rawBytes[2] -eq 0xBF) 'config.local.env must not have UTF-8 BOM'

        $rawText = [System.IO.File]::ReadAllText($localCfg, $utf8NoBom)
        Assert-NotContains $rawText "`r" 'config.local.env must use LF line endings'
        Assert-Contains $rawText "MODEL_FAMILY=''" 'Empty MODEL_FAMILY must be written explicitly'
        Assert-Contains $rawText "STRATA_EXTRA_ARGS='--vision yes --note '\''don'\''t expand `$HOME'\'''" 'Bash single-quote escaping for spaces/$/quotes'
        Assert-Contains $rawText 'HF_TOKEN=custom_unmanaged_placeholder' 'Unmanaged HF_TOKEN must be preserved'
        Assert-Contains $rawText 'USER_CUSTOM_FLAG=enabled' 'Unmanaged custom key must be preserved'
        Assert-Contains $rawText '# User custom comment' 'User comments must be preserved'

        $headerMatches = [System.Text.RegularExpressions.Regex]::Matches($rawText, '(?m)^# Managed by Strata Colab Desktop UI$')
        Assert-Equal 1 $headerMatches.Count 'Managed header must appear exactly once'

        $reloaded = Read-StrataConfig -ConfigPath $baseCfg -LocalConfigPath $localCfg
        Assert-Equal 'G4' $reloaded['GPU'] 'Updated GPU round-tripped'
        Assert-Equal '' $reloaded['MODEL_FAMILY'] 'Empty MODEL_FAMILY round-tripped'
        Assert-Equal $extraArgs $reloaded['STRATA_EXTRA_ARGS'] 'Escaped STRATA_EXTRA_ARGS round-tripped'
        Assert-Equal 'custom_unmanaged_placeholder' $reloaded['HF_TOKEN'] 'Preserved HF_TOKEN round-tripped'
        Assert-Equal 'enabled' $reloaded['USER_CUSTOM_FLAG'] 'Preserved USER_CUSTOM_FLAG round-tripped'
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ------------------------------------------------------------------------------
# 5. ConvertTo-Win32Arg & Build-WslArgs
# ------------------------------------------------------------------------------
Invoke-TestCase -Name 'ConvertTo-Win32Arg escapes quotes and trailing backslashes' -Body {
    Assert-Equal '""' (ConvertTo-Win32Arg -Value '') 'Empty string quoted'
    Assert-Equal '"C:\My Repo\path"' (ConvertTo-Win32Arg -Value 'C:\My Repo\path') 'Spaces quoted'
    Assert-Equal '"C:\Repo\\"' (ConvertTo-Win32Arg -Value 'C:\Repo\') 'Trailing backslash doubled'
    Assert-Equal '"echo \"hello\""' (ConvertTo-Win32Arg -Value 'echo "hello"') 'Embedded double quotes escaped'
}

Invoke-TestCase -Name 'Build-WslArgs builds --exec args, quotes distro with spaces, and escapes commands' -Body {
    $noDistro = Build-WslArgs -BashCommand 'bash ./status.sh --json' -RepoRoot 'D:\My Work\strata-colab-cli'
    Assert-NotContains $noDistro '-d ' 'Must not include -d when distro is empty'
    Assert-Contains $noDistro '--cd "D:\My Work\strata-colab-cli"' 'RepoRoot quoted with --cd'
    Assert-Contains $noDistro '--exec bash -lc "bash ./status.sh --json"' 'Uses --exec bash -lc'

    $withDistro = Build-WslArgs -BashCommand 'echo "hi there"' -RepoRoot 'D:\Repo' -Distro 'Ubuntu 24.04 LTS'
    Assert-True ($withDistro.StartsWith('-d "Ubuntu 24.04 LTS" ')) 'Distro with spaces quoted after -d'
    Assert-Contains $withDistro '--cd "D:\Repo"' 'RepoRoot included'
    Assert-Contains $withDistro '--exec bash -lc "echo \"hi there\""' 'Command quotes escaped cleanly'
}

# ------------------------------------------------------------------------------
# 6. Build-SessionEnvCommand
# ------------------------------------------------------------------------------
Invoke-TestCase -Name 'Build-SessionEnvCommand includes all 18 contract env vars cleanly' -Body {
    $selection = @{
        GPU                     = 'AUTO'
        MODEL                   = 'AUTO'
        MODEL_FAMILY            = ''
        CONTEXT                 = '262144'
        UI_MODE                 = 'desktop'
        TUNE_ON_START           = '1'
        USE_DRIVE               = '1'
        DRIVE_MODEL_CACHE       = '0'
        HIGH_MEM                = '1'
        ACTIVE_WORKLOAD_MONITOR = '1'
        OPEN_BROWSER            = '1'
        STRATA_KV_CACHE         = 'int8'
        STRATA_VISION           = 'gpu'
        STRATA_DRAFTER          = 'dflash2'
        AUTO_STOP_IDLE_MIN      = '30'
        MODEL_REPO              = 'org/custom-gguf'
        MODEL_FILES             = '*IQ3_S*.gguf'
        STRATA_EXTRA_ARGS       = '--threads 8 --note "$test"'
    }
    $cmd = Build-SessionEnvCommand -ScriptName 'up.sh' -Selection $selection -ExtraEnv @{ CUSTOM_KEY = 'a b' }

    Assert-True ($cmd.StartsWith('env STRATA_UI_HOST=1 ASK_GPU=0 ASK_MODEL=0 ')) 'Starts with UI contract env flags'
    Assert-True ($cmd.EndsWith(' bash ./up.sh')) 'Ends with bash ./up.sh'

    $expectedTokens = @(
        'GPU=AUTO',
        'MODEL=AUTO',
        "MODEL_FAMILY=''",
        'CONTEXT=262144',
        'UI_MODE=desktop',
        'TUNE_ON_START=1',
        'USE_DRIVE=1',
        'DRIVE_MODEL_CACHE=0',
        'HIGH_MEM=1',
        'ACTIVE_WORKLOAD_MONITOR=1',
        'OPEN_BROWSER=1',
        'STRATA_KV_CACHE=int8',
        'STRATA_VISION=gpu',
        'STRATA_DRAFTER=dflash2',
        'AUTO_STOP_IDLE_MIN=30',
        'MODEL_REPO=org/custom-gguf',
        "MODEL_FILES='*IQ3_S*.gguf'",
        "STRATA_EXTRA_ARGS='--threads 8 --note `"`$test`"'" ,
        "CUSTOM_KEY='a b'"
    )
    foreach ($tok in $expectedTokens) {
        Assert-Contains $cmd $tok "Missing expected env token: $tok"
    }
}

# ------------------------------------------------------------------------------
# 7. Parse-StatusPayload
# ------------------------------------------------------------------------------
Invoke-TestCase -Name 'Parse-StatusPayload parses active 15-key status.sh --json payload' -Body {
    $jsonLine = '{"runtime_active":true,"gpu_name":"NVIDIA RTX PRO 6000 Blackwell","vram_used_mib":61440,"vram_total_mib":98304,"gpu_util_pct":42,"gpu_temp_c":58,"strata_running":true,"active_model":"nvfp4-NVFP4","tunnel_connected":true,"local_port":8080,"cu_balance":123.45,"cu_rate":1.96,"eligible_gpus":["G4","H100","A100","L4","T4"],"drive_sync":"DONE | config:OK","workload_active":true}'
    $parsed = Parse-StatusPayload -Lines @('[info] status probe', $jsonLine)

    Assert-Equal 'json' $parsed.source 'Source should be json'
    Assert-True $parsed.runtime_active 'runtime_active'
    Assert-True $parsed.runtime_known 'runtime_known'
    Assert-Equal 'RUNNING' $parsed.runtime_state 'runtime_state'
    Assert-Equal 'NVIDIA RTX PRO 6000 Blackwell' $parsed.gpu_name 'gpu_name'
    Assert-Equal 61440 $parsed.vram_used_mib 'vram_used_mib'
    Assert-Equal 98304 $parsed.vram_total_mib 'vram_total_mib'
    Assert-Equal 42 $parsed.gpu_util_pct 'gpu_util_pct'
    Assert-Equal 58 $parsed.gpu_temp_c 'gpu_temp_c'
    Assert-True $parsed.strata_running 'strata_running'
    Assert-Equal 'RUNNING' $parsed.strata_state 'strata_state'
    Assert-Equal 'nvfp4-NVFP4' $parsed.active_model 'active_model'
    Assert-True $parsed.tunnel_connected 'tunnel_connected'
    Assert-True $parsed.tunnel_known 'tunnel_known'
    Assert-Equal 8080 $parsed.local_port 'local_port'
    Assert-Equal 'http://localhost:8080' $parsed.tunnel_url 'tunnel_url'
    Assert-Equal 123.45 $parsed.cu_balance 'cu_balance'
    Assert-Equal 1.96 $parsed.cu_rate 'cu_rate'
    Assert-Equal 5 $parsed.eligible_gpus.Count 'eligible_gpus count'
    Assert-Equal 'G4' $parsed.eligible_gpus[0] 'first eligible GPU'
    Assert-Equal 'DONE | config:OK' $parsed.drive_sync 'drive_sync'
    Assert-True $parsed.workload_active 'workload_active'
}

Invoke-TestCase -Name 'Parse-StatusPayload parses idle 15-key status.sh --json payload' -Body {
    $jsonLine = '{"runtime_active":false,"gpu_name":"","vram_used_mib":0,"vram_total_mib":0,"gpu_util_pct":null,"gpu_temp_c":null,"strata_running":false,"active_model":"","tunnel_connected":false,"local_port":8080,"cu_balance":50.0,"cu_rate":null,"eligible_gpus":["L4","T4"],"drive_sync":"","workload_active":false}'
    $parsed = Parse-StatusPayload -Lines @($jsonLine)

    Assert-Equal 'json' $parsed.source 'Source should be json'
    Assert-False $parsed.runtime_active 'runtime_active false'
    Assert-True $parsed.runtime_known 'runtime_known true'
    Assert-Equal 'None' $parsed.runtime_state 'runtime_state None'
    Assert-Equal '' $parsed.gpu_name 'gpu_name empty'
    Assert-Equal 0 $parsed.vram_used_mib 'vram_used_mib 0'
    Assert-Equal 0 $parsed.vram_total_mib 'vram_total_mib 0'
    Assert-Null $parsed.gpu_util_pct 'gpu_util_pct null'
    Assert-Null $parsed.gpu_temp_c 'gpu_temp_c null'
    Assert-False $parsed.strata_running 'strata_running false'
    Assert-Equal 'OFFLINE' $parsed.strata_state 'strata_state OFFLINE'
    Assert-False $parsed.tunnel_connected 'tunnel_connected false'
    Assert-True $parsed.tunnel_known 'tunnel_known true'
    Assert-Equal 50.0 $parsed.cu_balance 'cu_balance'
    Assert-Null $parsed.cu_rate 'cu_rate null'
    Assert-Equal 2 $parsed.eligible_gpus.Count 'eligible_gpus count'
    Assert-False $parsed.workload_active 'workload_active false'
}

Invoke-TestCase -Name 'Parse-StatusPayload parses legacy human text fallback (active and idle)' -Body {
    $activeLines = @(
        'Colab Runtime (strata):',
        '    NVIDIA L4, 18432 MiB, 23034 MiB, 65 %, 54',
        '    Strata Status: RUNNING',
        '    Active Model: IQ2_XS',
        '    Sync status: DONE',
        'Local SSH Tunnel: http://localhost:8080',
        '    Connected',
        '    Active (streaming via colab exec): step 2',
        '    Current balance: 88.5 compute units',
        '    Usage rate: 1.25 / hr',
        'ELIGIBLE_GPUS=G4 H100 L4'
    )
    $active = Parse-StatusPayload -Lines $activeLines
    Assert-Equal 'text' $active.source 'Legacy active source'
    Assert-True $active.runtime_active 'Legacy active runtime_active'
    Assert-Equal 'NVIDIA L4' $active.gpu_name 'Legacy gpu_name'
    Assert-Equal 18432 $active.vram_used_mib 'Legacy vram_used_mib'
    Assert-Equal 23034 $active.vram_total_mib 'Legacy vram_total_mib'
    Assert-Equal 65 $active.gpu_util_pct 'Legacy gpu_util_pct'
    Assert-Equal 54 $active.gpu_temp_c 'Legacy gpu_temp_c'
    Assert-True $active.strata_running 'Legacy strata_running'
    Assert-Equal 'IQ2_XS' $active.active_model 'Legacy active_model'
    Assert-True $active.tunnel_connected 'Legacy tunnel_connected'
    Assert-Equal 8080 $active.local_port 'Legacy local_port'
    Assert-Equal 'DONE' $active.drive_sync 'Legacy drive_sync'
    Assert-True $active.workload_active 'Legacy workload_active'
    Assert-Equal 88.5 $active.cu_balance 'Legacy cu_balance'
    Assert-Equal 1.25 $active.cu_rate 'Legacy cu_rate'
    Assert-Equal 3 $active.eligible_gpus.Count 'Legacy eligible_gpus count'

    $idleLines = @(
        '    No active Colab runtime',
        'Local SSH Tunnel: http://localhost:8080',
        '    Not connected',
        '    colab: command not found'
    )
    $idle = Parse-StatusPayload -Lines $idleLines
    Assert-Equal 'text' $idle.source 'Legacy idle source'
    Assert-False $idle.runtime_active 'Legacy idle runtime_active'
    Assert-True $idle.runtime_known 'Legacy idle runtime_known'
    Assert-Equal 'None' $idle.runtime_state 'Legacy idle runtime_state'
    Assert-False $idle.tunnel_connected 'Legacy idle tunnel_connected'
    Assert-True $idle.tunnel_known 'Legacy idle tunnel_known'
    Assert-Contains $idle.error_hint 'colab: command not found' 'Detects setup error hint'

    $empty = Parse-StatusPayload -Lines @()
    Assert-Equal 'empty' $empty.source 'Empty lines produce empty source'
}

# ------------------------------------------------------------------------------
# 8. Classify-LogLine
# ------------------------------------------------------------------------------
Invoke-TestCase -Name 'Classify-LogLine handles state markers, exact ready strings, and prevents false triggers/regression' -Body {
    $p = Classify-LogLine -Line '[STRATA_STATE:probing:G4]' -CurrentMode 'starting'
    Assert-Equal 'Probing' $p.Event 'Probing marker event'
    Assert-Equal 'G4' $p.Gpu 'Probing GPU extracted'
    Assert-Equal 'Probing G4...' $p.BadgeText 'Probing badge text'

    $p2 = Classify-LogLine -Line 'Trying A100 (HIGH_RAM)...' -CurrentMode 'starting'
    Assert-Equal 'Probing' $p2.Event 'Trying A100 event'
    Assert-Equal 'A100' $p2.Gpu 'Trying A100 GPU'

    $s = Classify-LogLine -Line '[STRATA_STATE:starting]' -CurrentMode 'starting'
    Assert-Equal 'Starting' $s.Event 'Starting marker event'
    Assert-Equal 'Starting Strata...' $s.BadgeText 'Starting badge text'

    foreach ($readyLine in @(
        '[STRATA_STATE:tunnel_ready]',
        'Strata is ready!',
        'Press Ctrl+C to disconnect',
        'Local tunnel active on 127.0.0.1:8080',
        'SSH tunnel running'
    )) {
        $r = Classify-LogLine -Line $readyLine -CurrentMode 'starting'
        Assert-Equal 'TunnelReady' $r.Event "Expected TunnelReady for: $readyLine"
        Assert-Equal 'tunnel' $r.NextMode "Expected NextMode=tunnel for: $readyLine"
        Assert-Equal 'Tunnel Active' $r.BadgeText "Expected Tunnel Active badge for: $readyLine"
        Assert-True ($r.NotifyTitle.Length -gt 0) "Expected notification title on transition to tunnel for: $readyLine"
    }

    # Repeated TunnelReady while already in tunnel mode must not fire duplicate toast
    $repeatReady = Classify-LogLine -Line '[STRATA_STATE:tunnel_ready]' -CurrentMode 'tunnel'
    Assert-Equal 'TunnelReady' $repeatReady.Event 'Repeated tunnel ready event'
    Assert-Equal '' $repeatReady.NotifyTitle 'No duplicate notification when already in tunnel mode'

    # Must NOT falsely trigger TunnelReady on arbitrary "is running" lines
    foreach ($noise in @(
        'Background cache sync is running',
        'Docker daemon is running',
        'System service is running normally'
    )) {
        $n = Classify-LogLine -Line $noise -CurrentMode 'starting'
        Assert-Equal 'None' $n.Event "Must NOT falsely trigger on: $noise"
        Assert-Equal 'starting' $n.NextMode "Mode must remain unchanged on: $noise"
    }

    # Must NOT regress from tunnel mode on probing/starting lines
    foreach ($lateLine in @(
        '[STRATA_STATE:probing:G4]',
        'Trying H100 now',
        '[STRATA_STATE:starting]',
        'Downloading model shards...'
    )) {
        $nr = Classify-LogLine -Line $lateLine -CurrentMode 'tunnel'
        Assert-Equal 'None' $nr.Event "Must not regress from tunnel mode on: $lateLine"
        Assert-Equal 'tunnel' $nr.NextMode "NextMode must stay tunnel on: $lateLine"
    }

    # OAuth, Drive mount, Auto-Tune, and fatal error markers
    $oauth = Classify-LogLine -Line 'Open https://accounts.google.com/o/oauth2/auth?client_id=123 to continue' -CurrentMode 'starting'
    Assert-Equal 'DriveAuthRequired' $oauth.Event 'OAuth event'
    Assert-Equal 'https://accounts.google.com/o/oauth2/auth?client_id=123' $oauth.AuthUrl 'OAuth URL captured'

    $mounted = Classify-LogLine -Line 'Mounted at /content/drive' -CurrentMode 'starting'
    Assert-Equal 'DriveAuthDone' $mounted.Event 'DriveAuthDone event'

    $tuned = Classify-LogLine -Line 'Strata tuning finished!' -CurrentMode 'tunnel'
    Assert-Equal 'TuneDone' $tuned.Event 'TuneDone event'

    $err = Classify-LogLine -Line '[ERROR] No capacity available right now' -CurrentMode 'starting'
    Assert-Equal 'Error' $err.Event 'Error event'
}

# ------------------------------------------------------------------------------
# 9. Redact-DiagnosticsText
# ------------------------------------------------------------------------------
Invoke-TestCase -Name 'Redact-DiagnosticsText scrubs API_KEY, HF_TOKEN, Bearer, and OAuth tokens' -Body {
    # Construct synthetic test tokens dynamically so no static secret scanner matches literal tokens
    $synHf = 'hf' + '_' + 'AbCdEfGhIjKlMnOpQrSt1234'
    $synSk = 'sk' + '-' + 'TestSyntheticKey9876543210'
    $synBearer = 'eyJhbGciOi' + 'SyntheticBearerPayload998877'
    $synOauthCode = '4/' + '0AfSyntheticOAuthCode12345'
    $synAccess = 'ya29.' + 'SyntheticAccessToken67890'
    $synRefresh = '1//' + 'SyntheticRefreshToken54321'

    $sample = @(
        'GPU=AUTO',
        'LOCAL_PORT=8080',
        'API_KEY=my-private-local-key',
        "export HF_TOKEN=$synHf",
        'ANTHROPIC_AUTH_TOKEN=my-anthropic-secret',
        "{`"api_key`": `"json-secret-value`", `"refresh_token`": `"json-refresh-val`"}",
        "Authorization: Bearer $synBearer",
        "Standalone token check: $synHf and $synSk",
        "https://accounts.google.com/o/oauth2/auth?code=$synOauthCode&access_token=$synAccess&refresh_token=$synRefresh"
    ) -join "`n"

    $redacted = Redact-DiagnosticsText -Text $sample

    Assert-Contains $redacted 'GPU=AUTO' 'Non-secret GPU preserved'
    Assert-Contains $redacted 'LOCAL_PORT=8080' 'Non-secret port preserved'
    Assert-Contains $redacted 'API_KEY=<REDACTED>' 'API_KEY redacted'
    Assert-Contains $redacted 'export HF_TOKEN=<REDACTED>' 'export HF_TOKEN redacted'
    Assert-Contains $redacted 'ANTHROPIC_AUTH_TOKEN=<REDACTED>' 'ANTHROPIC_AUTH_TOKEN redacted'
    Assert-Contains $redacted '"api_key": "<REDACTED>"' 'JSON api_key redacted'
    Assert-Contains $redacted '"refresh_token": "<REDACTED>"' 'JSON refresh_token redacted'
    Assert-Contains $redacted 'Authorization: Bearer <REDACTED>' 'Bearer token redacted'
    Assert-Contains $redacted '<REDACTED_HF_TOKEN>' 'Standalone HF token redacted'
    Assert-Contains $redacted '<REDACTED_API_KEY>' 'Standalone sk- key redacted'
    Assert-Contains $redacted '?code=<REDACTED>&access_token=<REDACTED>&refresh_token=<REDACTED>' 'OAuth query tokens redacted'

    foreach ($secret in @('my-private-local-key', $synHf, 'my-anthropic-secret', 'json-secret-value', 'json-refresh-val', $synBearer, $synSk, $synOauthCode, $synAccess, $synRefresh)) {
        Assert-NotContains $redacted $secret "Secret leaked after redaction: $secret"
    }
    Assert-Equal '' (Redact-DiagnosticsText -Text '') 'Empty input returns empty string'
}

# ------------------------------------------------------------------------------
# 10. Get-ClientConnectSnippets
# ------------------------------------------------------------------------------
Invoke-TestCase -Name 'Get-ClientConnectSnippets sets CLAUDE_CODE_ATTRIBUTION_HEADER=0 and localhost port' -Body {
    $snips = Get-ClientConnectSnippets -LocalPort '9090' -ApiKey 'test-token' -ActiveModel 'nvfp4-NVFP4'
    Assert-Equal 'http://localhost:9090' $snips.BaseUrl 'BaseUrl matches port'
    Assert-Equal 'http://localhost:9090/v1' $snips.OpenAiBaseUrl 'OpenAiBaseUrl matches port'

    $claudeObj = $snips.ClaudeJson | ConvertFrom-Json
    Assert-Equal 'http://localhost:9090' $claudeObj.env.ANTHROPIC_BASE_URL 'Claude ANTHROPIC_BASE_URL'
    Assert-Equal 'test-token' $claudeObj.env.ANTHROPIC_AUTH_TOKEN 'Claude ANTHROPIC_AUTH_TOKEN'
    Assert-Equal '0' $claudeObj.env.CLAUDE_CODE_ATTRIBUTION_HEADER 'Claude CLAUDE_CODE_ATTRIBUTION_HEADER must be 0'

    Assert-Contains $snips.CursorCline 'http://localhost:9090/v1' 'Cursor snippet has /v1 URL'
    Assert-Contains $snips.CursorCline 'nvfp4-NVFP4' 'Cursor snippet includes active model'
    Assert-Contains $snips.PythonSdk 'base_url="http://localhost:9090/v1"' 'Python SDK snippet has base_url'
    Assert-Contains $snips.PythonSdk 'api_key="test-token"' 'Python SDK snippet has api_key'

    $defaults = Get-ClientConnectSnippets -LocalPort ''
    Assert-Equal 'http://localhost:8080' $defaults.BaseUrl 'Default port 8080'
    $defClaude = $defaults.ClaudeJson | ConvertFrom-Json
    Assert-Equal 'http://localhost:8080' $defClaude.env.ANTHROPIC_BASE_URL 'Default Claude URL'
    Assert-Equal '0' $defClaude.env.CLAUDE_CODE_ATTRIBUTION_HEADER 'Default attribution header 0'
}

# ------------------------------------------------------------------------------
# 11. Merge-ClaudeSettingsJson
# ------------------------------------------------------------------------------
Invoke-TestCase -Name 'Merge-ClaudeSettingsJson preserves existing user keys and sets required env vars' -Body {
    $existing = @'
{
  "theme": "dark",
  "permissions": {
    "allow": ["Read", "Bash"]
  },
  "env": {
    "USER_EXISTING_FLAG": "keep-me",
    "ANTHROPIC_BASE_URL": "http://localhost:9999"
  }
}
'@
    $mergedText = Merge-ClaudeSettingsJson -ExistingJson $existing -LocalPort '8085' -ApiKey ''
    $merged = $mergedText | ConvertFrom-Json

    Assert-Equal 'dark' $merged.theme 'Top-level theme preserved'
    Assert-Equal 'Read' $merged.permissions.allow[0] 'Nested permissions preserved'
    Assert-Equal 'keep-me' $merged.env.USER_EXISTING_FLAG 'Existing env key preserved'
    Assert-Equal 'http://localhost:8085' $merged.env.ANTHROPIC_BASE_URL 'ANTHROPIC_BASE_URL updated'
    Assert-Equal 'strata-local' $merged.env.ANTHROPIC_AUTH_TOKEN 'Default ANTHROPIC_AUTH_TOKEN set'
    Assert-Equal '0' $merged.env.CLAUDE_CODE_ATTRIBUTION_HEADER 'CLAUDE_CODE_ATTRIBUTION_HEADER set to 0'

    $fromEmptyText = Merge-ClaudeSettingsJson -ExistingJson '' -LocalPort '8080' -ApiKey 'custom-key'
    $fromEmpty = $fromEmptyText | ConvertFrom-Json
    Assert-Equal 'http://localhost:8080' $fromEmpty.env.ANTHROPIC_BASE_URL 'Empty input sets URL'
    Assert-Equal 'custom-key' $fromEmpty.env.ANTHROPIC_AUTH_TOKEN 'Empty input sets custom token'
    Assert-Equal '0' $fromEmpty.env.CLAUDE_CODE_ATTRIBUTION_HEADER 'Empty input sets attribution header 0'
}

# ------------------------------------------------------------------------------
# 12. WPF Launcher -SmokeTest
# ------------------------------------------------------------------------------
Invoke-TestCase -Name 'ui\StrataLauncher.ps1 -SmokeTest exits 0 and emits SMOKE_TEST_OK' -Body {
    $psExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $psExe)) {
        $psExe = 'powershell.exe'
    }
    $out = & $psExe -NoProfile -ExecutionPolicy Bypass -STA -File $LauncherPath -SmokeTest 2>&1
    $exitCode = $LASTEXITCODE
    $joined = ($out | ForEach-Object { [string]$_ }) -join "`n"
    Assert-Equal 0 $exitCode "SmokeTest exited with code $exitCode. Output: $joined"
    Assert-Contains $joined 'SMOKE_TEST_OK' "SmokeTest output missing SMOKE_TEST_OK. Output: $joined"
}

Write-Output ''
Write-Output "Results: $($script:PassedCount) passed, $($script:FailedCount) failed."
if ($script:FailedCount -gt 0) {
    Write-Output 'Failures:'
    foreach ($f in $script:Failures) {
        Write-Output "  - $f"
    }
    exit 1
}
exit 0
