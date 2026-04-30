#requires -Version 7.0
<#
.SYNOPSIS
    Deterministic spawn wrapper for /tangent:new, /tangent:summary, and
    /tangent:full. Parses $ARGUMENTS as a single string, handles dirty-tree
    pre-flight, optionally writes a summary file, dispatches to the engine,
    and prints the final human-readable report. Designed so the slash-command
    markdown reduces to a single tool call with zero model reasoning required
    (other than authoring the summary text for /tangent:summary).

.DESCRIPTION
    Slash-command bodies become:
        Run `pwsh -NoProfile -File <plugin>\scripts\tangent-spawn.ps1
             -Mode {new|summary|full} -ArgString "$ARGUMENTS" [-SummaryFromStdin]`
        and print stdout verbatim.

    All argument parsing, branch auto-naming, dirty-handling, summary-file
    relocation, engine dispatch, and result formatting live here.

.PARAMETER Mode
    The spawn mode forwarded to the engine (-Mode parameter).
        new      — blank session, no context handoff.
        summary  — model-authored summary handoff. Requires -SummaryFromStdin
                   or -SummaryFile so the wrapper has summary text to seed.
        full     — deterministic session-clone (events, tools, plan.md, …).

.PARAMETER ArgString
    The raw $ARGUMENTS string. See Usage section for flags.

.PARAMETER SummaryFromStdin
    For -Mode summary: read the summary text from stdin and write it into
    <worktree>\.tangent\context.md before invoking the engine.

.PARAMETER SummaryFile
    For -Mode summary: path to a pre-written summary file. Mutually exclusive
    with -SummaryFromStdin.

.PARAMETER DryRun
    Skip the engine dispatch and emit the parsed plan as JSON. For tests and
    "what would this do?" probes.

.NOTES
    Recognised flags inside ArgString:
        --launcher="<cmd>"   override the autodetected launcher
        --no-prompt          resume an existing tangent (no clone, no -i prompt)
        --ignore-dirty       skip the dirty pre-flight entirely
        --include            carry uncommitted parent edits into the worktree (DEFAULT when dirty)
        --stash              stash parent edits and leave them stashed
        --commit="<msg>"     commit parent edits with the given message before forking

    Positional: first non-flag token is the branch (auto-prefixed with
    "tangent/" if it looks like a slug — must contain - / . _ or a digit, or
    start with `tangent/`. Pure alphabetic words like "fix" or "implement"
    are part of the prompt). Everything after the branch is the prompt.

    If the branch is omitted, resolution falls through:
      1. -AutoName <slug> (caller-supplied; e.g. derived from session topic).
      2. Auto-generated 2-4 kebab words from the prompt.
      3. Random `task-<short-guid>` (parameterless invocation).

    Empty ArgString is allowed (parameterless `/tangent:full` etc. spawn a
    contextless clone with an auto-named branch).
