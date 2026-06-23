#!/bin/bash
#
# connect_nvim.sh — Mac-side script to reconnect to a running nvim_session on CIRCE.
#
# Usage:
#   ./connect_nvim.sh              # auto-find job and connect
#   ./connect_nvim.sh <node>       # connect directly to a known node
#
# Drops into an interactive zsh inside the container (launched via proot).
# Start tmux/nvim manually from there if you want a persistent layout:
#   tm   (= tmux new-session -A -s main; attaches if it already exists)
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
echo "(Inside the container, start tmux manually if you want: tm)"
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
# unconditionally.  No tmux is launched — start it yourself if desired (`tm`).
#
# _SSH_COLS / _SSH_ROWS: custom env vars that carry the Mac terminal dimensions
# into the container.  zsh will NOT overwrite these (unlike $COLUMNS/$LINES,
# which zsh resets from TIOCGWINSZ during interactive init).  The y() wrapper
# in /etc/zsh/zshrc reads them as the authoritative fallback when TIOCGWINSZ
# inside Singularity returns 0 or an 80×24 default.
#
# PDF viewing needs no X11 and no Mac-side helper: VimTeX/yazi open PDFs in
# bookokrat, which draws in-terminal via the kitty graphics protocol over plain
# SSH (no XQuartz, no -Y forwarding, no mac-open reverse tunnel).

# Singularity/Apptainer can't start containers on compute nodes post-2026, so we
# launch via ~/bin/proot_dev.sh instead (userspace proot). It forwards args to
# zsh, so `-i -c '...'` behaves like the old `singularity exec ... zsh -i -c`.
ssh \
    -J "$LOGIN_ALIAS" \
    -tt \
    "$REMOTE_USER@$NODE" \
    "TERM=xterm-256color COLUMNS=$COLS LINES=$ROWS _SSH_COLS=$COLS _SSH_ROWS=$ROWS \
     ~/bin/proot_dev.sh -i -c 'stty cols $COLS rows $ROWS 2>/dev/null; exec zsh -i'"
