#!/bin/bash
#SBATCH --job-name=rsync_work
#SBATCH --output=/home/g/gson/sh_log/rsync_work_%j.log
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=16
#SBATCH --mem=16gb
#SBATCH --partition=general
#SBATCH --time=4-00:00:00
#SBATCH --mail-type=FAIL,END
#SBATCH --mail-user=gson@usf.edu
#
# Parallel, resume-safe migration of /work_bgfs/g/gson -> /work/g/gson.
#
# WHY THIS EXISTS
#   The previous job copied the whole tree with a single
#       xargs -P 8 -I{} rsync -a -- {} /work/g/gson/
#   but /work_bgfs/g/gson has only ONE top-level entry (01_Projects), so xargs
#   had a single work item -> ONE serial rsync.  The -P 8 did nothing.  On 1.2 TB
#   of small, sharded parquet files (metadata-bound: BeeGFS source + FUSE/Quobyte
#   destination) it moved ~17 GB/h and could not finish inside the 24 h wall.
#
# WHAT THIS DOES
#   Splits 01_Projects at depth-2 (~65 balanced work units, e.g.
#   01_Projects/04_OptionsML/BAW_10Mvol_DIV0) and runs $JOBS rsyncs in parallel,
#   then a single final full sweep to guarantee completeness.
#
# RESUME-SAFE
#   Plain `rsync -a` (no --partial): a file appears at its real name only after
#   it is fully copied (atomic temp-then-rename), so no half-written parquet is
#   ever visible.  Re-running skips files already copied (size+mtime) and only
#   transfers what's missing.  Safe to scancel and resubmit at any time.
#
# NODE REQUIREMENT
#   Must run where BOTH /work_bgfs (source) and /work (dest) are mounted.
#   /work_bgfs is NOT mounted on muma_2021 nodes -> keep --partition=general.
#
# TUNING
#   JOBS defaults to 16; this copy is metadata-bound (not CPU-bound), so more
#   concurrency hides per-file latency.  Override without editing:
#       RSYNC_JOBS=24 sbatch rsync_work.sh

set -uo pipefail

SRC=/work_bgfs/g/gson
DST=/work/g/gson
BIG=01_Projects                 # the large tree to parallelize
DEPTH=2                         # split BIG at this directory depth
JOBS="${RSYNC_JOBS:-16}"        # parallel rsync workers

# rsync 3.0.9 on CIRCE has no --info= support; classic flags only.
RSYNC=(rsync -a)

ts() { date '+%Y-%m-%d %H:%M:%S'; }
echo "=========================================================="
echo " parallel work_bgfs -> work migration"
echo " start : $(ts)   host: $(hostname -s)   jobid: ${SLURM_JOB_ID:-?}"
echo " SRC   : $SRC"
echo " DST   : $DST"
echo " split : $BIG at depth $DEPTH    workers: $JOBS"
echo "=========================================================="

# Fail fast if this node can't see the source (wrong partition).
[ -d "$SRC" ]      || { echo "FATAL: $SRC not mounted on $(hostname -s). Use --partition=general."; exit 1; }
[ -d "$SRC/$BIG" ] || { echo "FATAL: $SRC/$BIG not found."; exit 1; }
mkdir -p "$DST"    || { echo "FATAL: cannot create $DST"; exit 1; }
cd "$SRC"          || { echo "FATAL: cannot cd $SRC"; exit 1; }

# ── phase 1: pre-create the directory skeleton (dirs only, fast) ────────────
# Keeps the parallel workers from racing to mkdir the same parents.
echo "[$(ts)] phase 1: directory skeleton of $BIG"
"${RSYNC[@]}" -f'+ */' -f'- *' "$BIG/" "$DST/$BIG/"

# ── phase 2: parallel copy of the leaf work-units ──────────────────────────
echo "[$(ts)] phase 2: parallel copy ($JOBS workers, depth-$DEPTH units)"
find "$BIG" -mindepth "$DEPTH" -maxdepth "$DEPTH" -type d -print0 \
  | xargs -0 -P "$JOBS" -I{} "${RSYNC[@]}" -R -- "{}" "$DST/"
echo "[$(ts)] phase 2 finished (xargs rc=$?)"

# ── phase 3: final full sweep — correctness guarantee ──────────────────────
# Catches anything above the split depth (loose files in $BIG/ and $BIG/*/),
# any other top-level entries, and prints a summary.  Mostly a stat pass since
# the bulk is already copied, so it is fast and idempotent.
echo "[$(ts)] phase 3: final consistency sweep (+ stats)"
"${RSYNC[@]}" --stats ./ "$DST/"
RC=$?

echo "=========================================================="
echo "[$(ts)] FINISHED   (final rsync rc=$RC)"
echo " Verify: re-run this script — a clean run reports"
echo " 'Number of files transferred: 0' in the phase-3 stats."
echo "=========================================================="
exit "$RC"
