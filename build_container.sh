#!/bin/bash

# FinTech Tools Container Build Script
# Build (Podman) -> export flat rootfs tar (podman export) -> scp to CIRCE.

set -e # Exit on any error

# Configuration
IMAGE_NAME="fintech-tools"
VERSION="0.9"
# Flat rootfs tar produced by `podman export` — deployed to CIRCE.
ROOTFS_TAR="$HOME/fintech-rootfs.tar"
REMOTE_USER="gson"
# The ~/.ssh/config Host ALIAS, not the hostname. ssh matches Host patterns
# against the name on the command line, so `gson@circe.rc.usf.edu` misses the
# `Host circe` block entirely — losing IdentityFile circe_key (→ password
# fallback on a key-only account) and the shared ControlPath (→ its own login).
REMOTE_HOST="circe"
# Rootfs tar destination on CIRCE. Home is persistent AND backed up (unlike
# /work, purged at 6 months); the tar is read only once per node at unpack, so
# its slightly slower bulk read off the home FS doesn't affect runtime. Both
# launchers prefer this home path and fall back to the old /work location.
REMOTE_ROOTFS_DIR="/home/g/${REMOTE_USER}/fintech-sb"
REMOTE_ROOTFS_PATH="${REMOTE_ROOTFS_DIR}/fintech-rootfs.tar"
# Repo dir — so the build can chain ./sync_configs.sh at the end (one-shot deploy).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Shared login-node connection budget (one master per run, 15-min backoff after a
# refusal, shared with sync_configs.sh + connect_nvim.sh). See ssh_master.sh.
. "${SCRIPT_DIR}/ssh_master.sh"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
  echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
  echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
  echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
  echo -e "${RED}[ERROR]${NC} $1"
}

# Timer functions
start_timer() {
  STEP_START_TIME=$(date +%s)
}

end_timer() {
  local step_name="$1"
  local end_time=$(date +%s)
  local elapsed=$((end_time - STEP_START_TIME))
  local minutes=$((elapsed / 60))
  local seconds=$((elapsed % 60))

  if [ $minutes -gt 0 ]; then
    print_success "✓ $step_name completed in ${minutes}m ${seconds}s"
  else
    print_success "✓ $step_name completed in ${seconds}s"
  fi
}

format_total_time() {
  local total_seconds="$1"
  local hours=$((total_seconds / 3600))
  local minutes=$(((total_seconds % 3600) / 60))
  local seconds=$((total_seconds % 60))

  if [ $hours -gt 0 ]; then
    echo "${hours}h ${minutes}m ${seconds}s"
  elif [ $minutes -gt 0 ]; then
    echo "${minutes}m ${seconds}s"
  else
    echo "${seconds}s"
  fi
}

# Function to check if command exists
command_exists() {
  command -v "$1" >/dev/null 2>&1
}

# Pushover notification functions
load_pushover_config() {
  PUSHOVER_CONFIG="$HOME/.pushover_config"
  if [ -f "$PUSHOVER_CONFIG" ]; then
    source "$PUSHOVER_CONFIG"
    if [ -n "$PUSHOVER_TOKEN" ] && [ -n "$PUSHOVER_USER" ]; then
      NOTIFICATIONS_ENABLED=true
      print_status "✓ Pushover notifications enabled"
    else
      print_warning "Pushover config found but incomplete. Notifications disabled."
      NOTIFICATIONS_ENABLED=false
    fi
  else
    print_warning "Pushover config not found at $PUSHOVER_CONFIG. Notifications disabled."
    NOTIFICATIONS_ENABLED=false
  fi
}

