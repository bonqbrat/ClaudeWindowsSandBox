<#
.SYNOPSIS
    Prepares a folder with portable development tools for Windows Sandbox.

.DESCRIPTION
    Run ON THE HOST (not in the Sandbox). Downloads the latest versions of:
      - Git for Windows (PortableGit)
      - Node.js LTS (zip)
      - Visual Studio Code (zip)
      - Claude Code (npm package, installed into a separate prefix)
      - Angular CLI (npm package @angular/cli, installed into a separate prefix - the ng command)
      - Python (NuGet package "python" - a full, portable Python with pip and venv)
      - .NET SDK 8 and 10 (zip; C# compiler, .NET runtime, ASP.NET Core and Windows Desktop)
      - Git Extensions (portable zip; graphical Git client)
    and creates the folder structure mapped by DevSandbox.wsb (the environment folder can be located
    anywhere - E:\SandBox in the examples; the paths in DevSandbox.wsb are adjusted automatically):

      E:\SandBox\
        DevSandbox.wsb            - Sandbox configuration (double-click to start)
        Install-SandboxTools.ps1  - this script                                    (NOT visible in the Sandbox)
        Copy-ProjectToSandbox.ps1 - clones a project into Projects                 (NOT visible in the Sandbox)
        Import-SandboxWork.ps1    - brings work from the Sandbox to the target folder (NOT visible in the Sandbox)
        ProjectMap.json           - project name -> target folder                  (NOT visible in the Sandbox)
        Tools\                    - tools                (in the Sandbox: C:\SandBox\Tools,    read-only)
        Scripts\                  - Sandbox scripts      (in the Sandbox: C:\SandBox\Scripts,  read-only)
        Settings\ClaudeCode\      - Claude Code managed settings + hooks
                                                         (in the Sandbox: C:\Program Files\ClaudeCode, read-only)
        Home\                     - settings, Claude login, VS Code extensions
                                                         (in the Sandbox: C:\SandBox\Home,     writable)
        Projects\                 - your projects        (in the Sandbox: C:\SandBox\Projects, writable)

.PARAMETER Root
    Environment folder (default: the folder containing this script).

.PARAMETER Force
    Removes and reinstalls all tools (update to the latest versions).

.PARAMETER PythonVersion
    Specific Python version (e.g. 3.13.9). Default: the latest stable.

.PARAMETER AngularCliVersion
    Angular CLI version (e.g. 22). Default: the latest. The global ng uses the CLI version from the project's node_modules anyway.

.PARAMETER DotnetChannels
    .NET SDK versions to install (default 8.0 and 10.0) - always the latest release from the channel.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File E:\SandBox\Install-SandboxTools.ps1
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File E:\SandBox\Install-SandboxTools.ps1 -Force
#>
[CmdletBinding()]
param(
    [string]$Root,     # defaults to the folder containing this script
    [switch]$Force,
    [ValidatePattern('^\d+\.\d+\.\d+$')][string]$PythonVersion,            # full NuGet package version, e.g. 3.13.9
    [ValidatePattern('^\d+\.\d+$')][string[]]$DotnetChannels = @('8.0', '10.0'),
    [ValidatePattern('^(latest|\d+(\.\d+){0,2})$')][string]$AngularCliVersion = 'latest'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # greatly speeds up Invoke-WebRequest in PowerShell 5.1
# $PSScriptRoot as a default value in param() is empty in Windows PowerShell 5.1 - resolve it here.
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $Root) { $Root = $ScriptDir }
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$Tar = Join-Path $env:SystemRoot 'System32\tar.exe'   # built into Windows 10/11, faster than Expand-Archive

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
    Write-Host "  Downloading: $Url"
    Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -Headers @{ 'User-Agent' = 'SandboxToolsInstaller' }
}

function Get-Text([string]$Url) {
    $content = (Invoke-WebRequest -Uri $Url -UseBasicParsing -Headers @{ 'User-Agent' = 'SandboxToolsInstaller' }).Content
    if ($content -is [byte[]]) { $content = [Text.Encoding]::UTF8.GetString($content) }
    $content
}

