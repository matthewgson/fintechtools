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
_nvim_heal() {
  local lazy="${XDG_DATA_HOME:-$HOME/.local/share}/nvim/lazy"
  [ -d "$lazy" ] || return 0
  local c hit=0
  for c in LazyVim/lua/lazyvim/init.lua blink.cmp/lua/blink/cmp/init.lua \
           nvim-treesitter/lua/nvim-treesitter/init.lua \
           trouble.nvim/lua/trouble/init.lua snacks.nvim/lua/snacks/init.lua; do
    [ -d "$lazy/${c%%/*}/.git" ] && [ ! -f "$lazy/$c" ] && { hit=1; break; }
  done
  (( hit )) || return 0
  print -u2 "nvim: restoring plugin files reaped from /tmp (git checkout -f)…"
  local d
  for d in "$lazy"/*/.git(N); do
    d="${d:h}"
    git -C "$d" checkout -f >/dev/null 2>&1
  done
}
nvim() { _nvim_heal; command nvim "$@"; }
alias vi=nvim
alias vim=nvim

# ── claude-auto-retry ────────────────────────────────────────────────────────
# Auto-retries a Claude Code session when it hits a subscription rate limit or
# sustained API overload (529/500/503), with exponential backoff. Installed into
# the image by the Dockerfile (`npm i -g claude-auto-retry`, Stage 11).
#
# This block is what `claude-auto-retry install` would have injected. It is kept
# HERE, in the repo's .zshrc, rather than being installed at runtime, because
# sync_configs.sh rsyncs this file over CIRCE's ~/.zshrc — a runtime-injected
# wrapper would be silently reverted by the next config sync. The upstream marker
# comments are preserved verbatim so `claude-auto-retry install` / `uninstall`
# still find, replace, or remove this block cleanly if ever run by hand.
#
# Only the zsh branch of upstream's src/wrapper.sh is kept (this file is only ever
# sourced by zsh). The launcher path is the image's npm global root; the `-e` guard
# means an older image without the package degrades to plain `claude` instead of
# breaking the command. Requires tmux (image ships 3.6b) — the monitor runs in a
# tmux pane, so start Claude from inside a tmux session (`tm`) to get retries.
# >>> claude-auto-retry >>>
# Drop any pre-existing `claude` alias (Claude Code's own installer adds one)
# before defining the wrapper function. Without this, the shell expands the
# alias while parsing `claude() {`, producing "syntax error near unexpected
# token '('" when the rc file is sourced.
unalias claude 2>/dev/null || true
claude() {
  # Degrade to plain claude if already inside a wrapped session, or if the launcher
  # is gone (package removed via `npm uninstall -g`, or an image predating it) — an
  # orphaned wrapper must never break the claude command.
  if [ "${CLAUDE_AUTO_RETRY_ACTIVE}" = "1" ] || [ ! -e "/usr/lib/node_modules/claude-auto-retry/src/launcher.js" ]; then
    command claude "$@"
    return $?
  fi
  export CLAUDE_AUTO_RETRY_ACTIVE=1
  local _car_exit
  # zsh: localtraps restores the user's INT/TERM traps automatically on return.
  setopt localoptions localtraps
  trap 'unset CLAUDE_AUTO_RETRY_ACTIVE' INT TERM
  node "/usr/lib/node_modules/claude-auto-retry/src/launcher.js" "$@"
  _car_exit=$?
  unset CLAUDE_AUTO_RETRY_ACTIVE
  return $_car_exit
}
# <<< claude-auto-retry <<<
