#!/bin/bash
# proot_dev.sh — launch the fintech-tools container via proot.
#
# CIRCE compute nodes can't run Singularity/Apptainer post-2026 (/apps nosuid +
# user namespaces disabled). proot is a userspace runtime needing neither. This
# extracts the rootfs tarball to node-local /tmp on first use and execs proot
# into zsh; args are forwarded to zsh (e.g. `proot_dev.sh -i -c '...'`).
#
# Env overrides: PROOT (~/bin/proot), FINTECH_TAR
# (/work/g/$USER/proot-sb/fintech-rootfs.tar), FINTECH_SBX (auto-picked /tmp dir).
set -uo pipefail

PROOT="${PROOT:-$HOME/bin/proot}"
FINTECH_TAR="${FINTECH_TAR:-/work/g/$USER/proot-sb/fintech-rootfs.tar}"

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
if [ ! -e "$SBX_READY" ]; then
    [ -f "$FINTECH_TAR" ] || { err "rootfs tarball not found at $FINTECH_TAR"; exit 1; }
    mkdir -p "$FINTECH_SBX" || exit 1
    exec 9>"$FINTECH_SBX/.extract.lock"
    command -v flock >/dev/null 2>&1 && flock 9
    if [ ! -e "$SBX_READY" ]; then   # re-check: another process may have just finished
        err "extracting container rootfs -> $FINTECH_SBX (first use on $(hostname -s)) ..."
        if ! tar -xpf "$FINTECH_TAR" -C "$FINTECH_SBX" --no-same-owner 2>/dev/null; then
            err "extraction failed"; exit 1
        fi
        : > "$SBX_READY"
        err "extraction complete."
    fi
    exec 9>&-
fi

# ─── Redirect regenerable hot state off the slow network home → node-local /tmp
# The network home (Quobyte/BeeGFS via FUSE) costs ~16 ms per small-file create
# vs ~0.3 ms on node-local /tmp — a ~45× metadata penalty, and proot compounds
# it because every syscall is ptraced (PROOT_NO_SECCOMP=1, mandatory on
# muma_2021, disables the seccomp fast-path). Tools that churn many small files
# under $HOME stall as a result; point the worst offenders at /tmp instead.
#
# Same safe guard as the nvim block in /etc/zsh/zshenv: relink only when the
# source is absent or already a symlink, so a real directory holding data is
# never hidden. Done host-side here (once per connection, not per shell), but
# $HOME and /tmp are bound 1:1 into the guest so the links resolve identically
# inside the container. If a hot dir already exists as a REAL dir on the home,
# delete it once (it's pure scratch) so the symlink can form:
#   rm -rf ~/.claude/shell-snapshots ~/.claude/statsig
_scratch="$(dirname "$FINTECH_SBX")"          # same node-local FS proot picked
_link_scratch() {                              # $1 = path relative to $HOME
    local src="$HOME/$1" dst="$_scratch/$1"
    mkdir -p "$dst" "$(dirname "$src")" 2>/dev/null || return 0
    if [ -L "$src" ] || [ ! -e "$src" ]; then ln -sfn "$dst" "$src" 2>/dev/null || true; fi
}
# Claude Code rewrites a shell snapshot under shell-snapshots/ on EVERY Bash
# tool call and churns statsig/ telemetry — both pure scratch. (projects/ holds
# conversation history and ~/.claude.json holds auth, so those stay on the home
# to survive an allocation.)
_link_scratch ".claude/shell-snapshots"
_link_scratch ".claude/statsig"

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

# X11 forwarding (VimTeX → sioyek): $DISPLAY/$XAUTHORITY inherit through proot's
# env automatically, and the TCP display (localhost:60xx) is reachable because
# proot shares host networking. We only need the SSH-issued xauth cookie file to
# be visible inside the sandbox. It normally lives in $HOME or /tmp (both bound
# by -R), but bind it explicitly in case sshd placed it elsewhere (e.g. /run).
if [ -n "${XAUTHORITY:-}" ] && [ -f "$XAUTHORITY" ]; then
    BINDS+=(-b "$XAUTHORITY:$XAUTHORITY")
fi

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
exec "$PROOT" -r "$FINTECH_SBX" "${BINDS[@]}" -w "$HOME" /bin/zsh "$@"
