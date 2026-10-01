export XDG_CONFIG_HOME="$HOME/.config"
export PATH=$HOME/local/bin:$PATH
export DYLD_LIBRARY_PATH=${HOME}/local/lib:$DYLD_LIBRARY_PATH
export EDITOR=nvim

# Container: glibc loads locale data from the HOST path, so point LOCPATH at the
# ROOT's (see the Locale block in udocker_dev.sh). Without it zsh runs in the C
# locale, mis-measures starship's glyphs, and a vi-mode switch erases the lines
# above the prompt. Set here too for tmux servers older than that launcher
# change. Must precede the LC_ALL assignment, which is what makes zsh reload.
if [ -n "${FAKECHROOT_BASE:-}" ] && [ -z "${LOCPATH:-}" ] \
   && [ -f "$FAKECHROOT_BASE/usr/lib/locale/en_US.UTF-8/LC_CTYPE" ]; then
  export LOCPATH="$FAKECHROOT_BASE/usr/lib/locale"
fi
export LANG="en_US.UTF-8"
export LC_ALL="en_US.UTF-8"

# Yazi 
function y() {
	local tmp="$(mktemp -t "yazi-cwd.XXXXXX")" cwd
	command yazi "$@" --cwd-file="$tmp"
	IFS= read -r -d '' cwd < "$tmp"
	[ "$cwd" != "$PWD" ] && [ -d "$cwd" ] && builtin cd -- "$cwd"
	rm -f -- "$tmp"
}
export PATH="$HOME/.local/bin:$PATH"

# === bookokrat: the name on $PATH is the real binary ========================
# /usr/local/bin/bookokrat, installed by the image. Nothing shadows it, and
# nothing should: the ~/.local/bin/override/bookokrat wrapper that briefly
# existed on both machines is retired. It answered bookokrat's outer-terminal
# probe with "kitty" to force the Unicode-placeholder anchor path on, and
# Ghostty 1.3.1 does not implement the relative placements that path emits
# (Kitty keys P=/Q=) — it drops them and paints the page wherever the cursor
# sits, which is on top of yazi, leaving the reader's own pane empty. Retired
# on the Mac 2026-09-04; it was never viable here anyway, since the anchor path
# is implemented only over SHM transmission and bookokrat's shm object lives in
# /dev/shm on the compute node while Ghostty runs on the Mac.
#
# The ghost page that wrapper was written to prevent — a page left painted over
# the window you switched to (bookokrat#179) — is handled instead by
# ~/.local/bin/tmux-kitty-image-gc, which configs/tmux/tmux.conf calls from the
# window-change hooks and bookokrat-split appends to the reader's own command
# line for the exit case.
typeset -U path   # re-sourcing .zshrc must not stack duplicate PATH entries

# === Zoxide Initialization ===
# This creates the hooks so every directory change is automatically recorded
eval "$(zoxide init zsh)"

# Starship prompt initialization
# Only once per shell. The image's /etc/zsh/zshrc has already run
# `starship init zsh` in the container; a second init wraps the first one's
# zle-keymap-select, so each vi-mode switch runs `zle reset-prompt` twice, and
# zsh then redraws the two-line prompt one row too high per call, erasing
# output above it (2 lines per Esc/i, verified 2026-09-17). STARSHIP_CONFIG is
# read at every render, so exporting it after the image's init still applies.
export STARSHIP_CONFIG="$HOME/.config/starship/starship.toml"
(( ${+functions[prompt_starship_precmd]} )) || eval "$(starship init zsh)"

# fzf Integration
# Use command substitution (eval "$(...)") rather than process substitution
# (source <(...)). Under proot the latter opens /proc/self/fd/NN, which proot
# does not back with a real file — yielding
#   .zshrc:source:NN: no such file or directory: /proc/self/fd/15
# in every interactive shell (including each tmux pane). eval avoids the fd.
if command -v fzf >/dev/null 2>&1; then
  eval "$(fzf --zsh)"
fi

