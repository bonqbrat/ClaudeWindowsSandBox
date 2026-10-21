<#
.SYNOPSIS
    Skrypt startowy uruchamiany automatycznie WEWNATRZ Windows Sandbox (LogonCommand w DevSandbox.wsb).

.DESCRIPTION
    - ustawia PATH i zmienne srodowiskowe dla Git, Node.js, VS Code i Claude Code,
    - kieruje ustawienia (logowanie Claude, .gitconfig, rozszerzenia VS Code) do C:\SandBox\Home,
      dzieki czemu przetrwaja zamkniecie Sandboxa,
    - tworzy skroty na pulpicie i otwiera terminal w folderze projektow.
#>

$ErrorActionPreference = 'Continue'

$Root     = 'C:\SandBox'
$Tools    = "$Root\Tools"
$HomeDir  = "$Root\Home"
$Projects = "$Root\Projects"

# --- Zasady wykonywania skryptow ---------------------------------------------------
# npm tworzy nakladke claude.ps1, a domyslna polityka w Sandboxie (Restricted) blokuje skrypty .ps1.
# RemoteSigned pozwala uruchamiac lokalne skrypty, ale blokuje niepodpisane pobrane z internetu.
# Ostrzezenie "overridden by a policy defined at a more specific scope" jest oczekiwane
# (ten proces dziala z -ExecutionPolicy Bypass) - ustawienie i tak zostaje zapisane.
try {
    Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force -ErrorAction Stop
} catch { }

# --- Zmienne srodowiskowe --------------------------------------------------------
$vars = [ordered]@{
    CLAUDE_CONFIG_DIR         = "$HomeDir\.claude"          # logowanie i ustawienia Claude Code (trwale)
    CLAUDE_CODE_GIT_BASH_PATH = "$Tools\Git\bin\bash.exe"   # Git Bash dla narzedzia Bash w Claude Code
    DISABLE_AUTOUPDATER       = '1'                          # Tools jest tylko do odczytu; aktualizuj skryptem na hoscie
    GIT_CONFIG_GLOBAL         = "$HomeDir\.gitconfig"        # globalna konfiguracja Git (trwala)
    VSCODE_PORTABLE           = "$HomeDir\vscode-data"       # dane i rozszerzenia VS Code (trwale)
    PYTHONPYCACHEPREFIX       = "$env:LOCALAPPDATA\pycache"  # Tools\Python jest tylko do odczytu
    DOTNET_ROOT               = "$Tools\dotnet"              # .NET SDK 8 i 10 (tylko do odczytu)
    DOTNET_CLI_TELEMETRY_OPTOUT = '1'
    DOTNET_NOLOGO             = '1'
    NUGET_PACKAGES            = "$HomeDir\.nuget\packages"   # cache pakietow NuGet (trwaly - szybszy restore)
    npm_config_cache          = "$HomeDir\.npm-cache"        # cache npm (trwaly - szybsze npm ci)
    npm_config_prefix         = "$HomeDir\npm-global"        # npm install -g (Tools\node jest tylko do odczytu)
    NG_CLI_ANALYTICS          = 'false'                      # ng nie pyta o telemetrie w kazdej sesji
    HISTFILE                  = 'C:/SandBox/Home/.bash_history' # historia polecen Git Bash (trwala)
}
# Testy Karma (karma-chrome-launcher) - Edge z Sandboxa zamiast Chrome
$edge = "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe" |
        Where-Object { Test-Path $_ } | Select-Object -First 1
if ($edge) { $vars['CHROME_BIN'] = $edge }
foreach ($name in $vars.Keys) {
    [Environment]::SetEnvironmentVariable($name, $vars[$name], 'User')
    Set-Item -Path "env:$name" -Value $vars[$name]
}

