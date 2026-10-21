"""
PreToolUse guard - globalne reguly bezpieczenstwa Claude Code.
Dziala w kazdym trybie (rowniez auto): zwraca "deny" albo "ask" (wymusza reczne potwierdzenie).
Fail-closed: blad hooka albo nieczytelne wejscie = deny.

Reguly:
  DENY  - commit / merge / rebase / cherry-pick na branchu release
  DENY  - push / merge do brancha release
  DENY  - tworzenie Merge Requestow / Pull Requestow
  DENY  - edycja funkcji/ustawien systemowych (rejestr, uslugi, katalogi systemowe, podnoszenie uprawnien)
  DENY  - usuwanie/edycja danych na zasobach/dyskach zdalnych
  DENY  - modyfikacja wlasnych zabezpieczen (ten hook, ~/.claude/settings*.json, ~/.claude/CLAUDE.md,
          ~/.claude.json, managed-settings, disableAllHooks) oraz zmiana trybu uprawnien sesji
  ASK   - kazdy git push
  ASK   - instalowanie aplikacji/pakietow (rowniez niejawny restore: dotnet build/run/test...), skrypty z sieci
  ASK   - odczyt danych zwiazanych z bezpieczenstwem (hasla, klucze, tokeny)
  ASK   - wysylanie jakichkolwiek danych do internetu (rowniez git clone/fetch/pull, akcje w przegladarce)
  ASK   - trwale zmiany srodowiska (profile powloki, autostart, git config --global, hooki git, .mcp.json)
  ASK   - agenci/sesje w chmurze (tam ten hook nie dziala)
  ASK   - odczyt / zapis / usuwanie plikow POZA katalogiem projektu (CLAUDE_PROJECT_DIR), %TEMP%,
          EXTRA_ALLOWED_DIRS i permissions.additionalDirectories z ~/.claude/settings.json
          (narzedzia Read/Grep/Glob/Edit/Write oraz sciezki w poleceniach powloki; sciezki sa
          rozwiazywane przez realpath: .., ~, zmienne, /c/..., symlinki, junctiony, nazwy 8.3)
  ASK   - tworzenie symlinkow/junctionow/hardlinkow oraz zapis/usuwanie na sciezce ze zmiennej

Granica projektu to heurystyka (regexy na tekscie polecenia) - nie zastepuje sandboxa systemowego.
W tresci skryptow uruchamianych z plikow granica projektu NIE jest sprawdzana.

Skrypty uruchamiane z plikow (python x.py, .\\x.ps1, bash x.sh ...) oraz -EncodedCommand
sa odczytywane i sprawdzane pod katem regul DENY i git push.
Decyzje ask/deny sa dopisywane do ~/.claude/hooks/guard.log.
"""
import base64
import json
import os
import re
import subprocess
import sys
import tempfile
import time

HOME = os.path.expanduser("~")
LOG_PATH = os.path.join(HOME, ".claude", "hooks", "guard.log")
MAX_SCRIPT_BYTES = 512 * 1024
MAX_DEPTH = 3
RELEASE_RE = re.compile(r"release", re.IGNORECASE)

HITS = []


def deny(reason):
    HITS.append(("deny", reason))


def ask(reason):
    HITS.append(("ask", reason))


def log(decision, reason, data):
    try:
        ti = (data or {}).get("tool_input") or {}
        what = ti.get("command") or ti.get("file_path") or ti.get("url") or ti.get("action") or ""
        entry = {"ts": time.strftime("%Y-%m-%d %H:%M:%S"), "decision": decision,
                 "tool": (data or {}).get("tool_name"), "reason": reason, "input": str(what)[:300]}
        with open(LOG_PATH, "a", encoding="utf-8") as f:
            f.write(json.dumps(entry, ensure_ascii=False) + "\n")
    except Exception:
        pass


def finish(data):
    denies = list(dict.fromkeys(r for d, r in HITS if d == "deny"))
    asks = list(dict.fromkeys(r for d, r in HITS if d == "ask"))
    if denies:
        decision = "deny"
        reason = "; ".join(denies) + " - ZABRONIONE przez globalne reguly uzytkownika. Popros uzytkownika o wykonanie tego recznie."
    elif asks:
        decision = "ask"
        reason = "; ".join(asks) + " - wymaga recznego potwierdzenia uzytkownika."
    else:
        sys.exit(0)
    log(decision, reason, data)
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": decision,
            "permissionDecisionReason": "[guard] " + reason,
        }
    }))
    sys.exit(0)


# ---------------------------------------------------------------- helpers

def current_branch(cwd):
    try:
        r = subprocess.run(["git", "-C", cwd, "symbolic-ref", "--short", "-q", "HEAD"],
                           capture_output=True, text=True, timeout=5)
        return r.stdout.strip() if r.returncode == 0 else ""
    except Exception:
        return ""


def git_dirs(cmd, cwd):
    """Katalogi, w ktorych moze dzialac polecenie: cwd, cele `cd`, argumenty `git -C`."""
    dirs = [cwd]
    for m in re.finditer(r"(?:^|[;&|]\s*)(?:cd|Set-Location|pushd)\s+(?:/d\s+)?(\"[^\"]+\"|'[^']+'|\S+)", cmd, re.I):
        d = m.group(1).strip("\"'")
        dirs.append(d if os.path.isabs(d) else os.path.join(cwd, d))
    for m in re.finditer(r"\bgit\s+-C\s+(\"[^\"]+\"|'[^']+'|\S+)", cmd):
        d = m.group(1).strip("\"'")
        dirs.append(d if os.path.isabs(d) else os.path.join(cwd, d))
    return dirs


