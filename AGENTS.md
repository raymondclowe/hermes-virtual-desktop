# AGENTS.md — how an agent sets this up

You are an agent. A human pointed you at this repository and said "do this". Follow the steps in
order. Do not improvise a different stack.

## Goal

That host ends up with a virtual desktop a human can open in a browser, and a Chrome the agent can
drive over CDP, both as systemd services that survive reboot. Success is the verify output below,
not the presence of files.

## Steps

1. Confirm the host is Ubuntu/Debian and you have `sudo`:
   ```bash
   . /etc/os-release && echo "$ID $VERSION_ID"; sudo -n true && echo sudo-ok
   ```
   If `sudo -n` fails, stop and ask the human for sudo — do not try to work around it.

2. Clone and preview. Read the dry-run output before writing anything:
   ```bash
   git clone https://github.com/raymondclowe/hermes-virtual-desktop.git ~/hermes-virtual-desktop
   cd ~/hermes-virtual-desktop
   ./install.sh --dry-run --display 1
   ```

3. Check the ports you intend to use are free, and pick others if not:
   ```bash
   ss -ltn | grep -E ':(5901|6080|9333)\b' || echo free
   ```
   If display `:1` / 6080 / 9333 is already a working desktop, **do not replace it**. Install a
   second one: `--display 2 --web-port 6081 --cdp-port 9334`.

4. Install:
   ```bash
   ./install.sh --display <N> --web-port <P> --cdp-port <C> [--allow-cidr <your-lan-cidr>] [--no-ufw]
   ```

5. Verify. All ten checks must pass:
   ```bash
   ./install.sh --verify <N>
   ```
   Required: services active, X socket, VNC loopback-only, noVNC listening, RFB handshake,
   `/vnc.html` 200, websockify proven, X session answering, and **Chrome executes JS**.

6. Prove the agent path end to end, not just the ports:
   ```bash
   python3 bin/desktop_input.py --display :<N> --cdp http://127.0.0.1:<C> open 'https://example.com'
   python3 bin/desktop_input.py --display :<N> --url-contains example.com where --selector 'h1' --dry-run
   ```
   The second command must print a screen coordinate and a label. If it says
   `no matching page target`, the tab did not load — go to troubleshooting before claiming success.

7. Report to the human, with the browser door URL and the CDP URL:
   ```
   Desktop:  http://<host-ip>:<P>/vnc.html
   Agent:    http://127.0.0.1:<C>  (CDP)
   Verify:   ./install.sh --verify <N>  (10/10)
   ```

## Rules

- **Never** restart, stop or uninstall a display you did not just create. Another agent or human may
  be using it.
- **Never** bind the noVNC port to the internet, port-forward it, or set `--allow-cidr 0.0.0.0/0`
  without an explicit instruction. It is a passwordless desktop.
- **Never** type credentials. If a site needs a login, hand the human the browser door URL and ask
  them to log in once on that desktop.
- One Chrome per install. Do not point two agents at the same CDP port; each install has its own
  profile and port for that reason.
- Prefer the DOM/CDP path (`locator.click`) for ordinary work. Use `bin/desktop_input.py` only when
  the page ignores CDP input or a human needs to see the click. Do not mix both for the same action.
- If a step fails, read `docs/troubleshooting.md` and fix the cause. Do not add a second automation
  stack (bb-browser, Puppeteer, Selenium) to work around it.

## What "done" means

`./install.sh --verify <N>` prints `RESULT: display :<N> is live` with ten PASS lines, and the
`where` command in step 6 returns coordinates. Nothing less.
