# tangent (GHCP + Windows fork)

> Spawn isolated [GitHub Copilot CLI][gh-cli] sessions for side tasks —
> each in its own **git worktree** and its own **Windows Terminal tab**,
> with optional context handoff from your current chat.
>
> Windows-only fork of [JohnLangford/tangent][upstream]. The upstream is
> bash + tmux + Claude Code. This fork is **PowerShell + Windows
> Terminal + GHCP CLI**, packaged as a Copilot CLI plugin that
> registers a real `/tangent:new` slash command.

[gh-cli]: https://docs.github.com/en/copilot/how-tos/use-copilot-agents/use-copilot-cli
[upstream]: https://github.com/JohnLangford/tangent

---

## Why

You're mid-task in a Copilot session. A side investigation comes up.
You don't want to derail your main thread, blow your context window, or
risk corrupting your working tree. `/tangent:new` spins up an isolated
session in a fresh worktree + WT tab in one command — optionally
inheriting a summary (or the entire transcript) of the parent chat as
seed context.

## Prerequisites

| Requirement | Version | Why | Install |
|---|---|---|---|
| Windows | 10 / 11 | Plugin uses `wt.exe` and WMI parent-process probing | — |
| [PowerShell][pwsh] | **7.0+** | Engine uses `??`, `-AsHashtable`, `Get-CimInstance`, ternary | `winget install Microsoft.PowerShell` |
| [Windows Terminal][wt] | any recent | Each tangent gets a new tab via `wt.exe new-tab` | `winget install Microsoft.WindowsTerminal` |
| [git][git] | 2.20+ (worktree v2) | `git worktree add`, `git stash`, `git rev-parse` | `winget install Git.Git` |
| [GitHub Copilot CLI][gh-cli] | any | The thing tangent spawns | `npm install -g @github/copilot` |
| Pester (dev only) | 5.0+ | Running the test suite | `Install-Module Pester -Scope CurrentUser` |
| BurntToast (optional) | any | Windows toast on Stop hook (bell still fires without it) | `Install-Module BurntToast -Scope CurrentUser` |

A wrapper around `copilot` (e.g. `agency.exe copilot`) works too — see
*Launcher resolution* below.

[pwsh]: https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-windows
[wt]: https://learn.microsoft.com/windows/terminal/install
[git]: https://git-scm.com/download/win

## Quick start

### Install (from this repo)

```powershell
copilot plugin install shayben/tangent-ghcp
```

### Or run from a local checkout (no install)

```powershell
copilot --plugin-dir C:\path\to\tangent-ghcp
```

### Use it

Three flavors, one per **context-handoff mode**:

| Command | Context handoff | When to use |
|---|---|---|
| `/tangent:summary <prompt>` | Agent-written summary of this chat | **Most common.** Hand off a side task with just enough context to be productive. |
| `/tangent:new <prompt>` | None — blank session | When the side task is unrelated and you want a clean slate. |
| `/tangent:full <prompt>` | Entire transcript via `/share` | When you literally want to fork the whole conversation. ⚠ Can blow the spawned session's context window on long chats. |
| `/tangent:prune` | n/a — destructive (with guardrails) | Inventory + cleanup. Defaults to an interactive menu of worktrees; supports `--merged`/`--pushed`/`--orphaned`/`--all` fast paths and `--branch=<name>` for targeted drops. |

Inside any Copilot CLI session, in any git repo:

```text
/tangent:summary refactor the JWT middleware to use jose v5
```

That spawns a new Windows Terminal tab running `copilot` in a fresh
worktree on a new branch (`tangent/refactor-jwt-middleware`), seeded
with a summary of your current conversation.

## Cheat sheet

All three commands share the same argument grammar — only the context
handoff differs:

```text
/tangent:<new|summary|full> [branch] [--launcher=<cmd>] [--no-prompt] [--ignore-dirty] [prompt...]
```

| Flag | Default | Meaning |
|---|---|---|
| `<branch>` | auto-named from prompt | Explicit branch name (e.g. `fix-auth`). Auto-generates `tangent/<slug>` when omitted; collisions get `-2`, `-3`, … suffixes. |
| `--launcher="<cmd>"` | autodetect | Override the Copilot launcher for this invocation only. See *Launcher resolution* below. |
| `--no-prompt` | — | Resume mode — re-attach to the previously-spawned session for `<branch>` without sending a new prompt. |
| `--ignore-dirty` | — | Skip the dirty-tree pre-flight menu. |

