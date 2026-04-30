# TangentInventory.psm1 — discover and classify tangent worktrees in the current repo.
#
# Public:
#   Get-TangentInventory [-Fetch]   → @(PSCustomObject)
#   Get-TangentDefaultBranch        → 'main' | 'master' | $null
#   Test-TangentOwnership -Worktree → $true if it's safe for prune to touch
#
# Status values (first match wins, see Get-TangentClassification):
#   merged      — branch ancestor of origin/<default>; or PR shows merged via gh
#   pushed      — has upstream, no unpushed commits, not merged
#   local-only  — no upstream tracking branch
#   active      — dirty OR younger than grace period (1h)
#   stale       — > 30 days inactive AND not merged AND has work
#   orphaned    — state record exists but worktree dir missing
#   broken      — worktree dir exists but git status fails

Set-StrictMode -Version Latest

$script:GraceMinutes = 60
$script:StaleDays    = 30

function Get-TangentDefaultBranch {
    [CmdletBinding()]
    param([string]$RepoRoot = (& git rev-parse --show-toplevel 2>$null))
    if (-not $RepoRoot) { return $null }
    $RepoRoot = $RepoRoot.Trim()
    # Prefer the remote's HEAD (origin/HEAD → origin/main or similar)
    $sym = (& git -C $RepoRoot symbolic-ref --short refs/remotes/origin/HEAD 2>$null)
    if ($LASTEXITCODE -eq 0 -and $sym) {
        return ($sym.Trim() -replace '^origin/', '')
    }
    return $null
}

function Get-TangentWorktreeList {
    [CmdletBinding()]
    param([string]$RepoRoot = (& git rev-parse --show-toplevel 2>$null))
    if (-not $RepoRoot) { return @() }
    $RepoRoot = $RepoRoot.Trim()
    $out = & git -C $RepoRoot worktree list --porcelain 2>$null
    if ($LASTEXITCODE -ne 0) { return @() }
    $records = @()
    $cur = @{}
    foreach ($line in $out) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            if ($cur.Count -gt 0) { $records += [pscustomobject]$cur; $cur = @{} }
            continue
        }
        if ($line -match '^worktree\s+(.+)$')   { $cur['Worktree'] = $matches[1]; continue }
        if ($line -match '^HEAD\s+(.+)$')       { $cur['HEAD']     = $matches[1]; continue }
        if ($line -match '^branch\s+(.+)$')     { $cur['Branch']   = ($matches[1] -replace '^refs/heads/', ''); continue }
        if ($line -match '^(detached|bare|locked|prunable)') { $cur[$matches[1]] = $true }
    }
    if ($cur.Count -gt 0) { $records += [pscustomobject]$cur }
    return $records
}

function Get-TangentStateRecords {
    [CmdletBinding()]
    param([string]$StateFile = (Join-Path $HOME '.copilot/tangent/state.json'))
    if (-not (Test-Path -LiteralPath $StateFile)) { return @{} }
    try {
        $raw = Get-Content -LiteralPath $StateFile -Raw -ErrorAction Stop
        $obj = $raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        return ($obj ?? @{})
    } catch {
        Write-Warning "tangent: failed to parse $StateFile ($_); treating as empty"
        return @{}
    }
}

