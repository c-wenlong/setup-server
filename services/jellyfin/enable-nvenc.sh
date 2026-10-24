#!/usr/bin/env bash
#
# enable-nvenc.sh — give Docker a GPU, then switch Jellyfin onto NVENC.
#
# This is the one-time, sudo-requiring half of Jellyfin's hardware
# transcoding. setup.sh stays sudo-free and deliberately knows nothing about
# the host's GPU plumbing; it only reads JELLYFIN_NVENC from .env, which this
# script sets once the runtime is installed AND proven to work.
#
# What it does:
#   1. verifies the NVIDIA kernel driver is already loaded (nvidia-smi)
#   2. adds NVIDIA's apt repo — nvidia-container-toolkit is NOT in Ubuntu's
#      own archive, which is why plain `apt-get install` fails
#   3. installs nvidia-container-toolkit
#   4. registers the `nvidia` runtime with dockerd and restarts it
#   5. PROVES it: runs a throwaway container and expects nvidia-smi + the
#      encoder library to be present inside it
#   6. sets JELLYFIN_NVENC=on in .env and re-runs setup.sh
#
# Idempotent: every step is skipped if already done, so a re-run after a
# partial failure resumes rather than repeats. Safe to run on a live Jellyfin —
# the only disruption is a dockerd restart (step 4), which bounces every
# container on this box for a few seconds, and the Jellyfin restart in step 6.
#
# Linux only. macOS has no NVIDIA runtime; on a Mac use VideoToolbox instead,
# which needs no container plumbing at all.
#
# Usage:
#   ./enable-nvenc.sh            # install, verify, switch Jellyfin on
#   ./enable-nvenc.sh --check    # report status only, change nothing
#
# To undo: JELLYFIN_NVENC=off ./setup.sh   (leaves the toolkit installed)

set -euo pipefail

SERVICE_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SERVICE_DIR/.env"
KEYRING=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
APT_LIST=/etc/apt/sources.list.d/nvidia-container-toolkit.list
# Small, already-common base image. The toolkit injects nvidia-smi and the
# driver libraries from the host, so the image itself needs no CUDA payload —
# pulling nvidia/cuda for this check would cost ~2 GB to learn the same thing.
PROBE_IMAGE="ubuntu:24.04"

CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

