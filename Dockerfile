# Fintech Tools Container
# Base: Ubuntu 24.04 LTS (Noble Numbat) — headless server edition
FROM ubuntu:24.04

LABEL maintainer="Matthew Son"
LABEL description="HPC container: Neovim + Python 3.13 + uv + R 4.x + Copilot CLI + TinyTeX + sioyek"
LABEL version="0.8"

# ─── Version pins — bump here to upgrade any tool ────────────────────────────
ARG UV_VERSION=0.11.21
ARG QUARTO_VERSION=1.9.38
ARG TINYTEX_TAG=v2026.06
ARG NVIM_VERSION=v0.12.3
ARG LAZYGIT_VERSION=0.62.2
ARG YAZI_VERSION=v26.5.6
ARG RESVG_VERSION=0.47.0
ARG FZF_VERSION=0.73.1
ARG ZOXIDE_VERSION=0.9.9
ARG BOTTOM_VERSION=0.12.3
# sioyek = VimTeX's synctex-capable PDF viewer; pinned to match the Mac install.
ARG SIOYEK_VERSION=v2.0.0

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=America/New_York
ENV LC_ALL=C.UTF-8
ENV LANG=C.UTF-8

# Singularity library path (preserved for HPC compatibility)
ENV LD_LIBRARY_PATH="/.singularity.d/libs:$LD_LIBRARY_PATH"

WORKDIR /work/g/gson

