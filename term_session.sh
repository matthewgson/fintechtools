#!/bin/bash
#SBATCH --job-name=nvim_session
#SBATCH --output=/home/g/gson/sh_log/nvim_session.log
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=128
#SBATCH --partition=muma_2021
#SBATCH --qos=muma21
#SBATCH --mem=1007gb
#SBATCH --mail-type=FAIL,END
#SBATCH --mail-user=gson@usf.edu
#SBATCH --time=168:00:00
#SBATCH --nodelist=mdc-1057-13-13

# Lightweight CPU-only Neovim dev session. Mirrors dev_session.sh structure
# but drops GPU request, CUDA module load, and /apps/cuda bind so the job
# runs on any muma_2021 node (CUDA tree isn't guaranteed on non-GPU nodes).

# ─── Container runtime: udocker (default) or proot (fallback) ────────────────
# Singularity/Apptainer can't start containers on compute nodes (/apps nosuid +
# user namespaces disabled). Both options below are userspace and need neither:
#   udocker (Fakechroot/F3) — LD_PRELOAD libc interception, ~5x faster on our
#     metadata-heavy workload (no ptrace tax). The default.
#   proot — ptrace-based; the stable fallback. Select with CONTAINER_RUNTIME=proot.
# Each launcher does its own per-node setup (extract / import+F3) on /tmp.
CONTAINER_RUNTIME="${CONTAINER_RUNTIME:-udocker}"
case "$CONTAINER_RUNTIME" in
  udocker) LAUNCHER="$HOME/bin/udocker_dev.sh" ;;
  proot|*) LAUNCHER="$HOME/bin/proot_dev.sh"; CONTAINER_RUNTIME=proot ;;
esac
# rootfs tar: prefer the persistent home copy, fall back to the legacy /work copy
# (this is just a pre-flight existence check; the launcher resolves its own path).
ROOTFS_TAR=""
for _t in "$HOME/proot-sb/fintech-rootfs.tar" "/work/g/$USER/proot-sb/fintech-rootfs.tar"; do
  [ -f "$_t" ] && { ROOTFS_TAR="$_t"; break; }
done
ROOTFS_TAR="${ROOTFS_TAR:-$HOME/proot-sb/fintech-rootfs.tar}"
echo "Container runtime: $CONTAINER_RUNTIME (userspace; no setuid, no user namespaces)"
if [ ! -x "$LAUNCHER" ] || [ ! -f "$ROOTFS_TAR" ]; then
  echo "❌ ERROR: missing launcher ($LAUNCHER) or rootfs tar ($ROOTFS_TAR)."
  echo "   Run the one-time setup in the README (install the launcher to ~/bin; build the rootfs tar)."
  exit 1
fi

# Capture start time in human-readable format
START_TIME=$(date '+%Y-%m-%d %H:%M:%S %Z')

LOGIN_NODE="circe.rc.usf.edu"

# Set up cleanup function for graceful shutdown
export GID=$$
cleanup() {
  echo "Performing cleanup operations..."

  # proot has no persistent instance/daemon to stop: each SSH connection runs
  # its own proot process tree that exits with that session.  The node-local
  # sandbox under /tmp is reclaimed automatically when the allocation ends.

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
echo "Container: fintech-tools rootfs via $CONTAINER_RUNTIME (CPU only)"
echo "Connect: ssh -J gson@$LOGIN_NODE -t gson@$COMPUTE_NODE '$LAUNCHER -i'"
echo "========================================="

# ─── Pre-warm the node-local container ───────────────────────────────────────
# Neither runtime has a persistent daemon — each SSH connection runs its own
# process tree against the shared node-local container on /tmp. Do the one-time
# per-node setup here (proot: extract ~50 s; udocker: import+create+F3 ~1.5 min)
# so the first ./connect_nvim.sh is instant instead of waiting on it.
echo "Pre-warming the node-local container ($CONTAINER_RUNTIME; first run only)..."
if ! "$LAUNCHER" -c 'echo "✓ container ready: $(head -1 /etc/os-release)"'; then
  echo "❌ ERROR: $CONTAINER_RUNTIME could not launch the container"
  exit 1
fi

echo "========================================="
echo " READY — Neovim session is live"
echo ""
echo " From Mac, run:"
echo "   ./connect_nvim.sh"
echo ""
echo " Or manually:"
echo "   ssh -J gson@$LOGIN_NODE -t gson@$COMPUTE_NODE \\"
echo "     '$LAUNCHER -i'"
echo ""
echo " Reconnect freely from another shell — each connection launches its own"
echo " proot against the shared node-local sandbox."
echo " For persistent panes, use tmux (fast under proot: ~0.03s to create) and"
echo " ATTACH to a named session so the same panes survive reconnects:"
echo "   tm                       # helper in .zshrc = tmux new-session -A -s main"
echo "   tmux new-session -A -s main   # the explicit form, if you prefer"
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
