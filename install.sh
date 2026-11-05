#!/usr/bin/env bash
# install.sh — give a Hermes host its own browser-visible desktop and an
# agent-drivable Chrome, as systemd services that survive reboot.
#
# The stack, in plain words:
#   virtual X display (TigerVNC)             ->  real XFCE desktop, no monitor
#   websockify + noVNC                       ->  that desktop in a browser tab
#   Chrome inside that display + CDP port    ->  the agent drives it exactly,
#                                                a human clicks it visually
#
# Usage (run as the user who owns the Hermes install; sudo is used internally):
#   ./install.sh                       # display :1, web 6080, chrome on 9333
#   ./install.sh --display 2 --web-port 6081
#   ./install.sh --verify 1            # check only, change nothing
#   ./install.sh --dry-run --display 1 # print what would be written
#   ./install.sh --uninstall 2         # stop and remove that display's units
#
# Flags:
#   --display N        X display number            (default 1)
#   --web-port P       noVNC browser port          (default 6080)
#   --geometry WxH     desktop size                (default 1440x900)
#   --user NAME        owner of the desktop        (default: $USER)
#   --allow-cidr CIDR  ufw source for --web-port   (default 192.168.0.0/24)
#   --no-ufw           do not touch the firewall
#   --no-chrome        desktop only, no Chrome unit
#   --cdp-port P       Chrome DevTools port        (default 9333)
#   --browser NAME     chrome | chromium | auto    (default auto: Chrome first)
#   --profile-dir DIR  browser profile directory   (default: persistent, per display)
#   --generate-password  create a random VNC password, print it once, protect the desktop
#   --vnc-password-stdin read the VNC password from stdin (keeps it out of ps/logs)
#   --password-file F  use an existing TigerVNC passwd file (made by vncpasswd -f)
#   --dry-run          show the files, write nothing
#   --verify N         run the checks for display N and exit
#   --uninstall N      stop+disable+remove display N's units
#
# Security model, two settings:
#   default        the raw VNC port is loopback-only and passwordless; the only
#                  door is the noVNC web port, ufw-restricted to --allow-cidr.
#                  Anyone who reaches that port gets a full desktop as that user.
#   with a password  VNC asks for a password before it draws anything; noVNC
#                  prompts for it, and a wrong one is refused by the server. Use
#                  this when other machines - or other agents - share the LAN.
#                  RFB password auth is DES-based and travels unencrypted, so it
#                  keeps honest people out, not a determined attacker: keep the
#                  ufw allow-list, and for real secrecy tunnel over SSH.
set -euo pipefail

DISPLAY_NUM=1
WEB_PORT=6080
GEOMETRY="1440x900"
TARGET_USER="${USER:-$(id -un)}"
ALLOW_CIDR="192.168.0.0/24"
USE_UFW=1
WITH_CHROME=1
CDP_PORT=9333
BROWSER="auto"
PROFILE_DIR=
DRY_RUN=0
MODE="install"
VERIFY_ONLY=""
WANT_PASSWORD=0
GEN_PASSWORD=0
PASSWORD_FILE_IN=""
VNC_PASS_FILE=""
VNC_SEC_ARGS="-SecurityTypes None"

die() { echo "ERROR: $*" >&2; exit 1; }
say() { echo "  $*"; }
hdr() { echo; echo "== $* =="; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --display)     DISPLAY_NUM="$2"; shift 2 ;;
    --web-port)    WEB_PORT="$2"; shift 2 ;;
    --geometry)    GEOMETRY="$2"; shift 2 ;;
    --user)        TARGET_USER="$2"; shift 2 ;;
    --allow-cidr)  ALLOW_CIDR="$2"; shift 2 ;;
    --no-ufw)      USE_UFW=0; shift ;;
    --no-chrome)   WITH_CHROME=0; shift ;;
    --cdp-port)    CDP_PORT="$2"; shift 2 ;;
    --browser)     BROWSER="$2"; shift 2 ;;
    --profile-dir) PROFILE_DIR="$2"; shift 2 ;;
    --dry-run)     DRY_RUN=1; shift ;;
    --generate-password)   WANT_PASSWORD=1; GEN_PASSWORD=1; shift ;;
    --vnc-password-stdin)  WANT_PASSWORD=1; shift ;;
    --password-file)       VNC_PASS_FILE="$2"; PASSWORD_FILE_IN="$2"; WANT_PASSWORD=1; shift 2 ;;
    --suggest)     MODE="suggest"; shift ;;
    --verify)      MODE="verify"; VERIFY_ONLY="$2"; shift 2 ;;
    --uninstall)   MODE="uninstall"; VERIFY_ONLY="$2"; shift 2 ;;
    -h|--help)     sed -n '2,40p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ "$DISPLAY_NUM" =~ ^[0-9]+$ ]] || die "--display must be a number"