### Examples

```text
/tangent:summary refactor the JWT middleware to use jose v5
/tangent:summary fix-auth-bug refactor the JWT middleware
/tangent:full    fix-auth-bug continue this work in isolation
/tangent:new     fix-auth-bug start fresh, ignore parent context
/tangent:summary fix-auth-bug --no-prompt          # resume previously-spawned session
/tangent:new     --launcher="agency.exe copilot" demo-x test the wrapper
```

> **Why the colon.** Copilot CLI namespaces every plugin command as
> `/<plugin>:<command>`, so each file in `commands/` becomes a distinct
> verb — here, the **mode is the verb**, not a flag. Resuming a session
> works through the underlying Copilot CLI session manager (e.g.
> `copilot --resume=<branch>` or just `--no-prompt` here), not through a
> separate `/tangent:resume` command.

## Dirty working tree pre-flight

`git worktree add … HEAD` clones from HEAD, so any uncommitted edits in
your source workspace **stay there** — the tangent won't see them. When
the source workspace is dirty, the command asks:

```text
You have uncommitted changes in the current workspace. The tangent
will branch from HEAD and won't include them. Choose:
  1) commit  — commit them now (you'll be asked for a message)
  2) stash   — `git stash push -u` (you can `git stash pop` later)
  3) include — stash + apply inside the new worktree (carries edits in)
  4) ignore  — proceed; tangent starts from HEAD without your local edits
  5) cancel
```

The most useful option is **`include`** — your in-progress edits are
stashed and re-applied inside the new worktree, so the side task
literally builds on top of your unfinished work.

Skip the menu with `--ignore-dirty`.

## Launcher resolution

If you launch `copilot` via a wrapper (e.g. `agency.exe copilot`),
tangent figures out the right command in this order (highest first):

1. `--launcher="<cmd>"` flag on the command
2. `$env:TANGENT_COPILOT_CMD` (e.g. `"agency.exe copilot"`)
3. `~/.copilot/tangent/config.json` → `copilotCommand` (string or array)
4. **Auto-detect**: walks the parent process chain looking for
   `agency.exe` (or whatever `$env:TANGENT_LAUNCHER_HINT` says); if
   found, uses `<that-exe-path> copilot`.
5. Bare `copilot` (assumed on PATH).

Sample config — copy `config\config.example.json` to
`~\.copilot\tangent\config.json` and edit:

```json
{
  "copilotCommand": "agency.exe copilot",
  "worktreeRoot": "D:\\worktrees",
  "autodetectLauncher": true,
  "launcherHint": "agency.exe"
}
```

The chosen launcher is logged to stdout and recorded in
`~/.copilot/tangent/state.json` so you can see what got used.

## Windows Terminal companion

`windows\windows-terminal.jsonc` documents an optional WT profile +
key binding (Ctrl+Shift+T) for spawning tangents directly from the
terminal — useful when you're not currently inside a Copilot session.
Merge the relevant fragments into your own `settings.json`.

## Parity with upstream

| Upstream (bash + tmux + Claude Code) | This fork (plugin + WT + Copilot CLI) | Status |
|---|---|---|
| `tangent <branch> "<prompt>"` from shell | `/tangent:{new,summary,full}` from inside copilot OR `tangent.ps1` from any pwsh | ✅ both paths |
| Branch always required | Branch optional — auto-named from prompt | ✅ extended |
| `claude --dangerously-skip-permissions` | `<launcher> --allow-all-tools -n <branch>` | ✅ 1:1 |
| `claude --continue` | `<launcher> --resume=<branch>` | ✅ better |
| `git worktree add … HEAD` | identical, plus dirty-tree pre-flight + `include` mode | ✅ extended |
| tmux pane, column-balanced layout | one **WT tab** per tangent (no pane mgmt) | ⚠️ tabs only |
| sticky `@label` | `wt.exe new-tab --title "🌿 <branch>"` | ⚠️ partial |
| "already running? → focus" | sidecar state + best-effort `wt.exe focus-tab` | ⚠️ best-effort |
| tmux bell on completion | plugin `hooks.json` Stop hook → bell + toast | ✅ via hooks |
| Distribution | `copilot plugin install` + `--plugin-dir` for dev | ✅ one-line |
| `--mode=new\|summary\|full` (default `summary`) | three slash commands, mode is the verb: `/tangent:new`, `/tangent:summary`, `/tangent:full` | ✅ new feature |

