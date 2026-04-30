#requires -Version 7.0
<#
.SYNOPSIS
    Thin dispatcher invoked by the /tangent:new slash command.
    Forwards to scripts/tangent.ps1 and emits its JSON output.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Branch,

    [string]$Prompt = '',

    [ValidateSet('new', 'summary', 'full')]
    [string]$Mode = 'summary',

    [string]$ContextFile = '',

    [string]$Launcher = '',

    [switch]$Include,

    [switch]$Resume
)

$ErrorActionPreference = 'Stop'
$engine = Join-Path $PSScriptRoot 'tangent.ps1'

$forward = @{
    Branch = $Branch
    Mode   = $Mode
}
if ($Prompt)      { $forward.Prompt      = $Prompt }
if ($ContextFile) { $forward.ContextFile = $ContextFile }
if ($Launcher)    { $forward.Launcher    = $Launcher }
if ($Include)     { $forward.Include     = $true }
if ($Resume)      { $forward.Resume      = $true }

& $engine @forward