def network_drive_letters():
    letters = set()
    if os.name != "nt":
        return letters
    try:
        import ctypes
        GetDriveTypeW = ctypes.windll.kernel32.GetDriveTypeW
        for c in "ABCDEFGHIJKLMNOPQRSTUVWXYZ":
            if GetDriveTypeW(f"{c}:\\") == 4:  # DRIVE_REMOTE
                letters.add(c)
    except Exception:
        pass
    return letters


NET_LETTERS = network_drive_letters()


def norm(p):
    """Normalizuje sciezke: ~, $HOME, %USERPROFILE%, /c/... -> c:\\..., male litery, backslashe."""
    p = (p or "").strip().strip("\"'")
    p = re.sub(r"^(~|\$HOME|\$\{HOME\}|\$env:USERPROFILE|%USERPROFILE%)(?=[\\/]|$)", lambda m: HOME, p, flags=re.I)
    m = re.match(r"^/([A-Za-z])(/|$)", p)
    if m:
        p = m.group(1) + ":\\" + p[3:]
    return p.replace("/", "\\").lower()


def abs_norm(p, cwd):
    n = norm(p)
    if n and not re.match(r"^[a-z]:\\|^\\", n):
        n = norm(os.path.join(cwd, p.strip("\"'")))
    return n


IS_WIN = os.name == "nt"
TEMP_DIR = tempfile.gettempdir()


def real_path(p, base):
    """Kanoniczna sciezka: ~, zmienne, /c/..., /tmp, .., symlinki, junctiony, nazwy 8.3."""
    t = os.path.expandvars(os.path.expanduser((p or "").strip().strip("\"'")))
    if IS_WIN:
        if re.match(r"^[\\/]tmp([\\/]|$)", t, re.I):
            t = TEMP_DIR + t[4:]
        m = re.match(r"^[\\/]([A-Za-z])([\\/]|$)", t)
        if m:
            t = m.group(1) + ":/" + t[3:]
    if not os.path.isabs(t):
        t = os.path.join(base, t)
    return os.path.normcase(os.path.realpath(t))


def path_variants(p, cwd=None):
    """Warianty znormalizowanej sciezki: dosloswny, bezwzgledny, po realpath."""
    out = {norm(p)}
    if cwd:
        out.add(abs_norm(p, cwd))
        try:
            out.add(norm(real_path(p, cwd)))
        except (OSError, ValueError):
            pass
    out.discard("")
    return out


def is_remote_path(p):
    if not p:
        return False
    p = p.strip("\"'")
    if p.startswith("\\\\") or re.match(r"^//[^/]", p):
        return True
    # "X:\..." albo git-bashowe "/x/..."
    m = re.match(r"^([A-Za-z]):", p) or re.match(r"^/([A-Za-z])(/|$)", p)
    return bool(m and m.group(1).upper() in NET_LETTERS)


def mentions_remote_path(cmd):
    if re.search(r"\\\\[A-Za-z0-9_.$-]+\\", cmd) or re.search(r"(?<![:\w/])//[A-Za-z0-9_.-]+/", cmd):
        return True
    for c in NET_LETTERS:
        if re.search(rf"(?<![\w]){c}:[\\/]", cmd, re.I) or re.search(rf"(?:^|\s)/{c.lower()}/", cmd):
            return True
    return False


SYSTEM_DIRS = [r"c:\windows", r"c:\program files", r"c:\program files (x86)", r"c:\programdata",
               "\\etc", "\\usr", "\\bin", "\\sbin", "\\boot", "\\system"]
for _v in ("SystemRoot", "windir", "ProgramFiles", "ProgramFiles(x86)", "ProgramW6432", "ProgramData"):
    _d = norm(os.environ.get(_v, "")).rstrip("\\")
    if _d and _d not in SYSTEM_DIRS:
        SYSTEM_DIRS.append(_d)


def is_system_path(p, cwd=None):
    return any(n == d or n.startswith(d + "\\") for n in path_variants(p, cwd) for d in SYSTEM_DIRS)


# --- ochrona wlasnych zabezpieczen
_HOMES = {norm(HOME), norm(os.path.realpath(HOME))}
CLAUDE_DIRS = {h + "\\.claude" for h in _HOMES}
PROTECTED_EXACT = {d + s for d in CLAUDE_DIRS for s in ("\\settings.json", "\\settings.local.json", "\\claude.md",
                                                       "\\policy-limits.json", "\\remote-settings.json")}
PROTECTED_EXACT |= {h + "\\.claude.json" for h in _HOMES}
PROTECTED_DIRS = [d + "\\hooks" for d in CLAUDE_DIRS]
SELF_KEYWORD_RE = re.compile(r"guard\.py|disableAllHooks|allowManagedHooksOnly|managed-settings|managed-mcp", re.I)
PROJECT_SETTINGS_RE = re.compile(r"\\\.claude\\settings(\.local)?\.json$")

# --- trwale zmiany srodowiska (autostart, profile powloki, konfiguracja git)
PERSIST_RE = re.compile(
    r"\\start menu\\programs\\startup\\|\\(windows)?powershell\\[^\\]*profile\.ps1$|\\profile\.ps1$|"
    r"\\\.(bashrc|bash_profile|bash_login|profile|zshrc|zprofile|gitconfig)$|\\\.git\\hooks\\|"
    r"\\\.git\\config$|\\\.config\\git\\|\\\.mcp\.json$")


def is_protected_path(p, cwd):
    for n in path_variants(p, cwd):
        if n in PROTECTED_EXACT or any(n == d or n.startswith(d + "\\") for d in PROTECTED_DIRS):
            return True
        if n.endswith("managed-settings.json") or n.endswith("managed-mcp.json"):
            return True
    return False


