<#
.SYNOPSIS
    Przenosi prace z Sandboxa (commity + niezatwierdzone zmiany) do folderu docelowego na hoscie.

.DESCRIPTION
    Uruchamiany NA HOSCIE, po wykonaniu w Sandboxie Export-SandboxWork.ps1.
      1. git fetch z E:\SandBox\Projects\.sandbox-export\<nazwa>.bundle:
           galezie z Sandboxa -> refs/remotes/sandbox/*   (np. sandbox/main)
           HEAD z Sandboxa    -> refs/sandbox/head
           migawka zmian      -> refs/sandbox/wip
      2. (opcjonalnie, -FastForward) przesuwa biezaca galaz do commitow z Sandboxa,
      3. naklada niezatwierdzone zmiany z Sandboxa (git apply) na katalog roboczy celu
         - wczesniej pokazuje liste plikow i prosi o potwierdzenie,
         - wlasne niezatwierdzone zmiany celu zapisuje jako kopie refs/sandbox/backup/<data>,
      4. po udanym nalozeniu usuwa pomocnicze refs/sandbox/head i refs/sandbox/wip, zeby migawka
         nie byla widoczna w historii (np. jako "galaz" sandbox/wip w Git Extensions / VS Code).
         Zostaja, gdy zmiany nie zostaly nalozone (-NoApply, odmowa, konflikt) - mozna z nich pobrac pliki.

    Skrypt nie uruchamia gita w repozytorium zmodyfikowanym w Sandboxie - czyta tylko plik bundle.

.PARAMETER Name
    Nazwa projektu (folder w E:\SandBox\Projects).

.PARAMETER Target
    Repozytorium docelowe. Domyslnie z ProjectMap.json (zapisane przez Copy-ProjectToSandbox.ps1).

.PARAMETER FastForward
    Jesli Sandbox ma nowe commity na tej samej galezi - przesun galaz celu (merge --ff-only).

.PARAMETER ThreeWay
    Jesli zmiany nie nakladaja sie czysto - uzyj git apply --3way (konflikty do rozwiazania recznie).

.PARAMETER NoApply
    Tylko git fetch, bez nakladania niezatwierdzonych zmian.

.PARAMETER Yes
    Nie pytaj o potwierdzenie.

.EXAMPLE
    E:\SandBox\Import-SandboxWork.ps1 MojProjekt
.EXAMPLE
    E:\SandBox\Import-SandboxWork.ps1 MojProjekt -FastForward -ThreeWay
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)][string]$Name,
    [string]$Target,
    [switch]$FastForward,
    [switch]$ThreeWay,
    [switch]$NoApply,
    [switch]$Yes,
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

if ($Name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') { throw "Niepoprawna nazwa projektu: '$Name'." }

$ExportDir = Join-Path $Root 'Projects\.sandbox-export'
$bundle    = Join-Path $ExportDir "$Name.bundle"
$infoFile  = Join-Path $ExportDir "$Name.json"
$MapFile   = Join-Path $Root 'ProjectMap.json'

if (-not (Test-Path -LiteralPath $bundle)) {
    throw "Brak $bundle. Najpierw w Sandboxie uruchom skrot 'Eksportuj zmiany' (C:\SandBox\Scripts\Export-SandboxWork.ps1)."
}

if (-not $Target -and (Test-Path $MapFile)) {
    $entry = (Get-Content $MapFile -Raw | ConvertFrom-Json).$Name
    if ($entry) { $Target = $entry.target }
}
if (-not $Target) { throw "Nie znam folderu docelowego dla '$Name' - podaj -Target." }
$Target = (Invoke-Git -C $Target rev-parse --show-toplevel) -replace '/', '\'

# Plik .json pochodzi z Sandboxa - traktujemy go jako niezaufany (tylko informacyjnie + walidacja).
$sbBranch = $null
$exportedAt = '?'
if (Test-Path -LiteralPath $infoFile) {
    try {
        $info = Get-Content -LiteralPath $infoFile -Raw | ConvertFrom-Json
        $exportedAt = [string]$info.exportedAt
        if ($info.branch) {
            & $Git check-ref-format --branch ([string]$info.branch) | Out-Null
            if ($LASTEXITCODE -eq 0) { $sbBranch = [string]$info.branch }
        }
    } catch { Write-Warning "Nie udalo sie odczytac $infoFile - pomijam." }
}

Write-Host "Projekt : $Name  (eksport z Sandboxa: $exportedAt)" -ForegroundColor Cyan
Write-Host "Cel     : $Target"

# --- 1. git fetch z bundla ---------------------------------------------------------------
Invoke-Git -C $Target bundle verify -q $bundle | Out-Null
Invoke-Git -C $Target fetch --no-tags $bundle `
    '+refs/heads/*:refs/remotes/sandbox/*' '+refs/sandbox/head:refs/sandbox/head' '+refs/sandbox/wip:refs/sandbox/wip'

$sbHead = Invoke-Git -C $Target rev-parse 'refs/sandbox/head^{commit}'
$wip    = Invoke-Git -C $Target rev-parse 'refs/sandbox/wip^{commit}'
$tHead  = Invoke-Git -C $Target rev-parse 'HEAD^{commit}'
$tBranch = & $Git -C $Target symbolic-ref --short -q HEAD
if ($LASTEXITCODE -ne 0) { $tBranch = $null }

Write-Host "Galaz w Sandboxie: $(if ($sbBranch) { $sbBranch } else { '?' }), w celu: $(if ($tBranch) { $tBranch } else { '(odlaczony HEAD)' })"

# Pomocnicze refy migawki - usuwane, gdy nie sa juz potrzebne (inaczej narzedzia Git pokazuja
# migawke jako osobna galaz z niezatwierdzonymi zmianami). Obiekty i tak zostaja w reflogu/bazie do gc.
function Remove-SandboxRefs {
    foreach ($ref in 'refs/sandbox/wip', 'refs/sandbox/head') {
        & $Git -C $Target update-ref -d $ref 2>$null
    }
}

# --- 2. Commity z Sandboxa -----------------------------------------------------------------
if ($sbHead -ne $tHead) {
    & $Git -C $Target merge-base --is-ancestor $tHead $sbHead
    $canFastForward = ($LASTEXITCODE -eq 0)
    $newCommits = Invoke-Git -C $Target log --oneline --no-decorate --no-color "$tHead..$sbHead"
    if ($newCommits) {
        Write-Host "`nNowe commity z Sandboxa:" -ForegroundColor Cyan
        $newCommits | ForEach-Object { Write-Host "  $_" }
    }

    if ($FastForward -and $canFastForward -and $tBranch -and $tBranch -eq $sbBranch) {
        Write-Host "Przesuwam galaz $tBranch (fast-forward)..."
        Invoke-Git -C $Target merge --ff-only $sbHead
    } elseif ($FastForward -and -not $canFastForward) {
        Write-Warning "Historia w Sandboxie i w celu sie rozeszla - fast-forward niemozliwy. Scal recznie: git merge sandbox/$sbBranch"
    } elseif ($FastForward) {
        Write-Warning "Galaz celu ($tBranch) rozni sie od galezi w Sandboxie ($sbBranch) - pomijam fast-forward."
    } else {
        Write-Host "Commity sa dostepne jako sandbox/<galaz> (np. git merge --ff-only sandbox/$sbBranch) albo uzyj -FastForward." -ForegroundColor DarkGray
    }
}

# --- 3. Niezatwierdzone zmiany -------------------------------------------------------------
if ($NoApply) { Write-Host "`nPominieto nakladanie zmian (-NoApply). Migawka: refs/sandbox/wip"; return }
if ($wip -eq $sbHead) { Remove-SandboxRefs; Write-Host "`nW Sandboxie nie bylo niezatwierdzonych zmian." -ForegroundColor Green; return }

Write-Host "`nNiezatwierdzone zmiany z Sandboxa:" -ForegroundColor Cyan
Invoke-Git -C $Target diff --stat --no-color --no-ext-diff $sbHead $wip | ForEach-Object { Write-Host "  $_" }

if (-not $Yes) {
    $answer = Read-Host "`nNalozyc te zmiany na katalog roboczy $Target ? [t/N]"
    if ($answer -notmatch '^(t|tak|y|yes)$') { Write-Host 'Przerwano. Zmiany sa dostepne w refs/sandbox/wip.'; return }
}

# Kopia wlasnych niezatwierdzonych zmian celu (pliki sledzone) - do przywrocenia: git stash apply <sha>
$backup = Invoke-Git -C $Target stash create
if ($backup) {
    $backupRef = 'refs/sandbox/backup/' + (Get-Date -Format 'yyyyMMdd-HHmmss')
    Invoke-Git -C $Target update-ref $backupRef $backup
    Write-Host "Kopia zmian w celu: $backupRef (przywracanie: git stash apply $backupRef)" -ForegroundColor DarkGray
}

$patch = Join-Path $env:TEMP "sandbox-import-$Name-$PID.patch"
try {
    Invoke-Git -C $Target diff --binary --full-index --no-color --no-ext-diff --no-textconv `
        --src-prefix=a/ --dst-prefix=b/ "--output=$patch" $sbHead $wip

    & $Git -C $Target apply --check $patch
    if ($LASTEXITCODE -eq 0) {
        Invoke-Git -C $Target apply $patch
        Remove-SandboxRefs
        Write-Host "`nZmiany nalozone na katalog roboczy (nic nie zostalo zacommitowane)." -ForegroundColor Green
    } elseif ($ThreeWay) {
        Write-Warning 'Zmiany nie nakladaja sie czysto - probuje git apply --3way.'
        & $Git -C $Target apply --3way $patch
        if ($LASTEXITCODE -ne 0) {
            Write-Warning 'Wystapily konflikty - rozwiaz je recznie (git status). Uwaga: --3way dodaje zmiany do indeksu.'
            exit 1
        }
        Remove-SandboxRefs
        Write-Host "`nZmiany nalozone (3-way). Uwaga: --3way dodaje zmiany do indeksu (git restore --staged .)." -ForegroundColor Green
    } else {
        Write-Warning "Zmiany nie nakladaja sie czysto. Uruchom ponownie z -ThreeWay albo pobierz pliki recznie z refs/sandbox/wip (git checkout refs/sandbox/wip -- <plik>)."
        exit 1
    }
} finally {
    Remove-Item $patch -Force -ErrorAction SilentlyContinue
}