# Verifies the hash of a downloaded file BEFORE extracting/running it; deletes the file on mismatch.
function Assert-FileHash([string]$Path, [string]$Expected, [string]$Algorithm, [string]$What) {
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm $Algorithm).Hash
    if (-not $Expected -or $actual -ne $Expected.Trim()) {
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
        throw "$Algorithm hash mismatch ($What) - file corrupted or tampered with, deleted. Expected: '$Expected', computed: '$actual'."
    }
    Write-Host "  $Algorithm hash OK: $What" -ForegroundColor DarkGray
}

# Verifies the Authenticode signature and publisher of an executable.
function Assert-Signature([string]$Path, [string]$PublisherPattern, [string]$What) {
    $sig = Get-AuthenticodeSignature -LiteralPath $Path
    if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch $PublisherPattern) {
        throw "Invalid digital signature ($What): status $($sig.Status), publisher '$($sig.SignerCertificate.Subject)'."
    }
    Write-Host "  Digital signature valid: $What ($($sig.SignerCertificate.GetNameInfo('SimpleName', $false)))" -ForegroundColor DarkGray
}

# SHA-512 of a NuGet package (hex). First the .sha512 file from the flat container, and if it is missing -
# the packageHash field (base64) from the NuGet catalog (registration -> catalog leaf).
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
    if (-not $b64) { throw "Failed to get the SHA-512 hash of NuGet package $Id $Version." }
    ([BitConverter]::ToString([Convert]::FromBase64String($b64)) -replace '-', '')
}

# Latest 64-bit PortableGit: { Name, Url, Sha256 }.
# 1) GitHub API (SHA-256 from the asset's "digest" field or from the hash table in the release notes). An optional
#    token in the GITHUB_TOKEN variable raises the request limit (without it: 60/h per IP address).
# 2) When the API refuses (e.g. limit exceeded): the release from the github.com/.../releases/latest redirect
#    (no API limit), the file URL from the release name, SHA-256 from the release page - if possible.
function Get-PortableGitRelease {
    $headers = @{ 'User-Agent' = 'SandboxToolsInstaller' }
    if ($env:GITHUB_TOKEN) { $headers['Authorization'] = "Bearer $env:GITHUB_TOKEN" }
    try {
        $release = Invoke-RestMethod 'https://api.github.com/repos/git-for-windows/git/releases/latest' -Headers $headers
        $asset = $release.assets | Where-Object { $_.name -match '^PortableGit-.*-64-bit\.7z\.exe$' } | Select-Object -First 1
        if (-not $asset) { throw 'PortableGit (64-bit) file not found in the latest Git for Windows release.' }
        $sha = $null
        if ($asset.digest -match '^sha256:([0-9a-fA-F]{64})$') { $sha = $Matches[1] }
        elseif ($release.body -match "$([regex]::Escape($asset.name))\s*\|\s*([0-9a-fA-F]{64})") { $sha = $Matches[1] }
        return [pscustomobject]@{ Name = $asset.name; Url = $asset.browser_download_url; Sha256 = $sha }
    } catch {
        Write-Warning "  GitHub API unavailable ($($_.Exception.Message.Split([Environment]::NewLine)[0])) - using the release page."
    }

    # Redirect /releases/latest -> /releases/tag/<tag>
    $req = [System.Net.HttpWebRequest]::Create('https://github.com/git-for-windows/git/releases/latest')
    $req.AllowAutoRedirect = $false
    $req.UserAgent = 'SandboxToolsInstaller'
    $resp = $req.GetResponse()
    try { $location = $resp.Headers['Location'] } finally { $resp.Close() }
    if ($location -notmatch '/releases/tag/(v(\d+\.\d+\.\d+)\.windows\.(\d+))$') {
        throw "Failed to determine the latest Git for Windows release (redirect: '$location')."
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

# Asset of the latest GitHub release matching the pattern: { Name, Url, Sha256 }.
# 1) GitHub API (SHA-256 from the "digest" field; optional token in GITHUB_TOKEN).
# 2) When the API refuses: tag from the /releases/latest redirect, file list and SHA-256 (digest shown
#    on the page) from /releases/expanded_assets/<tag>.
# Without "digest", SHA-256 from the release's checksum file (e.g. checksums.txt), if -ChecksumAsset is given.
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
        Write-Warning "  GitHub API unavailable for $Repo ($($_.Exception.Message.Split([Environment]::NewLine)[0])) - using the release page."
        $req = [System.Net.HttpWebRequest]::Create("https://github.com/$Repo/releases/latest")
        $req.AllowAutoRedirect = $false
        $req.UserAgent = 'SandboxToolsInstaller'
        $resp = $req.GetResponse()
        try { $location = $resp.Headers['Location'] } finally { $resp.Close() }
        if ($location -notmatch '/releases/tag/([^/?#]+)$') { throw "Failed to determine the latest release of $Repo." }
        $tag = $Matches[1]
        $html = Get-Text "https://github.com/$Repo/releases/expanded_assets/$tag"
        # SHA-256 shown on the page: <clipboard-copy aria-label="... digest for <file>" value="sha256:<hex>">
        $digests = @{}
        foreach ($tag in [regex]::Matches($html, '<clipboard-copy\b[^>]*>')) {
            $n = [regex]::Match($tag.Value, 'digest for ([^"]+)"')
            $h = [regex]::Match($tag.Value, 'value="sha256:([0-9a-fA-F]{64})"')
            if ($n.Success -and $h.Success) { $digests[[Net.WebUtility]::HtmlDecode($n.Groups[1].Value)] = $h.Groups[1].Value }
        }
        $assets = @([regex]::Matches($html, "href=""(/$([regex]::Escape($Repo))/releases/download/[^""]+)""") |
            ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique | ForEach-Object {
                $assetName = [Uri]::UnescapeDataString(($_ -split '/')[-1])
                [pscustomobject]@{ Name = $assetName; Url = "https://github.com$_"; Sha256 = $digests[$assetName] } })
    }
    $asset = $assets | Where-Object { $_.Name -match $AssetPattern } | Select-Object -First 1
    if (-not $asset) { throw "No file matching '$AssetPattern' found in release $tag ($Repo). Available: $(($assets.Name) -join ', ')" }
    if (-not $asset.Sha256 -and $ChecksumAsset) {
        $sumAsset = $assets | Where-Object { $_.Name -eq $ChecksumAsset } | Select-Object -First 1
        if ($sumAsset) {
            $sums = Get-Text $sumAsset.Url
            if ($sums -match "(?m)^([0-9a-fA-F]{64})\s+\*?$([regex]::Escape($asset.Name))\s*$") { $asset.Sha256 = $Matches[1] }
        }
    }
    Write-Host "  Release: $tag, file: $($asset.Name)"
    $asset
}

