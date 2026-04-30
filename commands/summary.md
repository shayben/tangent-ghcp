---
description: Spawn an isolated Copilot CLI session, seeded with a SUMMARY of the current conversation
argument-hint: "[branch] [--launcher=<cmd>] [--no-prompt] [--ignore-dirty] [--include] [--stash] [--commit=<msg>] [prompt...]"
---

# /tangent:summary

Spawn an isolated Copilot CLI session for a side task in its own git worktree
+ Windows Terminal tab. **This variant seeds the spawned session with a
concise summary** of this conversation — usually the right choice when
handing off a side task.

This command is implemented as a single deterministic PowerShell call. **Do
not parse `$ARGUMENTS` yourself, do not run git, do not invoke ask_user, do
not parse the engine output.** Your one creative responsibility is **writing
the summary text**. Everything else is dispatch.

## Procedure

The slash command is **two steps in a single tool call**:
(1) compose a 200–600 word markdown summary in your reply, then
(2) pipe it into the wrapper which handles parsing, dirty pre-flight,
    relocation into `<worktree>\.tangent\context.md`, engine dispatch, and
    result formatting.

Resolve the wrapper script:

```powershell
$wrapper = if ($env:CLAUDE_PLUGIN_ROOT) {
    Join-Path $env:CLAUDE_PLUGIN_ROOT 'scripts\tangent-spawn.ps1'
} else {
    (Get-ChildItem "$env:USERPROFILE\.copilot\installed-plugins" -Recurse `
        -Filter tangent-spawn.ps1 -EA SilentlyContinue | Select-Object -First 1).FullName
}
```

Compose the summary as a single PowerShell here-string, then pipe to the
wrapper. The here-string IS your summary — write it covering:

- The user's overarching goals and the current task
- Key decisions made and their rationale
- Files/modules touched and their roles
- Open threads, blockers, things to verify

Pass `-AutoName <slug>` derived from your summary's topic as a 2–4 kebab-case
slug, so the spawned tangent has a contextual branch name even when
`$ARGUMENTS` is empty (parameterless `/tangent:summary`):

```powershell
$summary = @'
# <topic>

<200-600 words of markdown — the only model-authored content in this command>
'@

$summary | & pwsh -NoProfile -File $wrapper -Mode summary -SummaryFromStdin `
    -ArgString "$ARGUMENTS" -AutoName '<context-slug-from-summary-topic>'
```

Print the wrapper's stdout **verbatim**. Add no commentary. Do not summarise.
Do not interpret.

## Behavior the wrapper handles deterministically

- **Argument parsing:** flags + branch + prompt extracted from `$ARGUMENTS`.
- **Branch auto-naming:** when omitted, generated as 2–4 kebab-case words from the prompt; namespaced under `tangent/`.
- **Dirty pre-flight:** if the parent worktree is dirty:
  - default → `--include` (carry edits into the spawned worktree)
  - `--stash` → stash first, leave stashed (recover with `git stash pop`)
  - `--commit="<msg>"` → commit before forking
  - `--ignore-dirty` → skip pre-flight entirely
- **Summary staging:** reads stdin into a temp file, passes it to the engine
  via `-ContextFile`; the engine relocates it into `<worktree>\.tangent\context.md`.
- **Engine dispatch:** `tangent.ps1 -Mode summary -ContextFile <staged>`.
- **Result formatting:** human-readable summary on stdout.

## Examples

```
/tangent:summary refactor the JWT middleware to use jose v5
/tangent:summary fix-auth-bug refactor the JWT middleware
/tangent:summary fix-auth-bug --no-prompt          # resume
/tangent:summary --launcher="agency.exe copilot" demo-x test the wrapper
```

## See also

- `/tangent:new` — blank session, no context handoff.
- `/tangent:full` — full-fidelity session clone (events, plan.md, checkpoints, files, db).
- `/tangent:handback` — ship results from a tangent back to its parent session.
