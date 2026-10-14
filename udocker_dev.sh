#!/bin/bash
# udocker_dev.sh — launch the fintech-tools container via udocker (Fakechroot/F3).
#
# The container runtime for CIRCE. Compute nodes can't run Singularity/Apptainer
# (/apps nosuid + user namespaces disabled), so we use udocker's Fakechroot (F3)
# engine: it intercepts libc filesystem calls via LD_PRELOAD (pathname
# translation, no ptrace), which is ~4-7x lower per-op overhead than the ptrace
# tax that dominated our metadata-heavy workload (nvim plugin loads, Claude fsync).
# Measured inside the container 2026-06-23 on mdc-1057-13-13:
#   stat 0.005   read 0.007   create 0.017   fsync 0.225 ms/op
# => LazyVim cold start ~5.7x faster. All tools work, incl. Go statics fzf/lazygit.
#
# Imports the flat rootfs tar from build_container.sh. Args forward to zsh
# (e.g. `udocker_dev.sh -i -c '...'`).
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

# rootfs tar on the persistent home (build_container.sh ships it to ~/fintech-sb).
FINTECH_TAR="${FINTECH_TAR:-$HOME/fintech-sb/fintech-rootfs.tar}"

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
# /tmp is wiped per allocation, so the container is rebuilt per node (import-copy
# + extract + patchelf); flock serializes a batch pre-warm against an eager
# connect. F3 patchelf's the binaries to absolute container paths, so it must be
# redone per node (udocker F-mode containers aren't portable across hosts).
#
# Setup is gated on udocker's OWN state, not on a marker file we write. The old
# gate keyed on $UDOCKER_DIR/.f3-ready, which was written once and never read
# again — so the atime reaper below eventually pruned it, and its absence forced
# a full teardown + 4.9 GB re-import + F3 patch on a container that was perfectly
# good. Everything checked here is state udocker maintains for its own purposes,
# so there is nothing extra to keep alive.
#
# `udocker inspect` costs a python start (~0.5 s), so resolve the ROOT ONCE here
# and reuse it below; the warm path pays exactly one inspect, as it always did.
_root="$(udocker inspect -p "$UDOCKER_CONTAINER" 2>/dev/null || true)"

_container_ready() {
    [ -n "$_root" ] && [ -d "$_root" ] || return 1
    local cdir="${_root%/ROOT}"
    # `udocker setup --execmode=F3` records the mode here, and only writes
    # ld.so.orig (the saved original loader) once the patch has actually run —
    # together they distinguish a finished container from a half-built one.
    [ "$(cat "$cdir/execmode" 2>/dev/null)" = "F3" ] || return 1
    [ -s "$cdir/ld.so.orig" ] || return 1
    # Cheap spot-check that the ROOT itself hasn't been gutted. Deliberately not
    # exhaustive — a full 4.5 GB verify per launch would cost far more than the
    # re-setup it avoids.
    [ -x "$_root/bin/zsh" ] && [ -x "$_root/usr/bin/git" ] || return 1
    # Stale if the rootfs tar was rebuilt after this container was created:
    # container.json is written by `udocker create`, so it dates the container.
    # This is the auto-update path after build_container.sh ships a new tar.
    # Compares MTIMEs, which is why the reaper defence below uses `touch -a`.
    ! [ "$FINTECH_TAR" -nt "$cdir/container.json" ]
}
_need_setup() { ! _container_ready; }

if _need_setup; then
    [ -f "$FINTECH_TAR" ] || { err "rootfs tarball not found at $FINTECH_TAR"; exit 1; }
    exec 9>"$UDOCKER_DIR/.setup.lock"
    command -v flock >/dev/null 2>&1 && flock 9
    # Re-resolve before re-checking: whoever held the lock may have just built a
    # container under a NEW id, which our pre-lock $_root knows nothing about.
    # Without this the re-check inspects the old id, fails, and we rebuild the
    # container that was just built — exactly what the lock exists to prevent.
    _root="$(udocker inspect -p "$UDOCKER_CONTAINER" 2>/dev/null || true)"
    if _need_setup; then   # re-check under the lock
        err "udocker setup on $(hostname -s) (install + import + create + F3; tar=$FINTECH_TAR) ..."
        udocker install 1>&2 || { err "udocker install (tools) failed"; exit 1; }
        # ── heal a HALF-REAPED udocker tools tree ────────────────────────────
        # The tools live under $UDOCKER_DIR on /tmp, and CIRCE age-prunes /tmp by
        # ATIME (the same reaper that guts the nvim plugin store — see the nvim()
        # wrapper in .zshrc). Everything the runtime touches on each launch keeps
        # its atime fresh and survives; everything used only at SETUP time does
        # not. Observed 2026-08-10: bin/ and doc/ emptied completely and lib/ was
        # down to the ONE libfakechroot the running container had loaded, out of
        # ~100. The next setup then died with "Error: patchelf executable not
        # found" -> "F3 setup failed".
        #
        # Plain `udocker install` cannot recover from this: it finds the surviving
        # lib/VERSION, decides the tools are present, and no-ops. Only --force
        # re-extracts. So check for the binary F3 actually needs and force a
        # reinstall when it's gone. Cheap: this runs only on the setup path, which
        # is already the slow once-per-node branch.
        _patchelf="$UDOCKER_DIR/bin/patchelf-$(uname -m)"
        if [ ! -x "$_patchelf" ]; then
            err "udocker tools incomplete (no $(basename "$_patchelf")) — /tmp reaper; forcing reinstall"
            udocker install --force 1>&2 || { err "udocker install --force failed"; exit 1; }
            [ -x "$_patchelf" ] || { err "patchelf still missing after --force"; exit 1; }
        fi
        udocker rm  "$UDOCKER_CONTAINER" >/dev/null 2>&1 || true   # clean partial state
        udocker rmi "$UDOCKER_IMAGE"      >/dev/null 2>&1 || true
        udocker import "$FINTECH_TAR" "$UDOCKER_IMAGE" 1>&2 || { err "import failed"; exit 1; }
        udocker create --name="$UDOCKER_CONTAINER" "$UDOCKER_IMAGE" 1>&2 || { err "create failed"; exit 1; }
        udocker setup --execmode=F3 "$UDOCKER_CONTAINER" 1>&2 || { err "F3 setup failed"; exit 1; }
        err "udocker setup complete."
    fi
    exec 9>&-
    # The container was recreated under a new id — re-resolve the ROOT.
    _root="$(udocker inspect -p "$UDOCKER_CONTAINER" 2>/dev/null || true)"
fi

