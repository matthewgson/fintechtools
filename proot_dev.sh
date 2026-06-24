#!/bin/bash
# proot_dev.sh — launch the fintech-tools container via proot.
#
# CIRCE compute nodes can't run Singularity/Apptainer post-2026 (/apps nosuid +
# user namespaces disabled). proot is a userspace runtime needing neither. This
# extracts the rootfs tarball to node-local /tmp on first use and runs proot
# into zsh; args are forwarded to zsh (e.g. `proot_dev.sh -i -c '...'`).
#
# Env overrides: PROOT (~/bin/proot), FINTECH_TAR
# (/work/g/$USER/proot-sb/fintech-rootfs.tar), FINTECH_SBX (auto-picked /tmp dir).
set -uo pipefail

PROOT="${PROOT:-$HOME/bin/proot}"
# Prefer the persistent home copy of the rootfs tar, fall back to the legacy
# /work copy (build_container.sh ships to ~/proot-sb now; older runs used /work).
FINTECH_TAR="${FINTECH_TAR:-}"
if [ -z "$FINTECH_TAR" ]; then
    for _t in "$HOME/proot-sb/fintech-rootfs.tar" "/work/g/$USER/proot-sb/fintech-rootfs.tar"; do
        [ -f "$_t" ] && { FINTECH_TAR="$_t"; break; }
    done
    FINTECH_TAR="${FINTECH_TAR:-/work/g/$USER/proot-sb/fintech-rootfs.tar}"
fi

err() { echo "proot_dev: $*" >&2; }

[ -x "$PROOT" ] || { err "proot binary not found/executable at $PROOT"; exit 127; }

# Keep proot in pure-ptrace mode (PROOT_NO_SECCOMP=1). Toggling seccomp does
# NOT help with this proot 5.3.1 static binary — tested live on mdc-1057-13-13
# (AMD EPYC 7702) 2026-06-18: a 400k read/write-syscall `dd bs=1` ran ~6.0s
# (sys ~7.1s) with PROOT_NO_SECCOMP=0 and ~5.8s (sys ~7.1s) with =1 — identical.
# seccomp IS compiled in and proot reports "ptrace acceleration (seccomp mode 2)
# enabled" by default, but it never materializes here: read/write (which seccomp
# should let run native) still trap ~17 µs each, so the kernel seccomp-event
# path proot 5.3.1 needs isn't working on this node (its own strings warn
# "PTRACE_O_TRACESECCOMP not supported yet ... set PROOT_NO_SECCOMP to 1"), and
# it keeps syscall-tracing everything. The flag is thus a perf no-op — and
# seccomp was seen to segfault binaries on Xeon 4314 muma_2021 nodes — so pure
# ptrace is strictly the better default. Dropping the per-syscall tax needs a
# proot version where seccomp actually accelerates (re-test with the same dd
# A/B) or Apptainer (userns; no ptrace at all). An explicit PROOT_NO_SECCOMP in
# the environment overrides this.
export PROOT_NO_SECCOMP="${PROOT_NO_SECCOMP:-1}"

# Pick a node-local, exec-capable scratch dir for the sandbox (fixed order so the
# batch job and a later ssh connect agree; not $SLURM_TMPDIR — absent in ssh).
if [ -z "${FINTECH_SBX:-}" ]; then
    _pick=""
    for _base in "/tmp/$USER" "/dev/shm/$USER" "/work/g/$USER/proot-sb"; do
        [ -n "$_base" ] || continue
        mkdir -p "$_base" 2>/dev/null || continue
        printf '#!/bin/sh\nexit 0\n' > "$_base/.exectest" 2>/dev/null && chmod +x "$_base/.exectest" 2>/dev/null
        if "$_base/.exectest" 2>/dev/null; then _pick="$_base/fintech-sbx"; rm -f "$_base/.exectest"; break; fi
        rm -f "$_base/.exectest" 2>/dev/null
    done
    FINTECH_SBX="${_pick:-/tmp/$USER/fintech-sbx}"
fi

