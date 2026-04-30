#requires -Version 7.0
<#
.SYNOPSIS
    tangent — spawn an isolated Copilot CLI session in a new git worktree + Windows Terminal tab.

.DESCRIPTION
    Cross-cuts:
      • Creates a git worktree at $env:WORKTREE_ROOT\<branch> from current HEAD
        (or resumes if it already exists).
      • Optionally seeds a context file at <worktree>\.tangent\context.md and
        wraps the prompt so the spawned session reads it first.
      • Resolves the Copilot launcher via 5-step precedence (see TangentLauncher.psm1).
      • Opens a new Windows Terminal tab running the launcher; falls back to
        Start-Process pwsh if wt.exe is missing.
      • Records state at ~/.copilot/tangent/state.json so a second invocation
        for the same branch focuses the existing tab.
      • Optionally carries uncommitted source-workspace edits into the worktree
        via `git stash push -u` + `git stash apply` (-Include).

.OUTPUTS
    JSON object: { branch, worktree, tab_title, mode, launcher, launcherSource, resumed, included }
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Branch,

    [string]$Prompt = '',

    [ValidateSet('new', 'summary', 'full')]
    [string]$Mode = 'summary',

    [string]$ContextFile = '',

    [string]$Launcher = '',

    [switch]$Include,

    [switch]$Resume
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'TangentLauncher.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'TangentInventory.psm1') -Force

function Die($msg) { Write-Error "tangent: $msg"; exit 1 }

# ── Repo + worktree paths ─────────────────────────────────────────────
$repoRoot = (& git rev-parse --show-toplevel 2>$null)
if ($LASTEXITCODE -ne 0 -or -not $repoRoot) { Die 'not in a git repo' }
$repoRoot = $repoRoot.Trim()

$config = Get-TangentConfig
$worktreeRoot = $env:WORKTREE_ROOT
if (-not $worktreeRoot -and $config.ContainsKey('worktreeRoot') -and $config.worktreeRoot) {
    $worktreeRoot = [string]$config.worktreeRoot
}
if (-not $worktreeRoot) {
    $worktreeRoot = Join-Path $env:LOCALAPPDATA 'tangent\worktrees'
}
New-Item -ItemType Directory -Path $worktreeRoot -Force | Out-Null

# ── Branch collision (only when not resuming an existing worktree) ────
function Test-GitBranchExists($name) {
    & git show-ref --verify --quiet "refs/heads/$name"
    return ($LASTEXITCODE -eq 0)
}

$initialBranch = $Branch
$worktreeDir = Join-Path $worktreeRoot $Branch

# A real git worktree always has a `.git` entry (file pointing at gitdir, or
# a directory for the main worktree). A bare directory — even one we
# pre-created with .tangent/context.md inside — is NOT a worktree and must
# trigger a fresh `git worktree add`. Without this, callers who seed context
# before invoking the engine accidentally short-circuit creation.
function Test-IsGitWorktree([string]$dir) {
    if (-not (Test-Path -LiteralPath $dir)) { return $false }
    return (Test-Path -LiteralPath (Join-Path $dir '.git'))
}
$preExisted = Test-IsGitWorktree $worktreeDir
if (-not $preExisted) {
    # Pick a non-colliding branch name. Skip dirs that exist but aren't worktrees
    # (e.g. caller pre-seeded .tangent/context.md): we will populate them in place.
    $i = 2
    while ((Test-GitBranchExists $Branch) -or (Test-IsGitWorktree (Join-Path $worktreeRoot $Branch))) {
        $Branch = "$initialBranch-$i"
        $worktreeDir = Join-Path $worktreeRoot $Branch
        $i++
        if ($i -gt 99) { Die "branch collision: gave up after 99 attempts" }
    }
}

$resumed = $preExisted -or $Resume.IsPresent
$head = (& git rev-parse HEAD).Trim()

