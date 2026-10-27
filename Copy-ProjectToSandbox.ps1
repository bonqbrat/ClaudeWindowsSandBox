<#
.SYNOPSIS
    Clones a project into E:\SandBox\Projects to work on it in Windows Sandbox.

.DESCRIPTION
    Run ON THE HOST. The source can be:
      - a local repository (e.g. D:\Repos\MyProject) - cloned without hardlinks, so the Sandbox
        has no access to the original's files; origin in the copy points to the original's remote repo,
      - a repository URL (cloned using the host's credentials; the credentials do
        NOT reach the Sandbox, and a login/token in an https URL is removed).

    The name -> target folder mapping is saved in E:\SandBox\ProjectMap.json
    (outside the folders mapped into the Sandbox, so the Sandbox cannot change it).
    It is used by Import-SandboxWork.ps1.

.PARAMETER Source
    Path to a local repository or a URL.

.PARAMETER Name
    Folder name in Projects (default: the repository name).

.PARAMETER Target
    Folder on the host into which Import-SandboxWork.ps1 will bring the changes.
    Default: Source, if it is a local repository.

.PARAMETER Branch
    Branch to check out (default: the source's current branch / the remote repo's default branch).

.PARAMETER Force
    If the project is already in Projects - overwrite it without asking (with a backup, unless -NoBackup).

.PARAMETER NoBackup
    When overwriting, delete the previous copy instead of moving it to Projects\.backup (no backup prompt).

.EXAMPLE
    E:\SandBox\Copy-ProjectToSandbox.ps1 D:\Repos\MyProject
.EXAMPLE
    E:\SandBox\Copy-ProjectToSandbox.ps1 https://gitlab.example.com/team/project.git -Target D:\Repos\project
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
    [string]$Root      # environment folder - defaults to where this script is located
)

$ErrorActionPreference = 'Stop'
# $PSScriptRoot as a default value in param() is empty in Windows PowerShell 5.1 - resolve it here.
if (-not $Root) { $Root = Split-Path -Parent $MyInvocation.MyCommand.Path }

$Git = (Get-Command git.exe -ErrorAction SilentlyContinue).Source
if (-not $Git) { $Git = Join-Path $Root 'Tools\Git\cmd\git.exe' }

function Invoke-Git {
    $out = & $Git @args
    if ($LASTEXITCODE -ne 0) { throw "git $($args -join ' ') - exit code $LASTEXITCODE" }
    $out
}

$Projects = Join-Path $Root 'Projects'
$MapFile  = Join-Path $Root 'ProjectMap.json'

