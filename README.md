# FinTech Tools Container — v0.7

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
./sync_configs.sh   # push to CIRCE: term_session.sh → ~/sh/, proot_dev.sh → ~/bin/,
                    # bookokrat-{split,forward,inverse} → ~/.local/bin/,
                    # and ~/.config/{nvim,yazi,tmux,bookokrat,…}
```

Daily use: `sbatch ~/sh/term_session.sh`, then `./connect_nvim.sh` from the Mac.
The launcher extracts the rootfs to node-local `/tmp` and enters the container.
After a rebuild, clear an already-extracted node's sandbox to pick up the
new image: `rm -rf /tmp/$USER/fintech-sbx`.

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
| Terminal | tmux (multiplexer), Yazi (file manager) with all recommended deps, lazygit, `ncurses-term` (many terminfos) |
| AI agents | `claude` (Claude Code) **is** bundled as an in-container fallback, but runs sluggishly under proot (`PROOT_NO_SECCOMP=1` ptraces every syscall) — prefer running it locally on the Mac and driving the node over SSH. The standalone `copilot` CLI is **not** bundled (run locally). Neovim's inline Copilot (LSP via `copilot.lua`/`avante.nvim`) **is** included. |
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
  - `bookokrat-split` — opens a PDF in a new tmux split (forwards `$NVIM` for inverse search).
  - `bookokrat-forward` — VimTeX forward search (`<localleader>lv`): jumps an open instance, or launches one.
  - `bookokrat-inverse` — synctex inverse search: `gd` / Ctrl-click in the PDF jumps Neovim to the source line.
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

## How configs/ syncs

`sync_configs.sh` applies a per-cfg policy in its staging step:

| cfg | Policy | Why |
|---|---|---|
| `yazi` | **replace** — repo's `configs/yazi/` becomes CIRCE's `~/.config/yazi/` | Container-specific openers (e.g. bookokrat for PDFs) |
| `tmux` | **replace** — repo's `configs/tmux/` becomes CIRCE's `~/.config/tmux/` | Container-specific multiplexer config (replaced zellij); no Mac copy |
| `bookokrat` | **replace** — repo's `configs/bookokrat/` becomes CIRCE's `~/.config/bookokrat/` | Container owns the bookokrat config |
| `nvim` | **overlay** — Mac's `~/.config/nvim/` is staged, then `configs/nvim/*` is rsync'd on top | Keeps your Mac LazyVim config canonical; drops in the container plugins |
| `avante.nvim`, `github-copilot`, `btm` | **mac-only** — direct from Mac | No container-specific overrides needed |

To add another override: drop files into `configs/<cfg>/` and (if needed) add
the cfg name to `CONFIG_LIST` and the `replace`/`overlay` case in `sync_configs.sh`.

## R packages — PPM

`install.packages("tidyverse")` pulls precompiled Ubuntu binaries from PPM —
about 30s vs. ~10 minutes for the from-source CRAN build. The config lives at
`/etc/R/Rprofile.site` inside the container; switch the URL from
`noble/latest` to `noble/2026-MM-DD` for a pinned, reproducible snapshot.