send_pushover_notification() {
  local title="$1"
  local message="$2"
  local priority="${3:-0}" # Default priority is normal (0)

  if [ "$NOTIFICATIONS_ENABLED" != "true" ]; then
    return 0
  fi

  if ! command_exists curl; then
    print_warning "curl not found. Cannot send notification."
    return 1
  fi

  print_status "📱 Sending notification: $title"

  # Use URL-encoded data as per Pushover API documentation
  local response=$(curl -s \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "token=${PUSHOVER_TOKEN}" \
    -d "user=${PUSHOVER_USER}" \
    -d "title=${title}" \
    -d "message=${message}" \
    -d "priority=${priority}" \
    https://api.pushover.net/1/messages.json)

  # Check if response contains "status":1 (success)
  if echo "$response" | grep -q '"status":1'; then
    print_status "✓ Notification sent successfully"
    return 0
  else
    print_warning "Failed to send notification: $response"
    return 1
  fi
}

# Force-remove all containers that are using the given image so the image
# can be deleted. Called as part of pre-build cleanup — no prompts.
cleanup_containers_using_image() {
  local image_name="$1"
  local container_ids

  container_ids=$(podman ps -a --filter "ancestor=localhost/${image_name}" \
    --format "{{.ID}}" 2>/dev/null)

  if [ -n "$container_ids" ]; then
    print_status "Removing containers using image ${image_name}..."
    for cid in $container_ids; do
      podman rm -f "$cid" 2>/dev/null && \
        print_success "✓ Container ${cid} removed" || \
        print_warning "Could not remove container ${cid} — continuing"
    done
  fi
}

# Remove ALL existing fintech-tools images (any tag) and their dependent
# containers before a new build, then prune dangling intermediate layers.
purge_old_images() {
  local old_ids
  old_ids=$(podman images --format "{{.ID}} {{.Repository}}:{{.Tag}}" 2>/dev/null \
    | grep -E "(localhost/)?${IMAGE_NAME}" | awk '{print $1}' | sort -u)
  if [ -n "$old_ids" ]; then
    print_status "Removing existing ${IMAGE_NAME} image(s)..."
    for id in $old_ids; do
      cleanup_containers_using_image "$id"
      podman image rm -f "$id" 2>/dev/null && \
        print_success "✓ Removed image ${id}" || true
    done
  fi
  # Deliberately NOT pruning dangling layers here. Those untagged layers ARE the
  # build cache: with --layers (podman's default) every RUN is committed as its
  # own layer, and a later build reuses them for every step whose instruction and
  # inputs are unchanged. Pruning pre-build threw that away on every run, so a
  # build that died at stage 11 — as one did on 2026-08-10, on disk — restarted
  # from apt/R/TinyTeX instead of resuming near the end. Removing the TAGGED
  # image above is enough to avoid confusion; its layers stay behind untagged and
  # still serve as cache. They are reclaimed by prune_build_cache() once a build
  # has actually succeeded.
}

# ─────────────────────────────────────────────────────────────────────────────
# Resolve "track latest" versions to concrete ones before building.
#
# The Dockerfile defaults NVIM_VERSION and CLAUDE_CODE_VERSION to `latest` and
# can resolve that itself, but doing it HERE buys two things a bare `latest`
# cannot:
#   * cache invalidation — a --build-arg that still reads `latest` is an
#     unchanged build argument, so podman happily reuses the cached install layer
#     and you silently keep last month's Neovim. Feeding in the concrete version
#     changes the arg the moment upstream publishes, which is what forces the
#     rebuild.
#   * a record — the exact versions land in the build log and the summary below,
#     so a container that misbehaves can be tied to what actually went into it.
#
# Both lookups are best-effort: on a network failure we fall back to the literal
# `latest`, and the Dockerfile resolves it (correctly, just cache-permitting).
# Override either by exporting NVIM_VERSION / CLAUDE_CODE_VERSION before running.
# ─────────────────────────────────────────────────────────────────────────────
BUILD_ARGS=()

resolve_latest_versions() {
  local nv cc

  # GitHub's /releases/latest redirect resolves to the newest NON-prerelease tag,
  # so this tracks stable and never a nightly. -w %{url_effective} avoids needing
  # a token or jq (the API endpoint is rate-limited for unauthenticated callers).
  nv="${NVIM_VERSION:-}"
  if [ -z "$nv" ]; then
    nv=$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
           https://github.com/neovim/neovim/releases/latest 2>/dev/null \
         | sed -n 's#.*/tag/##p')
    [ -n "$nv" ] || { print_warning "Could not resolve latest Neovim — leaving it to the Dockerfile"; nv="latest"; }
  fi

  cc="${CLAUDE_CODE_VERSION:-}"
  if [ -z "$cc" ]; then
    cc=$(npm view @anthropic-ai/claude-code version 2>/dev/null | tr -d '[:space:]')
    [ -n "$cc" ] || { print_warning "Could not resolve latest claude-code — leaving it to the Dockerfile"; cc="latest"; }
  fi

  NVIM_RESOLVED="$nv"; CLAUDE_CODE_RESOLVED="$cc"
  BUILD_ARGS=( --build-arg "NVIM_VERSION=${nv}" --build-arg "CLAUDE_CODE_VERSION=${cc}" )
  print_status "Tracking latest → Neovim ${nv}, claude-code ${cc}"
}

