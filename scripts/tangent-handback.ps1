#requires -Version 7.0
<#
.SYNOPSIS
    tangent-handback — ship a context digest from a tangent session back to its
    parent Copilot CLI session.

.DESCRIPTION
    Composes a markdown digest (summary + git changes + commits + optional
    user message) and atomically publishes it as a JSON file to the parent
    session's tangent-handback inbox dir. The parent session ingests it via
    the UserPromptSubmit hook (best-effort).

    Refuses to run unless TANGENT_PARENT_SESSION/_DIR/_INTERACTION_ID env vars
    are set (i.e. this shell was spawned by tangent.ps1) and the parent
    session dir still exists.

.NOTES
    Delivery is context-only. No git operations on the parent. Content is
    XML-escaped and capped at 8 KB UTF-8 bytes for the body. Atomic publish:
    write *.json.tmp, rename to *.json.
#>
[CmdletBinding()]
param(
    [string]$Message = '',
    [string]$BaseRef = '',
    [int]$MaxBodyBytes = 8192
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Die($msg) { Write-Error "tangent-handback: $msg"; exit 1 }

# ── Pre-flight ────────────────────────────────────────────────────────
$parentSession = $env:TANGENT_PARENT_SESSION
$parentDir     = $env:TANGENT_PARENT_DIR
$interactionId = $env:TANGENT_INTERACTION_ID
$branch        = $env:TANGENT_BRANCH
$tangentSid    = $env:COPILOT_AGENT_SESSION_ID

if (-not $parentSession) { Die 'TANGENT_PARENT_SESSION not set — handback only works inside a tangent session spawned by tangent.ps1.' }
if (-not $parentDir)     { Die 'TANGENT_PARENT_DIR not set.' }
if (-not $interactionId) { Die 'TANGENT_INTERACTION_ID not set.' }
if (-not $branch)        { Die 'TANGENT_BRANCH not set.' }
if (-not (Test-Path -LiteralPath $parentDir)) { Die "parent session dir does not exist: $parentDir" }

# ── Resolve base ref for diff / log ───────────────────────────────────
if (-not $BaseRef) {
    if ($env:TANGENT_PARENT_BRANCH) { $BaseRef = $env:TANGENT_PARENT_BRANCH }
    else {
        $defaultBranch = (& git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>$null)
        if ($defaultBranch) { $BaseRef = ($defaultBranch -replace '^origin/','').Trim() } else { $BaseRef = 'main' }
    }
}

# ── Compose body ──────────────────────────────────────────────────────
$sb = [System.Text.StringBuilder]::new()
[void]$sb.AppendLine("# Tangent handback: $branch")
[void]$sb.AppendLine("")
[void]$sb.AppendLine("- base: ``$BaseRef``")
[void]$sb.AppendLine("- worktree: ``$($env:TANGENT_WORKTREE)``")
[void]$sb.AppendLine("- sent_at: $((Get-Date).ToString('o'))")
[void]$sb.AppendLine("")

if ($Message) {
    [void]$sb.AppendLine("## Message")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine($Message.Trim())
    [void]$sb.AppendLine("")
}

# Files changed
[void]$sb.AppendLine("## Files changed (vs $BaseRef)")
[void]$sb.AppendLine("")
$files = @()
try { $files = & git diff --name-status "$BaseRef...HEAD" 2>$null } catch {}
if (-not $files -or $files.Count -eq 0) {
    [void]$sb.AppendLine("_(no committed changes vs $BaseRef)_")
} else {
    $maxFiles = 50
    $shown = $files | Select-Object -First $maxFiles
    foreach ($line in $shown) { [void]$sb.AppendLine("- ``$line``") }
    if ($files.Count -gt $maxFiles) { [void]$sb.AppendLine("- _($($files.Count - $maxFiles) more)_") }
}
[void]$sb.AppendLine("")

# Uncommitted
$dirty = & git status --porcelain 2>$null
if ($dirty) {
    [void]$sb.AppendLine("## Uncommitted in worktree")
    [void]$sb.AppendLine("")
    $dlines = @($dirty)
    $shownD = $dlines | Select-Object -First 30
    foreach ($d in $shownD) { [void]$sb.AppendLine("- ``$d``") }
    if ($dlines.Count -gt 30) { [void]$sb.AppendLine("- _($($dlines.Count - 30) more)_") }
    [void]$sb.AppendLine("")
}

# Commits
[void]$sb.AppendLine("## Commits (vs $BaseRef)")
[void]$sb.AppendLine("")
$commits = @()
try { $commits = & git log "$BaseRef..HEAD" --oneline 2>$null } catch {}
if (-not $commits -or $commits.Count -eq 0) {
    [void]$sb.AppendLine("_(none)_")
} else {
    $maxC = 30
    $shownC = $commits | Select-Object -First $maxC
    foreach ($c in $shownC) { [void]$sb.AppendLine("- $c") }
    if ($commits.Count -gt $maxC) { [void]$sb.AppendLine("- _($($commits.Count - $maxC) more)_") }
}
[void]$sb.AppendLine("")

$body = $sb.ToString()

# ── Cap body at $MaxBodyBytes (UTF-8) ─────────────────────────────────
$bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($body)
if ($bodyBytes.Length -gt $MaxBodyBytes) {
    # Truncate to byte budget at a char boundary, append a tail marker.
    $tail = "`n`n_(truncated at $MaxBodyBytes bytes)_`n"
    $tailBytes = [System.Text.Encoding]::UTF8.GetBytes($tail)
    $budget = [Math]::Max(0, $MaxBodyBytes - $tailBytes.Length)
    # Decode the prefix safely with a replacement fallback for partial code points
    $dec = [System.Text.Encoding]::GetEncoding(
        'utf-8',
        [System.Text.EncoderFallback]::ReplacementFallback,
        [System.Text.DecoderFallback]::ReplacementFallback
    )
    $body = $dec.GetString($bodyBytes, 0, $budget) + $tail
}

# ── XML-escape body and attribute values ──────────────────────────────
function Escape-Xml([string]$s) {
    if ($null -eq $s) { return '' }
    return ($s -replace '&','&amp;') -replace '<','&lt;' -replace '>','&gt;'
}
function Escape-XmlAttr([string]$s) {
    return (Escape-Xml $s) -replace '"','&quot;'
}

$bodyEscaped   = Escape-Xml $body
$branchAttr    = Escape-XmlAttr $branch
$summary       = if ($Message) { ($Message -split "(`r`n|`n)")[0].Trim() } else { "Tangent $branch returned changes vs $BaseRef." }
if ($summary.Length -gt 300) { $summary = $summary.Substring(0, 297) + '...' }
$summaryEsc    = Escape-Xml $summary

$wrapped = "<tangent-handback branch=""$branchAttr"" trust=""untrusted"">`n$bodyEscaped`n</tangent-handback>"

# ── Sequence (best-effort): max(existing) + 1 across inbox+processing+read for our interaction_id ──
$inboxBase = Join-Path $parentDir 'files\tangent-handback'
$inboxDir  = Join-Path $inboxBase 'inbox'
$procDir   = Join-Path $inboxBase 'processing'
$readDir   = Join-Path $inboxBase 'read'
foreach ($d in @($inboxDir, $procDir, $readDir)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }

$nextSeq = 0
foreach ($d in @($inboxDir, $procDir, $readDir)) {
    Get-ChildItem -LiteralPath $d -Filter '*.json' -EA SilentlyContinue | ForEach-Object {
        try {
            $j = Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json
            if ($j.interaction_id -eq $interactionId -and $null -ne $j.sequence) {
                $s = [int]$j.sequence
                if ($s -ge $nextSeq) { $nextSeq = $s + 1 }
            }
        } catch {}
    }
}

# ── Sanitize branch for filename ──────────────────────────────────────
function Sanitize-Slug([string]$s) {
    if (-not $s) { return 'unknown' }
    $clean = ($s -replace '[\\/:\*\?"<>\|\s\p{C}]+','-').Trim('-','.')
    if (-not $clean) { return 'unknown' }
    if ($clean.Length -gt 40) { $clean = $clean.Substring(0, 40).TrimEnd('-','.') }
    return $clean
}

$slug    = Sanitize-Slug $branch
$utcTs   = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ')
$id      = [guid]::NewGuid().ToString()
$fname   = "$utcTs--$slug--$id.json"
$tmpPath = Join-Path $inboxDir "$fname.tmp"
$finalPath = Join-Path $inboxDir $fname

$payload = [ordered]@{
    id                  = $id
    branch              = $branch
    interaction_id      = $interactionId
    sequence            = $nextSeq
    tangent_session_id  = $tangentSid
    parent_session_id   = $parentSession
    summary             = $summaryEsc
    content_xml_escaped = $wrapped
    sent_at_iso         = (Get-Date).ToString('o')
}

# ── Atomic publish ────────────────────────────────────────────────────
$json = $payload | ConvertTo-Json -Depth 10
Set-Content -LiteralPath $tmpPath -Value $json -Encoding UTF8
Move-Item -LiteralPath $tmpPath -Destination $finalPath

Write-Host ""
Write-Host "📬 handback delivered to parent session"
Write-Host "   branch:         $branch"
Write-Host "   interaction:    $interactionId"
Write-Host "   sequence:       $nextSeq"
Write-Host "   parent inbox:   $finalPath"
Write-Host ""
Write-Host "The parent will surface this on its next prompt (UserPromptSubmit hook), or"
Write-Host "fall back to whenever the parent reads its files\tangent-handback\inbox dir."
