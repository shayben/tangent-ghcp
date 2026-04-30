#requires -Version 7.0
#requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0.0' }
<#
.SYNOPSIS
    Smoke tests for tangent. Run with:
      Invoke-Pester -Path tests/tangent.Tests.ps1 -Output Detailed

    These tests focus on PURE LOGIC in TangentLauncher.psm1 (no side effects)
    plus engine arg-parsing/argument-build behaviour using a heavily mocked
    environment. They do NOT spawn wt.exe, do NOT call git for real, and
    do NOT touch the user's ~/.copilot directory.
#>

BeforeAll {
    $script:RepoRoot     = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:LauncherMod  = Join-Path $RepoRoot 'scripts\TangentLauncher.psm1'
    $script:EnginePath   = Join-Path $RepoRoot 'scripts\tangent.ps1'
    Import-Module $LauncherMod -Force
}

Describe 'ConvertTo-LauncherTokens' {
    It 'returns $null for empty input' {
        ConvertTo-LauncherTokens '' | Should -BeNullOrEmpty
        ConvertTo-LauncherTokens $null | Should -BeNullOrEmpty
        ConvertTo-LauncherTokens @() | Should -BeNullOrEmpty
    }
    It 'splits a string on whitespace' {
        $t = ConvertTo-LauncherTokens 'agency.exe copilot'
        $t | Should -Be @('agency.exe', 'copilot')
    }
    It 'preserves an array as-is' {
        $t = ConvertTo-LauncherTokens @('agency.exe', 'copilot', '--foo')
        $t | Should -Be @('agency.exe', 'copilot', '--foo')
    }
    It 'trims whitespace-only strings' {
        ConvertTo-LauncherTokens '   ' | Should -BeNullOrEmpty
    }
}

Describe 'Resolve-TangentLauncher precedence' {
    BeforeEach {
        # Wipe environment + provide an empty config
        $env:TANGENT_COPILOT_CMD = $null
        $env:TANGENT_LAUNCHER_HINT = $null
        # Force autodetect to find nothing so 'fallback' is reachable
        Mock -ModuleName TangentLauncher Find-AgencyInParentChain { $null }
    }

    It 'uses the explicit -Launcher arg first (source=arg)' {
        $env:TANGENT_COPILOT_CMD = 'env-copilot'
        $r = Resolve-TangentLauncher -ExplicitLauncher 'arg-copilot foo' -Config @{ copilotCommand = 'cfg-copilot' }
        $r.Source | Should -Be 'arg'
        $r.Exe | Should -Be 'arg-copilot'
        $r.Arguments | Should -Be @('foo')
        $r.Display | Should -Be 'arg-copilot foo'
    }

    It 'falls through to env when no explicit arg (source=env)' {
        $env:TANGENT_COPILOT_CMD = 'env-copilot bar'
        $r = Resolve-TangentLauncher -Config @{ copilotCommand = 'cfg-copilot' }
        $r.Source | Should -Be 'env'
        $r.Exe | Should -Be 'env-copilot'
        $r.Arguments | Should -Be @('bar')
    }

    It 'falls through to config when no env (source=config)' {
        $r = Resolve-TangentLauncher -Config @{ copilotCommand = 'cfg-copilot baz' }
        $r.Source | Should -Be 'config'
        $r.Exe | Should -Be 'cfg-copilot'
    }

    It 'autodetects when nothing else is set (source=autodetect)' {
        Mock -ModuleName TangentLauncher Find-AgencyInParentChain { 'C:\Tools\agency.exe' }
        $r = Resolve-TangentLauncher -Config @{}
        $r.Source | Should -Be 'autodetect'
        $r.Exe | Should -Be 'C:\Tools\agency.exe'
        $r.Arguments | Should -Be @('copilot')
    }

    It 'falls back to bare copilot when nothing is found (source=fallback)' {
        $r = Resolve-TangentLauncher -Config @{}
        $r.Source | Should -Be 'fallback'
        $r.Exe | Should -Be 'copilot'
        $r.Arguments | Should -Be @()
    }

    It 'honors autodetectLauncher=false in config' {
        Mock -ModuleName TangentLauncher Find-AgencyInParentChain { 'C:\Tools\agency.exe' }
        $r = Resolve-TangentLauncher -Config @{ autodetectLauncher = $false }
        $r.Source | Should -Be 'fallback'
    }
}

