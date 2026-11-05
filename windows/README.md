# Windows: Hermes running on the same machine as the human

No VNC, no Xpra, no RDP. The human's own Windows session **is** the desktop. What the agent needs is a
Chrome it can drive exactly, in a window the human can see, with a profile that keeps logins.

```
Hermes (same user, interactive session)
        |
        +-- launches chrome.exe  --user-data-dir=%LOCALAPPDATA%\hermes-desktop\browser-9333
        |                        --remote-debugging-port=9333
        v
   visible Chrome window  <-- human watches / takes over
        ^
        +-- CDP on 127.0.0.1:9333  <-- agent drives it exactly
```

## Install

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1
```

What it does:

| Step | Detail |
|---|---|
| browser | finds Chrome (`Program Files`, `Program Files (x86)`, `%LOCALAPPDATA%`), falls back to Edge |
| profile | `%LOCALAPPDATA%\hermes-desktop\browser-<port>` — persistent, refuses a temp path |
| autostart | a **Scheduled Task at logon**, in the interactive session |
| starts it now | then proves CDP answers on `/json/version` |
| exposure | CDP binds to `127.0.0.1` only — nothing on the LAN |

Options: `-CdpPort`, `-ProfileDir`, `-Browser chrome|edge|auto`, `-NoAutostart`, `-DryRun`,
`-Uninstall` (removes the task, keeps the profile).

## Why a Scheduled Task and not a service

Windows isolates services in session 0, which has no desktop. A Chrome started there runs headless
whether you want it or not, and the human can never see or touch it. The task runs at logon in the
user's interactive session, so the window is real.

If Hermes itself runs as a Windows service, it cannot launch that task into the session directly.
Two options:

1. Run Hermes as the logged-in user (the normal case on a workstation).
2. Keep it as a service and let the Scheduled Task start the browser at logon; the service then only
   talks to `127.0.0.1:<port>`. That works, because the browser does not need to be a child of Hermes.

## The profile

The same rule as everywhere else: the profile is the point. It lives outside the install directory, is
never deleted by the script, and can be signed in to Chrome once to pull bookmarks and passwords from
the human's account.

Do **not** point it at the human's normal Chrome profile (`%LOCALAPPDATA%\Google\Chrome\User Data`).
Chrome locks a profile to one process: the daily browser is already running, so the second launch
would exit, and the agent's automation would land in the human's live session.

## Driving it

```python
browser = playwright.chromium.connect_over_cdp("http://127.0.0.1:9333")
ctx = browser.contexts[0]
page = ctx.pages[0] if ctx.pages else ctx.new_page()
page.goto("https://example.com")
```

- The DOM/CDP path is the default on Windows too.
- There is no X11 level on Windows. If a page ignores CDP input, the fix is a real profile with a
  once-by-hand login, not another input stack; the operating-system level equivalent would be
  `SendInput`, which this repo does not ship.
- Playwright's bundled browser is **not** used: connect to the installed Chrome so the profile, the
  extensions and the human's view are one and the same.

## Verify

```powershell
Invoke-RestMethod http://127.0.0.1:9333/json/version
```

That returns the browser version and the WebSocket URL. If it hangs, the port is taken by another
instance or the profile is locked — check for a second Chrome using the same `--user-data-dir`.

## Verified

On Windows 11 with PowerShell 5.1 (`5.1.26100`):

| Check | Result |
|---|---|
| script parses (`Parser::ParseFile`) | 0 errors |
| Chrome detection | `C:\Program Files\Google\Chrome\Application\chrome.exe` chosen; Edge found as fallback |
| dry-run output | correct, exit 0 |
| logon task registers for the current identity | `state=Ready`, `user=raymo`, then removed cleanly |

Not yet exercised on Windows by this repo: the live browser launch and the CDP read-back inside the
script (both are the same two operations that are proven on Linux: start the process, then read
`/json/version`). Run it once on the target machine before relying on it.

One defect found and fixed this way: `$env:USERDOMAIN` is `WORKGROUP` on a machine that is not
domain-joined, and `WORKGROUP\user` does not resolve — `Register-ScheduledTask` fails with
`0x80070534` (no mapping between account names and SIDs). The script now uses
`[WindowsIdentity]::GetCurrent().Name`, which resolves in both cases.

## If the machine is headless (no logged-in human)

- **Best:** install the Linux stack in WSL2 (`./install.sh` inside WSL, with systemd enabled) and use
  the browser door — the same noVNC desktop, visible from any browser on the network.
- **Or** run Chrome headless with CDP: same driving API, no visible window, no profile hand-off to a
  human. Fine for scraping, useless when a human must log in or watch.
- **Or** RDP into the Windows box — that is Microsoft's own remote desktop, not something this repo
  needs to build.
