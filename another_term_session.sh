#!/bin/bash
#SBATCH --job-name=nvim_session2
#SBATCH --output=/home/g/gson/sh_log/nvim_session2.log
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=128
#SBATCH --partition=muma_2021
#SBATCH --qos=muma21
#SBATCH --mem=1007gb
#SBATCH --mail-type=FAIL,END
#SBATCH --mail-user=gson@usf.edu
#SBATCH --time=168:00:00
#SBATCH --nodelist=mdc-1057-13-12

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

  # Capture SLURM's view of this job's termination — invaluable for post-mortem
  # in the next log file.  Bounded with `timeout` in case sacct/scontrol hang
  # while slurmstepd is mid-teardown.
  echo "── SLURM job state at termination ──"
  timeout 5 scontrol show job "$SLURM_JOB_ID" 2>/dev/null | head -40 || true
  timeout 5 sacct -j "$SLURM_JOB_ID" \
    --format=JobID,State,Reason,Start,End,Elapsed,Timelimit,ExitCode 2>/dev/null || true
  echo "─────────────────────────────────────"

  # Cancel the SLURM job
  scancel $SLURM_JOB_ID 2>/dev/null

  echo "Cleanup completed"
}
# Register cleanup ONLY on real termination signals — not EXIT.
# Trapping EXIT caused the job to self-scancel whenever the foreground
# `wait` returned (e.g., a step's default time limit killed the keep-alive
# srun at ~12h even though --time=168:00:00 was set on the job).
trap cleanup SIGINT SIGTERM SIGHUP

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
echo "Container: fintech-tools.sif (v0.8 - CPU only)"
echo "Connect: ssh -J gson@$LOGIN_NODE -t gson@$COMPUTE_NODE '/apps/singularity/3.5.3/bin/singularity exec instance://$INSTANCE zsh -i'"
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

# ─── SLURM client passthrough (host-binary binding) ──────────────────────────
# Cluster runs RHEL 7 + old SLURM; bind host binaries + their lib deps into
# /opt/host-slurm/ — wrapper scripts baked into the image at /usr/local/bin/
# exec them with a scoped LD_LIBRARY_PATH.
SLURM_BIND_ARGS=()
for _hp in /etc/slurm /etc/slurm-llnl /run/munge /var/run/munge /var/spool/slurm; do
  [ -d "$_hp" ] && SLURM_BIND_ARGS+=(--bind "$_hp:$_hp")
done
for _hp in /usr/lib64/slurm /usr/lib/slurm; do
  if [ -d "$_hp" ]; then
    SLURM_BIND_ARGS+=(--bind "$_hp:$_hp")
    break
  fi
done
_found_bins=()
# Try PATH first, then well-known RHEL 7 SLURM install locations.
# (sbatch compute jobs often don't inherit the SLURM bin dir in PATH.)
_slurm_bin_dirs=(/usr/bin /usr/local/bin /opt/slurm/bin /opt/slurm-llnl/bin)
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
  SLURM_BIND_ARGS+=(--bind "$_bin:/opt/host-slurm/bin/$_cmd")
  _found_bins+=("$_bin")
done
[ ${#_found_bins[@]} -eq 0 ] &&
  echo "⚠  No SLURM binaries found on host PATH or in ${_slurm_bin_dirs[*]}; sacct/squeue will not work inside container." >&2
declare -A _seen
for _entry in "${_found_bins[@]}"; do
  while IFS= read -r _lib; do
    [ -f "$_lib" ] && [ -z "${_seen[$_lib]:-}" ] || continue
    _seen[$_lib]=1
    SLURM_BIND_ARGS+=(--bind "$_lib:/opt/host-slurm/lib/${_lib##*/}")
  done < <(ldd "$_entry" 2>/dev/null | awk '/=> \//{print $3}' |
    grep -E 'lib(slurm|munge|hwloc|numa|lua|pmi|pmix|json-c|yaml|jwt|jansson|hdf5|cgroup|systemd|cap)')
done
unset _hp _cmd _bin _dir _slurm_bin_dirs _found_bins _seen _entry _lib

singularity instance start \
  --no-home \
  --bind /work_bgfs/g/$USER:/work_bgfs/g/$USER \
  --bind /home/g/$USER:/home/$USER \
  --bind /shares:/shares \
  "${SLURM_BIND_ARGS[@]}" \
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
echo "     '/apps/singularity/3.5.3/bin/singularity exec instance://$INSTANCE zsh -i'"
echo ""
echo " The container instance persists; reconnect freely from another shell."
echo " To use zellij for persistent panes, run inside the container:"
echo "   zellij attach nvim 2>/dev/null || zellij --session nvim"
echo " Session ends when job $SLURM_JOB_ID is cancelled or times out."
echo "========================================="

# Hold the allocation for the full --time window (7 days). The batch script
# itself runs on the allocated node, so no srun keep-alive step is needed.
# Using a sleep loop (rather than `wait`) ensures the job stays alive until
# SLURM hits the wall-clock limit or the user scancels.
echo "Holding allocation until wall-clock limit (7 days max)..."

# ─── Sanity: surface SLURM's *effective* TimeLimit before we go quiet ────────
# If QoS/partition silently caps --time below 168h, the job will end early no
# matter how well the keep-alive loop holds.  Print the real limit so the next
# post-mortem doesn't have to guess.
EFFECTIVE_LIMIT=$(scontrol show job "$SLURM_JOB_ID" -o 2>/dev/null \
  | grep -oE 'TimeLimit=[^ ]+' | head -1 | cut -d= -f2)
EFFECTIVE_LIMIT="${EFFECTIVE_LIMIT:-unknown}"
echo "SLURM-enforced TimeLimit for this job: $EFFECTIVE_LIMIT"
case "$EFFECTIVE_LIMIT" in
  7-00:00:00 | 168:00:00 | UNLIMITED | unknown) ;;
  *)
    echo "⚠  WARNING: TimeLimit is shorter than the requested 7 days."
    echo "    QoS '${SLURM_JOB_QOS:-?}' or partition '${SLURM_JOB_PARTITION:-?}' is capping it."
    echo "    The job WILL end at: $EFFECTIVE_LIMIT — investigate with:"
    echo "       sacctmgr show qos ${SLURM_JOB_QOS:-?} format=Name,MaxWall,GrpTRES,Flags"
    echo "       scontrol show partition ${SLURM_JOB_PARTITION:-?}"
    ;;
esac

while true; do
  sleep 86400 &
  wait $!
done