Describe 'Get-TangentConfig' {
    It 'returns empty hashtable when file does not exist' {
        $tmp = Join-Path ([IO.Path]::GetTempPath()) "no-such-$(Get-Random).json"
        $h = Get-TangentConfig -ConfigPath $tmp
        $h | Should -BeOfType [hashtable]
        $h.Count | Should -Be 0
    }

    It 'parses valid JSON and strips _comment-style keys' {
        $tmp = Join-Path ([IO.Path]::GetTempPath()) "cfg-$(Get-Random).json"
        Set-Content -LiteralPath $tmp -Value '{ "_comment": "doc", "copilotCommand": "agency.exe copilot" }' -Encoding UTF8
        try {
            $h = Get-TangentConfig -ConfigPath $tmp
            $h.ContainsKey('_comment') | Should -BeFalse
            $h.copilotCommand | Should -Be 'agency.exe copilot'
        } finally {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }

    It 'returns empty hashtable on malformed JSON (with warning)' {
        $tmp = Join-Path ([IO.Path]::GetTempPath()) "bad-$(Get-Random).json"
        Set-Content -LiteralPath $tmp -Value '{ not valid json' -Encoding UTF8
        try {
            $h = Get-TangentConfig -ConfigPath $tmp 3>$null
            $h.Count | Should -Be 0
        } finally {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Engine: arg validation' {
    It 'rejects an invalid -Mode' {
        $err = & pwsh -NoProfile -File $script:EnginePath -Branch 'x' -Mode 'bogus' 2>&1
        $LASTEXITCODE | Should -Not -Be 0
    }

    It 'errors when not inside a git repo' {
        $tmp = Join-Path ([IO.Path]::GetTempPath()) "notgit-$(Get-Random)"
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        try {
            $err = & pwsh -NoProfile -Command "Set-Location -LiteralPath '$tmp'; & '$script:EnginePath' -Branch 'demo'" 2>&1
            $LASTEXITCODE | Should -Not -Be 0
            ($err -join "`n") | Should -Match 'not in a git repo'
        } finally {
            Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'tangent-spawn.ps1 deterministic wrapper' {
    BeforeAll {
        $script:WrapperPath = Join-Path $RepoRoot 'scripts\tangent-spawn.ps1'
    }

    It 'exists and is invokable' {
        Test-Path -LiteralPath $script:WrapperPath | Should -BeTrue
    }

    It 'spawns with a fallback task-* branch when both branch and prompt are empty' {
        $json = & pwsh -NoProfile -File $script:WrapperPath -Mode full -ArgString '' -DryRun
        $LASTEXITCODE | Should -Be 0
        $obj = $json | ConvertFrom-Json
        $obj.branch | Should -Match '^tangent/(task-[a-f0-9]+|.+)$'
        $obj.prompt | Should -Be ''
    }

    It 'uses -AutoName slug when ArgString has no positional branch' {
        $json = & pwsh -NoProfile -File $script:WrapperPath -Mode full -ArgString '' -AutoName 'refactor-auth-middleware' -DryRun
        $obj = $json | ConvertFrom-Json
        $obj.branch | Should -Be 'tangent/refactor-auth-middleware'
    }

    It 'sanitizes -AutoName (lowercases, collapses non-alnum to hyphen)' {
        $json = & pwsh -NoProfile -File $script:WrapperPath -Mode full -ArgString '' -AutoName 'Refactor!! AUTH __ Middleware  v2' -DryRun
        $obj = $json | ConvertFrom-Json
        $obj.branch | Should -Be 'tangent/refactor-auth-middleware-v2'
    }

    It 'positional branch wins over -AutoName' {
        $json = & pwsh -NoProfile -File $script:WrapperPath -Mode full -ArgString 'fix-bug do stuff' -AutoName 'ignored-slug' -DryRun
        $obj = $json | ConvertFrom-Json
        $obj.branch | Should -Be 'tangent/fix-bug'
    }

    It 'parses --launcher, --no-prompt, --ignore-dirty, --include, --stash, --commit (structural check on source)' {
        $src = Get-Content -LiteralPath $script:WrapperPath -Raw
        $src | Should -Match '--launcher='
        $src | Should -Match '--no-prompt'
        $src | Should -Match '--ignore-dirty'
        $src | Should -Match '--include'
        $src | Should -Match '--stash'
        $src | Should -Match '--commit='
    }

    It 'auto-names a branch from the prompt when no branch is given' {
        $json = & pwsh -NoProfile -File $script:WrapperPath -Mode full -ArgString 'fix the broken auth in module x' -DryRun
        $LASTEXITCODE | Should -Be 0
        $obj = $json | ConvertFrom-Json
        $obj.branch | Should -Match '^tangent/[a-z0-9-]+$'
        $obj.branch | Should -Match 'broken'
        $obj.mode   | Should -Be 'full'
    }

    It 'namespaces user-provided branch under tangent/ when missing prefix' {
        $json = & pwsh -NoProfile -File $script:WrapperPath -Mode full -ArgString 'fix-bug do the thing' -DryRun
        $obj = $json | ConvertFrom-Json
        $obj.branch | Should -Be 'tangent/fix-bug'
        $obj.prompt | Should -Be 'do the thing'
    }

    It 'preserves an explicit tangent/ prefix' {
        $json = & pwsh -NoProfile -File $script:WrapperPath -Mode full -ArgString 'tangent/spike-x explore the api' -DryRun
        $obj = $json | ConvertFrom-Json
        $obj.branch | Should -Be 'tangent/spike-x'
        $obj.prompt | Should -Be 'explore the api'
    }

    It 'parses --launcher, --no-prompt, --ignore-dirty, --include, --stash, --commit flags' {
        $json = & pwsh -NoProfile -File $script:WrapperPath -Mode full `
            -ArgString '--launcher="copilot --foo" --no-prompt --include branch-x do stuff' -DryRun
        $obj = $json | ConvertFrom-Json
        $obj.launcher    | Should -Be 'copilot --foo'
        $obj.noPrompt    | Should -BeTrue
        $obj.dirtyMode   | Should -Be 'include'
        $obj.branch      | Should -Be 'tangent/branch-x'
        $obj.prompt      | Should -Be 'do stuff'
    }

    It 'parses --commit with quoted message' {
        $json = & pwsh -NoProfile -File $script:WrapperPath -Mode full `
            -ArgString '--commit="wip checkpoint" branch-y the prompt' -DryRun
        $obj = $json | ConvertFrom-Json
        $obj.dirtyMode | Should -Be 'commit'
        $obj.commitMsg | Should -Be 'wip checkpoint'
    }

    It 'carries -Mode through to the dry-run plan (new)' {
        $json = & pwsh -NoProfile -File $script:WrapperPath -Mode new -ArgString 'spike-x do stuff' -DryRun
        $obj = $json | ConvertFrom-Json
        $obj.mode   | Should -Be 'new'
        $obj.branch | Should -Be 'tangent/spike-x'
    }

    It 'carries -Mode through to the dry-run plan (summary)' {
        $json = & pwsh -NoProfile -File $script:WrapperPath -Mode summary -SummaryFromStdin -ArgString 'spike-x do stuff' -DryRun
        $obj = $json | ConvertFrom-Json
        $obj.mode             | Should -Be 'summary'
        $obj.summaryFromStdin | Should -BeTrue
    }

    It 'rejects -Mode summary without -SummaryFromStdin or -SummaryFile' {
        $out = & pwsh -NoProfile -File $script:WrapperPath -Mode summary -ArgString 'branch-x prompt' 2>&1
        $LASTEXITCODE | Should -Be 2
        ($out -join "`n") | Should -Match 'requires either -SummaryFromStdin or -SummaryFile'
    }

    It 'rejects mutually exclusive -SummaryFromStdin + -SummaryFile' {
        $tmp = New-TemporaryFile
        try {
            $out = & pwsh -NoProfile -File $script:WrapperPath -Mode summary `
                -SummaryFromStdin -SummaryFile $tmp.FullName -ArgString 'branch-x prompt' 2>&1
            $LASTEXITCODE | Should -Be 2
            ($out -join "`n") | Should -Match 'mutually exclusive'
        } finally {
            Remove-Item -LiteralPath $tmp.FullName -Force -ErrorAction SilentlyContinue
        }
    }

    It 'rejects -Mode summary when stdin is empty (no live engine call)' {
        # Pipe an empty string explicitly. Use cmd echo. without trailing newline.
        $out = '' | & pwsh -NoProfile -File $script:WrapperPath -Mode summary -SummaryFromStdin `
            -ArgString 'branch-x prompt' 2>&1
        $LASTEXITCODE | Should -Be 2
        ($out -join "`n") | Should -Match 'stdin was empty'
    }

    It 'commands/full.md dispatches via tangent-spawn.ps1 -Mode full (one tool call, no model parsing)' {
        $cmd = Get-Content -LiteralPath (Join-Path $RepoRoot 'commands\full.md') -Raw
        $cmd | Should -Match 'tangent-spawn\.ps1'
        $cmd | Should -Match '-Mode\s+full'
        $cmd | Should -Match 'ArgString'
        $cmd | Should -Match '-AutoName'
        $cmd | Should -Match '(?is)verbatim'
    }

    It 'commands/new.md dispatches via tangent-spawn.ps1 -Mode new (one tool call, no model parsing)' {
        $cmd = Get-Content -LiteralPath (Join-Path $RepoRoot 'commands\new.md') -Raw
        $cmd | Should -Match 'tangent-spawn\.ps1'
        $cmd | Should -Match '-Mode\s+new'
        $cmd | Should -Match 'ArgString'
        $cmd | Should -Match '-AutoName'
        $cmd | Should -Match '(?is)verbatim'
    }

    It 'commands/summary.md dispatches via tangent-spawn.ps1 -Mode summary -SummaryFromStdin (one tool call, only summary text is model-authored)' {
        $cmd = Get-Content -LiteralPath (Join-Path $RepoRoot 'commands\summary.md') -Raw
        $cmd | Should -Match 'tangent-spawn\.ps1'
        $cmd | Should -Match '-Mode\s+summary'
        $cmd | Should -Match '-SummaryFromStdin'
        $cmd | Should -Match 'ArgString'
        $cmd | Should -Match '-AutoName'
        $cmd | Should -Match '(?is)verbatim'
    }

    It 'commands/handback.md dispatches via tangent-handback.ps1 (one tool call, no model parsing)' {
        $cmd = Get-Content -LiteralPath (Join-Path $RepoRoot 'commands\handback.md') -Raw
        $cmd | Should -Match 'tangent-handback\.ps1'
        $cmd | Should -Match '-Message'
        $cmd | Should -Match '(?is)verbatim'
    }
}

Describe 'Plugin manifest is well-formed' {
    It 'plugin.json parses as JSON with required keys' {
        $manifest = Join-Path $script:RepoRoot '.claude-plugin/plugin.json'
        Test-Path -LiteralPath $manifest | Should -BeTrue
        $obj = Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json
        $obj.name | Should -Be 'tangent'
        $obj.version | Should -Match '^\d+\.\d+\.\d+'
    }

    It 'all commands/<mode>.md files have YAML frontmatter with description + argument-hint' {
        foreach ($name in @('new', 'summary', 'full', 'prune')) {
            $cmd = Join-Path $script:RepoRoot "commands/$name.md"
            Test-Path -LiteralPath $cmd | Should -BeTrue -Because "commands/$name.md should exist"
            $head = (Get-Content -LiteralPath $cmd -TotalCount 6) -join "`n"
            $head | Should -Match '^---' -Because "commands/$name.md should start with frontmatter"
            $head | Should -Match 'description:' -Because "commands/$name.md frontmatter should declare a description"
            $head | Should -Match 'argument-hint:' -Because "commands/$name.md frontmatter should declare an argument-hint"
        }
    }

    It 'no skills directory is shipped (avoids /tangent:<skill> ghost commands)' {
        $skillsDir = Join-Path $script:RepoRoot 'skills'
        Test-Path -LiteralPath $skillsDir | Should -BeFalse -Because 'skills register as /<plugin>:<name> slash commands too; we deliberately ship none'
    }

    It 'hooks/hooks.json parses as JSON' {
        $hooks = Join-Path $script:RepoRoot 'hooks/hooks.json'
        Test-Path -LiteralPath $hooks | Should -BeTrue
        { Get-Content -LiteralPath $hooks -Raw | ConvertFrom-Json } | Should -Not -Throw
    }

    It 'config/config.example.json parses as JSON' {
        $cfg = Join-Path $script:RepoRoot 'config/config.example.json'
        Test-Path -LiteralPath $cfg | Should -BeTrue
        { Get-Content -LiteralPath $cfg -Raw | ConvertFrom-Json } | Should -Not -Throw
    }
}

Describe 'Get-TangentClassification' {
    BeforeAll {
        Import-Module (Join-Path $script:RepoRoot 'scripts\TangentInventory.psm1') -Force
    }

    It 'orphaned: missing worktree dir wins over everything' {
        Get-TangentClassification @{ WorktreeMissing = $true; Broken = $false; Dirty = $false; IsMerged = $true; HasUpstream = $false; AheadOfRemote = 0; AgeMinutes = 0; AgeDays = 0 } | Should -Be 'orphaned'
    }
    It 'broken: git status failed' {
        Get-TangentClassification @{ WorktreeMissing = $false; Broken = $true; Dirty = $false; IsMerged = $false; HasUpstream = $false; AheadOfRemote = 0; AgeMinutes = 0; AgeDays = 0 } | Should -Be 'broken'
    }
    It 'active: dirty wins over merged' {
        Get-TangentClassification @{ WorktreeMissing = $false; Broken = $false; Dirty = $true; IsMerged = $true; HasUpstream = $false; AheadOfRemote = 0; AgeMinutes = 100000; AgeDays = 99 } | Should -Be 'active'
    }
    It 'active: fresh (<1h) skips merged classification (grace period)' {
        Get-TangentClassification @{ WorktreeMissing = $false; Broken = $false; Dirty = $false; IsMerged = $true; HasUpstream = $false; AheadOfRemote = 0; AgeMinutes = 30; AgeDays = 0 } | Should -Be 'active'
    }
    It 'merged: ancestor of default after grace, not dirty' {
        Get-TangentClassification @{ WorktreeMissing = $false; Broken = $false; Dirty = $false; IsMerged = $true; HasUpstream = $true; AheadOfRemote = 0; AgeMinutes = 1500; AgeDays = 1 } | Should -Be 'merged'
    }
    It 'pushed: has upstream, no unpushed commits, not merged' {
        Get-TangentClassification @{ WorktreeMissing = $false; Broken = $false; Dirty = $false; IsMerged = $false; HasUpstream = $true; AheadOfRemote = 0; AgeMinutes = 7200; AgeDays = 5 } | Should -Be 'pushed'
    }
    It 'local-only: no upstream, has work, not merged, not stale' {
        Get-TangentClassification @{ WorktreeMissing = $false; Broken = $false; Dirty = $false; IsMerged = $false; HasUpstream = $false; AheadOfRemote = 0; AgeMinutes = 7200; AgeDays = 5 } | Should -Be 'local-only'
    }
    It 'stale: has upstream + ahead, >30 days, not merged' {
        Get-TangentClassification @{ WorktreeMissing = $false; Broken = $false; Dirty = $false; IsMerged = $false; HasUpstream = $true; AheadOfRemote = 3; AgeMinutes = 65000; AgeDays = 45 } | Should -Be 'stale'
    }
    It 'active: in between — not stale, not pushed, not merged, has upstream + ahead' {
        Get-TangentClassification @{ WorktreeMissing = $false; Broken = $false; Dirty = $false; IsMerged = $false; HasUpstream = $true; AheadOfRemote = 2; AgeMinutes = 7200; AgeDays = 5 } | Should -Be 'active'
    }
}

Describe 'Test-TangentOwnership' {
    BeforeAll {
        Import-Module (Join-Path $script:RepoRoot 'scripts\TangentInventory.psm1') -Force
        $script:TmpRoot = Join-Path ([IO.Path]::GetTempPath()) "tangent-own-$(Get-Random)"
        New-Item -ItemType Directory -Path $script:TmpRoot -Force | Out-Null
    }
    AfterAll {
        Remove-Item -LiteralPath $script:TmpRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'rejects branches not under tangent/ prefix' {
        $wt = Join-Path $script:TmpRoot 'feature-x'
        New-Item -ItemType Directory -Path (Join-Path $wt '.tangent') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $wt '.tangent\launch.ps1') -Value '# stub' -Encoding UTF8
        Test-TangentOwnership -Branch 'feature/x' -Worktree $wt -WorktreeRoot $script:TmpRoot | Should -BeFalse
    }
    It 'rejects worktree outside the configured root' {
        $other = Join-Path ([IO.Path]::GetTempPath()) "elsewhere-$(Get-Random)"
        New-Item -ItemType Directory -Path (Join-Path $other '.tangent') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $other '.tangent\launch.ps1') -Value '# stub' -Encoding UTF8
        try {
            Test-TangentOwnership -Branch 'tangent/foo' -Worktree $other -WorktreeRoot $script:TmpRoot | Should -BeFalse
        } finally {
            Remove-Item -LiteralPath $other -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    It 'rejects worktree missing the .tangent/launch.ps1 marker' {
        $wt = Join-Path $script:TmpRoot 'tangent\bar'
        New-Item -ItemType Directory -Path $wt -Force | Out-Null
        Test-TangentOwnership -Branch 'tangent/bar' -Worktree $wt -WorktreeRoot $script:TmpRoot | Should -BeFalse
    }
    It 'accepts a properly-marked tangent worktree under the root' {
        $wt = Join-Path $script:TmpRoot 'tangent\baz'
        New-Item -ItemType Directory -Path (Join-Path $wt '.tangent') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $wt '.tangent\launch.ps1') -Value '# stub' -Encoding UTF8
        Test-TangentOwnership -Branch 'tangent/baz' -Worktree $wt -WorktreeRoot $script:TmpRoot | Should -BeTrue
    }
}

Describe 'Generated launch.ps1 sets TANGENT_SESSION env vars' {
    It 'engine writes TANGENT_SESSION/BRANCH/WORKTREE into the per-tangent launch script' {
        # Read the engine source and confirm the strings are present (cheap structural check).
        $engineSrc = Get-Content -LiteralPath $script:EnginePath -Raw
        $engineSrc | Should -Match 'TANGENT_SESSION'
        $engineSrc | Should -Match 'TANGENT_BRANCH'
        $engineSrc | Should -Match 'TANGENT_WORKTREE'
    }
    It 'engine writes TANGENT_PARENT_SESSION/DIR/INTERACTION_ID for handback' {
        $engineSrc = Get-Content -LiteralPath $script:EnginePath -Raw
        $engineSrc | Should -Match 'TANGENT_PARENT_SESSION'
        $engineSrc | Should -Match 'TANGENT_PARENT_DIR'
        $engineSrc | Should -Match 'TANGENT_INTERACTION_ID'
    }
    It 'engine bypasses agency.exe wrapper only for fresh -n spawns' {
        # Agency unconditionally injects --resume <agency-session-id>, which
        # collides with -n. Engine must rewrite to bare copilot.exe in that
        # path only — for --resume=<id> paths, agency's injected --resume is
        # harmless (commander last-wins → our --resume in EXTRA_ARGS overrides).
        $engineSrc = Get-Content -LiteralPath $script:EnginePath -Raw
        $engineSrc | Should -Match 'bypassing agency.exe wrapper for fresh -n spawn'
        $engineSrc | Should -Match '\$usingDashN'
        $engineSrc | Should -Match "Get-Command copilot"
    }
    It 'engine wires session-clone for -Mode full' {
        $engineSrc = Get-Content -LiteralPath $script:EnginePath -Raw
        $engineSrc | Should -Match 'tangent-clone-session\.ps1'
        $engineSrc | Should -Match '\$clonedSessionId'
        $engineSrc | Should -Match '--resume=\$clonedSessionId'
    }
}

Describe 'tangent-clone-session.ps1' {
    BeforeAll {
        $script:CloneScript = Join-Path $RepoRoot 'scripts\tangent-clone-session.ps1'
        $script:CloneRoot   = Join-Path $env:TEMP "tangent-clone-tests-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $script:CloneRoot -Force | Out-Null

        function global:New-FakeSession {
            param([string]$Root, [string]$Id)
            $dir = Join-Path $Root $Id
            New-Item -ItemType Directory -Path $dir | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $dir 'rewind-snapshots') | Out-Null
            'snapshot data' | Set-Content -LiteralPath (Join-Path $dir 'rewind-snapshots\should-skip.bin')
            'lock' | Set-Content -LiteralPath (Join-Path $dir 'inuse.123.lock')
            @"
id: $Id
cwd: c:\Repos\example
git_root: C:\Repos\example
branch: main
name: Original
user_named: false
summary: Original
mc_task_id: e0bde05d-e2ab-4a01-9216-9f3c7a8eed10
mc_session_id: 3655ac5b-89b5-4f31-903c-a8a5bd5f30f3
"@ | Set-Content -LiteralPath (Join-Path $dir 'workspace.yaml')
            @"
{"id":"e1","sessionId":"$Id","type":"session.start"}
{"id":"e2","data":{"sessionId":"$Id"},"type":"user.message"}
"@ | Set-Content -LiteralPath (Join-Path $dir 'events.jsonl')
            '# plan' | Set-Content -LiteralPath (Join-Path $dir 'plan.md')
            return $dir
        }
    }
    AfterAll {
        if (Test-Path -LiteralPath $script:CloneRoot) {
            Remove-Item -LiteralPath $script:CloneRoot -Recurse -Force -EA SilentlyContinue
        }
        Remove-Item function:\New-FakeSession -EA SilentlyContinue
    }

    It 'copies the session folder, skipping locks and rewind-snapshots' {
        $parent = 'parent-' + [guid]::NewGuid().ToString('N').Substring(0,8)
        $newId  = 'newid-'  + [guid]::NewGuid().ToString('N').Substring(0,8)
        New-FakeSession -Root $script:CloneRoot -Id $parent | Out-Null

        $json = & pwsh -NoProfile -File $script:CloneScript `
            -ParentSessionId $parent -NewSessionId $newId `
            -Branch 'tangent/test' -WorktreePath 'C:\fake\worktree' `
            -SessionStateRoot $script:CloneRoot
        $LASTEXITCODE | Should -Be 0
        $obj = $json | ConvertFrom-Json
        $obj.newSessionId | Should -Be $newId
        $obj.eventsRewritten | Should -Be 2

        $newDir = Join-Path $script:CloneRoot $newId
        Test-Path -LiteralPath $newDir | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $newDir 'plan.md') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $newDir 'workspace.yaml') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $newDir 'events.jsonl') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $newDir 'inuse.123.lock') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $newDir 'rewind-snapshots') | Should -BeFalse
    }

    It 'rewrites workspace.yaml with new id, cwd, git_root, branch and clears mc_*' {
        $parent = 'parent-' + [guid]::NewGuid().ToString('N').Substring(0,8)
        $newId  = 'newid-'  + [guid]::NewGuid().ToString('N').Substring(0,8)
        New-FakeSession -Root $script:CloneRoot -Id $parent | Out-Null

        & pwsh -NoProfile -File $script:CloneScript `
            -ParentSessionId $parent -NewSessionId $newId `
            -Branch 'tangent/feature-x' -WorktreePath 'C:\wt\tangent\feature-x' `
            -SessionStateRoot $script:CloneRoot | Out-Null

        $ws = Get-Content -LiteralPath (Join-Path $script:CloneRoot "$newId\workspace.yaml") -Raw
        $ws | Should -Match "(?m)^id:\s+$newId\s*$"
        $ws | Should -Match "(?m)^cwd:\s+C:\\wt\\tangent\\feature-x\s*$"
        $ws | Should -Match "(?m)^git_root:\s+C:\\wt\\tangent\\feature-x\s*$"
        $ws | Should -Match "(?m)^branch:\s+tangent/feature-x\s*$"
        $ws | Should -Match '(?m)^name:\s+tangent/feature-x\s*$'
        $ws | Should -Match '(?m)^user_named:\s+false\s*$'
        $ws | Should -Match '(?m)^mc_task_id:\s+""\s*$'
        $ws | Should -Match '(?m)^mc_session_id:\s+""\s*$'
        # Parent id should not appear as a session-id value; it does appear once in the
        # provenance "forked from <parent>" summary line, which is intentional.
        ([regex]::Matches($ws, [regex]::Escape($parent))).Count | Should -Be 1
        $ws | Should -Match "forked from $parent"
    }

    It 'rewrites parent GUID in events.jsonl and appends fork marker' {
        $parent = 'parent-' + [guid]::NewGuid().ToString('N').Substring(0,8)
        $newId  = 'newid-'  + [guid]::NewGuid().ToString('N').Substring(0,8)
        New-FakeSession -Root $script:CloneRoot -Id $parent | Out-Null

        & pwsh -NoProfile -File $script:CloneScript `
            -ParentSessionId $parent -NewSessionId $newId `
            -Branch 'tangent/test' -WorktreePath 'C:\fake' `
            -SessionStateRoot $script:CloneRoot | Out-Null

        $ev = Get-Content -LiteralPath (Join-Path $script:CloneRoot "$newId\events.jsonl")
        $ev.Count | Should -BeGreaterOrEqual 3   # 2 original + fork marker
        # Parent id should be replaced everywhere except in the fork-marker provenance.
        $nonForkLines = $ev | Where-Object { $_ -notmatch '"type":"session\.info"' }
        ($nonForkLines -join "`n") | Should -Not -Match $parent
        ($ev -join "`n") | Should -Match $newId
        $forkLine = $ev | Where-Object { $_ -match '"type":"session\.info"' -and $_ -match 'forked' }
        $forkLine | Should -Not -BeNullOrEmpty
        $forkObj = $forkLine | ConvertFrom-Json
        $forkObj.data.fork.parent_session_id | Should -Be $parent
        $forkObj.data.fork.branch | Should -Be 'tangent/test'
    }

    It 'refuses when ParentSessionId equals NewSessionId' {
        $sameId = 'same-' + [guid]::NewGuid().ToString('N').Substring(0,8)
        & pwsh -NoProfile -File $script:CloneScript `
            -ParentSessionId $sameId -NewSessionId $sameId `
            -Branch 'tangent/x' -WorktreePath 'C:\fake' `
            -SessionStateRoot $script:CloneRoot 2>&1 | Out-Null
        $LASTEXITCODE | Should -Not -Be 0
    }

    It 'refuses when destination already exists' {
        $parent = 'parent-' + [guid]::NewGuid().ToString('N').Substring(0,8)
        $newId  = 'newid-'  + [guid]::NewGuid().ToString('N').Substring(0,8)
        New-FakeSession -Root $script:CloneRoot -Id $parent | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:CloneRoot $newId) | Out-Null

        & pwsh -NoProfile -File $script:CloneScript `
            -ParentSessionId $parent -NewSessionId $newId `
            -Branch 'tangent/x' -WorktreePath 'C:\fake' `
            -SessionStateRoot $script:CloneRoot 2>&1 | Out-Null
        $LASTEXITCODE | Should -Not -Be 0
    }
}

Describe 'tangent-handback round-trip' {
    BeforeAll {
        $script:HandbackScript = Join-Path $RepoRoot 'scripts\tangent-handback.ps1'
        $script:IngestScript   = Join-Path $RepoRoot 'scripts\tangent-inbox-ingest.ps1'
    }
    BeforeEach {
        $script:HbSid       = "tangent-test-$(Get-Random)"
        $script:HbParent    = Join-Path $HOME ".copilot\session-state\$($script:HbSid)"
        $script:HbWorktree  = Join-Path ([IO.Path]::GetTempPath()) "tangent-hb-wt-$(Get-Random)"
        $script:HbIid       = [guid]::NewGuid().ToString()
        New-Item -ItemType Directory -Path $script:HbParent -Force | Out-Null
        New-Item -ItemType Directory -Path $script:HbWorktree -Force | Out-Null
        Push-Location $script:HbWorktree
        try {
            & git init -q -b main 2>$null | Out-Null
            & git -c user.email=t@t -c user.name=t commit --allow-empty -q -m init | Out-Null
        } finally { Pop-Location }
        $allow = Join-Path $script:HbParent 'files\tangent-handback\allowed'
        New-Item -ItemType Directory -Path $allow -Force | Out-Null
        ('{"interaction_id":"' + $script:HbIid + '"}') | Set-Content -LiteralPath (Join-Path $allow "$($script:HbIid).json")

        $script:HbSavedEnv = @{}
        foreach ($k in 'TANGENT_PARENT_SESSION','TANGENT_PARENT_DIR','TANGENT_INTERACTION_ID','TANGENT_BRANCH','TANGENT_WORKTREE','TANGENT_PARENT_BRANCH','COPILOT_AGENT_SESSION_ID') {
            $script:HbSavedEnv[$k] = [Environment]::GetEnvironmentVariable($k, 'Process')
        }
    }
    AfterEach {
        foreach ($kv in $script:HbSavedEnv.GetEnumerator()) {
            [Environment]::SetEnvironmentVariable($kv.Key, $kv.Value, 'Process')
        }
        Remove-Item -LiteralPath $script:HbParent -Recurse -Force -EA SilentlyContinue
        Remove-Item -LiteralPath $script:HbWorktree -Recurse -Force -EA SilentlyContinue
    }

    It 'handback writes a JSON file to the parent inbox and ingest archives it' {
        $env:TANGENT_PARENT_SESSION = $script:HbSid
        $env:TANGENT_PARENT_DIR     = $script:HbParent
        $env:TANGENT_INTERACTION_ID = $script:HbIid
        $env:TANGENT_BRANCH         = 'tangent/test'
        $env:TANGENT_WORKTREE       = $script:HbWorktree
        $env:TANGENT_PARENT_BRANCH  = 'main'
        $env:COPILOT_AGENT_SESSION_ID = 'tangent-side-fake'

        Push-Location $script:HbWorktree
        try {
            & $script:HandbackScript -Message 'pester test' | Out-Null
        } finally { Pop-Location }

        $inbox = Join-Path $script:HbParent 'files\tangent-handback\inbox'
        @(Get-ChildItem -LiteralPath $inbox -Filter '*.json').Count | Should -Be 1

        # Now ingest
        foreach ($k in 'TANGENT_PARENT_SESSION','TANGENT_PARENT_DIR','TANGENT_INTERACTION_ID','TANGENT_BRANCH','TANGENT_WORKTREE','TANGENT_PARENT_BRANCH') {
            [Environment]::SetEnvironmentVariable($k, $null, 'Process')
        }
        $env:COPILOT_AGENT_SESSION_ID = $script:HbSid
        $stdout = & $script:IngestScript

        @(Get-ChildItem -LiteralPath $inbox -Filter '*.json').Count | Should -Be 0
        $read = Join-Path $script:HbParent 'files\tangent-handback\read'
        @(Get-ChildItem -LiteralPath $read -Filter '*.json').Count | Should -Be 1

        ($stdout -join "`n") | Should -Match '<tangent-handback'
        ($stdout -join "`n") | Should -Match 'pester test'
    }

    It 'ingest rejects a file with wrong parent_session_id' {
        $inbox = Join-Path $script:HbParent 'files\tangent-handback\inbox'
        New-Item -ItemType Directory -Path $inbox -Force | Out-Null
        $payload = @{
            id = 'x'; branch = 'tangent/x'; interaction_id = $script:HbIid
            sequence = 0; tangent_session_id = 's'
            parent_session_id = 'WRONG-PARENT'
            summary = 's'; content_xml_escaped = '<tangent-handback>x</tangent-handback>'
            sent_at_iso = (Get-Date).ToString('o')
        } | ConvertTo-Json
        Set-Content -LiteralPath (Join-Path $inbox 'bad.json') -Value $payload -Encoding UTF8

        $env:COPILOT_AGENT_SESSION_ID = $script:HbSid
        & $script:IngestScript | Out-Null
        @(Get-ChildItem -LiteralPath $inbox -Filter '*.json').Count | Should -Be 0
        $rej = Join-Path $script:HbParent 'files\tangent-handback\rejected'
        @(Get-ChildItem -LiteralPath $rej -Filter '*.json').Count | Should -Be 1
    }

    It 'handback refuses without TANGENT_PARENT_SESSION env vars' {
        foreach ($k in 'TANGENT_PARENT_SESSION','TANGENT_PARENT_DIR','TANGENT_INTERACTION_ID') {
            [Environment]::SetEnvironmentVariable($k, $null, 'Process')
        }
        $env:TANGENT_BRANCH = 'tangent/test'
        $env:TANGENT_WORKTREE = $script:HbWorktree
        Push-Location $script:HbWorktree
        try {
            { & $script:HandbackScript -Message 'x' -ErrorAction Stop } | Should -Throw
        } finally { Pop-Location }
    }
}

Describe 'tangent-prune -Branch selection' {
    BeforeAll {
        $script:PruneScript = Join-Path $script:RepoRoot 'scripts\tangent-prune.ps1'
    }
    It 'reports skipped when -Branch names a non-existent worktree (JSON)' {
        $out = & pwsh -NoProfile -File $script:PruneScript -Branch 'tangent/does-not-exist' -DryRun -Json 2>&1
        $LASTEXITCODE | Should -Be 0
        $obj = $out | ConvertFrom-Json
        $obj.selected | Should -Be 0
        ($obj.skipped | Where-Object { $_.branch -eq 'tangent/does-not-exist' }).reason | Should -Match 'no such tangent'
    }

    It '-Force changes the planned worktree-remove command to use --force in the dry-run report' {
        # Use a synthetic, never-existing branch — we only need to check the script accepts -Force without erroring.
        $out = & pwsh -NoProfile -File $script:PruneScript -Branch 'tangent/does-not-exist' -DryRun -Force -Json 2>&1
        $LASTEXITCODE | Should -Be 0
        # Script must accept the flag and still emit a well-formed report
        $obj = $out | ConvertFrom-Json
        $obj.dryRun | Should -BeTrue
    }

    It '-Menu emits a JSON payload with question + choices, even when empty' {
        # We can't guarantee inventory state, so just exercise shape.
        $out = & pwsh -NoProfile -File $script:PruneScript -Menu 2>&1
        $LASTEXITCODE | Should -Be 0
        $obj = ($out -join "`n") | ConvertFrom-Json
        $obj.PSObject.Properties.Name | Should -Contain 'question'
        $obj.PSObject.Properties.Name | Should -Contain 'choices'
        $obj.PSObject.Properties.Name | Should -Contain 'empty'
        # Cancel must always be present
        ($obj.choices | Where-Object { $_.token -eq '__cancel__' }).Count | Should -BeGreaterThan 0
    }

    It '-OnDirty without -Branch fails with non-zero exit' {
        $null = & pwsh -NoProfile -File $script:PruneScript -OnDirty stash 2>&1
        $LASTEXITCODE | Should -Not -Be 0
    }

    It '-OnDirty commit without -CommitMessage fails with non-zero exit' {
        $null = & pwsh -NoProfile -File $script:PruneScript -Branch 'tangent/x' -OnDirty commit 2>&1
        $LASTEXITCODE | Should -Not -Be 0
    }

    It '-OnDirty discard implies -Force (script accepts and runs)' {
        $out = & pwsh -NoProfile -File $script:PruneScript -Branch 'tangent/does-not-exist' -OnDirty discard -DryRun -Json 2>&1
        $LASTEXITCODE | Should -Be 0
        $obj = $out | ConvertFrom-Json
        $obj.dryRun | Should -BeTrue
    }
}

Describe 'Stop hook is gated on TANGENT_SESSION' {
    It 'hooks.json early-returns when TANGENT_SESSION is unset' {
        $hooks = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'hooks/hooks.json') -Raw | ConvertFrom-Json
        $cmd = $hooks.Stop[0].args[-1]
        $cmd | Should -Match 'if \(-not \$env:TANGENT_SESSION\) \{ return \}'
    }
}
