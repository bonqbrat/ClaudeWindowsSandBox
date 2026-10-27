<#
.SYNOPSIS
    Przygotowuje folder z przenosnymi narzedziami programistycznymi dla Windows Sandbox.

.DESCRIPTION
    Uruchamiany NA HOSCIE (nie w Sandboxie). Pobiera najnowsze wersje:
      - Git for Windows (PortableGit)
      - Node.js LTS (zip)
      - Visual Studio Code (zip)
      - Claude Code (pakiet npm, instalowany do osobnego prefiksu)
      - Angular CLI (pakiet npm @angular/cli, instalowany do osobnego prefiksu - polecenie ng)
      - Python (pakiet NuGet "python" - pelny, przenosny Python z pip i venv)
      - .NET SDK 8 i 10 (zip; kompilator C#, runtime .NET, ASP.NET Core i Windows Desktop)
      - Git Extensions (portable zip; graficzny klient Git)
    i tworzy strukture folderow mapowana przez DevSandbox.wsb (folder srodowiska moze lezec w dowolnym
    miejscu - w przykladach E:\SandBox; sciezki w DevSandbox.wsb sa dopasowywane automatycznie):

      E:\SandBox\
        DevSandbox.wsb            - konfiguracja Sandboxa (kliknij dwukrotnie, aby uruchomic)
        Install-SandboxTools.ps1  - ten skrypt                                     (NIE jest widoczny w Sandboxie)
        Copy-ProjectToSandbox.ps1 - klonuje projekt do Projects                    (NIE jest widoczny w Sandboxie)
        Import-SandboxWork.ps1    - przenosi prace z Sandboxa do folderu docelowego (NIE jest widoczny w Sandboxie)
        ProjectMap.json           - nazwa projektu -> folder docelowy              (NIE jest widoczny w Sandboxie)
        Tools\                    - narzedzia            (w Sandboxie: C:\SandBox\Tools,    tylko do odczytu)
        Scripts\                  - skrypty Sandboxa     (w Sandboxie: C:\SandBox\Scripts,  tylko do odczytu)
        Settings\ClaudeCode\      - managed settings + hooki Claude Code
                                                         (w Sandboxie: C:\Program Files\ClaudeCode, tylko do odczytu)
        Home\                     - ustawienia, logowanie Claude, rozszerzenia VS Code
                                                         (w Sandboxie: C:\SandBox\Home,     zapis)
        Projects\                 - Twoje projekty       (w Sandboxie: C:\SandBox\Projects, zapis)

.PARAMETER Root
    Folder srodowiska (domyslnie folder, w ktorym lezy ten skrypt).

.PARAMETER Force
    Usuwa i instaluje ponownie wszystkie narzedzia (aktualizacja do najnowszych wersji).

.PARAMETER PythonVersion
    Konkretna wersja Pythona (np. 3.13.9). Domyslnie najnowsza stabilna.

.PARAMETER AngularCliVersion
    Wersja Angular CLI (np. 22). Domyslnie najnowsza. Globalne ng i tak uzywa wersji CLI z node_modules projektu.

.PARAMETER DotnetChannels
    Wersje .NET SDK do zainstalowania (domyslnie 8.0 i 10.0) - zawsze najnowsze wydanie z kanalu.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File E:\SandBox\Install-SandboxTools.ps1
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File E:\SandBox\Install-SandboxTools.ps1 -Force
#>
[CmdletBinding()]
param(
    [string]$Root,     # domyslnie folder, w ktorym lezy ten skrypt
    [switch]$Force,
    [ValidatePattern('^\d+\.\d+\.\d+$')][string]$PythonVersion,            # pelna wersja pakietu NuGet, np. 3.13.9
    [ValidatePattern('^\d+\.\d+$')][string[]]$DotnetChannels = @('8.0', '10.0'),
    [ValidatePattern('^(latest|\d+(\.\d+){0,2})$')][string]$AngularCliVersion = 'latest'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # znacznie przyspiesza Invoke-WebRequest w PowerShell 5.1
# $PSScriptRoot jako wartosc domyslna w param() jest pusty w Windows PowerShell 5.1 - ustalamy tutaj.
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $Root) { $Root = $ScriptDir }
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$Tar = Join-Path $env:SystemRoot 'System32\tar.exe'   # wbudowany w Windows 10/11, szybszy niz Expand-Archive

$Tools    = Join-Path $Root 'Tools'
$HomeDir  = Join-Path $Root 'Home'
$Projects = Join-Path $Root 'Projects'
$Scripts  = Join-Path $Root 'Scripts'
$Temp     = Join-Path $Root '_download'

$GitDir    = Join-Path $Tools 'Git'
$NodeDir   = Join-Path $Tools 'node'
$CodeDir   = Join-Path $Tools 'VSCode'
$ClaudeDir = Join-Path $Tools 'claude-code'
$PythonDir = Join-Path $Tools 'Python'
$NgDir     = Join-Path $Tools 'angular-cli'
$DotnetDir = Join-Path $Tools 'dotnet'
$GitExtDir = Join-Path $Tools 'GitExtensions'

function Write-Step([string]$Text) { Write-Host "`n=== $Text ===" -ForegroundColor Cyan }

function Get-File([string]$Url, [string]$OutFile) {
    Write-Host "  Pobieram: $Url"
    Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -Headers @{ 'User-Agent' = 'SandboxToolsInstaller' }
}

function Get-Text([string]$Url) {
    $content = (Invoke-WebRequest -Uri $Url -UseBasicParsing -Headers @{ 'User-Agent' = 'SandboxToolsInstaller' }).Content
    if ($content -is [byte[]]) { $content = [Text.Encoding]::UTF8.GetString($content) }
    $content
}

# Sprawdza skrot pobranego pliku PRZED jego rozpakowaniem/uruchomieniem; przy niezgodnosci usuwa plik.
function Assert-FileHash([string]$Path, [string]$Expected, [string]$Algorithm, [string]$What) {
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm $Algorithm).Hash
    if (-not $Expected -or $actual -ne $Expected.Trim()) {
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
        throw "Niezgodna suma $Algorithm ($What) - plik uszkodzony lub podmieniony, usuniety. Oczekiwano: '$Expected', obliczono: '$actual'."
    }
    Write-Host "  Suma $Algorithm zgodna: $What" -ForegroundColor DarkGray
}

