# FinTech Tools Container — v0.9

HPC container for Financial / Quantitative computing. Workflow has migrated
from VSCode Remote-SSH (legacy, still works) to **Neovim** SSH.

## Build

```bash
./build_container.sh
```

One-shot: builds with Podman → `podman export` to a flat rootfs tar → optional
`scp` to CIRCE (`/work/g/gson/fintech-rootfs.tar`) → optionally runs
`sync_configs.sh` (default yes) to push configs + the `~/.local/bin` wrappers, so
the node is fully ready in a single run. Both deployment choices are asked up
front, then the build runs unattended. Pushover notifications fire if
`~/.pushover_config` is set.

Prereqs (one-time):

```bash
brew install podman
podman machine init && podman machine start
```

## Running on CIRCE

One-time setup (`./build_container.sh` deploys the rootfs tar **and** runs the
config sync automatically; run `sync_configs.sh` on its own only when you change
configs without rebuilding):

```bash
./sync_configs.sh   # push to CIRCE: term_session.sh → ~/sh/, udocker_dev.sh → ~/bin/,
                    # the bookokrat helpers → ~/.local/bin/,
                    # ~/.config/{nvim,yazi,tmux,bookokrat,starship,…},
                    # and the Mac's herdr settings + plugins
```

Daily use: `sbatch ~/sh/term_session.sh`, then `./connect_nvim.sh` from the Mac.
The launcher (udocker, Fakechroot/F3) imports the rootfs into node-local `/tmp`
and enters the container. It auto-refreshes when the tar is newer than the
unpacked copy, so a rebuild is picked up with no manual step.

## What's inside (v0.9)

