#!/bin/bash
#
# connect_nvim.sh — Mac-side script to reconnect to a running nvim_session on CIRCE.
#
# Usage:
#   ./connect_nvim.sh              # auto-find job and connect (no X11)
#   ./connect_nvim.sh <node>       # connect directly to a known node
#   WITH_X11=1 ./connect_nvim.sh   # also launch XQuartz + ssh -Y for VimTeX \lv
#
# Drops into an interactive zsh inside the container (launched via proot).
# Start zellij/nvim manually from there if you want a persistent layout:
#   zellij attach nvim 2>/dev/null || zellij --session nvim
#
# Requires:
#   ~/.ssh/config entry for Host circe with IdentityFile ~/.ssh/circe_key
#   nvim_session running on CIRCE via sbatch

# SSH config alias for CIRCE login node (must match Host entry in ~/.ssh/config)
LOGIN_ALIAS="circe"
REMOTE_USER="gson"
# Target compute node — matches #SBATCH --nodelist in term_session.sh
TARGET_NODE="mdc-1057-13-13"

# ─── Find compute node ────────────────────────────────────────────────────────
if [ -n "$1" ]; then
    NODE="$1"
    echo "Using provided node: $NODE"
else
    NODE="$TARGET_NODE"
    echo "Checking for any running job on $NODE..."
    FOUND=$(ssh -o BatchMode=yes -o ConnectTimeout=10 \
        "$LOGIN_ALIAS" \
        "squeue -u $REMOTE_USER -h -t R -w $NODE -o '%N' 2>/dev/null | head -1")

    if [ -z "$FOUND" ]; then
        echo ""
        echo "No running job found on $NODE for user $REMOTE_USER."
        echo ""
        echo "Start one:"
        echo "  ssh $LOGIN_ALIAS"
        echo "  sbatch ~/sh/term_session.sh"
        echo ""
        echo "Once it's running, rerun: ./connect_nvim.sh"
        exit 1
    fi
    echo "Found running job on node: $NODE"
fi

echo "Connecting to container on $NODE ..."
echo "(Inside the container, start zellij manually if you want: zellij --session nvim)"
echo ""

# ─── Capture local terminal dimensions ───────────────────────────────────────
# stty size reads TIOCGWINSZ directly from the PTY fd — more reliable than
# `tput cols/lines`, which can return the value of the $COLUMNS env var set by
# an enclosing tmux/multiplexer session instead of the actual window size.
_sz=$(stty size 2>/dev/null)                      # "rows cols", e.g. "60 220"
COLS="${_sz##* }" ROWS="${_sz%% *}"
[[ -z "$COLS"  || "$COLS"  -le 0 ]] 2>/dev/null && COLS=$(tput cols  2>/dev/null || echo 220)
[[ -z "$ROWS"  || "$ROWS"  -le 0 ]] 2>/dev/null && ROWS=$(tput lines 2>/dev/null || echo 50)
unset _sz

# ─── SSH to compute node and launch the container via proot ──────────────────
# Uses the compute node's native SSH (no container sshd needed).
# Drops into interactive zsh (`-i`) so /etc/zsh/zshrc is sourced (aliases,
# starship, zoxide).  /etc/zsh/zshenv (PATH, XDG_*, EDITOR, SHELL) is sourced
# unconditionally.  No zellij is launched — start it yourself if desired.
#
# _SSH_COLS / _SSH_ROWS: custom env vars that carry the Mac terminal dimensions
# into the container.  zsh will NOT overwrite these (unlike $COLUMNS/$LINES,
# which zsh resets from TIOCGWINSZ during interactive init).  The y() wrapper
# in /etc/zsh/zshrc reads them as the authoritative fallback when TIOCGWINSZ
# inside Singularity returns 0 or an 80×24 default.
# ─── mac-open reverse tunnel ──────────────────────────────────────────────────
# -R 8765:127.0.0.1:8765 forwards the compute node's localhost:8765 back to the
# Mac's localhost:8765, where mac_open_listener.py (LaunchAgent
# com.matthewson.mac-open-listener) accepts file/URL open requests from
# `mac-open` inside the container.  Singularity shares host networking, so
# the container can reach the compute node's loopback transparently.
#
# Local listener sanity check: if nothing is bound to 127.0.0.1:8765 on the
# Mac, the reverse tunnel would land on a dead port and every `mac-open` call
# would just hang / time out.  Warn loudly so the user notices.
if ! lsof -nP -iTCP@127.0.0.1:8765 -sTCP:LISTEN >/dev/null 2>&1; then
    echo ""
    echo "⚠  mac-open: nothing listening on 127.0.0.1:8765 on this Mac."
    echo "    Start it with one of:"
    echo "      launchctl kickstart -k gui/\$(id -u)/com.matthewson.mac-open-listener"
    echo "      python3 ~/mac_open_listener.py &"
    echo "    Continuing — but mac-open inside the container will fail until fixed."
    echo ""
