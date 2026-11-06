# FinTech Tools Container — v0.9.1

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
                    # the farleaf helpers → ~/.local/bin/,
                    # ~/.config/{nvim,yazi,tmux,starship,…},
                    # and the Mac's herdr settings + plugins
```

Daily use: `sbatch ~/sh/term_session.sh`, then `./connect_nvim.sh` from the Mac.
The launcher (udocker, Fakechroot/F3) imports the rootfs into node-local `/tmp`
and enters the container. It auto-refreshes when the tar is newer than the
unpacked copy, so a rebuild is picked up with no manual step.

## What's inside (v0.9.1)

| Stack | Detail |
|---|---|
| Base | Ubuntu 24.04 LTS (Noble) headless |
| Python | **3.13** via deadsnakes; `/usr/local/bin/python{,3}` symlinked, env vars (`PYTHON`, `RETICULATE_PYTHON`, `UV_PYTHON`) point here — **not** the system 3.12 |
| uv | Astral binary in `/usr/local/bin/` |
| R | **4.x** from CRAN noble-cran40, default repo set to [**Posit Package Manager**](https://packagemanager.posit.co/) (`noble/latest`) so `install.packages()` pulls binary builds for Ubuntu instead of compiling from source |
| Quarto | Latest GitHub release, installed at `/opt/quarto`, on `$PATH` as `quarto`. Bundles pandoc, typst + Deno. The bundled pandoc and typst are static, and under udocker F3 a static binary looks up `/opt/quarto/share` on the host, so the image replaces both with dynamic builds of the same versions (pandoc from `pandoc/core:<v>-ubuntu`, typst compiled in its own stage). PDF output works out of the box via the TinyTeX install below, or via typst. |
| LaTeX | **TinyTeX** baked in at `/opt/TinyTeX` — installed via direct tarball pull from [`rstudio/tinytex-releases`](https://github.com/rstudio/tinytex-releases) (`TinyTeX-linux-x86_64-<TAG>.tar.xz`), no R/Rscript dependency in Stage 5d. Binaries symlinked into `/usr/local/bin` via `tlmgr path add` (with `sys_bin` pinned explicitly so the build does not fall back to `/root/.local/bin`). Ships `latexmk`, `pdflatex`, `xelatex`, `lualatex`, `biber`, plus `collection-latexrecommended`, `collection-fontsrecommended`, `biblatex`, and `synctex` (forward search). VimTeX (`lang.tex` extra) and Quarto find them automatically. The image is read-only at runtime, so extra packages install in user-mode — `TEXMFHOME` is pinned to `~/texmf` in zshenv so `tlmgr --usermode init-usertree && tlmgr --usermode install <pkg>` lands in a predictable, kpathsea-discoverable tree (no root required). Alternatively, rebuild the container with the package appended to Stage 5d. A pre-existing `~/.TinyTeX` install is honored — zshenv prepends it to `$PATH` so any user-installed extras win over the system copy. |
| Editor | Neovim (latest) + LazyVim starter |
| Own nvim plugins | [quarto-render.nvim](https://github.com/matthewgson/quarto-render.nvim) (Quarto CLI above) and [replstudio.nvim](https://github.com/matthewgson/replstudio.nvim) (R/Python REPL + plot pane), both cloned from GitHub by lazy.nvim, so the container runs what has been **pushed**. replstudio's container spec is `configs/nvim/lua/plugins/replstudio.lua`, which replaces the Mac's `dir =` copy. The image carries only the `duckdb` CLI for its parquet viewer. Its Python venv (`~/.local/share/replstudio/venv`) and R's `ragg` are installed at runtime, into `$HOME` |
| LazyVim extras | Whatever the Mac's `~/.config/nvim/lazyvim.json` enables (the nvim sync is an overlay of it), minus `lang.rust`. No AI extras: avante.nvim and Copilot were removed 2026-10-01 |
| Terminal | **tmux 3.6b** (multiplexer, built from source — newer than 24.04's apt 3.4, which is too old for ghostty's CSI-u extended keys over SSH and broke `Ctrl+Space`/`Ctrl+h/j/k/l`), **herdr** (agent multiplexer, built from source as a dynamic binary — see "herdr" below), Yazi (file manager) with all recommended deps, lazygit, `ncurses-term` (many terminfos) |
| AI agents | `claude` (Claude Code), `copilot` (GitHub Copilot CLI) and `codex` (OpenAI Codex CLI) are bundled, all installed globally with npm into `/usr/lib/node_modules`. `claude` runs well in-container under udocker/F3 (much snappier than the old ptrace runtime). `codex`'s agent is a **static musl** binary, so it bypasses libfakechroot like `gh`: `udocker_dev.sh` writes a `/usr/local/bin/codex` wrapper that puts host-path symlinks to the container's bash/git/ssh first on `PATH` and sets `SHELL` (see the `codex` block there; not yet verified on a node). Codex's own bwrap sandbox cannot work on CIRCE (no user namespaces), so run it with `--sandbox danger-full-access`. The nvim Copilot/avante plugins and `copilot-language-server` stay removed (2026-10-01). |
| SSH | `openssh-client` (git/scp); sshd not used |
| PDF viewer | **farleaf** at `/usr/local/bin/farleaf` — terminal PDF reader (kitty graphics, renders over SSH and in herdr; no X11). VimTeX (`<localleader>lv`), yazi, and snacks-explorer route PDFs to it (see "PDF viewing" below). |

Yazi deps included (per [yazi docs](https://yazi-rs.github.io/docs/installation)):
`file`, `p7zip`, `jq`, `poppler-utils`, `fd`, `ripgrep`, `fzf`,
`zoxide`, `imagemagick`, `resvg`, `unar`.

```

