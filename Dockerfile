# Fintech Tools Container
# Base: Ubuntu 24.04 LTS (Noble Numbat) — headless server edition
FROM ubuntu:24.04

LABEL maintainer="Matthew Son"
LABEL description="HPC container: Neovim + Python 3.13 + uv + R 4.x + gh Copilot CLI"
LABEL version="0.9"

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=America/New_York
ENV LC_ALL=C.UTF-8
ENV LANG=C.UTF-8

# Singularity library path (preserved for HPC GPU passthrough compatibility)
ENV LD_LIBRARY_PATH="/.singularity.d/libs:$LD_LIBRARY_PATH"

WORKDIR /work_bgfs/g/gson

# ─── Stage 1: Core system packages ──────────────────────────────────────────
RUN apt-get update && \
    apt-get install -y \
    # Locale / repo tooling
    locales \
    lsb-release \
    software-properties-common \
    gnupg \
    ca-certificates \
    # Build toolchain
    build-essential \
    pkg-config \
    cmake \
    ninja-build \
    autoconf \
    automake \
    libtool \
    # Java (H2O dependency)
    openjdk-21-jdk \
    # Boost + system QuantLib headers (kept; RQuantLib source build itself is disabled below)
    libboost-all-dev \
    libquantlib0-dev \
    # Compression / networking
    libcurl4-openssl-dev \
    libssl-dev \
    libssh2-1-dev \
    libz-dev \
    libbz2-dev \
    liblz4-dev \
    libzstd-dev \
    libsnappy-dev \
    xz-utils \
    # XML / protobuf
    libxml2-dev \
    libxml2-utils \
    libprotobuf-dev \
    protobuf-compiler \
    # BLAS / LAPACK
    libblas-dev \
    liblapack-dev \
    libopenblas-dev \
    # FFI / HDF5
    libffi-dev \
    libhdf5-dev \
    # Graphics / font libs (R + image previews)
    libfontconfig1-dev \
    libfreetype6-dev \
    libpng-dev \
    libtiff5-dev \
    libjpeg-dev \
    libcairo2-dev \
    libxt-dev \
    libfribidi-dev \
    libharfbuzz-dev \
    libgit2-dev \
    # Database / ODBC (RPostgres, RSQLite, RODBC/odbc)
    libpq-dev \
    libsqlite3-dev \
    unixodbc-dev \
    # Neovim / LazyVim CLI deps
    ripgrep \
    fd-find \
    unzip \
    # Yazi required + recommended optional deps (per yazi-rs.github.io/docs/installation)
    file \
    ffmpeg \
    p7zip-full \
    jq \
    poppler-utils \
    imagemagick \
    xclip \
    unar \
    # Terminfo (ghostty + many others) for SSH terminal compatibility
    ncurses-term \
    # clear command
    ncurses-bin \
    # process viewer
    htop \
    # Bootstrap node — replaced by NodeSource LTS in Stage 2
    nodejs \
    npm \
    # General utilities
    pandoc \
    git \
    nano \
    vim \
    htop \
    wget \
    curl \
    sudo \
    openssh-server \
    man-db \
    less \
    tmux \
    zsh && \
    locale-gen en_US.UTF-8 && \
    usermod -s /bin/zsh root && \
    rm -rf /var/lib/apt/lists/*

# Note: ghostty terminfo is not shipped here. ghostty generates it from Zig
# source at build time, so there is no raw file to fetch. After deploying the
# container, install it once from your Mac:
#   infocmp -x xterm-ghostty | ssh <ssh-target> -- tic -x -
# (per https://ghostty.org/docs/help/terminfo). ncurses-term covers most others.

# ─── Stage 1b: NVIDIA CUDA 12.3 runtime + utilities (Singularity --nv) ──────
# ubuntu2404 only ships CUDA 12.5+; use ubuntu2204 packages (glibc-compatible).
# cuda-compat-12-3  : driver forward-compat shim (libcuda.so stub)
# cuda-cudart-12-3  : CUDA runtime (libcudart.so)
# libcublas/cufft/curand/cusolver: common GPU compute libraries
# nvidia-utils-545  : nvidia-smi (545 = minimum driver for CUDA 12.3)
RUN curl -fsSL https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/cuda-keyring_1.1-1_all.deb \
        -o /tmp/cuda-keyring.deb && \
    dpkg -i /tmp/cuda-keyring.deb && \
    rm /tmp/cuda-keyring.deb && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        cuda-compat-12-3 \
        cuda-cudart-12-3 \
        libcufft-12-3 \
        libcublas-12-3 \
        libcurand-12-3 \
        libcusolver-12-3 \
        nvidia-utils-545 && \
    rm -rf /var/lib/apt/lists/*

ENV PATH="/usr/local/cuda-12.3/bin:$PATH"
ENV LD_LIBRARY_PATH="/usr/local/cuda-12.3/lib64:/.singularity.d/libs:$LD_LIBRARY_PATH"

# ─── Stage 2: Node.js 24 LTS (for Mason / LSP servers) ──────────────────────
RUN curl -fsSL https://deb.nodesource.com/setup_24.x | bash - && \
    apt-get install -y nodejs && \
    rm -rf /var/lib/apt/lists/*

# ─── Stage 3: Python 3.13 via deadsnakes (env defaults to this, not 3.12) ───
# /usr/local/bin precedes /usr/bin in PATH, so the symlinks below make
# `python` and `python3` resolve to 3.13 even though Ubuntu's 3.12 stays installed.
RUN add-apt-repository -y ppa:deadsnakes/ppa && \
    apt-get update && \
    apt-get install -y \
        python3.13 \
        python3.13-dev \
        python3.13-venv \
        python3.13-full \
        python3.13-tk && \
    rm -rf /var/lib/apt/lists/* && \
    ln -sf /usr/bin/python3.13 /usr/local/bin/python3 && \
    ln -sf /usr/bin/python3.13 /usr/local/bin/python && \
    python3.13 -m ensurepip --upgrade && \
    python3.13 -m pip install --upgrade pip setuptools wheel

# Env vars so downstream tools (R reticulate, uv, LSPs, etc.) pick 3.13
ENV PYTHON=/usr/local/bin/python3
ENV PYTHON3=/usr/local/bin/python3
ENV RETICULATE_PYTHON=/usr/local/bin/python3
ENV UV_PYTHON=/usr/local/bin/python3

# ─── Stage 4: uv (Astral) — fast Python package + project manager ───────────
RUN UV_VERSION=$(curl -s https://api.github.com/repos/astral-sh/uv/releases/latest \
        | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/') && \
    echo "Installing uv ${UV_VERSION}" && \
    curl -L "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-x86_64-unknown-linux-gnu.tar.gz" \
        -o /tmp/uv.tar.gz && \
    tar -C /tmp -xzf /tmp/uv.tar.gz && \
    mv /tmp/uv-x86_64-unknown-linux-gnu/uv /usr/local/bin/uv && \
    mv /tmp/uv-x86_64-unknown-linux-gnu/uvx /usr/local/bin/uvx && \
    chmod +x /usr/local/bin/uv /usr/local/bin/uvx && \
    rm -rf /tmp/uv.tar.gz /tmp/uv-x86_64-unknown-linux-gnu

# ─── Stage 5: R 4.x (CRAN noble-cran40) + tidyverse build dependencies ──────
# Installs R base + dev headers.  The system libraries required to compile core
# tidyverse packages from source (libxml2, libcurl, libssl, libcairo2, libpng,
# libjpeg, libtiff5, libfontconfig, libfreetype, libharfbuzz, libfribidi,
# libgit2, libblas, liblapack) are already present from Stage 1.
# The packages below cover the remaining tidyverse / spatial / crypto deps:
#   libudunits2-dev  → units, terra, sf
#   libgdal-dev      → sf, terra, rgdal
#   libgeos-dev      → sf
#   libproj-dev      → sf
#   libsodium-dev    → sodium, openssl
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        libudunits2-dev \
        libgdal-dev \
        libgeos-dev \
        libproj-dev \
        libsodium-dev && \
    rm -rf /var/lib/apt/lists/* && \
    mkdir -p /etc/apt/keyrings && \
    wget -qO- https://cloud.r-project.org/bin/linux/ubuntu/marutter_pubkey.asc \
        | gpg --dearmor -o /etc/apt/keyrings/cran.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/cran.gpg] \
https://cloud.r-project.org/bin/linux/ubuntu noble-cran40/" \
        > /etc/apt/sources.list.d/cran.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        r-base \
        r-base-dev && \
    rm -rf /var/lib/apt/lists/*

# ─── Stage 5b: Posit Package Manager (PPM) as default R repo ────────────────
# PPM ships precompiled binary packages for Ubuntu Noble, so install.packages()
# pulls a .deb-like binary instead of compiling from source — turns a 10-minute
# tidyverse install into ~30 seconds. PPM gates binaries on a Linux user-agent;
# the HTTPUserAgent override below makes R announce itself correctly.
#
# Rolling "latest" channel — change to a YYYY-MM-DD date for reproducible builds.
RUN mkdir -p /etc/R && \
    cat > /etc/R/Rprofile.site << 'EOF'
# /etc/R/Rprofile.site — sourced on every R startup (system-wide).
# Configure the Posit Package Manager (PPM) as the default CRAN mirror so that
# install.packages() pulls Linux binary builds for Ubuntu Noble.
local({
  ppm <- "https://packagemanager.posit.co/cran/__linux__/noble/latest"
  r <- getOption("repos")
  r["CRAN"] <- ppm
  options(repos = r)

  # PPM serves binary packages only to clients whose User-Agent identifies the
  # platform.  R's default UA omits the OS, so PPM falls back to source tarballs.
  options(HTTPUserAgent = sprintf(
    "R/%s R (%s)",
    getRversion(),
    paste(getRversion(), R.version$platform, R.version$arch, R.version$os)
  ))
})
EOF

# ─── Stage 5c: Quarto (scientific publishing — .qmd → PDF/HTML/Word) ────────
# Quarto bundles its own pandoc and Deno runtime, so the only system dep is a
# LaTeX distribution for PDF output — NOT installed here to keep the image
# small.  Run `quarto install tinytex` on first use inside the container if
# you need PDF rendering.
RUN QUARTO_VERSION=$(curl -s https://api.github.com/repos/quarto-dev/quarto-cli/releases/latest \
        | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"v\([^"]*\)".*/\1/') && \
    echo "Installing Quarto ${QUARTO_VERSION}" && \
    curl -L "https://github.com/quarto-dev/quarto-cli/releases/download/v${QUARTO_VERSION}/quarto-${QUARTO_VERSION}-linux-amd64.tar.gz" \
        -o /tmp/quarto.tar.gz && \
    mkdir -p /opt/quarto && \
    tar -C /opt/quarto --strip-components=1 -xzf /tmp/quarto.tar.gz && \
    ln -sf /opt/quarto/bin/quarto /usr/local/bin/quarto && \
    rm /tmp/quarto.tar.gz && \
    /usr/local/bin/quarto --version