# ── Handback metadata: parent session id + per-tangent interaction_id ──
# Captured at fork time; preserved across resume so the same tangent always
# delivers handback to the original parent. State file is loaded again later
# for tab-focus logic; loading it here is cheap and keeps resume-aware logic
# co-located with the metadata it manages.
$handbackStateFile = Join-Path $HOME '.copilot/tangent/state.json'
$handbackPriorState = @{}
if (Test-Path -LiteralPath $handbackStateFile) {
    try { $handbackPriorState = Get-Content -LiteralPath $handbackStateFile -Raw | ConvertFrom-Json -AsHashtable } catch { $handbackPriorState = @{} }
    if ($null -eq $handbackPriorState) { $handbackPriorState = @{} }
}

$parentSessionId       = $env:COPILOT_AGENT_SESSION_ID
$parentSessionDir      = if ($parentSessionId) { Join-Path $HOME ".copilot/session-state/$parentSessionId" } else { '' }
$parentBranchAtFork    = (& git rev-parse --abbrev-ref HEAD 2>$null)
if ($parentBranchAtFork) { $parentBranchAtFork = $parentBranchAtFork.Trim() }
$interactionId         = [guid]::NewGuid().ToString()

$priorRecord = if ($handbackPriorState.Contains($Branch)) { $handbackPriorState[$Branch] } else { $null }
if ($priorRecord) {
    # Resume: preserve original parent linkage; never silently rebind.
    if ($priorRecord.Contains('interaction_id') -and $priorRecord.interaction_id) {
        $interactionId = [string]$priorRecord.interaction_id
    }
    if ($priorRecord.Contains('parent_session_id') -and $priorRecord.parent_session_id) {
        $parentSessionId = [string]$priorRecord.parent_session_id
        $parentSessionDir = if ($priorRecord.Contains('parent_session_dir') -and $priorRecord.parent_session_dir) {
            [string]$priorRecord.parent_session_dir
        } else { Join-Path $HOME ".copilot/session-state/$parentSessionId" }
    }
    if ($priorRecord.Contains('parent_branch_at_fork') -and $priorRecord.parent_branch_at_fork) {
        $parentBranchAtFork = [string]$priorRecord.parent_branch_at_fork
    }
}

# Write allowlist file in parent's session dir (best-effort; handback works without it,
# but the parent-side ingest hook uses it as a per-fork accidental-misroute defense).
if ($parentSessionDir -and (Test-Path -LiteralPath $parentSessionDir)) {
    try {
        $allowDir = Join-Path $parentSessionDir 'files\tangent-handback\allowed'
        New-Item -ItemType Directory -Path $allowDir -Force | Out-Null
        $allowFile = Join-Path $allowDir "$interactionId.json"
        if (-not (Test-Path -LiteralPath $allowFile)) {
            $allowPayload = [ordered]@{
                interaction_id        = $interactionId
                branch                = $Branch
                parent_branch_at_fork = $parentBranchAtFork
                created_iso           = (Get-Date).ToString('o')
            } | ConvertTo-Json -Depth 5
            Set-Content -LiteralPath $allowFile -Value $allowPayload -Encoding UTF8
        }
    } catch {
        Write-Warning "tangent: could not write handback allowlist: $($_.Exception.Message)"
    }
}

# ── Optional: carry source-workspace stash into the worktree ──────────
$stashRef = $null
if ($Include -and -not $preExisted) {
    $status = (& git status --porcelain)
    if ($status) {
        Write-Host "tangent: stashing uncommitted changes from source workspace"
        & git stash push -u -m "tangent-include for $Branch" | Out-Null
        if ($LASTEXITCODE -eq 0) { $stashRef = 'stash@{0}' }
    }
}