info()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()    { printf '\033[1;32m ✓ \033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m ! \033[0m %s\n' "$*"; }
die()   { printf '\033[1;31m ✗ \033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- preflight
info "Preflight checks"
[ "$(uname -s)" = "Linux" ] || die "Linux only. On macOS, Jellyfin uses VideoToolbox — no container runtime needed."
[ "$(id -u)" -ne 0 ] || die "Run as a regular user, not root. This script escalates per command."
command -v curl >/dev/null || die "curl is required."
command -v docker >/dev/null || die "Docker is not installed."

command -v nvidia-smi >/dev/null \
  || die "nvidia-smi not found — the NVIDIA kernel driver is not installed. The container toolkit is a shim over that driver, not a replacement for it. Install it first: sudo ubuntu-drivers install"
GPU_NAME="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)"
DRIVER_VER="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)"
[ -n "$GPU_NAME" ] || die "nvidia-smi is present but returned no GPU. Check: nvidia-smi"
ok "GPU: $GPU_NAME (driver $DRIVER_VER)"

# Same failure mode setup.sh guards: a login session whose group list predates
# the docker group — `id` omits it while /etc/group lists it, so every docker
# call fails until the next login. `sg docker` starts a shell with the group
# list re-evaluated, so rather than making the caller know that, re-exec into
# it. The sentinel stops this recursing if sg itself lands somewhere that
# still cannot reach the daemon.
if ! docker ps >/dev/null 2>&1; then
  if [ -z "${NVENC_SG_REEXEC:-}" ] && sg docker -c 'docker ps' >/dev/null 2>&1; then
    warn "This shell's group list predates the docker group — re-running under \`sg docker\`."
    warn "  Log out and back in when convenient to fix it permanently."
    export NVENC_SG_REEXEC=1
    # %q-quote so a path with spaces survives sg's single -c string. sg keeps
    # the controlling terminal, so the sudo prompts below still work.
    exec sg docker -c "$(printf '%q ' "$SERVICE_DIR/enable-nvenc.sh" "$@")"
  fi
  if [ -n "${NVENC_SG_REEXEC:-}" ]; then
    die "Re-ran under \`sg docker\` and still cannot reach the Docker daemon. Is dockerd running? systemctl status docker"
  fi
  die "Cannot talk to the Docker daemon. Fix: sudo usermod -aG docker $USER, then log out and back in."
fi
ok "Docker daemon reachable"

[ -f "$ENV_FILE" ] || die "$ENV_FILE not found — deploy Jellyfin first: ./setup.sh"

runtime_present() { docker info --format '{{json .Runtimes}}' 2>/dev/null | grep -q '"nvidia"'; }

if [ "$CHECK_ONLY" = "1" ]; then
  command -v nvidia-ctk >/dev/null && ok "nvidia-container-toolkit installed" || warn "nvidia-container-toolkit NOT installed"
  runtime_present && ok "dockerd has the nvidia runtime" || warn "dockerd has NO nvidia runtime"
  if grep -q '^JELLYFIN_NVENC=on' "$ENV_FILE" 2>/dev/null; then
    ok "JELLYFIN_NVENC=on in .env"
  else
    warn "JELLYFIN_NVENC is not on in .env — Jellyfin is transcoding in software"
  fi
  exit 0
fi

# ------------------------------------------------------- 1. apt repository
if [ -f "$KEYRING" ] && [ -f "$APT_LIST" ]; then
  ok "NVIDIA container-toolkit apt repo already configured"
elif command -v nvidia-ctk >/dev/null; then
  ok "nvidia-container-toolkit already installed — skipping repo setup"
else
  info "Adding NVIDIA's apt repo (needs sudo: writes $KEYRING and $APT_LIST)"
  info "  nvidia-container-toolkit is not in Ubuntu's archive, so this is unavoidable."
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | sudo gpg --dearmor --yes -o "$KEYRING" \
    || die "Could not fetch or dearmor NVIDIA's signing key."
  curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed "s#deb https://#deb [signed-by=$KEYRING] https://#g" \
    | sudo tee "$APT_LIST" >/dev/null \
    || die "Could not write $APT_LIST."
  ok "Repo configured"
fi

# ---------------------------------------------------------- 2. the package
if command -v nvidia-ctk >/dev/null; then
  ok "nvidia-container-toolkit present ($(nvidia-ctk --version 2>/dev/null | head -1))"
else
  info "Installing nvidia-container-toolkit (needs sudo: apt-get)"
  sudo apt-get update -o Dir::Etc::sourcelist="$APT_LIST" -o Dir::Etc::sourceparts=- -o APT::Get::List-Cleanup=0 \
    || sudo apt-get update
  sudo apt-get install -y nvidia-container-toolkit || die "apt-get install nvidia-container-toolkit failed."
  command -v nvidia-ctk >/dev/null || die "Installed, but nvidia-ctk is still not on PATH."
  ok "Installed $(nvidia-ctk --version 2>/dev/null | head -1)"
fi

# ------------------------------------------------- 3. register with dockerd
if runtime_present; then
  ok "dockerd already has the nvidia runtime"
else
  info "Registering the nvidia runtime with dockerd (needs sudo: edits /etc/docker/daemon.json, restarts docker)"
  warn "  The restart briefly bounces EVERY container on this box (Seafile, Immich, Forgejo, …). They all have restart policies and come back on their own."
  sudo nvidia-ctk runtime configure --runtime=docker || die "nvidia-ctk runtime configure failed."
  sudo systemctl restart docker || die "Could not restart docker."
  # dockerd takes a moment to accept connections again after a restart.
  for _ in $(seq 1 30); do docker info >/dev/null 2>&1 && break; sleep 1; done
  runtime_present || die "docker restarted but still reports no nvidia runtime. Check /etc/docker/daemon.json and: journalctl -u docker -n 50"
  ok "nvidia runtime registered"
fi

# ------------------------------------------------------------- 4. prove it
# Two assertions, because the first can pass while the second fails — that is
# exactly the NVIDIA_DRIVER_CAPABILITIES trap docker-compose.gpu.yml exists to
# avoid, and it is worth catching here rather than as "hardware acceleration
# does nothing" three weeks from now.
info "Verifying GPU access inside a container (pulls $PROBE_IMAGE if absent)"
docker pull -q "$PROBE_IMAGE" >/dev/null 2>&1 || true
probe_smi="$(docker run --rm --gpus all "$PROBE_IMAGE" nvidia-smi --query-gpu=name --format=csv,noheader 2>&1)" \
  || die "A container could not see the GPU. Output: $probe_smi"
printf '%s' "$probe_smi" | grep -qi "nvidia\|geforce" \
  || die "Container ran but nvidia-smi returned something unexpected: $probe_smi"
ok "Container sees: $(printf '%s' "$probe_smi" | head -1)"

info "Verifying the ENCODER library is injected (the part --gpus all alone omits)"
if docker run --rm --gpus all -e NVIDIA_DRIVER_CAPABILITIES=all "$PROBE_IMAGE" \
     sh -c 'ls /usr/lib/x86_64-linux-gnu/libnvidia-encode.so* 2>/dev/null' >/dev/null 2>&1; then
  ok "libnvidia-encode present with NVIDIA_DRIVER_CAPABILITIES=all"
else
  warn "Could not confirm libnvidia-encode inside the container. NVENC may still work — Jellyfin's own ffmpeg is the real test — but if the dashboard shows NVENC enabled and transcodes stay on the CPU, this is the reason. See docker-compose.gpu.yml."
fi

# --------------------------------------------- 5. switch Jellyfin onto NVENC
# setup.sh owns the JELLYFIN_NVENC line in .env, so hand it the flag and let it
# persist the value rather than editing the file from two places.
info "Re-running setup.sh with the GPU attached"
JELLYFIN_NVENC=on "$SERVICE_DIR/setup.sh"

echo
printf '\033[1;32mNVENC plumbing is in place.\033[0m One manual step remains:\n'
echo
echo "  Jellyfin does NOT use the GPU until it is switched on in the web UI:"
echo "    Dashboard -> Playback -> Transcoding"
echo "    Hardware acceleration:  NVIDIA NVENC"
echo "    Enable hardware decoding for: H264, HEVC, VC1, VP9  (NOT AV1 — Pascal"
echo "      has no AV1 decoder, and ticking it makes those files fail instead"
echo "      of falling back to the CPU)"
echo "    Enable hardware encoding: on.  Tone mapping: leave off to start."
echo
echo "  Then confirm a real transcode uses it:"
echo "    play something that forces a transcode, and watch"
echo "      nvidia-smi dmon -s u        (the 'enc' column leaves 0)"
echo "    or check the log for 'h264_nvenc':"
echo "      docker compose --project-directory $SERVICE_DIR logs jellyfin | grep -i nvenc"
echo
echo "  What this GPU can and cannot do (GTX 1070, Pascal GP104):"
echo "    encode: H.264, HEVC 8-bit and 10-bit.  No AV1, no VP9 encode."
echo "    decode: H.264, HEVC 8/10-bit, VP9, VC1, MPEG2.  No AV1 decode."
echo "    GeForce cards also cap concurrent NVENC sessions in the driver —"
echo "      fine for a household, a wall for a many-viewer server."
echo
echo "  Status any time:  ./enable-nvenc.sh --check"
echo "  Undo:             JELLYFIN_NVENC=off ./setup.sh"
