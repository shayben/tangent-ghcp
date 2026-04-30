---
description: Spawn an isolated Copilot CLI session in a new git worktree + Windows Terminal tab — NO context handoff (blank session)
argument-hint: "[branch] [--launcher=<cmd>] [--no-prompt] [--ignore-dirty] [--include] [--stash] [--commit=<msg>] [prompt...]"
---

# /tangent:new

Spawn a **blank** isolated Copilot CLI session in its own git worktree
+ Windows Terminal tab. No context handoff — the new session starts fresh
with only the user's prompt.

This command is implemented as a single deterministic PowerShell call. **Do
not parse `$ARGUMENTS` yourself, do not run git, do not invoke ask_user, do
not parse the engine output. Just dispatch and print.**

## Procedure

Resolve the wrapper script:

```powershell
$wrapper = if ($env:CLAUDE_PLUGIN_ROOT) {
    Join-Path $env:CLAUDE_PLUGIN_ROOT 'scripts\tangent-spawn.ps1'
} else {
    (Get-ChildItem "$env:USERPROFILE\.copilot\installed-plugins" -Recurse `
        -Filter tangent-spawn.ps1 -EA SilentlyContinue | Select-Object -First 1).FullName
}
```

Run it, passing `$ARGUMENTS` verbatim as a single string. **If `$ARGUMENTS`
is empty/whitespace** (parameterless `/tangent:new`), additionally derive a
2–4 kebab-case slug summarising the current session's work and pass it via
`-AutoName` so the spawned tangent gets a contextual name instead of a
random `task-<guid>`:

```powershell
if ([string]::IsNullOrWhiteSpace("$ARGUMENTS")) {
    & pwsh -NoProfile -File $wrapper -Mode new -ArgString '' -AutoName '<context-slug>'
} else {
    & pwsh -NoProfile -File $wrapper -Mode new -ArgString "$ARGUMENTS"
}
```

Print the wrapper's stdout **verbatim**. Add no commentary. Do not summarise.
Do not interpret. The wrapper handles every concern (argument parsing, branch
auto-naming, dirty pre-flight, engine dispatch, result formatting) and emits
the final user-facing report itself.

## Behavior the wrapper handles deterministically

- **Argument parsing:** flags + branch + prompt extracted from `$ARGUMENTS`.
- **Branch auto-naming:** when omitted, generated as 2–4 kebab-case words from the prompt; namespaced under `tangent/`.
- **Dirty pre-flight:** if the parent worktree is dirty:
  - default → `--include` (carry edits into the spawned worktree)
  - `--stash` → stash first, leave stashed (recover with `git stash pop`)
  - `--commit="<msg>"` → commit before forking
  - `--ignore-dirty` → skip pre-flight entirely
- **Engine dispatch:** `tangent.ps1 -Mode new` (no context seed).
- **Result formatting:** human-readable summary on stdout.

## Examples

```
/tangent:new try a different approach
/tangent:new spike-graphql experiment with a graphql api
/tangent:new spike-graphql --no-prompt          # resume existing tangent
/tangent:new --commit="wip checkpoint" demo-x test the change
```

## See also

- `/tangent:summary` — model-written summary handoff (concise; no event history).
- `/tangent:full` — full-fidelity session clone (events, plan.md, checkpoints, files, db).
- `/tangent:handback` — ship results from a tangent back to its parent session.
