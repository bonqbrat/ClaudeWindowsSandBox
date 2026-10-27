<#
.SYNOPSIS
    Startup script run automatically INSIDE Windows Sandbox (LogonCommand in DevSandbox.wsb).

.DESCRIPTION
    - sets PATH and environment variables for Git, Node.js, VS Code and Claude Code,
    - redirects settings (Claude login, .gitconfig, VS Code extensions) to C:\SandBox\Home,
      so they survive closing the Sandbox,
    - creates desktop shortcuts and opens a terminal in the projects folder.
#>

$ErrorActionPreference = 'Continue'

$Root     = 'C:\SandBox'
$Tools    = "$Root\Tools"
$HomeDir  = "$Root\Home"
$Projects = "$Root\Projects"

# --- Script execution policy -------------------------------------------------------
# npm creates a claude.ps1 wrapper, and the default policy in the Sandbox (Restricted) blocks .ps1 scripts.
# RemoteSigned allows running local scripts but blocks unsigned ones downloaded from the internet.
# The warning "overridden by a policy defined at a more specific scope" is expected
# (this process runs with -ExecutionPolicy Bypass) - the setting is saved anyway.
try {
    Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force -ErrorAction Stop
} catch { }

# --- Environment variables -------------------------------------------------------
$vars = [ordered]@{
    CLAUDE_CONFIG_DIR         = "$HomeDir\.claude"          # Claude Code login and settings (persistent)
    CLAUDE_CODE_GIT_BASH_PATH = "$Tools\Git\bin\bash.exe"   # Git Bash for the Bash tool in Claude Code
    DISABLE_AUTOUPDATER       = '1'                          # Tools is read-only; update with the script on the host
    GIT_CONFIG_GLOBAL         = "$HomeDir\.gitconfig"        # global Git configuration (persistent)
    VSCODE_PORTABLE           = "$HomeDir\vscode-data"       # VS Code data and extensions (persistent)
    PYTHONPYCACHEPREFIX       = "$env:LOCALAPPDATA\pycache"  # Tools\Python is read-only
    DOTNET_ROOT               = "$Tools\dotnet"              # .NET SDK 8 and 10 (read-only)
    DOTNET_CLI_TELEMETRY_OPTOUT = '1'
    DOTNET_NOLOGO             = '1'
    NUGET_PACKAGES            = "$HomeDir\.nuget\packages"   # NuGet package cache (persistent - faster restore)
    npm_config_cache          = "$HomeDir\.npm-cache"        # npm cache (persistent - faster npm ci)
    npm_config_prefix         = "$HomeDir\npm-global"        # npm install -g (Tools\node is read-only)
    NG_CLI_ANALYTICS          = 'false'                      # ng does not ask about telemetry in every session
    HISTFILE                  = 'C:/SandBox/Home/.bash_history' # Git Bash command history (persistent)
}
# Karma tests (karma-chrome-launcher) - Edge from the Sandbox instead of Chrome
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

# --- PowerShell command history (Up arrow / Ctrl+R) --------------------------------------
# The PowerShell profile (Documents) is created on every start and redirects the PSReadLine history to Home,
# so it survives closing the Sandbox. Works in the VS Code terminal and in every PowerShell console.
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

# --- Git Extensions settings (persistent) --------------------------------------------------
# Git Extensions (IsPortable=False) saves its settings in %APPDATA%\GitExtensions - we redirect it to Home.
$gitExtHome  = "$HomeDir\GitExtensions"
$gitExtLocal = "$env:APPDATA\GitExtensions"
New-Item -ItemType Directory -Force -Path $gitExtHome | Out-Null
if (-not (Test-Path -LiteralPath $gitExtLocal)) { New-Item -ItemType Junction -Path $gitExtLocal -Value $gitExtHome | Out-Null }

# --- Variables for programs started from shortcuts -----------------------------------------
# Explorer (and therefore programs started from shortcuts) may not see variables set
# during logon. Without CLAUDE_CONFIG_DIR the Claude extension in VS Code would look for the conversation
# history in the Sandbox profile instead of C:\SandBox\Home\.claude. So the shortcuts load the variables explicitly.
$BinDir = "$env:LOCALAPPDATA\SandboxBin"
New-Item -ItemType Directory -Force -Path $BinDir | Out-Null
$EnvScript = "$BinDir\Sandbox-Env.ps1"

# $SandboxProject: the project most recently cloned by Copy-ProjectToSandbox.ps1 (name in Scripts\last-project.txt,
# a read-only folder in the Sandbox). Read on every shortcut launch; when the project is missing - Projects.
# Note: do not open C:\SandBox\Projects itself in VS Code - as the root of a mapped folder it has
# a realpath with a trailing backslash, which prevents the Claude extension from finding the conversation history.
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
$gitExtExe = Get-ChildItem "$Tools\GitExtensions" -Filter 'GitExtensions.exe' -File -Recurse -ErrorAction SilentlyContinue |
             Select-Object -First 1 -ExpandProperty FullName
if ($gitExtExe) {
    $gitExtLauncher = New-Launcher 'Start-GitExtensions' (@'
Start-Process -FilePath '__GITEXT__' -ArgumentList 'browse', ('"' + $SandboxProject + '"') -WorkingDirectory $SandboxProject
'@ -replace '__GITEXT__', $gitExtExe)
}
$hidden = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File'

# --- Desktop shortcuts -------------------------------------------------------------
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
if ($gitExtExe) {
    New-Shortcut -Name 'Git Extensions' -Target 'powershell.exe' -Arguments "$hidden `"$gitExtLauncher`"" `
                 -Icon "$gitExtExe,0"
}
New-Shortcut -Name 'Claude Code'        -Target 'powershell.exe' `
             -Arguments "-NoExit -ExecutionPolicy Bypass -File `"$claudeLauncher`"" `
             -Icon "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe,0"
New-Shortcut -Name 'Projects'           -Target $Projects
New-Shortcut -Name 'Export changes'     -Target 'powershell.exe' `
             -Arguments "-NoExit -ExecutionPolicy Bypass -File `"$Root\Scripts\Export-SandboxWork.ps1`"" `
             -Icon "$env:SystemRoot\System32\shell32.dll,45"

# --- Welcome terminal -------------------------------------------------------------
$welcome = @'
Write-Host 'Windows Sandbox - development environment' -ForegroundColor Cyan
Write-Host ('  git    : ' + (git --version))
Write-Host ('  node   : ' + (node --version) + ', npm ' + (npm --version))
if (Test-Path 'C:\SandBox\Tools\angular-cli\node_modules\@angular\cli\package.json') {
    Write-Host ('  ng     : ' + (Get-Content 'C:\SandBox\Tools\angular-cli\node_modules\@angular\cli\package.json' -Raw | ConvertFrom-Json).version)
}
Write-Host ('  claude : ' + (claude --version))
Write-Host ('  python : ' + (python --version))
Write-Host ('  dotnet : SDK ' + ((dotnet --list-sdks | ForEach-Object { ($_ -split ' ')[0] }) -join ', '))
Write-Host ''
Write-Host 'Commands: claude (Claude Code), code . (VS Code), git, python, dotnet, ng' -ForegroundColor DarkGray
Write-Host 'Save projects in C:\SandBox\Projects - all other files disappear when the Sandbox is closed.' -ForegroundColor Yellow
Write-Host 'To move work to the host: the "Export changes" shortcut, then Import-SandboxWork.ps1 on the host.' -ForegroundColor Yellow
'@
$encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($welcome))
. $EnvScript   # sets $SandboxProject
Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoExit', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded `
              -WorkingDirectory $SandboxProject
