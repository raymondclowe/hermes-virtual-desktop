#!/usr/bin/env python3
"""desktop_input.py — send real X11 mouse/keyboard input to the Chrome running on
a virtual desktop, instead of injecting input through Chrome DevTools (CDP).

Why: CDP input is exact and fast and should be the default. Some pages, though,
refuse or ignore CDP-injected clicks — canvas overlays, WebGL maps, cross-origin
widgets, and sites that fingerprint the automation session. Those accept input
that arrives through the X server, because to the browser it *is* the keyboard
and mouse.

Division of labour, which is the whole trick:
  * CDP (read-only)  finds the element, scrolls it into view, reports its box
    and the window geometry.
  * X11 / xdotool    moves the pointer to the mapped screen pixel and clicks,
    or types the text.

Dependencies: python3 + the `websockets` package + `xdotool`. No Playwright, no
browser download.

Examples:
  desktop_input.py click --selector '#submit'
  desktop_input.py type --selector '#search' --text 'hello world'
  desktop_input.py key ctrl+l
  desktop_input.py where --selector '#submit' --dry-run

Defaults come from the environment when set: DESKTOP_CDP (http://127.0.0.1:9333)
and DESKTOP_DISPLAY (":1").
"""
from __future__ import annotations

import argparse
import asyncio
import json
import os
import pwd
import shutil
import subprocess
import sys
import time
import urllib.parse
import urllib.request

CDP = os.environ.get("DESKTOP_CDP", "http://127.0.0.1:9333").rstrip("/")
DISP = os.environ.get("DESKTOP_DISPLAY", ":1")


def fail(msg: str, code: int = 2) -> None:
    print(f"desktop_input: {msg}", file=sys.stderr)
    raise SystemExit(code)


def http_json(path: str, method: str = "GET"):
    req = urllib.request.Request(f"{CDP}{path}", method=method)
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            body = r.read()
            return json.loads(body) if body.strip() else {}
    except Exception as exc:
        fail(f"Chrome {method} {path} failed: {exc}")


def activate(target_id: str) -> None:
    """Bring the tab to the front. Chrome freezes background tabs, and a frozen
    page never answers Runtime.evaluate."""
    try:
        req = urllib.request.Request(f"{CDP}/json/activate/{target_id}", method="PUT")
        urllib.request.urlopen(req, timeout=6).read()
    except Exception:
        pass


def xdo(*args: str, check: bool = True) -> subprocess.CompletedProcess:
    if not shutil.which("xdotool"):
        fail("xdotool is not installed (apt-get install xdotool)")
    env = dict(os.environ, DISPLAY=DISP)
    return subprocess.run(["xdotool", *args], env=env, check=check,
                          capture_output=True, text=True)


def pick_target(url_contains: str | None) -> dict:
    targets = http_json("/json/list")
    pages = [t for t in targets
             if t.get("type") == "page" and not t["url"].startswith("devtools://")]
    if url_contains:
        pages = [t for t in pages if url_contains in t["url"]]
    if not pages:
        fail("no matching page target" + (f" for {url_contains!r}" if url_contains else ""))
    # Prefer a real page over the blank/newtab placeholder.
    pages.sort(key=lambda t: (t["url"].startswith("chrome://"), t["url"] == "about:blank"))
    return pages[0]


async def open_and_navigate(url: str) -> dict:
    """New tab, then navigate over CDP and wait for the page to actually load.

    /json/new?<url> alone is unreliable on a freshly started Chrome: the tab can
    stay on about:blank, frozen in the background.
    """
    target = http_json("/json/new?about:blank", method="PUT")
    activate(target["id"])
    async with Session(target["webSocketDebuggerUrl"]) as s:
        await s.send("Page.enable")
        await s.send("Page.navigate", url=url)
        state = None
        for _ in range(60):
            await asyncio.sleep(0.2)
            try:
                state = await s.evaluate("document.readyState")
            except SystemExit:
                raise
            except Exception:
                continue
            if state == "complete":
                break
        title = await s.evaluate("document.title")
    return {"opened": url, "target": target["id"], "readyState": state, "title": title}


def activate(target_id: str) -> None:
    """Bring the tab to the front. Chrome freezes background tabs, and a frozen
    page never answers Runtime.evaluate."""
    try:
        req = urllib.request.Request(f"{CDP}/json/activate/{target_id}", method="PUT")
        urllib.request.urlopen(req, timeout=6).read()
    except Exception:
        pass


class Session:
    def __init__(self, ws_url: str) -> None:
        self.url = ws_url
        self.ws = None
        self._id = 0

    async def __aenter__(self):
        import websockets
        self.ws = await websockets.connect(self.url, max_size=32 * 1024 * 1024)
        return self

    async def __aexit__(self, *exc):
        try:
            await self.ws.close()
        except Exception:
            pass

    async def send(self, method: str, **params):
        self._id += 1
        mid = self._id
        await self.ws.send(json.dumps({"id": mid, "method": method, "params": params}))
        while True:
            raw = await asyncio.wait_for(self.ws.recv(), timeout=20)
            msg = json.loads(raw)
            if msg.get("id") == mid:
                if "error" in msg:
                    fail(f"{method} failed: {msg['error']}")
                return msg.get("result", {})

    async def evaluate(self, expression: str):
        res = await self.send("Runtime.evaluate", expression=expression,
                              returnByValue=True, awaitPromise=True,
                              userGesture=True)
        if res.get("exceptionDetails"):
            fail(f"JS error: {res['exceptionDetails'].get('text')}")
        return res.get("result", {}).get("value")


