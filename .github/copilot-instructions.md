# Copilot instructions — tangent-ghcp

Windows-only Copilot CLI plugin (PowerShell 7+) that spawns isolated Copilot
sessions in git worktrees + Windows Terminal tabs. Read `README.md` for the
user-facing surface; this file documents the *implementation* invariants you
need before changing code.

## Test / lint / run

```powershell
# Full suite (Pester 5+, ~30s, currently 72 tests)
Invoke-Pester -Path tests/tangent.Tests.ps1 -Output Minimal

# Single Describe / It (Pester filters)
Invoke-Pester -Path tests/tangent.Tests.ps1 -Output Detailed `
    -FullNameFilter '*deterministic wrapper*'

# Run the engine without a Copilot session (smoke test)
.\scripts\tangent.ps1 -Branch tangent/foo -Mode new -Prompt "hello"

# Try the plugin from a working tree without installing
copilot --plugin-dir C:\Repos\tangent-ghcp
```

There is no linter or build step. PowerShell scripts must run under
`pwsh -NoProfile` (parsed in CI-equivalent shell).

## After editing scripts/* or commands/* — sync to live install

Slash commands resolve through the **installed** plugin path, not the repo:

```powershell
$dst = "$env:USERPROFILE\.copilot\installed-plugins\_direct\shayben--tangent-ghcp"
Copy-Item .\scripts\<changed>.ps1   (Join-Path $dst 'scripts')   -Force
Copy-Item .\commands\<changed>.md   (Join-Path $dst 'commands')  -Force
```

Without this, `/tangent:*` invocations from a live Copilot session won't see
your edits.

## Architecture in one read

```
commands/<verb>.md   ──►  scripts/tangent-spawn.ps1   ──►  scripts/tangent.ps1   ──►  wt.exe new-tab → copilot
  (slash command)         (deterministic wrapper)         (engine: worktree,         (spawned tangent)
                                                           state, launcher)
```

- **commands/<verb>.md** are slash-command bodies. They are model-mediated
  (the model reads them and acts), so each one is collapsed to a *single*
  deterministic dispatch: resolve wrapper path → invoke wrapper with
  `$ARGUMENTS` verbatim → print stdout verbatim. The model adds no parsing
  or interpretation. Treat the **1-turn / 0-reasoning** floor as a hard
  design constraint when changing these files.
- **scripts/tangent-spawn.ps1** is the deterministic wrapper for
  `/tangent:new`, `/tangent:summary`, `/tangent:full`. Selected via
  `-Mode {new|summary|full}`. Owns argument parsing, branch auto-naming,
  dirty pre-flight, summary staging, engine dispatch, and the final
  user-facing report. Has a `-DryRun` mode that emits the parsed plan as
  one JSON line (used by tests).
- **scripts/tangent.ps1** is the engine. Creates the worktree
  (`git worktree add`), creates `<worktree>\.tangent\` with `launch.ps1`,
  resumes a session via `copilot --resume=<id>` when one exists, and
  spawns the WT tab. For `-Mode full`, also clones the parent session
  folder via `tangent-clone-session.ps1` so the spawned tangent inherits
  full event/tool fidelity.
- **scripts/tangent-handback.ps1** runs *inside* the tangent session. It
  reads `TANGENT_PARENT_SESSION` / `TANGENT_PARENT_DIR` /
  `TANGENT_INTERACTION_ID` env vars (set by the engine at fork), composes
  a digest, and atomically publishes a JSON blob into the parent's
  `files/tangent-handback/inbox/`. The parent's `UserPromptSubmit` hook
  (`hooks/hooks.json` → `tangent-inbox-ingest.ps1`) ingests them on the
  next turn. Delivery is **context only** — no git operations.
- **scripts/tangent-prune.ps1** + `TangentInventory.psm1` handle worktree
  cleanup. Two interaction modes: `-Menu` emits a JSON menu payload for
  the slash command to render via `ask_user`; `-OnDirty {commit|stash|discard}`
  + `-CommitMessage` carry the user's choice deterministically. Refuses
  to touch worktrees that aren't under the tangent root or lack a
  `.tangent\launch.ps1` marker.

## Conventions specific to this codebase

- **`-DryRun` returns one JSON line** for any wrapper that has it
  (`tangent-spawn.ps1`, `tangent-prune.ps1`). Tests parse that JSON. Add
  fields rather than restructuring; never split into multi-line output.
- **Branch slugs are auto-namespaced** under `tangent/`. The wrapper
  prefixes `tangent/` if absent. Inventory + prune logic only consider
  branches matching `^tangent/`; bare branch names like `test-handback`
  are invisible to prune (this is intentional — see *Honest threat model*
  in README).
- **Branch-from-prompt heuristic.** `tangent-spawn.ps1` treats the first
  positional token as a branch slug **only** if it contains
  `[\-/._0-9]` or starts with `tangent/`. Pure alphabetic words like
  `fix`, `implement`, `try` are part of the prompt — this prevents
  verb-led prompts from being hijacked. Don't relax this without a test.
- **Branch resolution priority** (in `tangent-spawn.ps1`):
  positional token → `-AutoName <slug>` (caller-derived) → kebab words
  from prompt → random `task-<short-guid>`. The slash-command MD passes
  `-AutoName` when `$ARGUMENTS` is empty so parameterless invocations get
  contextual names.
- **Default dirty-tree handling is `--include`** (carry edits into the
  spawned worktree). Other modes: `--stash`, `--commit="<msg>"`,
  `--ignore-dirty`. Decision was deliberate to favour workflow continuity.
- **`agency.exe copilot` wrapper bypass.** The engine detects when the
  autodetected launcher is the `agency.exe copilot` wrapper and rewrites
  to bare `copilot.exe`, because `agency.exe` unconditionally injects
  `--resume <agency-session-id>` which collides with `-n <branch>` for
  fresh forks. Skip the bypass if the user explicitly chose a launcher.
- **`-Mode full` clones the parent session folder** by GUID.
  `tangent-clone-session.ps1` robocopies the folder, rewrites
  `workspace.yaml`, bulk-replaces the parent GUID in `events.jsonl`, and
  appends a `session.info` fork-marker event. Excludes
  `inuse.*.lock` and `rewind-snapshots/`. The spawned tangent uses
  `copilot --resume=<newId>` (not `-n <branch>`).
- **Pester gotcha.** Functions defined at `Describe`-level are not
  visible inside `It` blocks. Put helpers inside `BeforeAll` and define
  them as `function global:Foo {...}` (then clean up in `AfterAll`).
- **Git commit trailer is enforced** for any commit you make:
  `Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>`.
  Use a here-string for the message body (single-quoted backslashes have
  bitten parsers in this repo before).
- **Two installation paths**, intentionally distinct:
  - `~\.copilot\installed-plugins\_direct\shayben--tangent-ghcp\` — the
    live install Copilot resolves slash commands through. Sync after
    every script/command edit (see above).
  - `~\.copilot\tangent\` — runtime state (`config.json`, `state.json`,
    last-used launcher, etc.). Engine reads + writes here.
- **Worktree default root** is `%LOCALAPPDATA%\tangent\worktrees`,
  overridable via `$env:WORKTREE_ROOT` or `config.json` →
  `worktreeRoot`.

## When in doubt

- Read `commands/full.md` as the canonical example of a deterministic
  slash command. `new.md` and `summary.md` mirror its shape.
- Read `tests/tangent.Tests.ps1` `Describe 'tangent-spawn.ps1
  deterministic wrapper'` for the full set of contracts the wrapper
  honours.