# ── a multiplexer server still running on a ROOT that setup replaced ─────────
# Re-setup (a new tar from build_container.sh, or a ROOT the reaper gutted past
# the checks above) deletes the old ROOT under any herdr/tmux server started
# from it. The server keeps running, but every pane it spawns preloads a
# libfakechroot that is gone and lands on the host — and `herdr` / `tm` would
# reattach straight to it. Its binary then shows as "(deleted)" in /proc.
# Warn, never kill: its panes may hold work in flight. Stopping a herdr server
# costs little — it saves the layout to ~/.config/herdr/session.json on $HOME
# (out of the reaper's and the re-setup's reach) and restores it, Claude
# conversations included, when the next server starts. One pgrep per connect.
for _p in $(pgrep -u "$USER" -x 'herdr|tmux: server' 2>/dev/null); do
    case "$(readlink "/proc/$_p/exe" 2>/dev/null)" in
        "$UDOCKER_DIR"/*' (deleted)')
            err "a herdr/tmux server from the replaced image is still running (pid $_p); its new panes will fail."
            err "  stop it before reattaching: herdr server stop (layout restores on the next herdr), tmux kill-server, or kill $_p"
            break ;;
    esac
done

# ── keep the /tmp reaper off the setup-only files ────────────────────────────
# /tmp is mounted relatime and CIRCE prunes it by ATIME: files the runtime opens
# on every launch stay fresh and survive, files touched only during setup age out.
# That is how bin/ lost patchelf entirely and lib/ went from ~185 entries to the
# single libfakechroot the running container had loaded (2026-08-10) — which then
# made the next setup fail outright with "patchelf executable not found".
#
# These are a few hundred small files; refreshing their atime costs milliseconds
# and keeps a future re-setup able to run at all. `-a` so ONLY atime moves —
# container.json's mtime is the staleness signal in _container_ready above, and
# bumping it would make a newly shipped tar look older than the container and
# never get picked up.
touch -a "$UDOCKER_DIR"/bin/* "$UDOCKER_DIR"/lib/* 2>/dev/null || true
[ -n "$_root" ] && touch -a "${_root%/ROOT}"/execmode "${_root%/ROOT}"/container.json \
    "${_root%/ROOT}"/ld.so.orig "${_root%/ROOT}"/ld.lib.dirs "${_root%/ROOT}"/ld.so.path 2>/dev/null || true

# ── ...and off the nvim plugin store ─────────────────────────────────────────
# Same reaper, different victim. ~/.local/share/nvim is symlinked onto node-local
# /tmp for startup speed, so the COLD plugin source files age out while each
# plugin's compact .git survives — LazyVim then believes the plugin is installed
# and require() fails ("No specs found for module lazyvim.plugins"). .zshrc's
# _nvim_heal repairs that after the fact via `git checkout -f`; this prevents it
# happening at all, which is the cheaper half of the deal. Covers mason's LSP
# binaries in the same sweep — they are just as cold and just as reapable.
#
# Measured 10,421 files in 0.115s on mdc-1057-13-13, so it runs synchronously
# rather than backgrounded; once per session is ample against a 30-day window.
# GNU find is on the HOST here (this runs before the container starts), so the
# `-exec ... +` batching is safe.
_nvim_store="$_NODE_SCRATCH/.local/share/nvim"
# Excludes lazy/.reap-sentinel by name: _nvim_heal in .zshrc detects a reap by
# that file being the COLDEST thing in the store, and sweeping it along with
# everything else would keep it fresh forever and neuter the detector.
[ -d "$_nvim_store" ] && find "$_nvim_store" -type f ! -name '.reap-sentinel' \
    -exec touch -a {} + 2>/dev/null || true

# ── zero-byte git metadata in the plugin store ───────────────────────────────
# Not the reaper: the reaper deletes, it never truncates. A 0-byte ref is never
# valid. git reads it as the null oid, and lazy.nvim's fetch then dies for that
# whole plugin ("fetch | fatal: bad object refs/heads/main"), on every :Lazy
# sync. Found 2026-10-14 in plenary.nvim, nvim-lspconfig and
# markdown-preview.nvim: stray empty refs/heads/main files written by some bulk
# operation on 2026-08-03 18:41 (the same minute left other plugins' files
# untracked in 21 repos), failing silently for two months.
#
# Pure filesystem, no git (the host's 1.8.3 can't read lazy's repos): one find
# over the ~45 small .git trees, ~10 ms, silent unless it repairs something.
#   * empty ref, or empty pack .idx/.pack/.rev: deleted. It holds nothing, so
#     nothing is lost (packs: same reasoning as _nvim_heal in .zshrc). Never
#     .promisor/.keep, which are legitimately empty.
#   * empty HEAD, or an empty ref that HEAD points at: the checkout has no
#     commit left, so the plugin dir goes and lazy re-clones it at the
#     lazy-lock.json commit on the next nvim start.
_nvim_git_repair() {
    local lazy="$_nvim_store/lazy" f g repo head
    [ -d "$lazy" ] || return 0
    while IFS= read -r f; do
        g="${f%%/.git/*}/.git"; repo="${g%/.git}"
        [ -d "$repo" ] || continue   # already removed earlier in this pass
        head="$(cat "$g/HEAD" 2>/dev/null)"
        if [ -z "$head" ] || [ "$f" = "$g/${head#ref: }" ]; then
            err "nvim plugin ${repo##*/}: no commit left (empty ${f#"$g"/}); removed, lazy re-clones it on the next nvim start"
            rm -rf -- "$repo"
        else
            err "nvim plugin ${repo##*/}: removed empty ${f#"$g"/} (it made :Lazy sync fail)"
            rm -f -- "$f"
        fi
    done < <(find "$lazy"/*/.git -type f -empty \( -path '*/.git/HEAD' -o -path '*/.git/refs/*' \
                 -o -path '*/objects/pack/*.idx' -o -path '*/objects/pack/*.pack' \
                 -o -path '*/objects/pack/*.rev' \) 2>/dev/null)
}
_nvim_git_repair

# ── ...and off everything else in the ROOT: repair, then prevent ─────────────
# The two sweeps above cover the paths whose loss we have already been bitten
# by. The reaper does not respect that list: it takes whatever went cold, and
# the ROOT is full of files no launch ever opens — the python stdlib's *.py
# (CPython reads __pycache__/*.pyc and only stat()s the source, and stat does
# not refresh atime), zsh's ~960 completion functions, TinyTeX, node_modules,
# R's system library. Each surfaces as an impossible bug in whichever tool
# needed the cold half of its own install; python dying with "no codec search
# functions registered" (2026-08-21) was the worst of them, because it takes the
# interpreter down before it can even report which module is missing.
#
# This runs on EVERY connect — connect_nvim.sh execs ~/bin/udocker_dev.sh on the
# node each time, reattach included — and before the git-static / gh / DNS
# blocks below, which read files out of the ROOT themselves.
#
# Two halves, in order of importance:
#   PREVENT — the background `touch -a` over the whole ROOT. Nothing ever goes
#             cold, so unguarded victims (TinyTeX, R, man pages) are covered
#             too. This is the actual fix; connect at least every ~10 days and
#             the reaper never reaches anything.
#   REPAIR  — the guard table, for the window where you did NOT connect for ten
#             days. Probes by file COUNT, because a reap eats a directory from
#             the cold end and a surviving __init__.py proves nothing.
# A new victim is one new row in _REAP_GUARDS, never a bespoke fix.
_REAP_GUARDS=(
    "usr/lib/python3.13/encodings|*.py|40|usr/lib/python3.13"
    "usr/lib/python3.13/asyncio|*.py|20|usr/lib/python3.13"
    "usr/lib/python3.13|*.py|100|usr/lib/python3.13"
    "usr/lib/python3.12/encodings|*.py|40|usr/lib/python3.12"
    "usr/lib/python3.12|*.py|100|usr/lib/python3.12"
    "usr/share/zsh/functions/Completion/Unix|_*|40|usr/share/zsh/functions"
    "usr/lib/node_modules/npm/lib|*.js|5|usr/lib/node_modules"
    # nvim's OWN runtime, not the plugin store — reaped on this node by
    # 2026-08-21 while lazy/ (swept since June) was untouched, so LazyVim looked
    # broken when the missing files were vim.health/filetype.lua/syntax/*.vim.
    # Symptom: "no file './vim.so'" tracebacks out of lazy.nvim + "E216: No such
    # group or event: filetypedetect". Survivors were lua/vim/{lsp,uri,glob,re},
    # i.e. exactly what an LSP session opens.
    "usr/local/share/nvim/runtime/lua/vim|*.lua|20|usr/local/share/nvim"
    "usr/local/share/nvim/runtime/syntax|*.vim|200|usr/local/share/nvim"
    "usr/local/share/nvim/runtime/ftplugin|*.vim|100|usr/local/share/nvim"
    # R's system library — holds `languageserver`, so a reap here kills nvim's R
    # LSP with no obvious connection to R. Was down to 1 of 43 packages.
    "usr/local/lib/R/site-library|*|20|usr/local/lib/R/site-library"
    # TinyTeX: thousands of .sty/.cls that only a compile ever opens.
    "opt/TinyTeX/texmf-dist/tex/latex|*|100|opt/TinyTeX"
)

# ── PT_INTERP: put back the loader path a tar restore just threw away ────────
# Second-order damage from the repair above, and the reason it lives here rather
# than in the image. F3 does not chroot; it rewrites every ELF's PT_INTERP to the
# ABSOLUTE HOST path of the container's own glibc-2.39 loader, once, at container
# setup:
#     /usr/bin/node  ->  <ROOT>//lib64/ld-linux-x86-64.so.2   (patched)
#     tree-sitter    ->  /lib64/ld-linux-x86-64.so.2          (stock)
# The kernel resolves PT_INTERP against the REAL host root before any LD_PRELOAD
# exists, so a stock header hands the binary to RHEL7's glibc-2.17 loader, which
# is then given the container's 2.39 libc and dies with the familiar
#   relocation error: ... libc.so.6: symbol _dl_find_dso_for_object,
#   version GLIBC_PRIVATE not defined in file ld-linux-x86-64.so.2
# libfakechroot cannot help: it is an LD_PRELOAD shim and execve's PT_INTERP
# lookup happens before it is loaded. This is the THIRD member of that error
# family — static binary breaks its dynamic children (git, gh), unpatched
# dynamic binary breaks itself (claude), and now: a patched binary REVERTED to
# stock. Same message, three different causes.
#
# `fintech-rootfs.tar` is the pristine image, so every binary in it carries the
# stock interpreter. `tar x` above therefore un-patches whatever it restores,
# and the guarded subtrees are exactly where the non-apt binaries live:
# usr/lib/node_modules (tree-sitter-cli, claude) and
# usr/local/lib/R/site-library (processx's px/supervisor/sock, ps's px, which
# callr and Quarto rendering sit on top of). Diagnosed 2026-09-03 after
# tree-sitter failed to run: every unpatched binary on the node was inside one
# of those two restore targets, and the R library had been restored on
# 2026-08-21 with 1 of 43 packages surviving.
#
# So: re-point anything with a stock interpreter, right after the restore that
# reverted it, and once more as a standing sweep for a hand-installed
# `npm -g` / `install.packages()` that arrives after F3's one-shot pass.
_INTERP_DIRS=(
    usr/lib/node_modules
    usr/local/lib/node_modules
    usr/local/lib/R/site-library
    usr/local/bin
    usr/local/libexec
)
_INTERP_HOST_LDSO="/lib64/ld-linux-x86-64.so.2"   # the stock header we look for
_interp_patchelf=""; _interp_ldso=""; _interp_have_file=""

_interp_init() {
    [ -n "$_root" ] || return 1
    # udocker's own bundled patchelf — the same one F3 patches with, and the one
    # the sweep at the top of this script keeps alive against the reaper.
    _interp_patchelf="$UDOCKER_DIR/bin/patchelf-$(uname -m)"
    [ -x "$_interp_patchelf" ] || return 1
    [ -e "$_root$_INTERP_HOST_LDSO" ] || return 1
    # Double slash on purpose: byte-identical to what F3 writes, so a patched
    # binary here is indistinguishable from one patched at setup.
    _interp_ldso="$_root/$_INTERP_HOST_LDSO"
    [ -n "$_interp_have_file" ] || \
        { command -v file >/dev/null 2>&1 && _interp_have_file=1 || _interp_have_file=0; }
    return 0
}

# Print every ELF under $1 whose PT_INTERP is still the bare host path.
# `file` reports the interpreter itself, so ONE process classifies the whole
# tree — that matters because node_modules is tens of thousands of files and
# this runs on every connect. A patched binary reads "interpreter /tmp/...",
# so the fixed string below matches the broken set and nothing else.
_interp_stock_elfs() {
    if [ "$_interp_have_file" = "1" ]; then
        find "$1" -type f -perm -u+x -print0 2>/dev/null \
            | xargs -0 -r file -h -- 2>/dev/null \
            | grep -F "interpreter $_INTERP_HOST_LDSO" \
            | sed 's/:[[:space:]]*ELF .*//'
    else
        # No `file` on this host: ask patchelf per candidate. Correct, slower.
        find "$1" -type f -perm -u+x -print 2>/dev/null | while IFS= read -r _f; do
            [ "$("$_interp_patchelf" --print-interpreter "$_f" 2>/dev/null)" \
                = "$_INTERP_HOST_LDSO" ] && printf '%s\n' "$_f"
        done
    fi
}

_interp_repair() {                       # $@ = subpaths under the ROOT
    _interp_init || return 0
    local sub f sz n=0
    for sub in "$@"; do
        [ -d "$_root/$sub" ] || continue
        while IFS= read -r f; do
            [ -n "$f" ] || continue
            case "$f" in
                # Owned by the claude wrapper further down, which starts the Bun
                # binary through the container loader WITHOUT touching the file.
                # A Bun executable hides a ~290 MB payload behind offsets stored
                # in itself; patchelf grows and re-lays-out the file to fit a
                # longer interpreter string, which is a good way to corrupt it.
                # The wrapper already makes this one work — do not trade a
                # working binary for a risky rewrite.
                */claude-code/bin/claude.exe|*/claude-code-linux-x64/claude) continue ;;
            esac
            # Everything else is patched regardless of size, on purpose. A stock
            # interpreter inside the ROOT means the binary CANNOT run here at
            # all, so a rewrite that goes wrong costs nothing that was working;
            # only claude, above, is already working and has something to lose.
            # A big one is slow (patchelf re-lays-out the whole file), so say so
            # rather than letting a connect look hung.
            sz=$(stat -c %s "$f" 2>/dev/null || stat -f %z "$f" 2>/dev/null || echo 0)
            [ "$sz" -gt 104857600 ] \
                && err "PT_INTERP: ${f#"$_root"/} is $((sz / 1048576)) MB — patching, this takes a moment"
            if "$_interp_patchelf" --set-interpreter "$_interp_ldso" "$f" 2>/dev/null; then
                n=$((n + 1))
            else
                err "PT_INTERP: FAILED to patch ${f#"$_root"/}"
            fi
        done <<< "$(_interp_stock_elfs "$_root/$sub")"
    done
    [ "$n" -gt 0 ] && err "PT_INTERP: re-pointed $n binaries at the container loader"
    return 0
}

# Standing sweep, for binaries that arrived after F3's one-shot pass. Gated on a
# watched directory being newer than the stamp: `npm -g install` and
# `install.packages()` both bump the mtime of the root they write into, so the
# usual connect costs a handful of stat()s and nothing more. A tar restore does
# NOT reliably trip it (tar puts the archived mtimes back), which is why
# _reap_repair calls _interp_repair directly instead of relying on this.
# The stamp is written last, so the repair's own mtime churn cannot re-arm it.
_interp_sweep() {
    [ -n "$_root" ] || return 0
    local stamp="$_root/.interp-sweep-stamp" d fresh=0
    if [ "${1:-}" != "--force" ] && [ -f "$stamp" ]; then
        for d in "${_INTERP_DIRS[@]}"; do
            [ -d "$_root/$d" ] && [ "$_root/$d" -nt "$stamp" ] && { fresh=1; break; }
        done
        [ "$fresh" -eq 1 ] || return 0
    fi
    _interp_repair "${_INTERP_DIRS[@]}"
    : > "$stamp"
}

# Cost on a healthy ROOT: one `find -maxdepth 1 | head` per row — a dozen
# directory reads that stop early, ~0.02s, and flat in the size of the ROOT.
# Counts entries, not just files: R packages and TinyTeX bundles are directories.
_reap_repair() {
    [ -n "$_root" ] || return 0
    local g dir glob min sub n hit=0
    local -a damaged=()
    for g in "${_REAP_GUARDS[@]}"; do
        IFS='|' read -r dir glob min sub <<< "$g"
        [ -d "$_root/$dir" ] || continue       # absent from this image — not ours
        n=$(find "$_root/$dir" -mindepth 1 -maxdepth 1 -name "$glob" 2>/dev/null \
            | head -n "$((min + 1))" | wc -l | tr -d ' ')
        [ "$n" -ge "$min" ] && continue
        err "/tmp reaper: $dir/$glob has $n files, expected >= $min"
        case " ${damaged[*]:-} " in *" $sub "*) ;; *) damaged+=("$sub") ;; esac
        hit=1
    done
    [ "$hit" -eq 1 ] || return 0
    if [ ! -f "$FINTECH_TAR" ]; then
        err "/tmp reaper: rootfs tar missing at $FINTECH_TAR — cannot restore"
        return 1
    fi
    for sub in "${damaged[@]}"; do
        err "/tmp reaper: restoring $sub from the rootfs tar ..."
        if tar xf "$FINTECH_TAR" -C "$_root" "$sub" 2>/dev/null; then
            # The tar is the pristine image, so everything just restored carries
            # the STOCK interpreter and would die under the host loader. Put F3's
            # patch back on exactly what we replaced. See the PT_INTERP block above.
            _interp_repair "$sub"
        else
            err "/tmp reaper: restore of $sub FAILED (stale tar?)"
        fi
    done
}

