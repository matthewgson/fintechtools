#!/bin/bash

# FinTech Tools — Config Sync Script
# Syncs configs, scripts, and dotfiles to CIRCE in one shot — no prompts.
# For building + deploying the container itself, use build_container.sh.

set -e

REMOTE_USER="gson"
REMOTE_HOST="circe.rc.usf.edu"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Fixed persistent socket path — reused across invocations so you only enter
# your password once per ControlPersist window (2 hours).
SSH_SOCKET="$HOME/.ssh/circe_mux"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_status()  { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

# ─────────────────────────────────────────────────────────────────────────────
# SSH mux — fixed socket so the master persists between script runs.
# First call: prompts for password and opens master (ControlPersist=2h).
# Subsequent calls within 2h: reuses existing master, zero prompts.
# ─────────────────────────────────────────────────────────────────────────────
ensure_ssh_mux() {
  mkdir -p "$(dirname "$SSH_SOCKET")"
  # Check if an existing master is still alive
  if ssh -O check -o ControlPath="$SSH_SOCKET" "${REMOTE_USER}@${REMOTE_HOST}" 2>/dev/null; then
    print_status "✓ Reusing existing SSH connection to ${REMOTE_HOST}"
    return 0
  fi
  print_status "Opening SSH connection to ${REMOTE_HOST} (one-time password prompt, valid 2h)..."
  ssh -fNM \
    -o ControlMaster=yes \
    -o ControlPath="$SSH_SOCKET" \
    -o ControlPersist=2h \
    -o ServerAliveInterval=60 \
    -o ServerAliveCountMax=3 \
    "${REMOTE_USER}@${REMOTE_HOST}"
  print_success "✓ SSH master connection established"
}

# Consistent ssh/rsync wrapper — always routes through the mux socket
SSH_CMD="ssh -o ControlMaster=auto -o ControlPath=${SSH_SOCKET}"

remote_ssh() { $SSH_CMD "${REMOTE_USER}@${REMOTE_HOST}" "$@"; }

# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────
echo "========================================="
echo "FinTech Tools — Config Sync"
echo "Started at: $(date '+%Y-%m-%d %H:%M:%S')"
echo "========================================="
echo

# ── Discover what exists ──────────────────────────────────────────────────────
CONFIG_LIST=(avante.nvim github-copilot btm nvim yazi tmux bookokrat starship)
CONFIGS_DIR="${SCRIPT_DIR}/configs"

HAVE_ZSHRC=0;    [ -f "${SCRIPT_DIR}/.zshrc" ]              && HAVE_ZSHRC=1
HAVE_IGNORE=0;   [ -f "${SCRIPT_DIR}/.ignore" ]             && HAVE_IGNORE=1
HAVE_TERM=0;     [ -f "${SCRIPT_DIR}/term_session.sh" ]     && HAVE_TERM=1
HAVE_PROOT=0;    [ -f "${SCRIPT_DIR}/proot_dev.sh" ]        && HAVE_PROOT=1
HAVE_UDOCKER=0;  [ -f "${SCRIPT_DIR}/udocker_dev.sh" ]      && HAVE_UDOCKER=1
HAVE_CONNECT=0;  [ -f "${SCRIPT_DIR}/connect_nvim.sh" ]     && HAVE_CONNECT=1
# bookokrat synctex wrappers → ~/.local/bin (on PATH inside the container).
# Source the LIVE copies from ~/.local/bin (where they're edited and used) so
# changes sync without a manual repo update; fall back to the repo-root snapshot.
BOOKOKRAT_SCRIPTS=(bookokrat-split bookokrat-forward bookokrat-inverse)
HAVE_BOOKOKRAT_SCRIPTS=1
for _s in "${BOOKOKRAT_SCRIPTS[@]}"; do
  [ -f "$HOME/.local/bin/${_s}" ] || [ -f "${SCRIPT_DIR}/${_s}" ] || HAVE_BOOKOKRAT_SCRIPTS=0
done

print_status "Will deploy:"
echo "  • ~/.config/{$(IFS=,; echo "${CONFIG_LIST[*]}")} → CIRCE"
[ "$HAVE_ZSHRC"    -eq 1 ] && echo "  • .zshrc → CIRCE ~/"
[ "$HAVE_IGNORE"   -eq 1 ] && echo "  • .ignore → CIRCE ~/  (fd/ripgrep excludes)"
[ "$HAVE_TERM"     -eq 1 ] && echo "  • term_session.sh → CIRCE ~/sh/"
[ "$HAVE_PROOT"    -eq 1 ] && echo "  • proot_dev.sh → CIRCE ~/bin/"
[ "$HAVE_UDOCKER"  -eq 1 ] && echo "  • udocker_dev.sh → CIRCE ~/bin/  (udocker/F3 launcher)"
[ "$HAVE_BOOKOKRAT_SCRIPTS" -eq 1 ] && echo "  • bookokrat-{split,forward,inverse} → CIRCE ~/.local/bin/"
[ "$HAVE_CONNECT"  -eq 1 ] && echo "  • connect_nvim.sh → ~/  (local)"
echo

# ── Local installs (no SSH needed) ───────────────────────────────────────────
if [ "$HAVE_CONNECT" -eq 1 ]; then
  cp "${SCRIPT_DIR}/connect_nvim.sh" "$HOME/connect_nvim.sh" && chmod +x "$HOME/connect_nvim.sh"
  print_success "✓ connect_nvim.sh → ~/connect_nvim.sh"
fi

# ── Open (or reuse) SSH master ────────────────────────────────────────────────
ensure_ssh_mux

# ── Stage everything, then push in ONE rsync call ─────────────────────────────
STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT

mkdir -p "$STAGING/.config"
_staged=()
_ok_cfg=()

for cfg in "${CONFIG_LIST[@]}"; do
  # Per-cfg sync policy:
  #   replace: repo's configs/<cfg>/ fully replaces Mac's ~/.config/<cfg>/
  #            (yazi — container-specific openers, e.g. bookokrat for PDFs).
  #   overlay: Mac's copy is staged first, repo's configs/<cfg>/* layered on top
  #            (nvim — adds repo plugins without touching user's other plugins).
  #   default: Mac's ~/.config/<cfg> is source of truth.
  _is_replace=0; _is_overlay=0
  case "$cfg" in
    yazi) _is_replace=1 ;;
    tmux) _is_replace=1 ;;   # repo owns the container tmux.conf (no Mac copy)
    bookokrat) _is_replace=1 ;;   # repo owns the container bookokrat config
    starship) _is_replace=1 ;;   # repo owns the container prompt (warm SSH theme; Mac keeps its own)
    nvim) _is_overlay=1 ;;
  esac

  src=""
  if [ "$_is_replace" -eq 1 ] && [ -d "${CONFIGS_DIR}/$cfg" ]; then
    src="${CONFIGS_DIR}/$cfg"
    print_status "  ${cfg}: repo configs/${cfg}/ (replaces Mac copy)"
  elif [ -e "$HOME/.config/$cfg" ]; then
    src="$HOME/.config/$cfg"
  fi

  if [ -n "$src" ]; then
    cp -r "$src" "$STAGING/.config/"
    if [ "$_is_overlay" -eq 1 ] && [ -d "${CONFIGS_DIR}/$cfg" ]; then
      rsync -a "${CONFIGS_DIR}/$cfg/" "$STAGING/.config/$cfg/"
      print_status "  ${cfg}: overlaid repo configs/${cfg}/* on Mac copy"
    fi
    _ok_cfg+=("$cfg")
  else
    print_warning "  Skipping missing: ~/.config/$cfg"
  fi