$isLocal = Test-Path -LiteralPath $Source -PathType Container
if ($isLocal) {
    $Source = (Invoke-Git -C $Source rev-parse --show-toplevel) -replace '/', '\'
    if (-not $Target) { $Target = $Source }
    $originUrl = & $Git -C $Source config --get remote.origin.url   # no message when origin does not exist
    if ($LASTEXITCODE -ne 0) { $originUrl = $null }
}
if (-not $Name) { $Name = (Split-Path ($Source.TrimEnd('\', '/')) -Leaf) -replace '\.git$', '' }
if ($Name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') { throw "Invalid project name: '$Name' (use -Name)." }

$dest = Join-Path $Projects $Name
if (Test-Path -LiteralPath $dest) {
    # Deliberately no "git status": the host does not run git in a repository modified in the Sandbox.
    Write-Warning "Project $Name is already in $dest."
    Write-Host '  Changes made in the Sandbox that have not been exported and imported will not be in the new copy.' -ForegroundColor Yellow
    $infoFile = Join-Path $Projects ".sandbox-export\$Name.json"
    $lastExport = 'never'
    if (Test-Path -LiteralPath $infoFile) {
        try { $lastExport = [string](Get-Content -LiteralPath $infoFile -Raw | ConvertFrom-Json).exportedAt } catch { }
    }
    Write-Host "  Last export from the Sandbox: $($lastExport.Substring(0, [Math]::Min(40, $lastExport.Length)))"

    if (-not $Force) {
        $answer = Read-Host "Overwrite $dest with a new clone of $Source ? [y/N]"
        if ($answer -notmatch '^(t|tak|y|yes)$') { Write-Host 'Aborted - nothing was changed.'; return }
        if (-not $NoBackup) {
            # Default YES (Enter) - the backup is instant and allows recovering changes.
            $answer = Read-Host "Keep the previous copy in $Projects\.backup ? [Y/n]"
            if ($answer -match '^(n|nie|no)$') { $NoBackup = $true }
        }
    }

    try {
        if ($NoBackup) {
            # rd /s /q does not descend into links (junction/symlink) - it removes only the links, not their targets.
            & cmd.exe /c rd /s /q $dest
            if (Test-Path -LiteralPath $dest) { throw 'failed to delete all files' }
            Write-Host '  Previous copy deleted.'
        } else {
            $backupDir = Join-Path $Projects '.backup'
            New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
            $backup = Join-Path $backupDir ('{0}-{1}' -f $Name, (Get-Date -Format 'yyyyMMdd-HHmmss'))
            Move-Item -LiteralPath $dest -Destination $backup   # rename - instant
            Write-Host "  Previous copy moved to: $backup" -ForegroundColor DarkGray
        }
    } catch {
        throw "Failed to free the folder $dest ($($_.Exception.Message)). Close the programs using the project in the Sandbox (VS Code, terminal, Claude) or close the Sandbox and try again."
    }
}

# --- Cloning ---------------------------------------------------------------------
$cloneArgs = @('clone')
if ($isLocal)           { $cloneArgs += '--no-hardlinks' }
if ($Branch)            { $cloneArgs += '--branch', $Branch }
if ($RecurseSubmodules) { $cloneArgs += '--recurse-submodules' }
$cloneArgs += '--', $Source, $dest

New-Item -ItemType Directory -Force -Path $Projects | Out-Null
Write-Host "Cloning $Source -> $dest" -ForegroundColor Cyan
Invoke-Git @cloneArgs

# origin in the copy: the original's remote repo (the host path is unreachable in the Sandbox anyway),
# without a login/token in the https URL.
$url = if ($isLocal) { $originUrl } else { $Source }
if ($url) {
    $url = $url -replace '^(https?://)[^/@]*@', '$1'
    Invoke-Git -C $dest remote set-url origin $url
} elseif ($isLocal) {
    Invoke-Git -C $dest remote remove origin
}

# --- Project map -------------------------------------------------------------------
$map = @{}
if (Test-Path $MapFile) {
    (Get-Content $MapFile -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $map[$_.Name] = $_.Value }
}
$map[$Name] = [ordered]@{ source = $Source; target = $Target; clonedAt = (Get-Date).ToString('s') }
$map | ConvertTo-Json | Set-Content -Path $MapFile -Encoding UTF8

# Current project: the shortcuts in the Sandbox (Claude Code, VS Code, Git Bash) open this folder.
# Scripts\ is read-only in the Sandbox, so the Sandbox cannot change this value.
New-Item -ItemType Directory -Force -Path (Join-Path $Root 'Scripts') | Out-Null
Set-Content -Path (Join-Path $Root 'Scripts\last-project.txt') -Value $Name -Encoding ASCII

# --- Git identity in the Sandbox (Home\.gitconfig), if not set yet ----------------------
$sbGitConfig = Join-Path $Root 'Home\.gitconfig'
foreach ($key in 'user.name', 'user.email') {
    $current = & $Git config --file $sbGitConfig $key
    if (-not $current) {
        $value = & $Git config --global $key
        if ($value) {
            Invoke-Git config --file $sbGitConfig $key $value
            Write-Host "  Set $key in Home\.gitconfig"
        }
    }
}

Write-Host "`nDone. In the Sandbox: C:\SandBox\Projects\$Name" -ForegroundColor Green
if ($Target) {
    Write-Host "Changes will return to: $Target  (Export-SandboxWork in the Sandbox, then Import-SandboxWork.ps1 $Name)"
} else {
    Write-Host 'Target folder is not set - pass -Target when importing.' -ForegroundColor Yellow
}
