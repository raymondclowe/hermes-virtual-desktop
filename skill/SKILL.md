---
name: virtual-desktop
description: Use when a host needs a browser-visible desktop or a CDP-drivable Chrome.
---

# Virtual desktop + agent-drivable Chrome

A host can carry its own desktop, visible in any browser, with a Chrome the agent drives over CDP.
Install it with one command from the public repo:

```bash
git clone https://github.com/raymondclowe/hermes-virtual-desktop.git ~/hermes-virtual-desktop
cd ~/hermes-virtual-desktop && ./install.sh --display 2 --web-port 6081 --cdp-port 9334
./install.sh --verify 2
```

Do not replace an existing working display (`:1`, 6080, 9333) — install a second one on its own
display/ports, each with its own Chrome profile.

## What you get

- `http://<host>:<web-port>/vnc.html` — the desktop, for the human.
- `http://127.0.0.1:<cdp-port>` — Chrome DevTools, for the agent.
- systemd units `hermes-vnc-N`, `hermes-novnc-N`, `hermes-chrome-N`, enabled at boot.

## Drive it — pick by symptom

1. **Page API** (`Runtime.evaluate` + `fetch`) for reads and anything the site's own JS calls.
2. **DOM over CDP** (`locator.click`, `fill`) — the default for ~95% of work.
3. **X11 input** (`bin/desktop_input.py click --selector …`) when a page ignores CDP input, is a
   canvas/WebGL widget, or the click must look human. CDP finds and scrolls; xdotool clicks.
4. **Human via noVNC** for passwords, 2FA, CAPTCHA.

Never fix an input problem by installing a second automation stack (bb-browser, Puppeteer, Selenium).
Fingerprint-level blocks are a browser-profile problem: log in once by hand on this desktop and reuse
the profile.

## The profile is the point

The browser keeps a **persistent profile** at `~/.config/hermes-desktop/<browser>-<display>/`.
Chrome is preferred because only the Google build can sign in to Chrome Sync (bookmarks, passwords,
extensions). Chromium works for everything else but cannot sync. Never delete the profile, never use
`--incognito` or a temp profile, and sign in once through the browser door — the agent's browser is
then already logged in.

## Verify before claiming it works

`./install.sh --verify N` must end `RESULT: display :N is live` with eleven PASS lines, including
`Chrome on :N executes JS` and `profile persists at ...`. Services "active" is not proof: a Chrome with a dead zygote still listens
on its CDP port while every tab hangs. That failure's fix is the `XDG_RUNTIME_DIR` and
`DBUS_SESSION_BUS_ADDRESS` entries in the Chrome unit — see `docs/troubleshooting.md`.

## Rules

- The noVNC port is a passwordless desktop as that user. LAN-only, ufw-restricted; never
  port-forward it; never `--allow-cidr 0.0.0.0/0`.
- Never type credentials into it; send the human the URL for that step.
- One Chrome per install; never share a CDP port between agents.
- Never stop or uninstall a display another session may be using.
- Windows client + remote Linux host + wants a native window: `docs/native-window.md` (Xpra). Optional
  lane — do not install it unless asked.