SECRET_PATH_RE = re.compile(
    r"(^|[\\/])(\.env(\.[\w.-]+)?|\.npmrc|\.pypirc|\.netrc|_netrc|\.git-credentials|\.pgpass|"
    r"\.credentials\.json|\.claude\.json|credentials(\.\w+)?|secrets?(\.\w+)?|id_rsa\w*|id_ed25519\w*|id_ecdsa\w*|"
    r"known_hosts|authorized_keys|[\w.-]*\.(pem|key|pfx|p12|jks|keystore|kdbx|ppk|asc|gpg))$"
    r"|[\\/]\.ssh[\\/]|[\\/]\.aws[\\/]|[\\/]\.azure[\\/]|[\\/]\.kube[\\/]config|[\\/]\.gnupg[\\/]"
    r"|appsettings\.[\w.]*secret|usersecrets|secrets\.json$|wallet",
    re.IGNORECASE,
)


def is_secret_path(p):
    return bool(p) and bool(SECRET_PATH_RE.search(p.strip("\"'")))


LOCAL_URL_RE = re.compile(
    r"^(https?://)?(localhost|127\.\d+\.\d+\.\d+|\[::1\]|0\.0\.0\.0|[\w.-]+\.localhost)(:\d+)?([/?#]|$)|"
    r"^(file|about|chrome|edge):|^(back|forward)$", re.I)


# ---------------------------------------------------------------- shell commands

MR_RE = re.compile(
    r"\b(gh\s+pr\s+create|gh\s+api\s+\S*pulls|glab\s+mr\s+create|hub\s+pull-request|"
    r"az\s+repos\s+pr\s+create|git\s+push\b[^\n]*merge_request\.create|"
    r"tea\s+pr\s+create|bb\s+pr\s+create)", re.I)

SYSTEM_CMD_RE = re.compile(
    r"(\breg(\.exe)?\s+(add|delete|import|load|unload|restore|copy)\b|\bregedit\b|"
    r"\b(Set|New|Remove|Rename)-ItemProperty\b|\bNew-Item\b[^\n]*\b(HKLM|HKCU|HKCR|HKU|Registry)::?|"
    r"\b(Remove-Item|Set-Item)\b[^\n]*\b(HKLM|HKCU|HKCR|HKU):|"
    r"\bwinreg\.(SetValue\w*|CreateKey\w*|DeleteKey\w*|DeleteValue)\b|"
    r"\.(SetValue|CreateSubKey|DeleteSubKey\w*|DeleteValue)\([^\n]*\b(HKLM|HKCU|LocalMachine|CurrentUser)\b|"
    r"\bsc(\.exe)?\s+(config|create|delete|stop|failure|sdset)\b|"
    r"\b(Set|New|Remove|Stop|Suspend)-Service\b|\bbcdedit\b|\bbcdboot\b|\bdiskpart\b|\bformat\s+[a-z]:|"
    r"\bschtasks(\.exe)?\s+/(create|delete|change)\b|\b(Register|Unregister|Set)-ScheduledTask\b|"
    r"\bnetsh\b|\bSet-ExecutionPolicy\b|\bSet-MpPreference\b|\bAdd-MpPreference\b|"
    r"\b(Enable|Disable)-(WindowsOptionalFeature|NetAdapter|ComputerRestore|PSRemoting)\b|"
    r"\bdism(\.exe)?\b|\bsfc\s+/|\bsetx\b[^\n]*\s/m\b|\b\[Environment\]::SetEnvironmentVariable\([^)]*Machine|"
    r"\bSet-(NetFirewall\w*|NetIPAddress|DnsClientServerAddress|TimeZone|Date|LocalUser)\b|"
    r"\b(New|Remove|Add)-(LocalUser|LocalGroupMember|NetFirewallRule)\b|\bnet\s+(user|localgroup|share|stop|start)\b|"
    r"\bicacls\b|\btakeown\b|\bwmic\b[^\n]*\b(set|delete|call)\b|\bgpupdate\b|\bsecedit\b|"
    r"\bshutdown\b|\bRestart-Computer\b|\bStop-Computer\b|\bsystemctl\b|\bsudo\b|\bgsudo\b|\brunas(\.exe)?\s|"
    r"-Verb\s+['\"]?RunAs\b|\bchmod\s+[0-7]*\s+/(etc|usr|bin)|"
    r"\bRemove-AppxPackage\b|\bUninstall-(Package|Module)\b)",
    re.I)

REG_MENTION_RE = re.compile(r"\b(HKLM|HKCU|HKCR|HKU|HKCC)(:|\\)|\bHKEY_[A-Z_]+|Registry::", re.I)
REG_WRITE_RE = re.compile(
    r"\b(Set|New|Remove|Rename|Move|Copy|Clear)-Item\w*\b|(^|[;&|(\s])(sp|ni|ri|rni|si|rp|cpp|mp|clp|cpi|mi|del|rm|erase)\s|"
    r"\breg(\.exe)?\s+(add|delete|import|load|unload|restore|copy)\b|\.(SetValue|CreateSubKey|DeleteSubKey\w*|DeleteValue)\(",
    re.I)

DESTRUCTIVE_WORDS = (r"\b(rm|rmdir|del|erase|rd|mv|move|ren|rename|cp|copy|xcopy|robocopy|Remove-Item|Move-Item|Rename-Item|"
                     r"Copy-Item|Set-Content|Add-Content|Clear-Content|Out-File|New-Item|truncate|tee|sed\s+-i|dd)\b")
DESTRUCTIVE_RE = re.compile(DESTRUCTIVE_WORDS + r"|>>?", re.I)
DESTRUCTIVE_NOREDIR_RE = re.compile(DESTRUCTIVE_WORDS, re.I)
WRITE_API_RE = re.compile(r"\bopen\([^)]*['\"][wax+]|\bwrite_text\b|\bwrite_bytes\b|\bjson\.dump\b|WriteAll(Text|Bytes|Lines)|"
                          r"\bshutil\.|\bos\.(remove|unlink|rename|replace)\b|\bfs\.(write|unlink|rm|rename)", re.I)