fi

# ─── X11 forwarding for VimTeX → sioyek (opt-in) ─────────────────────────────
# VimTeX's viewer (sioyek) runs inside the container and renders to this Mac's
# XQuartz over the SSH X11 forward (`-Y`, added to the ssh command below). For
# that to work the local X server must be running and $DISPLAY must point at it.
#
# This is OFF by default: a plain connect should not launch XQuartz or pull in
# the X11/xauth machinery (which on the compute node prompts for a password and
# spews ".Xauthority does not exist" warnings). Enable it only when you actually
# want VimTeX \lv → sioyek:
#   WITH_X11=1 ./connect_nvim.sh
X11_SSH_OPT=""
if [ -z "${WITH_X11:-}" ]; then
    :   # X11 not requested — skip XQuartz launch and -Y forwarding entirely.
elif [ -d /Applications/Utilities/XQuartz.app ] || [ -d /opt/X11 ]; then
    if ! pgrep -xq Xquartz 2>/dev/null; then
        echo "Starting XQuartz (needed for VimTeX \\lv → sioyek over X11)…"
        open -a XQuartz 2>/dev/null || true
        # Give the X server a moment to come up and register its socket.
        for _i in 1 2 3 4 5; do pgrep -xq Xquartz 2>/dev/null && break; sleep 1; done
    fi
    # A plain terminal may not have inherited DISPLAY from the launchd GUI
    # session; pull it from launchd so ssh -Y has a target X server.
    if [ -z "${DISPLAY:-}" ]; then
        DISPLAY="$(launchctl getenv DISPLAY 2>/dev/null)"
        [ -n "$DISPLAY" ] && export DISPLAY
    fi
    if pgrep -xq Xquartz 2>/dev/null && [ -n "${DISPLAY:-}" ]; then
        X11_SSH_OPT="-Y"
    else
        echo "⚠  XQuartz did not come up (no DISPLAY) — VimTeX \\lv won't display."
        echo "    Try: open -a XQuartz   then rerun ./connect_nvim.sh"
    fi
else
    echo "⚠  XQuartz not installed — VimTeX \\lv (sioyek over X11) won't display."
    echo "    Install once:  brew install --cask xquartz   (then log out/in)."
    echo "    Continuing without X11 forwarding."
fi

# -o ExitOnForwardFailure=yes: if the compute node can't bind 8765 (e.g. an
# orphaned forward from a previous session is holding the port), ssh aborts
# immediately instead of dropping you into a shell with a dead tunnel.
#
# Singularity/Apptainer can't start containers on compute nodes post-2026, so we
# launch via ~/bin/proot_dev.sh instead (userspace proot). It forwards args to
# zsh, so `-i -c '...'` behaves like the old `singularity exec ... zsh -i -c`.
ssh \
    -J "$LOGIN_ALIAS" \
    -R 8765:127.0.0.1:8765 \
    ${X11_SSH_OPT} \
    -o ExitOnForwardFailure=yes \
    -tt \
    "$REMOTE_USER@$NODE" \
    "TERM=xterm-256color COLUMNS=$COLS LINES=$ROWS _SSH_COLS=$COLS _SSH_ROWS=$ROWS \
     ~/bin/proot_dev.sh -i -c 'stty cols $COLS rows $ROWS 2>/dev/null; exec zsh -i'"
