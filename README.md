# hermes-virtual-desktop

Give an agent its own **browser-visible desktop**: a virtual X display running XFCE, served to any
browser with noVNC, plus a Chrome inside it that the agent drives exactly over DevTools (CDP) while a
human can watch and click the same screen.

One command installs it as systemd services that survive reboot. No monitor, no GPU, no client
software — open a URL and the desktop is there.

```
virtual X display (TigerVNC)  ->  XFCE desktop in memory
websockify + noVNC            ->  http://<host>:6080/vnc.html
Chrome inside that display     ->  CDP on 127.0.0.1:9333
```

## What it is called

There is no single product name. Use the parts, or the category:

| Name | Refers to |
|---|---|
| virtual desktop / virtual display | a desktop that exists only in memory — an X display (`:1`, `:2`, …) |
| VNC (Virtual Network Computing) | the protocol carrying pixels and input |
| noVNC / HTML5 VNC client | the web page that speaks VNC in a browser tab — [novnc.com](https://novnc.com/noVNC/) |
| websockify | translates the browser's WebSocket to plain TCP to the VNC port — [repo](https://github.com/noVNC/websockify) |
| browser-based remote desktop / VDI | the industry category |
| computer-use desktop / agent desktop | the agent case: the same screen is where the agent's browser runs |

## Which case are you in?

| Where Hermes runs | Where the human is | Use | Installer |
|---|---|---|---|
| Linux, any | any device with a browser | the browser door (noVNC) — the default | `./install.sh` |
| Linux | Windows/Linux/macOS, wants a native window | Xpra shadow (keeps the same profile) | [docs/native-window.md](docs/native-window.md) |
| Windows, same machine as the human | at that machine | its own Chrome window + CDP, no transport at all | [windows/install.ps1](windows/) |
| Windows, headless | anywhere | the Linux stack inside WSL2, browser door | `./install.sh` in WSL |

## Quick start

```bash
git clone https://github.com/raymondclowe/hermes-virtual-desktop.git
cd hermes-virtual-desktop
./install.sh
```

Then open `http://<host-ip>:6080/vnc.html`.

Two independent desktops on one host (each with its own browser and profile):

```bash
./install.sh --display 2 --web-port 6081 --cdp-port 9334
```

Check, preview, remove:

```bash
./install.sh --verify 1
./install.sh --dry-run --display 1
./install.sh --uninstall 2
```

## What the installer does

| Step | Detail |
|---|---|
| packages | tigervnc, novnc, websockify, xfce4, dbus-x11, xdotool, python3-websockets |
| session script | `~/.vnc/xstartup<N>` pins `DISPLAY=:<N>` and execs `xfce4-session` in the foreground |
| `hermes-vnc-<N>.service` | TigerVNC display `:<N>`, `-localhost yes -SecurityTypes None`, 24-bit |
| `hermes-novnc-<N>.service` | `websockify --web=/usr/share/novnc <web-port> localhost:590<N>` |
| browser | Chrome (Google build) if available, else Chromium — see [docs/profile-persistence.md](docs/profile-persistence.md) |
| `hermes-chrome-<N>.service` | that browser on the display `:<N>`, own **persistent** profile, CDP port, memory/task caps |
| browser door | `/usr/share/novnc/index.html` redirect so `host:port` works without `/vnc.html` |
| firewall | ufw allows the web port from `--allow-cidr` (default `192.168.0.0/24`) only |
| verification | ten live checks, including a real RFB handshake and a JS evaluation inside Chrome |

Flags: `--display`, `--web-port`, `--geometry`, `--user`, `--allow-cidr`, `--no-ufw`,
`--no-chrome`, `--cdp-port`, `--browser auto|chrome|chromium`, `--profile-dir`, `--dry-run`,
`--verify N`, `--uninstall N`.

## Three ways to drive it — pick by symptom, not by taste

Having several ways is only useful if exactly one is the default and the others are reached by a
rule. This is the rule.

| # | Method | Command / API | Use when | Do not use when |
|---|---|---|---|---|
| 1 | **Page API** — call the site's own `fetch`/JS with the logged-in cookies | CDP `Runtime.evaluate` inside the tab | the site has an API or the page exposes data; you want speed and no pixels | you must produce a real click (submit, upload, payment) |
| 2 | **DOM action over CDP** (default) | `locator.click()`, `fill()`, `press()` via CDP | almost always — exact, fast, no coordinates, works on off-screen elements | the page ignores or blocks CDP-injected input, or is a canvas/WebGL/cross-origin widget |
| 3 | **X11 input** — real pointer/keyboard at the X server | `bin/desktop_input.py click --selector '#id'` | a click must be indistinguishable from a human's; canvas maps; sites that fingerprint the automation session; the human must see the pointer move | you need speed, or the element is off-screen (X11 cannot scroll to it) |
| 4 | **Human in the loop** — the noVNC page | browser URL | passwords, 2FA, CAPTCHA, anything that must not pass through the agent | never for routine work |

The helper in `bin/` combines 2 and 3 the only sane way: **CDP reads, X11 acts.** CDP finds the
element, scrolls it into view and reports its box; `xdotool` moves the pointer to the mapped screen
pixel and clicks, or types. See [docs/input-ladder.md](docs/input-ladder.md).

```bash
./bin/desktop_input.py --display :1 --cdp http://127.0.0.1:9333 where --selector '#submit' --dry-run
./bin/desktop_input.py --display :1 click --selector '#submit'
./bin/desktop_input.py --display :1 type  --selector '#search' --text 'hello'
```

**What none of this fixes:** fingerprint-level blocking (a profile that has never been used by a
human, headless flags, missing plugins). That is a browser-profile problem, not an input problem —
fix it by using this desktop's real Chrome and logging in once by hand, not by adding another
automation stack.

## The profile is the point — Chrome, not Chromium

A desktop whose browser forgets you is a desktop you log into every morning. The installer therefore
gives the browser a **persistent profile** at `~/.config/hermes-desktop/<browser>-<display>/`, and
prefers **Chrome** because only the Google build can sign in to Chrome Sync — which is what carries
bookmarks, passwords and extensions from the human's other machines.

| | Chrome | Chromium |
|---|---|---|
| everything a browser does | yes | yes |
| profile persists on disk | yes | yes |
| Chrome Sync (bookmarks, passwords, extensions) | **yes** | **no** (no Google API keys) |
| Linux arm64 | not published by Google | yes |

`--verify N` prints the profile path and size and fails if it is missing. `--uninstall N` never
deletes it. Sign in once through the browser door; the agent's browser is then already logged in.
Details, backup and the password-store trade-off: [docs/profile-persistence.md](docs/profile-persistence.md).

## Native window instead of a browser tab (Windows client, remote Linux host)

If the human is on Windows, Hermes is on a remote Linux host, and they want Chrome to look like an
application window rather than a tab, the optional lane is **Xpra**: it forwards the desktop (or a
single app) and lets the client's own window manager draw it — real title bar, resize, clipboard,
survives disconnect.

```bash
# host: mirror the existing desktop, loopback only
sudo apt-get install -y xpra
/usr/bin/python3 /usr/bin/xpra shadow :1 --bind-tcp=127.0.0.1:14500 --html=on \
    --daemon=no --systemd-run=no --notifications=no --tray=no
```

```bat
:: Windows client (install Xpra first): attach over SSH
Xpra_cmd.exe attach ssh://USER@HOST/14500
```

Shadow keeps the **same** Chrome and the same saved logins. Seamless mode (`xpra seamless`) gives a
single Chrome window but needs its own profile. Neither is installed by default — the browser door
stays the default because it needs nothing on the client. Tested commands, the Windows client, the
seamless variant and the security rules: [docs/native-window.md](docs/native-window.md).

Why not RDP RemoteApp: single-application RDP requires Windows Server with per-user licences, and on
Linux `xrdp` publishes a whole desktop, not individual applications.

## Windows: Hermes on the same machine as the human

Nothing to stream. The human's own session is the desktop, so the only job is a Chrome the agent can
drive, in a window the human can see, with a profile that keeps logins:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File windows/install.ps1
```

It finds Chrome (Edge as fallback), creates `%LOCALAPPDATA%\hermes-desktop\browser-<port>`, registers
a **Scheduled Task at logon** — a service in session 0 could never show a window — starts the browser
now, and proves CDP answers on `127.0.0.1:<port>`. `-Uninstall` removes the task and keeps the profile.

Never point it at the human's normal Chrome profile: Chrome locks a profile to one process, so the
agent's launch would exit and automation would land in their live session. Details:
[windows/README.md](windows/README.md).

Verified on Windows 11 with PowerShell 5.1: script parses clean, Chrome detected at
`C:\Program Files\Google\Chrome\Application\chrome.exe`, and the logon task registers `Ready`
for the current identity. The live browser launch is the one step that needs a real run on the target
machine.

## Several instances on one machine

Ports belong to the machine, not to a Hermes profile. Two instances on one host want the same `6080`
and `9333`, and the second one loses — silently, in the worst way: Chrome cannot open the CDP port,
starts anyway, and the agent connects to **whatever is answering**, which may be the other instance's
browser or the human's own Chrome, with the wrong logins on the wrong sites.

The allocation rule is arithmetic, and the installer picks the block for you:

```
display :N  ->  VNC 5900+N   noVNC 6079+N   CDP 9332+N      (N=1: 5901 / 6080 / 9333)
```

```bash
./install.sh --suggest
#   ./install.sh --display 3 --web-port 6082 --cdp-port 9335
```

Before creating anything the installer refuses a port owned by someone else and names the owner:

```
CONFLICT CDP port 9333 is held by pid 346695 (/home/op3/.config/chrome-raymond)
```

and `--verify` proves the port is *yours*, not merely answering:

```
PASS  CDP 9335 belongs to this install (pid 476377)
```

Windows uses the same rule with `-CdpPort`. Port tables, how to find a port's owner, and the
container/WSL2 boundary for true isolation: [docs/ports.md](docs/ports.md).

## Requirements

- Ubuntu 22.04/24.04 (tested on 24.04, Chrome 156, TigerVNC 1.13). Any Debian-family distro with
  the same packages should work.
- `sudo` for the installing user (packages, systemd units, firewall).
- ~450 MB RAM per desktop, ~250 MB for Chrome.
- A LAN. Do not expose the web port to the internet.

## Verify

```
$ ./install.sh --verify 9
Verifying display :9 (VNC 5909, web 6089)
  PASS  hermes-vnc-9 active
  PASS  hermes-novnc-9 active
  PASS  X socket X9 exists
  PASS  VNC listening on 127.0.0.1:5909 (loopback only)
  PASS  noVNC listening on 0.0.0.0:6089
  PASS  RFB handshake: b'RFB 003.008\n' types=[1]
  PASS  /vnc.html returns 200
  PASS  websockify -> VNC proven (first frame: b'RFB 003.008\n')
  PASS  X session answers on :9 (active window: New Tab - Google Chrome)
  PASS  CDP 9339 belongs to this install (pid 476377)
  PASS  Chrome on :9 executes JS (CDP 9339, readyState=complete)
  PASS  profile persists at /home/op3/.config/hermes-desktop/chrome-9 (8.2M)

RESULT: display :9 is live.  Browser door: http://192.168.0.102:6089/vnc.html
```

`types=[1]` means security type "None" — no password prompt. `[2]` would mean a prompt.
The WebSocket check proves the web port really reaches the VNC server rather than just serving a page.
The last check exists because a Chrome with a dead zygote still listens on its CDP port while every
tab hangs — services "running" is not the same as a desktop that works.

## Verify against a page you control, not a public website

Any external page can be redesigned out from under a test — `example.com` no longer has an `<h1>`, so
an acceptance check based on it fails for a reason that has nothing to do with the desktop. Use the
small page in this repo instead; it reports what happened in its own title and in
`window.__selftest`:

```bash
PAGE="file://$PWD/bin/selftest.html"
bin/desktop_input.py --display :1 --cdp http://127.0.0.1:9333 open "$PAGE"
bin/desktop_input.py --display :1 --cdp http://127.0.0.1:9333 where --selector '#ok' --dry-run
bin/desktop_input.py --display :1 --cdp http://127.0.0.1:9333 click --selector '#btn'
bin/desktop_input.py --display :1 --cdp http://127.0.0.1:9333 type  --selector '#name' --text 'hello'
```

Measured on a fresh install: the title becomes `Hermes desktop selftest — 1 clicks`, the input reads
`hello`, and `window.__selftest.trusted` shows `click:isTrusted=true` / `input:isTrusted=true` — which
is the whole point of the X11 lane: the page sees real input, not synthetic events.

For a pure "can the agent evaluate anything at all" check, `Runtime.evaluate` of `1+1` needs no page
and no network at all.

## Security model

| Port | Bound to | Auth | Reachable by |
|---|---|---|---|
| 590N VNC | `127.0.0.1` | none | only websockify on the host |
| 6080+ noVNC | `0.0.0.0` | none — the firewall is the gate | the `--allow-cidr` subnet only |
| 9333 CDP | `127.0.0.1` | none | the agent on that host |

The web port is a **full desktop as that user**, with their SSH keys and browser sessions. Keep it
LAN-only. For anything beyond a LAN, put Apache Guacamole (or a proxy with real authentication) in
front of it.

## After install

1. Open the browser door and log in to the sites you need, once, by hand. Sessions persist in the
   Chrome profile.
2. Point the agent's browser tooling at the CDP port. One Chrome per install, never shared.
3. Re-run `./install.sh --verify N` after any reboot or config change.

## Troubleshooting

See [docs/troubleshooting.md](docs/troubleshooting.md). The four that bite most: the zygote dying
without a session bus, the passwordless-server refusal, per-display `xstartup`, and Chrome 136+
refusing `--remote-debugging-port` without an explicit `--user-data-dir`.

## Alternatives

| Option | What it is | Use when |
|---|---|---|
| [LinuxServer.io webtop](https://docs.linuxserver.io/images/docker-webtop/) | container with a full desktop streamed to the browser on 3001 | you want a container, not host packages |
| [Apache Guacamole](https://guacamole.apache.org/) | browser-to-VNC/RDP/SSH gateway with logins, 2FA, audit | many users, or exposure beyond a LAN |
| [Kasm Workspaces](https://kasmweb.com/) | managed container desktops per user | a team each needing a disposable desktop |

This repo is the lightest option (no Docker) and the only one that also wires the agent's browser
control port as part of the install.

## Layout

```
install.sh              provision / verify / uninstall (bash, no dependencies beyond apt)
bin/desktop_input.py    X11-level click/type/key, geometry read over CDP
bin/selftest.html       tiny local page with a counter, an input and a log — the drive test
docs/input-ladder.md    the four input paths, with code and the decision rule
docs/profile-persistence.md  Chrome vs Chromium, signing in, backup, password store
docs/ports.md           port blocks per instance, and the wrong-browser trap
docs/native-window.md   optional Xpra lane for a native-looking window (Windows client)
docs/troubleshooting.md symptom -> cause -> fix, from measured failures
systemd/                example unit for the optional Xpra lane
windows/                PowerShell installer for Hermes running on Windows itself
skill/SKILL.md          Hermes skill file: drop into a Hermes skills dir
AGENTS.md               instructions for an agent told "set this up"
```

## License

MIT