# Sprawdza podpis Authenticode i wydawce pliku wykonywalnego.
function Assert-Signature([string]$Path, [string]$PublisherPattern, [string]$What) {
    $sig = Get-AuthenticodeSignature -LiteralPath $Path
    if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch $PublisherPattern) {
        throw "Niepoprawny podpis cyfrowy ($What): status $($sig.Status), wydawca '$($sig.SignerCertificate.Subject)'."
    }
    Write-Host "  Podpis cyfrowy poprawny: $What ($($sig.SignerCertificate.GetNameInfo('SimpleName', $false)))" -ForegroundColor DarkGray
}

# SHA-512 pakietu NuGet (hex). Najpierw plik .sha512 z flat container, a gdy go brak -
# pole packageHash (base64) z katalogu NuGet (registration -> catalog leaf).
function Get-NuGetPackageSha512([string]$Id, [string]$Version) {
    $b64 = $null
    try { $b64 = (Get-Text "https://api.nuget.org/v3-flatcontainer/$Id/$Version/$Id.$Version.nupkg.sha512").Trim() } catch { }
    if (-not $b64) {
        $index = Invoke-RestMethod "https://api.nuget.org/v3/registration5-semver1/$Id/index.json"
        foreach ($page in $index.items) {
            $items = if ($page.items) { $page.items } else { (Invoke-RestMethod $page.'@id').items }
            $leaf = $items | Where-Object { $_.catalogEntry.version -eq $Version } | Select-Object -First 1
            if ($leaf) { $b64 = (Invoke-RestMethod $leaf.catalogEntry.'@id').packageHash; break }
        }
    }
    if (-not $b64) { throw "Nie udalo sie pobrac sumy SHA-512 pakietu NuGet $Id $Version." }
    ([BitConverter]::ToString([Convert]::FromBase64String($b64)) -replace '-', '')
}