# ─── Stage 6: Neovim (latest stable binary, x86_64) ─────────────────────────
RUN NVIM_VERSION=$(curl -s https://api.github.com/repos/neovim/neovim/releases/latest \
        | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/') && \
    echo "Installing Neovim ${NVIM_VERSION}" && \
    curl -L "https://github.com/neovim/neovim/releases/download/${NVIM_VERSION}/nvim-linux-x86_64.tar.gz" \
        -o /tmp/nvim.tar.gz && \
    tar -C /usr/local --strip-components=1 -xzf /tmp/nvim.tar.gz && \
    rm /tmp/nvim.tar.gz

# ─── Stage 7: lazygit (LazyVim git UI) ──────────────────────────────────────
RUN LAZYGIT_VERSION=$(curl -s https://api.github.com/repos/jesseduffield/lazygit/releases/latest \
        | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"v\([^"]*\)".*/\1/') && \
    echo "Installing lazygit ${LAZYGIT_VERSION}" && \
    curl -L "https://github.com/jesseduffield/lazygit/releases/download/v${LAZYGIT_VERSION}/lazygit_${LAZYGIT_VERSION}_Linux_x86_64.tar.gz" \
        -o /tmp/lazygit.tar.gz && \
    tar -C /usr/local/bin -xzf /tmp/lazygit.tar.gz lazygit && \
    rm /tmp/lazygit.tar.gz