# === DNS proxy for static binaries (container only) ==========================
# Compute-node DNS refuses external names (2026-08). Dynamic binaries are fixed
# by the container resolv.conf + node shim (see udocker_dev.sh), but STATIC
# binaries — claude.exe (Bun) above all — bypass libfakechroot and read the
# HOST resolv.conf, so they still die (claude TUI: "ENOTIMP"). They do honor
# proxy env vars though, and a proxy needs no DNS to reach (127.0.0.1). So in
# the container, start the launcher-generated CONNECT proxy once per node and
# route external traffic through it. NO_PROXY keeps localhost + USF internal
# addresses direct. Guarded on container_uuid: this same .zshrc also runs on
# the CIRCE login node, where DNS is fine and no proxy should exist.
if [ -n "${container_uuid:-}" ] && [ -f "$HOME/.local/lib/dns-proxy.cjs" ]; then
  _dnsproxy_port=18373
  if ! { exec 3<>"/dev/tcp/127.0.0.1/${_dnsproxy_port}"; } 2>/dev/null; then
    nohup node "$HOME/.local/lib/dns-proxy.cjs" \
      >> "/tmp/${USER}/dns-proxy.log" 2>&1 &!
    sleep 0.3
  else
    exec 3>&- 3<&-
  fi
  export HTTPS_PROXY="http://127.0.0.1:${_dnsproxy_port}"
  export HTTP_PROXY="http://127.0.0.1:${_dnsproxy_port}"
  export https_proxy="$HTTPS_PROXY" http_proxy="$HTTP_PROXY"
  export NO_PROXY="localhost,127.0.0.1,::1,.usf.edu"
  export no_proxy="$NO_PROXY"
  unset _dnsproxy_port
fi

# === Persistent tmux in one command ==========================================
# tmux replaced zellij here: a fresh tmux session creates in ~0.03s even under
# proot, where a fresh zellij create cost ~1.3-1.5s (its WASM plugin runtime +
# async plugin handshake fire thousands of syscalls at create, each ptraced by
# PROOT_NO_SECCOMP=1). So fresh launches are no longer the bottleneck.
# `tm` still gives one-command persistence across reconnects: new-session -A
# ATTACHES to the named session if it's live (reusing your panes), else creates
# it. Pass a name to use a session other than `main`.
tm() { tmux new-session -A -s "${1:-main}"; }

