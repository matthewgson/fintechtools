# Fintech Tools Container
# Base: Ubuntu 24.04 LTS (Noble Numbat) — headless server edition

# The pandoc that replaces Quarto's bundled one (Stage -1c). Global because a
# FROM line can only expand an ARG declared before the first FROM.
# build_container.sh passes the version the resolved Quarto release pins.
ARG QUARTO_PANDOC_VERSION=3.10

# ─── Stage -1: static git (musl) for lazygit's fakechroot escape ────────────
# lazygit is a Go binary; under udocker's F3 fakechroot its exec() of `git`
# bypasses the LD_PRELOAD hook and resolves against the RHEL7 *host* (the same
# escape this image already works around for yazi's Z→fzf). On the host the
# dynamic container git can't run and the system git is 1.8.3.1 — below
# lazygit's floor ("Git version must be at least 2.32.0"). Fix: build a FULLY
# STATIC git (no PT_INTERP) that runs as a bare process on the host AND
# in-container; udocker_dev.sh deploys it to the bind-identical ~/.local/bin so
# the escaped lookup finds a recent git. Build notes (each one is load-bearing):
#   -no-pie               Alpine gcc defaults to -fPIE -pie; with -static that
#                         yields a *dynamic* PIE needing ld-musl (absent on
#                         RHEL7). -no-pie => a classic, fully static ELF.
#   NO_REGEX=NeedsStartEnd musl's regex lacks REG_STARTEND -> use git's bundled.
#   --allow-multiple-definition  libidn2 (pulled via libpsl) bundles gnulib's
#                         error(), colliding with git's own error().
#   one `make … install`  a separate flag-less `make install` makes git detect
#                         "new build flags" and silently rebuild dynamic+PIE.
#   RUNTIME_PREFIX        git self-locates libexec relative to its real path, so
#                         the bundle works wherever it's dropped at runtime.
FROM alpine:3.20 AS gitstatic
ARG GIT_STATIC_VERSION=2.43.0
RUN apk add --no-cache \
  build-base wget tar xz ca-certificates pkgconf binutils \
  zlib-dev zlib-static openssl-dev openssl-libs-static \
  curl-dev curl-static expat-dev expat-static \
  nghttp2-static brotli-static zstd-static c-ares-static \
  libidn2-static libunistring-static libpsl-static && \
  cd /tmp && \
  wget -q -O git.tar.xz "https://www.kernel.org/pub/software/scm/git/git-${GIT_STATIC_VERSION}.tar.xz" && \
  tar xf git.tar.xz && cd "git-${GIT_STATIC_VERSION}" && \
  make -j"$(nproc)" \
  CC=gcc \
  CFLAGS="-O2 -fno-pie" \
  LDFLAGS="-static -no-pie -s -Wl,--allow-multiple-definition" \
  CURL_LDFLAGS="$(pkg-config --static --libs libcurl)" \
  NO_GETTEXT=1 NO_TCLTK=1 NO_PERL=1 NO_PYTHON=1 NO_REGEX=NeedsStartEnd \
  RUNTIME_PREFIX=YesPlease \
  prefix=/opt/git-static \
  install && \
  mkdir -p /opt/git-static/ssl && \
  cp /etc/ssl/certs/ca-certificates.crt /opt/git-static/ssl/cacert.pem && \
  cd /opt/git-static/libexec/git-core && \
  rm -f git-daemon git-http-backend git-http-fetch git-http-push \
  git-imap-send git-shell scalar git-sh-i18n--envsubst && \
  rm -f /opt/git-static/bin/scalar /opt/git-static/bin/git-shell && \
  [ -z "$(readelf -l /opt/git-static/bin/git | grep -i interpreter)" ] && \
  /opt/git-static/bin/git version

# ─── Stage -1b: herdr (agent multiplexer) as a DYNAMIC glibc binary ─────────
# herdr's Linux release asset is a static-pie musl binary — the lazygit/gh
# escape again, but worse: everything a multiplexer does is spawn children
# (every pane's $SHELL, `/bin/sh -c` for custom commands, `bash` for plugin
# actions), and a static parent never loads libfakechroot, so each of those
# would resolve against the RHEL7 host and die on the glibc loader mismatch.
# Built for x86_64-unknown-linux-gnu instead, against 24.04's glibc 2.39, it is
# an ordinary dynamic ELF: F3 patches its PT_INTERP like nvim's, LD_PRELOAD
# loads, and its children stay inside the container — exactly like tmux.
#
# The stage runs on the BUILD machine's arch and cross-compiles: under amd64
# emulation on an arm64 Mac, rustc + zig would take far longer than the rest of
# the image. Rust comes from herdr's own rust-toolchain.toml, and Zig (which
# builds the vendored libghostty-vt) from the version its build.zig.zon asks
# for, so a herdr bump needs no edit here.
FROM --platform=$BUILDPLATFORM ubuntu:24.04 AS herdrbuild
ARG BUILDARCH
ARG HERDR_VERSION=latest
ENV DEBIAN_FRONTEND=noninteractive \
  RUSTUP_HOME=/opt/rustup CARGO_HOME=/opt/cargo PATH=/opt/cargo/bin:/opt/zig:$PATH
