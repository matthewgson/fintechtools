export XDG_CONFIG_HOME="$HOME/.config"
export PATH=$HOME/local/bin:$PATH
export DYLD_LIBRARY_PATH=${HOME}/local/lib:$DYLD_LIBRARY_PATH
export EDITOR=nvim

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

# === Zoxide Initialization ===
# This creates the hooks so every directory change is automatically recorded
eval "$(zoxide init zsh)"

# Starship prompt initialization
export STARSHIP_CONFIG="$HOME/.config/starship/starship.toml"
eval "$(starship init zsh)"

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
# objects — offline, instant, no re-clone — and leaves untracked files (avante /
# blink native *.so) alone. Canary-gated: a healthy launch costs only a few
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
nvim() { _nvim_heal; command nvim "$@"; }
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