HARMLESS_REDIR_RE = re.compile(r"\d*>>?\s*(&\d|/dev/null|\$null|nul)(?=\s|$|[;&|)])", re.I)

REMOTE_EXEC_RE = re.compile(r"\b(ssh|plink|psexec|Invoke-Command|Enter-PSSession|winrs)\b", re.I)
REMOTE_DESTRUCTIVE_RE = re.compile(
    r"\b(rm|rmdir|del|mv|truncate|dd|drop|delete|update|insert|alter|Remove-Item|Set-Content|sed\s+-i|>)\b", re.I)

INSTALL_RE = re.compile(
    r"\b((npm|pnpm|yarn|bun)\s+(i|install|add|ci|update|upgrade|up|dlx|x|create|exec)\b|"
    r"npx\b|bunx\b|pipx?\d*\s+install\b|python\d*(\.exe)?\s+-m\s+pip\s+install\b|uv\s+(pip\s+install|add|tool\s+install|run|sync)\b|"
    r"poetry\s+(add|install)\b|conda\s+install\b|choco(latey)?\s+(install|upgrade)\b|winget\s+(install|upgrade)\b|"
    r"scoop\s+install\b|dotnet\s+(tool\s+install|add\s+\S*\s*package|new\s+install|workload\s+install)\b|"
    r"dotnet\s+restore\b|nuget(\.exe)?\s+(install|restore)\b|Install-(Package|Module|Script)\b|"
    r"gem\s+install\b|cargo\s+(install|add)\b|go\s+(install|get)\b|apt(-get)?\s+install\b|brew\s+install\b|"
    r"msiexec\b|\.msi\b|Start-Process\b[^\n]*\.(exe|msi)|rustup\b|nvm\s+install\b|"
    r"claude\s+(plugin|mcp)\s+(install|add)\b)",
    re.I)

# dotnet build/run/test/... bez --no-restore pobiera pakiety NuGet
DOTNET_IMPLICIT_RESTORE_RE = re.compile(r"\bdotnet(\.exe)?\s+(build|run|test|publish|pack|watch)\b", re.I)
MSBUILD_RESTORE_RE = re.compile(r"\bmsbuild(\.exe)?\b[^\n]*[-/](restore\b|t(arget)?:[^\s]*restore)", re.I)
BUILD_TOOL_NET_RE = re.compile(r"\b(mvnw?|gradlew?)\b|\bpip\d*\s+download\b|\bdocker\s+(pull|build|run|compose\s+(up|pull|build))\b", re.I)

NETWORK_RE = re.compile(
    r"\b(curl|wget|Invoke-WebRequest|iwr|Invoke-RestMethod|irm|Start-BitsTransfer|bitsadmin|certutil\b[^\n]*-urlcache|"
    r"Net\.WebClient|HttpClient|DownloadString|DownloadFile|UploadString|UploadFile|Send-MailMessage|"
    r"scp|sftp|ftp|rsync|nc|ncat|netcat|telnet|ssh|plink|pscp|Test-NetConnection|"
    r"git\s+(push|send-email|request-pull)|gh\s+(api|gist|issue|release|repo\s+create)|glab\s+|"
    r"az\s+|aws\s+|gcloud\s+|kubectl\s+|docker\s+(push|login)|npm\s+publish|dotnet\s+nuget\s+push|nuget\s+push|"
    r"twine\s+upload|python\d*(\.exe)?\s+-c\b[^\n]*(requests|urllib|http\.client|socket))\b",
    re.I)
HTTP_TOOLS = {"curl", "wget", "invoke-webrequest", "iwr", "invoke-restmethod", "irm", "test-netconnection"}
GIT_NET_RE = re.compile(r"\bgit\b[^\n;&|]*\b(clone|fetch|pull|ls-remote|remote\s+update|submodule\s+(update|add|sync))\b", re.I)

PIPE_EXEC_RE = re.compile(r"\|\s*(iex|Invoke-Expression|sh|bash|zsh|python\d*|pwsh|powershell|node)\b|"
                          r"\biex\s*\(|Invoke-Expression\s*\(|\bpowershell(\.exe)?\b[^\n]*-(enc|EncodedCommand)\b|"
                          r"\bpwsh(\.exe)?\b[^\n]*-(e|ec|enc|EncodedCommand)\s", re.I)
ENCODED_RE = re.compile(r"\s-(?:e|ec|en|enc|enco|encodedcommand)\s+([A-Za-z0-9+/=]{8,})", re.I)

SECRET_CMD_RE = re.compile(
    r"(\bcmdkey\s+/list\b|\bGet-Credential\b|\bGet-StoredCredential\b|\bvaultcmd\b|\bConvertFrom-SecureString\b|"
    r"\bgit\s+credential\b|\bgit\s+config\b[^\n]*credential|\bsecurity\s+find-(generic|internet)-password\b|"
    r"\b(printenv|env)\s*($|[|;&>])|\bset\s*($|[|;&>])|Get-ChildItem\s+env:|\bgci\s+env:|\bls\s+env:|\$env:\w*(KEY|TOKEN|SECRET|PASS)\w*|"
    r"\$\{?\w*(KEY|TOKEN|SECRET|PASSWORD|PASSWD)\w*\}?|"
    r"\bdotnet\s+user-secrets\s+list\b|\bnetsh\s+wlan\s+show\s+profile\b[^\n]*key=clear|"
    r"\bmimikatz\b|\bsekurlsa\b|\breg\s+(query|save)\b[^\n]*\b(SAM|SECURITY)\b|\bkeyring\b|\bpass\s+show\b|"
    r"\b(az|aws|gcloud)\b[^\n]*\b(get-access-token|print-access-token|get-secret|secret\s+show|keys\s+list)\b|"
    r"\bkubectl\s+get\s+secrets?\b|\bgh\s+auth\s+token\b)",
    re.I)

