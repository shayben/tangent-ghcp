---
description: Drop tangent worktrees safely — defaults to an interactive menu where you pick which worktree to prune
argument-hint: "[--merged] [--pushed] [--orphaned] [--all] [--branch=<name>...] [--dry-run] [--fetch] [--json]"
---

# /tangent:prune

Clean up tangent worktrees with strong safety guardrails:
- Always uses `git worktree remove` (refuses if dirty / locked)
- Branch deletion only via `git branch -d` (refuses if unmerged)
- Refuses to touch a worktree unless it's under the tangent root **and** has a
  `.tangent/launch.ps1` marker (so user-created `tangent/foo` branches outside
  the worktree root are never disturbed)
- Never touches `broken` worktrees
- Never touches the worktree the user is currently in

## Mode selection

The mode is chosen by the **first argument** the user passes:

| User invocation | Mode |
| --- | --- |
| `/tangent:prune` (no args) | **Interactive menu** — you build a single-select `ask_user` from the live inventory and let the user pick. **This is the default.** |
| `/tangent:prune --merged` / `--pushed` / `--orphaned` / `--all` | Bucket fast path — dry-run, confirm, execute. |
| `/tangent:prune --branch=<name>` (repeatable) | Targeted — drop these specific branches regardless of status. |

`--dry-run`, `--fetch`, `--json` work in any mode.

## Resolve the plugin scripts

```powershell
$plugin = if ($env:CLAUDE_PLUGIN_ROOT) {
    $env:CLAUDE_PLUGIN_ROOT
} else {
    (Get-ChildItem "$env:USERPROFILE\.copilot\installed-plugins" -Recurse `
        -Filter tangent-prune.ps1 -EA SilentlyContinue | Select-Object -First 1).Directory.Parent.FullName
}
$pruneScript = Join-Path $plugin 'scripts\tangent-prune.ps1'
$invModule   = Join-Path $plugin 'scripts\TangentInventory.psm1'
```

## Procedure — interactive menu (default; no flags passed)

### Step 1 — Get the menu payload (deterministic)

```powershell
$menu = & $pruneScript -Menu | ConvertFrom-Json
```

If `$menu.empty -eq $true` → respond with `$menu.question` (already formatted as
"🌿 No tangent worktrees…") and stop.

### Step 2 — Surface the menu

Pass straight through to `ask_user` (`allow_freeform: false`):
- `question` = `$menu.question`
- `choices`  = `$menu.choices.label` (the script already sorted, formatted icons,
  bucket shortcuts, and the cancel entry)

Find the picked entry by label match:
```powershell
$pick = $menu.choices | Where-Object { $_.label -eq $userChoice }
```

### Step 3 — Map `$pick.token` to a script invocation

| `$pick.token` | Run |
| --- | --- |
| `__cancel__` | respond "Cancelled." and stop |
| `__all_cleanable__` | `& $pruneScript -All -DryRun` |
| `__all_merged__` | `& $pruneScript -Merged -DryRun` |
| any other (a branch name) | `& $pruneScript -Branch $pick.token -DryRun` |

### Step 4 — Confirm + execute

Print the dry-run report (the script formats it for you).

**If `$pick.dirty -eq $true`** (single-worktree pick), don't just ask "Proceed?" —
`git worktree remove` will refuse. Ask the user how to handle the uncommitted
changes first:

```
ask_user (allow_freeform: false):
  question: "<branch> has uncommitted changes. How should I handle them before pruning?"
  choices:
    - "Commit them (you'll provide a message)"
    - "Stash them (git stash push -u; you can pop later)"
    - "Discard them (force prune; changes are LOST)"
    - "Cancel"
```

Map to `-OnDirty` (the script does the git work for you):

| Choice | Run |
| --- | --- |
| Commit | `ask_user` for a message → `& $pruneScript -Branch '<b>' -OnDirty commit -CommitMessage '<msg>'` |
| Stash  | `& $pruneScript -Branch '<b>' -OnDirty stash` |
| Discard | `& $pruneScript -Branch '<b>' -OnDirty discard` |
| Cancel | respond "Cancelled." and stop |

**If `$pick.dirty` is false**, the standard confirm is enough:
```
ask_user: "Proceed with the actions above?"  choices: ["Yes", "No"]
```
On `Yes`, re-run the same command **without** `-DryRun` and surface the report.

### Step 5 — Loop offer

After a successful prune, re-enumerate; if any worktrees remain, ask:
```
ask_user: "Prune another?"  choices: ["Yes", "No"]
```
On `Yes` → go back to Step 2. On `No` → done.

## Procedure — bucket fast path (`--merged` / `--pushed` / `--orphaned` / `--all`)

1. Dry-run: `& $pruneScript -DryRun <flag>`
2. If ≥1 selected item → `ask_user` "Proceed?" → on `Yes`, re-run without `-DryRun`.
3. Surface the report.

## Procedure — targeted (`--branch=<name>`)

```powershell
& $pruneScript -Branch 'tangent/foo','tangent/bar' -DryRun
```
Confirm via `ask_user`, then re-run without `-DryRun`. **If any named branch
is dirty**, use the same dirty-handling sub-procedure as in Step 4 above
(commit / stash / discard / cancel), passing the user's choice via
`-OnDirty {commit|stash|discard}` (and `-CommitMessage` for commit).

## Skip the upfront confirm when…

- The user explicitly passed `--dry-run` (they only want the preview).
- In the interactive-menu loop, the menu pick + dry-run preview already imply intent; the post-dry-run `ask_user "Proceed?"` is the one and only confirmation.

## Examples

```
/tangent:prune                                    # ← interactive menu (default)
/tangent:prune --merged                           # bucket fast path: merged only
/tangent:prune --all --dry-run                    # preview the maximum sweep, no action
/tangent:prune --branch=tangent/spike-graphql     # targeted (any status)
/tangent:prune --branch=tangent/a --branch=tangent/b   # multi-targeted
```