# ─── Stage 0: Apt resilience ────────────────────────────────────────────────
# Ubuntu's archive/security mirrors occasionally hand out an in-progress
# Packages.gz whose size disagrees with the freshly-published Release file
# ("File has unexpected size … Mirror sync in progress?").  apt's default
# retry count is 0, so a single hash/size miss aborts the whole `apt-get
# update`.  Bump retries + per-request timeout so transient mirror windows
# don't kill the build.
RUN printf '%s\n' \
        'Acquire::Retries "5";' \
        'Acquire::http::Timeout "60";' \
        'Acquire::https::Timeout "60";' \
        > /etc/apt/apt.conf.d/99-retries

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
    p7zip-full \
    jq \
    poppler-utils \
    imagemagick \
    unar \
    # Terminfo (ghostty + many others) for SSH terminal compatibility
    ncurses-term \
    # clear command
    ncurses-bin \
    # General utilities
    pandoc \
    git \
    rsync \
    # tmux: terminal multiplexer (persistent panes/sessions across reconnects).
    # Chosen over zellij here because a fresh zellij session is multi-second slow
    # under proot — its WASM plugin runtime + async plugin handshake fire a huge
    # number of syscalls at *create*, and PROOT_NO_SECCOMP=1 ptraces every one.
    # tmux is a lean C server with a built-in status line (no interpreter, no
    # plugin protocol), so a fresh session creates in ~0.03s on the same node.
    tmux \
    nano \
    vim \
    wget \
    curl \
    openssh-client \
    man-db \
    less \
    zsh && \
    locale-gen en_US.UTF-8 && \
    usermod -s /bin/zsh root && \
    rm -rf /var/lib/apt/lists/*

# Note: ghostty terminfo is not shipped here. ghostty generates it from Zig
# source at build time, so there is no raw file to fetch. After deploying the
# container, install it once from your Mac:
#   infocmp -x xterm-ghostty | ssh <ssh-target> -- tic -x -
# (per https://ghostty.org/docs/help/terminfo). ncurses-term covers most others.

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
        python3.13-venv && \
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
RUN UV_VERSION=${UV_VERSION} && \
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
# The packages below cover the remaining tidyverse / crypto deps:
#   libsodium-dev    → sodium, openssl
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
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
# Quarto bundles its own pandoc and Deno runtime.  LaTeX for PDF output is
# provided by Stage 5d (TinyTeX) below.
RUN QUARTO_VERSION=${QUARTO_VERSION} && \
    echo "Installing Quarto ${QUARTO_VERSION}" && \
    curl -L "https://github.com/quarto-dev/quarto-cli/releases/download/v${QUARTO_VERSION}/quarto-${QUARTO_VERSION}-linux-amd64.tar.gz" \
        -o /tmp/quarto.tar.gz && \
    mkdir -p /opt/quarto && \
    tar -C /opt/quarto --strip-components=1 -xzf /tmp/quarto.tar.gz && \
    ln -sf /opt/quarto/bin/quarto /usr/local/bin/quarto && \
    rm /tmp/quarto.tar.gz && \
    /usr/local/bin/quarto --version

# ─── Stage 5d: TinyTeX (LaTeX for Quarto / RMarkdown / VimTeX PDF output) ───
# Direct tarball install — no R/Rscript dependency.  Pulls the same prebuilt
# bundle that `tinytex::install_tinytex()` fetches under the hood from the
# rstudio/tinytex-releases GitHub repo, then extracts it straight to
# /opt/TinyTeX.  Faster and removes Stage 5/5b ordering coupling.
#
# Why not the upstream shell installer (yihui.org/tinytex/install-bin-unix.sh)?
#   1. It always appends ".TinyTeX" to $TINYTEX_DIR — so TINYTEX_DIR=/opt/TinyTeX
#      resolves to TEXDIR=/opt/TinyTeX/.TinyTeX, then `tar -C /opt/TinyTeX`
#      fails because the parent dir doesn't exist.
#   2. It pins sys_bin to $HOME/.local/bin — during docker build that's
#      /root/.local/bin, which is not on anyone's PATH at runtime.
# The tarball-direct route sidesteps both: `--strip-components=1` normalises
# the .TinyTeX/ layout into /opt/TinyTeX/, and the explicit `tlmgr option
# sys_bin /usr/local/bin` + `tlmgr path add` routes binary symlinks into
# /usr/local/bin so VimTeX, Quarto, and `rmarkdown::render()` find them on
# $PATH out of the box.
#
# Ships:
#   - Default TinyTeX (latex, pdflatex, xelatex, lualatex, latexmk, tlmgr)
#   - collection-latexrecommended  (amsmath, hyperref, geometry, tools, …)
#   - collection-fontsrecommended  (font packages used by most templates)
#   - biber + biblatex             (modern bibliography stack — not in default)
#
# /opt/TinyTeX is read-only at runtime under Singularity SIF.  For extra
# packages, install at runtime in user-mode — writes to $TEXMFHOME, which
# zshenv pins to ~/texmf (kpathsea picks it up automatically at compile time):
#   tlmgr --usermode init-usertree   # one-time: creates ~/texmf tree
#   tlmgr --usermode install <pkg>
# Or rebuild the container with the package appended to the tlmgr install line.
RUN rm -rf /opt/TinyTeX && \
    TINYTEX_TAG=${TINYTEX_TAG} && \
    echo "Installing TinyTeX ${TINYTEX_TAG} (default bundle, linux-x86_64)" && \
    curl -fL "https://github.com/rstudio/tinytex-releases/releases/download/${TINYTEX_TAG}/TinyTeX-linux-x86_64-${TINYTEX_TAG}.tar.xz" \
        -o /tmp/tinytex.tar.xz && \
    mkdir -p /opt/TinyTeX && \
    tar -C /opt/TinyTeX --strip-components=1 -xJf /tmp/tinytex.tar.xz && \
    rm /tmp/tinytex.tar.xz && \
    /opt/TinyTeX/bin/x86_64-linux/tlmgr option sys_bin /usr/local/bin && \
    /opt/TinyTeX/bin/x86_64-linux/tlmgr path add && \
    # The bundled tlmgr (texlive.infra) is often older than the revision on the
    # repo (tlnet.yihui.org), and tlmgr then HARD-REFUSES every `install` with
    # "tlmgr itself needs to be updated".  Self-update first so installs proceed.
    # (gnupg from Stage 1 lets tlmgr verify the repo signature.)
    /opt/TinyTeX/bin/x86_64-linux/tlmgr update --self && \
    /opt/TinyTeX/bin/x86_64-linux/tlmgr install \
        collection-latexrecommended \
        collection-fontsrecommended \
        biber \
        biblatex && \
    /opt/TinyTeX/bin/x86_64-linux/tlmgr path add && \
    /usr/local/bin/latexmk --version >/dev/null && \
    /usr/local/bin/pdflatex --version | head -1

# ─── Stage 5e: sioyek + X11 runtime (VimTeX synctex viewer) ─────────────────
# VimTeX's PDF viewer. Unlike the mac-open bridge (which ships a *copy* of the
# PDF to the Mac and so cannot carry synctex), sioyek runs INSIDE this container
# on the compute node and renders to the Mac's XQuartz over SSH X11 forwarding
# (connect_nvim.sh adds -Y). Because nvim and sioyek are co-located, VimTeX's
# forward search (<localleader>lv) AND inverse search (click the PDF to jump
# nvim to the source line) work natively — no cross-machine protocol needed.
#
# Two parts:
#   1. apt: the low-level X11 / xcb / OpenGL / xkbcommon runtime that even the
#      bundled-Qt sioyek dlopens, plus squashfs-tools (to unpack the AppImage at
#      build time, below) and xauth (so the container can read the SSH-forwarded
#      X cookie). libxcb-cursor0 is harmless extra cover should upstream move to
#      Qt6 later (this 2.0.0 build bundles Qt5).
#   2. sioyek itself. Upstream ships ONLY an AppImage for Linux (both the
#      "portable" and plain zips contain the same Sioyek-x86_64.AppImage), pinned
#      to the same 2.0.0 the Mac runs. AppImages need FUSE to self-mount — which
#      proot can't provide — and the amd64 runtime can't even exec under this
#      emulated (arm64-host) build. So we DON'T run it: we compute the squashfs
#      offset straight from the AppImage's ELF header and unsquashfs the payload.
#      The unpacked binary (usr/bin/sioyek) self-locates its bundled Qt5 via
#      RUNPATH=$ORIGIN/../lib and finds the xcb platform plugin via the adjacent
#      usr/bin/qt.conf, so the PATH wrapper just execs it (xcb forced, MIT-SHM
#      off for network X).
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        libgl1 \
        libegl1 \
        libopengl0 \
        libglx-mesa0 \
        libx11-6 \
        libx11-xcb1 \
        libxcb1 \
        libxcb-cursor0 \
        libxcb-glx0 \
        libxcb-icccm4 \
        libxcb-image0 \
        libxcb-keysyms1 \
        libxcb-randr0 \
        libxcb-render0 \
        libxcb-render-util0 \
        libxcb-shape0 \
        libxcb-shm0 \
        libxcb-sync1 \
        libxcb-util1 \
        libxcb-xfixes0 \
        libxcb-xinerama0 \
        libxcb-xkb1 \
        libxkbcommon0 \
        libxkbcommon-x11-0 \
        libxrender1 \
        libxext6 \
        libxi6 \
        libsm6 \
        libice6 \
        libdbus-1-3 \
        libglib2.0-0 \
        fontconfig \
        fonts-dejavu-core \
        squashfs-tools \
        xauth && \
    rm -rf /var/lib/apt/lists/*

RUN SIOYEK_VERSION=${SIOYEK_VERSION} && \
    echo "Installing sioyek ${SIOYEK_VERSION} (AppImage payload via unsquashfs, no FUSE)" && \
    curl -fL "https://github.com/ahrm/sioyek/releases/download/${SIOYEK_VERSION}/sioyek-release-linux-portable.zip" \
        -o /tmp/sioyek.zip && \
    mkdir -p /tmp/sioyek-zip && \
    unzip -q /tmp/sioyek.zip -d /tmp/sioyek-zip && \
    SIOYEK_AI="$(find /tmp/sioyek-zip -type f -name '*.AppImage' | head -1)" && \
    { [ -n "$SIOYEK_AI" ] || { echo "ERROR: no .AppImage inside sioyek zip" >&2; exit 1; }; } && \
    printf '%s\n' \
        'import struct,sys' \
        'd=open(sys.argv[1],"rb").read(64)' \
        'shoff=struct.unpack_from("<Q",d,0x28)[0]' \
        'shentsize=struct.unpack_from("<H",d,0x3a)[0]' \
        'shnum=struct.unpack_from("<H",d,0x3c)[0]' \
        'print(shoff+shentsize*shnum)' \
        > /tmp/elf_end.py && \
    SIOYEK_OFF="$(python3 /tmp/elf_end.py "$SIOYEK_AI")" && \
    echo "sioyek AppImage squashfs offset: $SIOYEK_OFF" && \
    mkdir -p /opt/sioyek && \
    unsquashfs -f -d /opt/sioyek -o "$SIOYEK_OFF" "$SIOYEK_AI" && \
    { [ -x /opt/sioyek/usr/bin/sioyek ] || { echo "ERROR: sioyek binary missing after unsquashfs" >&2; exit 1; }; } && \
    rm -rf /tmp/sioyek.zip /tmp/sioyek-zip /tmp/elf_end.py && \
    printf '%s\n' \
        '#!/bin/sh' \
        '# sioyek launch wrapper (Dockerfile Stage 5e).' \
        '# Force the xcb platform and disable MIT-SHM (unavailable over network X /' \
        '# XQuartz-via-SSH; otherwise Qt crashes or renders blank). The binary self-' \
        '# locates its bundled Qt5 via RUNPATH ($ORIGIN/../lib) and usr/bin/qt.conf;' \
        '# LD_LIBRARY_PATH is belt-and-suspenders.' \
        'export QT_QPA_PLATFORM=xcb' \
        'export QT_X11_NO_MITSHM=1' \
        'export LD_LIBRARY_PATH="/opt/sioyek/usr/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"' \
        'exec /opt/sioyek/usr/bin/sioyek "$@"' \
        > /usr/local/bin/sioyek && \
    chmod +x /usr/local/bin/sioyek && \
    echo "sioyek installed -> /opt/sioyek/usr/bin/sioyek"

# ─── Stage 6: Neovim (pinned stable binary, x86_64) ─────────────────────────
RUN NVIM_VERSION=${NVIM_VERSION} && \
    echo "Installing Neovim ${NVIM_VERSION}" && \
    curl -L "https://github.com/neovim/neovim/releases/download/${NVIM_VERSION}/nvim-linux-x86_64.tar.gz" \
        -o /tmp/nvim.tar.gz && \
    tar -C /usr/local --strip-components=1 -xzf /tmp/nvim.tar.gz && \
    rm /tmp/nvim.tar.gz

# ─── Stage 7: lazygit (LazyVim git UI) ──────────────────────────────────────
RUN LAZYGIT_VERSION=${LAZYGIT_VERSION} && \
    echo "Installing lazygit ${LAZYGIT_VERSION}" && \
    curl -L "https://github.com/jesseduffield/lazygit/releases/download/v${LAZYGIT_VERSION}/lazygit_${LAZYGIT_VERSION}_Linux_x86_64.tar.gz" \
        -o /tmp/lazygit.tar.gz && \
    tar -C /usr/local/bin -xzf /tmp/lazygit.tar.gz lazygit && \
    rm /tmp/lazygit.tar.gz

# ─── Stage 8: Yazi terminal file manager ────────────────────────────────────
RUN YAZI_VERSION=${YAZI_VERSION} && \
    echo "Installing Yazi ${YAZI_VERSION}" && \
    curl -L "https://github.com/sxyazi/yazi/releases/download/${YAZI_VERSION}/yazi-x86_64-unknown-linux-gnu.zip" \
        -o /tmp/yazi.zip && \
    unzip -o /tmp/yazi.zip -d /tmp/yazi_extracted && \
    cp /tmp/yazi_extracted/yazi-x86_64-unknown-linux-gnu/yazi /usr/local/bin/yazi && \
    cp /tmp/yazi_extracted/yazi-x86_64-unknown-linux-gnu/ya    /usr/local/bin/ya && \
    chmod +x /usr/local/bin/yazi /usr/local/bin/ya && \
    rm -rf /tmp/yazi.zip /tmp/yazi_extracted

# ─── Stage 8b: resvg (Yazi SVG preview) ─────────────────────────────────────
RUN RESVG_VERSION=${RESVG_VERSION} && \
    echo "Installing resvg ${RESVG_VERSION}" && \
    curl -L "https://github.com/linebender/resvg/releases/download/v${RESVG_VERSION}/resvg-linux-x86_64.tar.gz" \
        -o /tmp/resvg.tar.gz && \
    tar -C /usr/local/bin -xzf /tmp/resvg.tar.gz resvg && \
    chmod +x /usr/local/bin/resvg && \
    rm /tmp/resvg.tar.gz

# ─── Stage 8c: fzf + zoxide (pinned from GitHub) ────────────────────────────
# Install from GitHub releases instead of apt to guarantee the latest versions.
# Yazi's `z` interactive jump (zoxide --interactive → fzf) requires up-to-date
# binaries; the apt packages on Ubuntu 24.04 are ~2023 builds which can cause
# silent failures with newer yazi builds.
RUN FZF_VERSION=${FZF_VERSION} && \
    echo "Installing fzf ${FZF_VERSION}" && \
    curl -L "https://github.com/junegunn/fzf/releases/download/v${FZF_VERSION}/fzf-${FZF_VERSION}-linux_amd64.tar.gz" \
        -o /tmp/fzf.tar.gz && \
    tar -C /usr/local/bin -xzf /tmp/fzf.tar.gz fzf && \
    chmod +x /usr/local/bin/fzf && \
    rm /tmp/fzf.tar.gz
RUN ZOXIDE_VERSION=${ZOXIDE_VERSION} && \
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

# ─── Stage 8e: bottom (process/system monitor — replaces htop) ───────────────
RUN BOTTOM_VERSION=${BOTTOM_VERSION} && \
    echo "Installing bottom ${BOTTOM_VERSION}" && \
    curl -L "https://github.com/ClementTsang/bottom/releases/download/${BOTTOM_VERSION}/bottom_x86_64-unknown-linux-gnu.tar.gz" \
        -o /tmp/bottom.tar.gz && \
    tar -C /usr/local/bin -xzf /tmp/bottom.tar.gz btm && \
    chmod +x /usr/local/bin/btm && \
    rm /tmp/bottom.tar.gz

# Terminal multiplexer (tmux) is installed from apt in Stage 1 — see the note
# there for why tmux replaced zellij in this image.

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
               sgather sview sjstat; do \
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

# ─── Stage 11: AI CLIs + GitHub Copilot LSP + tree-sitter ───────────────────
# @anthropic-ai/claude-code       : Anthropic Claude terminal coding agent.
# @github/copilot                 : GitHub Copilot standalone CLI (invoked as `copilot`).
#                                   Replaces the deprecated `gh-copilot` extension.
# @github/copilot-language-server : GitHub Copilot LSP backend for Neovim
#     Copilot plugins (copilot.lua, avante.nvim) — inline completions + chat.
# tree-sitter-cli                 : required by nvim-treesitter to compile parsers.
RUN npm install -g @anthropic-ai/claude-code @github/copilot @github/copilot-language-server tree-sitter-cli

# ─── Stage 11b: Starship prompt ──────────────────────────────────────────────
RUN curl -sS https://starship.rs/install.sh | sh -s -- --yes

# ─── Stage 12: Build-time user (default UID/GID; runtime UID comes from host) ─
# At HPC runtime Singularity uses the host user's UID/GID/groups, so the
# build-time UID here is irrelevant for file access. We use the default (1000)
# because rootless podman's user namespace can't map the HPC's high IDs
# (UID 70230911, GIDs 663800067/663800106) — crun's setresuid/setgroups would fail.
RUN useradd -m -s /bin/zsh gson

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
# tmux/yazi/scp/etc. that spawn `zsh -c '…'` inherit the right env.
# Aliases and interactive integrations go in /etc/zsh/zshrc.
# ──────────────────────────────────────────────────────────────────────────────

# ── container PATH (prepend so container binaries win over host copies) ──────
# Singularity inherits the host PATH; be explicit so /usr/local/bin tools
# (nvim, starship, lazygit, uv, …) are always found.
export PATH="/usr/local/bin:$HOME/.local/bin:$PATH"

# ── TinyTeX user-mode binaries: prefer over system /opt/TinyTeX if present ───
# The system install (Dockerfile Stage 5d) symlinks its binaries into
# /usr/local/bin via `tlmgr path add`.  But if the user has their own TinyTeX
# at ~/.TinyTeX (e.g. from a previous `quarto install tinytex` or
# `tinytex::install_tinytex()`), prepend it so any user-added packages
# (`tlmgr install <pkg>` on the writable user install) take precedence.
if [ -d "${HOME}/.TinyTeX/bin/x86_64-linux" ]; then
    export PATH="${HOME}/.TinyTeX/bin/x86_64-linux:${PATH}"
fi

# ── TeX user tree (no-root package installs) ─────────────────────────────────
# The system TinyTeX at /opt/TinyTeX is read-only inside the SIF, so package
# installs must use `tlmgr --usermode`.  TEXMFHOME is the user-writable tree
# that kpathsea (via mktexlsr) and the TeX engines (pdflatex, xelatex, …)
# consult automatically at compile time.  Pinning it to ~/texmf gives a
# predictable, shareable location on the network home — independent of the
# TeX Live year-stamped dirs (~/.texlive2024/, …) used for var/config state.
#
# One-time bootstrap (run inside the container):
#   tlmgr --usermode init-usertree   # creates ~/texmf with the standard tree
#   tlmgr --usermode install <pkg>   # installs into ~/texmf, no root needed
export TEXMFHOME="${HOME}/texmf"

# ── Make zsh the default for child shells (tmux, scripts) ────────────────────
# CIRCE's /etc/passwd sets login shell to bash, which is inherited via the
# bind-mounted home.  Force SHELL=zsh inside the container so tmux (and other
# terminal multiplexers) spawn zsh panes by default.
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

# ── tmux server state on fast /tmp ───────────────────────────────────────────
# tmux keeps its socket under $TMUX_TMPDIR (default /tmp), which is node-local
# ext3 — already fast, nothing to redirect.  A fresh tmux session creates in
# ~0.03s even under proot's PROOT_NO_SECCOMP=1 ptrace, because tmux is a lean C
# server with a built-in status line: no WASM interpreter and no plugin
# handshake firing thousands of traced syscalls at create.  For persistence
# across reconnects, attach to a named session (`tm` helper in .zshrc =
# tmux new-session -A -s main) rather than re-creating.

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
# Declare 24-bit color support explicitly so tools like yazi do not need to
# query the terminal via DA1/XTVERSION escape sequences.
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
    #      tmux panes (tmux sets each pane's PTY size) and for any resize
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
