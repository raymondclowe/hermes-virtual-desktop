# hermes-virtual-desktop

Give an agent its own **screen you can watch**. On a Linux host that means a desktop that exists only
in memory, reachable in a browser tab, with a Chrome inside it that the agent drives exactly while you
click the same screen. On Windows it means a dedicated Chrome window with the same properties and none
of the transport.

## Read this part if you are a human

**Why you would want it.** An agent that can only make web requests is blind to anything interactive:
a login with a second factor, a site that blocks scripted browsers, a dashboard that needs a click, a
form whose next step depends on what appeared. A desktop removes that ceiling — the agent gets a real
browser with a real, persistent profile, and when it gets stuck you open the same screen and take over.

**What it looks like from your side.** One URL, in any browser, on any device:

```
http://<host>:6080/vnc.html
```

That is your desktop. The same screen the agent is using, live. Move the mouse, type, and the agent
sees what you did. If you want a password on it, install with `--generate-password`.

**What it costs.** No extra machine, no GPU, no client software. A few packages, three systemd
services, ~450 MB of memory for the desktop plus whatever Chrome uses.

**Is it safe?** The raw VNC port is loopback-only and never leaves the machine. The only door is the
web port, which the installer restricts to your LAN with ufw — anyone who can reach that port gets a
full desktop as that user, so keep it LAN-only. If your LAN has machines you do not trust, install with
a password; [A password on the door](#a-password-on-the-door) says exactly how much that buys.

**What it is called.** There is no single product name:

| Name | Refers to |
|---|---|
| virtual desktop / virtual display | a desktop that exists only in memory — an X display (`:1`, `:2`, …) |
| VNC (Virtual Network Computing) | the protocol carrying pixels and input |
| noVNC / HTML5 VNC client | the web page that speaks VNC in a browser tab — [novnc.com](https://novnc.com/noVNC/) |
| websockify | translates the browser's WebSocket to plain TCP to the VNC port — [repo](https://github.com/noVNC/websockify) |
| browser-based remote desktop / VDI | the industry category |
| computer-use desktop / agent desktop | the agent case: the same screen is where the agent's browser runs |

**The one-minute version.** On Linux: clone, `./install.sh`, open the URL it prints — the installer
checks its own work and refuses to claim success if anything is not answering. On Windows with the
agent on the same PC: `windows\install.ps1`, and read
[windows/clicking.md](windows/clicking.md) before the first interactive task.

---

# Recipes for an agent

Everything below is a set of **recipes**, not orders. Pick the one that matches the situation you are
actually in; each stands alone and tells you how to know it worked. If a recipe's premise does not hold
on the machine in front of you, that is the reason to take another row, not to force this one.

## Recipe 0: work out which case you are on

Three questions, answered from the live machine rather than from assumption.

| Question | How to find out |
|---|---|
| What OS am I (the agent) on? | Linux: `uname -s` says `Linux`, `ls /tmp/.X11-unix`. macOS: `uname -s` says `Darwin`. Windows: `$PSVersionTable` exists. |
| Do I have root/sudo here? | Linux: `sudo -n true`. Windows: try it — the Scheduled Task registration works unelevated for the current user. |
| Where is the human? | At this very machine, remote with a browser, or remote wanting a native-looking window. Ask if it is not obvious. |

Then take the matching row:

| Agent host | Human | Recipe |
|---|---|---|
| Linux with systemd (VM or container included) | anywhere with a browser | [Recipe 1](#recipe-1-linux-host-browser-door) |
| Linux | remote, wants a native window instead of a tab | [Recipe 2](#recipe-2-linux-host-native-window-for-a-remote-human) |
| Windows, human at that same box | local | [Recipe 3](#recipe-3-windows-host-human-at-the-same-machine) |
| Windows, nobody logged in | remote | [Recipe 4](#recipe-4-windows-host-no-human-logged-in) |
| macOS | local or remote | [Recipe 5](#recipe-5-macos-host) |

Two facts decide most of it:

- **The human's own screen is already a desktop.** If they are sitting at the machine, do not stream
  anything to them — give the agent a browser they can watch.
- **Agents and humans share ports.** One instance's `6080`/`9333` is another's collision, and the
  failure is silent. Every recipe below includes the port step; do not skip it.

## Recipe 1: Linux host, browser door

You need Linux with systemd and sudo.

```bash
git clone https://github.com/raymondclowe/hermes-virtual-desktop.git
cd hermes-virtual-desktop
./install.sh --suggest                 # which display/port block is free on THIS machine
./install.sh --display 3 --web-port 6082 --cdp-port 9335
./install.sh --verify 3
```

`--suggest` exists because ports are per machine. The rule is arithmetic: display `:N` → VNC `5900+N`,
noVNC `6079+N`, CDP `9332+N`. The installer refuses a port owned by another instance and names the
owner; `--verify` proves the CDP port carries *this* profile, not merely that something answers. That
second check is the one that matters — a taken CDP port does not make Chrome fail, it makes the agent
drive someone else's browser with someone else's logins.

Driving it afterwards, exact and coordinate-free (the default path; see
[docs/input-ladder.md](docs/input-ladder.md) for the three fallbacks):

```bash
python3 bin/desktop_input.py --display :3 --cdp http://127.0.0.1:9335 open 'https://example.org'
python3 bin/desktop_input.py --display :3 --cdp http://127.0.0.1:9335 where --selector '#login'
python3 bin/desktop_input.py --display :3 --cdp http://127.0.0.1:9335 click --selector '#login'
```

Or speak CDP directly: `playwright.chromium.connect_over_cdp("http://127.0.0.1:9335")`.

Know it worked when `./install.sh --verify N` ends with no FAIL lines — the ownership, `executes JS`
and `profile persists` lines are the three that catch real breakage.

If a site needs a login, do it once through the browser door. The profile at
`~/.config/hermes-desktop/<browser>-<N>` keeps it, which is the whole reason it lives outside the
install. Chrome is preferred over Chromium because only Chrome can sign in to Sync —
[docs/profile-persistence.md](docs/profile-persistence.md).

## Recipe 2: Linux host, native window for a remote human

Recipe 1, then add the optional lane — for a human on Windows/Linux/macOS who wants a real application
window rather than a tab.

```bash
sudo apt-get install -y xpra
/usr/bin/python3 /usr/bin/xpra shadow :1 --bind-tcp=127.0.0.1:14500 --html=on \
    --daemon=no --systemd-run=no --notifications=no --tray=no
```

The human runs `Xpra_cmd.exe attach ssh://USER@HOST/14500` and gets the desktop as one window. Shadow
keeps the **same** Chrome and logins; seamless mode gives a single Chrome window but needs its own
profile. Pin `/usr/bin/python3` — the launcher takes `python3` from `PATH` and dies on a user venv.
Commands, security notes and why RDP RemoteApp is not an option: [docs/native-window.md](docs/native-window.md).

## Recipe 3: Windows host, human at the same machine

This is the case that catches agents out, so the full method is in
[windows/clicking.md](windows/clicking.md). The short version:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File windows\install.ps1 -CdpPort 9333
Invoke-RestMethod http://127.0.0.1:9333/json/version
```

What "default behaviour does not work well" means here, and what to do instead:

| Trap | Why | Do this |
|---|---|---|
| browser never appears, CDP still answers | a service-started Chrome lives in session 0, which has no visible desktop | start it from the interactive session — the script's Scheduled Task does exactly that |
| browser dies with the agent | the agent launched it as a child | keep them separate; reconnect with `connect_over_cdp`, never relaunch |
| **clicks silently do nothing on high-security sites** | not a trust flag: CDP clicks arrive with `isTrusted: true`. The site is reading behaviour and fingerprints — a pointer that teleports with no hover trail, machine-regular typing, its own challenge script — so the click is accepted and ignored, with no error | send **real Windows input** — AutoIt `MouseMove`/`MouseClick`/`Send`, or its `AutoItX3.Control` COM object — at coordinates you obtained from CDP (reading the page still works; only input is refused) |
| every tab hangs | no renderer (GPU sandbox, or a stale profile lock) | check `chrome://gpu`; one profile, one running browser |

Before reaching for real clicks, check whether the site offers a route that needs no pointer at all —
its own API called from inside the page, keyboard navigation, an import/export. Real input is the
fallback, not the first move.

Know it worked when `/json/version` returns a browser and WebSocket URL, and a page you control reports
the action (`bin/selftest.html` writes its state into its own title).

## Recipe 4: Windows host, no human logged in

There is no session-0 desktop worth attaching to, so choose deliberately:

| Option | Gives you | Cost |
|---|---|---|
| WSL2 with systemd, then Recipe 1 inside it | the full browser door, reachable from anywhere | one extra layer; the ports live in the WSL VM |
| Chrome headless with `--remote-debugging-port` | driving only, no visible window, no human login | useless when a human must log in or watch |

WSL2 is the better answer for anything a human may later need to see; headless is for scraping.

## Recipe 5: macOS host

macOS has no X display, so the Linux recipes do not apply. Two shapes:

**a) A Linux VM (Lima, UTM, or a cloud box) running Recipe 1.** Closest to the documented setup and the
browser door then works from any device. Choose this when the human must watch the screen.

**b) A local Chrome with `--remote-debugging-port`, started in the user's own session.** Driving only —
there is no built-in screen-sharing equivalent to noVNC.

```bash
PROFILE="$HOME/Library/Application Support/hermes-desktop/browser-9333"
mkdir -p "$PROFILE"
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  --user-data-dir="$PROFILE" --remote-debugging-port=9333 \
  --no-first-run --window-position=0,0 --window-size=1440,900 &
```

Keep it alive with a `~/Library/LaunchAgents` plist (`RunAtLoad` true, `KeepAlive` true) rather than
parenting it to the agent, so an agent restart does not take the logged-in browser with it.

Real input on macOS, when a site ignores CDP: `brew install cliclick`, then
`cliclick c:640,420` and `cliclick t:"text"`. Two gates — the calling app needs **Accessibility**
permission in System Settings → Privacy & Security, and coordinates are in *points* while a Retina
display's pixels are double, so convert before trusting a sequence.

Do not attempt TigerVNC or Xpra on macOS for this purpose — support is not there in a form worth
relying on.

---

## What the installer does

| Unit | What it is |
|---|---|
| `hermes-vnc-<N>.service` | virtual X display `:<N>` running XFCE, loopback-only |
| `hermes-novnc-<N>.service` | websockify serving noVNC, so a browser tab is the desktop |
| `hermes-chrome-<N>.service` | the browser on `:<N>`, own **persistent** profile, CDP port, memory/task caps |

Flags: `--display`, `--web-port`, `--geometry`, `--user`, `--allow-cidr`, `--no-ufw`, `--no-chrome`,
`--cdp-port`, `--browser auto|chrome|chromium`, `--profile-dir`, `--generate-password`,
`--vnc-password-stdin`, `--password-file`, `--suggest`, `--dry-run`, `--verify N`, `--uninstall N`.

The installer also adds `/usr/share/novnc/index.html` as a redirect so a bare `host:port` URL works,
and opens the web port in ufw for `--allow-cidr` only.

## A password on the door

Default: the web port is the only way in and it has no login. Anyone who reaches it gets a full desktop
as that user. Fine on a LAN you control, not fine anywhere else.

```bash
./install.sh --generate-password                    # prints an 8-character password once
printf '%s\n' 'my-pass' | ./install.sh --vnc-password-stdin
./install.sh --password-file ~/existing.vncpasswd
```

Measured: RFB then offers security type 2 (`VncAuth`) instead of 1 (`None`), noVNC prompts before it
shows anything, and a wrong password is refused by the server. `--verify` proves both — it completes the
handshake with a deliberately wrong response and reports `PASS  a wrong password is refused`.

What it does **not** buy: VNC's password exchange is DES-based, uses only the first 8 characters, and
travels unencrypted. It keeps honest neighbours out; it is not protection against someone on your
network who is actually trying. For that, keep the ufw allow-list, tunnel over SSH, or use a VPN.

## Verify against a page you control, not a public website

Any external page can be redesigned out from under a test — `example.com` no longer has an `<h1>`, so
an acceptance check based on it fails for reasons unrelated to the desktop. Use the page in this repo;
it reports what happened in its own title and in `window.__selftest`:

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

For a pure "can the agent evaluate anything at all" check, `Runtime.evaluate` of `1+1` needs no page and
no network.

## The profile is the point — Chrome, not Chromium

A desktop whose browser forgets you is one you log into every morning. The installer gives the browser a
**persistent profile** at `~/.config/hermes-desktop/<browser>-<display>/`, and prefers **Chrome** because
only the Google build can sign in to Chrome Sync — which is what carries bookmarks, passwords and
extensions from the human's other machines.

| | Chrome | Chromium |
|---|---|---|
| everything a browser does | yes | yes |
| profile persists on disk | yes | yes |
| Chrome Sync (bookmarks, passwords, extensions) | **yes** | **no** (no Google API keys) |
| Linux arm64 | not published by Google | yes |

`--verify N` prints the profile path and size and fails if it is missing. `--uninstall N` never deletes
it, because it holds logins. Details, backup, and the password-store trade-off:
[docs/profile-persistence.md](docs/profile-persistence.md).

## Several instances on one machine

Ports belong to the machine, not to a Hermes profile. Two instances on one host want the same `6080` and
`9333`, and the second one loses — silently, in the worst way: Chrome cannot open the CDP port, starts
anyway, and the agent connects to **whatever is answering**, which may be the other instance's browser
or the human's own Chrome, with the wrong logins on the wrong sites.

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

## Verify output

```
$ ./install.sh --verify 9
Verifying display :9 (VNC 5909, web 6089)
  PASS  hermes-vnc-9 active
  PASS  hermes-novnc-9 active
  PASS  X socket X9 exists
  PASS  VNC listening on 127.0.0.1:5909 (loopback only)
  PASS  noVNC listening on 0.0.0.0:6089
  PASS  RFB handshake: b'RFB 003.008\n' types=[1] (passwordless by design)
  PASS  /vnc.html returns 200
  PASS  websockify -> VNC proven (first frame: b'RFB 003.008\n')
  PASS  X session answers on :9 (active window: New Tab - Google Chrome)
  PASS  CDP 9339 belongs to this install (pid 476377)
  PASS  Chrome on :9 executes JS (CDP 9339, readyState=complete)
  PASS  profile persists at /home/op3/.config/hermes-desktop/chrome-9 (8.2M)

RESULT: display :9 is live.  Browser door: http://192.168.0.102:6089/vnc.html
```

With a password installed, the two RFB lines become
`PASS  RFB asks for a password (... types=[2] wrong-password=refused)` and
`PASS  a wrong password is refused`. The WebSocket check proves the web port really reaches the VNC
server rather than just serving a page. The `executes JS` check exists because a Chrome with a dead
zygote still listens on its CDP port while every tab hangs — services "running" is not a working
desktop.

## Requirements

- Ubuntu 22.04/24.04, tested on 24.04 with TigerVNC 1.13 and Chrome 156/157. Any Debian-family distro
  with the same packages should work.
- `sudo` for the installing user (packages, systemd units, firewall).
- ~450 MB RAM per desktop, ~250 MB for Chrome.
- A LAN. Do not expose the web port to the internet.

## Security model

| Port | Bound to | Auth | Reachable by |
|---|---|---|---|
| 590N VNC | `127.0.0.1` | none, or VncAuth if installed with a password | only websockify on the host |
| 6080+ noVNC | `0.0.0.0` | none, or the VNC password prompt | the `--allow-cidr` subnet only, by firewall |
| 9333 CDP | `127.0.0.1` | none | the agent on that host |

The web port is a **full desktop as that user**, with their SSH keys and browser sessions. Keep it
LAN-only. Beyond a LAN, put Apache Guacamole (or a proxy with real authentication) in front of it.

## After install

```bash
./install.sh --verify 1        # health check, changes nothing
./install.sh --uninstall 1     # stop and remove the units; the profile stays
```

Logs: `journalctl -u hermes-vnc-1 -u hermes-novnc-1 -u hermes-chrome-1`.
Then open the browser door once and log in to the sites you need by hand — sessions persist in the
profile.

## Troubleshooting

[docs/troubleshooting.md](docs/troubleshooting.md). The four that bite most: the zygote dying without a
session bus, the passwordless-server refusal, per-display `xstartup`, and Chrome 136+ refusing
`--remote-debugging-port` without an explicit `--user-data-dir`.

## Alternatives

| Option | What it is | Use when |
|---|---|---|
| [LinuxServer.io webtop](https://docs.linuxserver.io/images/docker-webtop/) | container with a full desktop streamed to the browser on 3001 | you want a container, not host packages |
| [Apache Guacamole](https://guacamole.apache.org/) | browser-to-VNC/RDP/SSH gateway with logins, 2FA, audit | many users, or exposure beyond a LAN |
| [Kasm Workspaces](https://kasmweb.com/) | managed container desktops per user | a team each needing a disposable desktop |

This repo is the lightest (no Docker) and the only one that also wires the agent's browser control port
as part of the install.

## Layout

```
install.sh                   the Linux installer (idempotent; --suggest, --verify, --uninstall)
bin/desktop_input.py         X11-level click/type/key, geometry read over CDP
bin/selftest.html            tiny local page with a counter, an input and a log — the drive test
docs/input-ladder.md         the four input paths, with code and the decision rule
docs/profile-persistence.md  Chrome vs Chromium, signing in, backup, password store
docs/ports.md                port blocks per instance, and the wrong-browser trap
docs/native-window.md        optional Xpra lane for a native-looking window
docs/troubleshooting.md      symptom -> cause -> fix, from measured failures
windows/install.ps1          PowerShell installer for an agent on Windows itself
windows/clicking.md          the Windows trap: session 0, CDP-refused input, AutoIt clicks
systemd/                     example unit for the optional Xpra lane
AGENTS.md                    the same recipes, condensed, for an agent in a hurry
```

## License

MIT — see [LICENSE](LICENSE).
