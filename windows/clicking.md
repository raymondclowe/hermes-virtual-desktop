# Windows, with the human at that same machine

The awkward case. Everything is local — no transport, no remote display — and yet the default
behaviours all get in the way:

- a Chrome launched by a service or a scheduled task lands in **session 0**, where there is no
  visible desktop at all;
- a Chrome launched by an agent *inside* the human's session shows up, but tabs the agent creates
  may be in a window the human never looks at, and a tab left in the background is throttled;
- CDP-driven clicks are refused outright by some sites that detect automation;
- the profile that keeps logins is not the human's daily profile, and cannot be — Chrome locks a
  profile to one running process.

This page is the working recipe. Everything on it was run on Windows 11 / PowerShell 5.1 / Chrome 157.

---

## 1. Launch a browser that actually stays

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File windows/install.ps1 -CdpPort 9333
```

Rule of thumb: **one port, one profile, one running browser**. The script enforces it — if the port
already serves the same profile it reuses that process instead of starting a second; if the port is
held by anything else it refuses and names the owner.

Two failure modes to know before you debug blind:

| Symptom | Cause | Fix |
|---|---|---|
| window never appears, CDP still answers | the process is in session 0 (started by a service) | start it from the interactive session — the script's Scheduled Task does exactly this |
| `chrome.exe` exits immediately, no port | the `--user-data-dir` is already open by another Chrome | use a dedicated profile, never the human's `Google\Chrome\User Data` |
| browser opens but every tab hangs | no renderer; on Linux this is the missing session bus, on Windows usually a broken GPU sandbox | check `chrome://gpu`, restart with `--disable-gpu-sandbox` once to confirm |

## 2. Keep the session alive across agent restarts

The browser is deliberately **not** a child of the agent. If the agent restarts, the browser should
still be there, still logged in:

- the Scheduled Task opens it at logon;
- `install.ps1` run again is a no-op that reuses the running process;
- reconnecting is one call: `connect_over_cdp("http://127.0.0.1:9333")`.

Never kill the browser to "clean up" — kill the *agent's* connection. A killed browser loses in-page
state the human may be looking at, and any half-typed form.

## 3. When CDP input is refused

A CDP-injected click arrives with `isTrusted: true` — Chrome sets that flag itself — so a site that
checks only the flag will accept it. Sites that block automation use other signals: a pointer that
jumps straight to the target with no hover trail, keystroke timing that is too regular, a browser
carrying automation switches, their own challenge script, or account-level scoring. The click is
accepted and does nothing, and nothing is thrown.

Check whether the event arrives at all before concluding anything:

```python
page.evaluate("""() => new Promise(r => {
  document.addEventListener('click', e => r({trusted: e.isTrusted, x: e.clientX, y: e.clientY}), {once: true});
  setTimeout(() => r({timeout: true}), 1000);
})""")
```

If it never fires, the click is not reaching the page. If it fires with `trusted: true` and the site
still ignores it, the site is detecting the automation — stop fighting the DOM. Two things work:

### 3a. Real input at the Windows level with AutoIt

[AutoIt](https://www.autoitscript.com/) moves the actual pointer and sends real keystrokes, so the
browser cannot tell them from the human's. It is installed once (`autoit3.exe`, plus the
`AutoItX3.dll` COM object if you prefer COM).

The pattern: find the target's screen rectangle over CDP — that part still works, it is only *input*
that is refused — then click those coordinates with AutoIt.

```autoit
; click_at.au3  — run as: autoit3.exe click_at.au3 812 431
#include <Misc.au3>
Local $x = Number($CmdLine[1]), $y = Number($CmdLine[2])
MouseMove($x, $y, 0)
Sleep(80)            ; some pages need the hover to register first
MouseClick("left", $x, $y, 1, 0)
```

```powershell
# same thing through COM, no #include needed
$auto = New-Object -ComObject AutoItX3.Control
$auto.MouseMove(812, 431, 0); Start-Sleep -Milliseconds 80; $auto.MouseClick("LEFT", 812, 431, 1, 0)
```

Typing is `Send("text")` — it goes to whatever window has focus, so click the field first. For text
with characters that have meaning to AutoIt (`{`, `+`, `^`), use `Send("{SPACE}")`-style tokens or
`ControlSend` on the window handle.

Getting the coordinates is the part worth being careful with: CDP gives you the rectangle **in page
coordinates**, and you must add the browser window's origin and subtract any scroll. Do it once per
element, then verify by screenshot — a click that lands 40px off will happily type into the wrong
field and look like success.

### 3b. Do it in software instead of clicking

Before reaching for real input, check whether the site offers a way that needs no pointer at all: a
`fetch` against its own API with the session cookies the browser already holds, keyboard navigation,
or the site's own import/export. Real clicks are the fallback, not the first move.

## 4. Things that will bite

| Trap | What happens | Do instead |
|---|---|---|
| driving the human's live window | they are typing in it; your click steals focus | give the agent its own window/port, or ask before touching theirs |
| leaving tabs in the background | Chrome throttles timers; the page behaves oddly and looks broken | activate the tab (`Page.bringToFront`) before interacting |
| `--headless` when a human must log in | no window to log in through, and Sync prompts fail silently | run windowed; log in once, the profile keeps it |
| long `Send()` strings | dropped characters on a busy box | type in short chunks and read the value back over CDP to confirm |
| one profile, two Windows accounts | the second launch fails to acquire the lock | one profile directory per account |

## 5. What "done" looks like

- `Invoke-RestMethod http://127.0.0.1:9333/json/version` returns a version and a WebSocket URL;
- a page you control reports the action happened (`bin/selftest.html` sets its own title);
- if CDP input is refused, an AutoIt click on the same coordinates produces the same result, proven
  by the page's own state, not by a screenshot.