# ─── Stage 8: Yazi terminal file manager ────────────────────────────────────
RUN YAZI_VERSION=$(curl -s https://api.github.com/repos/sxyazi/yazi/releases/latest \
        | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/') && \
    echo "Installing Yazi ${YAZI_VERSION}" && \
    curl -L "https://github.com/sxyazi/yazi/releases/download/${YAZI_VERSION}/yazi-x86_64-unknown-linux-gnu.zip" \
        -o /tmp/yazi.zip && \
    unzip -o /tmp/yazi.zip -d /tmp/yazi_extracted && \
    cp /tmp/yazi_extracted/yazi-x86_64-unknown-linux-gnu/yazi /usr/local/bin/yazi && \
    cp /tmp/yazi_extracted/yazi-x86_64-unknown-linux-gnu/ya    /usr/local/bin/ya && \
    chmod +x /usr/local/bin/yazi /usr/local/bin/ya && \
    rm -rf /tmp/yazi.zip /tmp/yazi_extracted

# ─── Stage 8b: resvg (Yazi SVG preview) ─────────────────────────────────────
RUN RESVG_VERSION=$(curl -s https://api.github.com/repos/linebender/resvg/releases/latest \
        | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"v\([^"]*\)".*/\1/') && \
    echo "Installing resvg ${RESVG_VERSION}" && \
    curl -L "https://github.com/linebender/resvg/releases/download/v${RESVG_VERSION}/resvg-linux-x86_64.tar.gz" \
        -o /tmp/resvg.tar.gz && \
    tar -C /usr/local/bin -xzf /tmp/resvg.tar.gz resvg && \
    chmod +x /usr/local/bin/resvg && \
    rm /tmp/resvg.tar.gz