function Test-TangentOwnership {
    <# Safety guard for prune: refuse to act unless ALL ownership signals match. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Branch,
        [Parameter(Mandatory)][string]$Worktree,
        [string]$WorktreeRoot
    )
    if ($Branch -notlike 'tangent/*') { return $false }
    if (-not $WorktreeRoot) {
        $WorktreeRoot = $env:WORKTREE_ROOT
        if (-not $WorktreeRoot) { $WorktreeRoot = Join-Path $env:LOCALAPPDATA 'tangent\worktrees' }
    }
    $rootResolved = try { (Resolve-Path -LiteralPath $WorktreeRoot -ErrorAction Stop).Path } catch { $WorktreeRoot }
    $wtResolved   = try { (Resolve-Path -LiteralPath $Worktree     -ErrorAction Stop).Path } catch { $Worktree }
    if (-not $wtResolved.StartsWith($rootResolved, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
    $marker = Join-Path $Worktree '.tangent\launch.ps1'
    if (-not (Test-Path -LiteralPath $marker)) { return $false }
    return $true
}

function Get-TangentWorktreeHolders {
    <#
    Best-effort discovery of processes running inside a tangent worktree
    (the WT tab's pwsh + copilot.exe + its node helpers). Detection signals,
    in order of reliability:
      1. CommandLine contains the worktree path.
      2. CommandLine contains the branch name (e.g. `-n tangent/foo` for copilot.exe).
      3. ParentProcessId chain leads back to a holder from (1) or (2) — catches
         copilot.exe / node.exe children of the WT-tab pwsh whose own command
         lines mention neither path nor branch.
    -ExcludePid (defaults to the current process + its parent chain) prevents
    the prune script from finding itself / its launcher in the result set,
    which would cause a self-kill hang under -StopHolders.
    Returns @() if none, else @(@{ProcessId; Name; CommandLine; Allowlisted; MatchedBy}).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Worktree,
        [string]$Branch = '',
        [int[]]$ExcludePid
    )

    $allowlist = @('pwsh.exe','powershell.exe','copilot.exe','node.exe')

    $resolved = try { (Resolve-Path -LiteralPath $Worktree -ErrorAction Stop).Path } catch { $Worktree }
    $variants = @($resolved, $Worktree, ($resolved -replace '\\','/')) | Sort-Object -Unique
    $alts = ($variants | ForEach-Object { [regex]::Escape($_) }) -join '|'
    $pathPattern = "(?:$alts)(?=$|[\s""'\\/])"

    try { $procs = @(Get-CimInstance Win32_Process -ErrorAction Stop) }
    catch { return @() }

    $byPid = @{}
    foreach ($p in $procs) { $byPid[[int]$p.ProcessId] = $p }

    # Default exclusion: $PID (the caller — typically the prune script itself,
    # whose own command line will contain the branch name) plus its ancestor
    # chain up to the session host. Without this the script self-matches and
    # Stop-Process kills itself mid-run.
    if (-not $PSBoundParameters.ContainsKey('ExcludePid')) {
        $ExcludePid = @()
        $cur = $PID
        $guard = 0
        while ($cur -and $byPid.ContainsKey($cur) -and $guard -lt 32) {
            $ExcludePid += $cur
            $cur = [int]$byPid[$cur].ParentProcessId
            $guard++
        }
    }
    $excludeSet = @{}
    foreach ($x in $ExcludePid) { $excludeSet[[int]$x] = $true }

    $matched = @{}
    foreach ($p in $procs) {
        $pid_ = [int]$p.ProcessId
        if ($excludeSet.ContainsKey($pid_)) { continue }
        if (-not $p.CommandLine) { continue }
        if ($p.CommandLine -match $pathPattern) {
            $matched[$pid_] = 'path'
            continue
        }
        if ($Branch -and ($p.CommandLine -match [regex]::Escape($Branch) + '(?=$|[\s"''\\/])')) {
            $matched[$pid_] = 'branch'
        }
    }

    $changed = $true
    while ($changed) {
        $changed = $false
        foreach ($p in $procs) {
            $pid_ = [int]$p.ProcessId
            if ($matched.ContainsKey($pid_)) { continue }
            if ($excludeSet.ContainsKey($pid_)) { continue }
            $ppid = [int]$p.ParentProcessId
            if ($matched.ContainsKey($ppid) -and $byPid.ContainsKey($ppid)) {
                $parent = $byPid[$ppid]
                if ($allowlist -contains $parent.Name.ToLowerInvariant()) {
                    $matched[$pid_] = 'descendant'
                    $changed = $true
                }
            }
        }
    }

    foreach ($pid_ in $matched.Keys) {
        $p = $byPid[$pid_]
        [pscustomobject]@{
            ProcessId    = $pid_
            Name         = [string]$p.Name
            CommandLine  = [string]$p.CommandLine
            Allowlisted  = ($allowlist -contains $p.Name.ToLowerInvariant())
            MatchedBy    = $matched[$pid_]
        }
    }
}

function Get-TangentClassification {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Info
    )
    if ($Info.WorktreeMissing)             { return 'orphaned' }
    if ($Info.Broken)                      { return 'broken' }
    if (-not $Info.HasUpstream -and -not $Info.IsMerged -and -not $Info.Dirty) {
        # No remote tracking; before declaring local-only, fall through to stale check below.
    }
    if ($Info.Dirty)                       { return 'active' }
    # Grace period: skip merged for very fresh worktrees (newly created from default HEAD).
    if ($Info.AgeMinutes -lt $script:GraceMinutes) { return 'active' }
    if ($Info.IsMerged)                    { return 'merged' }
    if ($Info.HasUpstream -and $Info.AheadOfRemote -eq 0) { return 'pushed' }
    if (-not $Info.HasUpstream)            { return 'local-only' }
    if ($Info.AgeDays -gt $script:StaleDays) { return 'stale' }
    return 'active'
}