SCRIPT_TOKEN_RE = re.compile(r"\.(py|pyw|ps1|psm1|sh|bash|bat|cmd|js|mjs|cjs|ts|vbs|rb|pl)$", re.I)
EXECUTOR_RE = re.compile(
    r"(^|[;&|(\s])(python\d*(\.\d+)?(\.exe)?|py|node|deno|bun|tsx|ts-node|pwsh(\.exe)?|powershell(\.exe)?|bash|sh|zsh|"
    r"cmd(\.exe)?|call|start|Start-Process|Invoke-Item|ii|wscript|cscript|ruby|perl|&|\.)(?=\s|$)|"
    r"(^|[;&|(\s])\.{1,2}[\\/]\S+", re.I)


def paths_in(cmd):
    return re.findall(r"(\"[^\"]+\"|'[^']+'|[^\s;&|<>()]+)", cmd)


def join_list_args(s):
    """["reg", "add", "HKLM\\..."] -> reg add HKLM\\...  (wywolania subprocess z lista argumentow)."""
    return re.sub(r"[\"']\s*,\s*[\"']", " ", s)


# ---------------------------------------------------------------- granica projektu

# Dodatkowe katalogi dostepne bez pytania (oprocz projektu i %TEMP%). Dopisywane sa tez
# permissions.additionalDirectories z ~/.claude/settings.json (plik chroniony przez ten hook).
# Ustawienia projektu (.claude/settings*.json) sa celowo pomijane - Claude moze je zmienic.
EXTRA_ALLOWED_DIRS = [
    # os.path.join(HOME, ".claude", "projects"),  # automatyczna pamiec Claude Code
    # os.path.join(HOME, ".nuget", "packages"),
]
ALLOWED_ROOTS = []  # ustawiane w init_allowed_roots()

PATHLIKE_RE = re.compile(r"^(~|[A-Za-z]:|[\\/])|(\$|%)\S*[\\/]|(^|[\\/=])\.\.([\\/]|$)")
SWITCH_RE = re.compile(r"^/[A-Za-z?]{1,3}(:\S*)?$")  # przelaczniki cmd: /s /q /d /MT:8
NOISE_PATHS = {"/dev/null", "/dev/stdout", "/dev/stderr", "/dev/stdin", "nul", "nul:", "$null"}
GLOB_CHARS_RE = re.compile(r"[*?\[{]")
BARE_VAR_RE = re.compile(r"^\$\{?(?!(null|true|false)\b)[\w:]+\}?$", re.I)
LINK_RE = re.compile(r"\bmklink\b|\bNew-Item\b[^\n]*-ItemType\s+['\"]?(SymbolicLink|Junction|HardLink)\b|"
                     r"\bln\s+(-\w+\s+)*-\w*s|\bfsutil\s+hardlink\b|\bos\.symlink\b|\.symlink_to\(", re.I)


def _canon_root(d):
    try:
        return os.path.normcase(os.path.realpath(os.path.expandvars(os.path.expanduser(d))))
    except (OSError, ValueError):
        return None


def user_additional_dirs():
    try:
        with open(os.path.join(HOME, ".claude", "settings.json"), encoding="utf-8") as f:
            dirs = (json.load(f).get("permissions") or {}).get("additionalDirectories") or []
        out = []
        for d in dirs:
            if isinstance(d, str) and d.strip():
                e = os.path.expanduser(d)
                out.append(e if os.path.isabs(e) else os.path.join(HOME, e))
        return out
    except Exception:
        return []


def init_allowed_roots(cwd):
    project = os.environ.get("CLAUDE_PROJECT_DIR") or cwd
    roots = []
    for d in [project, TEMP_DIR] + EXTRA_ALLOWED_DIRS + user_additional_dirs():
        r = _canon_root(d)
        if r and r not in roots:
            roots.append(r)
    ALLOWED_ROOTS[:] = roots


def is_outside(p, base):
    """True, jesli sciezka wychodzi poza dozwolone katalogi (albo nie da sie jej ustalic)."""
    if not ALLOWED_ROOTS:
        return False
    s = (p or "").strip().strip("\"'")
    if not s:
        return False
    if re.search(r"\$|%\w+%", os.path.expandvars(os.path.expanduser(s))):
        return True  # nierozwiazana zmienna - nie wiadomo dokad prowadzi
    try:
        rp = real_path(s, base)
    except (OSError, ValueError):
        return True
    for r in ALLOWED_ROOTS:
        try:
            if os.path.commonpath([rp, r]) == r:
                return False
        except ValueError:  # inny dysk
            pass
    return True


def glob_base(p):
    """Czesc wzorca przed pierwszym znakiem globa: 'C:/x/**/*.py' -> 'C:/x/'."""
    s = (p or "").strip().strip("\"'")
    m = GLOB_CHARS_RE.search(s)
    if not m:
        return s
    head = s[:m.start()]
    cut = max(head.rfind("/"), head.rfind("\\"))
    return head[:cut + 1] if cut >= 0 else ""


def candidate_tokens(cmd):
    """Tokeny polecenia + tokeny ukryte w cudzyslowach (python -c "...", -Command "...", bash -c "...")."""
    out = []
    for tok in paths_in(cmd):
        t = tok.strip("\"'")
        out.append(t)
        if tok[:1] in "\"'" and not PATHLIKE_RE.search(t):
            out.extend(x.strip("\"'") for x in paths_in(re.sub(r"[(),=\[\]{}]", " ", t)))
    return out