# Extract the rootfs once per node (/tmp is wiped between allocations).
# Readiness is gated on a marker written *after* tar finishes — not on the
# presence of bin/zsh, which tar creates (with its exec bit) mid-extraction.
# An flock serializes the batch pre-warm against an eager connect so the second
# one waits for a complete sandbox instead of execve'ing a half-written binary.
SBX_READY="$FINTECH_SBX/.extracted-ok"
# Re-extract when the marker is missing OR the rootfs tar is newer than it: a
# rebuilt image must replace a node's already-extracted sandbox, else a new tar
# isn't picked up until /tmp is wiped (mirrors udocker_dev.sh's auto-refresh).
_need_extract() { [ ! -e "$SBX_READY" ] || [ "$FINTECH_TAR" -nt "$SBX_READY" ]; }
if _need_extract; then
    [ -f "$FINTECH_TAR" ] || { err "rootfs tarball not found at $FINTECH_TAR"; exit 1; }
    mkdir -p "$FINTECH_SBX" || exit 1
    exec 9>"$FINTECH_SBX/.extract.lock"
    command -v flock >/dev/null 2>&1 && flock 9
    if _need_extract; then   # re-check under the lock
        # Refreshing a newer tar: clear the stale sandbox first (keeping the lock we
        # hold) so files removed in the new image don't linger.
        [ -e "$SBX_READY" ] && { err "newer rootfs tar — refreshing sandbox on $(hostname -s) ..."; \
            find "$FINTECH_SBX" -mindepth 1 -maxdepth 1 ! -name '.extract.lock' -exec rm -rf {} + 2>/dev/null; }
        err "extracting container rootfs -> $FINTECH_SBX on $(hostname -s) ..."
        if ! tar -xpf "$FINTECH_TAR" -C "$FINTECH_SBX" --no-same-owner 2>/dev/null; then
            err "extraction failed"; exit 1
        fi
        : > "$SBX_READY"
        err "extraction complete."
    fi
    exec 9>&-
fi

# ─── Redirect Claude Code's config dir off the slow network home → node-local
# Claude's startup is write/fsync-heavy against ~/.claude: a new session file, a
# shell snapshot, a history append, atomic .claude.json rewrites (write-tmp →
# fsync → rename), the daemon socket, and statsig/changelog caches. The network
# home is Quobyte via FUSE and was 100% full; measured under proot it runs
# writes ~43× slower and fsync ~13× slower than node-local disk (300 writes:
# 943 ms vs 22 ms; 60 fsyncs: 269 ms vs 21 ms), and proot ptraces every one of
# those syscalls. A cold first launch balloons into a ~1-minute freeze; warm
# launches still pay the fsync tax because fsync bypasses the page cache.
#
# CLAUDE_CONFIG_DIR relocates the whole tree (incl. the relocated .claude.json),
# so all that churn lands on fast local disk instead. This is node-portable and
# permanent: $_scratch is re-derived per node from the scratch base proot just
# picked, so moving to another node automatically uses *that* node's local disk.
# /tmp (and /dev/shm under /dev) is bound 1:1 into the guest, so the path
# resolves identically inside proot, and proot passes the env through to zsh.
#
# The canonical copy lives on $HOME. We seed the local dir from it on first use
# per node, and sync the persistent bits (auth + conversation history) back on
# exit; the regenerable scratch (shell-snapshots/, statsig/, daemon socket) is
# never copied back.
_scratch="$(dirname "$FINTECH_SBX")"          # same node-local FS proot picked
CC_HOME="$HOME/.claude"
CC_LOCAL="$_scratch/.claude"
if [ ! -d "$CC_LOCAL" ]; then                 # first use on this node → seed
    mkdir -p "$CC_LOCAL" 2>/dev/null || true
    [ -d "$CC_HOME" ] && cp -a "$CC_HOME/." "$CC_LOCAL/" 2>/dev/null
    [ -f "$HOME/.claude.json" ] && cp -a "$HOME/.claude.json" "$CC_LOCAL/.claude.json" 2>/dev/null
fi
export CLAUDE_CONFIG_DIR="$CC_LOCAL"
export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1   # no autoupdater / statsig / error-report calls

