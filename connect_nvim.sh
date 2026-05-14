#!/bin/bash
#
# connect_nvim.sh — Mac-side script to reconnect to a running nvim_session on CIRCE.
#
# Usage:
#   ./connect_nvim.sh          # auto-find job and connect
#   ./connect_nvim.sh <node>   # connect directly to a known node
#
# On first connect:  creates a Zellij session named 'nvim' (run `nvim` inside)
# On reconnect:      re-attaches to the existing session with your state intact
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
echo "(First time: run 'nvim' inside the Zellij session)"
echo ""

# ─── Capture local terminal dimensions ───────────────────────────────────────
# singularity exec doesn't forward TIOCGWINSZ, so Zellij sees the wrong size.
# We read dimensions here and apply them inside via stty.
COLS=$(tput cols 2>/dev/null || echo 220)
ROWS=$(tput lines 2>/dev/null || echo 50)

# ─── SSH to compute node and exec into the running Singularity instance ───────
# Uses the compute node's native SSH (no container sshd needed).
# Uses absolute path to singularity binary — module system not available in
# non-login SSH exec sessions.
SINGULARITY=/apps/singularity/3.5.3/bin/singularity
ssh \
    -J "$LOGIN_ALIAS" \
    -tt \
    "$REMOTE_USER@$NODE" \
    "TERM=xterm-256color COLUMNS=$COLS LINES=$ROWS \
     $SINGULARITY exec instance://$INSTANCE \
     bash -c 'stty cols $COLS rows $ROWS 2>/dev/null; \
              zellij attach nvim 2>/dev/null || zellij --session nvim'"
