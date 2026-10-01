#!/bin/bash

# FinTech Tools — Config Sync Script
# Syncs configs, scripts, and dotfiles to CIRCE in one shot — no prompts.
# For building + deploying the container itself, use build_container.sh.

set -e

REMOTE_USER="gson"
# Address the login node by its ~/.ssh/config ALIAS, never by hostname — the
# alias is what supplies circe_key, the shared ControlPath and the keepalives.
# See ssh_master.sh for the full reasoning (raw hostname = no key = password
# fallback = failed auths on a key-only account).
REMOTE_HOST="circe"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Shared login-node connection budget: one master per run, on the socket path
# ~/.ssh/config defines, with a 15-minute backoff after a refusal that is shared
# with connect_nvim.sh and build_container.sh.
. "${SCRIPT_DIR}/ssh_master.sh"

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
# SSH mux — provided by ssh_master.sh (sourced above). circe_ensure_master()
# reuses a live master, clears a stale socket before dialing, opens exactly one
# connection, and refuses to redial for 15 min after the login node blocks us.
# ─────────────────────────────────────────────────────────────────────────────
ensure_ssh_mux() { circe_ensure_master; }

# ssh/rsync wrapper. No -o ControlPath override: the alias already carries it
# from ~/.ssh/config, and hardcoding a second copy is how the scripts drifted
# onto different sockets (each one then its own login) in the first place.
SSH_CMD="ssh"

remote_ssh() { $SSH_CMD "${REMOTE_HOST}" "$@"; }

# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────
echo "========================================="
echo "FinTech Tools — Config Sync"
echo "Started at: $(date '+%Y-%m-%d %H:%M:%S')"
echo "========================================="
echo

# ── Discover what exists ──────────────────────────────────────────────────────
# avante.nvim and github-copilot were dropped 2026-10-01 along with the plugins
# themselves. Copies already on CIRCE are not deleted by a sync (no --delete).
CONFIG_LIST=(bottom nvim yazi tmux bookokrat starship git)
CONFIGS_DIR="${SCRIPT_DIR}/configs"

# LazyVim extras to DROP from the container's nvim config only. The nvim sync is
# an overlay of your Mac's ~/.config/nvim, so any extra you enable locally (in
# lazyvim.json) is otherwise pushed to CIRCE verbatim. Some make no sense on the
# remote: e.g. the `rust` extra pulls in rustaceanvim + crates.nvim, which you
# don't use there and which then fail to resolve ("Too many rounds of missing
# plugins") and block the LazyVim dashboard. Listed extras are stripped from the
# STAGED copy below — your Mac config keeps them. Match is a substring of the
# extra's module path. Add more here as needed.
CONTAINER_NVIM_EXCLUDE_EXTRAS=(lang.rust)

HAVE_ZSHRC=0;    [ -f "${SCRIPT_DIR}/.zshrc" ]              && HAVE_ZSHRC=1
HAVE_IGNORE=0;   [ -f "${SCRIPT_DIR}/.ignore" ]             && HAVE_IGNORE=1
HAVE_TERM=0;     [ -f "${SCRIPT_DIR}/term_session.sh" ]     && HAVE_TERM=1
HAVE_UDOCKER=0;  [ -f "${SCRIPT_DIR}/udocker_dev.sh" ]      && HAVE_UDOCKER=1
HAVE_CLAUDEMD=0; [ -f "${SCRIPT_DIR}/configs/claude/CLAUDE.md" ] && HAVE_CLAUDEMD=1
HAVE_CONNECT=0;  [ -f "${SCRIPT_DIR}/connect_nvim.sh" ]     && HAVE_CONNECT=1
# bookokrat helper scripts. Source the LIVE Mac copies (where they're edited and
# used) so changes sync without a manual repo update; fall back to the repo-root
# snapshot. Each row is  LIVE-PATH-UNDER-~ | REPO-ROOT-SNAPSHOT | DEST-UNDER-~ .
# The repo name is flat even where the destination is nested, so the repo root
# stays flat — hence the explicit third column.
#
# Because the LIVE copy wins, an edit made in this repo alone is thrown away by
# the next sync. These files are shared between the Mac and the container, so a
# change has to be written to BOTH ~/.local/... and the snapshot here.
#
# Rows 1-3 are the synctex/opener wrappers (VimTeX forward+inverse search, yazi's
# PDF opener). Row 4 is the fix for bookokrat#179 — under Ghostty the reader
# draws its page as a classic Kitty placement that tmux holds no cell for, so
# switching windows leaves the page painted over the window you moved to;
# tmux-kitty-image-gc deletes it from outside tmux and repaints any reader still
# on screen. configs/tmux/tmux.conf's window-change hooks call it, and
# bookokrat-split appends it to the reader's own command line for the exit case.
# Row 5 is not a bookokrat helper but follows the same live-first rule:
# tmux-resurrect-age prints the age of the last prefix Ctrl-s save for the
# status-bar pill built by configs/tmux/modules/resurrect.conf.
#
# NOT deployed any more: `.local/bin/override/bookokrat` and its
# `.local/libexec/bookokrat-kitty-shim/tmux`. That pair forced bookokrat's
# Unicode-placeholder anchor path on by answering its terminal probe with
# "kitty". The anchor path places the page RELATIVE to a tmux-owned cell (Kitty
# keys P=/Q=), which Ghostty 1.3.1 does not implement — it drops P/Q and paints
# the page wherever the cursor sits, i.e. on top of yazi, with the reader's pane
# left empty. Retired on the Mac 2026-09-04 and removed from here with it; do not
# reintroduce either file.
BOOKOKRAT_FILES=(
  ".local/bin/bookokrat-split|bookokrat-split|.local/bin/bookokrat-split"
  ".local/bin/bookokrat-forward|bookokrat-forward|.local/bin/bookokrat-forward"
  ".local/bin/bookokrat-inverse|bookokrat-inverse|.local/bin/bookokrat-inverse"
  ".local/bin/tmux-kitty-image-gc|tmux-kitty-image-gc|.local/bin/tmux-kitty-image-gc"
  ".local/bin/tmux-resurrect-age|tmux-resurrect-age|.local/bin/tmux-resurrect-age"
)
HAVE_BOOKOKRAT_SCRIPTS=1
for _row in "${BOOKOKRAT_FILES[@]}"; do
  IFS='|' read -r _live _repo _ <<<"$_row"
  [ -f "$HOME/${_live}" ] || [ -f "${SCRIPT_DIR}/${_repo}" ] || HAVE_BOOKOKRAT_SCRIPTS=0