# ─── Stage 8c: fzf + zoxide (latest from GitHub) ────────────────────────────
# Install from GitHub releases instead of apt to guarantee the latest versions.
# Yazi's `z` interactive jump (zoxide --interactive → fzf) requires up-to-date
# binaries; the apt packages on Ubuntu 24.04 are ~2023 builds which can cause
# silent failures with newer yazi builds.
RUN FZF_VERSION=$(curl -s https://api.github.com/repos/junegunn/fzf/releases/latest \
        | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"v\?\([^"]*\)".*/\1/') && \
    echo "Installing fzf ${FZF_VERSION}" && \
    curl -L "https://github.com/junegunn/fzf/releases/download/v${FZF_VERSION}/fzf-${FZF_VERSION}-linux_amd64.tar.gz" \
        -o /tmp/fzf.tar.gz && \
    tar -C /usr/local/bin -xzf /tmp/fzf.tar.gz fzf && \
    chmod +x /usr/local/bin/fzf && \
    rm /tmp/fzf.tar.gz
RUN ZOXIDE_VERSION=$(curl -s https://api.github.com/repos/ajeetdsouza/zoxide/releases/latest \
        | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"v\?\([^"]*\)".*/\1/') && \
    echo "Installing zoxide ${ZOXIDE_VERSION}" && \
    curl -L "https://github.com/ajeetdsouza/zoxide/releases/download/v${ZOXIDE_VERSION}/zoxide-${ZOXIDE_VERSION}-x86_64-unknown-linux-musl.tar.gz" \
        -o /tmp/zoxide.tar.gz && \
    tar -C /usr/local/bin -xzf /tmp/zoxide.tar.gz zoxide && \
    chmod +x /usr/local/bin/zoxide && \
    rm /tmp/zoxide.tar.gz

# ─── Stage 8d: mac-open bridge ──────────────────────────────────────────────
# Pure-Python client that ships files/URLs to the Mac for opening.  Pairs with
# mac_open_listener.py running on the Mac and the SSH -R 8765 reverse forward
# in connect_nvim.sh.  No external deps — edit mac_open.py at the repo root
# to extend behavior; this stage just installs it.
COPY mac_open.py /usr/local/bin/mac-open
RUN chmod +x /usr/local/bin/mac-open

