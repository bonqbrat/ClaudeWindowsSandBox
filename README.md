# Development Environment in Windows Sandbox

This package contains powershell scripts that download and configure environment for C# and Angular programming tools 
with Claude Code in an isolated Windows Sandbox.
Portable tools (Git, Node.js, Angular CLI, VS Code, Claude Code, Python, .NET SDK 8 and 10) are installed on your host and are running
in an isolated Windows Sandbox (Sandbox loses all data after closing, so we keep them on your host).
Projects from the host (e.g., `C:\_Projects`) are cloned into the Sandbox, and after work is done,
commits and uncommitted changes return to the original repository via `git fetch` from a bundle file.

> In the examples, the environment folder is `E:\SandBox`. It can be located anywhere – the scripts automatically determine
> their location, and `Install-SandboxTools.ps1` adjusts the paths in `DevSandbox.wsb`.

---

## Quick start

Requirements: Windows 10/11 **Pro or Enterprise**, virtualization enabled in BIOS/UEFI, internet access,
approx. 4 GB of disk space. There is no need to install Git, Node.js, or anything else on the host.

**1. Enable Windows Sandbox** (one-time) – Windows PowerShell 5.1 (not 7) **as administrator**, then restart:

```powershell
Enable-WindowsOptionalFeature -Online -FeatureName Containers-DisposableClientVM -All
```

**2. Extract the package** Clone this repository or unpack `DevSandbox-<date>.zip` (if you got dist package) e.g., to the `E:` drive – this will create the `E:\SandBox` folder.

**3. Allow script execution** (one-time, regular PowerShell, only for your account):

```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```

> If your policy does not allow this, run scripts via
> `powershell -ExecutionPolicy Bypass -File E:\SandBox\<script>.ps1 <parameters>`.

**4. Install tools** (downloads approx. 1 GB, takes a few to several minutes):

```powershell
powershell -ExecutionPolicy Bypass -File E:\SandBox\Install-SandboxTools.ps1
```

**5. Clone your project** to the Sandbox:

```powershell
E:\SandBox\Copy-ProjectToSandbox.ps1 C:\_Projects\SampleMicroService
```

**6. Start the Sandbox** – double-click `E:\SandBox\DevSandbox.wsb`. After a moment, a terminal will appear
in `C:\SandBox\Projects\SampleMicroService` along with desktop shortcuts. On the first launch, click
**Claude Code** and log in (the login is remembered).

**7. Work** – the **Claude Code**, **Visual Studio Code**, and **Git Bash** shortcuts open the cloned project.

**8. Transfer work to the host** – in the Sandbox, click the **Eksportuj zmiany** (Export changes) shortcut, and on the host run:

```powershell
E:\SandBox\Import-SandboxWork.ps1 SampleMicroService
```

Changes (commits from the Sandbox as `sandbox/*` branches and uncommitted files) will be transferred to
`C:\_Projects\SampleMicroService`. You perform the final commit and `git push` on the host.

### Cheat sheet

| Where   | Command | Purpose |
|---------|-----------|-------|
| host    | `E:\SandBox\Copy-ProjectToSandbox.ps1 C:\_Projects\<Project>` | copy project to Sandbox (becomes the current one) |
| host    | `E:\SandBox\DevSandbox.wsb` (double-click) | start Sandbox |
| Sandbox | shortcut **Eksportuj zmiany** | save work for transfer |
| host    | `E:\SandBox\Import-SandboxWork.ps1 <Project>` | transfer work to the project on the host |
| host    | `Set-Content E:\SandBox\Scripts\last-project.txt <Project>` | switch the current project |
| host    | `powershell -ExecutionPolicy Bypass -File E:\SandBox\Install-SandboxTools.ps1 -Force` | update all tools |

---

## 1. How it works

### 1.1. Folder structure