RUN apt-get update && apt-get install -y --no-install-recommends \
  ca-certificates curl git xz-utils build-essential pkg-config && \
  if [ "$BUILDARCH" != amd64 ]; then \
  apt-get install -y --no-install-recommends gcc-x86-64-linux-gnu libc6-dev-amd64-cross; fi && \
  rm -rf /var/lib/apt/lists/*
RUN git clone -q --depth 1 --branch "${HERDR_VERSION}" https://github.com/herdrdev/herdr /src/herdr && \
  cd /src/herdr && \
  ZIG_VERSION=$(sed -n 's/.*minimum_zig_version = "\(.*\)".*/\1/p' vendor/libghostty-vt/build.zig.zon) && \
  case "$BUILDARCH" in arm64) zarch=aarch64 ;; amd64) zarch=x86_64 ;; \
  *) echo "ERROR: no Zig build for build arch $BUILDARCH" >&2; exit 1 ;; esac && \
  echo "Building herdr ${HERDR_VERSION} with Zig ${ZIG_VERSION} on ${zarch}" && \
  mkdir -p /opt/zig && \
  curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-${zarch}-linux-${ZIG_VERSION}.tar.xz" \
  | tar -xJ -C /opt/zig --strip-components=1 && \
  curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain none && \
  rustup toolchain install && \
  rustup target add x86_64-unknown-linux-gnu && \
  CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER=x86_64-linux-gnu-gcc \
  cargo build --release --locked --target x86_64-unknown-linux-gnu && \
  install -m 0755 target/x86_64-unknown-linux-gnu/release/herdr /opt/herdr

# ─── Stage -1c: Quarto's pandoc + typst as DYNAMIC glibc binaries ───────────
# Quarto's tarball ships a dynamic deno beside a static pandoc and a static-pie
# musl typst. deno runs under libfakechroot and hands those two container paths
# (Lua filters and templates, typst's --font-path/--package-path, all under
# /opt/quarto/share). A static binary never loads libfakechroot, so it opens
# them on the RHEL7 host, where /opt/quarto does not exist, and every render
# fails. There is no relocation error here, only missing files. The fix is the
# same one herdr got: swap each for a dynamic build of the SAME version, which
# F3 patches and LD_PRELOAD reaches like any other tool. Stage 5c swaps them
# in and fails the build on a version mismatch. apt's pandoc is no substitute:
# 24.04's 3.1.3 is far older than Quarto supports.
#   pandoc  pandoc/core's -ubuntu flavour is built on 24.04 itself: dynamic
#           against libc/libm/libz/libgmp/liblua5.4, with its data files embedded.
#   typst   upstream publishes only musl for x86_64 Linux, so it is built here,
#           cross-compiled like herdr. vendor-openssl matches typst's own
#           release build, which keeps libssl-dev:amd64 out of the builder.
# esbuild (static Go) stays as shipped. It only reads the project dir and /tmp,
# which are bound 1:1, so the host sees the same files the container does.
FROM docker.io/pandoc/core:${QUARTO_PANDOC_VERSION}-ubuntu AS pandocdyn

FROM --platform=$BUILDPLATFORM ubuntu:24.04 AS typstbuild
ARG BUILDARCH
ARG QUARTO_TYPST_VERSION=0.15.1
ENV DEBIAN_FRONTEND=noninteractive \
  RUSTUP_HOME=/opt/rustup CARGO_HOME=/opt/cargo PATH=/opt/cargo/bin:$PATH \
  CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER=x86_64-linux-gnu-gcc \
  CC_x86_64_unknown_linux_gnu=x86_64-linux-gnu-gcc \
  AR_x86_64_unknown_linux_gnu=x86_64-linux-gnu-ar
