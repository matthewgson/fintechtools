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
source <(fzf --zsh)