done

print_status "Will deploy:"
echo "  • ~/.config/{$(IFS=,; echo "${CONFIG_LIST[*]}")} → CIRCE"
[ "$HAVE_ZSHRC"    -eq 1 ] && echo "  • .zshrc → CIRCE ~/"
[ "$HAVE_IGNORE"   -eq 1 ] && echo "  • .ignore → CIRCE ~/  (fd/ripgrep excludes)"
[ "$HAVE_TERM"     -eq 1 ] && echo "  • term_session.sh → CIRCE ~/sh/"
[ "$HAVE_UDOCKER"  -eq 1 ] && echo "  • udocker_dev.sh → CIRCE ~/bin/  (udocker/F3 launcher)"
[ "$HAVE_CLAUDEMD" -eq 1 ] && echo "  • configs/claude/CLAUDE.md → CIRCE ~/.claude/CLAUDE.md  (container notes for Claude)"
[ "$HAVE_BOOKOKRAT_SCRIPTS" -eq 1 ] && echo "  • bookokrat helpers → CIRCE ~/.local/bin/  (${#BOOKOKRAT_FILES[@]} files)"
[ "$HAVE_CONNECT"  -eq 1 ] && echo "  • connect_nvim.sh → ~/  (local)"
echo

# ── Local installs (no SSH needed) ───────────────────────────────────────────
if [ "$HAVE_CONNECT" -eq 1 ]; then
  # This cp is a ONE-WAY install (repo → ~), so a fix made live in
  # ~/connect_nvim.sh and not ported back here is silently reverted by the next
  # sync. That nearly ate the 2026-07-28 connection-budget patch (ensure_master).
  # Refuse to overwrite a home copy that is newer AND different; the fix belongs
  # in the repo, where it also gets committed.
  if [ -f "$HOME/connect_nvim.sh" ] \
     && ! cmp -s "${SCRIPT_DIR}/connect_nvim.sh" "$HOME/connect_nvim.sh" \
     && [ "$HOME/connect_nvim.sh" -nt "${SCRIPT_DIR}/connect_nvim.sh" ]; then
    print_warning "~/connect_nvim.sh is NEWER than the repo copy and differs — not overwriting."
    print_warning "  Port the live edits into ${SCRIPT_DIR}/connect_nvim.sh, then re-run:"
    print_warning "    cp ~/connect_nvim.sh '${SCRIPT_DIR}/connect_nvim.sh'"
    print_warning "  (diff: diff -u '${SCRIPT_DIR}/connect_nvim.sh' ~/connect_nvim.sh)"
  else
    cp "${SCRIPT_DIR}/connect_nvim.sh" "$HOME/connect_nvim.sh" && chmod +x "$HOME/connect_nvim.sh"
    print_success "✓ connect_nvim.sh → ~/connect_nvim.sh"
  fi
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
    # repo owns the container-only git config (container.gitconfig). rsync has no
    # --delete, so an existing ~/.config/git/config on CIRCE is left alone — and
    # git never auto-reads container.gitconfig anyway (only GIT_CONFIG_GLOBAL,
    # set by udocker_dev.sh, points at it).
    git) _is_replace=1 ;;
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
# ── Strip container-excluded LazyVim extras from the staged nvim config ───────
# Edits only the STAGING copy, so your Mac's lazyvim.json is left intact. Also
# drops the matching plugins from the staged lazy-lock.json so a remote
# `:Lazy restore` doesn't try to reinstall them. No-op if jq/python3 are absent
# or the file isn't staged.
_LZ_JSON="$STAGING/.config/nvim/lazyvim.json"
if [ -f "$_LZ_JSON" ] && [ ${#CONTAINER_NVIM_EXCLUDE_EXTRAS[@]} -gt 0 ]; then
  if command -v python3 >/dev/null 2>&1; then
    EXCLUDES="${CONTAINER_NVIM_EXCLUDE_EXTRAS[*]}" \
    python3 - "$_LZ_JSON" "$STAGING/.config/nvim/lazy-lock.json" <<'PY'
import json, os, sys
lv, lock = sys.argv[1], sys.argv[2]
pats = os.environ.get("EXCLUDES", "").split()
# map known extras -> the plugins they introduce, so we can also prune the lock
extra_plugins = {"lang.rust": ["rustaceanvim", "crates.nvim"]}
try:
    d = json.load(open(lv))
except Exception:
    sys.exit(0)
keep, dropped = [], []
for e in d.get("extras", []):
    (dropped if any(p in e for p in pats) else keep).append(e)
if dropped:
    d["extras"] = keep
    json.dump(d, open(lv, "w"), indent=2)
    print("  nvim: dropped extras -> " + ", ".join(dropped))
    plugs = {pl for e in dropped for k, v in extra_plugins.items() if k in e for pl in v}
    if plugs and os.path.exists(lock):
        try:
            L = json.load(open(lock))
            for pl in plugs:
                L.pop(pl, None)
            json.dump(L, open(lock, "w"), indent=2)
            print("  nvim: pruned lazy-lock -> " + ", ".join(sorted(plugs)))
        except Exception:
            pass
PY
  else
    print_warning "  nvim: python3 not found — cannot strip excluded extras (${CONTAINER_NVIM_EXCLUDE_EXTRAS[*]})"
  fi
fi

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

# Container operating notes for Claude Code. ~/.claude/CLAUDE.md is user-level
# memory, so it loads in EVERY in-container session regardless of which project
# directory Claude is started in — which is what makes the /tmp-reaper family
# recognisable from inside a random analysis dir rather than only in this repo.
if [ "$HAVE_CLAUDEMD" -eq 1 ]; then
  # Don't silently eat a hand-written remote CLAUDE.md: ours carries a marker
  # line, so anything without it predates this sync and gets set aside once.
  if remote_ssh "[ -f ~/.claude/CLAUDE.md ] && ! grep -q 'synced from the .05_Container. repo' ~/.claude/CLAUDE.md" 2>/dev/null; then
    remote_ssh "cp ~/.claude/CLAUDE.md ~/.claude/CLAUDE.md.pre-sync.bak" 2>/dev/null
    print_warning "  CIRCE ~/.claude/CLAUDE.md was hand-written — saved as CLAUDE.md.pre-sync.bak"
    print_warning "  Fold anything worth keeping into ${SCRIPT_DIR}/configs/claude/CLAUDE.md"
  fi
  mkdir -p "$STAGING/.claude"
  cp "${SCRIPT_DIR}/configs/claude/CLAUDE.md" "$STAGING/.claude/CLAUDE.md"
  _staged+=(".claude/CLAUDE.md")
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
  for _row in "${BOOKOKRAT_FILES[@]}"; do
    IFS='|' read -r _live _repo _dest <<<"$_row"
    _src="$HOME/${_live}"; [ -f "$_src" ] || _src="${SCRIPT_DIR}/${_repo}"  # prefer live
    mkdir -p "$STAGING/$(dirname "${_dest}")"
    cp "$_src" "$STAGING/${_dest}"
    chmod +x "$STAGING/${_dest}"
    _staged+=("${_dest}")
  done
fi

# Pre-create remote dirs
remote_ssh "mkdir -p ~/.config ~/sh ~/bin ~/.local/bin ~/.claude" 2>/dev/null

# ONE rsync call for all remote files
echo
print_status "Syncing to CIRCE: ${_staged[*]}"
if rsync -avz -e "$SSH_CMD" "$STAGING/" "${REMOTE_HOST}:~/"; then
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
