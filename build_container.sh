#!/bin/bash

# FinTech Tools Container Build Script
# Build (Podman) -> export flat rootfs tar (podman export) -> scp to CIRCE.

set -e # Exit on any error

# Configuration
IMAGE_NAME="fintech-tools"
VERSION="0.8"
# Flat rootfs tar produced by `podman export` — deployed to CIRCE.
ROOTFS_TAR="$HOME/fintech-rootfs.tar"
REMOTE_USER="gson"
REMOTE_HOST="circe.rc.usf.edu"
# Rootfs tar destination on CIRCE.
# /work is persistent and is the only large FS mounted on compute nodes.
REMOTE_ROOTFS_DIR="/work/g/${REMOTE_USER}/proot-sb"
REMOTE_ROOTFS_PATH="${REMOTE_ROOTFS_DIR}/fintech-rootfs.tar"

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
  local dangling
  dangling=$(podman images -f dangling=true -q 2>/dev/null)
  if [ -n "$dangling" ]; then
    print_status "Pruning dangling intermediate layers..."
    podman image prune -f >/dev/null 2>&1 && \
      print_success "✓ Dangling layers pruned" || true
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# SSH connection multiplexer

setup_ssh_mux() {
  SSH_CONTROL_SOCKET="$(mktemp -u /tmp/circe_mux_XXXXXX)"
  print_status "Opening SSH connection to ${REMOTE_HOST} (enter password once for all transfers)..."
  if ssh -fNM \
    -o ControlMaster=yes \
    -o ControlPath="${SSH_CONTROL_SOCKET}" \
    -o ControlPersist=30m \
    "${REMOTE_USER}@${REMOTE_HOST}"; then
    print_success "✓ SSH connection established (multiplexed)"
  else
    print_warning "SSH multiplexing unavailable — transfers will prompt individually"
    SSH_CONTROL_SOCKET=""
  fi
}

teardown_ssh_mux() {
  [ -z "$SSH_CONTROL_SOCKET" ] && return
  ssh -O exit -o ControlPath="${SSH_CONTROL_SOCKET}" "${REMOTE_USER}@${REMOTE_HOST}" 2>/dev/null || true
  rm -f "${SSH_CONTROL_SOCKET}"
  SSH_CONTROL_SOCKET=""
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

  echo "Command: podman build --platform linux/amd64 -t ${IMAGE_NAME}:${VERSION} ."
  start_timer

  if podman build --platform linux/amd64 -t "${IMAGE_NAME}:${VERSION}" .; then
    end_timer "Docker image build"
    send_pushover_notification "✅ Docker Build Complete" "FinTech Tools Docker image built successfully (${IMAGE_NAME}:${VERSION})"
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

  # ── rootfs tar ───────────────────────────────────────────────────────────────
  XFER_ROOTFS=0
  read -r -p "Transfer rootfs tar to CIRCE ${REMOTE_ROOTFS_PATH} after build? (y/N): " _r </dev/tty; echo
  [[ $_r =~ ^[Yy]$ ]] && XFER_ROOTFS=1

  echo "============================================================"
  if [ "${XFER_ROOTFS:-0}" -eq 1 ]; then
    print_status "Will deploy after build: rootfs tar → CIRCE ${REMOTE_ROOTFS_PATH}"
  else
    print_status "No deployment selected — rootfs-tar transfer will be skipped"
  fi
  print_status "To sync configs/scripts separately, run: ./sync_configs.sh"
  echo "============================================================"
  echo
}

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 2 — Execute rootfs-tar transfer using a single SSH mux.
# Config/script syncing lives in sync_configs.sh (separate lightweight script).
# ─────────────────────────────────────────────────────────────────────────────
execute_all_transfers() {
  local -a MUX=()
  [ -n "$SSH_CONTROL_SOCKET" ] && MUX=(-o ControlMaster=auto -o ControlPath="${SSH_CONTROL_SOCKET}")

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
    print_status "On a fresh node it extracts automatically; to refresh an already-extracted"
    print_status "node, clear its sandbox: rm -rf /tmp/\$USER/fintech-sbx"
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
  echo "Workflow:"
  echo "  1. Build Docker image with Podman (cleans old images first)"
  echo "  2. Export flat rootfs tar with 'podman export'"
  echo "  3. Remove built image + prune dangling layers (disk cleanup)"
  echo "  4. Transfer rootfs tar to CIRCE ${REMOTE_ROOTFS_PATH} (optional)"
  echo
  echo "To sync configs/scripts to CIRCE without rebuilding, use:"
  echo "  ./sync_configs.sh"
  echo
  echo "Options:"
  echo "  -h, --help     Show this help message"
  echo "  -v, --version  Set version tag (default: ${VERSION})"
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
  *)
    print_error "Unknown option: $1"
    usage
    exit 1
    ;;
  esac
done

# Run main function
main