# Only atime moves (-a): container.json's mtime is the staleness signal for a
# newly shipped tar in _container_ready above and must not be disturbed.
# Backgrounded and rate-limited to 12h — a few seconds of find over a 4.5 GB
# ROOT, against a ~10-day window, so no connect should ever wait on it. stdin
# from /dev/null as well as stdout/stderr: connect_nvim.sh arrives over `ssh
# -tt`, and a background child still holding the session fds keeps the SSH
# channel from closing.
_reap_sweep() {
    [ -n "$_root" ] || return 0
    local stamp="$_root/.atime-sweep-stamp"
    [ -n "$(find "$stamp" -mmin -720 2>/dev/null)" ] && return 0
    : > "$stamp"
    nohup nice -n 19 find "$_root" -xdev -type f -exec touch -a {} + \
        </dev/null >/dev/null 2>&1 &
}

_reap_repair
_interp_sweep
_reap_sweep

# `udocker_dev.sh --doctor` — check/repair the ROOT and exit, without starting a
# container. For diagnosing from a node shell; a plain reconnect does the same.
if [ "${1:-}" = "--doctor" ]; then
    _reap_repair && err "ROOT $_root: reaper guards satisfied"
    _rc=$?
    # Unconditional, ignoring the mtime gate: on a node you are already
    # suspicious of, scan every watched tree for stock interpreters.
    _interp_sweep --force
    exit $_rc