# perl + make: vendored OpenSSL's Configure.
RUN apt-get update && apt-get install -y --no-install-recommends \
  ca-certificates curl git build-essential pkg-config perl && \
  if [ "$BUILDARCH" != amd64 ]; then \
  apt-get install -y --no-install-recommends gcc-x86-64-linux-gnu libc6-dev-amd64-cross; fi && \
  rm -rf /var/lib/apt/lists/*
RUN git clone -q --depth 1 --branch "v${QUARTO_TYPST_VERSION}" https://github.com/typst/typst /src/typst && \
  cd /src/typst && \
  echo "Building typst ${QUARTO_TYPST_VERSION}" && \
  curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain stable \
  --target x86_64-unknown-linux-gnu && \
  cargo build --release --locked -p typst-cli --features vendor-openssl \
  --target x86_64-unknown-linux-gnu && \
  install -m 0755 target/x86_64-unknown-linux-gnu/release/typst /opt/typst

FROM ubuntu:24.04

LABEL maintainer="Matthew Son"
LABEL description="HPC container: Neovim + Python 3.13 + uv + R 4.x + Claude Code CLI + TinyTeX + bookokrat + herdr"
LABEL version="0.8"

# ─── Version pins — bump here to upgrade any tool ────────────────────────────
ARG UV_VERSION=latest
ARG QUARTO_VERSION=latest
ARG TINYTEX_TAG=v2026.06
# Neovim and Claude Code track the LATEST release on every build (see Stage 6 and
# Stage 11). build_container.sh resolves `latest` to the concrete version before
# calling podman and passes it back in as a --build-arg — that is what makes the
# layer cache invalidate when upstream publishes, and what puts the exact version
# in the build log. Building the Dockerfile directly, with no --build-arg, still
# gets the newest release; it just may reuse a cached layer.
# Pin either one by passing e.g. --build-arg NVIM_VERSION=v0.12.4.
#
# Tracking latest is also what VimTeX wants: it supports only the CURRENT stable
# Neovim, and a lagging pin is exactly what broke .tex highlighting before
# (see configs/nvim/lua/plugins/vimtex.lua).
ARG NVIM_VERSION=latest
ARG CLAUDE_CODE_VERSION=latest
ARG LAZYGIT_VERSION=latest
ARG YAZI_VERSION=latest
ARG RESVG_VERSION=latest
ARG FZF_VERSION=latest
ARG ZOXIDE_VERSION=latest
ARG BOTTOM_VERSION=latest
# bookokrat = terminal PDF/EPUB reader (kitty graphics); the primary VimTeX/yazi
# viewer now — renders in-terminal over SSH, no X11/XQuartz. Comes from the
# matthewgson/bookokrat fork (tags vX.Y.Z-fork.N), not upstream: see Stage 5f.
ARG BOOKOKRAT_VERSION=latest
# duckdb CLI = replstudio.nvim's parquet viewer (`:e data.parquet` → table).
ARG DUCKDB_VERSION=latest
# catppuccin/tmux = tmux status-bar theme, baked into the image and sourced
# directly (no TPM at runtime). Pinned to match the Mac (which tracks "latest").
ARG CATPPUCCIN_TMUX_VERSION=latest
# Session persistence for tmux (prefix Ctrl-s save / Ctrl-r restore, manual
# only). Baked like catppuccin and sourced directly from configs/tmux/tmux.conf
# — no TPM.
ARG TMUX_RESURRECT_VERSION=latest

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=America/New_York
ENV LC_ALL=C.UTF-8
ENV LANG=C.UTF-8

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
  # Java runtime for H2O (the h2o R package runs `java -jar`; no JDK needed)
  openjdk-21-jre-headless \
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
  # XML
  libxml2-dev \
  libxml2-utils \
  # BLAS / LAPACK
  libblas-dev \
  liblapack-dev \
  libopenblas-dev \
  # FFI
  libffi-dev \
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
  # Database (RPostgres for WRDS, RSQLite)
  libpq-dev \
  libsqlite3-dev \
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
  # Quarto's dynamic pandoc (Stage -1c) links Lua 5.4 as a shared library
  liblua5.4-0 \
  git \
  rsync \
  # (tmux is NOT installed from apt — built from source in Stage 8g below,
  #  because 24.04 pins tmux 3.4 which is too old for ghostty's CSI-u keys.)
  nano \
  # `vi` only — `vim` is aliased to nvim in .zshrc
  vim-tiny \
  wget \
  curl \
  openssh-client \
  man-db \
  less \
  zsh && \
  locale-gen en_US.UTF-8 && \
  # ALSO compile en_US.UTF-8 in DIRECTORY form. Under udocker/F3, glibc's
  # setlocale() opens its data through internal calls libfakechroot cannot
  # interpose, so it reads the RHEL7 HOST /usr/lib/locale and every process
  # silently falls back to the C locale (zsh then measures multibyte glyphs
  # by the byte). The cure is LOCPATH pointed at the ROOT by host path (set
  # by udocker_dev.sh + /etc/zsh/zshrc), and LOCPATH disables the
  # locale-archive that locale-gen writes into — hence the directory copy.
  mkdir -p /usr/lib/locale/en_US.UTF-8 && \
  localedef -i en_US -f UTF-8 /usr/lib/locale/en_US.UTF-8 && \
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
  curl -fL "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-x86_64-unknown-linux-gnu.tar.gz" \
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

# ─── Stage 5b-2: R language server (nvim LSP for R) ─────────────────────────
# Bakes the CRAN `languageserver` package into the system R library so nvim's
# `r_language_server` LSP works out of the box — it is launched as
# `R --no-echo -e languageserver::run()` off the `R` already on $PATH.
#
# Pulled as a PRECOMPILED PPM binary (via the Stage 5b Rprofile.site repo +
# User-Agent), NOT compiled from source: install.packages() downloads the
# Ubuntu-Noble binary (and its binary deps) in seconds. Rscript sources
# Rprofile.site, so the PPM repo/UA set there apply here.
#
# This deliberately REPLACES Mason's `r-languageserver` install path, which in
# the container tries to build languageserver into a per-user Mason tree on the
# slow HPC filesystem and routinely fails to find/install it. The container
# nvim config (configs/nvim/lua/plugins/r.lua) sets `mason = false` on
# r_language_server so the LSP uses THIS system copy instead of Mason.
RUN Rscript -e 'install.packages("languageserver")' && \
  Rscript -e 'if (!requireNamespace("languageserver", quietly = TRUE)) quit(status = 1)' && \
  echo "languageserver $(Rscript -e 'cat(as.character(packageVersion("languageserver")))') installed into $(Rscript -e 'cat(find.package("languageserver"))')"

# ─── Stage 5c: Quarto (scientific publishing — .qmd → PDF/HTML/Word) ────────
# Quarto bundles its own pandoc, typst and Deno runtime.  LaTeX for PDF output
# is provided by Stage 5d (TinyTeX) below.  The bundled pandoc and typst are
# static, which cannot see the container's files under F3, so they are replaced
# with Stage -1c's dynamic builds.  The build stops if either one's version
# differs from what this Quarto release shipped.
COPY --from=pandocdyn /usr/local/bin/pandoc /opt/quarto-dyn/pandoc
COPY --from=typstbuild /opt/typst /opt/quarto-dyn/typst
RUN QUARTO_VERSION=${QUARTO_VERSION} && \
  echo "Installing Quarto ${QUARTO_VERSION}" && \
  curl -fL "https://github.com/quarto-dev/quarto-cli/releases/download/v${QUARTO_VERSION}/quarto-${QUARTO_VERSION}-linux-amd64.tar.gz" \
  -o /tmp/quarto.tar.gz && \
  mkdir -p /opt/quarto && \
  tar -C /opt/quarto --strip-components=1 -xzf /tmp/quarto.tar.gz && \
  # NOT a symlink: quarto's launcher resolves its install root from the script
  # path and gets it wrong via a symlink (looks for tools/deno + version under
  # /usr/local/…). A wrapper exec's the real binary so it finds /opt/quarto.
  printf '#!/bin/sh\nexec /opt/quarto/bin/quarto "$@"\n' > /usr/local/bin/quarto && \
  chmod +x /usr/local/bin/quarto && \
  rm /tmp/quarto.tar.gz && \
  T=/opt/quarto/bin/tools/x86_64 && \
  for t in pandoc typst; do \
  want=$("$T/$t" --version | awk 'NR==1 {print $2}'); \
  got=$("/opt/quarto-dyn/$t" --version | awk 'NR==1 {print $2}'); \
  if [ -z "$want" ] || [ "$want" != "$got" ]; then \
  echo "ERROR: Quarto ${QUARTO_VERSION} ships $t '$want' but Stage -1c's build reports '$got'." >&2; \
  echo "  build_container.sh passes the matching versions. For a direct build, pass" >&2; \
  echo "  --build-arg QUARTO_PANDOC_VERSION / QUARTO_TYPST_VERSION (pinned in quarto-cli's configuration file)." >&2; \
  exit 1; fi; \
  if ! file -L "/opt/quarto-dyn/$t" | grep -q 'dynamically linked'; then \
  echo "ERROR: Stage -1c's $t is not a dynamic ELF, so it would escape F3 like the bundled one." >&2; \
  exit 1; fi; \
  install -m 0755 "/opt/quarto-dyn/$t" "$T/$t" || exit 1; \
  echo "Quarto's $t $want → dynamic build"; \
  done && \
  rm -rf /opt/quarto-dyn && \
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

# ─── Stage 5e: PDF render fonts (for bookokrat) ─────────────────────────────
# bookokrat (Stage 5f) renders PDF text via MuPDF, which falls back to system
# fonts for any glyphs a PDF does not embed; fontconfig + a base font keep that
# from rendering blank/tofu. No X11/Qt/xcb stack is needed — bookokrat draws
# in-terminal via the kitty graphics protocol, so unlike the old sioyek viewer
# it needs no X server (and no XQuartz on the Mac).
RUN apt-get update && \
  apt-get install -y --no-install-recommends \
  fontconfig \
  fonts-dejavu-core && \
  rm -rf /var/lib/apt/lists/*

# ─── Stage 5f: bookokrat (primary terminal PDF/EPUB viewer) ─────────────────
# Terminal reader that draws PDFs inline via the kitty graphics protocol, which
# ghostty speaks — so VimTeX/yazi PDF viewing works straight over SSH with no
# X11/XQuartz (no X server needed at all). Prebuilt static-ish
# x86_64 gnu binary; the synctex wrapper scripts
# (bookokrat-forward/-split/-inverse) ship via sync_configs.sh into ~/.local/bin.
#
# The binary comes from the user's FORK's releases (matthewgson/bookokrat), not
# from upstream. When the terminal can't read bookokrat's shared memory, which
# is always the case over SSH, upstream sends every PDF page as ~18 MB of raw
# RGB, so a page turn took ~2 s. The fork zlib-compresses those images (Kitty
# o=z), and a page turn takes ~0.2–0.4 s (measured 2026-10-12). Its release
# workflow builds the same tarball upstream ships, so only the repo differs
# here. To follow a new upstream release: rebase the fork's main onto it, then
# push a vX.Y.Z-fork.N tag. The workflow publishes the tarball, and
# build_container.sh resolves the fork's latest release. The Mac keeps
# Homebrew's upstream build: locally it uses shared memory, so the patch
# doesn't apply there.
RUN BOOKOKRAT_VERSION=${BOOKOKRAT_VERSION} && \
  echo "Installing bookokrat ${BOOKOKRAT_VERSION} (matthewgson fork)" && \
  curl -fL "https://github.com/matthewgson/bookokrat/releases/download/${BOOKOKRAT_VERSION}/bookokrat-${BOOKOKRAT_VERSION}-x86_64-unknown-linux-gnu.tar.gz" \
  -o /tmp/bookokrat.tar.gz && \
  mkdir -p /tmp/bookokrat-x && \
  tar -C /tmp/bookokrat-x -xzf /tmp/bookokrat.tar.gz && \
  BK_BIN="$(find /tmp/bookokrat-x -type f -name bookokrat | head -1)" && \
  { [ -n "$BK_BIN" ] || { echo "ERROR: bookokrat binary missing in tarball" >&2; exit 1; }; } && \
  install -m 0755 "$BK_BIN" /usr/local/bin/bookokrat && \
  rm -rf /tmp/bookokrat.tar.gz /tmp/bookokrat-x && \
  /usr/local/bin/bookokrat --version

# ─── Stage 6: Neovim (latest stable release binary, x86_64) ─────────────────
# NVIM_VERSION=latest (the default) resolves through GitHub's /releases/latest
# redirect, which points at the newest NON-prerelease tag — so this never picks up
# a nightly. A concrete tag (v0.12.4) is fetched directly instead.
# `curl -f` so an unknown tag fails the build loudly rather than taring up a 404
# page, and the installed version is echoed for the build log.
RUN if [ "${NVIM_VERSION}" = "latest" ]; then \
  NVIM_URL="https://github.com/neovim/neovim/releases/latest/download/nvim-linux-x86_64.tar.gz"; \
  else \
  NVIM_URL="https://github.com/neovim/neovim/releases/download/${NVIM_VERSION}/nvim-linux-x86_64.tar.gz"; \
  fi && \
  echo "Installing Neovim ${NVIM_VERSION} from ${NVIM_URL}" && \
  curl -fL "${NVIM_URL}" -o /tmp/nvim.tar.gz && \
  tar -C /usr/local --strip-components=1 -xzf /tmp/nvim.tar.gz && \
  rm /tmp/nvim.tar.gz && \
  /usr/local/bin/nvim --version | head -1

# ─── Stage 7: lazygit (LazyVim git UI) ──────────────────────────────────────
RUN LAZYGIT_VERSION=${LAZYGIT_VERSION} && \
  echo "Installing lazygit ${LAZYGIT_VERSION}" && \
  curl -fL "https://github.com/jesseduffield/lazygit/releases/download/v${LAZYGIT_VERSION}/lazygit_${LAZYGIT_VERSION}_Linux_x86_64.tar.gz" \
  -o /tmp/lazygit.tar.gz && \
  tar -C /usr/local/bin -xzf /tmp/lazygit.tar.gz lazygit && \
  rm /tmp/lazygit.tar.gz

# ─── Stage 7b: static git bundle (host-runnable, for lazygit's escape) ──────
# Built in the `gitstatic` Alpine stage at the top. lazygit (Go) spawns `git`
# via an exec() that escapes udocker's F3 fakechroot onto the RHEL7 host, where
# the dynamic container git can't run and the host git is 1.8.3.1 (< 2.32).
# udocker_dev.sh copies this bundle to the bind-identical $HOME/.local/git-static
# and hands it to lazygit ALONE by wrapping /usr/local/bin/lazygit (real binary
# moved to lazygit.real) with a shim that prepends the static-git dir to PATH, so
# lazygit's escaped `git` resolves to this recent, statically-linked git. It is
# deliberately NOT the general in-container `git`: a static binary is immune to
# LD_PRELOAD, so libfakechroot never loads in it and the children it spawns
# in-container (credential helper, pager, hooks) die with a glibc loader
# relocation error. The dynamic /usr/bin/git stays the in-container git.
COPY --from=gitstatic /opt/git-static /opt/git-static

# ─── Stage 8: Yazi terminal file manager ────────────────────────────────────
RUN YAZI_VERSION=${YAZI_VERSION} && \
  echo "Installing Yazi ${YAZI_VERSION}" && \
  curl -fL "https://github.com/sxyazi/yazi/releases/download/${YAZI_VERSION}/yazi-x86_64-unknown-linux-gnu.zip" \
  -o /tmp/yazi.zip && \
  unzip -o /tmp/yazi.zip -d /tmp/yazi_extracted && \
  cp /tmp/yazi_extracted/yazi-x86_64-unknown-linux-gnu/yazi /usr/local/bin/yazi && \
  cp /tmp/yazi_extracted/yazi-x86_64-unknown-linux-gnu/ya    /usr/local/bin/ya && \
  chmod +x /usr/local/bin/yazi /usr/local/bin/ya && \
  rm -rf /tmp/yazi.zip /tmp/yazi_extracted

# ─── Stage 8b: resvg (Yazi SVG preview) ─────────────────────────────────────
RUN RESVG_VERSION=${RESVG_VERSION} && \
  echo "Installing resvg ${RESVG_VERSION}" && \
  curl -fL "https://github.com/linebender/resvg/releases/download/v${RESVG_VERSION}/resvg-linux-x86_64.tar.gz" \
  -o /tmp/resvg.tar.gz && \
  tar -C /usr/local/bin -xzf /tmp/resvg.tar.gz resvg && \
  chmod +x /usr/local/bin/resvg && \
  rm /tmp/resvg.tar.gz

# ─── Stage 8c: fzf + zoxide (pinned from GitHub — STATIC) ───────────────────
# From GitHub releases, not apt: this pins current versions AND ships STATIC
# binaries — fzf is Go-static, zoxide is the musl build. That matters because
# yazi's `Z` jump spawns zoxide→fzf via an exec() that escapes udocker's
# fakechroot onto the RHEL7 host, where only static binaries run (a dynamic
# glibc-2.39 apt build would abort); udocker_dev.sh also copies them onto the
# bind-identical $HOME/.local/bin so the escaped lookup resolves to a host-valid
# path. fzf itself no longer shells out to fd for file lists — it uses its
# built-in walker (see zshenv below) — so fd stays the plain apt build.
RUN FZF_VERSION=${FZF_VERSION} && \
  echo "Installing fzf ${FZF_VERSION}" && \
  curl -fL "https://github.com/junegunn/fzf/releases/download/v${FZF_VERSION}/fzf-${FZF_VERSION}-linux_amd64.tar.gz" \
  -o /tmp/fzf.tar.gz && \
  tar -C /usr/local/bin -xzf /tmp/fzf.tar.gz fzf && \
  chmod +x /usr/local/bin/fzf && \
  rm /tmp/fzf.tar.gz
RUN ZOXIDE_VERSION=${ZOXIDE_VERSION} && \
  echo "Installing zoxide ${ZOXIDE_VERSION}" && \
  curl -fL "https://github.com/ajeetdsouza/zoxide/releases/download/v${ZOXIDE_VERSION}/zoxide-${ZOXIDE_VERSION}-x86_64-unknown-linux-musl.tar.gz" \
  -o /tmp/zoxide.tar.gz && \
  tar -C /usr/local/bin -xzf /tmp/zoxide.tar.gz zoxide && \
  chmod +x /usr/local/bin/zoxide && \
  rm /tmp/zoxide.tar.gz

# ─── Stage 8e: bottom (process/system monitor — replaces htop) ───────────────
RUN BOTTOM_VERSION=${BOTTOM_VERSION} && \
  echo "Installing bottom ${BOTTOM_VERSION}" && \
  curl -fL "https://github.com/ClementTsang/bottom/releases/download/${BOTTOM_VERSION}/bottom_x86_64-unknown-linux-gnu.tar.gz" \
  -o /tmp/bottom.tar.gz && \
  tar -C /usr/local/bin -xzf /tmp/bottom.tar.gz btm && \
  chmod +x /usr/local/bin/btm && \
  rm /tmp/bottom.tar.gz

# ─── Stage 8e-2: duckdb CLI (replstudio.nvim's parquet viewer) ──────────────
# replstudio.nvim opens `.parquet` buffers as a read-only table through one
# `duckdb` call, which reads the footer and the first row group(s) only.
# Do NOT run `duckdb --version` here: like Bun (Stage 11), duckdb segfaults
# under the QEMU emulation this amd64 image is built in on the arm64 Mac
# ("qemu: uncaught target signal 11", exit 139 — failed the 2026-10-14 build).
# `file` checks it is an x86-64 ELF without executing it.
RUN DUCKDB_VERSION=${DUCKDB_VERSION} && \
  echo "Installing duckdb ${DUCKDB_VERSION}" && \
  curl -fL "https://github.com/duckdb/duckdb/releases/download/${DUCKDB_VERSION}/duckdb_cli-linux-amd64.zip" \
  -o /tmp/duckdb.zip && \
  unzip -o -d /usr/local/bin /tmp/duckdb.zip duckdb && \
  chmod +x /usr/local/bin/duckdb && \
  rm /tmp/duckdb.zip && \
  file /usr/local/bin/duckdb | grep -q 'ELF 64-bit LSB.*x86-64'

# ─── Stage 8f: catppuccin/tmux theme (status bar) ───────────────────────────
# tmux status-bar theme, baked into the image so the container's bar matches the
# Mac's. configs/tmux/tmux.conf sources it directly from this path (no TPM, no
# ~/.config plugin clone — keeps it on the fast rootfs, not the FUSE home).
RUN CATPPUCCIN_TMUX_VERSION=${CATPPUCCIN_TMUX_VERSION} && \
  echo "Installing catppuccin/tmux ${CATPPUCCIN_TMUX_VERSION}" && \
  mkdir -p /usr/local/share/tmux-plugins/catppuccin && \
  curl -fL "https://github.com/catppuccin/tmux/archive/refs/tags/${CATPPUCCIN_TMUX_VERSION}.tar.gz" \
  -o /tmp/catppuccin-tmux.tar.gz && \
  tar -C /usr/local/share/tmux-plugins/catppuccin --strip-components=1 -xzf /tmp/catppuccin-tmux.tar.gz && \
  rm /tmp/catppuccin-tmux.tar.gz && \
  { [ -f /usr/local/share/tmux-plugins/catppuccin/catppuccin.tmux ] || { echo "ERROR: catppuccin.tmux missing after extract" >&2; exit 1; }; }

# ─── tmux session persistence: resurrect ────────────────────────────────────
# Same treatment as catppuccin: extracted to /usr/local/share/tmux-plugins and
# sourced directly by configs/tmux/tmux.conf, so no TPM and no plugin clone on
# the slow network home. Save and restore are manual (prefix Ctrl-s / Ctrl-r);
# continuum (autosave) is not installed — herdr is the layout keeper now.
# Saved state still lives on $HOME (see @resurrect-dir in tmux.conf) — that is
# deliberate, so a layout survives the compute node changing.
RUN set -eu; \
  for p in "tmux-resurrect:${TMUX_RESURRECT_VERSION}:resurrect.tmux"; do \
  name="${p%%:*}"; rest="${p#*:}"; ver="${rest%%:*}"; entry="${rest#*:}"; \
  echo "Installing tmux-plugins/${name} ${ver}"; \
  mkdir -p "/usr/local/share/tmux-plugins/${name}"; \
  curl -fL "https://github.com/tmux-plugins/${name}/archive/refs/tags/${ver}.tar.gz" \
  -o /tmp/tmux-plugin.tar.gz; \
  tar -C "/usr/local/share/tmux-plugins/${name}" --strip-components=1 -xzf /tmp/tmux-plugin.tar.gz; \
  rm /tmp/tmux-plugin.tar.gz; \
  [ -f "/usr/local/share/tmux-plugins/${name}/${entry}" ] \
  || { echo "ERROR: ${entry} missing after extract" >&2; exit 1; }; \
  done

# ─── Patch resurrect: panes must restore in their saved directory ────────────
# Upstream (tmux-plugins/tmux-resurrect) writes one TAB-delimited record per
# pane and reads it back with `IFS=$'\t' read`. TAB is an IFS *whitespace*
# character, so the shell collapses runs of it and drops empty fields. Any pane
# whose title happens to be empty therefore loses a field, every later column
# shifts left, and `dir` ends up holding pane_active ("1") — restore.sh then has
# no directory for `new-window -c` and the pane opens in whatever cwd the
# restore inherited, i.e. $HOME. Reproduced and verified on the Mac.
#
# The fix is the author's own idiom, just never applied to pane_title:
# window_flags and pane_current_path are already written ":#{...}" so the field
# can never be empty, and the ":" is stripped on read.
#
# Kept identical to 02_dotfiles/patches/tmux-resurrect-empty-title.sh, which
# does the same to the TPM copy on the Mac. Both must move together.
# The verification below fails the build if upstream changes these lines, rather
# than letting the patch silently no-op and the bug come back.
RUN set -eu; \
  S=/usr/local/share/tmux-plugins/tmux-resurrect/scripts/save.sh; \
  R=/usr/local/share/tmux-plugins/tmux-resurrect/scripts/restore.sh; \
  sed -i 's|^\tformat+="#{pane_title}"$|\tformat+=":#{pane_title}"|' "$S"; \
  sed -i 's|-T "$pane_title"|-T "${pane_title#:}"|' "$R"; \
  grep -q 'format+=":#{pane_title}"' "$S" \
  || { echo "ERROR: resurrect save.sh pane_title patch did not apply" >&2; exit 1; }; \
  grep -q 'pane_title#:' "$R" \
  || { echo "ERROR: resurrect restore.sh pane_title patch did not apply" >&2; exit 1; }

# ─── Stage 8g: tmux built from source (newer than Ubuntu 24.04's apt 3.4) ────
# Ubuntu 24.04 pins tmux 3.4, which predates modern terminals' CSI-u extended-key
# negotiation. Over SSH from ghostty that breaks Ctrl+Space (legacy encoding = a
# NUL byte the PTY drops) and Ctrl+h/j/k/l (vim-tmux-navigator) — they work on the
# Mac (tmux 3.6b) but failed in the container. Building 3.6b here matches the Mac
# exactly and fixes it natively; configs/tmux/tmux.conf's `extended-keys` then just
# reinforces it. tmux is still preferred over zellij regardless: a lean C server,
# ~0.03s fresh-session create, no WASM plugin runtime to tax the container runtime.
# build-essential is already present (Stage 1); add only the tmux-specific deps
# (left in place — purging the -dev pkgs would also drop tmux's runtime libevent).
ARG TMUX_VERSION=3.6b
RUN apt-get update && apt-get install -y --no-install-recommends \
  libevent-dev libncurses-dev bison pkg-config && \
  curl -fL "https://github.com/tmux/tmux/releases/download/${TMUX_VERSION}/tmux-${TMUX_VERSION}.tar.gz" \
  -o /tmp/tmux.tar.gz && \
  tar -xzf /tmp/tmux.tar.gz -C /tmp && \
  cd "/tmp/tmux-${TMUX_VERSION}" && \
  ./configure --prefix=/usr/local && make -j"$(nproc)" && make install && \
  cd / && rm -rf /tmp/tmux* && \
  rm -rf /var/lib/apt/lists/* && \
  tmux -V && [ "$(command -v tmux)" = "/usr/local/bin/tmux" ]

# ─── Stage 8h: ghostty terminfo (xterm-ghostty) ──────────────────────────────
# Bake ghostty's OWN terminfo so connect_nvim.sh can pass the real
# TERM=xterm-ghostty instead of forcing xterm-256color. The entry advertises Tc
# (truecolor), setrgbf (RGB) and fullkbd (CSI-u extended keys), so tmux 3.6b
# auto-detects truecolor AND the modern key encoding natively — the prefix and
# vim-tmux-navigator work over SSH with no terminal-overrides / extended-keys
# workarounds. Source dumped from the Mac's Ghostty.app via `infocmp -x`. tic is
# from ncurses-bin (Stage 1).
COPY configs/terminfo/xterm-ghostty.src /tmp/xterm-ghostty.src
RUN tic -x -o /usr/share/terminfo /tmp/xterm-ghostty.src && \
  rm /tmp/xterm-ghostty.src && \
  infocmp xterm-ghostty >/dev/null && echo "xterm-ghostty terminfo installed"

# ─── Stage 8i: herdr (agent multiplexer, built in Stage -1b) ─────────────────
# The smoke test checks it really is dynamic: a PT_INTERP means F3 will patch it.
COPY --from=herdrbuild /opt/herdr /usr/local/bin/herdr
RUN readelf -l /usr/local/bin/herdr | grep -q 'program interpreter' && \
  herdr --version

# NOTE: no glibc-matched libfakechroot is baked in for udocker's F3 mode. Under
# F3, glibc NSS getpwuid() can't resolve our uid, so id/whoami show a bare number
# (cosmetic — udocker_dev.sh exports USER/LOGNAME; every tool works). The proper
# fix would be a libfakechroot matched to this image's glibc 2.39, but (verified
# 2026-06-24) the udocker fakechroot fork (jorge-lip/libfakechroot-glibc-udocker)
# uses the pre-2.33 __xstat64/_STAT_VER API and won't compile on glibc 2.39, and
# none of udocker's bundled variants resolve NSS here. udocker_dev.sh still picks
# up /opt/fakechroot/lib/libfakechroot.so if one ever appears. Revisit if udocker
# ships a glibc-2.39 fakechroot.

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


# ─── (removed) SLURM client passthrough ─────────────────────────────────────
# The host RHEL7 SLURM clients (squeue/sacct/sinfo/…) cannot run in this
# container under udocker's Fakechroot/F3: their glibc-2.17 runtime isn't
# reachable (bind / explicit-loader / copy+patchelf all resolve the container's
# glibc 2.39 → relocation error), and ssh-to-host is blocked by F3's getpwuid
# gap. So the auto-generated /usr/local/bin/<cmd> wrappers + /opt/host-slurm
# machinery were removed (2026-06-24). Run SLURM commands on the CIRCE login
# node, or a host shell (ssh -J circe <node>) — not inside the container.

# ─── Stage 11: claude-code CLI + tree-sitter ─────────────────────────────────
# @anthropic-ai/claude-code       : Anthropic Claude terminal coding agent. Kept
#     as an in-container option; under udocker's Fakechroot/F3 it's far more
#     responsive than under the old ptrace runtime (Claude is syscall-heavy, which
#     F3's LD_PRELOAD path avoids). Running `claude` on the Mac and driving this
#     box over SSH is still an option.
# tree-sitter-cli                 : required by nvim-treesitter to compile parsers.
#
# No Copilot anything (removed 2026-10-01): avante.nvim and copilot.lua are gone
# from the nvim config on both sides because they kept failing to build, so
# @github/copilot-language-server has nothing left to serve. The standalone
# GitHub Copilot CLI (@github/copilot) was never installed.
# Do NOT run `claude --version` here to log the version. Claude Code ships as a
# Bun-compiled binary, and this image is built --platform linux/amd64 on an
# arm64 Mac, so every RUN executes under QEMU emulation — where Bun segfaults:
#   panic(main thread): Segmentation fault at address 0x492492492497D1
#   qemu: uncaught target signal 11 (Segmentation fault) - core dumped
# It doesn't fail the build (the echo around it still exits 0) but it dumps core
# and prints an alarming crash report mid-build. Ask npm instead: it reads the
# installed package metadata without executing the binary. Native binaries like
# nvim are fine under emulation — this is specific to Bun.
#
# These land in /usr/lib/node_modules, which is BOTH a udocker_dev.sh reaper
# guard (restored wholesale from the pristine rootfs tar) and one of its
# _INTERP_DIRS. That pairing is deliberate: the tar carries stock PT_INTERP
# headers, so a restore un-does F3's loader patch and every binary here stops
# running until the interpreter sweep puts it back. Install somewhere other
# than these two trees and you owe _INTERP_DIRS a new row — otherwise the
# binary works until the first reap and then dies with a GLIBC_PRIVATE
# relocation error that looks nothing like a missing file.
RUN npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
  tree-sitter-cli && \
  npm ls -g --depth=0 @anthropic-ai/claude-code || true

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
# ~0.03s even in the container, because tmux is a lean C server with a built-in
# status line: no WASM interpreter and no plugin handshake firing thousands of
# intercepted syscalls at create.  For persistence
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

# (SLURM client config discovery removed with the SLURM passthrough — run SLURM
#  commands on the CIRCE login node, not inside the container.)

EOF
RUN cat >> /etc/zsh/zshrc << 'EOF'

# ── container aliases (interactive only) ─────────────────────────────────────
# No `vi` alias: `vi` stays the system vi.
alias vim="nvim"

# ── nvim self-heal: restore /tmp-reaped LazyVim plugin files ─────────────────
# The plugin store is symlinked onto node-local /tmp (above) for speed, but
# systemd-tmpfiles age-prunes /tmp: it deletes files untouched for N days —
# INCLUDING tracked plugin sources — while leaving each plugin's .git intact.
# lazy.nvim then still believes the plugin is installed and nvim errors on the
# now-missing modules; under nvim 0.12 a single failed extra aborts the whole
# spec import, leaving no dashboard ("Lazy doesn't open"). LazyVim/README.md is
# never read by nvim, so it ages out exactly when a prune has hit — use it as a
# one-stat canary (near-zero cost on the healthy path), and on a hit restore
# every plugin's worktree from its own .git. Objects survive in .git so this is
# offline; the in-container git also backfills blobless partial-clone gaps.
# (`vi`/`vim` expand to `nvim`, so they get the heal too.)
nvim() {
local _lazy="${XDG_DATA_HOME:-$HOME/.local/share}/nvim/lazy"
if [[ -d $_lazy/LazyVim && ! -f $_lazy/LazyVim/README.md ]]; then
print -u2 "nvim: repairing /tmp-reaped LazyVim plugin store ..."
local _r
for _r in $_lazy/*(/N); do
[[ -d $_r/.git ]] && command git -C "$_r" checkout -f -q -- . 2>/dev/null
done
fi

# ── un-stick an interrupted lazy.nvim clone (NOT the reaper) ─────────────
# lazy.nvim arms an empty "<plugin-dir>.cloning" marker before cloning and
# only unlinks it when git exits 0. Interrupt a first install — quit nvim,
# stall the network — and the marker outlives the clone. core/plugin.lua's
# update_state() then drops that plugin from the installed set on EVERY
# startup even though the finished directory is right there, so the clone
# task wipes the good copy and re-clones, at every launch, forever.
# A fresh node or fresh ROOT has the whole plugin set doing a first
# install at once, which is precisely when this is easy to trigger.
# A resolvable HEAD proves the clone finished, so drop only the marker;
# if it does not resolve the checkout is genuinely unfinished and lazy's
# own re-clone is the right answer. Healthy store: one readdir, no git.
local _m _d
for _m in $_lazy/*.cloning(N.); do
_d="${_m%.cloning}"
[[ -d $_d/.git ]] || continue
command git -C "$_d" rev-parse --verify --quiet HEAD >/dev/null 2>&1 || continue
print -u2 "nvim: clearing stale lazy.nvim clone marker for ${_d:t}"
rm -f -- "$_m"
done

command nvim "$@"
}

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

# ── locale: point glibc at THIS root's locale data by host path ──────────────
# See the localedef note in the apt stage: setlocale() escapes fakechroot and
# reads the host's locale tree, leaving every process in the C locale. LOCPATH
# is honoured by that same internal loader. udocker_dev.sh passes it in too;
# this copy covers a tmux server or shell started before that ran. The LC_ALL /
# LANG assignment after it is what makes zsh re-run setlocale.
if [[ -n ${FAKECHROOT_BASE:-} && -z ${LOCPATH:-} \
      && -f $FAKECHROOT_BASE/usr/lib/locale/en_US.UTF-8/LC_CTYPE ]]; then
  export LOCPATH="$FAKECHROOT_BASE/usr/lib/locale"
  export LANG="${LANG:-en_US.UTF-8}"
  export LC_ALL="${LC_ALL:-en_US.UTF-8}"
fi

# ── shell integrations (interactive only) ────────────────────────────────────
# Each guarded: ~/.zshrc (synced from the repo) runs the same integrations, and
# a SECOND `starship init` wraps the first one's zle-keymap-select, so every
# vi-mode switch fires `zle reset-prompt` twice and zsh redraws the two-line
# prompt a row too high per call — erasing 2 lines of output above it on each
# Esc/i. Verified 2026-09-17. The guards make whichever file runs first win.
(( ${+functions[__zoxide_hook]} ))         || eval "$(zoxide init zsh)"
(( ${+functions[fzf-history-widget]} ))    || eval "$(fzf --zsh)"
(( ${+functions[prompt_starship_precmd]} )) || eval "$(starship init zsh)"

# ── fzf appearance + file source ─────────────────────────────────────────────
# Applies to Ctrl-R (history), Ctrl-T (files), Alt-C (cd), bare `fzf`, and yazi's
# fzf jump. We intentionally DO NOT set FZF_DEFAULT_COMMAND / *_CTRL_T_* / *_ALT_C_*
# to `fd …`: fzf runs those through $SHELL (=/bin/zsh), and under udocker/F3 that
# exec ESCAPES fakechroot onto the RHEL7 host — which has no /bin/zsh and an older
# glibc — so it always fails ("Command failed: fd …" in the picker, incl. yazi `z`).
# Leaving them unset makes fzf use its OWN built-in Go file/dir walker: in-process,
# no subprocess, nothing to escape. (fd still works when YOU run it directly — the
# shell's fork+exec stays inside fakechroot; only fzf's $SHELL hop escaped.)
# --walker-skip prunes noise and keeps the occasional $HOME-wide scan bounded.
export FZF_DEFAULT_OPTS='--height=40% --layout=reverse --border --info=inline --walker-skip=.git,node_modules,.cache,.Trash,.local/share'

# yazi's zoxide jump (Z) runs fzf with a hardcoded --preview that lists the dir via
# `sh -c 'ls …'`. Under udocker/F3 that sh ESCAPES the sandbox and crashes with a
# relocation error (_dl_find_dso_for_object / GLIBC_PRIVATE — host ld.so paired with
# the container's newer libc), and the constant crash also makes the picker's
# C-j/C-k feel dead. The yazi zoxide plugin appends $YAZI_ZOXIDE_OPTS AFTER its own
# options and fzf honors the LAST value, so hiding the preview window stops the
# preview command from ever spawning. (The picker itself needs no subprocess —
# zoxide pipes its directory list straight into fzf.)
export YAZI_ZOXIDE_OPTS="--preview-window=hidden"
EOF

CMD ["/bin/zsh"]
USER gson