GEOMETRY_JS = r"""
(sel) => {
  const el = document.querySelector(sel);
  if (!el) return {error: 'not found'};
  el.scrollIntoView({block: 'center', inline: 'center', behavior: 'instant'});
  const r = el.getBoundingClientRect();
  return {
    rect: {x: r.x, y: r.y, w: r.width, h: r.height},
    win: {sx: window.screenX, sy: window.screenY,
          ow: window.outerWidth, oh: window.outerHeight,
          iw: window.innerWidth, ih: window.innerHeight,
          dpr: window.devicePixelRatio || 1},
    tag: el.tagName,
    label: (el.innerText || el.value || el.getAttribute('aria-label') || '').slice(0, 40)
  };
}
"""


def screen_point(geom: dict) -> tuple[int, int]:
    """Map the element's viewport box centre to an absolute X11 screen pixel.

    Chrome reports window.screenX/screenY for the window frame and outerHeight
    including its own title bar, tab strip and toolbar; innerHeight is the page
    viewport. The difference is the UI chrome above the page. The WM frame, if
    any, is already inside screenX/screenY on X11, so no extra correction.
    """
    w = geom["win"]
    pad_y = max(0.0, w["oh"] - w["ih"])
    pad_x = max(0.0, (w["ow"] - w["iw"]) / 2.0)
    cx = w["sx"] + pad_x + geom["rect"]["x"] + geom["rect"]["w"] / 2.0
    cy = w["sy"] + pad_y + geom["rect"]["y"] + geom["rect"]["h"] / 2.0
    return int(round(cx)), int(round(cy))


async def run(args) -> int:
    target = pick_target(args.url_contains)
    activate(target["id"])
    out: dict = {"page": target["url"], "display": DISP, "cdp": CDP}

    async with Session(target["webSocketDebuggerUrl"]) as s:
        # Tabs sometimes throttle; make sure the window is not minimised.
        if args.cmd in ("click", "type", "where"):
            geom = await s.evaluate(f"({GEOMETRY_JS})({json.dumps(args.selector)})")
            if not geom or geom.get("error"):
                fail(f"selector {args.selector!r} not found on {target['url']}")
            x, y = screen_point(geom)
            out.update({"selector": args.selector, "screen": {"x": x, "y": y},
                        "element": geom["rect"], "window": geom["win"],
                        "label": geom.get("label", "")})
            if args.dry_run:
                out["dry_run"] = True
                print(json.dumps(out, indent=2))
                return 0

            xdo("mousemove", "--sync", str(x), str(y))
            time.sleep(0.10)
            xdo("mousemove", str(x - 3), str(y + 2), "sleep", "0.05")
            xdo("mousemove", "--sync", str(x), str(y))

            if args.cmd == "where":
                print(json.dumps(out, indent=2))
                return 0

            if args.cmd == "click":
                xdo("click", str(args.button))
                out["action"] = "click"
            elif args.cmd == "type":
                xdo("click", "1")           # focus the field first
                time.sleep(0.2)
                xdo("type", "--clearmodifiers", "--delay", "35", "--", args.text)
                out["action"] = "type"
                out["text"] = args.text
        elif args.cmd == "key":
            for k in args.keys:
                xdo("key", "--clearmodifiers", k)
                time.sleep(0.05)
            out.update({"action": "key", "keys": args.keys})
        elif args.cmd == "scroll":
            button = "5" if args.clicks > 0 else "4"
            xdo("click", "--repeat", str(abs(args.clicks)), "--delay", "60", button)
            out.update({"action": "scroll", "clicks": args.clicks})

    print(json.dumps(out, indent=2))
    return 0


def main() -> int:
    global CDP, DISP
    ap = argparse.ArgumentParser(description="X11-level input for a desktop Chrome (CDP for geometry, xdotool to act)")
    ap.add_argument("--cdp", default=CDP, help=f"Chrome DevTools base URL (default {CDP})")
    ap.add_argument("--display", default=DISP, help=f"X display (default {DISP})")
    ap.add_argument("--url-contains", default=None, help="choose the page by URL substring")
    ap.add_argument("--dry-run", action="store_true", help="report coordinates, send nothing")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("click"); p.add_argument("--selector", required=True); p.add_argument("--button", type=int, default=1)
    p.add_argument("--dry-run", dest="dry_run_sub", action="store_true", help=argparse.SUPPRESS)
    p = sub.add_parser("type"); p.add_argument("--selector", required=True); p.add_argument("--text", required=True)
    p.add_argument("--dry-run", dest="dry_run_sub", action="store_true", help=argparse.SUPPRESS)
    p = sub.add_parser("key"); p.add_argument("keys", nargs="+")
    p = sub.add_parser("scroll"); p.add_argument("clicks", type=int)
    p = sub.add_parser("where"); p.add_argument("--selector", required=True)
    p.add_argument("--dry-run", dest="dry_run_sub", action="store_true", help=argparse.SUPPRESS)
    p = sub.add_parser("open"); p.add_argument("url")

    args = ap.parse_args()
    CDP, DISP = args.cdp.rstrip("/"), args.display
    args.dry_run = args.dry_run or getattr(args, "dry_run_sub", False)

    if args.cmd == "open":
        print(json.dumps(asyncio.run(open_and_navigate(args.url)), indent=2))
        return 0
    return asyncio.run(run(args))


if __name__ == "__main__":
    raise SystemExit(main())