fi

# Defensive hook: if a glibc-2.39-matched libfakechroot is ever dropped at
# /opt/fakechroot/lib (would silence the "OS might not be supported" warning and
# fix NSS/uid resolution), use it. None currently exists — the udocker fakechroot
# fork won't compile on glibc 2.39 and no bundled variant resolves NSS here
# (verified 2026-06-24) — so this is a no-op today and the bare-uid id/whoami is
# an accepted cosmetic limitation.
if [ -n "$_root" ] && [ -f "$_root/opt/fakechroot/lib/libfakechroot.so" ]; then
    export UDOCKER_FAKECHROOT_SO="$_root/opt/fakechroot/lib/libfakechroot.so"
fi

# ── Expose zoxide→fzf on a bind-identical path (yazi `Z` fix) ─────────────────
# udocker's fakechroot can't translate the exec() one CONTAINER binary makes to
# launch ANOTHER: posix_spawn (Rust) and Go's runtime exec bypass the LD_PRELOAD
# execve hook, so the child is resolved/run against the *host* root instead of the
# container's. Yazi's `Z` (zoxide → fzf) hit this and failed with "could not find
# fzf". Fix: drop the STATIC tools onto $HOME/.local/bin — bind-mounted 1:1
# (-v $HOME:$HOME, so host path == container path) and already on PATH — so the
# escaped lookup finds a host-valid, static binary (fzf=Go-static, zoxide=musl-
# static). Copy not symlink: a symlink would point into the node-local
# $UDOCKER_DIR ROOT and go stale next node. Refreshed when the rootfs tar is newer.
# (fd is intentionally NOT exposed: fzf uses its built-in walker instead of
# shelling out to fd, so nothing escapes to fd — see zshenv FZF_DEFAULT_OPTS.)
if [ -n "$_root" ]; then
    _bindbin="$HOME/.local/bin"
    mkdir -p "$_bindbin" 2>/dev/null
    for _t in fzf zoxide; do
        _src="$_root/usr/local/bin/$_t"
        [ -e "$_src" ] || continue
        if [ ! -e "$_bindbin/$_t" ] || [ "$_src" -nt "$_bindbin/$_t" ] \
           || [ "$FINTECH_TAR" -nt "$_bindbin/$_t" ]; then
            cp -fL "$_src" "$_bindbin/$_t.tmp.$$" 2>/dev/null \
                && chmod +x "$_bindbin/$_t.tmp.$$" 2>/dev/null \
                && mv -f "$_bindbin/$_t.tmp.$$" "$_bindbin/$_t" 2>/dev/null
            rm -f "$_bindbin/$_t.tmp.$$" 2>/dev/null
        fi
    done
fi