[[ "$WEB_PORT" =~ ^[0-9]+$ ]] || die "--web-port must be a number"
[[ "$CDP_PORT" =~ ^[0-9]+$ ]] || die "--cdp-port must be a number"
VNC_PORT=$((5900 + DISPLAY_NUM))

HOME_DIR="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[[ -n "$HOME_DIR" && -d "$HOME_DIR" ]] || die "no home directory for user $TARGET_USER"
TARGET_UID="$(id -u "$TARGET_USER")"

VNC_UNIT="hermes-vnc-${DISPLAY_NUM}"
NOVNC_UNIT="hermes-novnc-${DISPLAY_NUM}"
CHROME_UNIT="hermes-chrome-${DISPLAY_NUM}"
XSTARTUP="${HOME_DIR}/.vnc/xstartup${DISPLAY_NUM}"
PROFILE_ROOT="${HOME_DIR}/.config/hermes-desktop"
HOSTNAME_SHORT="$(hostname -s)"

have_sudo() { sudo -n true 2>/dev/null; }

check_port() {
  local name="$1" port="$2" unit="$3" pid owner
  if ! port_in_use "$port"; then say "$name port ${port} free"; return 0; fi
  if systemctl is-active --quiet "$unit" 2>/dev/null; then
    say "$name port ${port} held by ${unit} (this install)"; return 0
  fi
  pid=$(port_pid "$port")
  owner=""
  if [[ -n "$pid" && -r "/proc/${pid}/cmdline" ]]; then
    owner=$(tr '\0' ' ' < "/proc/${pid}/cmdline" | grep -o -- '--user-data-dir=[^ ]*' | head -1)
  fi
  say "CONFLICT ${name} port ${port} is held by pid ${pid:-?}${owner:+ (${owner#--user-data-dir=})}"
  return 1
}