#>
[CmdletBinding()]
param(
    [ValidateSet('new', 'summary', 'full')]
    [string]$Mode = 'full',

    [string]$ArgString = '',

    [switch]$SummaryFromStdin,

    [string]$SummaryFile = '',

    # Caller-supplied branch slug used when ArgString contains no positional
    # branch token. Lets the slash-command model contribute a context-aware
    # name (e.g. derived from the current session topic) for parameterless
    # invocations like `/tangent:full` with no args.
    [string]$AutoName = '',

    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Die($msg, $code = 2) {
    Write-Host "❌ tangent: $msg" -ForegroundColor Red
    exit $code
}

# ── Parse $ARGUMENTS ──────────────────────────────────────────────────
# Tokeniser: respects "double quoted" runs as a single token. Good enough for
# the surface area /tangent:full exposes (flag values, branch names, prompts).
function ConvertTo-ArgTokens([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return @() }
    $tokens = [System.Collections.Generic.List[string]]::new()
    $cur = New-Object System.Text.StringBuilder
    $inQuote = $false
    foreach ($ch in $s.ToCharArray()) {
        if ($ch -eq '"') { $inQuote = -not $inQuote; continue }
        if (-not $inQuote -and [char]::IsWhiteSpace($ch)) {
            if ($cur.Length -gt 0) { $tokens.Add($cur.ToString()); $cur.Clear() | Out-Null }
            continue
        }
        $cur.Append($ch) | Out-Null
    }
    if ($cur.Length -gt 0) { $tokens.Add($cur.ToString()) }
    return ,$tokens.ToArray()
}

$tokens = ConvertTo-ArgTokens $ArgString

$launcher    = ''
$noPrompt    = $false
$ignoreDirty = $false
$dirtyMode   = ''   # '', 'include', 'stash', 'commit'
$commitMsg   = ''
$positional  = [System.Collections.Generic.List[string]]::new()

foreach ($t in $tokens) {
    switch -Regex ($t) {
        '^--launcher=(.+)$'  { $launcher    = $Matches[1]; continue }
        '^--no-prompt$'      { $noPrompt    = $true;       continue }
        '^--ignore-dirty$'   { $ignoreDirty = $true;       continue }
        '^--include$'        { $dirtyMode   = 'include';   continue }
        '^--stash$'          { $dirtyMode   = 'stash';     continue }
        '^--commit=(.+)$'    { $dirtyMode   = 'commit'; $commitMsg = $Matches[1]; continue }
        default              { $positional.Add($t) }
    }
}

# ── Branch + prompt extraction ────────────────────────────────────────
# A "branch token" is the first positional token that LOOKS like a slug
# (must contain at least one of - / . _ or a digit, OR start with `tangent/`).
# Pure alphabetic words like "fix" or "implement" are treated as part of the
# prompt — otherwise short verb-led prompts get hijacked as branch names.
$branch = ''
$promptParts = [System.Collections.Generic.List[string]]::new()
if ($positional.Count -gt 0) {
    $first = $positional[0]
    $isSlug = $first -match '^[A-Za-z0-9][A-Za-z0-9._/\-]{0,63}$' -and
              ($first -match '[\-/._0-9]' -or $first -like 'tangent/*')
    if ($isSlug) {
        $branch = $first
        if ($positional.Count -gt 1) { $promptParts.AddRange([string[]]$positional[1..($positional.Count-1)]) }
    } else {
        $promptParts.AddRange([string[]]$positional)
    }
}
$prompt = ($promptParts -join ' ').Trim()

# ── Resolve branch ────────────────────────────────────────────────────
# Priority order:
#   1. Positional branch token from $ArgString
#   2. -AutoName from caller (slash-command model derived a context slug)
#   3. Auto-named from prompt words
#   4. Fallback random task-<short-guid> (parameterless invocation)
function New-AutoBranch([string]$p) {
    if (-not $p) { return "task-$([guid]::NewGuid().ToString('N').Substring(0,6))" }
    $words = ($p.ToLowerInvariant() -replace '[^a-z0-9 ]', ' ' -split '\s+') |
        Where-Object { $_ -and $_.Length -gt 1 -and $_ -notin @('the','a','an','to','of','for','and','or','in','on','my','me','i','is','it','that','this','with','from') }
    if (-not $words) { return "task-$([guid]::NewGuid().ToString('N').Substring(0,6))" }
    return ($words | Select-Object -First 4) -join '-'
}

if (-not $branch) {
    if ($AutoName) {
        # Sanitize caller-supplied slug: lowercase, alnum + hyphen only,
        # collapse repeats, trim leading/trailing hyphens, cap at 64 chars.
        $slug = $AutoName.ToLowerInvariant() -replace '[^a-z0-9/-]+', '-' -replace '-+', '-'
        $slug = $slug.Trim('-')
        if ($slug.Length -gt 64) { $slug = $slug.Substring(0, 64).TrimEnd('-') }
        if ($slug) { $branch = $slug }
    }
}
if (-not $branch) {
    $branch = New-AutoBranch $prompt
}

# Always namespace under tangent/ unless the user already did.
if ($branch -notmatch '^tangent/') { $branch = "tangent/$branch" }

# ── Dry-run: emit parsed plan as JSON and exit ────────────────────────
# Used by tests and for "what would this do?" probes. No side effects.
if ($DryRun) {
    [pscustomobject]@{
        mode             = $Mode
        branch           = $branch
        prompt           = $prompt
        launcher         = $launcher
        noPrompt         = [bool]$noPrompt
        ignoreDirty      = [bool]$ignoreDirty
        dirtyMode        = $dirtyMode
        commitMsg        = $commitMsg
        summaryFromStdin = [bool]$SummaryFromStdin
        summaryFile      = $SummaryFile
        autoName         = $AutoName
    } | ConvertTo-Json -Compress
    exit 0
}

# ── Mode-specific validation ──────────────────────────────────────────
if ($Mode -eq 'summary' -and -not $SummaryFromStdin -and -not $SummaryFile) {
    Die "-Mode summary requires either -SummaryFromStdin or -SummaryFile" 2
}
if ($SummaryFromStdin -and $SummaryFile) {
    Die "-SummaryFromStdin and -SummaryFile are mutually exclusive" 2
}

# ── Locate engine ─────────────────────────────────────────────────────
$engine = Join-Path $PSScriptRoot 'tangent.ps1'
if (-not (Test-Path -LiteralPath $engine)) {
    Die "engine not found at $engine" 3
}

# ── Dirty-tree pre-flight ─────────────────────────────────────────────
$includeFlag = $false
$dirtySummary = ''
if (-not $ignoreDirty -and -not $noPrompt) {
    $repoRoot = (& git rev-parse --show-toplevel 2>$null)
    if ($LASTEXITCODE -eq 0 -and $repoRoot) {
        Push-Location $repoRoot
        try {
            $status = (& git status --porcelain)
            if ($status) {
                # Default policy when no flag was passed: --include (carry edits
                # into the worktree). User can override via --stash / --commit /
                # --ignore-dirty. Decision was made deliberately to favour
                # workflow continuity over preservation-first.
                if (-not $dirtyMode) { $dirtyMode = 'include' }
                $dirtyLines = ($status -split "`r?`n").Count
                switch ($dirtyMode) {
                    'commit' {
                        if (-not $commitMsg) { Die "--commit requires a message: --commit=`"<msg>`"" 2 }
                        & git add -A 2>&1 | Out-Null
                        & git commit -m $commitMsg 2>&1 | Out-Null
                        if ($LASTEXITCODE -ne 0) { Die "git commit failed" 4 }
                        $dirtySummary = "  pre-flight:    committed $dirtyLines dirty path(s) — `"$commitMsg`""
                    }
                    'stash' {
                        & git stash push -u -m "pre-tangent $branch" 2>&1 | Out-Null
                        if ($LASTEXITCODE -ne 0) { Die "git stash failed" 4 }
                        $dirtySummary = "  pre-flight:    stashed $dirtyLines dirty path(s) (recover with: git stash pop)"
                    }
                    'include' {
                        $includeFlag = $true
                        $dirtySummary = "  pre-flight:    carrying $dirtyLines dirty path(s) into worktree (--include)"
                    }
                    default { Die "unknown dirty mode: $dirtyMode" 4 }
                }
            }
        } finally { Pop-Location }
    }
}

# ── Summary mode: stage the summary as a TEMP file ───────────────────
# Engine creates the worktree itself (via `git worktree add`), which fails
# if the target path already exists. So we write to TEMP and let the engine
# relocate the file into <worktree>\.tangent\ after it's been added (the
# engine has built-in relocation logic for caller-supplied seed files).
$contextFilePath = ''
if ($Mode -eq 'summary') {
    $stageDir = Join-Path $env:TEMP "tangent-summary-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    New-Item -ItemType Directory -Path $stageDir -Force | Out-Null
    $contextFilePath = Join-Path $stageDir 'context.md'

    if ($SummaryFromStdin) {
        $summaryText = [Console]::In.ReadToEnd()
        if ([string]::IsNullOrWhiteSpace($summaryText)) {
            Die "summary mode: stdin was empty (model produced no summary text)" 2
        }
        Set-Content -LiteralPath $contextFilePath -Value $summaryText -Encoding UTF8
    } else {
        if (-not (Test-Path -LiteralPath $SummaryFile)) {
            Die "summary file not found: $SummaryFile" 2
        }
        Copy-Item -LiteralPath $SummaryFile -Destination $contextFilePath -Force
    }
}

# ── Dispatch to engine ────────────────────────────────────────────────
$engineArgs = @('-Branch', $branch, '-Mode', $Mode)
if ($prompt)           { $engineArgs += @('-Prompt', $prompt) }
if ($launcher)         { $engineArgs += @('-Launcher', $launcher) }
if ($contextFilePath)  { $engineArgs += @('-ContextFile', $contextFilePath) }
if ($includeFlag)      { $engineArgs += '-Include' }
if ($noPrompt)         { $engineArgs += '-Resume' }

# Engine writes progress to host stream and JSON to stdout. Capture stdout
# only; let progress flow through to the user's terminal as the engine runs.
$engineJson = & pwsh -NoProfile -File $engine @engineArgs
if ($LASTEXITCODE -ne 0) { Die "engine exited with $LASTEXITCODE" 5 }

$result = $null
try {
    # Engine emits one JSON line at the end; if anything else slipped through,
    # last non-empty line is the JSON.
    $jsonLine = ($engineJson -split "`r?`n" | Where-Object { $_.Trim() -match '^\{' } | Select-Object -Last 1)
    $result = $jsonLine | ConvertFrom-Json
} catch {
    Die "could not parse engine JSON: $($_.Exception.Message)`nraw: $engineJson" 6
}

# ── Format report ─────────────────────────────────────────────────────
$autoNamed = ($positional.Count -eq 0) -or ($positional[0] -ne ($branch -replace '^tangent/',''))
$lines = @()
$lines += "🌿 tangent spawned: $($result.branch)" + $(if ($autoNamed -and $result.branch -eq $branch) { " (auto-named)" } else { "" })
$lines += "  worktree:      $($result.worktree)"
$lines += "  mode:          $($result.mode)" + $(if ($result.PSObject.Properties['clonedSessionId'] -and $result.clonedSessionId) { " (cloned session: $($result.clonedSessionId))" } else { "" })
$lines += "  launcher:      $($result.launcher) (source: $($result.launcherSource))"
if ($result.resumed) { $lines += "  resumed:       true" }
if ($result.included) { $lines += "  included:      true (parent edits applied in worktree)" }
if ($dirtySummary) { $lines += $dirtySummary }
if ($result.PSObject.Properties['nudge'] -and $result.nudge) { $lines += ""; $lines += $result.nudge }

$lines -join "`n"
