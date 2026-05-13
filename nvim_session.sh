#!/bin/bash
#SBATCH --job-name=nvim_session
#SBATCH --output=/home/g/gson/sh_log/nvim_session.log
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --partition=muma_2021
#SBATCH --qos=muma21
#SBATCH --mem=32gb
#SBATCH --mail-type=FAIL,END
#SBATCH --mail-user=gson@usf.edu
#SBATCH --time=168:00:00

# ─── Config ───────────────────────────────────────────────────────────────────
INSTANCE="fintech_nvim"
SIF="$HOME/containers/fintech-tools.sif"
SSH_PORT=2222
LOGIN_NODE="circe.rc.usf.edu"

# ─── Cleanup on job exit ──────────────────────────────────────────────────────
export GID=$$
cleanup() {
    echo "Shutting down nvim session (job $SLURM_JOB_ID)..."

    if [ -n "$SSH_PID" ] && kill -0 "$SSH_PID" 2>/dev/null; then
        echo "Stopping SSH daemon (PID: $SSH_PID)..."
        kill "$SSH_PID" 2>/dev/null
    fi

    echo "Stopping Singularity container..."
    for i in {1..3}; do
        singularity instance list 2>/dev/null | grep -q "$INSTANCE" || break
        singularity instance stop "$INSTANCE" 2>/dev/null
        sleep 2
    done

    kill -SIGINT -"$GID" 2>/dev/null
    scancel "$SLURM_JOB_ID" 2>/dev/null
    echo "Cleanup complete."
}
trap cleanup EXIT

# ─── Keep-alive (prevents SLURM from killing idle job) ───────────────────────
srun -N1 -n1 --job-name=nvim_keepalive sleep infinity &

# ─── Node info ────────────────────────────────────────────────────────────────
COMPUTE_NODE=$(hostname)

echo "========================================="
echo " Neovim Dev Session"
echo " Job ID  : $SLURM_JOB_ID"
echo " Node    : $COMPUTE_NODE"
echo " Started : $(date '+%Y-%m-%d %H:%M:%S')"
echo "========================================="

# ─── Verify SIF exists ────────────────────────────────────────────────────────
if [ ! -f "$SIF" ]; then
    echo "ERROR: Container not found at $SIF"
    exit 1
fi

# ─── Clean up any stale instance ─────────────────────────────────────────────
if singularity instance list 2>/dev/null | grep -q "$INSTANCE"; then
    echo "Removing stale container instance..."
    singularity instance stop "$INSTANCE" 2>/dev/null
    sleep 3
fi

# ─── Start container ──────────────────────────────────────────────────────────
echo "Starting Singularity container..."
singularity instance start \
    --no-home \
    --bind /work_bgfs/g/$USER:/work_bgfs/g/$USER \
    --bind /home/g/$USER:/home/$USER \
    --bind /shares:/shares \
    --bind /home/g/gson/ssh_keys:/etc/ssh \
    "$SIF" \
    "$INSTANCE"

sleep 5

if ! singularity instance list 2>/dev/null | grep -q "$INSTANCE"; then
    echo "ERROR: Container failed to start"
    singularity instance list
    exit 1
fi
echo "✓ Container started"

# ─── Start SSH daemon inside container ───────────────────────────────────────
if ! singularity exec "instance://$INSTANCE" test -f /usr/sbin/sshd; then
    echo "ERROR: sshd not found in container"
    exit 1
fi

singularity exec "instance://$INSTANCE" /usr/sbin/sshd -f /etc/ssh/sshd_config -D &
SSH_PID=$!
sleep 3

if ! kill -0 "$SSH_PID" 2>/dev/null; then
    echo "ERROR: SSH daemon failed to start"
    exit 1
fi
echo "✓ SSH daemon running (PID: $SSH_PID, port $SSH_PORT)"

# ─── Ready ────────────────────────────────────────────────────────────────────
echo ""
echo "========================================="
echo " READY — Neovim session is live"
echo ""
echo " From Mac, run:"
echo "   ./connect_nvim.sh"
echo ""
echo " Or manually:"
echo "   ssh -J $USER@$LOGIN_NODE $USER@$COMPUTE_NODE \\"
echo "     -p $SSH_PORT -i ~/.ssh/local_mac_to_singularity \\"
echo "     -t 'zellij attach nvim 2>/dev/null || zellij --session nvim'"
echo ""
echo " Your Zellij session 'nvim' persists inside the container."
echo " Disconnect and reconnect as many times as you like."
echo " Session ends when job $SLURM_JOB_ID is cancelled or times out."
echo "========================================="

# Keep job alive until cancelled
wait