# ── Create worktree (or note resume) ──────────────────────────────────
if (-not $preExisted) {
    # If a non-worktree dir already exists at the target (e.g. caller seeded
    # .tangent/context.md before invoking the engine), git 2.x accepts an
    # *empty* existing dir for `worktree add` — but refuses if it has any
    # content. Move the seeded *children* aside (not the dir itself, which
    # may be locked by an open shell/tab cwd'd into it), create the worktree
    # in place, then restore the children on top.
    $stashedSeedDir = $null
    if (Test-Path -LiteralPath $worktreeDir) {
        $children = @(Get-ChildItem -LiteralPath $worktreeDir -Force -EA SilentlyContinue)
        if ($children.Count -gt 0) {
            $stashedSeedDir = "$worktreeDir.preseed-$([guid]::NewGuid().ToString('N').Substring(0,8))"
            Write-Host "tangent: moving pre-seeded content aside ($worktreeDir\* -> $stashedSeedDir)"
            New-Item -ItemType Directory -Path $stashedSeedDir | Out-Null
            foreach ($c in $children) {
                Move-Item -LiteralPath $c.FullName -Destination (Join-Path $stashedSeedDir $c.Name)
            }
        }
    }

    Write-Host "tangent: creating worktree $worktreeDir from $head"
    & git worktree add $worktreeDir -b $Branch $head 2>&1 | Out-Host
    if ($LASTEXITCODE -ne 0) {
        # Best-effort restore so we don't lose seeded content on failure.
        if ($stashedSeedDir -and (Test-Path -LiteralPath $stashedSeedDir)) {
            try {
                foreach ($c in Get-ChildItem -LiteralPath $stashedSeedDir -Force) {
                    Move-Item -LiteralPath $c.FullName -Destination (Join-Path $worktreeDir $c.Name) -Force
                }
                Remove-Item -LiteralPath $stashedSeedDir -Recurse -Force -EA SilentlyContinue
            } catch {}
        }
        Die "git worktree add failed"
    }

    if ($stashedSeedDir -and (Test-Path -LiteralPath $stashedSeedDir)) {
        Write-Host "tangent: restoring pre-seeded content into the worktree"
        Get-ChildItem -LiteralPath $stashedSeedDir -Force | ForEach-Object {
            $dest = Join-Path $worktreeDir $_.Name
            if (Test-Path -LiteralPath $dest) {
                # Don't clobber anything git put there (vanishingly unlikely for a fresh worktree).
                Write-Warning "tangent: skipping restore of $($_.Name) — already exists in worktree"
            } else {
                Move-Item -LiteralPath $_.FullName -Destination $dest
            }
        }
        Remove-Item -LiteralPath $stashedSeedDir -Recurse -Force -EA SilentlyContinue
    }

    if ($stashRef) {
        Push-Location $worktreeDir
        try {
            Write-Host "tangent: applying stashed changes inside worktree"
            & git stash apply $stashRef 2>&1 | Out-Host
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "tangent: stash apply had conflicts; resolve manually inside the worktree"
            }
        } finally {
            Pop-Location
        }
    }
} else {
    Write-Host "tangent: worktree already exists at $worktreeDir — resuming"
}

# Ensure .tangent/ exists for context file + launch script
$tangentMeta = Join-Path $worktreeDir '.tangent'
New-Item -ItemType Directory -Path $tangentMeta -Force | Out-Null

# If the caller pre-seeded a context file under the *requested* branch dir
# (e.g. <root>\<initialBranch>\.tangent\context.md) and the engine resolved
# to a suffixed branch on collision, the seed sits in the wrong worktree.
# Relocate it into the resolved .tangent/, and clean up the orphan dir if
# it's empty afterward.
if ($ContextFile -and (Test-Path -LiteralPath $ContextFile)) {
    $ctxFull = (Resolve-Path -LiteralPath $ContextFile).Path
    if (-not $ctxFull.StartsWith($worktreeDir, [System.StringComparison]::OrdinalIgnoreCase)) {
        $relocated = Join-Path $tangentMeta (Split-Path -Leaf $ctxFull)
        Write-Host "tangent: relocating seed into resolved worktree ($ctxFull -> $relocated)"
        if (Test-Path -LiteralPath $relocated) {
            Write-Warning "tangent: $relocated already exists; keeping existing copy and ignoring caller seed"
        } else {
            Copy-Item -LiteralPath $ctxFull -Destination $relocated -Force
        }
        $ContextFile = $relocated

        # Best-effort: prune the orphan caller seed dir if it now contains nothing else.
        try {
            $orphanRoot = Join-Path $worktreeRoot $initialBranch
            if ($initialBranch -ne $Branch -and (Test-Path -LiteralPath $orphanRoot) -and -not (Test-IsGitWorktree $orphanRoot)) {
                Remove-Item -LiteralPath $ctxFull -Force -EA SilentlyContinue
                $orphanTangent = Join-Path $orphanRoot '.tangent'
                if ((Test-Path -LiteralPath $orphanTangent) -and -not (Get-ChildItem -LiteralPath $orphanTangent -Force -EA SilentlyContinue)) {
                    Remove-Item -LiteralPath $orphanTangent -Force -EA SilentlyContinue
                }
                if (-not (Get-ChildItem -LiteralPath $orphanRoot -Force -EA SilentlyContinue)) {
                    Remove-Item -LiteralPath $orphanRoot -Force -EA SilentlyContinue
                }
            }
        } catch {
            Write-Warning "tangent: could not clean orphan seed dir: $($_.Exception.Message)"
        }
    }
}