# Najnowszy PortableGit 64-bit: { Name, Url, Sha256 }.
# 1) API GitHub (SHA-256 z pola "digest" zasobu albo z tabeli sum w opisie wydania). Opcjonalny token
#    w zmiennej GITHUB_TOKEN podnosi limit zapytan (bez niego: 60/h na adres IP).
# 2) Gdy API odmowi (np. przekroczony limit): wydanie z przekierowania github.com/.../releases/latest
#    (bez limitu API), adres pliku z nazwy wydania, SHA-256 ze strony wydania - jesli sie da.
function Get-PortableGitRelease {
    $headers = @{ 'User-Agent' = 'SandboxToolsInstaller' }
    if ($env:GITHUB_TOKEN) { $headers['Authorization'] = "Bearer $env:GITHUB_TOKEN" }
    try {
        $release = Invoke-RestMethod 'https://api.github.com/repos/git-for-windows/git/releases/latest' -Headers $headers
        $asset = $release.assets | Where-Object { $_.name -match '^PortableGit-.*-64-bit\.7z\.exe$' } | Select-Object -First 1
        if (-not $asset) { throw 'Nie znaleziono pliku PortableGit (64-bit) w najnowszym wydaniu Git for Windows.' }
        $sha = $null
        if ($asset.digest -match '^sha256:([0-9a-fA-F]{64})$') { $sha = $Matches[1] }
        elseif ($release.body -match "$([regex]::Escape($asset.name))\s*\|\s*([0-9a-fA-F]{64})") { $sha = $Matches[1] }
        return [pscustomobject]@{ Name = $asset.name; Url = $asset.browser_download_url; Sha256 = $sha }
    } catch {
        Write-Warning "  API GitHub niedostepne ($($_.Exception.Message.Split([Environment]::NewLine)[0])) - uzywam strony wydania."
    }

    # Przekierowanie /releases/latest -> /releases/tag/<tag>
    $req = [System.Net.HttpWebRequest]::Create('https://github.com/git-for-windows/git/releases/latest')
    $req.AllowAutoRedirect = $false
    $req.UserAgent = 'SandboxToolsInstaller'
    $resp = $req.GetResponse()
    try { $location = $resp.Headers['Location'] } finally { $resp.Close() }
    if ($location -notmatch '/releases/tag/(v(\d+\.\d+\.\d+)\.windows\.(\d+))$') {
        throw "Nie udalo sie ustalic najnowszego wydania Git for Windows (przekierowanie: '$location')."
    }
    $tag = $Matches[1]
    $ver = if ($Matches[3] -eq '1') { $Matches[2] } else { "$($Matches[2]).$($Matches[3])" }
    $name = "PortableGit-$ver-64-bit.7z.exe"

    $sha = $null
    try {
        $page = Get-Text "https://github.com/git-for-windows/git/releases/tag/$tag"
        if ($page -match "(?s)$([regex]::Escape($name)).{0,300}?\b([0-9a-fA-F]{64})\b") { $sha = $Matches[1] }
    } catch { }
    [pscustomobject]@{
        Name   = $name
        Url    = "https://github.com/git-for-windows/git/releases/download/$tag/$name"
        Sha256 = $sha
    }
}

# Zasob najnowszego wydania GitHub pasujacy do wzorca: { Name, Url, Sha256 }.
# 1) API GitHub (SHA-256 z pola "digest"; opcjonalny token w GITHUB_TOKEN).
# 2) Przy odmowie API: tag z przekierowania /releases/latest, lista plikow z /releases/expanded_assets/<tag>.
# Gdy brak "digest", SHA-256 z pliku sum wydania (np. checksums.txt), jesli podano -ChecksumAsset.
function Get-GitHubReleaseAsset([string]$Repo, [string]$AssetPattern, [string]$ChecksumAsset) {
    $headers = @{ 'User-Agent' = 'SandboxToolsInstaller' }
    if ($env:GITHUB_TOKEN) { $headers['Authorization'] = "Bearer $env:GITHUB_TOKEN" }
    $assets = $null; $tag = $null
    try {
        $release = Invoke-RestMethod "https://api.github.com/repos/$Repo/releases/latest" -Headers $headers
        $tag = $release.tag_name
        $assets = @($release.assets | ForEach-Object {
            [pscustomobject]@{ Name = $_.name; Url = $_.browser_download_url
                               Sha256 = if ($_.digest -match '^sha256:([0-9a-fA-F]{64})$') { $Matches[1] } else { $null } } })
    } catch {
        Write-Warning "  API GitHub niedostepne dla $Repo ($($_.Exception.Message.Split([Environment]::NewLine)[0])) - uzywam strony wydania."
        $req = [System.Net.HttpWebRequest]::Create("https://github.com/$Repo/releases/latest")
        $req.AllowAutoRedirect = $false
        $req.UserAgent = 'SandboxToolsInstaller'
        $resp = $req.GetResponse()
        try { $location = $resp.Headers['Location'] } finally { $resp.Close() }
        if ($location -notmatch '/releases/tag/([^/?#]+)$') { throw "Nie udalo sie ustalic najnowszego wydania $Repo." }
        $tag = $Matches[1]
        $html = Get-Text "https://github.com/$Repo/releases/expanded_assets/$tag"
        $assets = @([regex]::Matches($html, "href=""(/$([regex]::Escape($Repo))/releases/download/[^""]+)""") |
            ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique | ForEach-Object {
                [pscustomobject]@{ Name = [Uri]::UnescapeDataString(($_ -split '/')[-1]); Url = "https://github.com$_"; Sha256 = $null } })
    }
    $asset = $assets | Where-Object { $_.Name -match $AssetPattern } | Select-Object -First 1
    if (-not $asset) { throw "Nie znaleziono pliku pasujacego do '$AssetPattern' w wydaniu $tag ($Repo). Dostepne: $(($assets.Name) -join ', ')" }
    if (-not $asset.Sha256 -and $ChecksumAsset) {
        $sumAsset = $assets | Where-Object { $_.Name -eq $ChecksumAsset } | Select-Object -First 1
        if ($sumAsset) {
            $sums = Get-Text $sumAsset.Url
            if ($sums -match "(?m)^([0-9a-fA-F]{64})\s+\*?$([regex]::Escape($asset.Name))\s*$") { $asset.Sha256 = $Matches[1] }
        }
    }
    Write-Host "  Wydanie: $tag, plik: $($asset.Name)"
    $asset
}

