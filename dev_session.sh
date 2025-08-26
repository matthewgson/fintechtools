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
    # Stop the Singularity instance
    singularity instance stop fintech_ssh_container 2>/dev/null
    # Kill the process group
    kill -SIGINT -$GID 2>/dev/null
    # Cancel the SLURM job
    scancel $SLURM_JOB_ID 2>/dev/null
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
echo "VSCode Development Session Started"
echo "========================================="
echo "Job ID: $SLURM_JOB_ID"
echo "Start Time: $START_TIME"
echo "Compute Node: $COMPUTE_NODE"
echo "Session Info: $SESSION_INFO"
echo "SSH Command: ssh -J $USER@$LOGIN_NODE $USER@$COMPUTE_NODE"
echo "========================================="

# Check for existing container instance and clean up if necessary
if singularity instance list | grep -q fintech_ssh_container; then
    echo "Found existing container instance. Stopping it..."
    singularity instance stop fintech_ssh_container
    sleep 2
fi

# Start Singularity container instance with GPU and SSH support
# Home contains .ssh directory for SSH keys
# In the sshd_config file it seraches: AuthorizedKeysFile ~/.ssh/authorized_keys
# Bind the Slurm configuration directory
echo "Starting Singularity container with GPU and SSH support..."
singularity instance start \
    --nv \
    --no-home \
    --bind /work_bgfs/g/$USER:/work_bgfs/g/$USER \
    --bind /home/g/$USER:/home/$USER \
    --bind /shares:/shares \
    --bind /home/g/gson/ssh_keys:/etc/ssh \
    --bind /etc/slurm:/etc/slurm \
    /home/g/$USER/containers/fintech-tools.sif \
    fintech_ssh_container

# Allow container to fully initialize
echo "Waiting for container to initialize..."
sleep 1

# Start SSH daemon inside the container for remote access
echo "Starting SSH daemon in container..."
singularity exec instance://fintech_ssh_container /usr/sbin/sshd -f /etc/ssh/sshd_config -D &
sleep 2

echo "Container is ready! SSH server is running and waiting for connections..."
echo "Use the SSH command above to connect with Positron or other SSH clients."

# Keep the job running to maintain the container session
wait

