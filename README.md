# FinTech Tools Container — v0.6

HPC container for Financial / Quantitative computing. Built on macOS with Podman, converted to
Singularity/Apptainer, deployed to CIRCE. Workflow has migrated from VSCode
Remote-SSH (legacy, still works) to **Neovim** SSH.

## Build

```bash
./build_container.sh
```

Does it all: builds with Podman → saves tar → converts to `.sif` inside the
Podman VM toolbox → optional `scp` to CIRCE (`gson@circe.rc.usf.edu:~/containers/`).
Pushover notifications fire if `~/.pushover_config` is set.

Prereqs (one-time):

```bash
brew install podman
podman machine init && podman machine start
podman machine ssh -- "sudo dnf install -y toolbox && toolbox create && toolbox run sudo dnf install -y apptainer"
```

## What's inside (v0.6)

| Stack | Detail |
|---|---|
| Base | Ubuntu 24.04 LTS (Noble) headless |
| Python | **3.13** via deadsnakes; `/usr/local/bin/python{,3}` symlinked, env vars (`PYTHON`, `RETICULATE_PYTHON`, `UV_PYTHON`) point here — **not** the system 3.12 |
| uv | Astral binary in `/usr/local/bin/` |
| Editor | Neovim (latest) + LazyVim starter |
| LazyVim extras | `ai.copilot`, `lang.html`, `lang.python`, plus git/json/markdown/yaml/toml |
| Terminal | Zellij (multiplexer), Yazi (file manager) with all recommended deps, lazygit, `ncurses-term` (many terminfos) |
| AI CLIs | `gh copilot` extension + `@anthropic-ai/claude-code` (npm global) |
| SSH | `openssh-server`, port 2222 (legacy VSCode remote still supported) |
| Not included | R, TinyTeX/TeX, h2o, RQuantLib — dropped in v0.6 for build speed. Re-add as a separate stage if you need them. |

Yazi deps included (per [yazi docs](https://yazi-rs.github.io/docs/installation)):
`file`, `ffmpeg`, `p7zip`, `jq`, `poppler-utils`, `fd`, `ripgrep`, `fzf`,
`zoxide`, `imagemagick`, `xclip`, `resvg`, `unar`.

## HPC deployment

Container drops at `~/containers/fintech-tools.sif` on CIRCE.
Launch a dev session: `sbatch dev_session.sh` (SSH on 2222, port-forward for
Positron via 2223 — see `dev_session.sh` for details).

### SSH connection

```bash
# Direct (ghostty / VSCode Remote-SSH)
ssh -J gson@circe.rc.usf.edu gson@<compute_node> -p 2222 -i ~/.ssh/local_mac_to_singularity

# Positron (needs local forward)
autossh -M 0 -f -N -L 2223:<compute_node>:2222 gson@circe.rc.usf.edu
# then connect Positron → localhost:2223
```

Container expects host-side `~/ssh_keys/` mounted into `/etc/ssh` with host
keys + `sshd_config` + `authorized_keys` containing your local pubkey
(`~/.ssh/local_mac_to_singularity.pub`).

## Files

- `Dockerfile` — image definition
- `build_container.sh` — build + convert + transfer
- `dev_session.sh` — SLURM job script for the dev session on CIRCE
- `ssh_config`, `sshd_config` — SSH templates
- `~/.pushover_config` (optional, not in repo) — Pushover token/user for build notifications
