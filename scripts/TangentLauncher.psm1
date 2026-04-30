# TangentLauncher.psm1 — resolves which command to use to launch Copilot CLI.
#
# Precedence (highest first):
#   1. Explicit -Launcher argument
#   2. $env:TANGENT_COPILOT_CMD
#   3. ~/.copilot/tangent/config.json -> copilotCommand
#   4. Parent-process autodetect (e.g. agency.exe)
#   5. Fallback: "copilot"

Set-StrictMode -Version Latest

function Get-TangentConfig {
    [CmdletBinding()]
    param(
        [string]$ConfigPath = (Join-Path $HOME '.copilot/tangent/config.json')
    )
    if (-not (Test-Path -LiteralPath $ConfigPath)) { return @{} }
    try {
        $raw = Get-Content -LiteralPath $ConfigPath -Raw -ErrorAction Stop
        $obj = $raw | ConvertFrom-Json -ErrorAction Stop
        $h = @{}
        foreach ($p in $obj.PSObject.Properties) {
            if ($p.Name -notlike '_*') { $h[$p.Name] = $p.Value }
        }
        return $h
    } catch {
        Write-Warning "tangent: failed to parse $ConfigPath ($_); ignoring"
        return @{}
    }
}

function ConvertTo-LauncherTokens {
    # Accept either a string ("agency.exe copilot") or an array (["agency.exe","copilot"]).
    # Returns @(<exe>, <arg>, ...). Returns $null for empty input.
    param([Parameter(ValueFromPipeline)]$Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [string]) {
        $s = $Value.Trim()
        if (-not $s) { return $null }
        # Naive split — tangent launchers don't have spaces in paths in practice.
        # Users with such paths should use the array form in config.json.
        return @($s -split '\s+')
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $arr = @($Value | ForEach-Object { [string]$_ } | Where-Object { $_ })
        if ($arr.Count -eq 0) { return $null }
        return $arr
    }
    return $null
}

function Find-AgencyInParentChain {
    [CmdletBinding()]
    param(
        [string]$HintExeName = 'agency.exe',
        [int]$MaxDepth = 8
    )
    try {
        $procId = $PID
        for ($i = 0; $i -lt $MaxDepth; $i++) {
            $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$procId" -ErrorAction Stop
            if (-not $proc) { return $null }
            $name = [IO.Path]::GetFileName($proc.ExecutablePath ?? $proc.Name)
            if ($name -and ($name -ieq $HintExeName)) {
                return $proc.ExecutablePath ?? $proc.Name
            }
            if (-not $proc.ParentProcessId -or $proc.ParentProcessId -eq 0) { return $null }
            $procId = [int]$proc.ParentProcessId
        }
    } catch {
        Write-Verbose "tangent: parent-chain probe failed ($_)"
    }
    return $null
}

function Resolve-TangentLauncher {
    <#
    .SYNOPSIS
        Resolves the Copilot CLI launcher per documented precedence.
    .OUTPUTS
        [pscustomobject] with: Exe, Arguments (string[]), Source ('arg'|'env'|'config'|'autodetect'|'fallback'), Display
    #>
    [CmdletBinding()]
    param(
        [string]$ExplicitLauncher,
        [hashtable]$Config,
        [string]$EnvValue = $env:TANGENT_COPILOT_CMD,
        [string]$HintEnv  = $env:TANGENT_LAUNCHER_HINT
    )
    if (-not $Config) { $Config = Get-TangentConfig }

    $tokens = $null
    $source = $null

    if (-not $tokens -and $ExplicitLauncher) {
        $tokens = ConvertTo-LauncherTokens $ExplicitLauncher
        if ($tokens) { $source = 'arg' }
    }
    if (-not $tokens -and $EnvValue) {
        $tokens = ConvertTo-LauncherTokens $EnvValue
        if ($tokens) { $source = 'env' }
    }
    if (-not $tokens -and $Config.ContainsKey('copilotCommand') -and $Config.copilotCommand) {
        $tokens = ConvertTo-LauncherTokens $Config.copilotCommand
        if ($tokens) { $source = 'config' }
    }
    if (-not $tokens) {
        $autodetectEnabled = $true
        if ($Config.ContainsKey('autodetectLauncher')) {
            $autodetectEnabled = [bool]$Config.autodetectLauncher
        }
        if ($autodetectEnabled) {
            $hint = $HintEnv
            if (-not $hint -and $Config.ContainsKey('launcherHint')) { $hint = [string]$Config.launcherHint }
            if (-not $hint) { $hint = 'agency.exe' }
            $found = Find-AgencyInParentChain -HintExeName $hint
            if ($found) {
                $tokens = @($found, 'copilot')
                $source = 'autodetect'
            }
        }
    }
    if (-not $tokens) {
        $tokens = @('copilot')
        $source = 'fallback'
    }

    [pscustomobject]@{
        Exe       = $tokens[0]
        Arguments = @(if ($tokens.Count -gt 1) { $tokens[1..($tokens.Count - 1)] } else { @() })
        Source    = $source
        Display   = ($tokens -join ' ')
    }
}

Export-ModuleMember -Function Get-TangentConfig, Resolve-TangentLauncher, ConvertTo-LauncherTokens, Find-AgencyInParentChain
