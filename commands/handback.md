---
description: Ship a context digest from this tangent session back to its parent Copilot CLI session (context only — no git merge)
argument-hint: "[message...]"
---

# /tangent:handback

Send a structured context digest (summary + git diff list + commits + optional
free-form message) from **this tangent session** back to the **parent session
that spawned it**. Delivery is **context only** — no git merges, no automatic
file edits in the parent. The parent decides what to do with the information.

Only works inside a session that was launched by `tangent.ps1` (env vars
`TANGENT_PARENT_SESSION` / `TANGENT_PARENT_DIR` / `TANGENT_INTERACTION_ID`
are set). Refuses politely otherwise.

## Procedure

This command is implemented as a single deterministic PowerShell call. **Do
not parse `$ARGUMENTS` yourself, do not run git, do not parse the script
output. Just dispatch and print.**

Resolve the helper script:

```powershell
$plugin = if ($env:CLAUDE_PLUGIN_ROOT) { $env:CLAUDE_PLUGIN_ROOT } else {
    (Get-ChildItem "$env:USERPROFILE\.copilot\installed-plugins" -Recurse `
        -Filter tangent-handback.ps1 -EA SilentlyContinue | Select-Object -First 1).Directory.Parent.FullName
}
$script = Join-Path $plugin 'scripts\tangent-handback.ps1'
```

Invoke, passing `$ARGUMENTS` verbatim as a single `-Message` string (empty
string is fine — the script auto-generates a digest in either case):

```powershell
& pwsh -NoProfile -File $script -Message "$ARGUMENTS"
```

Print the script's stdout **verbatim**. Add no commentary. Do not summarise.
Do not interpret. The script handles every concern (digest assembly, size
caps, atomic publish, parent verification) and emits the final user-facing
report itself.

## Behavior

- **Atomic publish** — handback file is written as `*.json.tmp` then renamed to
  `*.json`, so a parent reading the inbox concurrently never sees a half-written
  file.
- **Body cap** — content body is capped at 8 KB UTF-8 bytes. Long sections are
  truncated with `(N more)` tails.
- **Provenance** — file records `parent_session_id`, `interaction_id`, and the
  sender (`tangent_session_id`). Parent ingest verifies the first two.
- **Sandboxed** — content is XML-escaped and wrapped in
  `<tangent-handback trust="untrusted">…</tangent-handback>` so the parent's
  model treats it as data.
- **No git side-effects** — handback never pushes, merges, or changes the
  parent's working tree. If you want a git merge, do it separately in the
  parent session (e.g. `git -C <parent-worktree> merge tangent/<branch>`).

## Examples

```
/tangent:handback                                                  # auto-summary + diff + commits
/tangent:handback wrapped up the auth refactor; PR is ready        # adds a free-form note
/tangent:handback decided NOT to migrate to passport — see commits # ditto
```

## See also

- `/tangent:new`, `/tangent:summary`, `/tangent:full` — spawn tangents.
- `/tangent:prune` — clean up tangent worktrees after handback.
