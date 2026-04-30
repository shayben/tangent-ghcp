#requires -Version 7.0
<#
.SYNOPSIS
    Clone a Copilot CLI session folder under a new session id, rewriting
    workspace.yaml + events.jsonl so the spawned tangent can `--resume=<newId>`
    with full parent-session fidelity (events, plan.md, checkpoints, files).

.DESCRIPTION
    Replaces the old model-driven `/share` markdown handoff for /tangent:full.
    Pure deterministic file ops — no model reasoning required.

    Steps:
      1. Robocopy parent session folder → new session folder (excluding lock
         files and rewind-snapshots which are large + replay-only).
      2. Rewrite workspace.yaml: id, cwd, git_root, branch, name, summary,
         user_named, updated_at; clear mc_* (per-session machine claims).
      3. Bulk string-replace parent GUID → new GUID in events.jsonl.
      4. Append a `session.info` fork marker event recording provenance.
      5. Emit JSON: { parentSessionId, newSessionId, targetDir,
         eventsRewritten, sizeBytes }.

.PARAMETER ParentSessionId
    The parent Copilot session id (typically $env:COPILOT_AGENT_SESSION_ID).

.PARAMETER NewSessionId
    The new session id to create. Caller generates this (engine uses New-Guid).

.PARAMETER Branch
    The tangent branch name (used in the rewritten workspace.yaml).

.PARAMETER WorktreePath
    The tangent worktree absolute path (used as cwd + git_root in the new
    workspace.yaml so the resumed session opens with the correct workspace).

.PARAMETER SessionStateRoot
    Override the session-state root. Defaults to ~/.copilot/session-state.
    Mainly here for tests.

.OUTPUTS
    JSON object on stdout describing the result.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ParentSessionId,
    [Parameter(Mandatory)][string]$NewSessionId,
    [Parameter(Mandatory)][string]$Branch,
    [Parameter(Mandatory)][string]$WorktreePath,
    [string]$SessionStateRoot = (Join-Path $HOME '.copilot/session-state')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Die($msg) { Write-Error "tangent-clone: $msg"; exit 1 }

if ($ParentSessionId -eq $NewSessionId) {
    Die "ParentSessionId and NewSessionId must differ"
}

$src = Join-Path $SessionStateRoot $ParentSessionId
$dst = Join-Path $SessionStateRoot $NewSessionId

if (-not (Test-Path -LiteralPath $src -PathType Container)) { Die "parent session folder not found: $src" }
if (Test-Path -LiteralPath $dst) { Die "new session folder already exists: $dst" }

# ── Step 1: copy folder, excluding locks + replay-only data ───────────
# robocopy is the right tool on Windows: native, fast, handles long paths,
# and supports exclusion patterns out of the box. Exit codes 0..7 are success.
$rcLog = New-TemporaryFile
try {
    & robocopy $src $dst /E `
        /XD 'rewind-snapshots' `
        /XF 'inuse.*.lock' `
        /R:1 /W:1 /NFL /NDL /NJH /NJS /NC /NS /NP `
        /LOG:$rcLog | Out-Null
    if ($LASTEXITCODE -gt 7) {
        $tail = Get-Content -LiteralPath $rcLog -Tail 30 -EA SilentlyContinue
        Die ("robocopy failed (exit $LASTEXITCODE):`n" + ($tail -join "`n"))
    }
} finally {
    Remove-Item -LiteralPath $rcLog -Force -EA SilentlyContinue
}

if (-not (Test-Path -LiteralPath $dst -PathType Container)) {
    Die "robocopy produced no destination dir at $dst"
}

# ── Step 2: rewrite workspace.yaml ────────────────────────────────────
$wsPath = Join-Path $dst 'workspace.yaml'
if (Test-Path -LiteralPath $wsPath) {
    $ws  = Get-Content -LiteralPath $wsPath -Raw
    $now = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')

    # Per-key line replacements — safer than substring replace because some values
    # could legitimately appear elsewhere in the file (e.g. branch name in summary).
    $rewrites = [ordered]@{
        '^id:\s*.+$'              = "id: $NewSessionId"
        '^cwd:\s*.+$'             = "cwd: $WorktreePath"
        '^git_root:\s*.+$'        = "git_root: $WorktreePath"
        '^branch:\s*.+$'          = "branch: $Branch"
        '^name:\s*.+$'            = "name: $Branch"
        '^summary:\s*.+$'         = "summary: $Branch (forked from $ParentSessionId)"
        '^summary_count:\s*.+$'   = 'summary_count: 0'
        '^user_named:\s*.+$'      = 'user_named: false'
        '^updated_at:\s*.+$'      = "updated_at: $now"
        '^mc_task_id:\s*.+$'      = 'mc_task_id: ""'
        '^mc_session_id:\s*.+$'   = 'mc_session_id: ""'
        '^mc_last_event_id:\s*.+$' = 'mc_last_event_id: ""'
    }
    foreach ($pat in $rewrites.Keys) {
        $ws = [regex]::Replace($ws, $pat, $rewrites[$pat], 'Multiline')
    }
    Set-Content -LiteralPath $wsPath -Value $ws -Encoding UTF8 -NoNewline
}

# ── Step 3: rewrite events.jsonl ──────────────────────────────────────
# A GUID is unique enough that a plain string replace is safe — it cannot
# legitimately collide with anything else in the file (no other event will
# reference the parent session id by accident).
$evPath = Join-Path $dst 'events.jsonl'
$eventsRewritten = 0
if (Test-Path -LiteralPath $evPath) {
    $evContent = [IO.File]::ReadAllText($evPath)
    $eventsRewritten = ([regex]::Matches($evContent, [regex]::Escape($ParentSessionId))).Count
    if ($eventsRewritten -gt 0) {
        $evContent = $evContent.Replace($ParentSessionId, $NewSessionId)
        [IO.File]::WriteAllText($evPath, $evContent)
    }
}

# ── Step 4: append fork marker event ──────────────────────────────────
$forkEvt = [ordered]@{
    id        = [guid]::NewGuid().ToString()
    parentId  = $null
    timestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    type      = 'session.info'
    data      = [ordered]@{
        message = "Session forked from $ParentSessionId by tangent for branch $Branch."
        fork    = [ordered]@{
            parent_session_id = $ParentSessionId
            branch            = $Branch
            worktree          = $WorktreePath
        }
    }
} | ConvertTo-Json -Depth 6 -Compress
if (Test-Path -LiteralPath $evPath) {
    Add-Content -LiteralPath $evPath -Value $forkEvt -Encoding UTF8
} else {
    Set-Content -LiteralPath $evPath -Value $forkEvt -Encoding UTF8
}

# ── Step 5: emit JSON summary ─────────────────────────────────────────
$size = (Get-ChildItem -LiteralPath $dst -Recurse -File -EA SilentlyContinue | Measure-Object Length -Sum).Sum

[pscustomobject]@{
    parentSessionId = $ParentSessionId
    newSessionId    = $NewSessionId
    targetDir       = $dst
    eventsRewritten = $eventsRewritten
    sizeBytes       = [int64]($size ?? 0)
} | ConvertTo-Json -Compress

# robocopy intentionally exits non-zero on success (1 = files copied; 0..7
# all mean OK). The script's natural exit otherwise propagates $LASTEXITCODE
# from robocopy and the engine treats us as failed. Force a clean exit so
# the engine actually wires up --resume=<newId>.
exit 0
