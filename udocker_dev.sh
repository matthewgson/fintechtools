#!/bin/bash
# udocker_dev.sh — launch the fintech-tools container via udocker (Fakechroot/F3).
#
# Experimental, lower-overhead alternative to proot_dev.sh. CIRCE compute nodes
# can't run Singularity/Apptainer (/apps nosuid + user namespaces disabled), and
# proot's ptrace tax dominates our metadata-heavy workload (nvim plugin loads,
# Claude fsync writes). udocker's Fakechroot engine intercepts libc filesystem
# calls via LD_PRELOAD instead of ptrace, so per-op overhead is ~4-7x lower —
# measured inside the container 2026-06-23 on mdc-1057-13-13 (vs proot):
#   stat  0.005 vs 0.021 ms/op   read 0.007 vs 0.047 ms/op
#   create 0.017 vs 0.057 ms/op  fsync 0.225 vs 0.303 ms/op
# => LazyVim cold start ~5.7x faster. All tools ran, incl. Go statics fzf/lazygit.
#
# No rebuild: imports the SAME flat rootfs tar proot uses. Args forward to zsh
# (e.g. `udocker_dev.sh -i -c '...'`). proot_dev.sh stays as the stable fallback.
#
# Storage split (each item where its nature wants it):
#   /home  (persistent, backed-up; touched only at setup/launch, not at runtime):
#            udocker python package ($PYTHONUSERBASE) + rootfs tar
#   /tmp   (node-local fast disk; the runtime-hot paths):
#            $UDOCKER_DIR = container ROOT + tools; nvim plugin data; Claude config
#
# Env overrides: FINTECH_TAR, UDK_BASE ($HOME/udk), UDOCKER_DIR (node /tmp),
#   UDOCKER_IMAGE (fintech:latest), UDOCKER_CONTAINER (ft), PY_MODULE.
set -uo pipefail

err() { echo "udocker_dev: $*" >&2; }

UDOCKER_IMAGE="${UDOCKER_IMAGE:-fintech:latest}"
UDOCKER_CONTAINER="${UDOCKER_CONTAINER:-ft}"
PY_MODULE="${PY_MODULE:-apps/miniconda/4.7.12}"

# rootfs tar: prefer the persistent home copy, fall back to the legacy /work copy
# (build_container.sh currently ships to /work; it can move to ~/proot-sb later).
FINTECH_TAR="${FINTECH_TAR:-}"
if [ -z "$FINTECH_TAR" ]; then
    for _t in "$HOME/proot-sb/fintech-rootfs.tar" "/work/g/$USER/proot-sb/fintech-rootfs.tar"; do
        [ -f "$_t" ] && { FINTECH_TAR="$_t"; break; }
    done
    FINTECH_TAR="${FINTECH_TAR:-/work/g/$USER/proot-sb/fintech-rootfs.tar}"
fi

# ── python3 for the host-side udocker tool (the RHEL7 host has none) ──────────
# udocker is pure Python (>=3.6); the *running* container does NOT need it. Source
# the modules init first — a non-interactive shell lacks the `module` function.
if ! command -v python3 >/dev/null 2>&1; then
    command -v module >/dev/null 2>&1 \
        || source /etc/profile.d/modules.sh 2>/dev/null \
        || source /usr/share/lmod/lmod/init/bash 2>/dev/null || true
    module load "$PY_MODULE" 2>/dev/null || module load apps/anaconda/5.3.1 2>/dev/null || true
fi
command -v python3 >/dev/null 2>&1 || { err "no python3 (module load $PY_MODULE failed)"; exit 127; }

# ── udocker package on persistent $HOME (installed once) ──────────────────────
export PYTHONUSERBASE="${UDK_BASE:-$HOME/udk}"
export PATH="$PYTHONUSERBASE/bin:$PATH"
if ! command -v udocker >/dev/null 2>&1; then
    err "installing udocker -> $PYTHONUSERBASE (one-time) ..."
    pip install --user --upgrade --no-warn-script-location udocker 1>&2 \
        || { err "udocker pip install failed"; exit 1; }
fi