# ─────────────────────────────────────────────────────────────────────────────
# SSH connection multiplexer

setup_ssh_mux() {
  # Delegated to ssh_master.sh (sourced at the top) — the same helper
  # sync_configs.sh uses, so both ride ONE master on the socket path
  # ~/.ssh/config defines, and a refusal seen by either backs both off.
  #
  # Two things the old local implementation got wrong, both silent:
  #   * it hardcoded ~/.ssh/circe_mux, a socket path nothing else uses any more,
  #     so it never found the live master and always dialed its own;
  #   * on failure it blanked SSH_CONTROL_SOCKET and carried on "prompting
  #     individually" — i.e. one fresh connection per transfer, which is exactly
  #     the burst that gets this source IP firewalled. circe_ensure_master exits
  #     instead. The built tar is already on disk, so a re-run after the block
  #     clears costs nothing but the transfer.
  circe_ensure_master
}

teardown_ssh_mux() {
  # Leave the shared master alive — ControlPersist reaps it, and sync_configs.sh
  # (chained after the build) plus your own sessions reuse it for free.
  # Do NOT `ssh -O exit` it.
  :
}

# Main function
main() {
  # Start total timer
  TOTAL_START_TIME=$(date +%s)

  # Load Pushover configuration
  load_pushover_config

  echo "========================================="
  echo "FinTech Tools Container Build Script"
  echo "Started at: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "========================================="

  # Send start notification
  send_pushover_notification "🚀 Container Build Started" "FinTech Tools container build process has begun on $(hostname)"

  # Check prerequisites
  print_status "Checking prerequisites..."
  start_timer

  # Check if we're on macOS
  if [[ "$OSTYPE" != "darwin"* ]]; then
    print_warning "This script was designed and tested on macOS. You may encounter issues on other platforms."
  fi

  if ! command_exists podman; then
    print_error "Podman is not installed. Please install Podman first."
    print_status "On macOS, run: brew install podman"
    print_status "Then initialize: podman machine init && podman machine start"
    exit 1
  fi

  # Check if Podman machine is running
  if ! podman machine list | grep -q "Currently running"; then
    print_error "Podman machine is not running."
    print_status "Start it with: podman machine start"
    exit 1
  fi

  # Check if Dockerfile exists
  if [ ! -f "Dockerfile" ]; then
    print_error "Dockerfile not found in current directory!"
    exit 1
  fi

  print_status "✓ macOS environment detected"
  print_status "✓ Podman installed and running"
  print_status "✓ Dockerfile found"

  end_timer "Prerequisites check"

  # Collect ALL deployment decisions upfront, before any building, so the user
  # can answer once and walk away while the build/convert runs unattended.
  # A single SSH mux is opened later — one password prompt covers everything.
  collect_transfer_decisions

  # Step 1: Clean any existing image, then build
  print_status "Step 1: Cleaning old images and building with Podman..."
  purge_old_images

  resolve_latest_versions

  echo "Command: podman build --platform linux/amd64 -t ${IMAGE_NAME}:${VERSION} ${BUILD_ARGS[*]} ."
  start_timer

  if podman build --platform linux/amd64 -t "${IMAGE_NAME}:${VERSION}" "${BUILD_ARGS[@]}" .; then
    end_timer "Docker image build"
    print_success "✓ Built with Neovim ${NVIM_RESOLVED}, claude-code ${CLAUDE_CODE_RESOLVED}"
    send_pushover_notification "✅ Docker Build Complete" "FinTech Tools built (${IMAGE_NAME}:${VERSION}) — nvim ${NVIM_RESOLVED}, claude-code ${CLAUDE_CODE_RESOLVED}"
  else
    print_error "Failed to build Docker image"
    send_pushover_notification "❌ Build Failed" "Docker image build failed. Check logs for details."
    exit 1
  fi

  # Step 2: Export the image's flat filesystem as a rootfs tar.
  # We need a plain rootfs tar — NOT `podman save`, which is a layered image
  # archive. We make a throwaway container from the image, export its /, remove
  # it. No Singularity/apptainer, no Podman-VM toolbox — pure podman.
  print_status "Step 2: Exporting rootfs tar..."
  start_timer
  export_rootfs_tar
  end_timer "Rootfs export"

  # Post-export: remove the image and prune dangling layers so podman storage
  # returns to baseline. Only the rootfs tar is needed going forward.
  #
  # This is the ONLY place the cache is dropped, and it is reached only once the
  # rootfs tar exists. purge_old_images() deliberately leaves dangling layers
  # alone before a build so a failed attempt can resume from where it died
  # instead of restarting at apt/R/TinyTeX. Keep that pairing: prune on success
  # here, never pre-build.
  print_status "Cleaning up: removing built image to free disk space..."
  podman image rm -f "localhost/${IMAGE_NAME}:${VERSION}" 2>/dev/null && \
    print_success "✓ Built image removed" || true
  podman image prune -f >/dev/null 2>&1 && \
    print_success "✓ Intermediate build layers pruned" || true

  # Step 3: HPC deployment — one SSH mux, all transfers in a single batch
  # (decisions were already collected at startup; no interactive prompts here)
  print_status "Step 3: HPC deployment..."
  setup_ssh_mux
  start_timer
  execute_all_transfers
  teardown_ssh_mux
  end_timer "HPC transfer process"

  # One-shot: push configs + ~/.local/bin wrappers so the node is fully ready.
  # sync_configs.sh manages its own SSH mux, so it's safe after teardown above.
  if [ "${SYNC_CONFIGS:-0}" -eq 1 ]; then
    echo
    print_status "Step 4: syncing configs/scripts to CIRCE (./sync_configs.sh)..."
    if "${SCRIPT_DIR}/sync_configs.sh"; then
      print_success "✓ Configs/scripts synced to CIRCE"
    else
      print_warning "sync_configs.sh failed — run it manually: ./sync_configs.sh"
    fi
  fi

  # Calculate and display total time
  TOTAL_END_TIME=$(date +%s)
  TOTAL_ELAPSED=$((TOTAL_END_TIME - TOTAL_START_TIME))

  echo
  echo "========================================="
  print_success "BUILD PROCESS COMPLETED SUCCESSFULLY!"
  echo "========================================="
  print_status "Total build time: $(format_total_time $TOTAL_ELAPSED)"
  print_status "Finished at: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "========================================="
  echo

  # Send completion notification
  send_pushover_notification "🎉 Build Complete" "FinTech Tools container build completed successfully in $(format_total_time $TOTAL_ELAPSED)"
}

