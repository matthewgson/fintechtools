#!/bin/bash
#
# connect_nvim.sh — Mac-side script to reconnect to a running nvim_session on CIRCE.
#
# Usage:
#   ./connect_nvim.sh          # auto-find job and connect
#   ./connect_nvim.sh <node>   # connect directly to a known node
#
# Drops into an interactive zsh inside the Singularity container.
# Start zellij/nvim manually from there if you want a persistent layout:
#   zellij attach nvim 2>/dev/null || zellij --session nvim
#
# Requires:
#   ~/.ssh/config entry for Host circe with IdentityFile ~/.ssh/circe_key
#   nvim_session running on CIRCE via sbatch

# SSH config alias for CIRCE login node (must match Host entry in ~/.ssh/config)
LOGIN_ALIAS="circe"
REMOTE_USER="gson"
INSTANCE="fintech_nvim"
JOB_NAME="nvim_session"

# ─── Find compute node ────────────────────────────────────────────────────────
if [ -n "$1" ]; then
    NODE="$1"
    echo "Using provided node: $NODE"
else
    echo "Looking for running '$JOB_NAME' job on CIRCE..."
    NODE=$(ssh -o BatchMode=yes -o ConnectTimeout=10 \
        "$LOGIN_ALIAS" \
        "squeue -u $REMOTE_USER -n $JOB_NAME -h -o '%N' 2>/dev/null | head -1")

    if [ -z "$NODE" ]; then
        echo ""
        echo "No '$JOB_NAME' job is running."
        echo ""
        echo "Start one:"
        echo "  ssh $LOGIN_ALIAS"
        echo "  sbatch ~/containers/term_session.sh"
        echo ""
        echo "Once it's running, rerun: ./connect_nvim.sh"
        exit 1
    fi
    echo "Found job on node: $NODE"
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

# ─── SSH to compute node and exec into the running Singularity instance ───────
# Uses the compute node's native SSH (no container sshd needed).
# Uses absolute path to singularity binary — module system not available in
# non-login SSH exec sessions.
# Drops into interactive zsh (`-i`) so /etc/zsh/zshrc is sourced (aliases,
# starship, zoxide).  /etc/zsh/zshenv (PATH, XDG_*, EDITOR, SHELL) is sourced
# unconditionally.  No zellij is launched — start it yourself if desired.
#
# _SSH_COLS / _SSH_ROWS: custom env vars that carry the Mac terminal dimensions
# into the container.  zsh will NOT overwrite these (unlike $COLUMNS/$LINES,
# which zsh resets from TIOCGWINSZ during interactive init).  The y() wrapper
# in /etc/zsh/zshrc reads them as the authoritative fallback when TIOCGWINSZ
# inside Singularity returns 0 or an 80×24 default.
SINGULARITY=/apps/singularity/3.5.3/bin/singularity
ssh \
    -J "$LOGIN_ALIAS" \
    -tt \
    "$REMOTE_USER@$NODE" \
    "TERM=xterm-256color COLUMNS=$COLS LINES=$ROWS _SSH_COLS=$COLS _SSH_ROWS=$ROWS \
     $SINGULARITY exec instance://$INSTANCE \
     zsh -i -c 'stty cols $COLS rows $ROWS 2>/dev/null; exec zsh -i'"