# ── node-local scratch for the hot stuff (container ROOT, Claude config) ──────
# Prefer /tmp (disk) over /dev/shm (RAM): the ROOT is ~4.5 GB, don't pay it in RAM.
if [ -z "${UDOCKER_DIR:-}" ]; then
    _pick=""
    for _base in "/tmp/$USER" "/dev/shm/$USER"; do
        mkdir -p "$_base" 2>/dev/null || continue
        printf '#!/bin/sh\nexit 0\n' > "$_base/.exectest" 2>/dev/null && chmod +x "$_base/.exectest" 2>/dev/null
        if "$_base/.exectest" 2>/dev/null; then _pick="$_base"; rm -f "$_base/.exectest"; break; fi
        rm -f "$_base/.exectest" 2>/dev/null
    done
    _NODE_SCRATCH="${_pick:-/tmp/$USER}"
    export UDOCKER_DIR="$_NODE_SCRATCH/.udocker"
else
    _NODE_SCRATCH="$(dirname "$UDOCKER_DIR")"
fi
mkdir -p "$UDOCKER_DIR" || exit 1

# ── per-node setup: install tools + import + create + F3 (gated + flock) ──────
# /tmp is wiped per allocation, so the container is rebuilt per node — like proot's
# extraction but heavier (import-copy + extract + patchelf). Gated on a marker
# written only after F3 completes; flock serializes a batch pre-warm against an
# eager connect. F3 patchelf's the binaries to absolute container paths, so it must
# be redone per node (udocker F-mode containers aren't portable across hosts).
F3_READY="$UDOCKER_DIR/.f3-ready"
# Re-run setup when the marker is missing OR the rootfs tar is newer than it: a
# rebuilt image must replace this node's container (same stale-sandbox lesson as
# proot — a new tar on /work or $HOME wouldn't otherwise be picked up until /tmp
# is wiped). The setup below rm's any existing container/image first, so this is
# also the auto-update path after build_container.sh ships a new tar.
_need_setup() { [ ! -e "$F3_READY" ] || [ "$FINTECH_TAR" -nt "$F3_READY" ]; }
if _need_setup; then
    [ -f "$FINTECH_TAR" ] || { err "rootfs tarball not found at $FINTECH_TAR"; exit 1; }
    exec 9>"$UDOCKER_DIR/.setup.lock"
    command -v flock >/dev/null 2>&1 && flock 9
    if _need_setup; then   # re-check under the lock
        err "udocker setup on $(hostname -s) (install + import + create + F3; tar=$FINTECH_TAR) ..."
        udocker install 1>&2 || { err "udocker install (tools) failed"; exit 1; }
        udocker rm  "$UDOCKER_CONTAINER" >/dev/null 2>&1 || true   # clean partial state
        udocker rmi "$UDOCKER_IMAGE"      >/dev/null 2>&1 || true
        udocker import "$FINTECH_TAR" "$UDOCKER_IMAGE" 1>&2 || { err "import failed"; exit 1; }
        udocker create --name="$UDOCKER_CONTAINER" "$UDOCKER_IMAGE" 1>&2 || { err "create failed"; exit 1; }
        udocker setup --execmode=F3 "$UDOCKER_CONTAINER" 1>&2 || { err "F3 setup failed"; exit 1; }
        : > "$F3_READY"
        err "udocker setup complete."
    fi
    exec 9>&-
fi

# Resolve the container ROOT (host path) for the fakechroot-lib hint + slurm dirs.
_root="$(udocker inspect -p "$UDOCKER_CONTAINER" 2>/dev/null || true)"

# Defensive hook: if a glibc-2.39-matched libfakechroot is ever dropped at
# /opt/fakechroot/lib (would silence the "OS might not be supported" warning and
# fix NSS/uid resolution), use it. None currently exists — the udocker fakechroot
# fork won't compile on glibc 2.39 and no bundled variant resolves NSS here
# (verified 2026-06-24) — so this is a no-op today and the bare-uid id/whoami is
# an accepted cosmetic limitation.
if [ -n "$_root" ] && [ -f "$_root/opt/fakechroot/lib/libfakechroot.so" ]; then
    export UDOCKER_FAKECHROOT_SO="$_root/opt/fakechroot/lib/libfakechroot.so"
fi

