#!/bin/bash
#SBATCH --job-name=dev_session
#SBATCH --output=/home/g/gson/sh_log/dev_session.log
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=128
#SBATCH --partition=muma_2021
#SBATCH --qos=muma21
#SBATCH --mem=1007gb
#SBATCH --mail-type=FAIL,END
#SBATCH --mail-user=gson@usf.edu
#SBATCH --time=168:00:00
#SBATCH --nodelist=mdc-1057-13-9

# Load required modules
echo "Loading Singularity module..."
module load apps/singularity/3.5.3

# Capture start time in human-readable format
START_TIME=$(date '+%Y-%m-%d %H:%M:%S %Z')

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
        if singularity instance list | grep -q fintech_ssh_container; then
            singularity instance stop fintech_ssh_container 2>/dev/null
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
srun -N1 -n1 --job-name=prayer sleep infinity &

# Gather compute node information for SSH connection
COMPUTE_NODE=$(hostname)
NODE_IP=$(hostname -I | awk '{print $1}')
LOGIN_NODE="circe.rc.usf.edu"
SSH_PORT=2222


# Display session startup information
echo "========================================="
echo "FinTech Tools Development Session Started"
echo "========================================="
echo "Job ID: $SLURM_JOB_ID"
echo "Start Time: $START_TIME"
echo "Compute Node: $COMPUTE_NODE"
echo "Node IP: $NODE_IP"
echo "SSH Port: $SSH_PORT"
echo "Container: fintech-tools.sif (v0.4)"
echo "SSH Command: ssh -J $USER@$LOGIN_NODE $USER@$COMPUTE_NODE -p $SSH_PORT"
echo "========================================="

# Check for existing container instance and clean up if necessary
echo "Checking for existing container instances..."
if singularity instance list | grep -q fintech_ssh_container; then
    echo "Found existing container instance. Stopping it..."
    singularity instance stop fintech_ssh_container
    sleep 3
fi

# Verify munge binaries exist before attempting to bind mount them
MUNGE_BINDS=""
if [ -f "/usr/bin/munge" ]; then
    MUNGE_BINDS="$MUNGE_BINDS --bind /usr/bin/munge:/usr/bin/munge"
    echo "✓ Found munge binary for binding"
fi
if [ -f "/usr/bin/munged" ]; then
    MUNGE_BINDS="$MUNGE_BINDS --bind /usr/bin/munged:/usr/bin/munged"
    echo "✓ Found munged binary for binding"
else
    echo "⚠ Warning: /usr/bin/munged not found, skipping bind mount"
fi

# Verify directories exist before binding
OPTIONAL_BINDS=""
if [ -d "/var/run/munge" ]; then
    OPTIONAL_BINDS="$OPTIONAL_BINDS --bind /var/run/munge:/var/run/munge"
    echo "✓ Found munge socket directory for binding"
else
    echo "⚠ Warning: /var/run/munge not found, skipping bind mount"
fi

if [ -d "/etc/slurm" ]; then
    OPTIONAL_BINDS="$OPTIONAL_BINDS --bind /etc/slurm:/etc/slurm"
    echo "✓ Found SLURM config directory for binding"
else
    echo "⚠ Warning: /etc/slurm not found, skipping bind mount"
fi

# Start Singularity container instance with GPU and SSH support
# Enhanced bind mounts for full HPC integration:
# - Home directory for SSH keys and user data
# - Work directory for project files  
# - Shares for shared resources
# - SSH configuration from host
# - SLURM configuration for job management (if available)
# - Munge for authentication (if available)
echo "Starting Singularity container with GPU and SSH support..."
singularity instance start \
    --nv \
    --no-home \
    --bind /work_bgfs/g/$USER:/work_bgfs/g/$USER \
    --bind /home/g/$USER:/home/$USER \
    --bind /shares:/shares \
    --bind /home/g/gson/ssh_keys:/etc/ssh \
    $OPTIONAL_BINDS \
    $MUNGE_BINDS \
    /home/g/$USER/containers/fintech-tools.sif \
    fintech_ssh_container

# Allow container to fully initialize
echo "Waiting for container to initialize..."
sleep 5

# Verify container started successfully
if ! singularity instance list | grep -q fintech_ssh_container; then
    echo "❌ ERROR: Container failed to start properly"
    echo "Checking for container logs or errors..."
    singularity instance list
    exit 1
fi
echo "✓ Container instance started successfully"

# Create sanitized SLURM configuration inside the container to avoid
# "JobAcctGatherParams UsePSS and NoShared are mutually exclusive" fatal errors.
echo "Sanitizing SLURM configuration inside container..."
singularity exec instance://fintech_ssh_container /usr/local/bin/fix-slurm-config.sh

# Also set the environment variable for immediate use
singularity exec instance://fintech_ssh_container bash -c 'echo "export SLURM_CONF=/tmp/slurm/slurm.conf.sanitized" >> /home/gson/.bashrc'

# Test SLURM integration (optional verification)
echo "Verifying SLURM integration..."

# Test SLURM commands with sanitized configuration
echo "Testing SLURM commands with sanitized configuration..."
if singularity exec instance://fintech_ssh_container which sacct &>/dev/null; then
    echo "Testing SLURM version compatibility..."
    SLURM_TEST_OUTPUT=$(singularity exec instance://fintech_ssh_container bash -c 'export SLURM_CONF=/tmp/slurm/slurm.conf.sanitized && sacct --version' 2>&1)
    if echo "$SLURM_TEST_OUTPUT" | grep -q "slurm 21.08.8"; then
        echo "✓ SLURM 21.08.8 available and working in container"
    elif echo "$SLURM_TEST_OUTPUT" | grep -q "fatal.*mutually exclusive"; then
        echo "⚠ Warning: Configuration conflict still present"
    else
        echo "✓ SLURM commands working (version: $(echo "$SLURM_TEST_OUTPUT" | head -1))"
    fi
else
    echo "⚠ Warning: SLURM commands may not be properly configured"
fi

# Start SSH daemon inside the container for remote access
echo "Starting SSH daemon in container..."
if singularity exec instance://fintech_ssh_container test -f /usr/sbin/sshd; then
    singularity exec instance://fintech_ssh_container /usr/sbin/sshd -f /etc/ssh/sshd_config -D &
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
echo "Container is ready! SSH server is running and waiting for connections."
echo ""
echo "Connection Information:"
echo "  Host: $COMPUTE_NODE"
echo "  Port: $SSH_PORT"
echo "  User: $USER"
echo ""
echo "SSH Commands:"
echo "  Direct: ssh -J $USER@$LOGIN_NODE $USER@$COMPUTE_NODE -p $SSH_PORT"
echo "  VSCode: Use Remote-SSH extension with the above command"
echo "  Positron: Set up port forwarding first (see README.md)"
echo ""
echo "Available Tools in Container:"
echo "  - R 4.5.1 with RQuantLib & H2O"
echo "  - Python 3.12.3 with radian"
echo "  - SLURM commands (sacct, sbatch, squeue) - v21.08.8"
echo "  - QuantLib financial computing library"
echo "  - GPU acceleration (CUDA toolkit)"
echo "========================================="

# Keep the job running to maintain the container session
wait

