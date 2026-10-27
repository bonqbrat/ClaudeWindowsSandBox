<#
.SYNOPSIS
    Klonuje projekt do E:\SandBox\Projects, aby pracowac nad nim w Windows Sandbox.

.DESCRIPTION
    Uruchamiany NA HOSCIE. Zrodlem moze byc:
      - lokalne repozytorium (np. D:\Repos\MojProjekt) - klon bez hardlinkow, wiec Sandbox
        nie ma dostepu do plikow oryginalu; origin w kopii wskazuje na zdalne repo oryginalu,
      - adres URL repozytorium (klonowanie z uzyciem poswiadczen hosta; poswiadczenia
        NIE trafiaja do Sandboxa, a login/token z adresu https jest usuwany).

    Powiazanie nazwa -> folder docelowy zapisywane jest w E:\SandBox\ProjectMap.json
    (poza folderami mapowanymi do Sandboxa, wiec Sandbox nie moze go zmienic).
    Z niego korzysta Import-SandboxWork.ps1.

.PARAMETER Source
    Sciezka lokalnego repozytorium albo URL.

.PARAMETER Name
    Nazwa folderu w Projects (domyslnie nazwa repozytorium).

.PARAMETER Target
    Folder na hoscie, do ktorego Import-SandboxWork.ps1 przeniesie zmiany.
    Domyslnie: Source, jesli jest lokalnym repozytorium.

.PARAMETER Branch
    Galaz do pobrania (domyslnie biezaca galaz zrodla / domyslna galaz zdalnego repo).

.PARAMETER Force
    Jesli projekt juz jest w Projects - nadpisz go bez pytania (z kopia zapasowa, chyba ze -NoBackup).

.PARAMETER NoBackup
    Przy nadpisywaniu usun poprzednia kopie zamiast przenosic ja do Projects\.backup (bez pytania o kopie).

.EXAMPLE
    E:\SandBox\Copy-ProjectToSandbox.ps1 D:\Repos\MojProjekt
.EXAMPLE
    E:\SandBox\Copy-ProjectToSandbox.ps1 https://gitlab.example.com/zespol/projekt.git -Target D:\Repos\projekt
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)][string]$Source,
    [string]$Name,
    [string]$Target,
    [string]$Branch,
    [switch]$RecurseSubmodules,
    [switch]$Force,
    [switch]$NoBackup,
    [string]$Root      # folder srodowiska - domyslnie tam, gdzie lezy ten skrypt
)

$ErrorActionPreference = 'Stop'
# $PSScriptRoot jako wartosc domyslna w param() jest pusty w Windows PowerShell 5.1 - ustalamy tutaj.
if (-not $Root) { $Root = Split-Path -Parent $MyInvocation.MyCommand.Path }

$Git = (Get-Command git.exe -ErrorAction SilentlyContinue).Source
if (-not $Git) { $Git = Join-Path $Root 'Tools\Git\cmd\git.exe' }

function Invoke-Git {
    $out = & $Git @args
    if ($LASTEXITCODE -ne 0) { throw "git $($args -join ' ') - kod $LASTEXITCODE" }
    $out
}

$Projects = Join-Path $Root 'Projects'
$MapFile  = Join-Path $Root 'ProjectMap.json'