def outside_paths(cmd, base):
    hits = []
    for t in candidate_tokens(cmd):
        if t.startswith("-") and "=" in t:
            t = t.split("=", 1)[1]
        if not t or t.lower() in NOISE_PATHS or SWITCH_RE.match(t) or "://" in t:
            continue
        # sciezki jawnie wychodzace (C:, /, ~, .., zmienne) oraz wzgledne, ktore moga prowadzic
        # przez symlink/junction w projekcie (zawieraja separator albo istnieja na dysku)
        if not (PATHLIKE_RE.search(t) or re.search(r"[\\/]", t) or os.path.lexists(os.path.join(base, t))):
            continue
        b = glob_base(t)
        if b and is_outside(b, base) and t not in hits:
            hits.append(t)
    return hits


def resolve_file(tok, bases):
    t = tok.strip("\"'")
    for b in bases:
        p = os.path.expanduser(t)
        if not os.path.isabs(p):
            p = os.path.join(b, p)
        m = re.match(r"^[\\/]([A-Za-z])[\\/](.*)", p)
        if m:
            p = m.group(1) + ":/" + m.group(2)
        if os.path.isfile(p):
            return p
    return None


def scan_scripts(c, cwd, depth):
    """Sprawdza tresc plikow skryptow uruchamianych przez polecenie."""
    if depth >= MAX_DEPTH or not EXECUTOR_RE.search(c):
        return
    bases = git_dirs(c, cwd)
    for tok in paths_in(c):
        if not SCRIPT_TOKEN_RE.search(tok.strip("\"'")):
            continue
        p = resolve_file(tok, bases)
        if not p:
            continue
        try:
            if os.path.getsize(p) > MAX_SCRIPT_BYTES:
                ask(f"Uruchamianie duzego skryptu {tok} (guard nie sprawdzil jego tresci)")
                continue
            with open(p, "r", encoding="utf-8", errors="replace") as f:
                content = f.read()
        except OSError:
            continue
        check_shell(content, cwd, depth + 1, script=True)


def check_self_protection(raw, cd, cwd):
    toks = paths_in(raw)
    if re.search(r"disableAllHooks|allowManagedHooksOnly", raw, re.I):
        deny("Proba wylaczenia hookow Claude Code")
    if re.search(r"\bclaude\s+config\s+(set|add|remove)\b", raw, re.I):
        deny("Zmiana konfiguracji Claude Code")
    writes = DESTRUCTIVE_RE.search(cd) or WRITE_API_RE.search(raw)
    if writes and (any(is_protected_path(t, cwd) for t in toks) or SELF_KEYWORD_RE.search(raw)
                   or re.search(r"(~|HOME\}?|USERPROFILE%?|\\Users\\[^\\\s]+)[\\/]\.claude([\\/](settings|hooks|CLAUDE\.md)|\.json)", raw, re.I)):
        deny("Modyfikacja zabezpieczen Claude Code (hook/ustawienia/CLAUDE.md)")


