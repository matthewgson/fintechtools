# FinTech Tools Container — v0.7

HPC container for Financial / Quantitative computing. Workflow has migrated
from VSCode Remote-SSH (legacy, still works) to **Neovim** SSH.

## Build

```bash
./build_container.sh
```

Does it all: builds with Podman → `podman export` to a flat rootfs tar →
optional `scp` to CIRCE (`/work/g/gson/fintech-rootfs.tar`).
Pushover notifications fire if `~/.pushover_config` is set.

Prereqs (one-time):

```bash
brew install podman
podman machine init && podman machine start
```

## Running on CIRCE

One-time setup (the build script deploys the rootfs tar automatically):

```bash
./sync_configs.sh   # deploys term_session.sh → ~/sh/ and proot_dev.sh → ~/bin/ on CIRCE
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
| AI CLIs | `copilot` (GitHub Copilot standalone CLI) + `claude` (Anthropic Claude Code) |
| SSH | `openssh-client` (git/scp); sshd not used |
| mac-open | `/usr/local/bin/mac-open` — pure-Python client that ships files/URLs to a listener on the Mac (see "mac-open" below). VimTeX's PDF viewer (`<localleader>lv`) is routed through it by `configs/nvim/lua/plugins/vimtex.lua`. |

Yazi deps included (per [yazi docs](https://yazi-rs.github.io/docs/installation)):
`file`, `p7zip`, `jq`, `poppler-utils`, `fd`, `ripgrep`, `fzf`,
`zoxide`, `imagemagick`, `resvg`, `unar`.

```

## mac-open — open remote files on Mac browser

Pure-Python bridge so yazi / snacks-explorer inside the container can hand PDFs,
HTML, and images to the Mac's default browser/Preview. Two files, no external
dependencies:

- `mac_open_listener.py` (runs on Mac) — HTTP listener on `127.0.0.1:8765`, calls `open`.
- `mac_open.py` (baked into container as `/usr/local/bin/mac-open`) — POSTs file/URL.

Wiring: `connect_nvim.sh` adds `-R 8765:127.0.0.1:8765` to the SSH command, so
the container's `localhost:8765` is the Mac's loopback.

### Setup

1. **Rebuild + sync** — `./build_container.sh` does three things at once when
   you accept all the prompts:
   - Bakes `mac-open` (from `mac_open.py`) into the container as `/usr/local/bin/mac-open`.
   - Deploys configs to CIRCE:
     - `configs/yazi/yazi.toml` → CIRCE `~/.config/yazi/yazi.toml` (full replace).
     - `configs/nvim/lua/plugins/mac_open.lua` → CIRCE `~/.config/nvim/lua/plugins/`
       (overlaid on top of your Mac nvim config; LazyVim auto-discovers it).
   - Installs the Mac listener locally: `mac_open_listener.py` → `~/mac_open_listener.py` (executable).
2. **Run the listener as a LaunchAgent** so it auto-starts at login and
   restarts on failure — forgetting to start it is the #1 cause of silent
   "open does nothing" failures.

   One-time install:
   ```bash
   launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/com.matthewson.mac-open-listener.plist
   ```

   Manage it:

   ```bash
   launchctl kickstart -k gui/$(id -u)/com.matthewson.mac-open-listener   # restart
   launchctl bootout    gui/$(id -u)/com.matthewson.mac-open-listener     # stop+unload
   lsof -nP -iTCP:8765                                                    # verify it's listening
   tail -f ~/Library/Logs/mac-open-listener.log                           # watch traffic
   ```

   Files arrive in `~/.mac-open-inbox`. If you prefer a visible terminal
   instance instead, bootout the agent and run `~/mac_open_listener.py` by
   hand (Ctrl-C to stop).
3. **Connect** with `./connect_nvim.sh` — it adds `-R 8765:127.0.0.1:8765` to
   the ssh command automatically. It also pre-checks that something is bound
   to `127.0.0.1:8765` on the Mac and uses `ExitOnForwardFailure=yes` so a
   port collision on the compute node aborts immediately instead of dropping
   you into a shell with a dead tunnel.

### Where the files live

| File | Lives | Notes |
|---|---|---|
| `mac_open.py` | repo + `/usr/local/bin/mac-open` in container | Baked into image at build time |
| `mac_open_listener.py` | repo + `~/mac_open_listener.py` on Mac | Copied by `build_container.sh` |

### How configs/ syncs

`sync_configs.sh` applies a per-cfg policy in its staging step:

| cfg | Policy | Why |
|---|---|---|
| `yazi` | **replace** — repo's `configs/yazi/` becomes CIRCE's `~/.config/yazi/` | Container needs `mac-open` opener; Mac uses the native `open` command |
| `tmux` | **replace** — repo's `configs/tmux/` becomes CIRCE's `~/.config/tmux/` | Container-specific multiplexer config (replaced zellij); no Mac copy |
| `nvim` | **overlay** — Mac's `~/.config/nvim/` is staged, then `configs/nvim/*` is rsync'd on top | Keeps your Mac LazyVim config canonical; just drops in the `mac_open.lua` plugin |
| `avante.nvim`, `github-copilot`, `btm` | **mac-only** — direct from Mac | No container-specific overrides needed |

To add another override: drop files into `configs/<cfg>/` and (if needed) add
the cfg name to `CONFIG_LIST` and the `replace`/`overlay` case in `sync_configs.sh`.

### Test

After SSH'ing in via `./connect_nvim.sh` (with the Mac listener running):

```bash
mac-open https://example.com           # browser pops up on Mac
mac-open /work/g/gson/some.pdf    # PDF opens on Mac
```

In yazi: hit `o` on a `.pdf`/`.html`/image → routes through `mac-open`.
In Neovim/snacks-explorer: `o` on the same files works the same way (via the
`vim.ui.open` override in `mac_open.lua`).

### Troubleshooting

- **`mac-open` doesn't respond in yazi / snacks-explorer.** First check the
  listener is up on the Mac: `lsof -nP -iTCP:8765` should show a Python
  process bound. If empty: `launchctl kickstart -k gui/$(id -u)/com.matthewson.mac-open-listener`.
  Yazi opens with `block = false, orphan = true` and snacks calls
  `vim.system(..., { detach = true })`, so both swallow any error — running
  `mac-open <file>` manually inside the container surfaces the real message.
- "cannot reach Mac listener" → the listener isn't running on Mac, or you
  SSH'd in without going through `connect_nvim.sh` (so no `-R` forward).
- Tail traffic on the Mac: `tail -f ~/Library/Logs/mac-open-listener.log` —
  each request prints an `open-url` / `open-file` line.
- Port collision on the compute node: with `ExitOnForwardFailure=yes` in
  `connect_nvim.sh`, ssh now aborts with a clear "remote port forwarding
  failed for listen port 8765" if a previous (orphaned) session is holding
  the port. Wait for the stale tunnel to expire or kill the owning ssh
  process on the compute node.

## R packages — PPM

`install.packages("tidyverse")` pulls precompiled Ubuntu binaries from PPM —
about 30s vs. ~10 minutes for the from-source CRAN build. The config lives at
`/etc/R/Rprofile.site` inside the container; switch the URL from
`noble/latest` to `noble/2026-MM-DD` for a pinned, reproducible snapshot.