# Persist auth + history back to $HOME when the container exits, so credentials
# and conversation logs survive the per-allocation /tmp wipe. Best-effort and
# selective: the home was 100% full, so never silently assume a write worked —
# warn if it didn't. rsync --update ships only changed files (cheap on repeat,
# cp is the fallback). Concurrent sessions on different nodes merge per-file
# (last writer wins) — acceptable for a fallback CLI. .claude.json belongs at
# $HOME/.claude.json (not under .claude/), so it is handled separately.
_claude_sync_back() {
    [ -d "$CC_LOCAL" ] || return 0
    mkdir -p "$CC_HOME" 2>/dev/null
    local ok=1
    if command -v rsync >/dev/null 2>&1; then
        rsync -a --update \
              --exclude='shell-snapshots' --exclude='statsig' \
              --exclude='.claude.json' --exclude='*.sock' \
              "$CC_LOCAL/" "$CC_HOME/" 2>/dev/null || ok=0
    else
        local item
        for item in .credentials.json projects todos history history.jsonl; do
            [ -e "$CC_LOCAL/$item" ] && { cp -a "$CC_LOCAL/$item" "$CC_HOME/" 2>/dev/null || ok=0; }
        done
    fi
    [ -f "$CC_LOCAL/.claude.json" ] && { cp -a "$CC_LOCAL/.claude.json" "$HOME/.claude.json" 2>/dev/null || ok=0; }
    [ "$ok" -eq 1 ] || err "warning: Claude config sync-back to $HOME was incomplete (home full?)."
}
trap _claude_sync_back EXIT

# Bind mounts (proot's -b uses the same host:guest syntax as Singularity --bind).
#
# We launch with -r (bare rootfs) + these binds applied by hand rather than -R.
# -R is "rootfs + recommended host binds", but on this proot build (5.3.1) the
# -R code path leaves /proc/<pid>/exe untranslated: inside the sandbox
# /proc/self/exe resolves to the host proot loader (or nothing) instead of the
# guest binary. Anything that calls current_exe() to re-exec itself dies at
# startup with "no /proc/self/exe available. Is /proc mounted?".
# Applying the same binds explicitly under -r keeps identical behavior (same uid
# — -R does NOT grant root here — same $HOME, same tools) AND restores
# /proc/self/exe translation. Verified 2026-06-18 on mdc-1057-13-13:
# readlink /proc/self/exe → guest path.
BINDS=()
# -R's recommended bind set, applied by hand. Bind only sources that exist so
# proot doesn't abort on a missing path (e.g. /run or an absent /etc/* file).
for _b in /proc /dev /sys /tmp /run \
          /etc/passwd /etc/group /etc/hosts /etc/host.conf \
          /etc/nsswitch.conf /etc/resolv.conf /etc/localtime; do
    [ -e "$_b" ] && BINDS+=(-b "$_b:$_b")
done
[ -d "$HOME" ] && BINDS+=(-b "$HOME:$HOME")
for _d in "/work/g/$USER" "/work_bgfs/g/$USER" /shares; do
    [ -d "$_d" ] && BINDS+=(-b "$_d:$_d")
done

# SLURM client passthrough: host squeue/sacct + their RHEL-7 libs into
# /opt/host-slurm (image wrappers exec them with a scoped LD_LIBRARY_PATH).
# Best-effort — skipped when SLURM isn't on the node.
for _hp in /etc/slurm /etc/slurm-llnl /run/munge /var/run/munge /var/spool/slurm; do
    [ -d "$_hp" ] && BINDS+=(-b "$_hp:$_hp")
done
for _hp in /usr/lib64/slurm /usr/lib/slurm; do
    [ -d "$_hp" ] && { BINDS+=(-b "$_hp:$_hp"); break; }
done
_found_bins=()
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
    BINDS+=(-b "$_bin:/opt/host-slurm/bin/$_cmd")
    _found_bins+=("$_bin")
done
declare -A _seen
for _entry in "${_found_bins[@]}"; do
    while IFS= read -r _lib; do
        [ -f "$_lib" ] && [ -z "${_seen[$_lib]:-}" ] || continue
        _seen[$_lib]=1
        BINDS+=(-b "$_lib:/opt/host-slurm/lib/${_lib##*/}")
    done < <(ldd "$_entry" 2>/dev/null | awk '/=> \//{print $3}' |
        grep -E 'lib(slurm|munge|hwloc|numa|lua|pmi|pmix|json-c|yaml|jwt|jansson|hdf5|cgroup|systemd|cap)')
done

# Launch: -r = bare guest rootfs (host binds applied explicitly above — see the
# /proc/self/exe note); -w = start in the real $HOME. Default to interactive
# zsh; forward any args to zsh.
[ "$#" -eq 0 ] && set -- -i
# Not exec'd: this launcher stays the parent so the EXIT trap above (Claude
# config sync-back) runs after the guest shell quits. Preserve proot's status.
"$PROOT" -r "$FINTECH_SBX" "${BINDS[@]}" -w "$HOME" /bin/zsh "$@"
exit $?
