# Fintech Tools Container
# Base: Ubuntu 24.04 LTS (Noble Numbat) — headless server edition
FROM ubuntu:24.04

LABEL maintainer="Matthew Son"
LABEL description="HPC container: Neovim + Python 3.13 + uv"
LABEL version="0.6"

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
    libz-dev \
    libbz2-dev \
    liblz4-dev \
    libzstd-dev \
    libsnappy-dev \
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
    # Neovim / LazyVim CLI deps
    ripgrep \
    fd-find \
    fzf \
    unzip \
    # Yazi required + recommended optional deps (per yazi-rs.github.io/docs/installation)
    file \
    ffmpeg \
    p7zip-full \
    jq \
    poppler-utils \
    imagemagick \
    xclip \
    zoxide \
    unar \
    # Terminfo (ghostty + many others) for SSH terminal compatibility
    ncurses-term \
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

# ─── Stage 2: Node.js 20 LTS (for Mason / LSP servers) ──────────────────────
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && \
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

# R is intentionally NOT installed in this image (dropped in v0.6 — too slow
# to compile R + CRAN packages from source). Re-add as a separate stage if
# needed; see git history for the previous CRAN noble-cran40 setup.

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

# ─── Stage 9: Zellij (terminal multiplexer) ─────────────────────────────────
RUN ZELLIJ_VERSION=$(curl -s https://api.github.com/repos/zellij-org/zellij/releases/latest \
        | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"v\([^"]*\)".*/\1/') && \
    echo "Installing Zellij ${ZELLIJ_VERSION}" && \
    curl -L "https://github.com/zellij-org/zellij/releases/download/v${ZELLIJ_VERSION}/zellij-x86_64-unknown-linux-musl.tar.gz" \
        -o /tmp/zellij.tar.gz && \
    tar -C /usr/local/bin -xzf /tmp/zellij.tar.gz zellij && \
    chmod +x /usr/local/bin/zellij && \
    rm /tmp/zellij.tar.gz

# ─── Stage 10: GitHub CLI + Copilot extension ───────────────────────────────
RUN mkdir -p -m 755 /etc/apt/keyrings && \
    wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null && \
    chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        | tee /etc/apt/sources.list.d/github-cli.list && \
    apt-get update && \
    apt-get install -y gh && \
    rm -rf /var/lib/apt/lists/*

# ─── Stage 11: Claude Code CLI (global npm install) ─────────────────────────
RUN npm install -g @anthropic-ai/claude-code

# ─── Stage 12: Build-time user (default UID/GID; runtime UID comes from host) ─
# At HPC runtime Singularity uses the host user's UID/GID/groups, so the
# build-time UID here is irrelevant for file access. We use the default (1000)
# because rootless podman's user namespace can't map the HPC's high IDs
# (UID 70230911, GIDs 663800067/663800106) — crun's setresuid/setgroups would fail.
RUN useradd -m -s /bin/bash gson && \
    echo "gson ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

# NOTE: LazyVim config is NOT bootstrapped here.
# Singularity bind-mounts /home/g/gson → /home/gson at runtime, so anything
# written to ~/.config/nvim during the build would be hidden at runtime.
# Set up LazyVim on CIRCE directly (see README for steps).

ENV HOME=/home/gson
ENV XDG_CONFIG_HOME=/home/gson/.config
ENV XDG_DATA_HOME=/home/gson/.local/share
ENV XDG_STATE_HOME=/home/gson/.local/state
ENV XDG_CACHE_HOME=/home/gson/.cache

# ─── Final configuration ────────────────────────────────────────────────────
# Aliases and the yazi shell function go into /etc/bash.bashrc (sourced by
# all interactive bash sessions) rather than ~/.bashrc, because the home dir
# is bind-mounted from the host at runtime and overwrites the image's copy.
RUN ln -sf "$(which fdfind)" /usr/local/bin/fd 2>/dev/null || true && \
    cat >> /etc/bash.bashrc << 'EOF'

# ── container aliases ────────────────────────────────────────────────────────
export PATH="$HOME/.local/bin:$PATH"
alias vi="nvim"
alias vim="nvim"

# ── yazi: `y` opens yazi; quitting with q cd's the shell to the last dir ────
function y() {
    local tmp cwd
    tmp="$(mktemp -t "yazi-cwd.XXXXXX")"
    yazi "$@" --cwd-file="$tmp"
    if cwd="$(command cat -- "$tmp")" && [ -n "$cwd" ] && [ "$cwd" != "$PWD" ]; then
        builtin cd -- "$cwd"
    fi
    rm -f -- "$tmp"
}
EOF

CMD ["/bin/bash"]
USER gson