done
[ ${#_ok_cfg[@]} -gt 0 ] && _staged+=("~/.config/{$(IFS=,; echo "${_ok_cfg[*]}")}")

if [ "$HAVE_ZSHRC" -eq 1 ]; then
  cp "${SCRIPT_DIR}/.zshrc" "$STAGING/.zshrc"
  _staged+=(".zshrc")
fi

if [ "$HAVE_IGNORE" -eq 1 ]; then
  cp "${SCRIPT_DIR}/.ignore" "$STAGING/.ignore"
  _staged+=(".ignore")
fi

if [ "$HAVE_TERM" -eq 1 ]; then
  mkdir -p "$STAGING/sh"
  cp "${SCRIPT_DIR}/term_session.sh" "$STAGING/sh/term_session.sh"
  _staged+=("sh/term_session.sh")
fi

if [ "$HAVE_PROOT" -eq 1 ]; then
  mkdir -p "$STAGING/bin"
  cp "${SCRIPT_DIR}/proot_dev.sh" "$STAGING/bin/proot_dev.sh"
  # term_session.sh and connect_nvim.sh exec ~/bin/proot_dev.sh and require it to
  # be executable (term_session.sh hard-fails on a non-exec launcher). The repo
  # copy isn't +x, so set it here before the perm-preserving rsync -a.
  chmod +x "$STAGING/bin/proot_dev.sh"
  _staged+=("bin/proot_dev.sh")
fi

if [ "$HAVE_UDOCKER" -eq 1 ]; then
  mkdir -p "$STAGING/bin"
  cp "${SCRIPT_DIR}/udocker_dev.sh" "$STAGING/bin/udocker_dev.sh"
  # term_session.sh / connect_nvim.sh exec ~/bin/udocker_dev.sh and require +x;
  # the repo copy isn't executable, so set it before the perm-preserving rsync -a.
  chmod +x "$STAGING/bin/udocker_dev.sh"
  _staged+=("bin/udocker_dev.sh")
fi

if [ "$HAVE_BOOKOKRAT_SCRIPTS" -eq 1 ]; then
  mkdir -p "$STAGING/.local/bin"
  for _s in "${BOOKOKRAT_SCRIPTS[@]}"; do
    _src="$HOME/.local/bin/${_s}"; [ -f "$_src" ] || _src="${SCRIPT_DIR}/${_s}"  # prefer live
    cp "$_src" "$STAGING/.local/bin/${_s}"
    chmod +x "$STAGING/.local/bin/${_s}"
    _staged+=(".local/bin/${_s}")
  done
fi

# Pre-create remote dirs
remote_ssh "mkdir -p ~/.config ~/sh ~/bin ~/.local/bin" 2>/dev/null

# ONE rsync call for all remote files
echo
print_status "Syncing to CIRCE: ${_staged[*]}"
if rsync -avz -e "$SSH_CMD" "$STAGING/" "${REMOTE_USER}@${REMOTE_HOST}:~/"; then
  print_success "✓ All files synced to CIRCE"
  print_status "Tip — run once inside the container on CIRCE to set up starship:"
  echo "    starship preset nerd-font-symbols -o ~/.config/starship.toml"
else
  print_error "Batch sync to CIRCE failed"
  exit 1
fi

echo
echo "========================================="
print_success "Config sync complete."
echo "Finished at: $(date '+%Y-%m-%d %H:%M:%S')"
echo "SSH master stays open for 2h — next run won't prompt for password."
echo "========================================="
