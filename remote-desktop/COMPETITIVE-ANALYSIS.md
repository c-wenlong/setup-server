# Competitive analysis — browser-based remote desktop for kai-home-server

_Shipped note (2026-09-12): shipped with gnome-remote-desktop as the RDP backend instead of the xrdp verdict below (see PLAN.md decision D2)._

Surveyed 2026-09-11 for this box (Ryzen 5 2600, 7.7 GB RAM, GTX 1070,
Ubuntu 24.04, tailnet-only). Written for the agent that will build
`remote-desktop/setup.sh` — read this before PLAN.md so the *why* behind
the plan's constraints is legible.

The directory is named for the capability, not the app (like
`monitoring/`, which holds both Kuma and ntfy), so that swapping the
implementation later does not orphan the path. The chosen implementation
is **Apache Guacamole + xrdp**.

## The requirement

Operate **this host's** graphical desktop from a browser tab, on the
tailnet, from a Mac. Two words in that sentence did all the eliminating:

- **"this host's"** — not *a* desktop. The user's ask was to operate their
  Ubuntu machine, which means the session must see the host's filesystem,
  its Docker socket, `~/dev`, `~/services`. A containerized desktop is a
  different product wearing the same UI.
- **"browser"** — the user explicitly walked back from native clients
  after being offered them. A tool whose browser story is a preview or a
  paid tier does not qualify, however good its native apps are.

## Verdict: Apache Guacamole + xrdp

An HTML5 gateway (`guacd`) that translates browser input into RDP against
`xrdp` running on the host. Browser → Guacamole → xrdp → real host session.

| Why it won | Detail |
|---|---|
| Genuinely clientless | No agent, no extension, no app on the Mac. Any browser on the tailnet. |
| Operates the *host* | xrdp spawns a real session as the real user. Host FS, host docker, host everything. |
| Wayland is a non-issue | xrdp brings up its own X session, so none of the Wayland capture/injection problems apply. |
| Licensing is clean | Apache-2.0, no tiers, no seat math. |
| Extends beyond this box | Same portal can later front SSH, VNC, or the Mac itself — the one candidate that grows. |
| File transfer + clipboard | Drive redirection and an SFTP sidecar come free; clipboard via the Ctrl+Alt+Shift panel. |

### What it costs — state this plainly in SETUP.md

- ⚠️ **Host-level installs.** `xfce4` + `xrdp` via apt, with sudo. Every
  other service in this repo is a container or a user unit that touches
  nothing outside `$HOME`. This is a real deviation from the repo's grain
  and the reason a service-level `AGENTS.md` is warranted.
- ⚠️ **RAM.** ~400 MB idle (Tomcat JVM + guacd), plus ~400–600 MB per
  active XFCE session. EXPLORATION.md's rule is "keep new always-on
  services in the tens-of-MB class"; this breaks it by an order of
  magnitude. Mitigating facts: the session cost is only paid while
  connected, and XFCE was chosen over GNOME precisely to keep it down.
  With ollama holding ~5 GB, a connected session is the difference between
  comfortable and swapping — worth measuring on first deploy.
- **Three moving parts** where this repo usually ships one container.
  Dropping Postgres for file-based auth (see PLAN.md) removes the worst of it.

### Version and security constraints — non-negotiable

- **Pin 1.6.0** (June 2025, still current as of this survey). It is also
  the release that fixed **CVE-2024-35164**, where the terminal emulator
  failed to validate console codes from SSH/telnet and allowed code
  execution as the `guacd` process. Anything ≤1.5.5 is disqualified.
- **Use the Docker images, not a native build.** Guacamole 1.6.0 supports
  FreeRDP 3 only experimentally and *fails to compile* with RDP enabled
  against `freerdp3-dev`, which is what current distros ship. The official
  images bundle FreeRDP 2 and sidestep this entirely. Do not "simplify"
  this into an apt/source install.

## What lost, and why

**KasmVNC / linuxserver `webtop`** — the closest call, and the better
engineering fit on paper: one container, HTML5 built in, no gateway, no
JVM, no host installs, contained RAM. It loses on the requirement, not on
quality: you get a desktop *in a container*, not this host's desktop. Host
files only appear where you bind-mount them, and the desktop dies with the
container. Keep it as the documented fallback if Guacamole's footprint
proves intolerable on 7.7 GB — but understand it as a scope change, not a
swap.

**RustDesk** — the tool that prompted the question, eliminated on four
counts. Its browser client is **controller-only** (a tab can drive a peer,
never host one). Serving the web client from your own server requires a
Pro plan satisfying `(users × 10) + devices ≥ 400`, i.e. far past this
box's scale; the free path routes through RustDesk's hosted client. Doing
it self-hosted also means exposing hbbs/hbbr's WSS ports 21118/21119 behind
a reverse proxy, and those trust `X-Real-IP`/`X-Forwarded-For` without
validation — anyone reaching them directly spoofs arbitrary IPs and defeats
rate limiting. Finally, unattended Wayland access is still a *preview*
build. Worth noting for the record: on a tailnet RustDesk's entire ID/relay
layer is redundant — Direct IP Access to `100.85.87.87` needs no server at
all, and a RustDesk maintainer says running one alongside Tailscale can
*reduce* performance. That is a good native-app answer. It is not a browser
answer.

**gnome-remote-desktop system Remote Login** — the best *native* option
(Wayland-native, headless by design, ships with GNOME 46+/Ubuntu 24.04, can
even use CUDA for AVC444 H.264 encode, which this box's GTX 1070 could
actually do). No browser client of its own, so it only enters as a backend
Guacamole could point at instead of xrdp — see PLAN.md decision D2.

**MeshCentral** — agent-based, browser desktop + terminal + file manager,
Apache-2.0, reportedly the simplest self-host of the bunch. Right answer
for a *fleet*; overweight as a control plane for one machine that already
has code-server, Kuma, beszel and a launcher.

**NoMachine** — best raw performance on Linux, free for personal use,
proprietary. Fails the repo's disposition, not its requirements.

**Sunshine + Moonlight** — lowest latency by a wide margin, and newly
plausible here: `nvidia-container-toolkit` 1.20.0 went in with Jellyfin's
NVENC work on 2026-09-11, so the GPU runtime now exists. (⚠️ EXPLORATION.md
line 47 still says the box has no GPU runtime — it is stale; DIRECTORY.md
is correct.) Native clients only, and needs a virtual display. This is the
escape hatch if Guacamole's latency disappoints for video or animation
work, not a browser answer.

**noVNC + TigerVNC** — the DIY floor. Fewer dependencies than Guacamole,
but you hand-roll TLS, auth and session lifecycle, and end up rebuilding a
worse Guacamole.

## Sources

- [Guacamole 1.6.0 manual](https://guacamole.apache.org/doc/1.6.0/gug/guacamole-native.html) · [release archive](https://guacamole.apache.org/releases/)
- [Guacamole 1.6 on Debian — FreeRDP 3 build failure](https://computingforgeeks.com/install-guacamole-debian/)
- [Guacamole vs RustDesk vs MeshCentral, tested](https://computingforgeeks.com/guacamole-vs-rustdesk-vs-meshcentral/)
- [RustDesk pricing — web client plan threshold](https://rustdesk.com/pricing/) · [self-host docs, WSS ports](https://rustdesk.com/docs/en/self-host/)
- [Tailscale — RustDesk direct connections](https://tailscale.com/docs/solutions/access-remote-desktops-with-rustdesk)
- [GNOME Remote Desktop with GPU encode](https://technotim.com/posts/gpu-accelerated-rdp/)