def check_shell(cmd, cwd, depth=0, script=False):
    raw = cmd
    c = join_list_args(cmd)
    cd = HARMLESS_REDIR_RE.sub(" ", c)
    destructive_re = DESTRUCTIVE_NOREDIR_RE if script else DESTRUCTIVE_RE
    destructive = bool(destructive_re.search(cd))
    toks = paths_in(raw)

    # 0. Ochrona samych zabezpieczen
    check_self_protection(raw, cd, cwd)

    # 1. Merge Requesty / Pull Requesty
    if MR_RE.search(c):
        deny("Tworzenie Merge Requestow / Pull Requestow")

    # 2. Operacje na branchach release
    is_push = re.search(r"\bgit\b[^\n;&|]*\bpush\b", c)
    if is_push and RELEASE_RE.search(c):
        deny("Push do brancha release")
    if re.search(r"\bgit\b[^\n;&|]*\b(checkout|switch)\b[^\n;&|]*release", c, re.I) and \
            re.search(r"\bgit\b[^\n;&|]*\b(commit|merge|rebase|cherry-pick|revert|am|pull|push|reset)\b", c):
        deny("Commit/merge/push na branchu release")
    git_write = re.search(r"\bgit\b[^\n;&|]*\b(commit|merge|rebase|cherry-pick|revert|am|pull|push|reset|stash\s+pop|apply)\b", c)
    if git_write:
        for d in git_dirs(c, cwd):
            b = current_branch(d)
            if b and RELEASE_RE.search(b):
                deny(f"Operacja git zmieniajaca historie/push na branchu release ('{b}')")
    if re.search(r"\bgit\b[^\n;&|]*\b(update-ref|branch\s+-[fM])\b[^\n]*release", c, re.I):
        deny("Modyfikacja brancha release")

    # 3. Funkcje systemowe
    if SYSTEM_CMD_RE.search(c):
        deny("Edycja funkcji/ustawien systemowych")
    if REG_MENTION_RE.search(c) and REG_WRITE_RE.search(c):
        deny("Modyfikacja rejestru systemu")
    if destructive and any(is_system_path(p, cwd) for p in toks):
        deny("Modyfikacja plikow w katalogach systemowych")
    if re.search(r"\bgit\s+config\b[^\n;&|]*--system\b", c):
        deny("Zmiana systemowej konfiguracji git (git config --system)")

    # 4. Zasoby / dyski zdalne
    if mentions_remote_path(c) and destructive:
        deny("Usuwanie/edycja danych na zasobie/dysku zdalnym")
    if REMOTE_EXEC_RE.search(c) and REMOTE_DESTRUCTIVE_RE.search(c):
        deny("Usuwanie/edycja danych na zdalnym hoscie")
    if re.search(r"\b(scp|rsync|pscp)\b", c, re.I):
        last = toks[-1].strip("\"'") if toks else ""
        if re.match(r"^[^\\/:]+:", last) and not re.match(r"^[A-Za-z]:", last):
            deny("Zapis danych na zdalnym hoscie (scp/rsync)")
    if re.search(r"\b(s?ftp)\b", c, re.I) and re.search(r"\b(put|mput|rm|del|delete|rmdir|rename)\b", c, re.I):
        deny("Zapis/usuwanie danych na zdalnym hoscie (sftp/ftp)")
    if re.search(r"\b(net\s+use\b[^\n]*/delete|Remove-PSDrive|Remove-SmbShare|Set-SmbShare)", c, re.I):
        deny("Modyfikacja zasobow zdalnych")
    if re.search(r"\bgit\s+push\b[^\n]*(--delete|\s:\S|--force|-f\b|--mirror|--prune)", c):
        deny("Usuwanie/nadpisywanie danych w zdalnym repozytorium (push --delete/--force/--mirror)")

    # 5. Zakodowane polecenia PowerShell - dekoduj i sprawdz tresc
    if depth < MAX_DEPTH and re.search(r"\b(pwsh|powershell)", c, re.I):
        for m in ENCODED_RE.finditer(c):
            try:
                decoded = base64.b64decode(m.group(1)).decode("utf-16-le")
            except Exception:
                continue
            check_shell(decoded, cwd, depth + 1)

    # 6. Skrypty uruchamiane z plikow - sprawdz ich tresc
    scan_scripts(raw, cwd, depth)

    # 7. Push (zawsze reczne potwierdzenie)
    if is_push:
        ask("git push")

    if script:
        return  # w tresci skryptow egzekwujemy tylko reguly DENY i push

    # 8. Instalacja / skrypty z sieci / niejawne pobieranie pakietow
    if PIPE_EXEC_RE.search(c):
        ask("Wykonywanie skryptu pobranego z sieci / zakodowanego polecenia")
    if INSTALL_RE.search(c):
        ask("Instalowanie aplikacji/pakietow z sieci")
    if DOTNET_IMPLICIT_RESTORE_RE.search(c) and not re.search(r"--no-restore\b", c):
        ask("dotnet build/run/test bez --no-restore pobiera pakiety NuGet z sieci")
    if MSBUILD_RESTORE_RE.search(c):
        ask("msbuild restore pobiera pakiety NuGet z sieci")
    if BUILD_TOOL_NET_RE.search(c):
        ask("Narzedzie pobierajace zaleznosci/obrazy z sieci (maven/gradle/docker/pip download)")

    # 9. Dane bezpieczenstwa
    if SECRET_CMD_RE.search(c) or any(is_secret_path(p) for p in toks):
        ask("Dostep do danych zwiazanych z bezpieczenstwem (hasla/klucze/tokeny)")

    # 10. Trwale zmiany srodowiska
    if re.search(r"\bgit\s+config\b[^\n;&|]*(--global|core\.hooksPath|credential\.|alias\.|url\.|http\.)", c) and \
            not re.search(r"\bgit\s+config\b[^\n;&|]*\s(--get\S*|--list|-l)\b", c):
        ask("Zmiana globalnej konfiguracji git")
    if destructive and any(PERSIST_RE.search(abs_norm(p, cwd)) for p in toks):
        ask("Trwala zmiana srodowiska (profil powloki/autostart/konfiguracja git/hooki git)")

    # 11. Wysylanie danych do internetu (localhost nie jest internetem)
    urls = re.findall(r"https?://[^\s\"'<>)]+", c, re.I)
    remote_urls = [u for u in urls if not LOCAL_URL_RE.match(u)]
    net_hits = {m.group(1).lower().strip() for m in NETWORK_RE.finditer(c)}
    only_local_http = net_hits and net_hits <= HTTP_TOOLS and urls and not remote_urls
    if (net_hits and not only_local_http) or remote_urls:
        ask("Komunikacja z siecia / wysylanie danych do internetu")
    if GIT_NET_RE.search(c):
        ask("Komunikacja git ze zdalnym repozytorium (clone/fetch/pull)")

    # 12. Granica projektu (odczyt, zapis i usuwanie poza katalogiem projektu)
    if is_outside(cwd, cwd):
        ask(f"Polecenie uruchamiane w katalogu poza projektem ({cwd})")
    outside = outside_paths(cd, cwd)
    if outside:
        ask("Dostep do sciezek poza katalogiem projektu: " + ", ".join(o[:120] for o in outside[:3]))
    if LINK_RE.search(c):
        ask("Tworzenie symlinku/junctiona/hardlinku (moze wyprowadzic dostep poza projekt)")
    if DESTRUCTIVE_NOREDIR_RE.search(cd) and any(BARE_VAR_RE.match(t) for t in candidate_tokens(cd)):
        ask("Zapis/usuwanie na sciezce ze zmiennej (guard nie zna jej wartosci)")


# ---------------------------------------------------------------- inne narzedzia

def check_write(ti, cwd):
    p = ti.get("file_path") or ti.get("notebook_path") or ""
    content = " ".join(str(ti.get(k) or "") for k in ("content", "new_string", "new_source"))
    for e in ti.get("edits") or []:
        if isinstance(e, dict):
            content += " " + str(e.get("new_string") or "")
    if is_remote_path(p):
        deny("Edycja pliku na zasobie/dysku zdalnym")
    if is_system_path(p, cwd):
        deny("Edycja plikow systemowych")
    if is_protected_path(p, cwd):
        deny("Modyfikacja zabezpieczen Claude Code (hook/ustawienia/CLAUDE.md)")
    if re.search(r"disableAllHooks|allowManagedHooksOnly", content, re.I):
        deny("Proba wylaczenia hookow Claude Code")
    n = abs_norm(p, cwd)
    if PROJECT_SETTINGS_RE.search(n):
        ask("Zmiana ustawien Claude Code w projekcie (.claude/settings*.json)")
    if PERSIST_RE.search(n):
        ask("Trwala zmiana srodowiska (profil powloki/autostart/konfiguracja git/hooki git/.mcp.json)")
    if p and is_outside(p, cwd):
        ask(f"Zapis poza katalogiem projektu ({p[:150]})")


