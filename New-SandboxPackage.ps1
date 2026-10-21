<#
.SYNOPSIS
    Tworzy paczke zip z plikami potrzebnymi do zbudowania srodowiska Windows Sandbox na innym komputerze.

.DESCRIPTION
    Uruchamiany NA HOSCIE. Pakuje WYLACZNIE pliki z listy ponizej (skrypty, konfiguracje Sandboxa
    i Claude Code, dokumentacje). Celowo NIE pakuje: Tools\ (pobiera je Install-SandboxTools.ps1),
    Home\ (logowanie Claude, historia, ustawienia), Projects\, ProjectMap.json, Scripts\ (kopie skryptow)
    ani logow.

    Paczka zawiera folder SandBox\ - po rozpakowaniu np. na dysk E: powstaje E:\SandBox.

.PARAMETER OutDir
    Folder, w ktorym powstanie paczka (domyslnie <folder srodowiska>\dist).

.EXAMPLE
    E:\SandBox\New-SandboxPackage.ps1
#>
[CmdletBinding()]
param(
    [string]$Root,     # domyslnie folder, w ktorym lezy ten skrypt
    [string]$OutDir
)

$ErrorActionPreference = 'Stop'
# $PSScriptRoot jako wartosc domyslna w param() jest pusty w Windows PowerShell 5.1 - ustalamy tutaj.
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
        if (-not (Test-Path -LiteralPath $src)) { throw "Brak pliku: $src" }
        $dst = Join-Path $pkgRoot $f
        New-Item -ItemType Directory -Force -Path (Split-Path $dst) | Out-Null
        Copy-Item -LiteralPath $src -Destination $dst
        Write-Host "  + $f"
    }
    # puste foldery tworzone i tak przez Install-SandboxTools.ps1 - dla czytelnosci struktury
    foreach ($d in 'Projects', 'Scripts') { New-Item -ItemType Directory -Force -Path (Join-Path $pkgRoot $d) | Out-Null }

    Compress-Archive -Path $pkgRoot -DestinationPath $zip -Force
} finally {
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "`nUtworzono: $zip ($([Math]::Round((Get-Item $zip).Length / 1KB)) KB)" -ForegroundColor Green