If you want the original Unix flow, use the [upstream repo][upstream]
unchanged — this fork doesn't ship the bash script or `tmux.conf`.

## Handback (tangent → parent context return)

When you spawn a tangent it inherits a link back to the parent session
(captured at fork time as env vars `TANGENT_PARENT_SESSION`,
`TANGENT_PARENT_DIR`, `TANGENT_INTERACTION_ID`, `TANGENT_PARENT_BRANCH`,
plus an allow-listed entry in `<parent-session>/files/tangent-handback/allowed/`).

When you're done, run **`/tangent:handback [optional message]`** inside the
tangent. The helper composes a markdown digest (summary + git diff list +
commits + your message), XML-escapes the body, wraps it in
`<tangent-handback trust="untrusted">…</tangent-handback>`, and atomically
publishes a JSON file into the parent's session directory at
`<parent>/files/tangent-handback/inbox/`.

The parent's `UserPromptSubmit` hook (registered by this plugin) reads the
inbox on the next user prompt, surfaces up to 3 handbacks per turn (capped at
24 KB total), and archives them to `read/`. Your parent model sees a banner
+ the wrapped block as situational context, treated as data.

**Caveats / honest threat model**

- **Best-effort delivery.** The `UserPromptSubmit` hook only fires in parent
  sessions that loaded this plugin **at session start** (after install). If
  it doesn't fire, the JSON still sits in the inbox dir; you can `cat` it
  manually.
- **No git operations.** Handback is context only — it never pushes, merges,
  or modifies files in the parent worktree. If you want a merge, do
  `git -C <parent-worktree> merge tangent/<branch>` yourself.
- **No defense vs malicious local code.** The `parent_session_id` and
  `interaction_id` checks defend against accidental misroute (e.g. two
  parents on the same machine), not against same-user code that can read
  the allowlist directly.
- **Caps.** Body capped at 8 KB at write time, 16 KB at read time, 24 KB
  total per turn, 3 handbacks per turn. Excess defers to the next prompt.

```
/tangent:handback                                                 # auto-summary only
/tangent:handback wrapped up the auth refactor; PR is ready       # + free-form note
/tangent:handback decided NOT to migrate — see commits for why    # ditto
```

## Repo layout

```text
.claude-plugin/
  plugin.json              # plugin manifest
commands/
  new.md                   # /tangent:new      — no context handoff
  summary.md               # /tangent:summary  — concise context summary
  full.md                  # /tangent:full     — entire parent transcript
  prune.md                 # /tangent:prune    — interactive cleanup menu (+ bucket / targeted modes)
hooks/
  hooks.json               # Stop event → bell + toast + cleanup hint (gated on $env:TANGENT_SESSION)
scripts/
  tangent.ps1              # engine — worktree, state, wt.exe, copilot launch
  tangent-launch.ps1       # thin shim invoked by /tangent:* commands
  tangent-prune.ps1        # `/tangent:prune` implementation
  TangentLauncher.psm1     # launcher resolution + config loading
  TangentInventory.psm1    # worktree discovery + status classification
windows/
  windows-terminal.jsonc   # optional WT profile + Ctrl+Shift+T binding
config/
  config.example.json      # documented template
tests/
  tangent.Tests.ps1        # Pester smoke tests
```

## Development

```powershell
# Run the test suite
Invoke-Pester -Path tests/tangent.Tests.ps1 -Output Detailed

# Try the plugin without installing it
copilot --plugin-dir C:\Repos\tangent-ghcp

# Run the engine directly (no copilot involvement)
.\scripts\tangent.ps1 -Branch tangent/foo -Mode new -Prompt "hello world"
```

## License

MIT (carried over from upstream). See [LICENSE](./LICENSE).