| Stack | Detail |
|---|---|
| Base | Ubuntu 24.04 LTS (Noble) headless |
| Python | **3.13** via deadsnakes; `/usr/local/bin/python{,3}` symlinked, env vars (`PYTHON`, `RETICULATE_PYTHON`, `UV_PYTHON`) point here — **not** the system 3.12 |
| uv | Astral binary in `/usr/local/bin/` |
| R | **4.x** from CRAN noble-cran40, default repo set to [**Posit Package Manager**](https://packagemanager.posit.co/) (`noble/latest`) so `install.packages()` pulls binary builds for Ubuntu instead of compiling from source |
| Quarto | Latest GitHub release, installed at `/opt/quarto`, on `$PATH` as `quarto`. Bundles pandoc, typst + Deno. The bundled pandoc and typst are static, and under udocker F3 a static binary looks up `/opt/quarto/share` on the host, so the image replaces both with dynamic builds of the same versions (pandoc from `pandoc/core:<v>-ubuntu`, typst compiled in its own stage). PDF output works out of the box via the TinyTeX install below, or via typst. |
| LaTeX | **TinyTeX** baked in at `/opt/TinyTeX` — installed via direct tarball pull from [`rstudio/tinytex-releases`](https://github.com/rstudio/tinytex-releases) (`TinyTeX-linux-x86_64-<TAG>.tar.xz`), no R/Rscript dependency in Stage 5d. Binaries symlinked into `/usr/local/bin` via `tlmgr path add` (with `sys_bin` pinned explicitly so the build does not fall back to `/root/.local/bin`). Ships `latexmk`, `pdflatex`, `xelatex`, `lualatex`, `biber`, plus `collection-latexrecommended`, `collection-fontsrecommended`, and `biblatex`. VimTeX (`lang.tex` extra) and Quarto find them automatically. The image is read-only at runtime, so extra packages install in user-mode — `TEXMFHOME` is pinned to `~/texmf` in zshenv so `tlmgr --usermode init-usertree && tlmgr --usermode install <pkg>` lands in a predictable, kpathsea-discoverable tree (no root required). Alternatively, rebuild the container with the package appended to Stage 5d. A pre-existing `~/.TinyTeX` install is honored — zshenv prepends it to `$PATH` so any user-installed extras win over the system copy. |
| Editor | Neovim (latest) + LazyVim starter |
| Own nvim plugins | [quarto-render.nvim](https://github.com/matthewgson/quarto-render.nvim) (Quarto CLI above) and [replstudio.nvim](https://github.com/matthewgson/replstudio.nvim) (R/Python REPL + plot pane), both cloned from GitHub by lazy.nvim, so the container runs what has been **pushed**. replstudio's container spec is `configs/nvim/lua/plugins/replstudio.lua`, which replaces the Mac's `dir =` copy. The image carries only the `duckdb` CLI for its parquet viewer. Its Python venv (`~/.local/share/replstudio/venv`) and R's `ragg` are installed at runtime, into `$HOME` |
| LazyVim extras | Whatever the Mac's `~/.config/nvim/lazyvim.json` enables (the nvim sync is an overlay of it), minus `lang.rust`. No AI extras: avante.nvim and Copilot were removed 2026-10-01 |
| Terminal | **tmux 3.6b** (multiplexer, built from source — newer than 24.04's apt 3.4, which is too old for ghostty's CSI-u extended keys over SSH and broke `Ctrl+Space`/`Ctrl+h/j/k/l`), **herdr** (agent multiplexer, built from source as a dynamic binary — see "herdr" below), Yazi (file manager) with all recommended deps, lazygit, `ncurses-term` (many terminfos) |
| AI agents | `claude` (Claude Code) **is** bundled and runs well in-container under udocker/F3 (much snappier than the old ptrace runtime; F3's LD_PRELOAD path avoids the per-syscall tax). Running it locally on the Mac and driving the node over SSH is still an option. Copilot is **not** bundled in any form: neither the standalone `copilot` CLI nor the nvim Copilot/avante plugins and their language server (removed 2026-10-01 after repeated build failures). |
| SSH | `openssh-client` (git/scp); sshd not used |
| PDF viewer | **bookokrat** at `/usr/local/bin/bookokrat` — terminal PDF/EPUB reader (kitty graphics, renders over SSH; no X11). VimTeX (`<localleader>lv`), yazi, and snacks-explorer route PDFs to it (see "PDF viewing" below). |

Yazi deps included (per [yazi docs](https://yazi-rs.github.io/docs/installation)):
`file`, `p7zip`, `jq`, `poppler-utils`, `fd`, `ripgrep`, `fzf`,
`zoxide`, `imagemagick`, `resvg`, `unar`.

```

## PDF viewing — bookokrat

PDFs (and EPUBs) open in **bookokrat**, a terminal reader that draws inline via
the kitty graphics protocol — which **ghostty** renders straight over SSH, so no
X11/XQuartz and no Mac-side helper are involved. Synctex works both ways because
Neovim and bookokrat run on the same node.

- **Binary** — baked into the image at `/usr/local/bin/bookokrat` (Dockerfile Stage 5f),
  from the [`matthewgson/bookokrat`](https://github.com/matthewgson/bookokrat) fork's
  releases (`vX.Y.Z-fork.N`), not upstream. Over SSH the terminal can't read
  bookokrat's shared memory, so upstream sends every PDF page as ~18 MB of raw RGB
  (~2 s per page turn); the fork zlib-compresses it (kitty `o=z`, ~0.5 MB,
  ~0.2-0.4 s). `build_container.sh` resolves the fork's latest release. The Mac
  keeps Homebrew's upstream build, since shared memory works locally.
- **Wrappers** — synced to `~/.local/bin/` by `sync_configs.sh` (on `$PATH` inside the container):
  - `bookokrat-split` — opens a PDF in a **half split beside the caller** (forwards
    `$NVIM` for inverse search). Opening a second PDF respawns that same reader pane
    rather than splitting again; opening one already on screen just jumps to it.
    Panes carry the pane option `@bkfile`, which is how both are recognised.
  - `bookokrat-forward` — VimTeX forward search (`<localleader>lv`): jumps an open instance, or launches one.
  - `bookokrat-inverse` — synctex inverse search: `gd` / Ctrl-click in the PDF jumps Neovim to the source line.
  - `tmux-kitty-image-gc` — takes the page **off the screen** when you switch away
    from the reader or quit it (bookokrat#179). Under ghostty bookokrat draws a
    classic kitty placement, which **tmux holds no cell for**, so a window switch
    repaints the text and leaves the page painted over the window you switched to.
    This writes the kitty delete escape straight to the client tty — around tmux's
    pane-visibility rules, which would swallow it — then sends `C-l` to any reader
    still on screen. Deletes are targeted at z-index `-1` / image id `1`, where
    bookokrat draws and yazi does not, so a neighbouring preview survives. Wired in
    `configs/tmux/tmux.conf` (`session-window-changed`, `client-session-changed`)
    and appended to the reader's own command line by `bookokrat-split`. The repaint
    on return cost ~1-1.5s here with upstream bookokrat, against ~100-300ms on
    the Mac. That was the raw page crossing SSH, which the fork (above) compresses.
    Only a reader that is **visible but not focused** actually leaks: with the
    cursor in the reader, bookokrat tears its own placements down on focus-out and
    this script finds nothing to do. That is why the bug reads as intermittent —
    it depends on which pane had the cursor. `focus-events on` is therefore
    load-bearing for images, not just for nvim. Measured 2026-09-07.
- **One file each, shared with the Mac.** `sync_configs.sh` prefers the LIVE
  `~/.local/bin/` copy over the repo's `local-bin/` snapshot, so an edit made live must be
  copied back to the repo **and** an edit made only in the repo is discarded by the
  next sync. Platform differences live inside the scripts (`uname -s`), which is how
  `bookokrat-split` picks Homebrew's binary on the Mac and `/usr/local/bin/bookokrat`
  here.
- **Retired: the `~/.local/bin/override/bookokrat` wrapper** (and its `tmux` shim
  under `~/.local/libexec/`). It answered bookokrat's outer-terminal probe with
  `kitty` to force the Unicode-placeholder anchor path back on. Ghostty 1.3.1 does
  not implement the relative placements that path emits (kitty keys `P=`/`Q=`) — it
  drops them and paints the page at the cursor, i.e. on top of yazi, leaving the
  reader's pane empty. Removed 2026-09-04; it was never viable here in any case,
  the anchor path being implemented only over SHM transmission while the shm object
  lives in `/dev/shm` on the compute node and ghostty runs on the Mac. Do not
  reintroduce it — `tmux-kitty-image-gc` is the supported fix.
- **Config** — `configs/bookokrat/` → `~/.config/bookokrat/` (inverse search wired via `synctex_editor`).
- **Wiring** — VimTeX (`configs/nvim/lua/plugins/vimtex.lua`, `general` viewer), yazi
  (`*.pdf`/`*.epub` opener), and `vim.ui.open` / snacks-explorer
  (`pdf_open.lua`, `snacks.lua`) all route PDFs to bookokrat.

### Test

After SSH'ing in via `./connect_nvim.sh`, from inside the container (in tmux):

```bash
bookokrat-split /work/g/gson/some.pdf   # opens in a new tmux split
```

In yazi: Enter on a `.pdf`/`.epub` opens it in a bookokrat split.
In Neovim: `<localleader>lv` in a `.tex` forward-searches; `gd` / Ctrl-click in
bookokrat jumps back to the source line.

**Start tmux on this side first — "in tmux" above is not optional.** If you SSH
in from inside a *local* tmux on the Mac and run bookokrat with no tmux here,
bookokrat sees no `$TMUX`, emits raw kitty escapes instead of wrapping them for
passthrough, and the local tmux swallows them: the reader's frame and scrollbar
draw and the page never appears. `tm` first. It looks like a PDF that failed to
load rather than a terminal problem, which is what makes it worth knowing.

Nesting is otherwise fine. With tmux running on both sides the page renders
correctly through both multiplexers, and nothing is left painted behind on an
inner or an outer session switch — the leftover-page bug needs a single
multiplexer, i.e. the ordinary bare-ghostty `connect_nvim.sh` case. Measured end
to end with a real PDF, 2026-09-07.

## herdr

[herdr](https://herdr.dev) is the container's multiplexer, and the startup
messages point only to it. tmux (`tm`) stays installed because bookokrat's PDF
split still needs it. Start herdr by hand after `./connect_nvim.sh`:
`herdr` attaches to the running server, or starts one and restores the saved
layout.

- **The `/tmp` self-heal does not depend on the multiplexer.** The reaper
  repair runs in `udocker_dev.sh` on every `./connect_nvim.sh`, before any
  shell starts, and nvim's plugin heal runs in `.zshrc`'s `nvim()` wrapper,
  which herdr's pane shells load (they are interactive zsh). So keep coming in
  through `connect_nvim.sh` and reattach with `herdr`, as you did with `tm`.
  herdr puts nothing on `/tmp` except its sockets: its binary is part of the
  ROOT, swept with the rest of it, and its layout, logs and plugin state are on
  `$HOME`.
- **The layout outlives the job.** herdr saves it to
  `~/.config/herdr/session.json` and restores it, including Claude
  conversations, whenever a server starts. Because that file is on `$HOME`, it
  survives the reaper, a new node, and the end of the 7-day job.
- **Stop the server after a rebuild.** A new image replaces the ROOT under a
  server that is still running, and that server's new panes fail.
  `udocker_dev.sh` warns on connect when that happens. Run `herdr server stop`,
  then `herdr`.

- **Built from source, not downloaded.** The release binary is static musl.
  Under F3 a static parent never loads libfakechroot, so every pane shell,
  `/bin/sh -c` command and plugin action it spawned would run against the RHEL7
  host and die with the `GLIBC_PRIVATE` relocation error. The Dockerfile's
  `herdrbuild` stage cross-compiles `x86_64-unknown-linux-gnu` on the build
  machine's own arch, so it does not run under emulation. That gives a normal
  dynamic binary that behaves like tmux. For the same reason `herdr update` is
  refused in the container: upgrade by rebuilding the image.
- **Settings follow the Mac.** `sync_configs.sh` pushes `~/.config/herdr`'s
  settings and plugins (see the table below). On the nvim side, the Mac's
  `herdr-splits.lua` comes across with the nvim overlay, so `Ctrl+h/j/k/l`
  crosses between herdr panes and nvim splits there too. The one exception is
  the machine label at the right of the tab row: the sync rewrites the Mac's
  Apple-icon `MacOS` to a server-icon `CIRCE`, so you can tell at a glance which
  herdr you are in.
- **Sockets are on node-local `/tmp`.** `.zshrc` sets `HERDR_SOCKET_PATH` to
  `/tmp/$USER/herdr/herdr.sock`, because the default `~/.config/herdr` is on
  the network home. Named sessions (`--session`) still keep their sockets under
  `~/.config/herdr/sessions/`.
- **Claude shows up as an agent.** The `claude` wrapper runs through the
  container's loader, which hides the name herdr matches on. Inside herdr it
  sets `HERDR_AGENT=claude` to restore it.
- **Do not point the Mac's `herdr --remote` / `herdr machine add` at CIRCE.**
  Both install the static release on the *host*, outside the container, and
  run its server there. They also open SSH connections of their own against the
  login node's rate limit.

## How configs/ syncs

`sync_configs.sh` applies a per-cfg policy in its staging step:

| cfg | Policy | Why |
|---|---|---|
| `yazi` | **replace** — repo's `configs/yazi/` becomes CIRCE's `~/.config/yazi/` | Container-specific openers (e.g. bookokrat for PDFs) |
| `tmux` | **replace** — repo's `configs/tmux/` becomes CIRCE's `~/.config/tmux/` | Container-specific multiplexer config (replaced zellij); no Mac copy |
| `bookokrat` | **replace** — repo's `configs/bookokrat/` becomes CIRCE's `~/.config/bookokrat/` | Container owns the bookokrat config |
| `nvim` | **overlay** — Mac's `~/.config/nvim/` is staged, then `configs/nvim/*` is rsync'd on top | Keeps your Mac LazyVim config canonical; drops in the container plugins |
| `bottom` | **default** — direct from Mac | No container-specific overrides needed |
| `herdr` | **mirror, filtered** — Mac's `config.toml`, `plugins.json` and `plugins/` (minus `.git`), with the Mac's `$HOME` in `plugins.json` rewritten to CIRCE's | Same keys, theme and plugins as the Mac. Its sockets, logs and saved sessions are runtime state and stay put |

`avante.nvim` and `github-copilot` used to sync here too. They were dropped on
2026-10-01 together with the avante and Copilot nvim plugins. A sync never
deletes on CIRCE, so old copies of both directories stay there until removed by
hand.

To add another override: drop files into `configs/<cfg>/` and (if needed) add
the cfg name to `CONFIG_LIST` and the `replace`/`overlay` case in `sync_configs.sh`.

## R packages — PPM

`install.packages("tidyverse")` pulls precompiled Ubuntu binaries from PPM —
about 30s vs. ~10 minutes for the from-source CRAN build. The config lives at
`/etc/R/Rprofile.site` inside the container; switch the URL from
`noble/latest` to `noble/2026-MM-DD` for a pinned, reproducible snapshot.