# ── Resolve launcher ──────────────────────────────────────────────────
# Agency-wrapper bypass is deferred until after we know whether our final
# copilot args contain `-n <branch>`; agency unconditionally injects
# `--resume <agency-session-id>` which collides with `-n` ('option -n
# cannot be used with --resume') but is harmless alongside our own
# `--resume=<id>` (commander last-wins → our id, passed last as EXTRA_ARGS,
# overrides agency's). See "Conditionally bypass agency" block below.
$resolved = Resolve-TangentLauncher -ExplicitLauncher $Launcher -Config $config
Write-Host "tangent: launcher = $($resolved.Display) (source: $($resolved.Source))"

# ── Optional: deterministic session clone for `-Mode full` ────────────
# Replaces the old model-driven /share markdown handoff. Copies the parent
# session folder to a new GUID, rewrites workspace.yaml + events.jsonl, and
# spawns copilot with `--resume=<newId>` so the tangent inherits FULL
# fidelity (events, tool history, plan.md, checkpoints, files). Skipped
# when resuming an existing tangent or when the parent session id isn't
# discoverable (e.g. invoked outside a Copilot CLI session for testing).
$clonedSessionId = ''
if ($Mode -eq 'full' -and -not $preExisted -and $parentSessionId -and -not $Resume.IsPresent) {
    $cloneScript = Join-Path $PSScriptRoot 'tangent-clone-session.ps1'
    if (Test-Path -LiteralPath $cloneScript) {
        $clonedSessionId = [guid]::NewGuid().ToString()
        Write-Host "tangent: cloning parent session $parentSessionId -> $clonedSessionId"
        try {
            $cloneJson = & $cloneScript `
                -ParentSessionId $parentSessionId `
                -NewSessionId $clonedSessionId `
                -Branch $Branch `
                -WorktreePath $worktreeDir
            if ($LASTEXITCODE -ne 0) { throw "clone script exited with $LASTEXITCODE" }
            $cloneInfo = $cloneJson | ConvertFrom-Json
            Write-Host ("tangent: cloned {0} events, {1} bytes" -f $cloneInfo.eventsRewritten, $cloneInfo.sizeBytes)
        } catch {
            Write-Warning "tangent: session clone failed ($($_.Exception.Message)); falling back to non-clone spawn"
            $clonedSessionId = ''
        }
    } else {
        Write-Warning "tangent: clone script not found at $cloneScript; falling back to non-clone spawn"
    }
}

# ── Build copilot args (mode selection only; launcher prefix added after bypass) ──
# Mode selection (mutually exclusive — copilot CLI rejects -n with --resume):
#   1. Clone path: `--resume=<clonedSessionId>` so the spawned session attaches
#      to the cloned-from-parent state with full event/tool fidelity.
#   2. Resume-existing-tangent path: `--resume=<branch>` (named session resume).
#   3. Fresh path: `-n <branch>` to register a named session.
$modeArgs = @('--allow-all-tools')
if ($clonedSessionId) {
    $modeArgs += "--resume=$clonedSessionId"
} elseif ($resumed -and -not $Prompt) {
    $modeArgs += "--resume=$Branch"
} else {
    $modeArgs += @('-n', $Branch)
}