## PDF viewing — farleaf

PDFs open in **[farleaf](https://github.com/matthewgson/farleaf)**, the user's
own terminal reader, which draws inline via the kitty graphics protocol, so
**ghostty** shows it straight over SSH and inside herdr: no X11/XQuartz and no
Mac-side helper. It replaced bookokrat on 2026-10-29.

- **Binary** — baked into the image at `/usr/local/bin/farleaf` (Dockerfile Stage
  5f) from farleaf's GitHub release (`farleaf-linux-x64.tar.gz`, checked against
  the release's `SHA256SUMS`); `build_container.sh` resolves the latest release.
  It is a dynamic glibc binary, so it has to be in the image (F3 patches its
  loader there), not in `$HOME`. Under herdr it sends the next and previous
  pages ahead, so a page turn only moves images herdr already sent. The Mac
  installs it with farleaf's `install.sh` (`~/.local/bin`).
- **Helpers** — synced to `~/.local/bin/` by `sync_configs.sh` (on `$PATH` inside the container):
  - `farleaf-split FILE [PAGE[:Y]]` — opens a PDF in a **half herdr split beside
    the caller**. Opening a second PDF replaces the reader in that tab rather
    than splitting again; opening one already open brings its pane forward.
    farleaf does not run inside tmux.
  - `farleaf-forward` — VimTeX forward search (`<localleader>lv`): `synctex view`
    (TinyTeX's `synctex`, Stage 5d) gives the line's page and height; the PDF
    opens there, or the farleaf already showing it is sent there (`:PAGE:Y`).
  - Inverse search (farleaf 0.6.0+): **Ctrl-click** a line in farleaf (or `gd`)
    and the nvim that has the project open goes to its source line and gets the
    focus. farleaf runs `$FARLEAF_SYNCTEX_EDITOR` (set in `.zshrc`), VimTeX's
    `VimtexInverseSearch`; right-click is herdr's pane menu.
  - `herdr-focus-pane PANE` — focuses a herdr pane by id (herdr focuses panes
    only by direction); nvim calls it after an inverse search.
- **One file each, shared with the Mac.** `sync_configs.sh` prefers the LIVE
  `~/.local/bin/` copy over the repo's `local-bin/` snapshot, so an edit made live must be
  copied back to the repo **and** an edit made only in the repo is discarded by the
  next sync. Platform differences live inside the scripts (`uname -s`), which is how
  `farleaf-split` picks `~/.local/bin/farleaf` on the Mac and `/usr/local/bin/farleaf`
  here.
- **Wiring** — VimTeX (`configs/nvim/lua/plugins/vimtex.lua`, `general` viewer), yazi
  (`*.pdf` opener), and `vim.ui.open` / snacks-explorer (`pdf_open.lua`,
  `snacks.lua`) all route PDFs to farleaf. EPUBs have no reader here.

### Test

After SSH'ing in via `./connect_nvim.sh`, from a herdr pane in the container:

```bash
farleaf-split /work/g/gson/some.pdf   # opens in a herdr split
```

In yazi: Enter on a `.pdf` opens it in a farleaf split. In Neovim:
`<localleader>lv` in a `.tex` forward-searches.

## HTML in Safari — mac-open

`o` on an `.html` file in yazi or the nvim explorer, and `gx` on a URL in nvim,
open it in **Safari on the Mac**, as they would locally. The container's
`~/.local/bin/mac-open` does the work. You can also call it by hand:
`mac-open report.html` or `mac-open https://…`.

- **Only through `connect_nvim.sh`.** Each connection it makes carries two
  extra SSH forwards, both private Unix sockets:
  - one from the node to a small listener on the Mac, which runs
    `open -a Safari`;
  - one from a Mac port (18374 or the next free one) to a page server on the
    node.

  The connect banner reports it: `mac-open is on: … (port 18374)`, or
  `mac-open is OFF:` and the reason. A session opened any other way has
  neither forward, and `mac-open` says so. Reconnecting through
  `connect_nvim.sh` fixes it, and your herdr layout survives the reconnect.
  An nvim or yazi already running in a herdr pane keeps its old config until
  you restart it.
- **Served, not copied.** Safari reads the page over HTTP from the node, so a
  Quarto or R Markdown page finds its `*_files/` folder, and **reload** shows a
  fresh render. The URL contains a random token, and the server answers only
  requests addressed to `127.0.0.1` or `localhost`.
- **HTML and http(s) URLs only.** PDFs still go to farleaf. A
  `http://localhost:…` URL printed on the node (`quarto preview`) points at
  the node, not the Mac, so it will not load in Safari.

## herdr

[herdr](https://herdr.dev) is the container's multiplexer, and the startup
messages point only to it. tmux (`tm`) stays installed, though nothing here
needs it any more (PDFs open in herdr splits). Start herdr by hand after `./connect_nvim.sh`:
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
| `yazi` | **replace** — repo's `configs/yazi/` becomes CIRCE's `~/.config/yazi/` | Container-specific openers (e.g. farleaf for PDFs) |
| `tmux` | **replace** — repo's `configs/tmux/` becomes CIRCE's `~/.config/tmux/` | Container-specific multiplexer config (replaced zellij); no Mac copy |
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
