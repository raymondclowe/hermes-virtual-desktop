# Several instances on one machine: port numbers

Ports are **per machine**, not per Hermes. Two Hermes profiles on one host — or a profile and the
human's own Chrome — share loopback, so a second instance asking for `6080` or `9333` collides with
the first even though their state, skills and memory are completely separate.

## The allocation rule

```
display :N   ->   VNC 5900+N      noVNC 6079+N      CDP 9332+N
```

`N = 1` gives the defaults: `:1`, `5901`, `6080`, `9333`.

| Instance | Display | VNC | noVNC | CDP |
|---|---|---|---|---|
| 1 | `:1` | 5901 | 6080 | 9333 |
| 2 | `:2` | 5902 | 6081 | 9334 |
| 3 | `:3` | 5903 | 6082 | 9335 |
| 4 | `:4` | 5904 | 6083 | 9336 |
| 5 | `:5` | 5905 | 6084 | 9337 |
| 6 | `:6` | 5906 | 6085 | 9338 |

Ask the machine which block is free; do not guess:

```bash
./install.sh --suggest
# next free block on this host:
#   ./install.sh --display 3 --web-port 6082 --cdp-port 9335
```

It skips a block if the X socket exists, if any of the three ports is listening, or if the display
number is taken. Install with exactly those numbers.

## The dangerous failure: the CDP port answers, but it is not yours

This is worse than a refusal. The installer starts Chrome with `--remote-debugging-port=9333`. If
something else already owns 9333, Chrome cannot open the port, starts anyway, and the agent connects
to **whatever is answering** — another Hermes instance's browser, or the human's personal Chrome. It
then acts with the wrong logins on the wrong sites, and nothing looks broken.

So the installer checks two separate things:

| Check | When | What it proves |
|---|---|---|
| preflight | before creating anything | the port is free, or held by *this* install's own unit |
| ownership | in `--verify` | the process listening on the CDP port carries **this profile** in its command line |

Measured on this host: asking for `9333` while the human's own Chrome holds it gives

```
CONFLICT CDP port 9333 is held by pid 346695 (/home/USERNAME/.config/chrome-raymond)
```

and the install stops. A correct install prints

```
PASS  CDP 9335 belongs to this install (pid 476377)
```

## Windows

Same rule, different commands. One CDP port and one profile directory per instance:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File windows/install.ps1 -CdpPort 9334
Get-NetTCPConnection -LocalPort 9334 -State Listen | Select-Object OwningProcess
```

`install.ps1` refuses a port held by someone else, and names the process. If the port already serves
the same profile it reuses that browser instead of starting a second one.

## Finding who owns a port

```bash
ss -ltnp | grep -E ':(5901|6080|9333)\b'          # pid + program
tr '\0' ' ' < /proc/<pid>/cmdline | grep -o 'user-data-dir=[^ ]*'
```

```powershell
Get-NetTCPConnection -LocalPort 9333 -State Listen |
    ForEach-Object { Get-CimInstance Win32_Process -Filter "ProcessId=$($_.OwningProcess)" } |
    Select-Object ProcessId, Name, CommandLine
```

## What does *not* isolate ports

Separate Hermes profiles, separate users' shells, separate venvs — none of these give you a separate
loopback. If the isolation must be real (two agents that must never see each other's browser), the
boundary has to be a network namespace:

| Option | Isolation | Cost |
|---|---|---|
| distinct port blocks on one host | logical only — a wrong port still reaches the other instance | none, needs discipline |
| LXD container or VM per Hermes | own loopback, own everything | one container per instance |
| WSL2 instance per Hermes (Windows host) | own network namespace inside the VM, port-forwarded | one distro per instance |

For agents that merely need their own desktop, port blocks are enough — that is what `--suggest` and
the ownership check are for. Use a container when "must never touch the other one" is a requirement
rather than a hope.

## A stale socket is not a running desktop

`--suggest` skips a display when `/tmp/.X11-unix/X<N>` exists. If a desktop crashed without cleaning
up, the socket stays behind and blocks that number forever. Check before removing it:

```bash
ls -l /tmp/.X11-unix/
fuser /tmp/.X11-unix/X2      # prints a pid if something is alive; empty means stale
```

Empty output → the socket is dead and can be deleted. A pid → a desktop is running there; leave it
alone and pick the next block.
