# A native-looking window instead of a browser tab

For the narrow case: **the human is on Windows (or Linux/macOS), Hermes runs on a remote Linux host,
and they want Chrome to look like an application window, not a tab in their browser.**

The tool is [Xpra](https://xpra.org/) — "screen for X". It forwards individual applications from a
Linux host and lets the *client's* window manager draw them: real title bar, resize, minimise,
clipboard, audio, and the app keeps running when you disconnect. Native clients exist for Windows,
Linux and macOS, plus an HTML5 client.

This is **optional**. The browser door (noVNC) needs nothing installed on the client and remains the
default. Do not add this lane unless the human asks for it.

## Two ways to show the same desktop

| Mode | What the human sees | Chrome profile | Moving parts |
|---|---|---|---|
| **Shadow** (recommended) | One window containing the whole 1440×900 desktop, Chrome inside it | The same single Chrome, same saved logins | Fewest — one extra process |
| **Seamless** | Only Chrome's window, no desktop around it | A **second** Chrome with its own profile (a seamless session is its own X server, and Chrome locks a profile to one process) | More — separate session and profile |

Shadow is what to use for "make it feel native without losing my logins". Seamless is for "I want
literally one window and I accept a second profile".

## Host side (the Linux machine running Hermes)

```bash
sudo apt-get install -y xpra          # Ubuntu 24.04 ships 3.1.5; xpra.org has current builds
```

Start a shadow server for the existing desktop on `:1`, bound to **loopback only**:

```bash
/usr/bin/python3 /usr/bin/xpra shadow :1 \
    --bind-tcp=127.0.0.1:14500 --html=on --daemon=no \
    --systemd-run=no --notifications=no --tray=no
```

Measured on Ubuntu 24.04 with xpra 3.1.5: the server came up on `127.0.0.1:14500`, served the HTML5
client (`HTTP 200`, 35,783 bytes), and reported the shadowed desktop as `content-type=desktop`,
`depth=24`. Tray and notification support fail harmlessly on a desktop with no tray — they are
switched off above.

**Pin the interpreter.** The `xpra` launcher runs `python3` from `PATH`. On a host where a user venv
(3.14, for example) comes first, it dies with `xpra for python 3.14 is not installed` and then tries
`python2`. Call `/usr/bin/python3 /usr/bin/xpra` explicitly, as above.

To make it permanent, wrap exactly that command in a unit — see
[`systemd/xpra-shadow.service.example`](../systemd/xpra-shadow.service.example). Change `User`,
the display number and the port.

## Client side (the human's machine)

1. Install the Xpra client for Windows (EXE or MSI) — [xpra.org](https://xpra.org/) / the
   [project releases](https://github.com/Xpra-org/xpra). Linux and macOS builds exist too.
2. Attach over SSH, which gives encryption and login for free:

   ```bat
   Xpra_cmd.exe attach ssh://USER@HOST/14500
   ```

   With `--bind-tcp=127.0.0.1:...` on the host, that SSH connection is also the only way in — no
   extra firewall hole.

3. The desktop appears as one window. Move, resize and minimise it like any local window; clipboard
   and audio follow.

If the human wants fewer pixels, run the shadow with `--desktop-scaling` or resize the client window;
the virtual desktop itself stays 1440×900 unless you install with a different `--geometry`.

## Seamless instead (true single window)

```bash
/usr/bin/python3 /usr/bin/xpra seamless :100 \
    --start-child="google-chrome --user-data-dir=$HOME/.config/hermes-desktop/chrome-seamless --no-first-run" \
    --bind-tcp=127.0.0.1:14501 --daemon=no --systemd-run=no --tray=no
```

- The window is just Chrome — no desktop, no panel.
- That Chrome has its own profile, so it does **not** share logins with the desktop Chrome. Sign in
  once and it persists, like any other profile.
- Only one of the two Chromes can run at a time on the same profile; with separate profile
  directories that restriction disappears.
- Add Chrome's own `--app=https://example.com` to hide the tab strip and address bar entirely.

## Security

- Shadow mode gives the client **input** to the whole desktop, not a read-only view.
- Keep `--bind-tcp` on `127.0.0.1` and reach it over SSH. If you must expose it, use TCP with TLS and
  a password (`--tcp-auth=...`), never plain `0.0.0.0`.
- The session inherits the desktop's logins. Treat client access as equivalent to the noVNC door.

## What not to use

| Option | Why not |
|---|---|
| **RDP RemoteApp** | Single-application RDP is a Windows Server feature needing RDS per-user licences. On Linux, `xrdp` publishes a whole desktop, not individual apps. |
| **ssh -X / -Y** | Works Linux→Linux on a LAN, but needs an X server on Windows, dies with the connection, and is slow (every drawing call waits for a reply). Xpra exists to fix exactly that. |
| **A second automation stack** (bb-browser, Puppeteer, Selenium) | Changes nothing about how pixels reach the human. This is a display problem, not an input problem. |

## When to skip it

- The human is on Linux and already happy with a browser tab — no benefit worth an install.
- The link is over the open internet without a VPN: every option here is latency-bound. Use Tailscale
  (or similar) first; a native window over a bad link feels worse than a VNC tab because the window
  manager fights the lag.
- Hermes runs on the human's own machine: just open the desktop's Chrome locally — it is already
  native.