# Architektura pliku wykonywalnego (naglowek PE): x64, ARM64, x86.
function Get-PeMachine([string]$Path) {
    $fs = [IO.File]::OpenRead($Path)
    try {
        $br = New-Object IO.BinaryReader($fs)
        $fs.Position = 0x3C; $fs.Position = $br.ReadInt32() + 4
        switch ($br.ReadUInt16()) { 0x8664 { 'x64' } 0xAA64 { 'ARM64' } 0x14C { 'x86' } default { 'nieznana' } }
    } finally { $fs.Dispose() }
}

# Rozpakowuje zip do folderu docelowego; jesli zip ma jeden folder glowny - jego zawartosc.
function Expand-ToolZip([string]$Zip, [string]$Destination) {
    $extract = Join-Path $Temp ([IO.Path]::GetFileNameWithoutExtension($Zip))
    New-Item -ItemType Directory -Force -Path $extract | Out-Null
    & $Tar -xf $Zip -C $extract
    if ($LASTEXITCODE -ne 0) { throw "Rozpakowanie $Zip nie powiodlo sie." }
    $top = @(Get-ChildItem -LiteralPath $extract -Force)
    $src = if ($top.Count -eq 1 -and $top[0].PSIsContainer) { $top[0].FullName } else { $extract }
    New-Item -ItemType Directory -Force -Path (Split-Path $Destination) | Out-Null
    Move-Item -LiteralPath $src -Destination $Destination
}

function Test-NeedsInstall([string]$Path, [string]$Name) {
    if (Test-Path $Path) {
        if (-not $Force) {
            Write-Host "  $Name jest juz zainstalowany - pomijam (uzyj -Force, aby zaktualizowac)." -ForegroundColor DarkGray
            return $false
        }
        Write-Host "  Usuwam poprzednia wersje: $Path"
        Remove-Item $Path -Recurse -Force
    }
    return $true
}