# ─── Stage 9: Zellij (terminal multiplexer) ─────────────────────────────────
RUN ZELLIJ_VERSION=$(curl -s https://api.github.com/repos/zellij-org/zellij/releases/latest \
        | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"v\([^"]*\)".*/\1/') && \
    echo "Installing Zellij ${ZELLIJ_VERSION}" && \
    curl -L "https://github.com/zellij-org/zellij/releases/download/v${ZELLIJ_VERSION}/zellij-x86_64-unknown-linux-musl.tar.gz" \
        -o /tmp/zellij.tar.gz && \
    tar -C /usr/local/bin -xzf /tmp/zellij.tar.gz zellij && \
    chmod +x /usr/local/bin/zellij && \
    rm /tmp/zellij.tar.gz

# ─── Stage 10: GitHub CLI ────────────────────────────────────────────────────
RUN mkdir -p -m 755 /etc/apt/keyrings && \
    wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null && \
    chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        | tee /etc/apt/sources.list.d/github-cli.list && \
    apt-get update && \
    apt-get install -y gh && \
    rm -rf /var/lib/apt/lists/*

# ─── Stage 10b: GitHub Copilot CLI extension ─────────────────────────────────
# Install to /usr/local/share/gh so the extension survives the Singularity
# runtime bind-mount that shadows /home/gson with the host home directory.
# Direct binary download avoids `gh auth login` requirement at build time.
ENV GH_DATA_DIR=/usr/local/share/gh
RUN GH_COPILOT_VERSION=$(curl -s https://api.github.com/repos/github/gh-copilot/releases/latest \
        | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/') && \
    echo "Installing gh-copilot extension ${GH_COPILOT_VERSION}" && \
    mkdir -p /usr/local/share/gh/extensions/gh-copilot && \
    curl -L "https://github.com/github/gh-copilot/releases/download/${GH_COPILOT_VERSION}/linux-amd64" \
        -o /usr/local/share/gh/extensions/gh-copilot/gh-copilot && \
    chmod +x /usr/local/share/gh/extensions/gh-copilot/gh-copilot && \
    chmod -R 755 /usr/local/share/gh

# ─── Stage 10c: SLURM client passthrough (host-binary binding) ──────────────
# The HPC cluster runs RHEL 7 with an old SLURM whose RPC protocol is not
# compatible with anything we could install via apt.  Instead, the launcher
# scripts (term_session.sh / dev_session.sh) bind-mount the host's SLURM
# binaries and their direct library deps into the locations created below.
#
# Layout at runtime:
#   /opt/host-slurm/bin/{squeue,sacct,…}  ← host /usr/bin/<cmd>
#   /opt/host-slurm/lib/<basename>.so     ← host libslurm*, libmunge*, plugins' deps
#   /usr/lib64/slurm/                     ← host plugin dir (path is absolute
#                                            in slurm.conf, so we mirror it)
#   /etc/slurm[-llnl]/slurm.conf          ← cluster config
#   /run/munge, /var/run/munge            ← munge auth socket
#
# Wrappers in /usr/local/bin/<cmd> exec the bound host binary with a SCOPED
# LD_LIBRARY_PATH so RHEL 7 libs (libslurm, libmunge) are used ONLY for
# these commands, never leaking to the rest of the container's newer glibc.
# The host binary's hard-coded PT_INTERP (/lib64/ld-linux-x86-64.so.2) is
# resolved against the container's Ubuntu ld.so + libc, which is
# forward-compatible with RHEL 7 binaries.
RUN mkdir -p /opt/host-slurm/bin /opt/host-slurm/lib \
             /usr/lib64/slurm \
             /etc/slurm /etc/slurm-llnl \
             /run/munge /var/run/munge /var/spool/slurm && \
    useradd -r -M -s /sbin/nologin slurm 2>/dev/null || true && \
    for cmd in squeue sacct sbatch srun sinfo scancel scontrol salloc \
               sstat sprio sshare sreport sacctmgr sbcast sdiag sattach \
               sgather sview sinfo sjstat; do \
        printf '%s\n' \
            '#!/bin/sh' \
            '# Auto-generated wrapper: exec host SLURM binary with scoped LD_LIBRARY_PATH.' \
            'cmd="${0##*/}"' \
            'if [ ! -x "/opt/host-slurm/bin/${cmd}" ]; then' \
            '    echo "${cmd}: host SLURM binary not bound at /opt/host-slurm/bin/${cmd}." >&2' \
            '    echo "Did the launcher script run on a node with SLURM installed?" >&2' \
            '    exit 127' \
            'fi' \
            'export LD_LIBRARY_PATH="/opt/host-slurm/lib:/usr/lib64/slurm:${LD_LIBRARY_PATH}"' \
            'exec "/opt/host-slurm/bin/${cmd}" "$@"' \
            > "/usr/local/bin/${cmd}" && \
        chmod +x "/usr/local/bin/${cmd}"; \
    done