$isLocal = Test-Path -LiteralPath $Source -PathType Container
if ($isLocal) {
    $Source = (Invoke-Git -C $Source rev-parse --show-toplevel) -replace '/', '\'
    if (-not $Target) { $Target = $Source }
    $originUrl = & $Git -C $Source config --get remote.origin.url   # bez komunikatu, gdy origin nie istnieje
    if ($LASTEXITCODE -ne 0) { $originUrl = $null }
}
if (-not $Name) { $Name = (Split-Path ($Source.TrimEnd('\', '/')) -Leaf) -replace '\.git$', '' }
if ($Name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') { throw "Niepoprawna nazwa projektu: '$Name' (uzyj -Name)." }

$dest = Join-Path $Projects $Name
if (Test-Path -LiteralPath $dest) {
    # Celowo bez "git status": host nie uruchamia gita w repozytorium zmienionym w Sandboxie.
    Write-Warning "Projekt $Name jest juz w $dest."
    Write-Host '  Zmiany wprowadzone w Sandboxie, ktore nie zostaly wyeksportowane i zaimportowane, nie trafia do nowej kopii.' -ForegroundColor Yellow
    $infoFile = Join-Path $Projects ".sandbox-export\$Name.json"
    $lastExport = 'nigdy'
    if (Test-Path -LiteralPath $infoFile) {
        try { $lastExport = [string](Get-Content -LiteralPath $infoFile -Raw | ConvertFrom-Json).exportedAt } catch { }
    }
    Write-Host "  Ostatni eksport z Sandboxa: $($lastExport.Substring(0, [Math]::Min(40, $lastExport.Length)))"

    if (-not $Force) {
        $answer = Read-Host "Nadpisac $dest nowym klonem z $Source ? [t/N]"
        if ($answer -notmatch '^(t|tak|y|yes)$') { Write-Host 'Przerwano - nic nie zostalo zmienione.'; return }
        if (-not $NoBackup) {
            # Domyslnie TAK (Enter) - kopia jest natychmiastowa i pozwala odzyskac zmiany.
            $answer = Read-Host "Zachowac poprzednia kopie w $Projects\.backup ? [T/n]"
            if ($answer -match '^(n|nie|no)$') { $NoBackup = $true }
        }
    }

    try {
        if ($NoBackup) {
            # rd /s /q nie wchodzi w dowiazania (junction/symlink) - usuwa tylko je same, nie ich cel.
            & cmd.exe /c rd /s /q $dest
            if (Test-Path -LiteralPath $dest) { throw 'nie udalo sie usunac wszystkich plikow' }
            Write-Host '  Poprzednia kopia usunieta.'
        } else {
            $backupDir = Join-Path $Projects '.backup'
            New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
            $backup = Join-Path $backupDir ('{0}-{1}' -f $Name, (Get-Date -Format 'yyyyMMdd-HHmmss'))
            Move-Item -LiteralPath $dest -Destination $backup   # zmiana nazwy - natychmiastowa
            Write-Host "  Poprzednia kopia przeniesiona do: $backup" -ForegroundColor DarkGray
        }
    } catch {
        throw "Nie udalo sie zwolnic folderu $dest ($($_.Exception.Message)). Zamknij w Sandboxie programy korzystajace z projektu (VS Code, terminal, Claude) albo zamknij Sandbox i sprobuj ponownie."
    }
}

# --- Klonowanie ------------------------------------------------------------------
$cloneArgs = @('clone')
if ($isLocal)           { $cloneArgs += '--no-hardlinks' }
if ($Branch)            { $cloneArgs += '--branch', $Branch }
if ($RecurseSubmodules) { $cloneArgs += '--recurse-submodules' }
$cloneArgs += '--', $Source, $dest

New-Item -ItemType Directory -Force -Path $Projects | Out-Null
Write-Host "Klonuje $Source -> $dest" -ForegroundColor Cyan
Invoke-Git @cloneArgs

# origin w kopii: zdalne repo oryginalu (sciezka hosta i tak jest niedostepna w Sandboxie),
# bez loginu/tokenu w adresie https.
$url = if ($isLocal) { $originUrl } else { $Source }
if ($url) {
    $url = $url -replace '^(https?://)[^/@]*@', '$1'
    Invoke-Git -C $dest remote set-url origin $url
} elseif ($isLocal) {
    Invoke-Git -C $dest remote remove origin
}

# --- Mapa projektow ----------------------------------------------------------------
$map = @{}
if (Test-Path $MapFile) {
    (Get-Content $MapFile -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $map[$_.Name] = $_.Value }
}
$map[$Name] = [ordered]@{ source = $Source; target = $Target; clonedAt = (Get-Date).ToString('s') }
$map | ConvertTo-Json | Set-Content -Path $MapFile -Encoding UTF8

# Biezacy projekt: skroty w Sandboxie (Claude Code, VS Code, Git Bash) otwieraja ten folder.
# Scripts\ jest w Sandboxie tylko do odczytu, wiec Sandbox nie moze tej wartosci zmienic.
New-Item -ItemType Directory -Force -Path (Join-Path $Root 'Scripts') | Out-Null
Set-Content -Path (Join-Path $Root 'Scripts\last-project.txt') -Value $Name -Encoding ASCII

# --- Tozsamosc Git w Sandboxie (Home\.gitconfig), jesli jeszcze nie ustawiona ----------
$sbGitConfig = Join-Path $Root 'Home\.gitconfig'
foreach ($key in 'user.name', 'user.email') {
    $current = & $Git config --file $sbGitConfig $key
    if (-not $current) {
        $value = & $Git config --global $key
        if ($value) {
            Invoke-Git config --file $sbGitConfig $key $value
            Write-Host "  Ustawiono $key w Home\.gitconfig"
        }
    }
}

Write-Host "`nGotowe. W Sandboxie: C:\SandBox\Projects\$Name" -ForegroundColor Green
if ($Target) {
    Write-Host "Zmiany wroca do: $Target  (Export-SandboxWork w Sandboxie, potem Import-SandboxWork.ps1 $Name)"
} else {
    Write-Host 'Folder docelowy nie jest ustawiony - przy imporcie podaj -Target.' -ForegroundColor Yellow
}
