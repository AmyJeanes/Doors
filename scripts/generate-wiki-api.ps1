[CmdletBinding()]
param(
    [string] $WikiPath,
    [switch] $Check,
    [switch] $Strict
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/bootstrap.ps1"

$RepoRoot = Split-Path -Parent $PSScriptRoot
if (-not $WikiPath) { $WikiPath = Join-Path (Split-Path -Parent $RepoRoot) 'Doors.wiki' }

$WikiConfig = & "$PSScriptRoot/wiki-api.config.ps1"

Invoke-WikiGen `
    -Root $RepoRoot `
    -WikiPath $WikiPath `
    -Categories $WikiConfig['Categories'] `
    -OwnedPrefix $WikiConfig['OwnedPrefix'] `
    -Check:$Check `
    -Strict:$Strict