# ─── Stage 11: Claude Code + GitHub Copilot language server + tree-sitter ────
# @anthropic-ai/claude-code   : Anthropic Claude terminal coding agent.
# @github/copilot-language-server : GitHub Copilot LSP backend used by Neovim
#     Copilot plugins (copilot.lua, avante.nvim, etc.).  The gh copilot CLI
#     extension (Stage 10b) provides `gh copilot suggest/explain`; this package
#     provides inline completion and chat via the LSP protocol.
# tree-sitter-cli             : required by nvim-treesitter to compile parsers.
RUN npm install -g @anthropic-ai/claude-code @github/copilot-language-server tree-sitter-cli

# ─── Stage 11b: Starship prompt ──────────────────────────────────────────────
RUN curl -sS https://starship.rs/install.sh | sh -s -- --yes

# ─── Stage 12: Build-time user (default UID/GID; runtime UID comes from host) ─
# At HPC runtime Singularity uses the host user's UID/GID/groups, so the
# build-time UID here is irrelevant for file access. We use the default (1000)
# because rootless podman's user namespace can't map the HPC's high IDs
# (UID 70230911, GIDs 663800067/663800106) — crun's setresuid/setgroups would fail.
RUN useradd -m -s /bin/zsh gson && \
    echo "gson ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

# NOTE: LazyVim config is NOT bootstrapped here.
# Singularity bind-mounts /home/g/gson → /home/gson at runtime, so anything
# written to ~/.config/nvim during the build would be hidden at runtime.
# Set up LazyVim on CIRCE directly (see README for steps).

ENV HOME=/home/gson
ENV SHELL=/bin/zsh
ENV XDG_CONFIG_HOME=/home/gson/.config
ENV XDG_DATA_HOME=/home/gson/.local/share
ENV XDG_STATE_HOME=/home/gson/.local/state
ENV XDG_CACHE_HOME=/home/gson/.cache

# ─── Final configuration ────────────────────────────────────────────────────
# Aliases go into /etc/zsh/zshrc (sourced by all interactive zsh sessions)
# rather than ~/.zshrc, because the home dir is bind-mounted from the host
# at runtime and overwrites the image's copy.
RUN ln -sf "$(which fdfind)" /usr/local/bin/fd 2>/dev/null || true && \
    mkdir -p /etc/zsh && \
    cat > /etc/zsh/zshenv << 'EOF'
# ──────────────────────────────────────────────────────────────────────────────
# /etc/zsh/zshenv — sourced by EVERY zsh invocation (login, interactive,
# non-interactive `zsh -c`, scripts).  We keep environment exports here so that
# zellij/yazi/scp/tmux/etc. that spawn `zsh -c '…'` inherit the right env.
# Aliases and interactive integrations go in /etc/zsh/zshrc.
# ──────────────────────────────────────────────────────────────────────────────

# ── container PATH (prepend so container binaries win over host copies) ──────
# Singularity inherits the host PATH; be explicit so /usr/local/bin tools
# (nvim, starship, lazygit, uv, …) are always found.
export PATH="/usr/local/bin:/usr/local/cuda-12.3/bin:$HOME/.local/bin:$PATH"

# ── Make zsh the default for child shells (zellij, tmux, scripts) ────────────
# CIRCE's /etc/passwd sets login shell to bash, which is inherited via the
# bind-mounted home.  Force SHELL=zsh inside the container so zellij and
# other terminal multiplexers spawn zsh panes by default.
export SHELL=/bin/zsh

