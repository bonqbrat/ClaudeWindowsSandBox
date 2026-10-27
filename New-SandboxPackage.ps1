<#
.SYNOPSIS
    Creates a zip package with the files needed to build the Windows Sandbox environment on another computer.

.DESCRIPTION
    Run ON THE HOST. Packs ONLY the files listed below (scripts, Sandbox and Claude Code
    configuration, documentation). Deliberately does NOT pack: Tools\ (downloaded by Install-SandboxTools.ps1),
    Home\ (Claude login, history, settings), Projects\, ProjectMap.json, Scripts\ (script copies)
    or logs.

    The package contains a SandBox\ folder - extracting it e.g. to drive E: creates E:\SandBox.

.PARAMETER OutDir
    Folder where the package is created (default <environment folder>\dist).

.EXAMPLE
    E:\SandBox\New-SandboxPackage.ps1
#>
[CmdletBinding()]
param(
    [string]$Root,     # defaults to the folder containing this script
    [string]$OutDir
)

$ErrorActionPreference = 'Stop'
# $PSScriptRoot as a default value in param() is empty in Windows PowerShell 5.1 - resolve it here.
if (-not $Root) { $Root = Split-Path -Parent $MyInvocation.MyCommand.Path }

$Files = @(
    'README.md',
    'DevSandbox.wsb',
    'Install-SandboxTools.ps1',
    'Start-Sandbox.ps1',
    'Export-SandboxWork.ps1',
    'Copy-ProjectToSandbox.ps1',
    'Import-SandboxWork.ps1',
    'New-SandboxPackage.ps1',
    'Settings\ClaudeCode\managed-settings.json',
    'Settings\ClaudeCode\hooks\guard.py'
)

if (-not $OutDir) { $OutDir = Join-Path $Root 'dist' }
$stamp   = Get-Date -Format 'yyyyMMdd-HHmm'
$zip     = Join-Path $OutDir "DevSandbox-$stamp.zip"
$staging = Join-Path $env:TEMP "DevSandbox-package-$PID"
$pkgRoot = Join-Path $staging 'SandBox'

New-Item -ItemType Directory -Force -Path $OutDir, $pkgRoot | Out-Null
try {
    foreach ($f in $Files) {
        $src = Join-Path $Root $f
        if (-not (Test-Path -LiteralPath $src)) { throw "Missing file: $src" }
        $dst = Join-Path $pkgRoot $f
        New-Item -ItemType Directory -Force -Path (Split-Path $dst) | Out-Null
        Copy-Item -LiteralPath $src -Destination $dst
        Write-Host "  + $f"
    }
    # empty folders (created anyway by Install-SandboxTools.ps1) - for a clearer structure
    foreach ($d in 'Projects', 'Scripts') { New-Item -ItemType Directory -Force -Path (Join-Path $pkgRoot $d) | Out-Null }

    Compress-Archive -Path $pkgRoot -DestinationPath $zip -Force
} finally {
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "`nCreated: $zip ($([Math]::Round((Get-Item $zip).Length / 1KB)) KB)" -ForegroundColor Green
