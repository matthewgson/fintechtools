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

# Lightweight CPU-only Neovim dev session. Mirrors dev_session.sh structure
# but drops GPU request, CUDA module load, and /apps/cuda bind so the job
# runs on any muma_2021 node (CUDA tree isn't guaranteed on non-GPU nodes).

# Load required modules
echo "Loading Singularity module..."
module load apps/singularity/3.5.3

# Capture start time in human-readable format
START_TIME=$(date '+%Y-%m-%d %H:%M:%S %Z')

INSTANCE="fintech_nvim"
SIF="$HOME/containers/fintech-tools.sif"
SSH_PORT=2222
LOGIN_NODE="circe.rc.usf.edu"

# Set up cleanup function for graceful shutdown
export GID=$$
cleanup() {
    echo "Performing cleanup operations..."

    # Stop SSH daemon if it's running
    if [ ! -z "$SSH_PID" ] && kill -0 $SSH_PID 2>/dev/null; then
        echo "Stopping SSH daemon (PID: $SSH_PID)..."
        kill $SSH_PID 2>/dev/null
    fi

    # Stop the Singularity instance with retries
    echo "Stopping Singularity container..."
    for i in {1..3}; do
        if singularity instance list | grep -q "$INSTANCE"; then
            singularity instance stop "$INSTANCE" 2>/dev/null
            sleep 2
        else
            echo "Container instance stopped successfully"
            break
        fi
        if [ $i -eq 3 ]; then
            echo "Warning: Container may still be running"
        fi
    done

    # Kill the process group
    kill -SIGINT -$GID 2>/dev/null

    # Cancel the SLURM job
    scancel $SLURM_JOB_ID 2>/dev/null

    echo "Cleanup completed"
}
# Register cleanup function to run on script exit
trap cleanup EXIT

# Start background process to prevent job termination due to inactivity
echo "Starting background keep-alive process..."
srun -N1 -n1 --job-name=nvim_keepalive sleep infinity &

# Gather compute node information for SSH connection
COMPUTE_NODE=$(hostname)
NODE_IP=$(hostname -I | awk '{print $1}')

# Display session startup information
echo "========================================="
echo "Neovim Dev Session Started"
echo "========================================="
echo "Job ID: $SLURM_JOB_ID"
echo "Start Time: $START_TIME"
echo "Compute Node: $COMPUTE_NODE"
echo "Node IP: $NODE_IP"
echo "SSH Port: $SSH_PORT"
echo "Container: fintech-tools.sif (v0.6 - CPU only)"
echo "SSH Command: ssh -J $USER@$LOGIN_NODE $USER@$COMPUTE_NODE -p $SSH_PORT"
echo "========================================="

# Verify SIF exists
if [ ! -f "$SIF" ]; then
    echo "❌ ERROR: Container not found at $SIF"
    exit 1
fi

# Check for existing container instance and clean up if necessary
echo "Checking for existing container instances..."
if singularity instance list | grep -q "$INSTANCE"; then
    echo "Found existing container instance. Stopping it..."
    singularity instance stop "$INSTANCE"
    sleep 3
fi

echo "Starting Singularity container with SSH support..."
singularity instance start \
    --no-home \
    --bind /work_bgfs/g/$USER:/work_bgfs/g/$USER \
    --bind /home/g/$USER:/home/$USER \
    --bind /shares:/shares \
    --bind /home/g/gson/ssh_keys:/etc/ssh \
    "$SIF" \
    "$INSTANCE"

# Allow container to fully initialize
echo "Waiting for container to initialize..."
sleep 5

# Verify container started successfully
if ! singularity instance list | grep -q "$INSTANCE"; then
    echo "❌ ERROR: Container failed to start properly"
    singularity instance list
    exit 1
fi
echo "✓ Container instance started successfully"

# Start SSH daemon inside the container for remote access
echo "Starting SSH daemon in container..."
if singularity exec instance://$INSTANCE test -f /usr/sbin/sshd; then
    singularity exec instance://$INSTANCE /usr/sbin/sshd -f /etc/ssh/sshd_config -D &
    SSH_PID=$!
    sleep 3

    # Verify SSH daemon is running
    if kill -0 $SSH_PID 2>/dev/null; then
        echo "✓ SSH daemon started successfully (PID: $SSH_PID)"
    else
        echo "❌ ERROR: SSH daemon failed to start"
        exit 1
    fi
else
    echo "❌ ERROR: SSH daemon not found in container"
    exit 1
fi

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

# Keep the job running to maintain the container session
wait