# Ports are host-wide. Several Hermes instances on one machine share loopback,
# so two desktops asking for 6080 or 9333 collide even though their profiles,
# state and skills are separate. The arithmetic below is the allocation rule:
#   display :N  ->  VNC 5900+N, noVNC 6079+N, CDP 9332+N
# N=1 gives the defaults (5901 / 6080 / 9333).
port_in_use() { ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$1\$"; }
port_pid() { ss -ltnp 2>/dev/null | awk -v p=":$1" '$0 ~ p {match($0, /pid=([0-9]+)/, m); print m[1]; exit}'; }

suggest_ports() {
  local n v w c
  for n in $(seq 1 20); do
    v=$((5900 + n)); w=$((6079 + n)); c=$((9332 + n))
    [[ -e "/tmp/.X11-unix/X${n}" ]] && continue
    port_in_use "$v" && continue
    port_in_use "$w" && continue
    port_in_use "$c" && continue
    echo "--display ${n} --web-port ${w} --cdp-port ${c}"
    return 0
  done
  return 1
}

# ---------------------------------------------------------------- verify ----
# Every claim below is measured, never inferred.
verify() {
  local n="$1"
  local wport="${2:-}"
  if [[ -z "$wport" ]]; then
    # Read the real web port from the unit rather than assuming the default.
    wport=$(systemctl show -p ExecStart --value "hermes-novnc-${n}" 2>/dev/null \
            | grep -o 'websockify[^;]*' | awk '{for(i=1;i<=NF;i++) if ($i ~ /^[0-9]+$/ && $i > 1024) {print $i; exit}}')
    [[ -z "$wport" ]] && wport="$WEB_PORT"
  fi
  local vport=$((5900 + n))
  local fails=0
  local vunit="hermes-vnc-${n}" wunit="hermes-novnc-${n}"
  echo "Verifying display :${n} (VNC ${vport}, web ${wport})"

  for u in "$vunit" "$wunit"; do
    if systemctl is-active --quiet "$u"; then say "PASS  ${u} active"
    else say "FAIL  ${u} not active"; fails=$((fails+1)); fi
  done

  if [[ -S "/tmp/.X11-unix/X${n}" ]]; then say "PASS  X socket X${n} exists"
  else say "FAIL  no /tmp/.X11-unix/X${n}"; fails=$((fails+1)); fi

  if ss -ltn 2>/dev/null | awk '{print $4}' | grep -qx "127.0.0.1:${vport}"; then
    say "PASS  VNC listening on 127.0.0.1:${vport} (loopback only)"
  else say "FAIL  nothing on 127.0.0.1:${vport}"; fails=$((fails+1)); fi

  if ss -ltn 2>/dev/null | awk '{print $4}' | grep -qx "0.0.0.0:${wport}"; then
    say "PASS  noVNC listening on 0.0.0.0:${wport}"
  else say "FAIL  nothing on 0.0.0.0:${wport}"; fails=$((fails+1)); fi

  # Real RFB handshake. The security-type list says what the server accepts:
  #   [1] = None (no password)   [2] = VncAuth (password)
  # If a password is configured, also prove a wrong one is actually refused.
  local rfb rfb_want="1"
  systemctl show -p ExecStart --value "$vunit" 2>/dev/null | grep -q 'SecurityTypes VncAuth' && rfb_want="2"
  rfb=$(python3 - "$vport" <<'PY' 2>&1 || true
import socket, sys
port = int(sys.argv[1])
s = socket.create_connection(("127.0.0.1", port), 6); s.settimeout(6)
banner = s.recv(12)
s.sendall(b"RFB 003.008\n")
n = s.recv(1)[0]
types = list(s.recv(n))
out = f"{banner!r} types={types}"
if 2 in types:
    s.sendall(b"\x02")
    s.recv(16)                        # challenge
    s.sendall(b"\x00" * 16)           # deliberately wrong response
    status = s.recv(4)
    out += (" wrong-password=refused" if status != b"\x00\x00\x00\x00" else " wrong-password=ACCEPTED")
print(out)
PY
)
  if [[ "$rfb" != *"RFB 003."* ]]; then
    say "FAIL  RFB handshake: ${rfb}"; fails=$((fails+1))
  elif [[ "$rfb_want" == "2" ]]; then
    if [[ "$rfb" == *"2]"* ]]; then say "PASS  RFB asks for a password (${rfb})"
    else say "FAIL  password configured but server offers: ${rfb}"; fails=$((fails+1)); fi
    if [[ "$rfb" == *"wrong-password=refused"* ]]; then say "PASS  a wrong password is refused"
    else say "FAIL  wrong password was not refused: ${rfb}"; fails=$((fails+1)); fi
  else
    if [[ "$rfb" == *"types=[1]"* ]]; then say "PASS  RFB handshake: ${rfb} (passwordless by design)"
    else say "FAIL  expected passwordless types=[1], got: ${rfb}"; fails=$((fails+1)); fi
  fi

  # Web door: page must exist, and the WebSocket upgrade must really reach the
  # VNC server (the RFB banner arrives as the first binary frame).
  local code ws
  code=$(curl -s -o /dev/null -m 6 -w '%{http_code}' "http://127.0.0.1:${wport}/vnc.html" || echo 000)
  if [[ "$code" == "200" ]]; then say "PASS  /vnc.html returns 200"
  else say "FAIL  /vnc.html returns ${code}"; fails=$((fails+1)); fi

  ws=$(python3 - "$wport" <<'PY' 2>&1 || true
import base64, os, socket, sys
port = int(sys.argv[1])
s = socket.create_connection(("127.0.0.1", port), 6); s.settimeout(6)
key = base64.b64encode(os.urandom(16)).decode()
s.sendall(("GET /websockify HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\n"
           "Connection: Upgrade\r\nSec-WebSocket-Key: %s\r\n"
           "Sec-WebSocket-Version: 13\r\nSec-WebSocket-Protocol: binary\r\n\r\n" % key).encode())
head = b""
while b"\r\n\r\n" not in head:
    chunk = s.recv(1)
    if not chunk: break
    head += chunk
if b"101" not in head.split(b"\r\n")[0]:
    print("handshake:", head.split(b"\r\n")[0]); raise SystemExit
hdr = s.recv(2)
ln = hdr[1] & 0x7F
if ln == 126: ln = int.from_bytes(s.recv(2), "big")
payload = s.recv(ln)
print(repr(payload))
PY
)
  if [[ "$ws" == *"RFB 003."* ]]; then say "PASS  websockify -> VNC proven (first frame: ${ws})"
  else say "FAIL  websockify did not return an RFB banner: ${ws}"; fails=$((fails+1)); fi

  if [[ "$(id -un)" == "$TARGET_USER" ]] && command -v xdotool >/dev/null 2>&1; then
    local wm
    wm=$(DISPLAY=":${n}" timeout 5 xdotool getactivewindow getwindowname 2>/dev/null || true)
    [[ -n "$wm" ]] && say "PASS  X session answers on :${n} (active window: ${wm})"
  fi

  # The browser must actually be able to render. A Chrome whose zygote died still
  # listens on its CDP port while every tab hangs on "took too long to load".
  local cunit="hermes-chrome-${n}" cport rc
  cport=$(systemctl show -p ExecStart --value "$cunit" 2>/dev/null \
          | grep -o 'remote-debugging-port=[0-9]*' | cut -d= -f2 | head -1)
  if [[ -n "$cport" ]]; then
    # The port answering is not enough: another instance's Chrome would answer
    # just as happily, and the agent would drive the wrong browser with the
    # wrong logins. Check the listening process actually carries our profile.
    local cpid cowner prof0
    prof0=$(systemctl show -p ExecStart --value "$cunit" 2>/dev/null \
            | grep -o 'user-data-dir=[^ ]*' | cut -d= -f2 | head -1)
    cpid=$(port_pid "$cport")
    if [[ -n "$cpid" && -r "/proc/${cpid}/cmdline" ]]; then
      cowner=$(tr '\0' ' ' < "/proc/${cpid}/cmdline" | grep -o -- '--user-data-dir=[^ ]*' | head -1)
      if [[ -n "$prof0" && "$cowner" != *"$prof0"* ]]; then
        say "FAIL  CDP ${cport} belongs to another instance (${cowner#--user-data-dir=}) — the agent would drive the wrong browser"
        fails=$((fails+1))
      else
        say "PASS  CDP ${cport} belongs to this install (pid ${cpid})"
      fi
    fi
    rc=$(python3 - "$cport" <<'PY' 2>&1 || true
import asyncio, json, sys, urllib.request
port = sys.argv[1]
try:
    targets = json.load(urllib.request.urlopen(f"http://127.0.0.1:{port}/json/list", timeout=6))
except Exception as exc:
    print(f"cdp-unreachable: {exc}"); raise SystemExit
pages = [t for t in targets if t.get("type") == "page"]
if not pages:
    print("no-page-target"); raise SystemExit
t = pages[0]
async def main():
    import websockets
    async with websockets.connect(t["webSocketDebuggerUrl"], max_size=2**22) as ws:
        await ws.send(json.dumps({"id": 1, "method": "Runtime.evaluate",
                                  "params": {"expression": "document.readyState",
                                             "returnByValue": True}}))
        while True:
            msg = json.loads(await asyncio.wait_for(ws.recv(), timeout=10))
            if msg.get("id") == 1:
                print(msg.get("result", {}).get("result", {}).get("value")); return
try:
    asyncio.run(main())
except ModuleNotFoundError:
    print("skip-no-websockets")
except Exception as exc:
    print(f"eval-failed: {exc}")
PY
)
    case "$rc" in
      complete|interactive|loading) say "PASS  Chrome on :${n} executes JS (CDP ${cport}, readyState=${rc})" ;;
      skip-no-websockets)           say "SKIP  Chrome render check (python websockets not installed)" ;;
      *) say "FAIL  Chrome on :${n} does not render: ${rc}"; fails=$((fails+1)) ;;
    esac

    # The profile is the whole point: it keeps logins, bookmarks and extensions.
    local prof
    prof=$(systemctl show -p ExecStart --value "$cunit" 2>/dev/null \
           | grep -o 'user-data-dir=[^ ]*' | cut -d= -f2 | head -1)
    if [[ -n "$prof" ]]; then
      if [[ -d "$prof" ]]; then
        say "PASS  profile persists at ${prof} ($(du -sh "$prof" 2>/dev/null | cut -f1))"
      else
        say "FAIL  profile directory missing: ${prof}"; fails=$((fails+1))
      fi
    fi
  fi

  echo
  if [[ $fails -eq 0 ]]; then
    echo "RESULT: display :${n} is live.  Browser door: http://$(hostname -I | awk '{print $1}'):${wport}/vnc.html"
    return 0
  fi
  echo "RESULT: ${fails} check(s) failed."
  return 1
}