# ── XDG base dirs: use runtime $HOME, not the build-time /home/gson path ─────
# The Dockerfile ENV hardcodes /home/gson/.*, but Singularity bind-mounts the
# real user home (e.g. /home/g/gson) at runtime, making those paths wrong.
export XDG_CONFIG_HOME="${HOME}/.config"
export XDG_DATA_HOME="${HOME}/.local/share"
export XDG_STATE_HOME="${HOME}/.local/state"

# ── Neovim XDG cache on node-local /tmp ──────────────────────────────────────
# BGFS/NFS home dirs cause extremely slow nvim startup because the Lua
# bytecode cache (luac/) and tree-sitter parser cache live in XDG_CACHE_HOME.
# Redirecting to /tmp (local disk) keeps the cache fast.
export XDG_CACHE_HOME="/tmp/${USER}/.cache"
mkdir -p "${XDG_CACHE_HOME}/nvim" 2>/dev/null

# ── Neovim data/state on node-local /tmp via symlinks ────────────────────────
# Quobyte/BeeGFS network home incurs ~1.2 ms per file × thousands of files
# when nvim loads the LazyVim plugin tree (~3600 .lua files, 12k inodes),
# producing multi-second cold starts.  Local ext3 /tmp is ~88× faster.
# We symlink the two hot directories into /tmp/$USER while leaving
# ~/.config/nvim on the network home (small, must persist, edited rarely).
#
# Trade-off: /tmp is node-local and may be wiped between SLURM allocations.
# If the symlink target is missing, nvim will simply re-bootstrap plugins
# on next launch (:Lazy sync, :MasonInstall).
#
# Safety: we only create the symlink when ~/.local/share/nvim (or state)
# either does not exist or is already a symlink.  If a real directory with
# content is present, we leave it untouched so existing data is not hidden;
# migrate it manually with:
#   mv ~/.local/share/nvim /tmp/${USER}/.local/share/nvim
#   mv ~/.local/state/nvim /tmp/${USER}/.local/state/nvim
for _nv_sub in share/nvim state/nvim; do
    _nv_src="${HOME}/.local/${_nv_sub}"
    _nv_dst="/tmp/${USER}/.local/${_nv_sub}"
    mkdir -p "${_nv_dst}" 2>/dev/null
    mkdir -p "$(dirname "${_nv_src}")" 2>/dev/null
    if [ -L "${_nv_src}" ] || [ ! -e "${_nv_src}" ]; then
        ln -sfn "${_nv_dst}" "${_nv_src}" 2>/dev/null
    fi
done
unset _nv_sub _nv_src _nv_dst

# ── Default editor (yazi uses $EDITOR / $VISUAL to open files) ───────────────
export EDITOR=nvim
export VISUAL=nvim

# ── Terminal color capability ─────────────────────────────────────────────────
# Declare 24-bit color support explicitly so tools like yazi, bat, and delta
# do not need to query the terminal via DA1/XTVERSION escape sequences.
# Without this, newer yazi probes the terminal at startup; the probe round-trips
# through SSH + Singularity and times out, printing "Terminal response timeout".
export COLORTERM=truecolor
# Ensure TERM is explicit — Singularity sometimes clears it.
: "${TERM:=xterm-256color}"
export TERM

# ── SLURM client config discovery ────────────────────────────────────────────
# squeue/sacct/sbatch read $SLURM_CONF first.  Host clusters may put the
# config at /etc/slurm/slurm.conf (modern) or /etc/slurm-llnl/slurm.conf
# (older Debian/Ubuntu).  Both mount points are pre-created in the image
# and bind-mounted (when present on the host) by the launcher scripts.
if [ -z "${SLURM_CONF:-}" ]; then
    if [ -f /etc/slurm/slurm.conf ]; then
        export SLURM_CONF=/etc/slurm/slurm.conf
    elif [ -f /etc/slurm-llnl/slurm.conf ]; then
        export SLURM_CONF=/etc/slurm-llnl/slurm.conf
    fi
fi

