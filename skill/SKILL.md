---
name: virtual-desktop
description: Set up, use, manage, troubleshoot, and change the viewing channel for this Hermes desktop.
---

# Virtual desktop + agent-drivable Chrome

This skill covers the desktop provisioned by `hermes-virtual-desktop`. The setup installs this directory
at `~/.hermes/skills/virtual-desktop`, with the referenced guides under `references/` and the Linux
`desktop_input.py` helper under `bin/`. `SOURCE_REPO` records the checkout used for installation.

## Keep advice current

Before changing the setup, first read the local `references/AGENTS.md` and the relevant guides in
`references/docs/`. Then check `SOURCE_REPO` for the original checkout. Verify that its `origin` is
`https://github.com/raymondclowe/hermes-virtual-desktop.git` and review the current `AGENTS.md`,
`README.md`, `skill/SKILL.md`, and relevant `docs/` files there for newer guidance. If the checkout
is missing or stale and network access is allowed, fetch upstream refs and review the commits and file
changes without changing the working tree; otherwise consult the canonical repository before
proceeding. Do not pull, reset, or replace a checkout with unreviewed content.
The installed references are a fallback snapshot, not a substitute for checking the source repo.

## Set up and identify the desktop

For Linux, follow the full preflight and safety steps in `references/AGENTS.md`. Preview with
`./install.sh --dry-run`, ensure the intended ports and display are unused, and install with
`./install.sh --display N --web-port P --cdp-port C`. The installer also installs this Hermes skill.
Never replace a working display owned by another session; choose a separate display and ports.

For Windows when Hermes and the human use the same machine, use
`windows/install.ps1 -CdpPort P` from the source checkout. It installs a dedicated Chrome profile,
starts a visible browser in the interactive session, and installs this skill. It does not create a
VNC or Xpra desktop. See `references/windows/README.md`.

On Linux, display `:N` uses VNC port `5900+N`, noVNC port `6079+N`, and the default CDP port
`9332+N`. The browser profile is `~/.config/hermes-desktop/<browser>-N`. Use the install output or
service files for custom ports and profile paths. The human's noVNC door is
`http://<host>:<web-port>/vnc.html`; the agent's CDP endpoint is `http://127.0.0.1:<cdp-port>`.

Do not claim success from files or active services alone. On Linux, run `./install.sh --verify N` and
require no FAIL lines, including the Chrome JavaScript execution and profile persistence checks.
On Windows, verify `http://127.0.0.1:<cdp-port>/json/version` returns the expected browser.

## Manage and drive it

Use the configured display's `./install.sh --verify N` to inspect health. Use
`systemctl status hermes-vnc-N hermes-novnc-N hermes-chrome-N` and `journalctl -u <unit>` for Linux
diagnostics. Restart or uninstall only the specific display this session created and only when asked;
`./install.sh --uninstall N` leaves the browser profile and this shared skill intact. On Windows,
rerunning `windows/install.ps1` reuses its dedicated profile; `-Uninstall` removes its scheduled task
but deliberately keeps the profile.

Prefer the page's DOM/CDP interface for normal interaction. Use `bin/desktop_input.py` on Linux when
the page ignores CDP input or a human needs to see a click:

```bash
python3 ~/.hermes/skills/virtual-desktop/bin/desktop_input.py --display :N --cdp http://127.0.0.1:C open URL
python3 ~/.hermes/skills/virtual-desktop/bin/desktop_input.py --display :N --cdp http://127.0.0.1:C click --selector '#button'
```

The installed helper lives at `~/.hermes/skills/virtual-desktop/bin/desktop_input.py`; its source
checkout copy is preferred when available. Do not mix DOM/CDP and X11 input for the same action.

Never enter credentials for the human. For passwords, 2FA, CAPTCHAs, or login prompts, hand over the
browser door and let the human take over. Never delete, move, or use a temporary/incognito browser
profile: it preserves the human's session and bookmarks.

## Change the human's viewing channel

The default human channel is noVNC in a browser tab. Keep it as the safe fallback. If the human
specifically wants a native-looking window from a remote Linux host, the optional channel is Xpra
shadow mode: it shows the *same* Linux display and Chrome profile. Follow `references/docs/native-window.md`
and `references/systemd/xpra-shadow.service.example`; bind Xpra to loopback and access it over SSH.
Do not install Xpra unless requested, expose its port publicly, or stop the noVNC services to switch.
To return to noVNC, use the existing browser door and detach/stop only the Xpra client or service
created for that display. The agent continues using the same CDP endpoint either way.

Xpra is not a Windows-host alternative. If Hermes and the human are at the same Windows machine,
Chrome itself is the visible channel. For Windows clients viewing remote Linux, use the documented
Xpra-over-SSH option only when requested.

## Troubleshoot

Start with `references/docs/troubleshooting.md`, then `references/docs/ports.md`,
`references/docs/profile-persistence.md`, or `references/docs/input-ladder.md` as relevant. On Linux,
`./install.sh --verify N` tests service state, ports, VNC/noVNC, X session, CDP rendering, and profile
persistence. Read the specific unit's journal before changing it. Never stop or remove a display
another person or agent may be using.

Treat the noVNC and Xpra channels as full desktop access, not read-only viewing. Keep access restricted
to the intended LAN or loopback/SSH; never use `0.0.0.0/0` or port-forward a passwordless desktop.
Never solve an input issue by adding another browser automation stack.
