#!/bin/bash
#SBATCH --job-name=gpu_dev_session
#SBATCH --output=/home/g/gson/sh_log/gpu_dev_session.log
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=64
#SBATCH --partition=muma_2021
#SBATCH --qos=muma21
#SBATCH --mem=251gb
#SBATCH --gres=gpu:2 
#SBATCH --mail-type=FAIL,END
#SBATCH --mail-user=gson@usf.edu
#SBATCH --time=168:00:00
#SBATCH --nodelist=mdc-1057-18-1

# Load required modules
echo "Loading Singularity module..."
module load apps/singularity/3.5.3
module load apps/cuda/12.3

# Environment variables for Singularity
CUDA_PATH="/apps/cuda/12.3"

export CUDA_PATH="$CUDA_PATH"
export CUDA_HOME="$CUDA_PATH"
export LD_LIBRARY_PATH="/.singularity.d/libs:$LD_LIBRARY_PATH"

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
echo "Container: fintech-tools.sif (v0.42 - GPU Enabled)"
echo "SSH Command: ssh -J $USER@$LOGIN_NODE $USER@$COMPUTE_NODE -p $SSH_PORT"
echo "========================================="

# Check for existing container instance and clean up if necessary
echo "Checking for existing container instances..."
if singularity instance list | grep -q fintech_ssh_container; then
    echo "Found existing container instance. Stopping it..."
    singularity instance stop fintech_ssh_container
    sleep 3
fi

echo "Starting Singularity container with GPU and SSH support..."

# ─── SLURM client passthrough (host-binary binding) ──────────────────────────
# Cluster runs RHEL 7 + old SLURM; bind host binaries + their lib deps into
# /opt/host-slurm/ — wrapper scripts baked into the image at /usr/local/bin/
# exec them with a scoped LD_LIBRARY_PATH.
SLURM_BIND_ARGS=()
for _hp in /etc/slurm /etc/slurm-llnl /run/munge /var/run/munge /var/spool/slurm; do
  [ -d "$_hp" ] && SLURM_BIND_ARGS+=( --bind "$_hp:$_hp" )
done
for _hp in /usr/lib64/slurm /usr/lib/slurm; do
  if [ -d "$_hp" ]; then SLURM_BIND_ARGS+=( --bind "$_hp:$_hp" ); break; fi
done
_found_bins=()
# Try PATH first, then well-known RHEL 7 SLURM install locations.
# (sbatch compute jobs often don't inherit the SLURM bin dir in PATH.)
_slurm_bin_dirs=( /usr/bin /usr/local/bin /opt/slurm/bin /opt/slurm-llnl/bin )
for _cmd in squeue sacct sbatch srun sinfo scancel scontrol salloc \
            sstat sprio sshare sreport sacctmgr sbcast sdiag sattach \
            sgather sview sjstat; do
  _bin=$(command -v "$_cmd" 2>/dev/null) || true
  if [ -z "$_bin" ]; then
    for _dir in "${_slurm_bin_dirs[@]}"; do
      [ -x "$_dir/$_cmd" ] && _bin="$_dir/$_cmd" && break
    done
  fi
  [ -n "$_bin" ] && [ -x "$_bin" ] || continue
  SLURM_BIND_ARGS+=( --bind "$_bin:/opt/host-slurm/bin/$_cmd" )
  _found_bins+=( "$_bin" )
done
[ ${#_found_bins[@]} -eq 0 ] && \
  echo "⚠  No SLURM binaries found on host PATH or in ${_slurm_bin_dirs[*]}; sacct/squeue will not work inside container." >&2
declare -A _seen
for _entry in "${_found_bins[@]}"; do
  while IFS= read -r _lib; do
    [ -f "$_lib" ] && [ -z "${_seen[$_lib]:-}" ] || continue
    _seen[$_lib]=1; SLURM_BIND_ARGS+=( --bind "$_lib:/opt/host-slurm/lib/${_lib##*/}" )
  done < <(ldd "$_entry" 2>/dev/null | awk '/=> \//{print $3}' | \
           grep -E 'lib(slurm|munge|hwloc|numa|lua|pmi|pmix|json-c|yaml|jwt|jansson|hdf5|cgroup|systemd|cap)')
done
unset _hp _cmd _bin _dir _slurm_bin_dirs _found_bins _seen _entry _lib

singularity instance start \
    --nv \
    --no-home \
    --bind /work_bgfs/g/$USER:/work_bgfs/g/$USER \
    --bind /home/g/$USER:/home/$USER \
    --bind /shares:/shares \
    --bind /home/g/gson/ssh_keys:/etc/ssh \
    --bind /apps/cuda/12.3:/apps/cuda/12.3 \
    "${SLURM_BIND_ARGS[@]}" \
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

# Test GPU integration
echo "Testing GPU integration..."
if singularity exec instance://fintech_ssh_container which nvidia-smi &>/dev/null; then
    GPU_STATUS=$(singularity exec instance://fintech_ssh_container nvidia-smi --query-gpu=name --format=csv,noheader 2>&1)
    if [ $? -eq 0 ]; then
        echo "✓ GPU access working:"
        echo "$GPU_STATUS" | sed 's/^/  GPU: /'
    else
        echo "⚠ Warning: GPU access may have issues: $GPU_STATUS"
    fi
else
    echo "⚠ Note: nvidia-smi not available (expected if no GPU bound)"
fi

# Create privsep directory required by sshd (fails silently if already exists)
singularity exec instance://fintech_ssh_container mkdir -p /run/sshd 2>/dev/null || true

# Singularity user-namespace maps the process to a kernel UID that differs
# from the LDAP UID injected into /etc/passwd.  sshd calls setresuid(ldap_uid)
# which fails because the process is already kernel_uid ≠ ldap_uid and is not
# root.  Fix: overwrite the passwd entry with the actual effective UID/GID.
ACTUAL_UID=$(singularity exec instance://fintech_ssh_container id -u)
ACTUAL_GID=$(singularity exec instance://fintech_ssh_container id -g)
echo "Patching /etc/passwd in container: ${USER} uid=${ACTUAL_UID} gid=${ACTUAL_GID}"
singularity exec instance://fintech_ssh_container bash -c \
    "sed -i 's/^\(${USER}\):x:[0-9]*:[0-9]*/\1:x:${ACTUAL_UID}:${ACTUAL_GID}/' /etc/passwd" \
    2>/dev/null || true

# Start SSH daemon inside the container for remote access
echo "Starting SSH daemon in container..."
if singularity exec instance://fintech_ssh_container test -f /usr/sbin/sshd; then
    singularity exec instance://fintech_ssh_container \
        /usr/sbin/sshd -f /etc/ssh/sshd_config -o "UsePrivilegeSeparation no" -D &
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
echo "  - Python 3.12.3 (use pip install for packages)"
echo "  - QuantLib financial computing library"
echo "  - GPU acceleration via --nv (if available)"
echo "  - Development tools (git, vim, htop, etc.)"
echo "========================================="

# Keep the job running to maintain the container session
wait