# ── Host-runnable static git for lazygit's escape — scoped to lazygit ONLY ───
# lazygit is Go; under F3 its exec() of `git` escapes fakechroot onto the RHEL7
# host (same escape as yazi's Z→fzf above). There the dynamic container git
# can't run and the host git is 1.8.3.1 — below lazygit's 2.32 floor, so it
# refuses to start ("Git version must be at least 2.32.0"). The image ships a
# FULLY STATIC git at /opt/git-static (no PT_INTERP -> runs as a bare host
# process too). Deploy the whole bundle (git needs its libexec/templates/CA, not
# just one binary) to the bind-identical, PERSISTENT $HOME/.local/git-static
# (host path == container path). cp -a (not a symlink into the node-local ROOT)
# so it survives /tmp wipes; RUNTIME_PREFIX makes git find its libexec relative
# to the bundle, so the path is self-contained wherever it lands. Refreshed when
# the rootfs tar is newer.
#
# IMPORTANT: do NOT put this static git on PATH as the general `git`. A static
# binary is immune to LD_PRELOAD, so udocker's libfakechroot never loads into it;
# the children it spawns IN-CONTAINER (credential helper /bin/sh, pager, hooks)
# then get a mismatched glibc loader and die with
# "relocation error: ... _dl_find_dso_for_object ... not defined in ld-linux"
# (and git silently falls back to prompting for a password). The DYNAMIC
# /usr/bin/git (2.43, runs with libfakechroot) handles children correctly, so it
# stays the in-container git. The static git is host-runnable but only needed by
# lazygit's escape — so we hand it to lazygit ALONE via a wrapper at
# ~/.local/bin/lazygit (first on PATH, so even nvim-launched lazygit hits it)
# that prepends the static-git dir to PATH before exec'ing the real lazygit.
# (Proven 2026-06-29: dynamic git auths fine; static git breaks every child.)
if [ -n "$_root" ] && [ -d "$_root/opt/git-static" ]; then
    _gitdst="$HOME/.local/git-static"
    if [ ! -x "$_gitdst/bin/git" ] || [ "$FINTECH_TAR" -nt "$_gitdst/bin/git" ]; then
        rm -rf "$_gitdst.tmp.$$" 2>/dev/null
        if cp -a "$_root/opt/git-static" "$_gitdst.tmp.$$" 2>/dev/null; then
            rm -rf "$_gitdst" 2>/dev/null
            mv "$_gitdst.tmp.$$" "$_gitdst" 2>/dev/null
        fi
        rm -rf "$_gitdst.tmp.$$" 2>/dev/null
    fi
    mkdir -p "$HOME/.local/bin" 2>/dev/null
    # Remove the old static-git-on-PATH symlink from earlier versions: it made
    # the in-container `git` the static one and broke credential helpers/pager.
    if [ -L "$HOME/.local/bin/git" ]; then
        case "$(readlink "$HOME/.local/bin/git")" in
            *"/.local/git-static/"*) rm -f "$HOME/.local/bin/git" ;;
        esac
    fi
    # Drop the short-lived ~/.local/bin/lazygit wrapper: /usr/local/bin precedes
    # ~/.local/bin in PATH, so a wrapper there was bypassed (real lazygit won).
    if [ -f "$HOME/.local/bin/lazygit" ] \
       && grep -q 'Auto-generated by udocker_dev.sh' "$HOME/.local/bin/lazygit" 2>/dev/null; then
        rm -f "$HOME/.local/bin/lazygit"
    fi

    # lazygit wrapper, installed IN the container ROOT's /usr/local/bin — which
    # DOES win in PATH, so even nvim-launched lazygit hits it. It prepends the
    # static, host-runnable git for lazygit ONLY (lazygit's Go exec of `git`
    # escapes F3 onto the RHEL7 host, where the dynamic git can't run); the rest
    # of the container keeps using the dynamic /usr/bin/git, whose children work.
    # The real binary is copied aside to lazygit.real (copy, not move, so the
    # original stays runnable if the wrapper write fails). Idempotent; a rebuilt
    # ROOT (fresh tar) ships a plain lazygit, so this re-wraps per node.
    #
    # The wrapper is (re)written whenever it lacks the CURRENT revision marker, so
    # a node that already has an older wrapper picks up changes on the next
    # launch. Keying only on "is lazygit.real missing" (the previous behaviour)
    # froze the wrapper at whatever revision first landed on that node.
    _lgreal="$_root/usr/local/bin/lazygit.real"
    _lgbin="$_root/usr/local/bin/lazygit"
    _lgrev="LG_WRAPPER_REV=3"
    if [ -x "$_gitdst/bin/git" ] && [ -f "$_lgbin" ]; then
        # Stash the real binary once. Guarded, so we never copy a wrapper over it.
        [ -e "$_lgreal" ] || cp -p "$_lgbin" "$_lgreal" 2>/dev/null
        if [ -e "$_lgreal" ] && ! grep -q "$_lgrev" "$_lgbin" 2>/dev/null; then
            cat > "$_lgbin.tmp.$$" <<'LG'
#!/bin/sh
# LG_WRAPPER_REV=3
# Auto-generated by udocker_dev.sh. lazygit (Go) execve()s `git`, which escapes
# udocker's F3 fakechroot onto the RHEL7 host where the dynamic container git
# can't run. Prepend the static, host-runnable git for lazygit ONLY; everything
# else in the container uses the dynamic /usr/bin/git (whose children work).
#
# ── GitHub auth for lazygit ──────────────────────────────────────────────────
# lazygit cannot use a credential helper AT ALL. git launches every helper
# through /bin/sh, and under lazygit's host escape that /bin/sh dies with
# "relocation error: ... _dl_find_dso_for_object ... not defined in ld-linux"
# (host loader + container glibc). Verified for every form: the `store` builtin,
# a `!gh auth git-credential` shell helper, a bare absolute path to a static
# helper binary, and with LD_PRELOAD/LD_LIBRARY_PATH sanitized — all fail. So
# authenticate with NO helper: hand the token to git as an HTTP header.
#
# `http.<url>.extraheader` is used rather than a tokenised
# `url.<...>.insteadOf`, because insteadOf rewrites the URL *before* git records
# it — a `clone` under that config writes the token into the new repo's
# .git/config (verified). extraheader leaves .git/config clean.
#
# Minted at every launch, so it cannot go stale the way ~/.git-credentials did.
# The 077 umask matters: this file holds a live token.
# The config is rewritten from scratch at EVERY launch, so the token can never
# go stale and no old token lingers on disk. The helper reset is unconditional:
# if gh has no token we still need the inherited shell helper gone, otherwise
# lazygit's git spawns /bin/sh and reports a relocation error instead of a clean
# "could not read Username". Only the header section is token-dependent.
LG_CFG="$HOME/.config/git/lazygit.gitconfig"
mkdir -p "$HOME/.config/git" 2>/dev/null
_tok=$(/usr/local/bin/gh auth token 2>/dev/null)
# NB: the redirect lives INSIDE the subshell, after `umask 077`. Written as
# `(umask 077; ...) > "$LG_CFG"` the parent shell creates the file with the
# parent's umask and the token lands group/world-readable.
if (
    umask 077
    {
        cat <<LGCFG
# Auto-generated by the lazygit wrapper at every launch. Holds a live token.
[include]
	path = $HOME/.config/git/container.gitconfig
[credential]
	# container.gitconfig installs the gh shell helper, which cannot run under
	# lazygit's host escape — discard it so git never spawns /bin/sh.
	helper =
LGCFG
        [ -n "$_tok" ] && printf '[http "https://github.com/"]\n\textraheader = AUTHORIZATION: basic %s\n' \
            "$(printf 'x-access-token:%s' "$_tok" | base64 | tr -d '\n')"
    } > "$LG_CFG"
   ) 2>/dev/null; then
    export GIT_CONFIG_GLOBAL="$LG_CFG"
fi
# Without a token, lazygit still runs: every LOCAL op (status, diff, stage,
# commit, log, branch) works fine under the static git. Only push/fetch/pull
# need the header.
exec env PATH="$HOME/.local/git-static/bin:$PATH" /usr/local/bin/lazygit.real "$@"
LG
            chmod +x "$_lgbin.tmp.$$" 2>/dev/null \
                && mv -f "$_lgbin.tmp.$$" "$_lgbin" 2>/dev/null
            rm -f "$_lgbin.tmp.$$" 2>/dev/null
        fi
    fi
fi