```text
E:\SandBox\
  README.md                   this document
  DevSandbox.wsb              Sandbox configuration (double-click = run)
  Install-SandboxTools.ps1    tool installation / update                     [host only]
  Copy-ProjectToSandbox.ps1   clone project to Sandbox                       [host only]
  Import-SandboxWork.ps1      transfer work from Sandbox to project          [host only]
  New-SandboxPackage.ps1      build zip package for others                   [host only]
  ProjectMap.json             project name -> target folder on host          [host only, auto-generated]
  Start-Sandbox.ps1           startup script source (copied to Scripts\)
  Export-SandboxWork.ps1      export script source  (copied to Scripts\)
  Tools\                      Git, node, angular-cli, VSCode, claude-code, Python, dotnet
  Scripts\                    scripts executed inside Sandbox
    Start-Sandbox.ps1         startup script (LogonCommand)
    Export-SandboxWork.ps1    export work to bundle
    last-project.txt          current project (written by Copy-ProjectToSandbox.ps1)
  Settings\ClaudeCode\        managed-settings.json + hooks\guard.py
  Home\                       .gitconfig, .claude (auth, conversation history), vscode-data,
                              .nuget and .npm-cache (package cache), npm-global (npm install -g),
                              PowerShell\ and .bash_history (terminal command history)
  Projects\                   project clones + .sandbox-export\ (bundle with work)
```

### 1.2. Folder mapping (`DevSandbox.wsb`)

| Host                            | Sandbox                        | Access            |
|---------------------------------|--------------------------------|-------------------|
| `E:\SandBox\Tools`              | `C:\SandBox\Tools`             | read-only         |
| `E:\SandBox\Scripts`            | `C:\SandBox\Scripts`           | read-only         |
| `E:\SandBox\Settings\ClaudeCode`| `C:\Program Files\ClaudeCode`  | read-only         |
| `E:\SandBox\Home`               | `C:\SandBox\Home`              | read and write    |
| `E:\SandBox\Projects`           | `C:\SandBox\Projects`          | read and write    |

- Paths in the Sandbox are always the same (`C:\SandBox\...`), regardless of the folder location on the host.
- Files in the root directory `E:\SandBox` (host scripts, `ProjectMap.json`) are **not visible** in the Sandbox.
  The `C:\_Projects` folder is also not mapped – the Sandbox works exclusively on a copy.
- `C:\Program Files\ClaudeCode` is the location of Claude Code's *managed settings* on Windows. Therefore, settings from
  `Settings\ClaudeCode` have the highest priority in the Sandbox (this also applies to the VS Code extension)
  and cannot be changed or overwritten from inside the Sandbox. Nothing is mapped to `C:\Program Files` on the host.
- The Sandbox is allocated **12 GB RAM** (`MemoryInMB = 12288`) – the Angular build runs Node
  with `--max_old_space_size=8000`, so 8 GB was not enough.
- Everything except `C:\SandBox\Home` and `C:\SandBox\Projects` disappears after closing the Sandbox.

---

## 2. Installation – details

### 2.1. Tools (`Install-SandboxTools.ps1`)

The script downloads the latest versions and extracts them to `Tools`:

| Tool        | Folder                    | Source                         |
|-------------|---------------------------|--------------------------------|
| Git         | `Tools\Git`               | PortableGit (GitHub)           |
| Node.js LTS | `Tools\node`              | nodejs.org                     |
| VS Code     | `Tools\VSCode`            | update.code.visualstudio.com   |
| Claude Code | `Tools\claude-code`       | npm `@anthropic-ai/claude-code`|
| Angular CLI | `Tools\angular-cli`       | npm `@angular/cli` (command `ng`) |
| Python      | `Tools\Python`            | NuGet, `python` package        |
| .NET SDK 8 & 10 | `Tools\dotnet`        | builds.dotnet.microsoft.com (zip, SHA-512 verification) |

The .NET SDK contains the C# compiler (Roslyn) and the .NET, ASP.NET Core, and Windows Desktop runtimes.
Both SDKs reside in one folder and work side-by-side – a `net8.0` project runs on runtime 8,
and a `net10.0` project runs on runtime 10.