# ── Conditionally bypass agency wrapper ───────────────────────────────
# Agency unconditionally injects `--resume <agency-session-id>` and has no
# `--no-resume` flag. That collides with `-n <branch>` (copilot CLI rejects
# the combination), so we must use bare copilot.exe in fresh-spawn mode.
# For `--resume=<id>` paths (clone or resume-existing), agency's injected
# --resume is harmless: copilot's commander is last-wins, and our
# --resume=<id> is appended last as EXTRA_ARGS, overriding agency's value.
# Skip rewrite if the user explicitly chose a launcher (don't second-guess).
$usingDashN = $modeArgs -contains '-n'
if ($usingDashN -and $resolved.Source -eq 'autodetect' -and ([IO.Path]::GetFileName($resolved.Exe)) -ieq 'agency.exe') {
    $bareCopilot = (Get-Command copilot -ErrorAction SilentlyContinue).Source
    if ($bareCopilot) {
        Write-Host "tangent: bypassing agency.exe wrapper for fresh -n spawn (auto-injects --resume); using $bareCopilot"
        $resolved = [pscustomobject]@{
            Exe       = $bareCopilot
            Arguments = @()
            Source    = 'autodetect-bypass-agency'
            Display   = $bareCopilot
        }
    } else {
        Write-Warning "tangent: detected agency.exe but bare 'copilot' not on PATH; spawn will likely fail with -n/--resume conflict"
    }
}

# Stitch launcher prefix args (e.g. ['copilot'] for agency.exe) with our
# mode args. After bypass, $resolved.Arguments=@(), so bare copilot gets
# clean args without the leftover 'copilot' subcommand token.
$copilotArgs = @($resolved.Arguments) + $modeArgs

if ($ContextFile -and -not $clonedSessionId) {
    if (-not (Test-Path -LiteralPath $ContextFile)) {
        Write-Warning "tangent: context file $ContextFile does not exist; proceeding without --add-dir"
    } else {
        $ctxDir = Split-Path -Parent $ContextFile
        $copilotArgs += @('--add-dir', $ctxDir)
    }
}