# ── gh (GitHub CLI) → give it git (and friends) it can run from the host ─────
# gh is a STATIC Go binary, so — exactly like the static git above, one level up
# — udocker's F3 libfakechroot never loads into it (static binaries ignore
# LD_PRELOAD). Whenever gh runs `git` (repo create/clone/fork/sync, pr checkout,
# repo set-default, ...) its PATH lookup and execve happen against the HOST
# root: it finds RHEL7's /usr/bin/git, which starts under the host glibc-2.17
# loader but inherits F3's LD_LIBRARY_PATH into the container's glibc 2.39:
#   failed to run git: /usr/bin/git: relocation error: <ROOT>//usr/lib/
#   x86_64-linux-gnu/libc.so.6: symbol _dl_find_dso_for_object, version
#   GLIBC_PRIVATE not defined in file ld-linux-x86-64.so.2
# gh used as a leaf (api, auth, pr view, ...) never spawns anything and is fine.
#
# Fix: the wrapper at /usr/local/bin/gh (precedes /usr/bin in PATH) prepends a
# directory of symlinks to the CONTAINER's binaries, by absolute HOST path
# (/tmp is bound 1:1, so that path is valid on both sides). The host kernel then
# execs the container's own git, whose PT_INTERP F3 already patched to
# <ROOT>//lib64/ld-linux-x86-64.so.2; the LD_PRELOAD gh passed along loads
# libfakechroot into it, and from there git is an ordinary in-container process —
# its credential helper (`!gh auth git-credential` via /bin/sh), git-remote-https
# and ssh children all go through fakechroot's execve hook. Verified live
# 2026-09-17 on mdc-1057-13-13: public clone, private clone (helper auth) and
# `gh repo set-default` all work; the same calls without the shim reproduce the
# relocation error.
#
# This replaces the 2026-07-01 wrapper that only rewrote `gh repo clone` into a
# bare `git clone` and so left `gh repo create --clone/--push`, fork, sync and
# `pr checkout` broken. Only ELF targets are linked: a script's `#!/bin/sh`
# would again be resolved on the host. git is the verified one; the editor and
# pager gh launches (pr create/issue create, diff) were equally unrunnable on
# the host before, so linking them can only help.
#
# Written into the node-local ROOT with that ROOT's path baked in; rewritten
# whenever the revision marker or the ROOT path in it is out of date.
if [ -n "$_root" ] && [ -x "$_root/usr/bin/gh" ]; then
    _ghwrap="$_root/usr/local/bin/gh"
    _ghshim="$_root/usr/local/libexec/gh-hostpath"
    _ghrev="GH_WRAPPER_REV=2"
    mkdir -p "$_ghshim" "$_root/usr/local/bin" 2>/dev/null
    for _t in usr/bin/git usr/bin/ssh usr/bin/less usr/local/bin/nvim usr/bin/nvim; do
        _n="${_t##*/}"
        [ -e "$_ghshim/$_n" ] && continue       # nvim: first location wins
        [ -f "$_root/$_t" ] && [ "$(head -c 4 "$_root/$_t" 2>/dev/null)" = "$(printf '\177ELF')" ] \
            && ln -sfn "$_root/$_t" "$_ghshim/$_n" 2>/dev/null
    done
    if ! grep -q "$_ghrev" "$_ghwrap" 2>/dev/null || ! grep -qF "$_ghshim" "$_ghwrap" 2>/dev/null; then
        {
            echo '#!/bin/sh'
            echo "# $_ghrev"
            echo '# Auto-generated by udocker_dev.sh — see the gh block there. gh is static,'
            echo '# so the `git` it spawns is looked up and exec'"'"'d on the HOST. Put the'
            echo "# container's own (PT_INTERP-patched) binaries first, by host path."
            echo "export PATH=\"$_ghshim:\$PATH\""; echo "exec /usr/bin/gh \"\$@\""
        } > "$_ghwrap.tmp.$$" 2>/dev/null \
            && chmod +x "$_ghwrap.tmp.$$" 2>/dev/null \
            && mv -f "$_ghwrap.tmp.$$" "$_ghwrap" 2>/dev/null
        rm -f "$_ghwrap.tmp.$$" 2>/dev/null
    fi
fi

# ── claude → start the Bun binary through the CONTAINER's loader ─────────────
# `claude` died with
#   /usr/bin/claude: relocation error: <ROOT>/usr/lib/x86_64-linux-gnu/libc.so.6:
#   symbol _dl_find_dso_for_object, version GLIBC_PRIVATE not defined in file
#   ld-linux-x86-64.so.2
# Same glibc-mismatch signature as the static git/gh escapes, but a different
# cause, and worth keeping straight. Those are STATIC binaries that bypass
# libfakechroot and break their DYNAMIC children. claude.exe is the opposite: a
# 297 MB DYNAMIC Bun ELF that F3's patchelf pass left alone (nvim's PT_INTERP is
# rewritten to "<ROOT>//lib64/ld-linux-x86-64.so.2"; claude.exe still asks for a
# bare "/lib64/ld-linux-x86-64.so.2"). PT_INTERP is resolved by the KERNEL before
# any LD_PRELOAD exists, and against the HOST root — so RHEL7's glibc-2.17 loader
# starts the process and is then handed the container's glibc-2.39 libc.so.6,
# which needs a symbol the old loader doesn't export.
#
# Fix: name the container's loader explicitly, by absolute host path (/tmp is
# bound 1:1, so the same path is valid inside). Both paths must be host paths —
# ld.so opens the program before libfakechroot is loaded, so a container path
# would not be translated in time. Verified live: `claude --version` ->
# "2.1.226 (Claude Code)".
#
# Not patchelf'ing the binary itself (which is what F3 would have done) on
# purpose: a Bun executable carries a ~290 MB payload behind offsets recorded in
# the file, and rewriting its program headers per node is both slow and a good
# way to corrupt it. The wrapper costs one exec.
#
# NOTE: if some `claude` subcommand ever re-execs the binary by its own
# process.execPath, that child gets the raw PT_INTERP again and this same error.
# Nothing observed so far; the fallback would be the patchelf route above.
#
# Inside a herdr pane the wrapper also sets HERDR_AGENT=claude. herdr spots
# agents by process name and argv[0], and through this wrapper both say
# ld-linux-x86-64.so.2, so the pane would never show Claude's state. herdr reads
# that hint from the foreground process's environment; outside herdr it is unset.
_cl_exe="$_root/usr/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe"
if [ -n "$_root" ] && [ -x "$_cl_exe" ] && [ -e "$_root/lib64/ld-linux-x86-64.so.2" ]; then
    _clwrap="$_root/usr/local/bin/claude"     # /usr/local/bin precedes /usr/bin
    if [ ! -e "$_clwrap" ] || ! grep -q "$_cl_exe" "$_clwrap" 2>/dev/null \
       || ! grep -q HERDR_AGENT "$_clwrap" 2>/dev/null; then
        mkdir -p "$_root/usr/local/bin" 2>/dev/null
        {
            echo '#!/bin/sh'
            echo '# Auto-generated by udocker_dev.sh — see the claude block there.'
            echo '# claude.exe keeps an unpatched PT_INTERP, so the HOST loader would'
            echo '# start it against the container glibc. Name the container loader.'
            echo '[ -n "$HERDR_ENV" ] && export HERDR_AGENT=claude'
            echo "exec \"$_root/lib64/ld-linux-x86-64.so.2\" \"$_cl_exe\" \"\$@\""
        } > "$_clwrap.tmp.$$" 2>/dev/null \
            && chmod +x "$_clwrap.tmp.$$" 2>/dev/null \
            && mv -f "$_clwrap.tmp.$$" "$_clwrap" 2>/dev/null
        rm -f "$_clwrap.tmp.$$" 2>/dev/null
    fi
fi

# ── Locale: hand glibc the container's locale data by HOST path ──────────────
# setlocale() opens its data through glibc-INTERNAL calls that libfakechroot
# cannot interpose (same wall as resolv.conf in the DNS block below), so it
# reads the HOST's RHEL7 /usr/lib/locale, whose format glibc 2.39 rejects.
# Every process therefore silently ran in the C locale despite
# LC_ALL=en_US.UTF-8: `locale` says "Cannot set LC_ALL to default locale", and
# zsh counts multibyte characters by the BYTE. The visible damage is the
# prompt: starship's first line is mostly 3-4-byte powerline/Nerd glyphs, so zsh
# believed it wrapped over several rows, and every vi-mode switch (starship's
# zle-keymap-select does a reset-prompt; zsh picks vi keys because $EDITOR
# contains "vi") moved the cursor up that many rows and erased the output
# above. Verified 2026-09-17: `s="░▒▓❯"; ${(m)#s}` was 12, is 4 with LOCPATH.
#
# LOCPATH is honoured by that same internal loader, but it disables the
# locale-archive (where Ubuntu keeps en_US), so compile a directory-form
# en_US.UTF-8 next to the stock C.utf8 dir. Done host-side with the container's
# own localedef, started through the container loader (the host localedef would
# write the old format): ~1s, once per ROOT, re-made if a reaper restore or a
# fresh ROOT drops it. .zshrc repeats the export for tmux servers started
# before this existed.
if [ -n "$_root" ] && [ -d "$_root/usr/lib/locale" ]; then
    _locdir="$_root/usr/lib/locale/en_US.UTF-8"
    if [ ! -f "$_locdir/LC_CTYPE" ] && [ -x "$_root/usr/bin/localedef" ] \
       && [ -d "$_root/usr/share/i18n/locales" ]; then
        mkdir -p "$_locdir" 2>/dev/null
        env -i I18NPATH="$_root/usr/share/i18n" \
            "$_root/lib64/ld-linux-x86-64.so.2" \
            --library-path "$_root/usr/lib/x86_64-linux-gnu" \
            "$_root/usr/bin/localedef" -i en_US -f UTF-8 "$_locdir" >/dev/null 2>&1 \
            || { err "locale: could not compile en_US.UTF-8 (prompt widths will be wrong)"; rm -rf "$_locdir"; }
    fi
    [ -f "$_locdir/LC_CTYPE" ] && _LOCPATH="$_root/usr/lib/locale"