if [[ "$MODE" == "suggest" ]]; then
  block=$(suggest_ports) || die "no free display/port block in 1..20 — clean up unused desktops first"
  echo "next free block on $(hostname -s):"
  echo "  $0 $block"
  exit 0
fi

if [[ "$MODE" == "verify" ]]; then verify "$VERIFY_ONLY"; exit $?; fi

# ------------------------------------------------------------- uninstall ----
if [[ "$MODE" == "uninstall" ]]; then
  have_sudo || die "sudo needed to remove systemd units"
  # Capture the profile path before the unit file goes away.
  kept="$(grep -o 'user-data-dir=[^ ]*' "/etc/systemd/system/hermes-chrome-${VERIFY_ONLY}.service" 2>/dev/null | cut -d= -f2 || true)"
  for u in "hermes-chrome-${VERIFY_ONLY}" "hermes-novnc-${VERIFY_ONLY}" "hermes-vnc-${VERIFY_ONLY}"; do
    sudo systemctl disable --now "$u" 2>/dev/null || true
    sudo rm -f "/etc/systemd/system/${u}.service"
    say "removed ${u}"
  done
  sudo systemctl daemon-reload
  rm -f "${HOME_DIR}/.vnc/xstartup${VERIFY_ONLY}"
  # The browser profile is never deleted: it holds logins, bookmarks and extensions.
  echo "Display :${VERIFY_ONLY} removed (log files under ${HOME_DIR}/.vnc/ left in place)."
  [[ -n "$kept" && -d "$kept" ]] && echo "Browser profile kept at ${kept} — delete it yourself only if you want to lose those logins."
  exit 0
