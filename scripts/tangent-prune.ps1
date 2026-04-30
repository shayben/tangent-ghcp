#requires -Version 7.0
<#
.SYNOPSIS
    Prune tangent worktrees + branches with strong safety guardrails.

.PARAMETER Merged
    Drop worktrees classified as 'merged' AND delete their branches. Default if no other selector is passed.

.PARAMETER Pushed
    Also drop 'pushed' worktrees (keeps the branch since it's preserved upstream).

.PARAMETER Orphaned
    Also clear orphaned state.json entries.

.PARAMETER All
    Equivalent to -Merged -Pushed -Orphaned. Still NEVER touches 'broken' worktrees.

.PARAMETER Branch
    One or more specific branches to prune REGARDLESS of bucket / status (e.g. 'tangent/foo').
    Use this from the slash command for interactive per-item selection of active tangents.
    Ownership check still applies; dirty worktrees are still refused by `git worktree remove`.
    For 'merged' branches passed this way, the branch is also deleted; otherwise only the
    worktree is removed (the branch is preserved).

.PARAMETER DryRun
    Print what would happen, do not act.

.PARAMETER Json
    Emit a JSON report instead of formatted text.

.PARAMETER Fetch
    `git fetch --quiet` before classifying.

.PARAMETER Force
    Pass `--force` to `git worktree remove` so dirty worktrees are removed (their
    uncommitted/untracked changes are DISCARDED). Use only after the user
    explicitly chose to discard. Branch deletion still uses `-d` (refuses unmerged).

.PARAMETER Menu
    Emit a JSON `{ question, choices }` payload describing the interactive
    menu the slash command should surface via ask_user. Each choice has a
    stable `token` (the branch name, or `__all_cleanable__` / `__all_merged__`
    / `__cancel__`) plus a pre-rendered `label`, `dirty` flag, and `status`.
    No actions are taken. Honors -Fetch.

.PARAMETER OnDirty
    Strategy for handling a single dirty branch's uncommitted changes BEFORE
    pruning. Lifted from the slash-command sub-flow so the model doesn't have
    to drive multi-step git invocations.
      * fail    (default) — do nothing extra; let `git worktree remove` refuse
      * stash   — `git -C <wt> stash push -u -m "pre-prune <branch>"` first
      * commit  — `git -C <wt> add -A; git -C <wt> commit -m <CommitMessage>` first
      * discard — alias for -Force
    Only meaningful with -Branch (single name).

.PARAMETER CommitMessage
    Required when -OnDirty commit. Passed to `git commit -m`.
#>
[CmdletBinding()]
param(
    [switch]$Merged,
    [switch]$Pushed,
    [switch]$Orphaned,
    [switch]$All,
    [string[]]$Branch,
    [switch]$DryRun,
    [switch]$Json,
    [switch]$Fetch,
    [switch]$Force,
    [switch]$Menu,
    [ValidateSet('fail', 'stash', 'commit', 'discard')]
    [string]$OnDirty = 'fail',
    [string]$CommitMessage = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'TangentInventory.psm1') -Force

# ── Menu mode: emit ask_user payload, no actions ─────────────────────
if ($Menu) {
    $inv = @(Get-TangentInventory -Fetch:$Fetch)

    $iconMap = @{
        'merged' = '✅'; 'pushed' = '📤'; 'local-only' = '🌱'
        'active' = '🟡'; 'stale'  = '⚠️'; 'orphaned'   = '👻'; 'broken' = '💥'
    }
    $bucketOrder = @{
        'merged' = 0; 'pushed' = 1; 'orphaned' = 2;
        'local-only' = 3; 'stale' = 4; 'active' = 5; 'broken' = 6
    }

    $sorted = $inv | Sort-Object @{e = { $bucketOrder[$_.Status] ?? 99 }}, Branch
    $choices = @()
    foreach ($it in $sorted) {
        $bits = @($it.Status, "$($it.AgeDays)d")
        if ($it.Dirty)         { $bits += 'dirty' }
        if ($it.AheadOfRemote -gt 0) { $bits += "$($it.AheadOfRemote) ahead" }
        if (-not $it.HasUpstream)    { $bits += 'no upstream' }
        $icon  = $iconMap[$it.Status]
        $label = "$icon $($it.Branch) — $($bits -join ', ')"
        $choices += [ordered]@{
            label  = $label
            token  = $it.Branch
            status = $it.Status
            dirty  = [bool]$it.Dirty
        }
    }

    $cleanable = @($inv | Where-Object { $_.Status -in 'merged','pushed','orphaned' })
    $mergedOnly = @($inv | Where-Object { $_.Status -eq 'merged' })
    if ($cleanable.Count -ge 2) {
        $choices += [ordered]@{
            label = "⚡ All cleanable ($($cleanable.Count): merged + pushed + orphaned)"
            token = '__all_cleanable__'
        }
    }
    if ($mergedOnly.Count -ge 2) {
        $choices += [ordered]@{
            label = "✅ All merged only ($($mergedOnly.Count))"
            token = '__all_merged__'
        }
    }
    $choices += [ordered]@{ label = '❌ Cancel'; token = '__cancel__' }

    [ordered]@{
        question = if ($inv.Count -eq 0) {
            '🌿 No tangent worktrees in this repo — nothing to prune.'
        } else {
            'Which tangent worktree would you like to prune?'
        }
        choices  = $choices
        empty    = ($inv.Count -eq 0)
    } | ConvertTo-Json -Depth 5
    return
}

# ── -OnDirty pre-flight (only meaningful for single -Branch) ─────────
if ($OnDirty -ne 'fail') {
    if (-not ($Branch -and $Branch.Count -eq 1)) {
        Write-Error '-OnDirty requires exactly one -Branch'; exit 2
    }
    if ($OnDirty -eq 'commit' -and -not $CommitMessage) {
        Write-Error '-OnDirty commit requires -CommitMessage'; exit 2
    }
    if ($OnDirty -eq 'discard') { $Force = $true }
}

if ($All)               { $Merged = $true; $Pushed = $true; $Orphaned = $true }
$bucketFlagSet = $Merged -or $Pushed -or $Orphaned
$branchSet     = $Branch -and $Branch.Count -gt 0
if (-not ($bucketFlagSet -or $branchSet)) { $Merged = $true }   # safe default

$repoRoot = (& git rev-parse --show-toplevel 2>$null)
if (-not $repoRoot) { Write-Error 'tangent-prune: not in a git repo'; exit 1 }
$repoRoot = $repoRoot.Trim()

$cwd = (Get-Location).Path
$stateFile = Join-Path $HOME '.copilot/tangent/state.json'

$inv = @(Get-TangentInventory -Fetch:$Fetch)

$branchSet_h = @{}
if ($branchSet) {
    foreach ($b in $Branch) { $branchSet_h[$b] = $true }
}

$selected = @()
$skippedReasons = @{}   # branch -> reason (for reporting when -Branch was explicit)
foreach ($it in $inv) {
    $explicit = $branchSet_h.ContainsKey($it.Branch)
    $bucketPick = switch ($it.Status) {
        'merged'   { $Merged }
        'pushed'   { $Pushed }
        'orphaned' { $Orphaned }
        default    { $false }
    }
    if (-not ($explicit -or $bucketPick)) { continue }

    # Refuse 'broken' even when explicit — too risky to auto-act on.
    if ($it.Status -eq 'broken') {
        $skippedReasons[$it.Branch] = "broken (git status failed); investigate manually"
        continue
    }
    # Don't touch the worktree the user is currently in.
    if ($it.Worktree -and ($cwd.StartsWith($it.Worktree, [System.StringComparison]::OrdinalIgnoreCase))) {
        $skippedReasons[$it.Branch] = "current working directory is inside this worktree"
        continue
    }
    # Ownership proof (skip for orphaned: marker file is gone by definition).
    if ($it.Status -ne 'orphaned') {
        if (-not (Test-TangentOwnership -Branch $it.Branch -Worktree $it.Worktree)) {
            $skippedReasons[$it.Branch] = "ownership check failed (not under tangent root or missing .tangent/launch.ps1)"
            continue
        }
    }
    $selected += $it
}

$report = [System.Collections.Generic.List[object]]::new()

function Add-Report {
    param([string]$Branch, [string]$Action, [bool]$Success, [string]$Detail)
    $report.Add([pscustomobject]@{
        branch  = $Branch
        action  = $Action
        success = $Success
        detail  = $Detail
        dryRun  = [bool]$DryRun
    })
}

foreach ($it in $selected) {
    # Use $br (not $branch) — PowerShell variable names are case-insensitive, so
    # `$branch = ...` would clobber the [string[]]$Branch parameter and coerce
    # the value to a 1-element string[], breaking later $state.ContainsKey($br) lookups.
    $br = [string]$it.Branch
    $worktree = $it.Worktree

    if ($it.Status -eq 'orphaned') {
        if ($DryRun) {
            Add-Report -Branch $br -Action 'state-cleanup' -Success $true -Detail 'would remove orphaned state.json entry'
        } else {
            try {
                $state = Get-TangentStateRecords -StateFile $stateFile
                if ($state.Contains($br)) {
                    $state.Remove($br) | Out-Null
                    $state | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $stateFile -Encoding UTF8
                }
                Add-Report -Branch $br -Action 'state-cleanup' -Success $true -Detail 'removed orphaned state.json entry'
            } catch {
                Add-Report -Branch $br -Action 'state-cleanup' -Success $false -Detail "$_"
            }
        }
        continue
    }

    # 0. -OnDirty pre-step: stash or commit the dirty tree so worktree-remove succeeds.
    if (-not $DryRun -and $OnDirty -in @('stash', 'commit') -and $it.Dirty) {
        if ($OnDirty -eq 'stash') {
            $out = & git -C $worktree stash push -u -m "pre-prune $br" 2>&1
            if ($LASTEXITCODE -eq 0) {
                Add-Report -Branch $br -Action 'stash-changes' -Success $true -Detail "$out"
            } else {
                Add-Report -Branch $br -Action 'stash-changes' -Success $false -Detail "$out"
                continue
            }
        } else {
            & git -C $worktree add -A 2>&1 | Out-Null
            $out = & git -C $worktree commit -m $CommitMessage 2>&1
            if ($LASTEXITCODE -eq 0) {
                Add-Report -Branch $br -Action 'commit-changes' -Success $true -Detail "committed: $CommitMessage"
            } else {
                Add-Report -Branch $br -Action 'commit-changes' -Success $false -Detail "$out"
                continue
            }
        }
    }

    # 1. Remove worktree (`git worktree remove` refuses on dirty / locked unless --force)
    $rmCmd = if ($Force) { 'git worktree remove --force' } else { 'git worktree remove' }
    if ($DryRun) {
        $detail = if ($Force -and $it.Dirty) {
            "would run: $rmCmd $worktree  (DISCARDS uncommitted changes)"
        } else {
            "would run: $rmCmd $worktree"
        }
        Add-Report -Branch $br -Action 'worktree-remove' -Success $true -Detail $detail
    } else {
        $out = if ($Force) {
            & git -C $repoRoot worktree remove --force $worktree 2>&1
        } else {
            & git -C $repoRoot worktree remove $worktree 2>&1
        }
        if ($LASTEXITCODE -eq 0) {
            $detail = if ($Force -and $it.Dirty) { "$worktree (forced; uncommitted changes discarded)" } else { $worktree }
            Add-Report -Branch $br -Action 'worktree-remove' -Success $true -Detail $detail
        } else {
            Add-Report -Branch $br -Action 'worktree-remove' -Success $false -Detail "$out"
            continue   # don't try to delete the branch if worktree removal failed
        }
    }

    # 2. Branch deletion:
    #    - merged bucket → safe `-d` (refuses unmerged) as a guardrail.
    #    - -Force (user explicitly chose discard) → `-D` so re-spawning the
    #      same name doesn't auto-suffix to <branch>-2 next time.
    if ($it.Status -eq 'merged') {
        if ($DryRun) {
            Add-Report -Branch $br -Action 'branch-delete' -Success $true -Detail "would run: git branch -d $br"
        } else {
            $out = & git -C $repoRoot branch -d $br 2>&1
            if ($LASTEXITCODE -eq 0) {
                Add-Report -Branch $br -Action 'branch-delete' -Success $true -Detail "$out"
            } else {
                # Squash/rebase merges sometimes leave -d unhappy. Surface, don't force.
                Add-Report -Branch $br -Action 'branch-delete' -Success $false -Detail "git refused (unmerged per ancestry): $out"
            }
        }
    } elseif ($Force) {
        if ($DryRun) {
            Add-Report -Branch $br -Action 'branch-delete' -Success $true -Detail "would run: git branch -D $br  (forced)"
        } else {
            $out = & git -C $repoRoot branch -D $br 2>&1
            if ($LASTEXITCODE -eq 0) {
                Add-Report -Branch $br -Action 'branch-delete' -Success $true -Detail "$out (forced)"
            } else {
                Add-Report -Branch $br -Action 'branch-delete' -Success $false -Detail "$out"
            }
        }
    }

    # 3. Clean up state.json record
    if (-not $DryRun) {
        try {
            $state = Get-TangentStateRecords -StateFile $stateFile
            if ($state.Contains($br)) {
                $state.Remove($br) | Out-Null
                $state | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $stateFile -Encoding UTF8
            }
        } catch { Write-Warning "failed to clean state.json for ${br}: $_" }
    }
}

if ($Json) {
    # Report explicit -Branch requests that didn't survive filtering, and not-found branches.
    $skippedReport = @()
    foreach ($k in $skippedReasons.Keys) {
        if ($branchSet_h.ContainsKey($k)) {
            $skippedReport += [pscustomobject]@{ branch = $k; reason = $skippedReasons[$k] }
        }
    }
    if ($branchSet) {
        $foundBranches = @{}
        foreach ($it in $inv) { $foundBranches[$it.Branch] = $true }
        foreach ($b in $Branch) {
            if (-not $foundBranches.ContainsKey($b)) {
                $skippedReport += [pscustomobject]@{ branch = $b; reason = 'no such tangent worktree in this repo' }
            }
        }
    }
    [pscustomobject]@{
        considered = $inv.Count
        selected   = $selected.Count
        actions    = $report.ToArray()
        skipped    = $skippedReport
        dryRun     = [bool]$DryRun
    } | ConvertTo-Json -Depth 5 -Compress
    return
}

# Text report
$prefix = if ($DryRun) { '[dry-run] ' } else { '' }
Write-Host "🌿 ${prefix}tangent-prune: considered $($inv.Count), selected $($selected.Count)`n"
if ($selected.Count -eq 0) {
    Write-Host '  Nothing to do.'
}
foreach ($r in $report) {
    $glyph = if ($r.success) { '✓' } else { '✗' }
    Write-Host ("  {0} {1,-16} {2,-40} {3}" -f $glyph, $r.action, $r.branch, $r.detail)
}

# Surface explicit -Branch requests we couldn't act on (most useful when user typo'd a name)
if ($branchSet) {
    $foundBranches = @{}
    foreach ($it in $inv) { $foundBranches[$it.Branch] = $true }
    foreach ($b in $Branch) {
        if (-not $foundBranches.ContainsKey($b)) {
            Write-Host ("  ! {0,-16} {1,-40} no such tangent worktree in this repo" -f 'skipped', $b)
        }
    }
    foreach ($k in $skippedReasons.Keys) {
        if ($branchSet_h.ContainsKey($k)) {
            Write-Host ("  ! {0,-16} {1,-40} {2}" -f 'skipped', $k, $skippedReasons[$k])
        }
    }
}
