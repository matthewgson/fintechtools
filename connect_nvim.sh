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
#   ~/.ssh/local_mac_to_singularity  (private key for container SSH)
#   nvim_session.sh running on CIRCE via sbatch

LOGIN_NODE="circe.rc.usf.edu"
REMOTE_USER="gson"
SSH_PORT=2222
SSH_KEY="$HOME/.ssh/local_mac_to_singularity"
JOB_NAME="nvim_session"

# ─── Check key exists ─────────────────────────────────────────────────────────
if [ ! -f "$SSH_KEY" ]; then
    echo "ERROR: SSH key not found at $SSH_KEY"
    exit 1
fi

# ─── Find compute node ────────────────────────────────────────────────────────
if [ -n "$1" ]; then
    NODE="$1"
    echo "Using provided node: $NODE"
else
    echo "Looking for running '$JOB_NAME' job on CIRCE..."
    NODE=$(ssh -o BatchMode=yes -o ConnectTimeout=10 \
        "$REMOTE_USER@$LOGIN_NODE" \
        "squeue -u $REMOTE_USER -n $JOB_NAME -h -o '%N' 2>/dev/null | head -1")

    if [ -z "$NODE" ]; then
        echo ""
        echo "No '$JOB_NAME' job is running."
        echo ""
        echo "Start one:"
        echo "  ssh $REMOTE_USER@$LOGIN_NODE"
        echo "  sbatch ~/containers/$JOB_NAME.sh"
        echo ""
        echo "Once it's running, rerun: ./connect_nvim.sh"
        exit 1
    fi
    echo "Found job on node: $NODE"
fi

echo "Connecting to container on $NODE:$SSH_PORT ..."
echo "(First time: run 'zellij --session nvim' then 'nvim' inside)"
echo ""

# ─── SSH into container and attach (or create) the Zellij 'nvim' session ─────
ssh \
    -J "$REMOTE_USER@$LOGIN_NODE" \
    "$REMOTE_USER@$NODE" \
    -p "$SSH_PORT" \
    -i "$SSH_KEY" \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -t "zellij attach nvim 2>/dev/null || zellij --session nvim"