# === Self-heal nvim plugins reaped by /tmp's age-cleaner ======================
# nvim's plugin store (~/.local/share/nvim) is symlinked to node-local /tmp for
# fast startup (see the image's /etc/zsh/zshenv). But systemd-tmpfiles
# age-prunes /tmp (/usr/lib/tmpfiles.d/tmp.conf: `D /tmp ... 30d`), so on a
# long-lived node it deletes the thousands of individual plugin *source* files
# while leaving each plugin's compact .git intact. LazyVim then sees the plugin
# as installed and runs its `config`, but require() can't find the module →
# "module not found" for nvim-treesitter / trouble / blink.cmp / R.nvim / ….
#
# `git checkout -f` rebuilds each working tree from the surviving local git
# objects — offline, instant, no re-clone — and leaves untracked files (blink's
# native *.so) alone. Canary-gated: a healthy launch costs only a few
# stat()s; the full restore runs only when a hot plugin's worktree was reaped.
#
# 2026-08-10: this guard failed and nvim died with "No specs found for module
# lazyvim.plugins". Two independent bugs, both fixed below.
#   1. The canary list missed. The reaper ate LazyVim/lua/lazyvim/plugins/*.lua
#      while lua/lazyvim/init.lua — the canary — survived, so hit stayed 0. Any
#      hardcoded list has this hole: /tmp is pruned by ATIME, so the files that
#      die are precisely the COLD ones, and a canary is only useful if it is
#      colder than everything it guards.
#   2. Even had it fired, `git checkout -f` would have restored nothing. An
#      interrupted fetch/gc had left 0-byte pack .idx/.pack files in 6 repos;
#      git then fails EVERY object lookup there ("index file ... is too small").
#      Since the loop sends stderr to /dev/null and ignores the exit status,
#      that failure was completely silent.
# === Un-stick a lazy.nvim clone that was interrupted =========================
# Nothing to do with the /tmp reaper below, and it is worth knowing the two
# apart because they present almost identically — a plugin that behaves as
# though it were never installed.
#
# lazy.nvim writes an empty "<plugin-dir>.cloning" marker beside the directory
# BEFORE it clones, and unlinks it from the clone task's on_exit only when git
# exited 0 (lazy/manage/task/git.lua). So the marker is armed before the work
# and disarmed after it. Quit nvim — or stall the network, which on a compute
# node means the CONNECT proxy — while a first install is in flight, and the
# marker outlives the clone that was supposed to clear it.
#
# From then on it never converges on its own. lazy/core/plugin.lua's
# update_state() drops any name with a marker from the installed set, ignoring
# the perfectly good directory sitting right next to it; the clone task then
# sees that directory already exists, fs.clean()s it away, re-arms the marker
# and clones again — every single startup, forever. Quit early once more and
# it re-arms. Cost is a full re-clone of that plugin at each launch.
#
# Bitten 2026-09-03 by quarto-render.nvim: every other plugin had been
# installed in Jul/Aug and pinned in lazy-lock.json, so it was the only one
# still doing a first install and the only one exposed. A fresh node or a fresh
# ROOT puts EVERY plugin back into exactly that state at once, which is why
# this runs unconditionally rather than behind the reaper's sentinel.
#
# A resolvable HEAD next to the marker proves the clone did finish, so the
# marker is the only thing removed. If HEAD does not resolve the checkout
# really is unfinished — leave it alone, lazy's re-clone is then correct. This
# cannot race a live clone: git writes HEAD's commit last, and a concurrent
# clone that succeeds anyway just unlinks a file that is already gone.
# Cost on a healthy store: one readdir, no git spawned.
_nvim_unstick_clones() {
  local lazy="${XDG_DATA_HOME:-$HOME/.local/share}/nvim/lazy"
  [ -d "$lazy" ] || return 0
  local m d
  for m in "$lazy"/*.cloning(N.); do
    d="${m%.cloning}"
    [ -d "$d/.git" ] || continue
    command git -C "$d" rev-parse --verify --quiet HEAD >/dev/null 2>&1 || continue
    print -u2 "nvim: clearing stale lazy.nvim clone marker for ${d:t} (it would re-clone every launch)"
    rm -f -- "$m"
  done
}

_nvim_heal() {
  local lazy="${XDG_DATA_HOME:-$HOME/.local/share}/nvim/lazy"
  [ -d "$lazy" ] || return 0

  # Detection: a sentinel, not a canary list. It is written after each heal and
  # never read again — stat() does not update atime — so it ages at the rate of
  # the coldest file in the tree and the reaper claims it FIRST. Its absence is
  # a leading indicator of a reap, whichever plugin files were taken. Healthy
  # launch costs exactly one stat(), cheaper than the old five.
  local sentinel="$lazy/.reap-sentinel" hit=0
  [ -e "$sentinel" ] || hit=1
  # Belt-and-braces: catch a reap that somehow spared the sentinel.
  if (( ! hit )); then
    local c
    for c in LazyVim/lua/lazyvim/plugins/init.lua plenary.nvim/lua/plenary/path.lua \
             blink.cmp/lua/blink/cmp/init.lua nvim-treesitter/lua/nvim-treesitter/init.lua \
             trouble.nvim/lua/trouble/init.lua snacks.nvim/lua/snacks/init.lua; do
      [ -d "$lazy/${c%%/*}/.git" ] && [ ! -f "$lazy/$c" ] && { hit=1; break; }
    done
  fi
  (( hit )) || return 0

  # Clear the 0-byte packs before checking out, or the restore silently no-ops
  # (bug 2 above). A 0-byte pack holds no objects, so deleting it loses nothing.
  # NEVER match .promisor: those are legitimately 0 bytes, and they are what
  # marks a pack as coming from a promisor remote — delete them and the
  # blob:none partial clones lose the right to fetch their missing blobs.
  local p
  for p in "$lazy"/*/.git/objects/pack/*.(idx|pack)(.L0N); do rm -f -- "$p"; done

  # Only check out repos that actually lost files: `ls-files --deleted` skips
  # the untracked scan, so the full 47-repo sweep costs ~0.4s.
  local d restored=0
  for d in "$lazy"/*/.git(N); do
    d="${d:h}"
    [ -n "$(git -C "$d" ls-files --deleted 2>/dev/null | head -1)" ] || continue
    (( restored )) || print -u2 "nvim: restoring plugin files reaped from /tmp (git checkout -f)…"
    restored=1
    git -C "$d" checkout -f >/dev/null 2>&1
  done

  # vim.loader's bytecode cache sits on the same reaped /tmp; drop it after a
  # real restore so it rebuilds against the recovered sources.
  (( restored )) && rm -rf -- "${XDG_CACHE_HOME:-$HOME/.cache}/nvim/luac"

  : > "$sentinel"
}
nvim() { _nvim_unstick_clones; _nvim_heal; command nvim "$@"; }
alias vim=nvim
# `vi` is deliberately NOT aliased — it stays the system vi. The image's
# /etc/zsh/zshrc still sets `alias vi="nvim"` and is sourced before this file, so
# undo it here; that line is gone from the Dockerfile, and this unalias can go
# once the image has been rebuilt.
unalias vi 2>/dev/null || true

# ── claude ───────────────────────────────────────────────────────────────────
# No wrapper. claude-auto-retry (auto-resume on rate limit) was removed
# 2026-08-21 — it is gone from the Dockerfile too, so nothing here to degrade to.
# `claude` resolves to the ROOT's /usr/local/bin/claude launcher that
# udocker_dev.sh writes: the npm binary is a Bun ELF whose PT_INTERP F3 leaves
# unpatched, so it must be started through the container's own loader.
