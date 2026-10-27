<#
.SYNOPSIS
    Exports work from projects in the Sandbox (commits + uncommitted changes) to a git bundle file.

.DESCRIPTION
    Run INSIDE Windows Sandbox (the "Export changes" desktop shortcut).
    For each repository it:
      - takes a snapshot of the working tree (modified, new and deleted files; honoring .gitignore)
        as the commit refs/sandbox/wip - using a temporary index, so it does NOT change
        either the working tree or the staged changes,
      - records refs/sandbox/head (the current HEAD),
      - creates C:\SandBox\Projects\.sandbox-export\<name>.bundle (+ <name>.json with a description).

    On the host the changes are brought over by Import-SandboxWork.ps1 (git fetch from the bundle + git apply).
    A bundle is pure data - the host does not need to run git in a repository modified in the Sandbox.

.PARAMETER Path
    Repository folder(s). Default: all repositories in C:\SandBox\Projects.

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
    if ($LASTEXITCODE -ne 0) { throw "git $($args -join ' ') - exit code $LASTEXITCODE" }
    $out
}

$ExportDir = Join-Path $ProjectsRoot '.sandbox-export'

if (-not $Path) {
    $Path = Get-ChildItem -LiteralPath $ProjectsRoot -Directory |
            Where-Object { $_.Name -notlike '.*' -and (Test-Path (Join-Path $_.FullName '.git')) } |
            ForEach-Object { $_.FullName }
    if (-not $Path) { Write-Warning "No repositories in $ProjectsRoot."; return }
}

New-Item -ItemType Directory -Force -Path $ExportDir | Out-Null
$failed = 0

foreach ($p in $Path) {
    try {
        $top  = Invoke-Git -C $p rev-parse --show-toplevel
        $name = Split-Path $top -Leaf
        Write-Host "`n=== $name ===" -ForegroundColor Cyan

        $head = & $Git -C $top rev-parse -q --verify 'HEAD^{commit}'
        if ($LASTEXITCODE -ne 0) { Write-Warning '  The repository has no commits yet - skipping.'; continue }
        $branch = & $Git -C $top symbolic-ref --short -q HEAD
        if ($LASTEXITCODE -ne 0) { $branch = $null }

        # Snapshot of the working tree in a temporary index (the real index stays untouched).
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
                $wip = Invoke-Git -C $top commit-tree $tree -p $head -m 'sandbox: uncommitted changes'
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

        $state = if ($dirty) { 'with uncommitted changes' } else { 'no uncommitted changes' }
        Write-Host "  Branch: $(if ($branch) { $branch } else { '(detached HEAD)' }), HEAD $($head.Substring(0, 10)), $state"
        if ($dirty) { Invoke-Git -C $top diff --stat --no-color $head $wip | Select-Object -Last 1 | ForEach-Object { Write-Host "  $_" } }
        Write-Host "  Saved: $bundle" -ForegroundColor Green
    } catch {
        $failed++
        Write-Host "  ERROR ($p): $_" -ForegroundColor Red
    }
}

Write-Host "`nOn the host run: <environment folder>\Import-SandboxWork.ps1 <project-name>" -ForegroundColor Yellow
if ($failed) { exit 1 }