# Architecture of an executable (PE header): x64, ARM64, x86.
function Get-PeMachine([string]$Path) {
    $fs = [IO.File]::OpenRead($Path)
    try {
        $br = New-Object IO.BinaryReader($fs)
        $fs.Position = 0x3C; $fs.Position = $br.ReadInt32() + 4
        switch ($br.ReadUInt16()) { 0x8664 { 'x64' } 0xAA64 { 'ARM64' } 0x14C { 'x86' } default { 'unknown' } }
    } finally { $fs.Dispose() }
}

# Extracts a zip into the destination folder; if the zip has a single top-level folder - its contents.
function Expand-ToolZip([string]$Zip, [string]$Destination) {
    $extract = Join-Path $Temp ([IO.Path]::GetFileNameWithoutExtension($Zip))
    New-Item -ItemType Directory -Force -Path $extract | Out-Null
    & $Tar -xf $Zip -C $extract
    if ($LASTEXITCODE -ne 0) { throw "Extracting $Zip failed." }
    $top = @(Get-ChildItem -LiteralPath $extract -Force)
    $src = if ($top.Count -eq 1 -and $top[0].PSIsContainer) { $top[0].FullName } else { $extract }
    New-Item -ItemType Directory -Force -Path (Split-Path $Destination) | Out-Null
    Move-Item -LiteralPath $src -Destination $Destination
}