$addToPath = @(
    "$Tools\Git\cmd",
    "$Tools\node",
    "$Tools\claude-code",
    "$Tools\VSCode\bin",
    "$Tools\Python",
    "$Tools\Python\Scripts",
    "$Tools\dotnet",
    "$Tools\angular-cli",
    "$HomeDir\npm-global"
)
New-Item -ItemType Directory -Force -Path "$HomeDir\npm-global" | Out-Null
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$newPath  = (($addToPath + ($userPath -split ';')) | Where-Object { $_ } | Select-Object -Unique) -join ';'
[Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
$env:Path = ($addToPath -join ';') + ';' + $env:Path

# --- Historia polecen PowerShell (strzalka w gore / Ctrl+R) ------------------------------
# Profil PowerShell (Dokumenty) jest tworzony przy kazdym starcie i kieruje historie PSReadLine do Home,
# dzieki czemu przetrwa zamkniecie Sandboxa. Dziala w terminalu VS Code i w kazdej konsoli PowerShell.
$psHistory = "$HomeDir\PowerShell\ConsoleHost_history.txt"
New-Item -ItemType Directory -Force -Path (Split-Path $psHistory) | Out-Null
$profileText = @'
if ($Host.Name -eq 'ConsoleHost') {
    try { Set-PSReadLineOption -HistorySavePath '__HISTORY__' -HistorySaveStyle SaveIncrementally } catch { }
}
'@ -replace '__HISTORY__', $psHistory
$documents = [Environment]::GetFolderPath('MyDocuments')
foreach ($dir in "$documents\WindowsPowerShell", "$documents\PowerShell") {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Set-Content -Path "$dir\profile.ps1" -Value $profileText -Encoding UTF8
}

# --- Zmienne dla programow uruchamianych ze skrotow ---------------------------------------
# Eksplorator (a wiec i programy uruchamiane ze skrotow) moze nie widziec zmiennych ustawionych
# w trakcie logowania. Bez CLAUDE_CONFIG_DIR rozszerzenie Claude w VS Code szukaloby historii rozmow
# w profilu Sandboxa zamiast w C:\SandBox\Home\.claude. Skroty wczytuja wiec zmienne jawnie.
$BinDir = "$env:LOCALAPPDATA\SandboxBin"
New-Item -ItemType Directory -Force -Path $BinDir | Out-Null
$EnvScript = "$BinDir\Sandbox-Env.ps1"

# $SandboxProject: projekt ostatnio sklonowany przez Copy-ProjectToSandbox.ps1 (nazwa w Scripts\last-project.txt,
# folder tylko do odczytu w Sandboxie). Odczytywany przy kazdym uruchomieniu skrotu; gdy projektu brak - Projects.
# Uwaga: nie otwieraj w VS Code samego C:\SandBox\Projects - jako katalog glowny zmapowanego folderu ma on
# realpath z ukosnikiem na koncu, przez co rozszerzenie Claude nie znajduje historii rozmow.
$projectBlock = @'
$SandboxProject = '__PROJECTS__'
try {
    $lastName = (Get-Content -LiteralPath '__LASTFILE__' -TotalCount 1 -ErrorAction Stop).Trim()
    if ($lastName -match '^[A-Za-z0-9][A-Za-z0-9._-]*$' -and (Test-Path -LiteralPath "__PROJECTS__\$lastName" -PathType Container)) {
        $SandboxProject = "__PROJECTS__\$lastName"
    }
} catch { }
'@ -replace '__PROJECTS__', $Projects -replace '__LASTFILE__', "$Root\Scripts\last-project.txt"

(@($vars.Keys | ForEach-Object { "`$env:$_ = '$($vars[$_])'" }) + "`$env:Path = '$env:Path'" + $projectBlock) |
    Set-Content -Path $EnvScript -Encoding UTF8

function New-Launcher([string]$Name, [string]$Command) {
    $path = "$BinDir\$Name.ps1"
    ". '$EnvScript'", $Command | Set-Content -Path $path -Encoding UTF8
    $path
}
$codeLauncher = New-Launcher 'Start-VSCode' (@'
Start-Process -FilePath '__CODE__' -ArgumentList ('"' + $SandboxProject + '"')
'@ -replace '__CODE__', "$Tools\VSCode\Code.exe")
$bashLauncher = New-Launcher 'Start-GitBash' (@'
Start-Process -FilePath '__BASH__' -ArgumentList ('--cd="' + $SandboxProject + '"') -WorkingDirectory $SandboxProject
'@ -replace '__BASH__', "$Tools\Git\git-bash.exe")
$claudeLauncher = New-Launcher 'Start-Claude' (@'
Set-Location -LiteralPath $SandboxProject
claude
'@)
$hidden = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File'

# --- Skroty na pulpicie -----------------------------------------------------------
$shell   = New-Object -ComObject WScript.Shell
$desktop = [Environment]::GetFolderPath('Desktop')

function New-Shortcut {
    param([string]$Name, [string]$Target, [string]$Arguments = '', [string]$WorkDir = $Projects, [string]$Icon = '')
    $lnk = $shell.CreateShortcut((Join-Path $desktop "$Name.lnk"))
    $lnk.TargetPath       = $Target
    $lnk.Arguments        = $Arguments
    $lnk.WorkingDirectory = $WorkDir
    if ($Icon) { $lnk.IconLocation = $Icon }
    $lnk.Save()
}

New-Shortcut -Name 'Visual Studio Code' -Target 'powershell.exe' -Arguments "$hidden `"$codeLauncher`"" `
             -Icon "$Tools\VSCode\Code.exe,0"
New-Shortcut -Name 'Git Bash'           -Target 'powershell.exe' -Arguments "$hidden `"$bashLauncher`"" `
             -Icon "$Tools\Git\git-bash.exe,0"
New-Shortcut -Name 'Claude Code'        -Target 'powershell.exe' `
             -Arguments "-NoExit -ExecutionPolicy Bypass -File `"$claudeLauncher`"" `
             -Icon "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe,0"
New-Shortcut -Name 'Projekty'           -Target $Projects
New-Shortcut -Name 'Eksportuj zmiany'   -Target 'powershell.exe' `
             -Arguments "-NoExit -ExecutionPolicy Bypass -File `"$Root\Scripts\Export-SandboxWork.ps1`"" `
             -Icon "$env:SystemRoot\System32\shell32.dll,45"

# --- Terminal powitalny -----------------------------------------------------------
$welcome = @'
Write-Host 'Windows Sandbox - srodowisko programistyczne' -ForegroundColor Cyan
Write-Host ('  git    : ' + (git --version))
Write-Host ('  node   : ' + (node --version) + ', npm ' + (npm --version))
if (Test-Path 'C:\SandBox\Tools\angular-cli\node_modules\@angular\cli\package.json') {
    Write-Host ('  ng     : ' + (Get-Content 'C:\SandBox\Tools\angular-cli\node_modules\@angular\cli\package.json' -Raw | ConvertFrom-Json).version)
}
Write-Host ('  claude : ' + (claude --version))
Write-Host ('  python : ' + (python --version))
Write-Host ('  dotnet : SDK ' + ((dotnet --list-sdks | ForEach-Object { ($_ -split ' ')[0] }) -join ', '))
Write-Host ''
Write-Host 'Polecenia: claude (Claude Code), code . (VS Code), git, python, dotnet' -ForegroundColor DarkGray
Write-Host 'Projekty zapisuj w C:\SandBox\Projects - pozostale pliki znikna po zamknieciu Sandboxa.' -ForegroundColor Yellow
Write-Host 'Aby przeniesc prace na hosta: skrot "Eksportuj zmiany", potem na hoscie Import-SandboxWork.ps1.' -ForegroundColor Yellow
'@
$encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($welcome))
. $EnvScript   # ustawia $SandboxProject
Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoExit', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded `
              -WorkingDirectory $SandboxProject