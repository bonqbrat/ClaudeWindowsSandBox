<#
.SYNOPSIS
    Eksportuje prace z projektow w Sandboxie (commity + niezatwierdzone zmiany) do pliku git bundle.

.DESCRIPTION
    Uruchamiany WEWNATRZ Windows Sandbox (skrot "Eksportuj zmiany" na pulpicie).
    Dla kazdego repozytorium:
      - robi migawke katalogu roboczego (pliki zmienione, nowe i usuniete; z pominieciem .gitignore)
        jako commit refs/sandbox/wip - przy uzyciu tymczasowego indeksu, wiec NIE zmienia
        ani katalogu roboczego, ani przygotowanych (staged) zmian,
      - zapisuje refs/sandbox/head (biezacy HEAD),
      - tworzy C:\SandBox\Projects\.sandbox-export\<nazwa>.bundle (+ <nazwa>.json z opisem).

    Na hoscie zmiany przenosi Import-SandboxWork.ps1 (git fetch z bundla + git apply).
    Bundle to czyste dane - host nie musi uruchamiac gita w repozytorium zmodyfikowanym w Sandboxie.

.PARAMETER Path
    Katalog(i) repozytoriow. Domyslnie: wszystkie repozytoria w C:\SandBox\Projects.

.EXAMPLE
    C:\SandBox\Scripts\Export-SandboxWork.ps1
.EXAMPLE
    C:\SandBox\Scripts\Export-SandboxWork.ps1 -Path .
#>
[CmdletBinding()]
param(
    [string[]]$Path,
    [string]$ProjectsRoot = 'C:\SandBox\Projects'
)

$ErrorActionPreference = 'Stop'

$Git = (Get-Command git.exe -ErrorAction SilentlyContinue).Source
if (-not $Git) { $Git = 'C:\SandBox\Tools\Git\cmd\git.exe' }

function Invoke-Git {
    $out = & $Git @args
    if ($LASTEXITCODE -ne 0) { throw "git $($args -join ' ') - kod $LASTEXITCODE" }
    $out
}

$ExportDir = Join-Path $ProjectsRoot '.sandbox-export'

if (-not $Path) {
    $Path = Get-ChildItem -LiteralPath $ProjectsRoot -Directory |
            Where-Object { $_.Name -notlike '.*' -and (Test-Path (Join-Path $_.FullName '.git')) } |
            ForEach-Object { $_.FullName }
    if (-not $Path) { Write-Warning "Brak repozytoriow w $ProjectsRoot."; return }
}

New-Item -ItemType Directory -Force -Path $ExportDir | Out-Null
$failed = 0

foreach ($p in $Path) {
    try {
        $top  = Invoke-Git -C $p rev-parse --show-toplevel
        $name = Split-Path $top -Leaf
        Write-Host "`n=== $name ===" -ForegroundColor Cyan

        $head = & $Git -C $top rev-parse -q --verify 'HEAD^{commit}'
        if ($LASTEXITCODE -ne 0) { Write-Warning '  Repozytorium nie ma jeszcze zadnego commita - pomijam.'; continue }
        $branch = & $Git -C $top symbolic-ref --short -q HEAD
        if ($LASTEXITCODE -ne 0) { $branch = $null }

        # Migawka katalogu roboczego w tymczasowym indeksie (prawdziwy indeks pozostaje nietkniety).
        $gitDir  = Invoke-Git -C $top rev-parse --absolute-git-dir
        $tmpIdx  = Join-Path $env:TEMP "sandbox-export-$name-$PID.index"
        $realIdx = Join-Path $gitDir 'index'
        if (Test-Path $realIdx) { Copy-Item $realIdx $tmpIdx -Force }
        $env:GIT_INDEX_FILE = $tmpIdx
        try {
            Invoke-Git -C $top add -A | Out-Null
            $tree = Invoke-Git -C $top write-tree
        } finally {
            Remove-Item Env:GIT_INDEX_FILE -ErrorAction SilentlyContinue
            Remove-Item $tmpIdx -Force -ErrorAction SilentlyContinue
        }

        $headTree = Invoke-Git -C $top rev-parse 'HEAD^{tree}'
        $dirty = $tree -ne $headTree
        if ($dirty) {
            $env:GIT_AUTHOR_NAME = $env:GIT_COMMITTER_NAME = 'Sandbox Export'
            $env:GIT_AUTHOR_EMAIL = $env:GIT_COMMITTER_EMAIL = 'sandbox@localhost'
            try {
                $wip = Invoke-Git -C $top commit-tree $tree -p $head -m 'sandbox: niezatwierdzone zmiany'
            } finally {
                'GIT_AUTHOR_NAME', 'GIT_COMMITTER_NAME', 'GIT_AUTHOR_EMAIL', 'GIT_COMMITTER_EMAIL' |
                    ForEach-Object { Remove-Item "Env:$_" -ErrorAction SilentlyContinue }
            }
        } else {
            $wip = $head
        }
        Invoke-Git -C $top update-ref refs/sandbox/head $head
        Invoke-Git -C $top update-ref refs/sandbox/wip $wip

        $bundle = Join-Path $ExportDir "$name.bundle"
        $tmp    = "$bundle.tmp"
        Invoke-Git -C $top bundle create -q $tmp --branches refs/sandbox/head refs/sandbox/wip
        Move-Item $tmp $bundle -Force

        [ordered]@{
            name       = $name
            branch     = $branch
            head       = $head
            wip        = $wip
            dirty      = $dirty
            exportedAt = (Get-Date).ToString('s')
        } | ConvertTo-Json | Set-Content -Path (Join-Path $ExportDir "$name.json") -Encoding UTF8

        $state = if ($dirty) { 'z niezatwierdzonymi zmianami' } else { 'bez niezatwierdzonych zmian' }
        Write-Host "  Galaz: $(if ($branch) { $branch } else { '(odlaczony HEAD)' }), HEAD $($head.Substring(0, 10)), $state"
        if ($dirty) { Invoke-Git -C $top diff --stat --no-color $head $wip | Select-Object -Last 1 | ForEach-Object { Write-Host "  $_" } }
        Write-Host "  Zapisano: $bundle" -ForegroundColor Green
    } catch {
        $failed++
        Write-Host "  BLAD ($p): $_" -ForegroundColor Red
    }
}

Write-Host "`nNa hoscie uruchom: <folder srodowiska>\Import-SandboxWork.ps1 <nazwa-projektu>" -ForegroundColor Yellow
if ($failed) { exit 1 }