function Test-NeedsInstall([string]$Path, [string]$Name) {
    if (Test-Path $Path) {
        if (-not $Force) {
            Write-Host "  $Name is already installed - skipping (use -Force to update)." -ForegroundColor DarkGray
            return $false
        }
        Write-Host "  Removing the previous version: $Path"
        Remove-Item $Path -Recurse -Force
    }
    return $true
}

# --- Folder structure ---------------------------------------------------------
Write-Step 'Creating folder structure'
foreach ($dir in $Root, $Tools, $HomeDir, $Projects, $Scripts, $Temp,
                 (Join-Path $HomeDir '.claude'),
                 (Join-Path $HomeDir 'vscode-data\user-data\User')) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
}
$Root = (Resolve-Path $Root).Path.TrimEnd('\')

# Scripts from a zip package downloaded from the web carry the "from the internet" mark - we unblock them
# so they work under the RemoteSigned execution policy. Only the explicitly listed environment scripts.
@('Install-SandboxTools.ps1', 'Start-Sandbox.ps1', 'Export-SandboxWork.ps1',
  'Copy-ProjectToSandbox.ps1', 'Import-SandboxWork.ps1', 'New-SandboxPackage.ps1') |
    ForEach-Object { $p = Join-Path $Root $_; if (Test-Path -LiteralPath $p) { Unblock-File -LiteralPath $p } }

# DevSandbox.wsb: host folder paths adjusted to the environment's location
# (other settings, e.g. memory, stay unchanged).
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
            # [string]: Join-Path returns a string wrapped in a PSObject, and XML nodes accept only a plain string.
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
        Write-Host "  Updated paths in DevSandbox.wsb -> $Root"
    }
} else {
    Write-Warning "Missing file $wsbFile."
}

# Scripts run in the Sandbox: if they are next to this script, copy them to Scripts\
foreach ($name in 'Start-Sandbox.ps1', 'Export-SandboxWork.ps1') {
    $src = Join-Path $ScriptDir $name
    if ((Test-Path $src) -and ($ScriptDir -ne $Scripts)) {
        Copy-Item $src $Scripts -Force
        Unblock-File (Join-Path $Scripts $name)
        Write-Host "  Copied $name to the Scripts folder."
    }
    if (-not (Test-Path (Join-Path $Scripts $name))) {
        Write-Warning "Missing file $Scripts\$name - put it there before starting the Sandbox."
    }
}