fi

# ── Claude Code config dir → node-local /tmp ─────────────────────────────────
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

# ── volumes (host dirs -> udocker -v). udocker provides /proc /dev /sys itself,
# so those drop out; we bind the data dirs + /tmp (carries the nvim->/tmp and
# Claude->/tmp redirects) + the network/time /etc files. --hostauth (below) maps
# the host user, so /etc/passwd,group are handled there.
VOLS=()
for _v in "/tmp" "/run" "$HOME" "/work/g/$USER" "/work_bgfs/g/$USER" "/shares"; do
    [ -e "$_v" ] && VOLS+=( -v "$_v:$_v" )
done
for _f in /etc/localtime; do
    [ -e "$_f" ] && VOLS+=( -v "$_f:$_f" )
done

# ── DNS: container-only resolv.conf with a public-resolver fallback ───────────
# 2026-08-19: the campus DNS server (131.247.250.68) REFUSES external names when
# asked from compute-node subnets (login nodes still get answers), and UDP/53
# egress is blocked — so inside the container getaddrinfo/c-ares died on every
# external host (Claude Code: "Failed to connect to api.anthropic.com: ENOTIMP").
# TCP/53 to public resolvers DOES get out (verified from mdc-1057-13-13), so the
# container gets its own resolv.conf:
#   - campus server stays FIRST: internal rc.usf.edu names keep resolving, and
#     its REFUSED on external names makes glibc and c-ares fall through to the
#     next server rather than give up;
#   - public resolvers appended as that fallback;
#   - `use-vc` forces TCP for all of it (glibc >=2.14 and node's c-ares both
#     honor it), which is what routes around the UDP/53 block. `rotate` from the
#     host file is deliberately NOT carried over — order matters here.
# Written INTO the node-local container ROOT (udocker seeds ROOT/etc/resolv.conf
# from the host at create; F3 ignores a file -v map whose source differs from the
# container path — verified live, the bind form left the Puppet host copy in
# place). The ROOT is rebuilt per node, so this is re-written on every launch.
# The host's /etc/resolv.conf is untouched.
if [ -n "$_root" ] && [ -d "$_root/etc" ]; then
    {
        grep -hE '^(search|domain)[[:space:]]' /etc/resolv.conf 2>/dev/null
        echo "options use-vc timeout:2 attempts:2"
        # Deliberately NO campus nameserver: c-ares does NOT fall through past
        # its REFUSED (verified: campus-first => EREFUSED, public-only => OK).
        echo "nameserver 8.8.8.8"
        echo "nameserver 1.1.1.1"
    } > "$_root/etc/resolv.conf"

    # glibc's getaddrinfo is a separate, harder problem: it reads resolv.conf
    # through glibc-INTERNAL calls that LD_PRELOAD cannot interpose, so it always
    # sees the HOST file (campus-only => external names die with EAI_AGAIN no
    # matter what the container file says). The only user-space lever left for
    # curl/git/getent is /etc/hosts pinning, so generate a container hosts file:
    # host entries + the handful of external domains the container actually
    # talks to, resolved fresh at launch via DNS-over-HTTPS (TCP/443 egress
    # works). Every DoH lookup has a static last-known-good fallback so a launch
    # without DoH still pins something usable. IPs are pinned per-launch, not
    # forever — the ROOT is node-local and rebuilt/re-written each launch.
    _PIN_DOMAINS="api.anthropic.com=160.79.104.10
claude.ai=160.79.104.6
console.anthropic.com=160.79.104.14
statsig.anthropic.com=160.79.104.10
github.com=140.82.112.3
api.github.com=140.82.112.6
codeload.github.com=140.82.112.9
objects.githubusercontent.com=185.199.108.133
raw.githubusercontent.com=185.199.108.133
registry.npmjs.org=104.16.0.35
pypi.org=151.101.0.223
files.pythonhosted.org=151.101.0.175"
    {
        cat /etc/hosts 2>/dev/null
        echo "# --- pinned by udocker_dev.sh (compute-node DNS refuses external names) ---"
        echo "$_PIN_DOMAINS" | while IFS='=' read -r _d _fallback; do
            [ -n "$_d" ] || continue
            _ip=$(timeout 6 curl -s "https://8.8.8.8/resolve?name=${_d}&type=A" 2>/dev/null \
                  | grep -o '"data":"[0-9.]*"' | head -1 | cut -d'"' -f4)
            echo "${_ip:-$_fallback} $_d"
        done
    } > "$_root/etc/hosts"
fi

# ── node DNS shim: route dns.lookup around the broken glibc resolver ──────────
# glibc getaddrinfo is beyond repair from user space (it reads the HOST
# resolv.conf and HOST /etc/hosts through glibc-internal calls that neither
# LD_PRELOAD nor the container files can reach — verified: /etc/hosts pins are
# visible to cat but invisible to getent). Node, however, exposes its resolver:
# dns.lookup (used by fetch/undici/net — i.e., by Claude Code) wraps
# getaddrinfo, while dns.resolve4 uses c-ares, which DOES honor the container
# resolv.conf (public servers + use-vc over TCP) — verified working. So preload
# a shim into every node process: try the native lookup first (keeps localhost,
# /etc/hosts and internal names native — the broken path fails FAST with
# EAI_AGAIN on REFUSED), and on failure re-resolve via c-ares.
_NODE_SHIM="$HOME/.local/lib/node-dns-shim.cjs"
mkdir -p "$HOME/.local/lib"
cat > "$_NODE_SHIM" <<'NODESHIM'
// Auto-generated by udocker_dev.sh — see the comment block there.
// Fallback: native dns.lookup (glibc getaddrinfo, broken for external names on
// compute nodes since 2026-08 DNS ACL change) -> c-ares resolve4/6, which uses
// the container resolv.conf (8.8.8.8/1.1.1.1 over TCP).
'use strict';
const dns = require('dns');
const { isIP } = require('net');
const origLookup = dns.lookup.bind(dns);
const origPromise = dns.promises.lookup.bind(dns.promises);

function caresLookup(host, options, cb) {
  dns.resolve4(host, (e4, a4) => {
    if (!e4 && a4 && a4.length) {
      const addrs = a4.map((a) => ({ address: a, family: 4 }));
      return options.all ? cb(null, addrs) : cb(null, addrs[0].address, 4);
    }
    dns.resolve6(host, (e6, a6) => {
      if (!e6 && a6 && a6.length) {
        const addrs = a6.map((a) => ({ address: a, family: 6 }));
        return options.all ? cb(null, addrs) : cb(null, addrs[0].address, 6);
      }
      cb(e4 || e6);
    });
  });
}