# --- Struktura folderow -------------------------------------------------------
Write-Step 'Tworze strukture folderow'
foreach ($dir in $Root, $Tools, $HomeDir, $Projects, $Scripts, $Temp,
                 (Join-Path $HomeDir '.claude'),
                 (Join-Path $HomeDir 'vscode-data\user-data\User')) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
}
$Root = (Resolve-Path $Root).Path.TrimEnd('\')

# Skrypty z paczki zip pobranej z sieci maja znacznik "z internetu" - odblokowujemy je,
# aby dzialaly przy zasadach wykonywania RemoteSigned. Tylko jawnie wymienione skrypty srodowiska.
@('Install-SandboxTools.ps1', 'Start-Sandbox.ps1', 'Export-SandboxWork.ps1',
  'Copy-ProjectToSandbox.ps1', 'Import-SandboxWork.ps1', 'New-SandboxPackage.ps1') |
    ForEach-Object { $p = Join-Path $Root $_; if (Test-Path -LiteralPath $p) { Unblock-File -LiteralPath $p } }

# DevSandbox.wsb: sciezki folderow hosta dopasowane do lokalizacji srodowiska
# (pozostale ustawienia, np. pamiec, zostaja bez zmian).
$wsbFile = Join-Path $Root 'DevSandbox.wsb'
if (Test-Path $wsbFile) {
    $hostFolders = @{
        'C:\SandBox\Tools'            = 'Tools'
        'C:\SandBox\Scripts'          = 'Scripts'
        'C:\Program Files\ClaudeCode' = 'Settings\ClaudeCode'
        'C:\SandBox\Home'             = 'Home'
        'C:\SandBox\Projects'         = 'Projects'
    }
    $wsb = New-Object System.Xml.XmlDocument
    $wsb.PreserveWhitespace = $true
    $wsb.Load($wsbFile)
    $changed = $false
    foreach ($mf in $wsb.SelectNodes('/Configuration/MappedFolders/MappedFolder')) {
        $rel = $hostFolders[$mf.SandboxFolder]
        if ($rel) {
            # [string]: Join-Path zwraca string opakowany w PSObject, a wezly XML przyjmuja tylko czysty string.
            $expected = [string](Join-Path $Root $rel)
            $node = $mf.SelectSingleNode('HostFolder')
            if ($node -and $node.InnerText -ne $expected) { $node.InnerText = $expected; $changed = $true }
        }
    }
    if ($changed) {
        $xmlSettings = New-Object System.Xml.XmlWriterSettings
        $xmlSettings.Encoding = New-Object System.Text.UTF8Encoding($false)
        $xmlSettings.OmitXmlDeclaration = $true
        $writer = [System.Xml.XmlWriter]::Create($wsbFile, $xmlSettings)
        try { $wsb.Save($writer) } finally { $writer.Close() }
        Write-Host "  Zaktualizowano sciezki w DevSandbox.wsb -> $Root"
    }
} else {
    Write-Warning "Brak pliku $wsbFile."
}

# Skrypty uruchamiane w Sandboxie: jesli leza obok tego skryptu, kopiujemy je do Scripts\
foreach ($name in 'Start-Sandbox.ps1', 'Export-SandboxWork.ps1') {
    $src = Join-Path $ScriptDir $name
    if ((Test-Path $src) -and ($ScriptDir -ne $Scripts)) {
        Copy-Item $src $Scripts -Force
        Unblock-File (Join-Path $Scripts $name)
        Write-Host "  Skopiowano $name do folderu Scripts."
    }
    if (-not (Test-Path (Join-Path $Scripts $name))) {
        Write-Warning "Brak pliku $Scripts\$name - umiesc go tam przed uruchomieniem Sandboxa."
    }
}

if (-not (Test-Path (Join-Path $Root 'Settings\ClaudeCode\managed-settings.json'))) {
    Write-Warning "Brak $Root\Settings\ClaudeCode\managed-settings.json - Claude Code w Sandboxie bedzie dzialal bez managed settings."
}

# --- Git (PortableGit) --------------------------------------------------------
Write-Step 'Git for Windows (PortableGit)'
if (Test-NeedsInstall $GitDir 'Git') {
    $gitInfo = Get-PortableGitRelease
    $exe = Join-Path $Temp $gitInfo.Name
    Get-File $gitInfo.Url $exe
    if ($gitInfo.Sha256) {
        Assert-FileHash $exe $gitInfo.Sha256 'SHA256' $gitInfo.Name
    } else {
        Write-Warning "  Brak sumy SHA-256 dla $($gitInfo.Name) - pochodzenie potwierdza tylko podpis cyfrowy."
    }
    Assert-Signature $exe 'Johannes Schindelin' $gitInfo.Name   # Git for Windows podpisuje wydania tym certyfikatem

    Write-Host "  Rozpakowuje do $GitDir"
    New-Item -ItemType Directory -Force -Path $GitDir | Out-Null
    $p = Start-Process -FilePath $exe -ArgumentList "-o`"$GitDir`"", '-y' -Wait -PassThru
    if ($p.ExitCode -ne 0) { throw "Rozpakowanie PortableGit nie powiodlo sie (kod $($p.ExitCode))." }

    # Konfiguracja koncowa PortableGit musi sie wykonac tutaj,
    # bo w Sandboxie folder Tools jest tylko do odczytu.
    $postInstall = Join-Path $GitDir 'post-install.bat'
    if (Test-Path $postInstall) {
        Write-Host '  Uruchamiam post-install PortableGit...'
        Start-Process -FilePath (Join-Path $GitDir 'git-bash.exe') `
                      -ArgumentList '--needs-console', '--hide', '--no-cd', '--command=post-install.bat' `
                      -WorkingDirectory $GitDir -Wait
    }
    Write-Host "  Zainstalowano: $(& (Join-Path $GitDir 'cmd\git.exe') --version)" -ForegroundColor Green
}

# --- Node.js LTS ---------------------------------------------------------------
Write-Step 'Node.js LTS'
if (Test-NeedsInstall $NodeDir 'Node.js') {
    $index = Invoke-RestMethod 'https://nodejs.org/dist/index.json'
    $lts = $index | Where-Object { $_.lts -and ($_.files -contains 'win-x64-zip') } | Select-Object -First 1
    if (-not $lts) { throw 'Nie udalo sie ustalic najnowszej wersji LTS Node.js.' }
    $ver  = $lts.version
    $name = "node-$ver-win-x64"
    $zip  = Join-Path $Temp "$name.zip"
    Get-File "https://nodejs.org/dist/$ver/$name.zip" $zip
    $sums = Get-Text "https://nodejs.org/dist/$ver/SHASUMS256.txt"
    $expected = if ($sums -match "(?m)^([0-9a-fA-F]{64})\s+$([regex]::Escape("$name.zip"))\s*$") { $Matches[1] }
    Assert-FileHash $zip $expected 'SHA256' "$name.zip"

    Write-Host "  Rozpakowuje do $NodeDir"
    & $Tar -xf $zip -C $Temp
    if ($LASTEXITCODE -ne 0) { throw 'Rozpakowanie Node.js nie powiodlo sie.' }
    Move-Item (Join-Path $Temp $name) $NodeDir
    Write-Host "  Zainstalowano: Node.js $(& (Join-Path $NodeDir 'node.exe') --version)" -ForegroundColor Green
}

# --- Visual Studio Code (zip) --------------------------------------------------
Write-Step 'Visual Studio Code'
if (Test-NeedsInstall $CodeDir 'VS Code') {
    # API aktualizacji VS Code zwraca adres paczki i jej SHA-256.
    $meta = Invoke-RestMethod 'https://update.code.visualstudio.com/api/update/win32-x64-archive/stable/latest'
    $zip = Join-Path $Temp 'vscode.zip'
    Get-File $meta.url $zip
    Assert-FileHash $zip $meta.sha256hash 'SHA256' "VS Code $($meta.productVersion)"

    Write-Host "  Rozpakowuje do $CodeDir"
    New-Item -ItemType Directory -Force -Path $CodeDir | Out-Null
    & $Tar -xf $zip -C $CodeDir
    if ($LASTEXITCODE -ne 0) { throw 'Rozpakowanie VS Code nie powiodlo sie.' }
    # Uwaga: celowo NIE tworzymy folderu VSCode\data - dane VS Code trafiaja do Home\vscode-data
    # (zmienna VSCODE_PORTABLE ustawiana w Sandboxie), bo Tools jest tylko do odczytu.
    Write-Host '  Zainstalowano VS Code.' -ForegroundColor Green
}

# --- Claude Code (npm) ---------------------------------------------------------
Write-Step 'Claude Code'
if (Test-NeedsInstall $ClaudeDir 'Claude Code') {
    $env:Path = "$NodeDir;$env:Path"
    New-Item -ItemType Directory -Force -Path $ClaudeDir | Out-Null
    # --ignore-scripts: zadne skrypty z pakietow npm nie sa wykonywane na hoscie.
    & (Join-Path $NodeDir 'npm.cmd') install -g '@anthropic-ai/claude-code' `
        --prefix $ClaudeDir --cache (Join-Path $Temp 'npm-cache') --ignore-scripts --no-fund --no-audit
    if ($LASTEXITCODE -ne 0) { throw 'Instalacja Claude Code przez npm nie powiodla sie.' }

    # Zamiast pominietego postinstall (install.cjs): natywny claude.exe z pakietu
    # @anthropic-ai/claude-code-win32-x64 -> bin\claude.exe, po sprawdzeniu podpisu Anthropic.
    $native = Get-ChildItem (Join-Path $ClaudeDir 'node_modules') -Recurse -Filter 'claude.exe' -File |
              Where-Object { $_.FullName -match '\\claude-code-win32-x64\\claude\.exe$' } | Select-Object -First 1
    if (-not $native) { throw 'Nie znaleziono natywnego claude.exe (pakiet @anthropic-ai/claude-code-win32-x64).' }
    Assert-Signature $native.FullName 'O="?Anthropic, PBC' 'claude.exe'
    $binExe = Join-Path $ClaudeDir 'node_modules\@anthropic-ai\claude-code\bin\claude.exe'
    Remove-Item -LiteralPath $binExe -Force -ErrorAction SilentlyContinue
    try { New-Item -ItemType HardLink -Path $binExe -Value $native.FullName | Out-Null }
    catch { Copy-Item -LiteralPath $native.FullName -Destination $binExe }

    $env:Path = "$ClaudeDir;$env:Path"
    Write-Host "  Zainstalowano: $(claude --version)" -ForegroundColor Green
}

# --- Angular CLI (npm) ---------------------------------------------------------
Write-Step 'Angular CLI'
if (Test-NeedsInstall $NgDir 'Angular CLI') {
    $env:Path = "$NodeDir;$env:Path"
    $env:NG_CLI_ANALYTICS = 'false'
    New-Item -ItemType Directory -Force -Path $NgDir | Out-Null
    & (Join-Path $NodeDir 'npm.cmd') install -g "@angular/cli@$AngularCliVersion" `
        --prefix $NgDir --cache (Join-Path $Temp 'npm-cache') --ignore-scripts --no-fund --no-audit
    if ($LASTEXITCODE -ne 0) { throw 'Instalacja Angular CLI przez npm nie powiodla sie.' }
    $ngVersion = (Get-Content (Join-Path $NgDir 'node_modules\@angular\cli\package.json') -Raw | ConvertFrom-Json).version
    Write-Host "  Zainstalowano: Angular CLI $ngVersion" -ForegroundColor Green
}

# --- Python (NuGet) ------------------------------------------------------------
# Pakiet NuGet "python" to pelna, przenosna dystrybucja (bez instalatora i wpisow w rejestrze).
# Uzywany m.in. przez hook guard.py z Settings\ClaudeCode. W Sandboxie folder jest tylko do odczytu,
# wiec pakiety instaluj w srodowiskach wirtualnych projektu (python -m venv .venv).
Write-Step 'Python'
if (Test-NeedsInstall $PythonDir 'Python') {
    $ver = $PythonVersion
    if (-not $ver) {
        $ver = (Invoke-RestMethod 'https://api.nuget.org/v3-flatcontainer/python/index.json').versions |
               Where-Object { $_ -match '^\d+\.\d+\.\d+$' } |
               Sort-Object { [version]$_ } | Select-Object -Last 1
        if (-not $ver) { throw 'Nie udalo sie ustalic najnowszej wersji Pythona w NuGet.' }
    }
    $pkg = Join-Path $Temp "python.$ver.zip"
    Get-File "https://api.nuget.org/v3-flatcontainer/python/$ver/python.$ver.nupkg" $pkg
    Assert-FileHash $pkg (Get-NuGetPackageSha512 'python' $ver) 'SHA512' "python.$ver.nupkg"

    Write-Host "  Rozpakowuje do $PythonDir"
    $extract = Join-Path $Temp 'python-pkg'
    New-Item -ItemType Directory -Force -Path $extract | Out-Null
    & $Tar -xf $pkg -C $extract
    if ($LASTEXITCODE -ne 0) { throw 'Rozpakowanie Pythona nie powiodlo sie.' }
    Move-Item (Join-Path $extract 'tools') $PythonDir
    Write-Host "  Zainstalowano: $(& (Join-Path $PythonDir 'python.exe') --version)" -ForegroundColor Green
}

# --- .NET SDK (zip) --------------------------------------------------------------
# Kilka SDK rozpakowanych do jednego folderu dziala obok siebie (dotnet --list-sdks).
# Kanaly sa instalowane od najstarszego, aby wspolne pliki (dotnet.exe, host) pochodzily z najnowszego.
Write-Step '.NET SDK'
if (Test-NeedsInstall $DotnetDir '.NET SDK') {
    New-Item -ItemType Directory -Force -Path $DotnetDir | Out-Null
    foreach ($channel in ($DotnetChannels | Sort-Object { [version]$_ })) {
        $meta = Invoke-RestMethod "https://builds.dotnet.microsoft.com/dotnet/release-metadata/$channel/releases.json"
        $sdkVer = $meta.'latest-sdk'
        $sdk = $meta.releases | ForEach-Object { $_.sdks } | Where-Object { $_.version -eq $sdkVer } | Select-Object -First 1
        $file = $sdk.files | Where-Object { $_.name -eq 'dotnet-sdk-win-x64.zip' } | Select-Object -First 1
        if (-not $file) { throw "Nie znaleziono paczki .NET SDK $sdkVer (win-x64 zip) w kanale $channel." }

        $zip = Join-Path $Temp "dotnet-sdk-$sdkVer-win-x64.zip"
        Get-File $file.url $zip
        Assert-FileHash $zip $file.hash 'SHA512' ".NET SDK $sdkVer"

        Write-Host "  Rozpakowuje .NET SDK $sdkVer do $DotnetDir"
        & $Tar -xf $zip -C $DotnetDir
        if ($LASTEXITCODE -ne 0) { throw "Rozpakowanie .NET SDK $sdkVer nie powiodlo sie." }
    }
    $env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
    $env:DOTNET_NOLOGO = '1'
    Write-Host '  Zainstalowane SDK:' -ForegroundColor Green
    & (Join-Path $DotnetDir 'dotnet.exe') --list-sdks | ForEach-Object { Write-Host "    $_" -ForegroundColor Green }
}

# --- Git Extensions (portable zip) ------------------------------------------------
# Graficzny klient Git. Wymaga .NET Desktop Runtime 10 - jest w Tools\dotnet (SDK 10).
Write-Step 'Git Extensions'
if (Test-NeedsInstall $GitExtDir 'Git Extensions') {
    # Wersja portable dla x64 (wydanie zawiera tez wersje ARM64).
    $a = Get-GitHubReleaseAsset 'gitextensions/gitextensions' '(?i)^(?!.*arm).*portable.*\.zip$'
    if (-not $a.Sha256) { throw "Brak sumy SHA-256 dla $($a.Name) - przerywam (ustaw GITHUB_TOKEN, aby korzystac z API GitHub)." }
    $zip = Join-Path $Temp $a.Name
    Get-File $a.Url $zip
    Assert-FileHash $zip $a.Sha256 'SHA256' $a.Name
    Expand-ToolZip $zip $GitExtDir
    $exe = Get-ChildItem $GitExtDir -Filter 'GitExtensions.exe' -File -Recurse | Select-Object -First 1
    if (-not $exe) { throw "W paczce $($a.Name) nie ma GitExtensions.exe." }
    $arch = Get-PeMachine $exe.FullName
    if ($arch -ne 'x64') {
        Remove-Item -LiteralPath $GitExtDir -Recurse -Force
        throw "Pobrany Git Extensions jest dla architektury $arch, a nie x64 ($($a.Name)) - usuniety."
    }

    # IsPortable=False: ustawienia w %APPDATA%\GitExtensions (w Sandboxie przekierowane do Home),
    # bo folder programu w Tools jest w Sandboxie tylko do odczytu.
    $cfgFile = Join-Path $exe.DirectoryName 'GitExtensions.dll.config'
    if (Test-Path -LiteralPath $cfgFile) {
        $cfg = New-Object System.Xml.XmlDocument
        $cfg.PreserveWhitespace = $true
        $cfg.Load($cfgFile)
        $node = $cfg.SelectSingleNode("//setting[@name='IsPortable']/value")
        if ($node) { $node.InnerText = 'False'; $cfg.Save($cfgFile); Write-Host '  Ustawiono IsPortable=False (ustawienia w profilu uzytkownika).' }
        else { Write-Warning '  Brak ustawienia IsPortable w GitExtensions.dll.config - ustawienia moga nie byc zapisywane.' }
    }
    $sig = Get-AuthenticodeSignature -LiteralPath $exe.FullName
    Write-Host "  GitExtensions.exe: podpis $($sig.Status) $($sig.SignerCertificate.Subject)" -ForegroundColor DarkGray
    Write-Host "  Zainstalowano: Git Extensions $($exe.VersionInfo.ProductVersion)" -ForegroundColor Green
}

# --- Ustawienia domyslne w Home (tylko jesli jeszcze nie istnieja) -------------
Write-Step 'Ustawienia domyslne'

# Globalny .gitconfig dla Sandboxa (wskazywany przez GIT_CONFIG_GLOBAL).
# safe.directory = * jest potrzebne, bo pliki w zmapowanych folderach naleza do Twojego
# konta na hoscie, a w Sandboxie pracujesz jako WDAGUtilityAccount.
$gitConfig = Join-Path $HomeDir '.gitconfig'
if (-not (Test-Path $gitConfig)) {
    @"
[safe]
	directory = *
[init]
	defaultBranch = main
[core]
	autocrlf = true
"@ | Set-Content -Path $gitConfig -Encoding ASCII
    Write-Host '  Utworzono Home\.gitconfig'
}

# Ustawienia VS Code: wylaczamy probe samoaktualizacji (folder programu jest tylko do odczytu).
# claudeCode.environmentVariables: rozszerzenie Claude Code uzywa tej samej konfiguracji i historii
# rozmow (C:\SandBox\Home\.claude) co konsola - niezaleznie od tego, jak uruchomiono VS Code.
$codeSettings = Join-Path $HomeDir 'vscode-data\user-data\User\settings.json'
if (-not (Test-Path $codeSettings)) {
    @'
{
    "update.mode": "none",
    "terminal.integrated.defaultProfile.windows": "PowerShell",
    "claudeCode.environmentVariables": [
        { "name": "CLAUDE_CONFIG_DIR",         "value": "C:\\SandBox\\Home\\.claude" },
        { "name": "CLAUDE_CODE_GIT_BASH_PATH", "value": "C:\\SandBox\\Tools\\Git\\bin\\bash.exe" },
        { "name": "DISABLE_AUTOUPDATER",       "value": "1" }
    ]
}
'@ | Set-Content -Path $codeSettings -Encoding UTF8
    Write-Host '  Utworzono ustawienia VS Code'
}

# --- Sprzatanie ----------------------------------------------------------------
Write-Step 'Sprzatanie'
Remove-Item $Temp -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "`nGotowe! Uruchom Sandbox, klikajac dwukrotnie plik DevSandbox.wsb." -ForegroundColor Green
Write-Host "Projekty klonuj skryptem: $Root\Copy-ProjectToSandbox.ps1 <sciezka-lub-URL>  (w Sandboxie: C:\SandBox\Projects)."
Write-Host "Prace z Sandboxa przenos: 'Eksportuj zmiany' w Sandboxie, potem $Root\Import-SandboxWork.ps1 <nazwa>."