fi

# --------------------------------------------------------------- install ----
hdr "Preconditions"
[[ -x /usr/bin/vncserver ]] || MISSING_PKGS=1
command -v websockify >/dev/null || MISSING_PKGS=1
[[ -d /usr/share/novnc ]] || MISSING_PKGS=1
command -v xfce4-session >/dev/null || MISSING_PKGS=1

if [[ "${MISSING_PKGS:-0}" == "1" ]]; then
  say "packages missing — installing (tigervnc, novnc, websockify, xfce4)"
  if [[ "$DRY_RUN" == "1" ]]; then
    say "[dry-run] would run: sudo apt-get install -y tigervnc-standalone-server tigervnc-common novnc websockify xfce4-session xfce4-terminal dbus-x11 xdotool python3-websockets"
  else
    have_sudo || die "sudo needed to install packages"
    sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
      tigervnc-standalone-server tigervnc-common novnc websockify \
      xfce4-session xfce4-terminal dbus-x11 xdotool python3-websockets
  fi
else
  say "tigervnc, noVNC, websockify and XFCE all present"
fi

hdr "Browser"
BROWSER_BIN=""
BROWSER_NAME=""
if [[ "$WITH_CHROME" == "1" ]]; then
  case "$BROWSER" in
    chrome|chromium|auto) ;;
    *) die "--browser must be chrome, chromium or auto" ;;
  esac
  pick() { for b in "$@"; do command -v "$b" 2>/dev/null && return 0; done; return 1; }
  case "$BROWSER" in
    chrome)   BROWSER_BIN=$(pick google-chrome google-chrome-stable || true) ;;
    chromium) BROWSER_BIN=$(pick chromium chromium-browser || true) ;;
    auto)     BROWSER_BIN=$(pick google-chrome google-chrome-stable chromium chromium-browser || true) ;;
  esac

  if [[ -z "$BROWSER_BIN" ]]; then
    # Chrome (the Google build) is preferred: only it can sign in to Chrome Sync,
    # which is what carries bookmarks and the password manager between machines.
    if [[ "$BROWSER" != "chromium" && "$(uname -m)" == "x86_64" ]]; then
      say "Chrome not installed — installing google-chrome-stable"
      if [[ "$DRY_RUN" == "1" ]]; then
        say "[dry-run] would download google-chrome-stable_current_amd64.deb and install it"
        BROWSER_BIN="google-chrome"
      else
        have_sudo || die "sudo needed to install Chrome"
        deb="$(mktemp -d)/google-chrome.deb"
        curl -fsSL -o "$deb" https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb \
          || die "could not download Chrome (no network?)"
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$deb" || die "Chrome install failed"
        BROWSER_BIN=$(pick google-chrome google-chrome-stable || true)
      fi
    else
      [[ "$BROWSER" == "chrome" ]] && say "Chrome is not published for $(uname -m) — using Chromium"
      say "Chromium not installed — installing chromium-browser"
      if [[ "$DRY_RUN" == "1" ]]; then
        say "[dry-run] would run: sudo apt-get install -y chromium-browser"
        BROWSER_BIN="chromium"
      else
        have_sudo || die "sudo needed to install Chromium"
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq chromium-browser || die "Chromium install failed"
        BROWSER_BIN=$(pick chromium chromium-browser || true)
      fi
    fi
  fi
  [[ -n "$BROWSER_BIN" ]] || die "no usable browser found"

  case "$(basename "$BROWSER_BIN")" in
    *chromium*) BROWSER_NAME="chromium" ;;
    *)          BROWSER_NAME="chrome" ;;
  esac
  PROFILE_DIR="${PROFILE_DIR:-${PROFILE_ROOT}/${BROWSER_NAME}-${DISPLAY_NUM}}"
  [[ "$PROFILE_DIR" = /* ]] || die "--profile-dir must be an absolute path"
  case "$PROFILE_DIR" in
    /tmp/*|/run/*|/var/tmp/*) die "profile must persist across reboots — refusing a temporary profile dir: $PROFILE_DIR" ;;
  esac
  say "browser: ${BROWSER_BIN} (${BROWSER_NAME}) — profile ${PROFILE_DIR}"
  [[ "$BROWSER_NAME" == "chromium" ]] && \
    say "note: Chromium cannot sign in to Chrome Sync (no Google API keys). The profile still persists."
fi

hdr "Ports"
conflict=0
if [[ -e "/tmp/.X11-unix/X${DISPLAY_NUM}" ]] && ! systemctl is-active --quiet "${VNC_UNIT}" 2>/dev/null; then
  say "CONFLICT display :${DISPLAY_NUM} already has an X socket (/tmp/.X11-unix/X${DISPLAY_NUM})"
  conflict=1
fi
check_port "VNC" "$VNC_PORT" "$VNC_UNIT" || conflict=1
check_port "noVNC" "$WEB_PORT" "$NOVNC_UNIT" || conflict=1
if [[ "$WITH_CHROME" == "1" ]]; then check_port "CDP" "$CDP_PORT" "$CHROME_UNIT" || conflict=1; fi
if [[ "$conflict" == "1" ]]; then
  echo
  echo "  These ports are host-wide, not per Hermes profile: another instance on this"
  echo "  machine already owns one of them. Pick the next free block with:"
  echo "      $0 --suggest"
  exit 1
fi
say "display :${DISPLAY_NUM} -> VNC ${VNC_PORT}, noVNC ${WEB_PORT}${WITH_CHROME:+, CDP ${CDP_PORT}}"

hdr "Write the desktop session script"
XSTARTUP_CONTENT="#!/bin/sh
# Session script for display :${DISPLAY_NUM} — written by hermes-desktop-provision.sh
# DISPLAY is explicit so this session can never land on another display.
export DISPLAY=:${DISPLAY_NUM}
export HOME=${HOME_DIR}
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
xsetroot -solid '#2e3436'
vncconfig -iconic &
# xfce4-session must stay in the foreground: vncserver treats this script
# exiting as the end of the session and kills the display.
exec dbus-launch --exit-with-session xfce4-session
"
say "$XSTARTUP"

hdr "Write systemd units (system units — survive reboot, start at boot)"

# ---------------------------------------------------------------- access ----
# Optional VNC password: RFB asks for it before a single pixel is drawn, so the
# noVNC door stops being "a full desktop to anyone who can reach the port".
# TigerVNC's VncAuth uses only the first 8 characters - say so rather than
# pretend a longer password buys anything.
as_target() { if [[ "$EUID" -eq 0 ]]; then sudo -u "$TARGET_USER" "$@"; else "$@"; fi; }

if [[ "$WANT_PASSWORD" == "1" ]]; then
  hdr "Access"
  pass_dir="${HOME_DIR}/.vnc"
  dest="${pass_dir}/passwd-${DISPLAY_NUM}"

  if [[ -n "$PASSWORD_FILE_IN" ]]; then
    [[ -r "$PASSWORD_FILE_IN" ]] || die "cannot read password file: ${PASSWORD_FILE_IN}"
    say "using existing VNC passwd file ${PASSWORD_FILE_IN}"
  elif [[ "$GEN_PASSWORD" == "1" ]]; then
    # head -c closes the pipe first; under `set -o pipefail` tr then exits on
    # SIGPIPE and kills the whole script. `|| true` keeps that harmless.
    VNC_PASSWORD=$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom 2>/dev/null | head -c 8 || true)
    say "generated an 8-character password - shown once, save it now:"
    say "    ${VNC_PASSWORD}"
    say "(VncAuth uses only the first 8 characters, so this is the whole secret)"
  else
    IFS= read -r VNC_PASSWORD || true
    [[ -n "${VNC_PASSWORD:-}" ]] || die "--vnc-password-stdin needs the password on stdin"
    [[ ${#VNC_PASSWORD} -gt 8 ]] && say "note: VncAuth uses only the first 8 characters"
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    say "[dry-run] would write ${dest} (mode 600) and require a password"
  else
    as_target mkdir -p "$pass_dir"
    as_target chmod 700 "$pass_dir"
    if [[ -n "$PASSWORD_FILE_IN" ]]; then
      as_target install -m 600 "$PASSWORD_FILE_IN" "$dest"
    else
      command -v vncpasswd >/dev/null || die "vncpasswd not found (install tigervnc-tools)"
      printf '%s\n' "$VNC_PASSWORD" | as_target sh -c "vncpasswd -f > '$dest'"
      as_target chmod 600 "$dest"
    fi
    [[ -s "$dest" ]] || die "password file ${dest} was not written"
    say "password file ${dest} (mode 600, owner ${TARGET_USER})"
  fi
  VNC_PASS_FILE="$dest"
  VNC_SEC_ARGS="-SecurityTypes VncAuth -PasswordFile ${dest}"
fi

VNC_UNIT_CONTENT="[Unit]
Description=Hermes desktop display :${DISPLAY_NUM} (TigerVNC + XFCE)
After=network.target

[Service]
Type=forking
User=${TARGET_USER}
Group=${TARGET_USER}
Environment=HOME=${HOME_DIR}
Environment=USER=${TARGET_USER}
# Loopback-only always. Auth depends on how this display was installed:
#   -SecurityTypes None            -> passwordless (noVNC door is the only gate)
#   -SecurityTypes VncAuth -PasswordFile ...  -> password before any pixels
# vncserver refuses a network-exposed passwordless server by design.
ExecStart=/usr/bin/vncserver :${DISPLAY_NUM} -geometry ${GEOMETRY} -depth 24 -localhost yes ${VNC_SEC_ARGS} -xstartup ${XSTARTUP}
ExecStop=/usr/bin/vncserver -kill :${DISPLAY_NUM}
Restart=on-failure
RestartSec=5
PIDFile=${HOME_DIR}/.vnc/${HOSTNAME_SHORT}:${DISPLAY_NUM}.pid

[Install]
WantedBy=multi-user.target
"
NOVNC_UNIT_CONTENT="[Unit]
Description=noVNC web page for display :${DISPLAY_NUM} (${WEB_PORT} -> ${VNC_PORT})
After=${VNC_UNIT}.service
Wants=${VNC_UNIT}.service

[Service]
Type=simple
User=${TARGET_USER}
Group=${TARGET_USER}
ExecStart=/usr/bin/websockify --web=/usr/share/novnc ${WEB_PORT} localhost:${VNC_PORT}
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
"
CHROME_UNIT_CONTENT="[Unit]
Description=Desktop Chrome on :${DISPLAY_NUM} (CDP ${CDP_PORT})
After=${VNC_UNIT}.service
Requires=${VNC_UNIT}.service

[Service]
Type=simple
User=${TARGET_USER}
Group=${TARGET_USER}
Environment=HOME=${HOME_DIR}
Environment=DISPLAY=:${DISPLAY_NUM}
# Without a session bus / runtime dir the zygote child dies at startup and every
# tab hangs on took-too-long-to-load (measured on op3, Chrome 156).
Environment=XDG_RUNTIME_DIR=/run/user/${TARGET_UID}
Environment=DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${TARGET_UID}/bus
# Chrome 136+ refuses --remote-debugging-port without an explicit --user-data-dir.
ExecStartPre=/bin/sleep 5
ExecStart=/opt/google/chrome/google-chrome --user-data-dir=${PROFILE_DIR} --remote-debugging-port=${CDP_PORT} --renderer-process-limit=15 --remote-allow-origins=* --no-first-run --no-default-browser-check --password-store=basic --start-maximized
Restart=on-failure
RestartSec=5
MemoryMax=2G
TasksMax=200

[Install]
WantedBy=multi-user.target
"

if [[ "$DRY_RUN" == "1" ]]; then
  hdr "[dry-run] ${VNC_UNIT}.service"; echo "$VNC_UNIT_CONTENT"
  hdr "[dry-run] ${NOVNC_UNIT}.service"; echo "$NOVNC_UNIT_CONTENT"
  [[ "$WITH_CHROME" == "1" ]] && { hdr "[dry-run] ${CHROME_UNIT}.service"; echo "$CHROME_UNIT_CONTENT"; }
  echo; echo "dry-run complete — nothing was written."
  exit 0
fi

have_sudo || die "sudo needed to install systemd units"

mkdir -p "${HOME_DIR}/.vnc"
if [[ -f "$XSTARTUP" ]]; then
  cp -a "$XSTARTUP" "${XSTARTUP}.bak.$(date +%Y%m%d%H%M%S)"
  say "backed up existing $XSTARTUP"
fi
printf '%s' "$XSTARTUP_CONTENT" > "$XSTARTUP"
chmod 755 "$XSTARTUP"
say "wrote $XSTARTUP"

tmpd=$(mktemp -d)
printf '%s' "$VNC_UNIT_CONTENT" > "${tmpd}/${VNC_UNIT}.service"
printf '%s' "$NOVNC_UNIT_CONTENT" > "${tmpd}/${NOVNC_UNIT}.service"
sudo install -m 644 "${tmpd}/${VNC_UNIT}.service" "/etc/systemd/system/${VNC_UNIT}.service"
sudo install -m 644 "${tmpd}/${NOVNC_UNIT}.service" "/etc/systemd/system/${NOVNC_UNIT}.service"
say "/etc/systemd/system/${VNC_UNIT}.service"
say "/etc/systemd/system/${NOVNC_UNIT}.service"

# A bare host:port URL silently fails: websockify's web root has no index page.
if [[ ! -f /usr/share/novnc/index.html ]]; then
  echo '<!DOCTYPE html><meta http-equiv="refresh" content="0; url=vnc.html">' | sudo tee /usr/share/novnc/index.html >/dev/null
  say "added /usr/share/novnc/index.html redirect (bare host:port URLs now work)"
fi

if [[ "$WITH_CHROME" == "1" ]]; then
  printf '%s' "$CHROME_UNIT_CONTENT" > "${tmpd}/${CHROME_UNIT}.service"
  sudo install -m 644 "${tmpd}/${CHROME_UNIT}.service" "/etc/systemd/system/${CHROME_UNIT}.service"
  say "/etc/systemd/system/${CHROME_UNIT}.service (profile ${PROFILE_DIR}, CDP ${CDP_PORT})"
fi
rm -rf "$tmpd"

hdr "Firewall"
if [[ "$USE_UFW" == "1" ]] && command -v ufw >/dev/null && sudo ufw status 2>/dev/null | grep -q "Status: active"; then
  sudo ufw allow from "$ALLOW_CIDR" to any port "$WEB_PORT" proto tcp comment "Hermes noVNC display :${DISPLAY_NUM}" >/dev/null
  say "ufw: ${WEB_PORT}/tcp allowed from ${ALLOW_CIDR} only"
else
  say "ufw not active or skipped — ${WEB_PORT} reachability depends on the host firewall"
fi

hdr "Start"
sudo systemctl daemon-reload
sudo systemctl enable --now "${VNC_UNIT}" "${NOVNC_UNIT}"
[[ "$WITH_CHROME" == "1" ]] && sudo systemctl enable --now "${CHROME_UNIT}"
sleep 6

hdr "Verify"
verify "$DISPLAY_NUM" "$WEB_PORT"

cat <<EOF

Next steps
  Browser:  http://$(hostname -I | awk '{print $1}'):${WEB_PORT}/vnc.html
  Agent:    CDP at http://127.0.0.1:${CDP_PORT} — connect_over_cdp, or drive real
            X11 input with bin/desktop_input.py. Log in once via the browser door.
  Profile:  ${PROFILE_DIR}
            persistent: sign in to Chrome once and bookmarks/passwords sync from
            your other machines. Nothing here is wiped on rebuild or reboot.
  Access:   $(if [[ -n "$VNC_PASS_FILE" ]]; then echo "VNC password required (file ${VNC_PASS_FILE}) - noVNC asks for it"; else echo "NO password: anyone who reaches the web port gets this desktop"; fi)
  Re-check: $0 --verify ${DISPLAY_NUM}
  Remove:   $0 --uninstall ${DISPLAY_NUM}
EOF
