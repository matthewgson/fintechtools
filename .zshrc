# ~/.zshrc — CIRCE HPC user config for fintechtools container
# Copy this file to ~/.zshrc on CIRCE.
# The container's /etc/zsh/zshrc handles: PATH, nvim aliases, zoxide, starship.
# This file adds per-user tools and guards against double-initialization.

# ── Yazi file manager shell wrapper ─────────────────────────────────────────
# 'y' launches yazi and cd's to the last directory yazi was in on exit.
function y() {
    local tmp cwd
    tmp="$(mktemp -t "yazi-cwd.XXXXXX")"
    yazi "$@" --cwd-file="$tmp"
    if cwd="$(command cat -- "$tmp")" && [ -n "$cwd" ] && [ "$cwd" != "$PWD" ]; then
        builtin cd -- "$cwd"
    fi
    rm -f -- "$tmp"
}

# ── Zoxide (smart cd) ────────────────────────────────────────────────────────
# Re-initializing is harmless; ensures zoxide works even outside the container.
eval "$(zoxide init zsh)"

# ── Starship prompt ──────────────────────────────────────────────────────────
# Point starship to the config file copied into ~/.config/starship/
export STARSHIP_CONFIG="$HOME/.config/starship/starship.toml"
# Skip if the container's /etc/zsh/zshrc already initialized starship
# (starship sets STARSHIP_SHELL=zsh on init).
[[ -z "$STARSHIP_SHELL" ]] && eval "$(starship init zsh)"