if (-not (Test-Path (Join-Path $Root 'Settings\ClaudeCode\managed-settings.json'))) {
    Write-Warning "Missing $Root\Settings\ClaudeCode\managed-settings.json - Claude Code in the Sandbox will run without managed settings."
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
        Write-Warning "  No SHA-256 hash for $($gitInfo.Name) - origin is confirmed only by the digital signature."
    }
    Assert-Signature $exe 'Johannes Schindelin' $gitInfo.Name   # Git for Windows signs its releases with this certificate

    Write-Host "  Extracting to $GitDir"
    New-Item -ItemType Directory -Force -Path $GitDir | Out-Null
    $p = Start-Process -FilePath $exe -ArgumentList "-o`"$GitDir`"", '-y' -Wait -PassThru
    if ($p.ExitCode -ne 0) { throw "Extracting PortableGit failed (exit code $($p.ExitCode))." }

    # The PortableGit post-install configuration has to run here,
    # because the Tools folder is read-only in the Sandbox.
    $postInstall = Join-Path $GitDir 'post-install.bat'
    if (Test-Path $postInstall) {
        Write-Host '  Running PortableGit post-install...'
        Start-Process -FilePath (Join-Path $GitDir 'git-bash.exe') `
                      -ArgumentList '--needs-console', '--hide', '--no-cd', '--command=post-install.bat' `
                      -WorkingDirectory $GitDir -Wait
    }
    Write-Host "  Installed: $(& (Join-Path $GitDir 'cmd\git.exe') --version)" -ForegroundColor Green
}

# --- Node.js LTS ---------------------------------------------------------------
Write-Step 'Node.js LTS'
if (Test-NeedsInstall $NodeDir 'Node.js') {
    $index = Invoke-RestMethod 'https://nodejs.org/dist/index.json'
    $lts = $index | Where-Object { $_.lts -and ($_.files -contains 'win-x64-zip') } | Select-Object -First 1
    if (-not $lts) { throw 'Failed to determine the latest Node.js LTS version.' }
    $ver  = $lts.version
    $name = "node-$ver-win-x64"
    $zip  = Join-Path $Temp "$name.zip"
    Get-File "https://nodejs.org/dist/$ver/$name.zip" $zip
    $sums = Get-Text "https://nodejs.org/dist/$ver/SHASUMS256.txt"
    $expected = if ($sums -match "(?m)^([0-9a-fA-F]{64})\s+$([regex]::Escape("$name.zip"))\s*$") { $Matches[1] }
    Assert-FileHash $zip $expected 'SHA256' "$name.zip"

    Write-Host "  Extracting to $NodeDir"
    & $Tar -xf $zip -C $Temp
    if ($LASTEXITCODE -ne 0) { throw 'Extracting Node.js failed.' }
    Move-Item (Join-Path $Temp $name) $NodeDir
    Write-Host "  Installed: Node.js $(& (Join-Path $NodeDir 'node.exe') --version)" -ForegroundColor Green
}

# --- Visual Studio Code (zip) --------------------------------------------------
Write-Step 'Visual Studio Code'
if (Test-NeedsInstall $CodeDir 'VS Code') {
    # The VS Code update API returns the package URL and its SHA-256.
    $meta = Invoke-RestMethod 'https://update.code.visualstudio.com/api/update/win32-x64-archive/stable/latest'
    $zip = Join-Path $Temp 'vscode.zip'
    Get-File $meta.url $zip
    Assert-FileHash $zip $meta.sha256hash 'SHA256' "VS Code $($meta.productVersion)"

    Write-Host "  Extracting to $CodeDir"
    New-Item -ItemType Directory -Force -Path $CodeDir | Out-Null
    & $Tar -xf $zip -C $CodeDir
    if ($LASTEXITCODE -ne 0) { throw 'Extracting VS Code failed.' }
    # Note: we deliberately do NOT create the VSCode\data folder - VS Code data goes to Home\vscode-data
    # (the VSCODE_PORTABLE variable is set in the Sandbox), because Tools is read-only.
    Write-Host '  Installed VS Code.' -ForegroundColor Green
}

# --- Claude Code (npm) ---------------------------------------------------------
Write-Step 'Claude Code'
if (Test-NeedsInstall $ClaudeDir 'Claude Code') {
    $env:Path = "$NodeDir;$env:Path"
    New-Item -ItemType Directory -Force -Path $ClaudeDir | Out-Null
    # --ignore-scripts: no scripts from npm packages are run on the host.
    & (Join-Path $NodeDir 'npm.cmd') install -g '@anthropic-ai/claude-code' `
        --prefix $ClaudeDir --cache (Join-Path $Temp 'npm-cache') --ignore-scripts --no-fund --no-audit
    if ($LASTEXITCODE -ne 0) { throw 'Installing Claude Code via npm failed.' }

    # Instead of the skipped postinstall (install.cjs): the native claude.exe from the package
    # @anthropic-ai/claude-code-win32-x64 -> bin\claude.exe, after verifying the Anthropic signature.
    $native = Get-ChildItem (Join-Path $ClaudeDir 'node_modules') -Recurse -Filter 'claude.exe' -File |
              Where-Object { $_.FullName -match '\\claude-code-win32-x64\\claude\.exe$' } | Select-Object -First 1
    if (-not $native) { throw 'Native claude.exe not found (package @anthropic-ai/claude-code-win32-x64).' }
    Assert-Signature $native.FullName 'O="?Anthropic, PBC' 'claude.exe'
    $binExe = Join-Path $ClaudeDir 'node_modules\@anthropic-ai\claude-code\bin\claude.exe'
    Remove-Item -LiteralPath $binExe -Force -ErrorAction SilentlyContinue
    try { New-Item -ItemType HardLink -Path $binExe -Value $native.FullName | Out-Null }
    catch { Copy-Item -LiteralPath $native.FullName -Destination $binExe }

    $env:Path = "$ClaudeDir;$env:Path"
    Write-Host "  Installed: $(claude --version)" -ForegroundColor Green
}