Every downloaded file is verified **before** extraction or execution – in case of a mismatch, the file is
deleted, and the installation is aborted:

| Tool        | Verification |
|-------------|-------------|
| Git         | SHA-256 from GitHub Releases (`digest` field, or sum table in release description) + Authenticode signature "Johannes Schindelin". If GitHub API refuses (limit 60 requests/h per IP) – release from `releases/latest` page, sum from release page; if missing, signature only (with warning) |
| Node.js     | SHA-256 from `https://nodejs.org/dist/<version>/SHASUMS256.txt` |
| VS Code     | SHA-256 from VS Code update API (`sha256hash`) |
| Python      | SHA-512 of the NuGet package (`.nupkg.sha512` or `packageHash` from NuGet catalog) |
| .NET SDK    | SHA-512 from .NET release metadata (`releases.json`) |
| Claude Code | npm with `--ignore-scripts`; native `claude.exe` – Authenticode signature "Anthropic, PBC" |
| Angular CLI | npm with `--ignore-scripts` |

> Hashes come from the same services as the files – they protect against file corruption or replacement in transit
> or on a mirror/CDN, but not against the publisher's service itself being compromised. For Git and Claude Code, this gap is closed by the
> Authenticode signature. The `--ignore-scripts` flag prevents npm from running any package scripts on the host;
> the only post-installation step needed for Claude Code (copying `claude.exe` to `bin\`) is performed by the script itself.

Additionally, the script:

- unblocks the explicitly listed environment scripts (`Install-SandboxTools.ps1`, `Start-Sandbox.ps1`,
  `Export-SandboxWork.ps1`, `Copy-ProjectToSandbox.ps1`, `Import-SandboxWork.ps1`, `New-SandboxPackage.ps1`)
  from the "downloaded from the internet" mark – other `.ps1` files in the folder remain blocked,
- adjusts host folder paths in `DevSandbox.wsb` to the environment's location (other settings,
  like memory, remain unchanged),
- copies `Start-Sandbox.ps1` and `Export-SandboxWork.ps1` to `Scripts\`,
- creates default `Home\.gitconfig` and VS Code settings (only if they do not exist yet). VS Code settings
  contain `claudeCode.environmentVariables` (`CLAUDE_CONFIG_DIR`, `CLAUDE_CODE_GIT_BASH_PATH`,
  `DISABLE_AUTOUPDATER`), so the Claude Code extension uses the same configuration and history as the console.

Parameters:

```powershell
# update all tools to the latest versions
powershell -ExecutionPolicy Bypass -File E:\SandBox\Install-SandboxTools.ps1 -Force

# specific Python version (during initial installation or with -Force)
powershell -ExecutionPolicy Bypass -File E:\SandBox\Install-SandboxTools.ps1 -Force -PythonVersion 3.13.9

# specific Angular CLI version (latest by default)
powershell -ExecutionPolicy Bypass -File E:\SandBox\Install-SandboxTools.ps1 -Force -AngularCliVersion 22

# other .NET SDK channels (8.0 and 10.0 by default)
powershell -ExecutionPolicy Bypass -File E:\SandBox\Install-SandboxTools.ps1 -Force -DotnetChannels 8.0,9.0,10.0
```

> The script skips tools that are already installed. `-Force` removes and reinstalls **all** tools.
> Hash and signature verification only works during (re)installation – to check already installed tools,
> run the script with `-Force`.
>
> Parameters are validated: `-PythonVersion` as `3.13.9` (full NuGet package version), `-DotnetChannels`
> as `8.0`, `-AngularCliVersion` as `latest`, `22`, `22.2` or `22.2.3`.
>
> The Claude Code and Angular CLI installation uses npm on the host, so it utilizes your `~\.npmrc` (e.g., corporate
> registry). The warning `npm warn Unknown user config "always-auth"` comes from this file and is harmless.

### 2.2. Claude Code Settings

The `Settings\ClaudeCode\managed-settings.json` file contains permissions, auto mode rules, and the `guard.py` hook.
The hook uses Python from `Tools`:

```json
"command": "C:/SandBox/Tools/Python/python.exe",
"args": ["C:/Program Files/ClaudeCode/hooks/guard.py"],
```

The `args` path is correct – in the Sandbox, `C:\Program Files\ClaudeCode` is the mapped
`Settings\ClaudeCode` folder.

Make settings changes **on the host** in `Settings\ClaudeCode`. They take effect after restarting
Claude Code in the Sandbox. For example, to keep chat history longer than the default 30 days, add
`"cleanupPeriodDays": 365`.

---

## 3. Sandbox – details

### 3.1. Startup script

The startup script (`C:\SandBox\Scripts\Start-Sandbox.ps1`) automatically:

- adds to `PATH`: Git, Node.js, Angular CLI, Claude Code, VS Code, Python, .NET, `C:\SandBox\Home\npm-global`,
- sets variables: `CLAUDE_CONFIG_DIR`, `GIT_CONFIG_GLOBAL`, `VSCODE_PORTABLE`, `NUGET_PACKAGES`, `npm_config_cache`,
  `npm_config_prefix` (pointing to `C:\SandBox\Home`, so login, settings, NuGet/npm package cache, and global
  npm packages survive closing the Sandbox), `DOTNET_ROOT`, `DISABLE_AUTOUPDATER`, `PYTHONPYCACHEPREFIX`,
  `CHROME_BIN` (Microsoft Edge from Sandbox – for Karma tests), `NG_CLI_ANALYTICS=false`,
  `HISTFILE` (Git Bash history in `C:\SandBox\Home\.bash_history`),
- creates a PowerShell profile (`Documents\WindowsPowerShell\profile.ps1`) that saves command history
  (↑, Ctrl+R) in `C:\SandBox\Home\PowerShell\ConsoleHost_history.txt` – this history is shared across the VS Code terminal,
  welcome terminal, and Claude Code console, and survives closing the Sandbox,
- saves variables (and `PATH`) in `%LOCALAPPDATA%\SandboxBin\Sandbox-Env.ps1` and creates wrapper scripts there
  to run `Start-Claude.ps1`, `Start-VSCode.ps1`, `Start-GitBash.ps1`,
- creates shortcuts on the desktop:

  | Shortcut | Action |
  |---|---|
  | **Claude Code** | PowerShell console with Claude Code in the current project |
  | **Visual Studio Code** | VS Code with the current project open |
  | **Git Bash** | Git Bash in the current project |
  | **Projekty** | opens the `C:\SandBox\Projects` folder in Explorer |
  | **Eksportuj zmiany** | runs `Export-SandboxWork.ps1` for all projects |

- opens a PowerShell terminal in the current project, showing tool versions.

The Claude Code, VS Code, and Git Bash shortcuts first load `Sandbox-Env.ps1`, and only then start the program.
Explorer (from which the shortcut programs are launched) might not see the variables set during login –
without this, the Claude extension in VS Code, for example, would use the Sandbox profile instead of `C:\SandBox\Home\.claude`.
VS Code and Git Bash start via a hidden PowerShell, so a window might flash briefly.

### 3.2. Current project

The **Claude Code**, **Visual Studio Code**, **Git Bash** shortcuts, and the welcome terminal open the project most recently
cloned by `Copy-ProjectToSandbox.ps1`. Its name is in `E:\SandBox\Scripts\last-project.txt`
(read-only in the Sandbox). The file is read every time a shortcut is clicked, so a newly cloned project works
even if the Sandbox is already running. To switch to another existing project, enter its name on the host:

```powershell
Set-Content E:\SandBox\Scripts\last-project.txt PerspectivNG-UI
```

If the file does not exist or the specified project is not found in `Projects`, the shortcuts open `C:\SandBox\Projects`.

### 3.3. Claude Code conversation history

The console and the VS Code extension use the same configuration folder `C:\SandBox\Home\.claude`
(variable `CLAUDE_CONFIG_DIR`; additionally set for the extension in `claudeCode.environmentVariables`
in VS Code settings). Thus, history survives closing the Sandbox:

| What                      | Where (on host)                                    |
|-------------------------|----------------------------------------------------|
| saved conversations     | `E:\SandBox\Home\.claude\projects\<project-path>\*.jsonl` |
| Claude command history (↑) | `E:\SandBox\Home\.claude\history.jsonl`        |

```powershell
cd C:\SandBox\Projects\SampleMicroService
claude --continue        # continue the last conversation in this folder
claude --resume          # select a conversation from the list
```

In VS Code, past conversations are available in the Claude Code panel (session history). Conversations are tied to the
folder where Claude was launched – always open the same project folder.

> **Do not open `C:\SandBox\Projects` itself in VS Code.** As the root directory of a mapped folder, it has a physical path
> with a trailing slash in the Sandbox (`C:\SandBox\Projects\`), causing the Claude Code extension to look for history
> in the wrong folder and leaving the conversation list empty (though conversations are still saved). Open the specific
> project's folder – the **Visual Studio Code** shortcut does this automatically.

---

## 4. Working with a project – SampleMicroService example

Workflow cycle:

```text
 HOST                                         SANDBOX
 C:\_Projects\SampleMicroService
        │  1. Copy-ProjectToSandbox.ps1
        ▼
 E:\SandBox\Projects\SampleMicroService  ═══  C:\SandBox\Projects\SampleMicroService
                                                      │  2. work: claude, code, git commit
                                                      │  3. Eksportuj zmiany (Export changes)
                                                      ▼
 E:\SandBox\Projects\.sandbox-export\     ═══  SampleMicroService.bundle + .json
        │  4. Import-SandboxWork.ps1
        ▼
 C:\_Projects\SampleMicroService   (git fetch + git apply)
```

### 4.1. Cloning the project to Sandbox (host)

```powershell
E:\SandBox\Copy-ProjectToSandbox.ps1 C:\_Projects\SampleMicroService
```

Result:

- clone is created in `E:\SandBox\Projects\SampleMicroService` (in the Sandbox `C:\SandBox\Projects\SampleMicroService`),
  with the current branch from the source,
- `SampleMicroService` becomes the current project – Sandbox shortcuts will open this folder,
- cloning is done **without hardlinks** – the Sandbox has no access to files in `C:\_Projects`,
- `origin` in the copy points to the remote repository of the original (login/token from the `https://` URL is removed);
  host credentials are not passed to the Sandbox,
- the mapping `SampleMicroService -> C:\_Projects\SampleMicroService` is saved in `E:\SandBox\ProjectMap.json` (used during import),
- if `Home\.gitconfig` lacks `user.name` / `user.email`, they are copied from the host's global Git config.

The script uses Git from the host, or if unavailable – Git from `Tools\Git`.

Variants:

```powershell
# different branch
E:\SandBox\Copy-ProjectToSandbox.ps1 C:\_Projects\SampleMicroService -Branch feature/orders-api

# different folder name in Sandbox (e.g. second copy for experimentation)
E:\SandBox\Copy-ProjectToSandbox.ps1 C:\_Projects\SampleMicroService -Name SampleMicroService-exp

# with submodules
E:\SandBox\Copy-ProjectToSandbox.ps1 C:\_Projects\SampleMicroService -RecurseSubmodules

# directly from Git server; changes will return to local repository specified by -Target
E:\SandBox\Copy-ProjectToSandbox.ps1 https://gitlab.example.com/zespol/SampleMicroService.git `
    -Target C:\_Projects\SampleMicroService
```

> If the folder in `Projects` already exists, the script refuses to clone. First, import the work,
> then delete the folder manually: `Remove-Item E:\SandBox\Projects\SampleMicroService -Recurse -Force`.

### 4.2. Working in the Sandbox

```powershell
cd C:\SandBox\Projects\SampleMicroService

claude                      # Claude Code (with settings from Settings\ClaudeCode)
code .                      # VS Code
git checkout -b feature/health-check
git add -A
git commit -m "Dodaj endpoint /health"
```

A `git push` from the Sandbox to private repositories will not work (no credentials) – this is intentional.
Work is returned to the host via export/import, and you push from the host.

#### Python

The `Tools\Python` folder is read-only, so install packages in the project's virtual environment:

```powershell
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
```

#### .NET / C#

```powershell
dotnet --list-sdks                 # 8.0.x and 10.0.x
dotnet --list-runtimes
dotnet build
dotnet test
dotnet run --project src\SampleMicroService.Api --framework net8.0
```

Packages from nuget.org download normally (cache: `E:\SandBox\Home\.nuget\packages`). Private NuGet feeds
require credentials, which are intentionally omitted in the Sandbox. `dotnet workload install` (e.g., MAUI) will not work,
because `Tools\dotnet` is read-only – workloads must be installed on the host into `E:\SandBox\Tools\dotnet`.

#### Angular (`C:\_Projects\PerspectivNG-UI` example)

```powershell
# host
E:\SandBox\Copy-ProjectToSandbox.ps1 C:\_Projects\PerspectivNG-UI

# Sandbox (Claude Code shortcut / terminal opens in the current project)
cd C:\SandBox\Projects\PerspectivNG-UI
npm ci --legacy-peer-deps          # as in CI
npm run build                      # ng build --configuration production
ng build ngx-forcom-ui             # library
npm test -- --watch=false          # Karma in Edge (CHROME_BIN)
npm start                          # ng serve -> http://localhost:4200
```

- Node.js from `Tools\node` (24.x) matches the CI image `node:24.19.0`.
- The `ng` command comes from `Tools\angular-cli`. When run inside a project, it still uses the Angular CLI version
  from the project's `node_modules`.
- Packages come from `proget.forcom.com.pl` (addresses in `package-lock.json`) – the Sandbox uses the host's network, so
  the registry must be reachable from the host (e.g., via VPN). A registry requiring login will not work – the Sandbox intentionally
  has no credentials.
- The npm cache is persistent (`E:\SandBox\Home\.npm-cache`), so subsequent `npm ci` runs don't redownload packages.
  Project packages go to the project's `node_modules`, not to `npm-global`.
- `node_modules` is located in the mapped `Projects` folder – `npm ci` and build are slower than on the host.
  `node_modules` and `dist` are not exported (`.gitignore`).
- `npm install -g <package>` installs to `E:\SandBox\Home\npm-global` (persistent, available in `PATH`).
- `proxy.conf.js` routes `/api` etc. to `localhost` – in the Sandbox, this means the Sandbox itself, not the host; a backend running
  on the host is not accessible at this address.

### 4.3. Exporting work (Sandbox)

Click the **Eksportuj zmiany** (Export changes) shortcut on the desktop (exports all projects from `C:\SandBox\Projects`)
or run manually:

```powershell
# all projects
C:\SandBox\Scripts\Export-SandboxWork.ps1

# single project only
C:\SandBox\Scripts\Export-SandboxWork.ps1 -Path C:\SandBox\Projects\SampleMicroService
```

For each repository, the script:

- creates a snapshot of the working directory (changed, new, deleted, and staged files) as a `refs/sandbox/wip` commit,
  **without changing** the working directory or index,
- saves the current `HEAD` as `refs/sandbox/head`,
- creates `C:\SandBox\Projects\.sandbox-export\SampleMicroService.bundle` (all branches + snapshot)
  and `SampleMicroService.json` (branch, export date).

> Files from `.gitignore` (e.g., `.env`, `.venv`, `node_modules`, `bin/obj`) **are not exported**.
> The bundle reflects the state at the time of export – run the export again right before every import.

### 4.4. Importing work to the project (host)

```powershell
E:\SandBox\Import-SandboxWork.ps1 SampleMicroService
```

The script:

1. runs `git fetch` from the bundle into `C:\_Projects\SampleMicroService`:
   - Sandbox branches → `sandbox/<branch>` (e.g., `sandbox/main`, `sandbox/feature/health-check`),
   - `refs/sandbox/head`, `refs/sandbox/wip`,
2. shows new commits from the Sandbox,
3. shows the list of uncommitted changes and asks for confirmation,
4. saves your local uncommitted changes as a backup copy in `refs/sandbox/backup/<date>`,
5. applies changes to the working directory (`git apply`) – **nothing is committed**.

Variants:

```powershell
# fast-forward current branch to Sandbox commits (when both sides share the same branch)
E:\SandBox\Import-SandboxWork.ps1 SampleMicroService -FastForward

# changes conflict with local ones – 3-way merge (conflicts resolved manually; changes staged to index)
E:\SandBox\Import-SandboxWork.ps1 SampleMicroService -ThreeWay

# fetch only (git fetch), do not apply anything
E:\SandBox\Import-SandboxWork.ps1 SampleMicroService -NoApply

# without confirmation prompt
E:\SandBox\Import-SandboxWork.ps1 SampleMicroService -FastForward -Yes

# different target folder than the one saved in ProjectMap.json
E:\SandBox\Import-SandboxWork.ps1 SampleMicroService -Target D:\Repos\SampleMicroService
```

### 4.5. After import (host)

```powershell
cd C:\_Projects\SampleMicroService

git status                                   # applied changes
git log --oneline main..sandbox/main         # Sandbox commits that are not present locally
git branch -r --list "sandbox/*"             # all branches from Sandbox

# merge branch created in Sandbox
git switch -c feature/health-check sandbox/feature/health-check
# or
git merge sandbox/feature/health-check

# preview / restore a single file from snapshot
git diff refs/sandbox/head refs/sandbox/wip -- src/Program.cs
git checkout refs/sandbox/wip -- src/Program.cs

# restore local changes saved prior to import
git for-each-ref refs/sandbox/backup
git stash apply refs/sandbox/backup/20261020-153000

# push (from host, using your credentials)
git push origin feature/health-check
```

Cleanup `sandbox` references after work is done:

```powershell
git for-each-ref --format="%(refname)" refs/sandbox refs/remotes/sandbox |
    ForEach-Object { git update-ref -d $_ }
```

---

## 5. Security – assumptions

- **The Sandbox cannot see** `C:\_Projects`, host scripts, or `ProjectMap.json`. The target import folder
  comes exclusively from `ProjectMap.json` / the `-Target` parameter, so the Sandbox cannot redirect the import.
- **The host does not run git in a repository modified inside the Sandbox.** A `.git/config` from the Sandbox could
  contain, for example, `clean` filters or `core.fsmonitor` hooks that would execute code on the host. That's why the snapshot
  is created by `Export-SandboxWork.ps1` inside the Sandbox, and the host only reads the bundle file (`git bundle verify` + `git fetch`).
- The `.json` file from the export is treated as untrusted (the branch name is validated).
- Before applying changes, always review the list of files – especially changes in `.gitattributes`,
  `.vscode/`, build/CI scripts, and hooks.
- `Tools`, `Scripts` (including `last-project.txt`), and `Settings\ClaudeCode` are read-only inside the Sandbox.
- The zip package does not contain `Home` (login info, history), `Projects`, `ProjectMap.json`, or logs – each
  developer logs into Claude Code independently.

---

## 6. Limitations

- Not transferred: ignored files, contents of changes within submodules (only the commit pointer is updated),
  `git stash` from the Sandbox, tags.
- The bundle contains the entire repository – for very large repositories, export/import takes longer.
- `guard.py` protects settings in `~\.claude`, while in the Sandbox user configuration is kept in
  `C:\SandBox\Home\.claude` (however, rules from managed settings always take precedence).
- Claude login credentials (`Home\.claude\.credentials.json`) are write-accessible from within the Sandbox.
- Windows Sandbox does not persist installed programs – this is why all tools are portable
  (in `Tools`) and not installed normally.

---

## 7. Troubleshooting

| Problem | Solution |
|---|---|
| `... cannot be loaded because running scripts is disabled on this system` (host) | Execute step 3 of the quick start (`Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`) or run via `powershell -ExecutionPolicy Bypass -File ...`. |
| Double-clicking `DevSandbox.wsb` does nothing / missing Windows Sandbox | Execute step 1 of the quick start and restart the computer; ensure virtualization is enabled in BIOS/UEFI. |
| Sandbox won't start: host folder missing | Run `Install-SandboxTools.ps1` – it creates folders and adjusts paths in `DevSandbox.wsb`. |
| `claude` won't run in PowerShell (execution policies) | The startup script sets `RemoteSigned`; open a new terminal or use the **Claude Code** shortcut. |
| The guard hook doesn't work in the Sandbox | Check if `E:\SandBox\Tools\Python\python.exe` exists and whether `command` in `managed-settings.json` points to `C:/SandBox/Tools/Python/python.exe`. |
| `dubious ownership` in the Sandbox | `Home\.gitconfig` must contain `[safe] directory = *` (this is created by `Install-SandboxTools.ps1`). |
| Changes in `Start-Sandbox.ps1` / `Export-SandboxWork.ps1` don't take effect | Edit the files in `E:\SandBox`, then run `Install-SandboxTools.ps1` (it copies them to `Scripts\`) and restart the Sandbox – shortcuts are recreated on startup. |
| Empty conversation list in the Claude Code panel in VS Code | Do not open `C:\SandBox\Projects` itself – open the project folder (the **Visual Studio Code** shortcut does this automatically). Check VS Code terminal: `$env:CLAUDE_CONFIG_DIR` must be `C:\SandBox\Home\.claude`. Conversations from the `Projects` directory are available in the console: `cd C:\SandBox\Projects; claude --resume`. |
| Shortcuts open `C:\SandBox\Projects` instead of the project | Check `E:\SandBox\Scripts\last-project.txt` – it must contain the name of an existing folder in `Projects`. |
| Program started differently than via a shortcut does not see variables (`CLAUDE_CONFIG_DIR`, `PATH`) | Launch from the welcome terminal or shortcuts, or source the variables: `. $env:LOCALAPPDATA\SandboxBin\Sandbox-Env.ps1`. |
| Terminal does not remember command history | Check `(Get-PSReadLineOption).HistorySavePath` – it should be `C:\SandBox\Home\PowerShell\ConsoleHost_history.txt`. If not, the Sandbox is running with an old startup script – restart it. |
| `API rate limit exceeded` / `API GitHub niedostepne` when installing Git | Unauthenticated GitHub API limit reached (60 requests/h per IP, shared e.g., across an office behind NAT). The script automatically falls back to the release page. To use the API, set a GitHub token (no permissions needed) before installation: `$env:GITHUB_TOKEN = '<token>'`. |
| `dotnet` cannot find SDKs | Run `dotnet --list-sdks` – if empty, check `E:\SandBox\Tools\dotnet` and run `Install-SandboxTools.ps1`. |

---

## 8. Package for other developers

To create a zip package containing all files required to build the environment, run:

```powershell
E:\SandBox\New-SandboxPackage.ps1
# -> E:\SandBox\dist\DevSandbox-<date>.zip
```

The package contains a `SandBox\` folder with the files: `README.md`, `DevSandbox.wsb`, `Install-SandboxTools.ps1`,
`Start-Sandbox.ps1`, `Export-SandboxWork.ps1`, `Copy-ProjectToSandbox.ps1`, `Import-SandboxWork.ps1`,
`New-SandboxPackage.ps1`, `Settings\ClaudeCode\managed-settings.json`, `Settings\ClaudeCode\hooks\guard.py`.

It intentionally **does not** contain: `Tools` (downloaded by `Install-SandboxTools.ps1`), `Home` (login data, conversation
and command history), `Projects`, `ProjectMap.json`, `Scripts` (script copies), or logs. The recipient should follow the
[Quick start](#quick-start) guide.

Generate the package again after making changes to the scripts or settings.