BROWSER_PREFIXES = ("mcp__claude_browser__", "mcp__claude-in-chrome__")
BROWSER_READONLY = {
    "find", "read_page", "get_page_text", "read_console_messages", "read_network_requests",
    "tabs_context", "tabs_context_mcp", "tabs_create", "tabs_create_mcp", "tabs_close", "tabs_close_mcp",
    "tabs_select", "resize_window", "preview_list", "preview_logs", "preview_stop",
    "list_connected_browsers", "select_browser", "switch_browser", "shortcuts_list",
}
COMPUTER_READONLY = {"screenshot", "scroll", "scroll_to", "zoom", "hover", "wait"}


def check_browser(name, ti):
    name = name.split("__")[-1].lower()
    ti = ti if isinstance(ti, dict) else {}
    if name in BROWSER_READONLY:
        return
    if name in ("navigate", "preview_start"):
        url = str(ti.get("url") or "").strip()
        if not url or LOCAL_URL_RE.match(url):
            return  # dev server z launch.json / localhost / wstecz-dalej
        ask(f"Przegladarka: otwarcie strony zewnetrznej ({url[:120]})")
        return
    if name == "computer":
        action = str(ti.get("action") or "")
        if action in COMPUTER_READONLY:
            return
        ask(f"Przegladarka: akcja '{action}' (klikniecie/wpisanie moze wyslac dane lub zatwierdzic operacje)")
        return
    if name == "browser_batch":
        for a in ti.get("actions") or []:
            if isinstance(a, dict):
                check_browser(str(a.get("name") or ""), a.get("input") or {})
        return
    if name == "javascript_tool":
        ask("Przegladarka: wykonanie JavaScriptu na stronie")
        return
    ask(f"Przegladarka: {name} (moze wyslac dane)")


def check_ccd(low):
    if "permission_mode" in low:
        deny("Zmiana trybu uprawnien sesji")
    if "move_to_cloud" in low:
        ask("Przeniesienie sesji do chmury - tam lokalny hook guard.py nie dziala")
    if low.startswith("mcp__ccd_settings__") and not re.search(r"(get|read|list)", low):
        ask("Zmiana ustawien aplikacji Claude")
    if re.search(r"(delete|trash|destroy|drop)", low):
        deny("Trwale usuwanie danych (sesja/grupa)")


def check_mcp(low):
    if re.search(r"(delete|trash|remove|destroy|drop)", low):
        deny("Usuwanie danych na zasobie zdalnym (MCP)")
    if re.search(r"(update|edit|modify|move|rename|overwrite)", low):
        deny("Edycja danych na zasobie zdalnym (MCP)")
    if re.search(r"(create|upload|share|send|post|publish|copy|batch|write|submit|form_input|file_upload|trigger|run_)", low):
        ask("Wysylanie danych do uslugi zewnetrznej (MCP)")
    if "download" in low:
        ask("Pobieranie pliku z uslugi zewnetrznej (MCP)")


# ---------------------------------------------------------------- main

def evaluate(data):
    tool = data.get("tool_name", "") or ""
    ti = data.get("tool_input", {}) or {}
    cwd = data.get("cwd") or os.getcwd()
    low = tool.lower()
    init_allowed_roots(cwd)

    if tool in ("Bash", "PowerShell"):
        check_shell(ti.get("command", "") or "", cwd)
    elif tool in ("Edit", "Write", "MultiEdit", "NotebookEdit"):
        check_write(ti, cwd)
    elif tool in ("Read", "Grep", "Glob"):
        p = ti.get("file_path") or ti.get("path") or ti.get("pattern") or ""
        if is_secret_path(p) or (tool == "Grep" and re.search(r"(password|passwd|secret|api[_-]?key|token|private key)",
                                                               ti.get("pattern", "") or "", re.I)):
            ask("Odczyt danych zwiazanych z bezpieczenstwem (hasla/klucze/tokeny)")
        targets = [ti.get("file_path")] + [glob_base(ti.get(k) or "") for k in ("path", "pattern")
                                           if k == "path" or tool == "Glob"]
        for t in targets:
            if isinstance(t, str) and t.strip() and is_outside(t, cwd):
                ask(f"Odczyt poza katalogiem projektu ({t[:150]})")
                break
    elif tool in ("WebFetch", "WebSearch"):
        ask("Wysylanie zapytania do internetu")
    elif tool == "Artifact":
        action = ti.get("action") or "publish"
        if action == "delete":
            deny("Usuwanie danych na zasobie zdalnym (Artifact)")
        if action in ("publish", "pin", "unpin"):
            ask("Publikacja/zmiana danych w internecie (Artifact)")
    elif tool == "RemoteTrigger" or (tool == "Agent" and ti.get("isolation") == "remote"):
        ask("Uruchamianie agenta w chmurze - tam lokalny hook guard.py nie dziala")
    elif tool in ("SuggestPluginInstall",):
        ask("Instalacja pluginu (moze dodac wlasne hooki/serwery MCP)")
    elif low.startswith(BROWSER_PREFIXES):
        check_browser(low, ti)
    elif low.startswith("mcp__ccd_"):
        check_ccd(low)
    elif low.startswith("mcp__"):
        check_mcp(low)


def main():
    data = None
    try:
        data = json.loads(sys.stdin.buffer.read().decode("utf-8", "replace"))
        if not isinstance(data, dict):
            raise ValueError("wejscie nie jest obiektem JSON")
    except Exception as e:
        deny(f"Nieczytelne wejscie hooka ({e}) - fail-closed")
        finish(data)
    try:
        evaluate(data)
    except Exception as e:
        deny(f"Blad wewnetrzny guard.py ({type(e).__name__}: {e}) - fail-closed")
    finish(data)


if __name__ == "__main__":
    main()