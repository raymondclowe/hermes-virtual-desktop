# Chrome (not Chromium) with a persistent profile

The profile is the enabler. With it, the desktop's browser is *the same browser* every time: logged
in to the same sites, same bookmarks, same password manager, same extensions. Without it every
session starts as a stranger, and half the work is logging in again.

## Why Chrome rather than Chromium

| | Chrome (Google build) | Chromium |
|---|---|---|
| rendering, extensions, DevTools | identical | identical |
| profile persists on disk | yes | yes |
| **Chrome Sync** (bookmarks, passwords, history, tabs, extensions) | **yes** | **no** — Chromium ships without Google's API keys, so sign-in is unavailable |
| Linux arm64 | not published by Google | available (snap/deb) |

So: Chrome is the default wherever Google publishes it (x86_64). The installer installs Chrome even
if Chromium is already present, and uses Chromium only where Chrome is unavailable (arm64) or when the
human explicitly requests it. Either way the profile persists — that is the part that matters.

`install.sh` defaults to Chrome:

```bash
./install.sh                       # install/use Chrome (falls back to Chromium on arm64)
./install.sh --browser auto        # same Chrome-first behavior
./install.sh --browser chromium    # Chromium only
./install.sh --profile-dir /srv/profiles/alice-1   # put the profile somewhere else
```

If Chrome is not present, the installer downloads Google's `.deb` and installs it (x86_64). On arm64,
where Google does not publish Chrome, it installs Chromium instead.

## Where the profile lives

```
~/.config/hermes-desktop/<browser>-<display>/
```

For example `~/.config/hermes-desktop/chrome-1`. It is:

- **outside the systemd unit's lifetime** — restarting or rebuilding the service does not touch it;
- **outside the package manager** — upgrading Chrome keeps it;
- **never deleted by `--uninstall`** — the uninstall prints the path and leaves it alone, because it
  holds logins;
- **one per display**, so two desktops never fight over Chrome's single-instance lock.

`--verify N` prints the path and its size, and fails if the directory is missing. A profile that is
not on disk is not a profile.

## Turn on Sync once

1. Open the browser door.
2. Chrome → sign in with the Google account → turn on Sync (bookmarks, passwords, extensions).
3. Done. The session cookie lives in the profile; the agent's Chrome is signed in from then on.

Extensions and logged-in sites work the same way: install or log in once, persist forever.

## Back it up

Chrome must be **stopped** while you copy the profile — a live copy is corruptible.

```bash
sudo systemctl stop hermes-chrome-1
tar -C ~/.config/hermes-desktop -czf chrome-1-$(date +%F).tgz chrome-1
sudo systemctl start hermes-chrome-1
```

Restore is the reverse: stop the unit, unpack over the directory, start it.

## The password-store trade-off

The units pass `--password-store=basic`. That is deliberate: a headless desktop has no unlocked
keyring, so the alternative is a prompt the agent cannot answer, or a browser that silently drops
every saved password. The consequence is that saved passwords sit in the profile with only weak
obfuscation.

Treat the profile directory as being as sensitive as an unlocked browser:

```bash
chmod 700 ~/.config/hermes-desktop ~/.config/hermes-desktop/chrome-1
```

and keep the noVNC door LAN-only. If the host is shared, use a password manager extension that
requires its own unlock rather than Chrome's built-in store.

## Multi-account, multi-profile

Two Chrome profiles on one desktop (work and personal, for instance) is fine — give each its own
`--user-data-dir` and its own service, or use Chrome's own profile switcher inside the one window.
Never point two *running* Chromes at the same directory: Chrome locks it and the second exits.
