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
                    # and ~/.config/{nvim,yazi,tmux,bookokrat,starship,…}
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
| Quarto | Latest GitHub release, installed at `/opt/quarto`, on `$PATH` as `quarto`. Bundles pandoc + Deno. PDF output works out of the box via the TinyTeX install below. |
| LaTeX | **TinyTeX** baked in at `/opt/TinyTeX` — installed via direct tarball pull from [`rstudio/tinytex-releases`](https://github.com/rstudio/tinytex-releases) (`TinyTeX-linux-x86_64-<TAG>.tar.xz`), no R/Rscript dependency in Stage 5d. Binaries symlinked into `/usr/local/bin` via `tlmgr path add` (with `sys_bin` pinned explicitly so the build does not fall back to `/root/.local/bin`). Ships `latexmk`, `pdflatex`, `xelatex`, `lualatex`, `biber`, plus `collection-latexrecommended`, `collection-fontsrecommended`, and `biblatex`. VimTeX (`lang.tex` extra) and Quarto find them automatically. The image is read-only at runtime, so extra packages install in user-mode — `TEXMFHOME` is pinned to `~/texmf` in zshenv so `tlmgr --usermode init-usertree && tlmgr --usermode install <pkg>` lands in a predictable, kpathsea-discoverable tree (no root required). Alternatively, rebuild the container with the package appended to Stage 5d. A pre-existing `~/.TinyTeX` install is honored — zshenv prepends it to `$PATH` so any user-installed extras win over the system copy. |
| Editor | Neovim (latest) + LazyVim starter |
| LazyVim extras | `ai.copilot`, `lang.html`, `lang.python`, plus git/json/markdown/yaml/toml |
| Terminal | **tmux 3.6b** (multiplexer, built from source — newer than 24.04's apt 3.4, which is too old for ghostty's CSI-u extended keys over SSH and broke `Ctrl+Space`/`Ctrl+h/j/k/l`), Yazi (file manager) with all recommended deps, lazygit, `ncurses-term` (many terminfos) |
| AI agents | `claude` (Claude Code) **is** bundled and runs well in-container under udocker/F3 (much snappier than the old ptrace runtime; F3's LD_PRELOAD path avoids the per-syscall tax). Running it locally on the Mac and driving the node over SSH is still an option. The standalone `copilot` CLI is **not** bundled (run locally). Neovim's inline Copilot (LSP via `copilot.lua`/`avante.nvim`) **is** included. |
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

- **Binary** — baked into the image at `/usr/local/bin/bookokrat` (Dockerfile Stage 5f).
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
    on return costs ~1-1.5s here (remote render + re-upload) against ~100-300ms on
    the Mac — that is the SSH page floor.
    Only a reader that is **visible but not focused** actually leaks: with the
    cursor in the reader, bookokrat tears its own placements down on focus-out and
    this script finds nothing to do. That is why the bug reads as intermittent —
    it depends on which pane had the cursor. `focus-events on` is therefore
    load-bearing for images, not just for nvim. Measured 2026-09-07.
- **One file each, shared with the Mac.** `sync_configs.sh` prefers the LIVE
  `~/.local/bin/` copy over the repo-root snapshot, so an edit made live must be
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

## How configs/ syncs

`sync_configs.sh` applies a per-cfg policy in its staging step:

| cfg | Policy | Why |
|---|---|---|
| `yazi` | **replace** — repo's `configs/yazi/` becomes CIRCE's `~/.config/yazi/` | Container-specific openers (e.g. bookokrat for PDFs) |
| `tmux` | **replace** — repo's `configs/tmux/` becomes CIRCE's `~/.config/tmux/` | Container-specific multiplexer config (replaced zellij); no Mac copy |
| `bookokrat` | **replace** — repo's `configs/bookokrat/` becomes CIRCE's `~/.config/bookokrat/` | Container owns the bookokrat config |
| `nvim` | **overlay** — Mac's `~/.config/nvim/` is staged, then `configs/nvim/*` is rsync'd on top | Keeps your Mac LazyVim config canonical; drops in the container plugins |
| `avante.nvim`, `github-copilot`, `btm` | **mac-only** — direct from Mac | No container-specific overrides needed (but see the Copilot auth note below) |

**Copilot auth is stored unencrypted, on purpose.** The Mac's
`~/.config/nvim/lua/plugins/copilot.lua` (tracked in `02_dotfiles`) launches
`copilot-language-server` with `GITHUB_COPILOT_AUTH_TOKEN_ENCRYPTION=false`.
Otherwise the server encrypts `~/.config/github-copilot/auth.db` with a key held
in the macOS login Keychain, and macOS asked for Keychain access on every nvim
launch. The nvim overlay carries that setting into the container too, so both
sides read and write the token in plaintext. A container has no Keychain
anyway, so Mac-encrypted auth entries could never have been decrypted here.
Don't drop the override from either side; if Copilot reports it is signed out,
run `:Copilot auth` on the Mac and re-sync.

To add another override: drop files into `configs/<cfg>/` and (if needed) add
the cfg name to `CONFIG_LIST` and the `replace`/`overlay` case in `sync_configs.sh`.

## R packages — PPM

`install.packages("tidyverse")` pulls precompiled Ubuntu binaries from PPM —
about 30s vs. ~10 minutes for the from-source CRAN build. The config lives at
`/etc/R/Rprofile.site` inside the container; switch the URL from
`noble/latest` to `noble/2026-MM-DD` for a pinned, reproducible snapshot.
