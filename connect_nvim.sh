#!/bin/bash
#
# connect_nvim.sh — Mac-side script to reconnect to a running nvim_session on CIRCE.
#
# Usage:
#   ./connect_nvim.sh              # auto-find job and connect
#   ./connect_nvim.sh <node>       # connect directly to a known node
#
# Drops into an interactive zsh inside the container (launched via udocker).
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

# Container launcher to run on the compute node (udocker Fakechroot/F3). It
# forwards args to zsh, so `-i -c '...'` behaves like a plain interactive shell.
LAUNCHER="udocker_dev.sh"

# How long to sit out after the login node refuses us (see ensure_master).
BACKOFF_SECS=900
REFUSED_STAMP="$HOME/.ssh/sockets/.circe_refused"

# ─── Login-node connection budget ────────────────────────────────────────────
# CIRCE's login node rate-limits by source IP and answers over-limit traffic
# with ICMP host-prohibited — which ssh reports as "Connection refused" for ALL
# ports, and ping stops answering too. Because the VPN pool address is shared,
# the budget is not entirely ours to spend, so this script spends as little as
# possible: exactly ONE TCP connection to the login node, held open as a
# ControlMaster. The squeue probe and the ProxyJump to the compute node then
# ride that session as extra channels — the firewall sees no new connections.
#
# The failure that used to cost us: a master killed by a VPN reconnect or sleep
# leaves its socket file behind, ssh silently declines to multiplex, and every
# invocation dials fresh instead. `ssh -O check` is the only reliable liveness
# test, so use it rather than testing for the socket file's existence.
ensure_master() {
    mkdir -p "$HOME/.ssh/sockets"

    if ssh -O check "$LOGIN_ALIAS" 2>/dev/null; then
        return 0                       # live master — costs us nothing
    fi

    # Refuse to redial into a block we already hit. Retrying is what extends
    # these bans, and a rerun after a refusal is the natural reflex.
    if [ -f "$REFUSED_STAMP" ]; then
        local age=$(( $(date +%s) - $(stat -f %m "$REFUSED_STAMP") ))
        if [ "$age" -lt "$BACKOFF_SECS" ]; then
            echo "" >&2
            echo "The login node refused us $((age / 60))m ago; sitting out the" >&2
            echo "remaining $(( (BACKOFF_SECS - age) / 60 ))m rather than redialing." >&2
            echo "" >&2
            echo "Retrying now extends the block. If you need in sooner, reconnect" >&2
            echo "GlobalProtect for a new VPN address, then: rm $REFUSED_STAMP" >&2
            exit 1
        fi
        rm -f "$REFUSED_STAMP"
    fi

    # Clear a dead master's leftovers, then open the one connection we get.
    ssh -O exit "$LOGIN_ALIAS" 2>/dev/null
    rm -f "$(ssh -G "$LOGIN_ALIAS" 2>/dev/null | awk '/^controlpath /{print $2}')"

    echo "Opening master connection to $LOGIN_ALIAS ..."
    local err
    if ! err=$(ssh -o ConnectTimeout=15 -MNf "$LOGIN_ALIAS" 2>&1); then
        if printf '%s' "$err" | grep -qi 'connection refused\|prohibited'; then
            date +%s > "$REFUSED_STAMP" 2>/dev/null
            echo "" >&2
            echo "$LOGIN_ALIAS refused the connection." >&2
            echo "" >&2
            echo "This is a firewall reject, not sshd being down — the source IP is" >&2
            echo "blocked. Do not rerun in a loop; that extends it. Either wait it" >&2
            echo "out (~15m, backing off automatically) or reconnect GlobalProtect" >&2
            echo "to get a new VPN address." >&2
        else
            echo "Could not reach $LOGIN_ALIAS:" >&2
            printf '%s\n' "$err" >&2
        fi
        exit 1
    fi
}

ensure_master

# ─── Find compute node ────────────────────────────────────────────────────────
if [ -n "$1" ]; then
    NODE="$1"
    echo "Using provided node: $NODE"
else
    NODE="$TARGET_NODE"
    echo "Checking for any running job on $NODE..."
    # Rides the master opened above — no new TCP connection to the login node.
    FOUND=$(ssh -o BatchMode=yes -o ConnectTimeout=10 \
        "$LOGIN_ALIAS" \
        "squeue -u $REMOTE_USER -h -t R -w $NODE -o '%N' 2>/dev/null | head -1")

    if [ -z "$FOUND" ]; then
        echo ""
        echo "No running job found on $NODE for user $REMOTE_USER."
        echo ""
        echo "Start one (the master is already open, so this is free):"
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

# ─── SSH to compute node and launch the container via udocker ────────────────
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
# launch via ~/bin/$LAUNCHER instead (userspace udocker, Fakechroot/F3). It
# forwards args to zsh, so `-i -c '...'` behaves like `singularity exec … zsh -i -c`.
#
# TERM: default to xterm-256color but upgrade to xterm-ghostty INSIDE the container
# when the image carries ghostty's terminfo (baked in Dockerfile Stage 8h). With the
# real ghostty TERM, tmux 3.6b auto-detects truecolor + CSI-u extended keys natively
# (so C-Space and C-h/j/k/l work with no tmux.conf workarounds); images built before
# that stage simply keep xterm-256color. The `infocmp` probe runs in the container.
ssh \
    -J "$LOGIN_ALIAS" \
    -tt \
    "$REMOTE_USER@$NODE" \
    "TERM=xterm-256color COLUMNS=$COLS LINES=$ROWS _SSH_COLS=$COLS _SSH_ROWS=$ROWS \
     ~/bin/$LAUNCHER -i -c 'infocmp xterm-ghostty >/dev/null 2>&1 && export TERM=xterm-ghostty; stty cols $COLS rows $ROWS 2>/dev/null; exec zsh -i'"
