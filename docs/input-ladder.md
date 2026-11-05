# The input ladder — four ways to make a page do something

The failure this document prevents: installing three automation stacks, then not knowing which one
to reach for, then blaming the wrong one when a click does nothing.

Order matters. Try them top-down. Stop at the first that works.

| Level | Where the action happens | Use when | Cost |
|---|---|---|---|
| 1. Page API | inside the page's own JS | the site has an API, or the data is already in the page | fastest, no UI |
| 2. DOM action over CDP | Chrome's DOM, via DevTools | default for everything | exact, fast |
| 3. X11 input | the X server, below Chrome | CDP input is ignored, or must look human | needs coordinates, ~200 ms |
| 4. Human | the noVNC page | secrets, 2FA, CAPTCHA | human's time |

## 1. Page API — skip the UI

Everything the page can do, its own JavaScript can do, with the session cookies already attached.
No coordinates, no elements, survives layout changes.

```python
# inside the tab, over CDP
await page.evaluate("""async () => {
  const r = await fetch('/api/orders?limit=50', {credentials: 'include'});
  return (await r.json()).items.map(o => o.id);
}""")
```

Use it for reads and for anything the site's own front end calls. Do not use it to fake a purchase,
a submit or an upload: the site may verify the UI flow, and a "success" that never touched the UI is
a false positive.

## 2. DOM action over CDP — the default

```python
page.locator("#submit").click()
page.locator("input[name=q]").fill("hello")
page.keyboard.press("Enter")
```

- Exact and coordinate-free; works on elements scrolled out of view; waits for actionability.
- This is what `browser_exec` / Playwright / Puppeteer do, and it is right ~95% of the time.

It fails in three specific situations:

1. **Canvas / WebGL / maps** — there is no DOM element to click, only pixels.
2. **Cross-origin widgets** (embedded players, some payment iframes) — the DOM is out of reach.
3. **Input the page deliberately ignores** — sites that check `event.isTrusted`, or that only accept
   pointer events from the compositor.

## 3. X11 input — act below the browser

`xdotool` asks the X server to move the pointer and click. Chrome then receives a normal hardware
event: `isTrusted === true`, routed through the compositor like any human's click. Pages that ignore
CDP-injected events cannot tell the difference, because nothing was injected.

The catch: xdotool needs **absolute screen coordinates**, and it cannot scroll an element into view.
So read with CDP, act with X11:

```bash
# where is it? (CDP finds, scrolls, reports the screen pixel)
bin/desktop_input.py --display :1 --cdp http://127.0.0.1:9333 \
    where --selector '#canvas-button' --dry-run

# click it at that pixel, through the X server
bin/desktop_input.py --display :1 click --selector '#canvas-button'

# type into a field (clicks to focus first, then types with real key events)
bin/desktop_input.py --display :1 type --selector '#search' --text 'hello world'
```

How the coordinate mapping works: Chrome reports the element's box in page coordinates plus the
window's screen position and the height of its own toolbars. Add the two and you have the screen
pixel. That is why the helper needs CDP even in X11 mode — and why it is the only combination that
stays correct when the window moves or the page scrolls.

Verify it worked by reading back, not by assuming:

```bash
# the page's own state is the proof
bin/desktop_input.py --display :1 where --selector '#count' --dry-run   # then read the text over CDP
```

Limits: one display, one pointer — do not run two X11 actions concurrently on the same display; the
pointer is shared state. And `xdotool type` sends keysyms, so IME-only input (Chinese, emoji pickers)
will not work; use CDP `insertText` for that.

## 4. Human in the loop

Some steps must not pass through an agent: passwords, 2FA codes, CAPTCHA, bank confirmations. Send
the human the browser door URL and let them do exactly that step on the same desktop. Their session
persists in the Chrome profile, so the agent can carry on afterwards.

## What no input method fixes

Fingerprint-level blocking — a profile with no history, automation flags in the command line, no
plugins, headless GL — is a **browser** problem. The symptom is that the page loads but everything
is refused, or a challenge appears on every navigation. Fix it by using the desktop's real Chrome,
logging in once by hand, and reusing that profile. Switching input method will not help; adding
another automation library will make it worse.

## Why not bb-browser / Puppeteer / Selenium as extra fallbacks

They are the same two levels already listed (CDP DOM work, or CDP input with extra steps), installed
a second time, with their own browser binaries and their own bugs. Every extra stack is another
"which one is running?" question at 2 a.m. This repo keeps one stack and exposes its lower level
explicitly as `bin/desktop_input.py`.
