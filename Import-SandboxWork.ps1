<#
.SYNOPSIS
    Brings work from the Sandbox (commits + uncommitted changes) into the target folder on the host.

.DESCRIPTION
    Run ON THE HOST, after running Export-SandboxWork.ps1 in the Sandbox.
      1. git fetch from E:\SandBox\Projects\.sandbox-export\<name>.bundle:
           branches from the Sandbox -> refs/remotes/sandbox/*   (e.g. sandbox/main)
           HEAD from the Sandbox     -> refs/sandbox/head
           changes snapshot          -> refs/sandbox/wip
      2. (optionally, -FastForward) moves the current branch forward to the commits from the Sandbox,
      3. applies the uncommitted changes from the Sandbox (git apply) to the target's working tree
         - first shows the list of files and asks for confirmation,
         - saves the target's own uncommitted changes as a backup refs/sandbox/backup/<date>,
      4. after a successful apply removes the helper refs refs/sandbox/head and refs/sandbox/wip, so the
         snapshot is not visible in the history (e.g. as a "branch" sandbox/wip in Git Extensions / VS Code).
         They are kept when the changes were not applied (-NoApply, declined, conflict) - files can be taken from them.

    The script does not run git in the repository modified in the Sandbox - it only reads the bundle file.

.PARAMETER Name
    Project name (folder in E:\SandBox\Projects).

.PARAMETER Target
    Target repository. Default: from ProjectMap.json (saved by Copy-ProjectToSandbox.ps1).

.PARAMETER FastForward
    If the Sandbox has new commits on the same branch - move the target's branch (merge --ff-only).

.PARAMETER ThreeWay
    If the changes do not apply cleanly - use git apply --3way (conflicts to be resolved manually).

.PARAMETER NoApply
    Only git fetch, without applying the uncommitted changes.

.PARAMETER Yes
    Do not ask for confirmation.

.EXAMPLE
    E:\SandBox\Import-SandboxWork.ps1 MyProject
.EXAMPLE
    E:\SandBox\Import-SandboxWork.ps1 MyProject -FastForward -ThreeWay
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)][string]$Name,
    [string]$Target,
    [switch]$FastForward,
    [switch]$ThreeWay,
    [switch]$NoApply,
    [switch]$Yes,
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

if ($Name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') { throw "Invalid project name: '$Name'." }

$ExportDir = Join-Path $Root 'Projects\.sandbox-export'
$bundle    = Join-Path $ExportDir "$Name.bundle"
$infoFile  = Join-Path $ExportDir "$Name.json"
$MapFile   = Join-Path $Root 'ProjectMap.json'

if (-not (Test-Path -LiteralPath $bundle)) {
    throw "Missing $bundle. First run the 'Export changes' shortcut in the Sandbox (C:\SandBox\Scripts\Export-SandboxWork.ps1)."
}

if (-not $Target -and (Test-Path $MapFile)) {
    $entry = (Get-Content $MapFile -Raw | ConvertFrom-Json).$Name
    if ($entry) { $Target = $entry.target }
}
if (-not $Target) { throw "Unknown target folder for '$Name' - pass -Target." }
$Target = (Invoke-Git -C $Target rev-parse --show-toplevel) -replace '/', '\'

# The .json file comes from the Sandbox - treat it as untrusted (informational only + validation).
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
    } catch { Write-Warning "Failed to read $infoFile - skipping." }
}

Write-Host "Project : $Name  (exported from the Sandbox: $exportedAt)" -ForegroundColor Cyan
Write-Host "Target  : $Target"

# --- 1. git fetch from the bundle ---------------------------------------------------------
Invoke-Git -C $Target bundle verify -q $bundle | Out-Null
Invoke-Git -C $Target fetch --no-tags $bundle `
    '+refs/heads/*:refs/remotes/sandbox/*' '+refs/sandbox/head:refs/sandbox/head' '+refs/sandbox/wip:refs/sandbox/wip'

$sbHead = Invoke-Git -C $Target rev-parse 'refs/sandbox/head^{commit}'
$wip    = Invoke-Git -C $Target rev-parse 'refs/sandbox/wip^{commit}'
$tHead  = Invoke-Git -C $Target rev-parse 'HEAD^{commit}'
$tBranch = & $Git -C $Target symbolic-ref --short -q HEAD
if ($LASTEXITCODE -ne 0) { $tBranch = $null }

Write-Host "Branch in the Sandbox: $(if ($sbBranch) { $sbBranch } else { '?' }), in the target: $(if ($tBranch) { $tBranch } else { '(detached HEAD)' })"

# Helper snapshot refs - removed when no longer needed (otherwise Git tools show the snapshot
# as a separate branch with uncommitted changes). The objects stay in the reflog/database until gc anyway.
function Remove-SandboxRefs {
    foreach ($ref in 'refs/sandbox/wip', 'refs/sandbox/head') {
        & $Git -C $Target update-ref -d $ref 2>$null
    }
}

# --- 2. Commits from the Sandbox ------------------------------------------------------------
if ($sbHead -ne $tHead) {
    & $Git -C $Target merge-base --is-ancestor $tHead $sbHead
    $canFastForward = ($LASTEXITCODE -eq 0)
    $newCommits = Invoke-Git -C $Target log --oneline --no-decorate --no-color "$tHead..$sbHead"
    if ($newCommits) {
        Write-Host "`nNew commits from the Sandbox:" -ForegroundColor Cyan
        $newCommits | ForEach-Object { Write-Host "  $_" }
    }

    if ($FastForward -and $canFastForward -and $tBranch -and $tBranch -eq $sbBranch) {
        Write-Host "Moving branch $tBranch (fast-forward)..."
        Invoke-Git -C $Target merge --ff-only $sbHead
    } elseif ($FastForward -and -not $canFastForward) {
        Write-Warning "The histories in the Sandbox and in the target have diverged - fast-forward not possible. Merge manually: git merge sandbox/$sbBranch"
    } elseif ($FastForward) {
        Write-Warning "The target branch ($tBranch) differs from the branch in the Sandbox ($sbBranch) - skipping fast-forward."
    } else {
        Write-Host "Commits are available as sandbox/<branch> (e.g. git merge --ff-only sandbox/$sbBranch), or use -FastForward." -ForegroundColor DarkGray
    }
}

# --- 3. Uncommitted changes ----------------------------------------------------------------
if ($NoApply) { Write-Host "`nSkipped applying changes (-NoApply). Snapshot: refs/sandbox/wip"; return }
if ($wip -eq $sbHead) { Remove-SandboxRefs; Write-Host "`nThere were no uncommitted changes in the Sandbox." -ForegroundColor Green; return }

Write-Host "`nUncommitted changes from the Sandbox:" -ForegroundColor Cyan
Invoke-Git -C $Target diff --stat --no-color --no-ext-diff $sbHead $wip | ForEach-Object { Write-Host "  $_" }

if (-not $Yes) {
    $answer = Read-Host "`nApply these changes to the working tree of $Target ? [y/N]"
    if ($answer -notmatch '^(t|tak|y|yes)$') { Write-Host 'Aborted. The changes are available in refs/sandbox/wip.'; return }
}

# Backup of the target's own uncommitted changes (tracked files) - to restore: git stash apply <sha>
$backup = Invoke-Git -C $Target stash create
if ($backup) {
    $backupRef = 'refs/sandbox/backup/' + (Get-Date -Format 'yyyyMMdd-HHmmss')
    Invoke-Git -C $Target update-ref $backupRef $backup
    Write-Host "Backup of changes in the target: $backupRef (restore: git stash apply $backupRef)" -ForegroundColor DarkGray
}

$patch = Join-Path $env:TEMP "sandbox-import-$Name-$PID.patch"
try {
    Invoke-Git -C $Target diff --binary --full-index --no-color --no-ext-diff --no-textconv `
        --src-prefix=a/ --dst-prefix=b/ "--output=$patch" $sbHead $wip

    & $Git -C $Target apply --check $patch
    if ($LASTEXITCODE -eq 0) {
        Invoke-Git -C $Target apply $patch
        Remove-SandboxRefs
        Write-Host "`nChanges applied to the working tree (nothing was committed)." -ForegroundColor Green
    } elseif ($ThreeWay) {
        Write-Warning 'The changes do not apply cleanly - trying git apply --3way.'
        & $Git -C $Target apply --3way $patch
        if ($LASTEXITCODE -ne 0) {
            Write-Warning 'Conflicts occurred - resolve them manually (git status). Note: --3way adds the changes to the index.'
            exit 1
        }
        Remove-SandboxRefs
        Write-Host "`nChanges applied (3-way). Note: --3way adds the changes to the index (git restore --staged .)." -ForegroundColor Green
    } else {
        Write-Warning "The changes do not apply cleanly. Run again with -ThreeWay, or take the files manually from refs/sandbox/wip (git checkout refs/sandbox/wip -- <file>)."
        exit 1
    }
} finally {
    Remove-Item $patch -Force -ErrorAction SilentlyContinue
}
