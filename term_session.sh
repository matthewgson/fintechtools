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
LOGIN_NODE="circe.rc.usf.edu"

# Set up cleanup function for graceful shutdown
export GID=$$
cleanup() {
    echo "Performing cleanup operations..."

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
echo "Container: fintech-tools.sif (v0.6 - CPU only)"
echo "Connect: ssh -J gson@$LOGIN_NODE -t gson@$COMPUTE_NODE '/apps/singularity/3.5.3/bin/singularity exec instance://$INSTANCE bash -c \"zellij attach nvim 2>/dev/null || zellij --session nvim\"'"
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

echo "Starting Singularity container..."
singularity instance start \
    --no-home \
    --bind /work_bgfs/g/$USER:/work_bgfs/g/$USER \
    --bind /home/g/$USER:/home/$USER \
    --bind /shares:/shares \
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

echo "========================================="
echo " READY — Neovim session is live"
echo ""
echo " From Mac, run:"
echo "   ./connect_nvim.sh"
echo ""
echo " Or manually:"
echo "   ssh -J gson@$LOGIN_NODE -t gson@$COMPUTE_NODE \\"
echo "     '/apps/singularity/3.5.3/bin/singularity exec instance://$INSTANCE \\"
echo "      bash -c \"zellij attach nvim 2>/dev/null || zellij --session nvim\"'"
echo ""
echo " Your Zellij session 'nvim' persists inside the container."
echo " Disconnect and reconnect as many times as you like."
echo " Session ends when job $SLURM_JOB_ID is cancelled or times out."
echo "========================================="

# Keep the job running to maintain the container session
wait