function Get-TangentInventory {
    <#
    .SYNOPSIS Enumerate tangent worktrees in the current repo with classified status.
    .PARAMETER Fetch  When set, run `git fetch --quiet` first for fresher remote refs.
    .OUTPUTS PSCustomObject[] (one per tangent worktree)
    #>
    [CmdletBinding()]
    param(
        [switch]$Fetch,
        [string]$RepoRoot = (& git rev-parse --show-toplevel 2>$null),
        [string]$StateFile = (Join-Path $HOME '.copilot/tangent/state.json')
    )
    if (-not $RepoRoot) { Write-Warning 'tangent: not in a git repo'; return @() }
    $RepoRoot = $RepoRoot.Trim()

    if ($Fetch) {
        & git -C $RepoRoot fetch --quiet 2>$null | Out-Null
    }

    $default = Get-TangentDefaultBranch -RepoRoot $RepoRoot
    $defaultRef = if ($default) { "refs/remotes/origin/$default" } else { $null }

    $worktrees = Get-TangentWorktreeList -RepoRoot $RepoRoot
    $state = Get-TangentStateRecords -StateFile $StateFile

    $results = @()
    $seenBranches = @{}

    foreach ($wt in $worktrees) {
        $branch = $wt.PSObject.Properties['Branch'] ? $wt.Branch : $null
        if (-not $branch -or $branch -notlike 'tangent/*') { continue }
        $seenBranches[$branch] = $true

        $worktreePath = $wt.Worktree
        $missing = -not (Test-Path -LiteralPath $worktreePath)
        $info = @{
            Branch          = $branch
            Worktree        = $worktreePath
            WorktreeMissing = $missing
            Broken          = $false
            Dirty           = $false
            HasUpstream     = $false
            AheadOfRemote   = 0
            IsMerged        = $false
            MergedSource    = $null   # 'ancestry' | 'pr'
            LastActivity    = $null
            AgeMinutes      = [int]::MaxValue
            AgeDays         = [int]::MaxValue
            StateRecord     = $false
            StartedAt       = $null
        }

        if ($state.ContainsKey($branch)) {
            $info.StateRecord = $true
            $rec = $state[$branch]
            if ($rec -is [hashtable] -and $rec.ContainsKey('started_at')) {
                try { $info.StartedAt = [datetime]::Parse([string]$rec.started_at) } catch {}
            }
        }

        if ($missing) {
            $info.Status = Get-TangentClassification -Info $info
            $results += [pscustomobject]$info
            continue
        }

        # Dirty?
        $statusOut = & git -C $worktreePath status --porcelain 2>$null
        if ($LASTEXITCODE -ne 0) {
            $info.Broken = $true
            $info.Status = Get-TangentClassification -Info $info
            $results += [pscustomobject]$info
            continue
        }
        $info.Dirty = [bool]($statusOut)

        # Upstream + ahead count
        $upstream = & git -C $worktreePath rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>$null
        if ($LASTEXITCODE -eq 0 -and $upstream) {
            $info.HasUpstream = $true
            $aheadStr = & git -C $worktreePath rev-list --count '@{u}..HEAD' 2>$null
            if ($LASTEXITCODE -eq 0 -and $aheadStr) {
                $info.AheadOfRemote = [int]$aheadStr.Trim()
            }
        }

        # Merged into origin/<default>?
        if ($defaultRef) {
            $defaultSha = & git -C $worktreePath rev-parse --verify --quiet $defaultRef 2>$null
            if ($LASTEXITCODE -eq 0 -and $defaultSha) {
                $branchSha = & git -C $worktreePath rev-parse --verify --quiet $branch 2>$null
                if ($LASTEXITCODE -eq 0 -and $branchSha) {
                    & git -C $worktreePath merge-base --is-ancestor $branchSha $defaultSha.Trim() 2>$null
                    if ($LASTEXITCODE -eq 0) {
                        $info.IsMerged = $true
                        $info.MergedSource = 'ancestry'
                    }
                }
            }
        }

        # GitHub PR squash/rebase fallback (best-effort)
        if (-not $info.IsMerged -and (Get-Command gh -ErrorAction SilentlyContinue)) {
            $prJson = & gh pr list --head $branch --state merged --json number,mergedAt --limit 1 2>$null
            if ($LASTEXITCODE -eq 0 -and $prJson -and $prJson.Trim() -ne '[]') {
                $info.IsMerged = $true
                $info.MergedSource = 'pr'
            }
        }

        # LastActivity = max(StartedAt, dir mtime, latest commit time)
        $candidates = @()
        if ($info.StartedAt) { $candidates += $info.StartedAt }
        try {
            $candidates += (Get-Item -LiteralPath $worktreePath -ErrorAction Stop).LastWriteTime
        } catch {}
        $commitTs = & git -C $worktreePath log -1 --format=%cI HEAD 2>$null
        if ($LASTEXITCODE -eq 0 -and $commitTs) {
            try { $candidates += [datetime]::Parse($commitTs.Trim()) } catch {}
        }
        if ($candidates.Count -gt 0) {
            $info.LastActivity = ($candidates | Sort-Object -Descending | Select-Object -First 1)
            $age = (Get-Date) - $info.LastActivity
            $info.AgeMinutes = [int]$age.TotalMinutes
            $info.AgeDays    = [int]$age.TotalDays
        }

        $info.Status = Get-TangentClassification -Info $info
        $results += [pscustomobject]$info
    }

    # Orphans: state records whose branch isn't in `git worktree list`
    foreach ($key in $state.Keys) {
        if ($seenBranches.ContainsKey($key)) { continue }
        if ($key -notlike 'tangent/*') { continue }
        $rec = $state[$key]
        $wtPath = if ($rec -is [hashtable] -and $rec.ContainsKey('worktree')) { [string]$rec.worktree } else { $null }
        if (-not $wtPath) { continue }
        $info = @{
            Branch          = $key
            Worktree        = $wtPath
            WorktreeMissing = $true
            Broken          = $false
            Dirty           = $false
            HasUpstream     = $false
            AheadOfRemote   = 0
            IsMerged        = $false
            MergedSource    = $null
            LastActivity    = $null
            AgeMinutes      = [int]::MaxValue
            AgeDays         = [int]::MaxValue
            StateRecord     = $true
            StartedAt       = $null
        }
        $info.Status = 'orphaned'
        $results += [pscustomobject]$info
    }

    return $results
}

function Get-TangentNudge {
    <# Returns a short string to surface to the user, or $null if nothing to nudge about. #>
    [CmdletBinding()]
    param(
        [int]$MergedThreshold = 3
    )
    try {
        $inv = Get-TangentInventory
    } catch {
        return $null
    }
    $merged = @($inv | Where-Object { $_.Status -eq 'merged' })
    if ($merged.Count -ge $MergedThreshold) {
        return "💡 You have $($merged.Count) merged tangents. Run /tangent:prune to clean up."
    }
    return $null
}

Export-ModuleMember -Function `
    Get-TangentInventory, `
    Get-TangentDefaultBranch, `
    Get-TangentWorktreeList, `
    Get-TangentStateRecords, `
    Get-TangentClassification, `
    Test-TangentOwnership, `
    Get-TangentWorktreeHolders, `
    Get-TangentNudge