dns.lookup = function lookup(host, options, cb) {
  if (typeof options === 'function') { cb = options; options = {}; }
  if (typeof options === 'number') options = { family: options };
  options = options || {};
  if (!host || isIP(host)) return origLookup(host, options, cb);
  origLookup(host, options, (err, addr, fam) => {
    if (!err) return cb(null, addr, fam);
    caresLookup(host, options, (err2, addr2, fam2) => {
      if (err2) return cb(err, addr, fam); // surface the ORIGINAL error
      cb(null, addr2, fam2);
    });
  });
};

dns.promises.lookup = async function lookup(host, options) {
  try { return await origPromise(host, options); }
  catch (err) {
    if (!host || isIP(host)) throw err;
    return new Promise((resolve, reject) => {
      caresLookup(host, typeof options === 'object' && options ? options : {},
        (e, addr, fam) => e ? reject(err)
          : resolve(Array.isArray(addr) ? addr : { address: addr, family: fam }));
    });
  }
};
NODESHIM
ENVS_NODE_OPTIONS="--require $_NODE_SHIM"

# ── local CONNECT proxy: DNS for STATIC binaries (claude.exe) ─────────────────
# claude v2.1.226+ is a static Bun executable: NODE_OPTIONS never loads in it,
# and (same family as the static-git escapes) it bypasses libfakechroot, so it
# reads the HOST resolv.conf -> campus server -> ENOTIMP, no matter what the
# container files say. Static binaries can't be fixed by files or preloads — but
# claude/curl/git all honor HTTP(S)_PROXY, and a proxy only needs to be reached
# by IP (127.0.0.1, no DNS). So ship a tiny CONNECT proxy that runs as a
# DYNAMIC node process inside the container (working DNS via c-ares + the
# container resolv.conf) and resolves upstream names itself. The container
# .zshrc starts it once per node and exports the proxy env vars.
_DNS_PROXY="$HOME/.local/lib/dns-proxy.cjs"
cat > "$_DNS_PROXY" <<'DNSPROXY'
// Auto-generated by udocker_dev.sh — local forward proxy for static binaries
// (claude.exe etc.) that cannot see the container's working DNS. Resolves
// upstream hosts via c-ares (container resolv.conf: public servers over TCP).
'use strict';
const http = require('http');
const net = require('net');
const dns = require('dns');
const PORT = parseInt(process.env.DNS_PROXY_PORT || '18373', 10);

function resolveHost(host, cb) {
  if (net.isIP(host)) return cb(null, host);
  dns.resolve4(host, (e4, a4) => {
    if (!e4 && a4 && a4.length) return cb(null, a4[0]);
    dns.resolve6(host, (e6, a6) => {
      if (!e6 && a6 && a6.length) return cb(null, a6[0]);
      cb(e4 || e6 || new Error('unresolvable'));
    });
  });
}

const srv = http.createServer((req, res) => {  // plain-http forwards
  let u; try { u = new URL(req.url); } catch { res.writeHead(400); return res.end(); }
  resolveHost(u.hostname, (err, ip) => {
    if (err) { res.writeHead(502); return res.end('proxy dns fail\n'); }
    const p = http.request(
      { host: ip, port: u.port || 80, path: u.pathname + u.search,
        method: req.method, headers: req.headers },
      (pr) => { res.writeHead(pr.statusCode, pr.headers); pr.pipe(res); });
    p.on('error', () => { try { res.writeHead(502); res.end(); } catch {} });
    req.pipe(p);
  });
});
srv.on('connect', (req, sock, head) => {       // HTTPS tunnels
  const i = req.url.lastIndexOf(':');
  const host = i > 0 ? req.url.slice(0, i) : req.url;
  const port = i > 0 ? parseInt(req.url.slice(i + 1), 10) : 443;
  resolveHost(host, (err, ip) => {
    if (err) { sock.end('HTTP/1.1 502 Bad Gateway\r\n\r\n'); return; }
    const up = net.connect(port, ip, () => {
      sock.write('HTTP/1.1 200 Connection Established\r\n\r\n');
      if (head && head.length) up.write(head);
      up.pipe(sock); sock.pipe(up);
    });
    up.on('error', () => sock.destroy());
    sock.on('error', () => up.destroy());
  });
});
srv.on('clientError', (e, sock) => sock.destroy());
srv.listen(PORT, '127.0.0.1');
DNSPROXY

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
       --env="CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1"
       --env="NODE_OPTIONS=${ENVS_NODE_OPTIONS:-}" )
[ -n "${_LOCPATH:-}" ] && ENVS+=( --env="LOCPATH=$_LOCPATH" )   # see the Locale block

# Point the static git (above) at its bundled CA so HTTPS remotes work both
# in-container AND when lazygit's `git` escapes onto the RHEL7 host, whose CA
# path differs from the binary's musl/Alpine default. Guarded: only set when the
# bundle is present, so an older image without it keeps using the system CA.
[ -f "$HOME/.local/git-static/ssl/cacert.pem" ] && \
    ENVS+=( --env="GIT_SSL_CAINFO=$HOME/.local/git-static/ssl/cacert.pem" )

# ── GitHub credentials for the in-container git ──────────────────────────────
# CIRCE's ~/.gitconfig sets `credential.helper = store`, and credential.helper is
# MULTI-VALUED: git consults every helper it finds, in order, and stops at the
# first that answers. store answered first with a stale token from
# ~/.git-credentials, so git never fell through to gh — and store returns the
# same dead credential on every retry, which is why in-container pushes failed
# identically each attempt.
#
# ~/.config/git/container.gitconfig (shipped by sync_configs.sh) includes
# ~/.gitconfig, then RESETS the helper list with an empty value and installs
# `!/usr/local/bin/gh auth git-credential` as the only helper. It must be
# activated at the GLOBAL level or later: git parses system -> global -> local, so
# an /etc/gitconfig reset would just be overridden by ~/.gitconfig's store being
# appended after it. GIT_CONFIG_GLOBAL is the lever, and it keeps this scoped to
# the container — the RHEL7 host's git still reads plain ~/.gitconfig.
#
# Guarded on the file existing, so a node that hasn't had the config synced yet
# behaves exactly as before rather than losing its global config entirely.
# lazygit overrides this with its own token-header config (see the wrapper above);
# it cannot use a helper at all.
[ -f "$HOME/.config/git/container.gitconfig" ] && \
    ENVS+=( --env="GIT_CONFIG_GLOBAL=$HOME/.config/git/container.gitconfig" )

# ── launch. Default to interactive zsh; forward args. NOT exec'd so the EXIT trap
# (Claude sync-back) runs after the shell quits. --workdir starts in the real
# $HOME. No --hostauth: the host uses LDAP (no local /etc/passwd line), so it
# can't map our uid — the getent append into the container's NSS files (setup,
# above) is what makes id/whoami/the prompt resolve.
[ "$#" -eq 0 ] && set -- -i
# --nosysdirs: udocker force-binds its sysdirs_list (/dev /proc /sys
# /etc/resolv.conf /etc/host.conf /lib/modules) to the HOST on every run, which
# is what kept the broken host resolv.conf visible in-container no matter what
# -v said (see the DNS block above). So opt out and re-add every sysdir EXCEPT
# /etc/resolv.conf explicitly — they still take the same host-passthrough branch
# (membership in sysdirs_list), so /dev, /proc, /sys behave exactly as before.
# The container then reads its own ROOT/etc/resolv.conf, written above.
for _sd in /dev /proc /sys /etc/host.conf /lib/modules; do
    [ -e "$_sd" ] && VOLS+=( -v "$_sd:$_sd" )
done
udocker run --nosysdirs --workdir="$HOME" "${ENVS[@]}" "${VOLS[@]}" \
    "$UDOCKER_CONTAINER" /bin/zsh "$@"
exit $?