# ── GitHub CLI data directory ─────────────────────────────────────────────────
# gh looks here for extensions (including gh-copilot).  The Docker ENV is set
# at build time, but Singularity --cleanenv drops it; re-export here so
# `gh copilot suggest/explain` always finds the extension at runtime.
export GH_DATA_DIR=/usr/local/share/gh
EOF
RUN cat >> /etc/zsh/zshrc << 'EOF'

# ── container aliases (interactive only) ─────────────────────────────────────
alias vi="nvim"
alias vim="nvim"

# ── yazi shell wrapper ────────────────────────────────────────────────────────
# Official wrapper from yazi-rs.github.io/docs/quick-start.
# Use `y` instead of `yazi` so the shell follows yazi's working directory
# on exit, AND so the `z` key (zoxide --interactive → fzf) gets proper
# terminal handoff inside the multiplexer.
function y() {
    local tmp cwd _sz _cols _rows
    # Resolve terminal dimensions in priority order:
    #
    #   1. stty size — reads TIOCGWINSZ directly from the PTY fd.  Correct for
    #      zellij panes (zellij sets each pane's PTY size) and for any resize
    #      (SSH sends TIOCSWINSZ + SIGWINCH on the remote PTY after a resize,
    #      making TIOCGWINSZ reliable immediately afterwards).
    #
    #   2. _SSH_COLS / _SSH_ROWS — injected by connect_nvim.sh from stty size on
    #      the Mac terminal at connect time.  zsh will NOT overwrite these names
    #      (unlike $COLUMNS/$LINES, which zsh resets from TIOCGWINSZ during its
    #      own interactive-init sequence, potentially stamping wrong defaults).
    #
    #   3. Hard defaults (80 × 24).
    _sz=$(stty size 2>/dev/null)        # "rows cols", e.g. "60 220"
    _cols="${_sz##* }" _rows="${_sz%% *}"
    (( ${_cols:-0} > 0 && ${_rows:-0} > 0 )) 2>/dev/null || {
        _cols="${_SSH_COLS:-80}" _rows="${_SSH_ROWS:-24}"
    }
    stty cols "$_cols" rows "$_rows" 2>/dev/null
    tmp="$(mktemp -t "yazi-cwd.XXXXXX")"
    COLUMNS="$_cols" LINES="$_rows" yazi "$@" --cwd-file="$tmp"
    if cwd="$(command cat -- "$tmp")" && [ -n "$cwd" ] && [ "$cwd" != "$PWD" ]; then
        builtin cd -- "$cwd"
    fi
    rm -f -- "$tmp"
}

# ── SIGWINCH trap: refresh _SSH_COLS/_SSH_ROWS and the kernel PTY record ───────
# After a terminal resize, SSH calls TIOCSWINSZ on the remote PTY and sends
# SIGWINCH.  TIOCGWINSZ is then valid; capture the new values into
# _SSH_COLS/_SSH_ROWS so the next `y` launch uses post-resize dimensions.
TRAPWINCH() {
    local _sz
    _sz=$(stty size 2>/dev/null)
    _SSH_COLS="${_sz##* }" _SSH_ROWS="${_sz%% *}"
    (( ${_SSH_COLS:-0} > 0 )) 2>/dev/null || _SSH_COLS="${COLUMNS:-80}"
    (( ${_SSH_ROWS:-0} > 0 )) 2>/dev/null || _SSH_ROWS="${LINES:-24}"
    stty cols "${_SSH_COLS}" rows "${_SSH_ROWS}" 2>/dev/null
}

# ── shell integrations (interactive only) ────────────────────────────────────
eval "$(zoxide init zsh)"
eval "$(fzf --zsh)"
eval "$(starship init zsh)"

# ── fzf appearance and file-picker defaults ──────────────────────────────────
# These apply to Ctrl-R (history), Ctrl-T (files), Alt-C (cd), and yazi's
# internal fzf calls (the Z key / zoxide --interactive).
export FZF_DEFAULT_OPTS='--height=40% --layout=reverse --border --info=inline'
export FZF_DEFAULT_COMMAND='fd --type f --hidden --follow --exclude .git'
export FZF_CTRL_T_COMMAND="${FZF_DEFAULT_COMMAND}"
export FZF_ALT_C_COMMAND='fd --type d --hidden --follow --exclude .git'
EOF

CMD ["/bin/zsh"]
USER gson