# Compose the actual prompt (with context wrapper for non-new modes).
# Clone mode: the parent transcript is already loaded via --resume, so the
# prompt is sent verbatim as the first new user turn — no wrapper needed.
$finalPrompt = $Prompt
if ($Prompt -and $Mode -ne 'new' -and $ContextFile -and -not $clonedSessionId) {
    $relCtx = (Resolve-Path -LiteralPath $ContextFile).Path.Substring($worktreeDir.Length).TrimStart('\','/')
    $finalPrompt = @"
You inherited $Mode context from a parent Copilot CLI session.
Read $relCtx FIRST, then handle the user's task:

$Prompt
"@
}

# Write final prompt to a file the launch script will read — avoids all wt.exe quoting hell.
$promptFile = $null
if ($finalPrompt) {
    $promptFile = Join-Path $tangentMeta 'prompt.txt'
    Set-Content -LiteralPath $promptFile -Value $finalPrompt -Encoding UTF8
}

# ── Generate the per-tangent launch script ────────────────────────────
$launchScript = Join-Path $tangentMeta 'launch.ps1'
$exeLiteral   = "'" + ($resolved.Exe -replace "'", "''") + "'"
$argsArrayLit = if ($copilotArgs.Count -gt 0) {
    '@(' + (($copilotArgs | ForEach-Object {
        "'" + ($_ -replace "'", "''") + "'"
    }) -join ', ') + ')'
} else { '@()' }

$promptHandling = if ($promptFile) {
    $pfLit = "'" + ($promptFile -replace "'", "''") + "'"
    @"
`$promptText = Get-Content -LiteralPath $pfLit -Raw
`$copilotArgs += '-i'
`$copilotArgs += `$promptText
"@
} else { '' }

$launchBody = @"
#requires -Version 7.0
# Auto-generated by tangent.ps1 — runs the resolved Copilot launcher in this WT tab.
# Clear inherited session-identity env vars from the parent agency/copilot
# process so wrappers (e.g. agency.exe) don't auto-resume the parent session
# and conflict with our `-n <branch>` for a fresh session.
foreach (`$_n in @(
    'AGENCY_SESSION_ID',
    'AGENCY_LOG_SESSION_DIR',
    'COPILOT_AGENT_SESSION_ID',
    'COPILOT_LOADER_PID',
    'COPILOT_RUN_APP'
)) { Remove-Item -LiteralPath "env:`$_n" -ErrorAction SilentlyContinue }
`$env:TANGENT_SESSION             = '1'
`$env:TANGENT_BRANCH              = '$($Branch -replace "'", "''")'
`$env:TANGENT_WORKTREE            = '$($worktreeDir -replace "'", "''")'
`$env:TANGENT_PARENT_SESSION      = '$($parentSessionId -replace "'", "''")'
`$env:TANGENT_PARENT_DIR          = '$($parentSessionDir -replace "'", "''")'
`$env:TANGENT_INTERACTION_ID      = '$($interactionId -replace "'", "''")'
`$env:TANGENT_PARENT_BRANCH       = '$($parentBranchAtFork -replace "'", "''")'
Set-Location -LiteralPath '$($worktreeDir -replace "'", "''")'
`$copilotExe  = $exeLiteral
`$copilotArgs = $argsArrayLit
$promptHandling
Write-Host "tangent[$Branch]: launching `$copilotExe `$(`$copilotArgs -join ' ')"
& `$copilotExe @copilotArgs
"@

Set-Content -LiteralPath $launchScript -Value $launchBody -Encoding UTF8

# ── Spawn the visual surface ──────────────────────────────────────────
$tabTitle = "🌿 $Branch"
$wt = Get-Command wt.exe -ErrorAction SilentlyContinue

# State file (reload before checking for existing tab)
$stateDir  = Join-Path $HOME '.copilot/tangent'
$stateFile = Join-Path $stateDir 'state.json'
New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
$state = @{}
if (Test-Path -LiteralPath $stateFile) {
    try { $state = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json -AsHashtable } catch { $state = @{} }
    if ($null -eq $state) { $state = @{} }
}

# Best-effort: if a record exists, try to focus the tab
if ($state.ContainsKey($Branch) -and $wt) {
    Write-Host "tangent: state record exists for $Branch — attempting to focus tab"
    & wt.exe --window 0 focus-tab --title $tabTitle 2>$null
    # We have no reliable way to confirm; if focus failed silently, the new-tab below still proceeds.
}

if ($wt) {
    & wt.exe -w 0 new-tab `
        --title $tabTitle `
        --startingDirectory $worktreeDir `
        pwsh.exe -NoExit -ExecutionPolicy Bypass -File $launchScript
    if ($LASTEXITCODE -ne 0) { Die "wt.exe new-tab failed (exit $LASTEXITCODE)" }
} else {
    Write-Warning "tangent: wt.exe not found — falling back to Start-Process pwsh"
    Start-Process -FilePath 'pwsh.exe' `
        -ArgumentList @('-NoExit', '-ExecutionPolicy', 'Bypass', '-File', $launchScript) `
        -WorkingDirectory $worktreeDir
}

# ── Persist state and emit JSON result ────────────────────────────────
$state[$Branch] = [ordered]@{
    branch                = $Branch
    worktree              = $worktreeDir
    tab_title             = $tabTitle
    mode                  = $Mode
    launcher              = $resolved.Display
    launcher_source       = $resolved.Source
    started_at            = (Get-Date).ToString('o')
    parent_session_id     = $parentSessionId
    parent_session_dir    = $parentSessionDir
    parent_branch_at_fork = $parentBranchAtFork
    interaction_id        = $interactionId
    cloned_session_id     = $clonedSessionId
}
$state | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $stateFile -Encoding UTF8

[pscustomobject]@{
    branch            = $Branch
    worktree          = $worktreeDir
    tab_title         = $tabTitle
    mode              = $Mode
    launcher          = $resolved.Display
    launcherSource    = $resolved.Source
    resumed           = [bool]$resumed
    included          = [bool]$Include
    clonedSessionId   = $clonedSessionId
    nudge             = (Get-TangentNudge)
} | ConvertTo-Json -Compress