# Export the image's flat root filesystem as a tar the launcher can extract.
# `podman create` makes a container (its rootfs == the image content); `podman
# export` dumps that filesystem as a plain tar. No emulation runs, so the amd64
# binaries are exported as-is even on an arm64 Mac. The throwaway container is
# removed afterwards.
export_rootfs_tar() {
  local cid
  print_status "Creating throwaway container from ${IMAGE_NAME}:${VERSION}..."
  cid=$(podman create --platform linux/amd64 "localhost/${IMAGE_NAME}:${VERSION}" /bin/true) || {
    print_error "podman create failed"
    exit 1
  }

  print_status "Exporting container filesystem to rootfs tar..."
  echo "Command: podman export ${cid} -o ${ROOTFS_TAR}"
  if podman export "${cid}" -o "${ROOTFS_TAR}"; then
    print_status "Rootfs tar size: $(du -h "${ROOTFS_TAR}" | cut -f1)"
    print_success "✓ Rootfs tar created: ${ROOTFS_TAR}"
    podman rm -f "${cid}" >/dev/null 2>&1 || true
  else
    print_error "podman export failed"
    podman rm -f "${cid}" >/dev/null 2>&1 || true
    exit 1
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 1 — Gather rootfs-tar deployment decision BEFORE touching SSH.
# Called at startup so the user answers once and the build runs unattended.
# Config/script syncing lives in sync_configs.sh (separate lightweight script).
# ─────────────────────────────────────────────────────────────────────────────
collect_transfer_decisions() {
  echo
  echo "============================================================"
  print_status "Deployment decision — answer now, then build runs unattended"
  print_status "Rootfs-tar transfer will reuse ONE SSH connection after the build"
  echo "============================================================"
  echo

  # Non-interactive mode (-y). The reads below are bound to /dev/tty so that a
  # backgrounded or piped build cannot answer them; -y is the supported way to
  # run unattended. Defaults to doing BOTH deployment steps, which is the whole
  # point of the one-shot workflow; --no-transfer / --no-sync opt out.
  if [ "${ASSUME_YES:-0}" -eq 1 ]; then
    XFER_ROOTFS="${ASSUME_XFER:-1}"
    SYNC_CONFIGS="${ASSUME_SYNC:-1}"
    print_status "Non-interactive (-y): transfer=${XFER_ROOTFS} sync_configs=${SYNC_CONFIGS}"
    echo "============================================================"
    return 0
  fi

  # ── rootfs tar ───────────────────────────────────────────────────────────────
  XFER_ROOTFS=0
  read -r -p "Transfer rootfs tar to CIRCE ${REMOTE_ROOTFS_PATH} after build? (y/N): " _r </dev/tty; echo
  [[ $_r =~ ^[Yy]$ ]] && XFER_ROOTFS=1

  # ── configs/scripts (sync_configs.sh) ────────────────────────────────────────
  # Default YES: this is what makes the build a true one-shot. The rootfs tar
  # carries the image (incl. the bookokrat binary on the fast node-local rootfs);
  # sync_configs.sh pushes the configs + ~/.local/bin wrappers. Together the node
  # is fully ready in one run — no manual steps, and no heavy binaries dumped onto
  # the at-quota FUSE home.
  SYNC_CONFIGS=1
  read -r -p "Also sync configs/scripts (./sync_configs.sh) after build? (Y/n): " _s </dev/tty; echo
  [[ $_s =~ ^[Nn]$ ]] && SYNC_CONFIGS=0

  echo "============================================================"
  if [ "${XFER_ROOTFS:-0}" -eq 1 ]; then
    print_status "Will deploy after build: rootfs tar → CIRCE ${REMOTE_ROOTFS_PATH}"
  else
    print_status "No rootfs-tar transfer selected"
  fi
  if [ "${SYNC_CONFIGS:-0}" -eq 1 ]; then
    print_status "Will also run ./sync_configs.sh after build (configs + wrappers)"
  else
    print_status "Config/script sync skipped — run ./sync_configs.sh manually if needed"
  fi
  echo "============================================================"
  echo
}

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 2 — Execute rootfs-tar transfer using a single SSH mux.
# Config/script syncing lives in sync_configs.sh (separate lightweight script).
# ─────────────────────────────────────────────────────────────────────────────
execute_all_transfers() {
  # No ControlPath override — ${REMOTE_HOST} is the ~/.ssh/config alias, which
  # already carries ControlMaster/ControlPath, so ssh and scp ride the master
  # opened by setup_ssh_mux as channels. Hardcoding a second socket path here is
  # how this script drifted off the shared master.
  local -a MUX=()

  if [ "${XFER_ROOTFS:-0}" -eq 0 ]; then
    print_status "Rootfs-tar transfer skipped. Run ./sync_configs.sh to push configs."
    return 0
  fi

  # ── Remote: rootfs tar (large file — dedicated scp, same mux) ────────────────
  if [ ! -f "$ROOTFS_TAR" ]; then
    print_warning "Rootfs tar ${ROOTFS_TAR} not found — skipping"
    return 0
  fi

  echo
  print_status "Transferring rootfs tar to ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_ROOTFS_PATH}..."
  send_pushover_notification "🔐 Transfer Starting" "Beginning rootfs-tar transfer to CIRCE."
  echo "Command: scp ${ROOTFS_TAR} ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_ROOTFS_PATH}"
  local _ts _te _tt
  _ts=$(date +%s)
  ssh "${MUX[@]}" "${REMOTE_USER}@${REMOTE_HOST}" "mkdir -p ${REMOTE_ROOTFS_DIR}" 2>/dev/null
  if scp "${MUX[@]}" "${ROOTFS_TAR}" "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_ROOTFS_PATH}"; then
    _te=$(date +%s); _tt=$((_te - _ts))
    print_success "✓ Rootfs tar transferred to CIRCE in ${_tt}s"
    send_pushover_notification "✅ Transfer Complete" "Rootfs tar transferred to CIRCE in ${_tt}s."
    print_status "On a fresh node the container is unpacked automatically; the launcher"
    print_status "auto-refreshes when this tar is newer than the unpacked copy (no manual"
    print_status "step). To force it on a busy node: rm -rf /tmp/\$USER/.udocker"
    # Offer to remove the local tar — it's large (~10 GB) and no longer needed
    # after a successful transfer. The next build overwrites it anyway.
    local _tar_size
    _tar_size=$(du -sh "${ROOTFS_TAR}" 2>/dev/null | cut -f1)
    read -r -p "Delete local rootfs tar ${ROOTFS_TAR} (${_tar_size}) to free space? (y/N): " _del </dev/tty; echo
    if [[ $_del =~ ^[Yy]$ ]]; then
      rm -f "${ROOTFS_TAR}" && print_success "✓ Local rootfs tar deleted" || print_warning "Could not delete ${ROOTFS_TAR}"
    else
      print_status "Local rootfs tar kept at ${ROOTFS_TAR}"
    fi
  else
    print_error "Failed to transfer rootfs tar to CIRCE"
    send_pushover_notification "❌ Transfer Failed" "Rootfs-tar transfer failed. Manual: scp ${ROOTFS_TAR} ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_ROOTFS_PATH}"
    print_status "Manual transfer: scp ${ROOTFS_TAR} ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_ROOTFS_PATH}"
  fi
}

# Show usage
usage() {
  echo "Usage: $0 [OPTIONS]"
  echo
  echo "Workflow (one-shot — leaves the node fully ready):"
  echo "  1. Build Docker image with Podman (cleans old images first)"
  echo "  2. Export flat rootfs tar with 'podman export' (incl. the bookokrat binary)"
  echo "  3. Remove built image + prune dangling layers (disk cleanup)"
  echo "  4. Transfer rootfs tar to CIRCE ${REMOTE_ROOTFS_PATH} (optional)"
  echo "  5. Run ./sync_configs.sh — push configs + ~/.local/bin wrappers (optional, default yes)"
  echo
  echo "To sync configs/scripts to CIRCE WITHOUT rebuilding, run on its own:"
  echo "  ./sync_configs.sh"
  echo
  echo "Options:"
  echo "  -h, --help     Show this help message"
  echo "  -v, --version  Set version tag (default: ${VERSION})"
  echo "  -y, --yes      Non-interactive: transfer the rootfs tar AND sync configs"
  echo "                 (the prompts read from /dev/tty, so they cannot be piped;"
  echo "                  use this to run the whole thing unattended)"
  echo "      --no-transfer  With -y: build and export only, skip the CIRCE transfer"
  echo "      --no-sync      With -y: skip ./sync_configs.sh at the end"
  echo
  echo "System Requirements:"
  echo "  - macOS with Podman installed and running (no apptainer/toolbox needed)"
  echo
  echo "Setup Instructions:"
  echo "  brew install podman"
  echo "  podman machine init && podman machine start"
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  case $1 in
  -h | --help)
    usage
    exit 0
    ;;
  -v | --version)
    VERSION="$2"
    shift 2
    ;;
  -y | --yes)
    ASSUME_YES=1
    shift
    ;;
  --no-transfer)
    ASSUME_YES=1
    ASSUME_XFER=0
    shift
    ;;
  --no-sync)
    ASSUME_YES=1
    ASSUME_SYNC=0
    shift
    ;;
  *)
    print_error "Unknown option: $1"
    usage
    exit 1
    ;;
  esac
done

# Run main function
main
