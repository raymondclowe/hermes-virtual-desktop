# Troubleshooting — measured failures, in the order they bite

Each entry: symptom → cause → fix. All of these were hit and fixed on Ubuntu 24.04 with Chrome 156
and TigerVNC 1.13.

## Chrome is "running" but every tab hangs; tabs titled "Untitled"

**Symptom.** `systemctl status hermes-chrome-N` says active, the CDP port answers `/json/version`,
but `/json/list` shows pages with empty URLs, and `Runtime.evaluate` times out. `journalctl -u
hermes-chrome-N` shows `Did not receive ping from zygote child` and `Failed to send
GetTerminationStatus message to zygote`. The desktop screenshot shows Chrome with blank tabs and the
tab spinner stuck.

**Cause.** Chrome was started by systemd without a session bus and runtime directory. The zygote
child dies, and the surviving browser process accepts CDP connections but can never render.

**Fix.** The unit needs:

```ini
Environment=XDG_RUNTIME_DIR=/run/user/<uid>
Environment=DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/<uid>/bus
```

`install.sh` sets both. If you wrote your own unit, add them, then `systemctl daemon-reload &&
systemctl restart hermes-chrome-N`. Confirm with `--verify N`: the last check must say
`Chrome on :N executes JS`.

**Why it is easy to miss.** Every superficial check passes. Only evaluating JS inside a page proves
the renderer works — that is why `--verify` does exactly that.

## VNC refuses the connection with "No password configured"

**Cause.** TigerVNC started without disabling its password check.

**Fix.** Start it with `-localhost yes -SecurityTypes None`. Being loopback-only is what makes
passwordless acceptable; the noVNC port is the authenticated-by-network door.

## A second desktop shows the first desktop's applications, or xstartup changes affect both

**Cause.** `~/.vnc/xstartup` is shared and `vncserver` runs it with whatever `DISPLAY` it inherits,
so a hard-coded `:1` starts a second session onto the first display.

**Fix.** One `xstartup<N>` per display, with `DISPLAY=:<N>` exported at the top and
`exec xfce4-session` in the foreground. `install.sh` writes `~/.vnc/xstartup<N>` and starts the
server with `-xstartup`.

## Chrome exits immediately: "DevTools remote debugging requires a non-default data dir"

**Cause.** Chrome 136+ refuses `--remote-debugging-port` with the default profile.

**Fix.** Always pass an explicit `--user-data-dir`, one per install (`~/.config/chrome-desktop-<N>`).

## `host:port` shows the noVNC directory listing instead of the client

**Cause.** `/usr/share/novnc` has no `index.html`, only `vnc.html`.

**Fix.** `install.sh` writes a one-line `index.html` redirect. Without it, use `/vnc.html` in the URL.

## ufw blocks the web port

**Cause.** On a host with ufw active, new listening ports are invisible to the LAN even though they
work from `localhost`.

**Fix.** `sudo ufw allow from <cidr> to any port <P> proto tcp`, and **prove it from another host** —
testing with `curl` on the same machine passes through the loopback interface and tells you nothing.

## The install says the web port is in use

**Cause.** Either a previous install of the same display (fine — the script reinstalls over its own
unit) or an unrelated service.

**Fix.** `ss -ltnp | grep :<P>` and read the process. Pick another port with `--web-port`.

## Killing a stuck Chrome kills my shell instead

**Cause.** `pkill -f chrome` matches the agent's own command line, which contains the word chrome.

**Fix.** Find the PID, then kill the PID:

```bash
pgrep -af 'user-data-dir=/home/USER/.config/chrome-desktop-1'
kill <pid>
```

## X11 clicks land on the wrong spot

**Cause.** Window moved, page scrolled, or browser zoom/scaling differs from the assumed 1.0.

**Fix.** Always re-read geometry immediately before acting — never cache a coordinate between
actions. `bin/desktop_input.py` does this on every call. If clicks are consistently offset
vertically, the window manager is drawing a frame that Chrome does not count in `outerHeight`; run
the helper's `where --dry-run` and compare its `window` block against
`xdotool search --name Chrome getwindowgeometry`.

## CDP connects but every command times out, and only on a background tab

**Cause.** Chrome freezes background tabs; a frozen page never answers `Runtime.evaluate`.

**Fix.** Activate the tab first (`PUT /json/activate/<target-id>`, or `Target.activateTarget`).
`bin/desktop_input.py` does this before every command.

## Display number already in use

**Cause.** A previous Xvfb/TigerVNC session left `/tmp/.X11-unix/X<N>` behind.

**Fix.** Check `ls /tmp/.X11-unix/` and `pgrep -af Xtigervnc`. Use another display number, or stop the
old unit properly with `./install.sh --uninstall N`.