# --- Angular CLI (npm) ---------------------------------------------------------
Write-Step 'Angular CLI'
if (Test-NeedsInstall $NgDir 'Angular CLI') {
    $env:Path = "$NodeDir;$env:Path"
    $env:NG_CLI_ANALYTICS = 'false'
    New-Item -ItemType Directory -Force -Path $NgDir | Out-Null
    & (Join-Path $NodeDir 'npm.cmd') install -g "@angular/cli@$AngularCliVersion" `
        --prefix $NgDir --cache (Join-Path $Temp 'npm-cache') --ignore-scripts --no-fund --no-audit
    if ($LASTEXITCODE -ne 0) { throw 'Installing Angular CLI via npm failed.' }
    $ngVersion = (Get-Content (Join-Path $NgDir 'node_modules\@angular\cli\package.json') -Raw | ConvertFrom-Json).version
    Write-Host "  Installed: Angular CLI $ngVersion" -ForegroundColor Green
}

# --- Python (NuGet) ------------------------------------------------------------
# The NuGet package "python" is a full, portable distribution (no installer and no registry entries).
# Used among others by the guard.py hook from Settings\ClaudeCode. In the Sandbox the folder is read-only,
# so install packages in the project's virtual environments (python -m venv .venv).
Write-Step 'Python'
if (Test-NeedsInstall $PythonDir 'Python') {
    $ver = $PythonVersion
    if (-not $ver) {
        $ver = (Invoke-RestMethod 'https://api.nuget.org/v3-flatcontainer/python/index.json').versions |
               Where-Object { $_ -match '^\d+\.\d+\.\d+$' } |
               Sort-Object { [version]$_ } | Select-Object -Last 1
        if (-not $ver) { throw 'Failed to determine the latest Python version in NuGet.' }
    }
    $pkg = Join-Path $Temp "python.$ver.zip"
    Get-File "https://api.nuget.org/v3-flatcontainer/python/$ver/python.$ver.nupkg" $pkg
    Assert-FileHash $pkg (Get-NuGetPackageSha512 'python' $ver) 'SHA512' "python.$ver.nupkg"

    Write-Host "  Extracting to $PythonDir"
    $extract = Join-Path $Temp 'python-pkg'
    New-Item -ItemType Directory -Force -Path $extract | Out-Null
    & $Tar -xf $pkg -C $extract
    if ($LASTEXITCODE -ne 0) { throw 'Extracting Python failed.' }
    Move-Item (Join-Path $extract 'tools') $PythonDir
    Write-Host "  Installed: $(& (Join-Path $PythonDir 'python.exe') --version)" -ForegroundColor Green
}

# --- .NET SDK (zip) --------------------------------------------------------------
# Several SDKs extracted into one folder work side by side (dotnet --list-sdks).
# Channels are installed from the oldest, so that the shared files (dotnet.exe, host) come from the newest.
Write-Step '.NET SDK'
if (Test-NeedsInstall $DotnetDir '.NET SDK') {
    New-Item -ItemType Directory -Force -Path $DotnetDir | Out-Null
    foreach ($channel in ($DotnetChannels | Sort-Object { [version]$_ })) {
        $meta = Invoke-RestMethod "https://builds.dotnet.microsoft.com/dotnet/release-metadata/$channel/releases.json"
        $sdkVer = $meta.'latest-sdk'
        $sdk = $meta.releases | ForEach-Object { $_.sdks } | Where-Object { $_.version -eq $sdkVer } | Select-Object -First 1
        $file = $sdk.files | Where-Object { $_.name -eq 'dotnet-sdk-win-x64.zip' } | Select-Object -First 1
        if (-not $file) { throw ".NET SDK $sdkVer package (win-x64 zip) not found in channel $channel." }

        $zip = Join-Path $Temp "dotnet-sdk-$sdkVer-win-x64.zip"
        Get-File $file.url $zip
        Assert-FileHash $zip $file.hash 'SHA512' ".NET SDK $sdkVer"

        Write-Host "  Extracting .NET SDK $sdkVer to $DotnetDir"
        & $Tar -xf $zip -C $DotnetDir
        if ($LASTEXITCODE -ne 0) { throw "Extracting .NET SDK $sdkVer failed." }
    }
    $env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
    $env:DOTNET_NOLOGO = '1'
    Write-Host '  Installed SDKs:' -ForegroundColor Green
    & (Join-Path $DotnetDir 'dotnet.exe') --list-sdks | ForEach-Object { Write-Host "    $_" -ForegroundColor Green }
}

# --- Git Extensions (portable zip) ------------------------------------------------
# Graphical Git client. Requires .NET Desktop Runtime 10 - it is in Tools\dotnet (SDK 10).
Write-Step 'Git Extensions'
if (Test-NeedsInstall $GitExtDir 'Git Extensions') {
    # Portable version for x64 (the release also contains ARM64 versions).
    $a = Get-GitHubReleaseAsset 'gitextensions/gitextensions' '(?i)^(?!.*arm).*portable.*\.zip$'
    if (-not $a.Sha256) { throw "No SHA-256 hash for $($a.Name) - aborting (set GITHUB_TOKEN to use the GitHub API)." }
    $zip = Join-Path $Temp $a.Name
    Get-File $a.Url $zip
    Assert-FileHash $zip $a.Sha256 'SHA256' $a.Name
    Expand-ToolZip $zip $GitExtDir
    $exe = Get-ChildItem $GitExtDir -Filter 'GitExtensions.exe' -File -Recurse | Select-Object -First 1
    if (-not $exe) { throw "Package $($a.Name) does not contain GitExtensions.exe." }
    $arch = Get-PeMachine $exe.FullName
    if ($arch -ne 'x64') {
        Remove-Item -LiteralPath $GitExtDir -Recurse -Force
        throw "The downloaded Git Extensions is for the $arch architecture, not x64 ($($a.Name)) - deleted."
    }

    # IsPortable=False: settings in %APPDATA%\GitExtensions (redirected to Home in the Sandbox),
    # because the program folder in Tools is read-only in the Sandbox.
    $cfgFile = Join-Path $exe.DirectoryName 'GitExtensions.dll.config'
    if (Test-Path -LiteralPath $cfgFile) {
        $cfg = New-Object System.Xml.XmlDocument
        $cfg.PreserveWhitespace = $true
        $cfg.Load($cfgFile)
        $node = $cfg.SelectSingleNode("//setting[@name='IsPortable']/value")
        if ($node) { $node.InnerText = 'False'; $cfg.Save($cfgFile); Write-Host '  Set IsPortable=False (settings in the user profile).' }
        else { Write-Warning '  No IsPortable setting in GitExtensions.dll.config - settings may not be saved.' }
    }
    $sig = Get-AuthenticodeSignature -LiteralPath $exe.FullName
    Write-Host "  GitExtensions.exe: signature $($sig.Status) $($sig.SignerCertificate.Subject)" -ForegroundColor DarkGray
    Write-Host "  Installed: Git Extensions $($exe.VersionInfo.ProductVersion)" -ForegroundColor Green
}

# --- Default settings in Home (only if they do not exist yet) ------------------
Write-Step 'Default settings'

# Global .gitconfig for the Sandbox (pointed to by GIT_CONFIG_GLOBAL).
# safe.directory = * is needed because files in the mapped folders belong to your
# account on the host, while in the Sandbox you work as WDAGUtilityAccount.
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
    Write-Host '  Created Home\.gitconfig'
}

# VS Code settings: disable self-update attempts (the program folder is read-only).
# claudeCode.environmentVariables: the Claude Code extension uses the same configuration and conversation
# history (C:\SandBox\Home\.claude) as the console - regardless of how VS Code was started.
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
    Write-Host '  Created VS Code settings'
}

# --- Cleanup -------------------------------------------------------------------
Write-Step 'Cleanup'
Remove-Item $Temp -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "`nDone! Start the Sandbox by double-clicking the DevSandbox.wsb file." -ForegroundColor Green
Write-Host "Clone projects with: $Root\Copy-ProjectToSandbox.ps1 <path-or-URL>  (in the Sandbox: C:\SandBox\Projects)."
Write-Host "Move work out of the Sandbox: 'Export changes' in the Sandbox, then $Root\Import-SandboxWork.ps1 <name>."