# ── Claude Code config dir → node-local /tmp (ported verbatim from proot_dev.sh)
# ~/.claude is fsync/write-heavy and the network home is slow; relocate the whole
# tree to fast local disk, seed from $HOME on first use per node, and sync the
# persistent bits (auth + history) back on exit. Passed into the container via
# --env=CLAUDE_CONFIG_DIR below; /tmp is bound 1:1 so the path resolves inside.
CC_HOME="$HOME/.claude"
CC_LOCAL="$_NODE_SCRATCH/.claude"
if [ ! -d "$CC_LOCAL" ]; then
    mkdir -p "$CC_LOCAL" 2>/dev/null || true
    [ -d "$CC_HOME" ] && cp -a "$CC_HOME/." "$CC_LOCAL/" 2>/dev/null
    [ -f "$HOME/.claude.json" ] && cp -a "$HOME/.claude.json" "$CC_LOCAL/.claude.json" 2>/dev/null
fi
_claude_sync_back() {
    [ -d "$CC_LOCAL" ] || return 0
    mkdir -p "$CC_HOME" 2>/dev/null
    local ok=1
    if command -v rsync >/dev/null 2>&1; then
        rsync -a --update --exclude='shell-snapshots' --exclude='statsig' \
              --exclude='.claude.json' --exclude='*.sock' "$CC_LOCAL/" "$CC_HOME/" 2>/dev/null || ok=0
    else
        local item
        for item in .credentials.json projects todos history history.jsonl; do
            [ -e "$CC_LOCAL/$item" ] && { cp -a "$CC_LOCAL/$item" "$CC_HOME/" 2>/dev/null || ok=0; }
        done
    fi
    [ -f "$CC_LOCAL/.claude.json" ] && { cp -a "$CC_LOCAL/.claude.json" "$HOME/.claude.json" 2>/dev/null || ok=0; }
    [ "$ok" -eq 1 ] || err "warning: Claude config sync-back to $HOME was incomplete."
}
trap _claude_sync_back EXIT

# ── volumes (proot binds -> udocker -v). udocker provides /proc /dev /sys itself,
# so those drop out; we bind the data dirs + /tmp (carries the nvim->/tmp and
# Claude->/tmp redirects) + the network/time /etc files. --hostauth (below) maps
# the host user, so /etc/passwd,group are handled there.
VOLS=()
for _v in "/tmp" "/run" "$HOME" "/work/g/$USER" "/work_bgfs/g/$USER" "/shares"; do
    [ -e "$_v" ] && VOLS+=( -v "$_v:$_v" )
done
for _f in /etc/resolv.conf /etc/hosts /etc/localtime; do
    [ -e "$_f" ] && VOLS+=( -v "$_f:$_f" )
done

# (SLURM client passthrough removed — host RHEL7 squeue/sacct can't run under F3's
#  glibc 2.39, and ssh-to-host is blocked by the getpwuid gap. Run SLURM commands
#  on the CIRCE login node, or a host shell: ssh -J circe <node>.)

# Runtime env: real HOME (image default is /home/gson — would break tools that
# write to ~, e.g. starship's cache), zsh as SHELL, the Claude redirect, and the
# no-telemetry flag.
# Note: under F3/fakechroot, glibc NSS (getpwuid/getpwnam) can't resolve our uid
# to a name, so `id -un`/`whoami` show the bare number. This is an ACCEPTED
# cosmetic limitation — a glibc-2.39-matched libfakechroot would fix it, but the
# udocker fakechroot fork won't compile on glibc 2.39 and no bundled variant
# works (verified 2026-06-24). We export USER/LOGNAME so the prompt and tools
# that read them still show the right name; functionally everything works.
ENVS=( --env="HOME=$HOME"
       --env="USER=$USER"
       --env="LOGNAME=$USER"
       --env="SHELL=/bin/zsh"
       --env="CLAUDE_CONFIG_DIR=$CC_LOCAL"
       --env="CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1" )

# ── launch. Default to interactive zsh; forward args. NOT exec'd so the EXIT trap
# (Claude sync-back) runs after the shell quits. --workdir starts in the real
# $HOME. No --hostauth: the host uses LDAP (no local /etc/passwd line), so it
# can't map our uid — the getent append into the container's NSS files (setup,
# above) is what makes id/whoami/the prompt resolve.
[ "$#" -eq 0 ] && set -- -i
udocker run --workdir="$HOME" "${ENVS[@]}" "${VOLS[@]}" \
    "$UDOCKER_CONTAINER" /bin/zsh "$@"
exit $?
