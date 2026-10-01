# 05_Container — repo notes

Build and operate the `fintech-tools` container that runs on USF's CIRCE
cluster: `Dockerfile` + `build_container.sh` produce a flat rootfs tar,
`udocker_dev.sh` launches it on a compute node via udocker's Fakechroot (F3)
engine, `sync_configs.sh` pushes the dotfiles and helper scripts to CIRCE.

## The `/tmp` reaper — the single most common failure here

**If something in the container behaves as though part of its own install were
missing, this is the cause. Check it before any other theory.**

The container ROOT lives on node-local `/tmp` (`udocker_dev.sh`'s storage
split), and CIRCE age-prunes `/tmp` by **atime** on a ~10-day window. `/tmp` is
`relatime` and `stat()` does not refresh atime, so what dies is exactly what
nothing ever *opens*, while whatever the runtime opens each launch stays fresh.
The result is always a tree half-eaten along its hot/cold seam, presenting as a
bug in whichever tool needed the cold half:

| Victim | Survivor | Symptom |
| --- | --- | --- |
| python stdlib `*.py` | `__pycache__/*.pyc` (read; the `.py` is only `stat`ed) | `no codec search functions registered` — python won't start at all |
| zsh completion functions | `.zwc` digests | wall of text at every shell start |
| nvim `lazy/` sources | each plugin's `.git` | LazyVim `module not found` cascade |
| udocker `bin/`, `lib/` | the loaded `libfakechroot` | `patchelf executable not found` |
| **nvim's own runtime** (`/usr/local/share/nvim/runtime`) | `lua/vim/{lsp,uri,glob,re}` — what an LSP session opens | `no file './vim.so'` traceback from lazy.nvim, `E216: No such group or event: filetypedetect`. **Looks like a LazyVim/plugin bug; the plugin store is fine** |
| R `site-library` | nothing — went to 1 of 43 packages | nvim's R LSP dies, no visible connection to R |

Confirmed on 2026-08-21: after the python restore, nvim still failed — **because
the reaped tree was nvim's runtime inside the ROOT, not the plugin store**. The
plugin store (`~/.local/share/nvim/lazy`, 47 repos, 0 deleted files) had been
swept since June and was pristine; `/usr/local/share/nvim/runtime` had 4 of ~40
`lua/vim/*.lua` and 17 of 775 `syntax/*.vim`. Restoring it took 0.4s. Always
check **which** tree is missing files before blaming the tool that reported it.

Diagnosis: **count** entries in the suspect directory (a reap eats from the cold
end, so a surviving `__init__.py` proves nothing), and check the ROOT's age
(`ls -l` any container binary — that's the extract date). Past ~10 days on the
same node, assume it. It is never a version, glibc, image, or packaging bug, and
never worth a rebuild.

Ownership lives in **`udocker_dev.sh`** (the `_REAP_GUARDS` table plus
`_reap_repair` / `_reap_sweep`, right after the two older sweeps). It runs on
**every connect** — `connect_nvim.sh` execs `~/bin/udocker_dev.sh` on the node
each time, reattach included — so there is nothing to remember and nothing to
invoke. Two halves:

1. **Prevention** — `_reap_sweep` backgrounds a `touch -a` over the whole ROOT,
   rate-limited to once per 12h via a stamp file. Nothing goes cold, so
   *unguarded* victims (TinyTeX, R's library, man pages) are covered too. This
   is the real fix: connect at least every ~10 days and the reaper never
   reaches anything. Backgrounded with stdin/stdout/stderr on `/dev/null`, so it
   never delays a connect and never holds the `ssh -tt` channel open.
2. **Repair** — `_reap_repair` probes the guarded subtrees by file **count** and
   re-extracts what was gutted from `~/fintech-sb/fintech-rootfs.tar`. This is
   the net for the window where you did *not* connect for ten days.
   **A new victim is one new row in `_REAP_GUARDS`**, never a bespoke fix.

Cost on a healthy ROOT: **~0.015s** — seven `find -maxdepth 1 | head` calls that
stop early, flat in the size of the ROOT. `~/bin/udocker_dev.sh --doctor`
check/repairs and exits without starting a container, for diagnosing from a node
shell; a plain reconnect does the same thing.

`udocker_dev.sh` also keeps two older, narrower sweeps for paths outside the
ROOT (udocker's own `bin/`+`lib/`, and the nvim plugin store), and `.zshrc`'s
`_nvim_heal` repairs the plugin store after the fact via `git checkout -f`.

### The repair un-patches what it restores

`fintech-rootfs.tar` is the pristine image, so every binary in it still carries
the **stock** `PT_INTERP`. F3 does not chroot: it rewrites each ELF's
interpreter to the absolute host path of the container's own glibc-2.39 loader
(`<ROOT>//lib64/ld-linux-x86-64.so.2`), once, at setup. A `tar x` restore
therefore hands those binaries back with `/lib64/ld-linux-x86-64.so.2`, the
kernel resolves that against the **host** root before any `LD_PRELOAD` exists,
and RHEL7's glibc-2.17 loader is handed the container's 2.39 libc:
`_dl_find_dso_for_object ... GLIBC_PRIVATE`. Not a missing file, so the reaper
checklist above will not find it.

Two guarded subtrees hold every non-apt binary in the image, which is why this
bites: `usr/lib/node_modules` (tree-sitter-cli, claude) and
`usr/local/lib/R/site-library` (processx's `px`/`supervisor`/`sock` and ps's `px`, which `callr` and Quarto rendering sit on). Found 2026-09-03
when `tree-sitter` would not run; every stock-interpreter binary on the node
was inside one of those two, and the R library had been restored on 2026-08-21
from 1 surviving package of 43.

`_interp_repair` in `udocker_dev.sh` re-points them, called straight after each
restore and again as `_interp_sweep` on every connect for a hand-installed
`npm -g` or `install.packages()`. Detection is one `file` pass per tree, which
prints the interpreter, so the usual connect costs a few `stat`s: the sweep only
scans when a watched directory is newer than its stamp. **A new install root is
one new row in `_INTERP_DIRS`.** `claude.exe` is deliberately excluded — it is
a Bun bundle hiding a payload behind offsets stored in itself, and it already
works through its loader wrapper, so patchelf has nothing to win there and a
corrupt 297 MB binary to lose.

### The look-alike that is *not* the reaper: a stuck lazy.nvim clone

A plugin that acts as though it were never installed can also be a leftover
`<plugin-dir>.cloning` marker, and that one has nothing to do with `/tmp`.
lazy.nvim arms the marker *before* it clones and unlinks it only when git exits
0, so interrupting a first install — quitting nvim, or a network stall, which
on a compute node means the CONNECT proxy — leaves it behind. From then on
`core/plugin.lua`'s `update_state()` drops that plugin from the installed set
on every startup while ignoring the perfectly good directory beside it; the
clone task then wipes that directory and re-clones, forever, once per launch.

Tell them apart by *what is missing*. A reap leaves a half-eaten tree with the
`.git` intact and no marker; this leaves a **complete** plugin with a 0-byte
`<name>.cloning` file next to it. Hit 2026-09-03 by `quarto-render.nvim`, the
only plugin still mid-first-install and the only one absent from
`lazy-lock.json`. A fresh node or fresh ROOT puts the *whole* plugin set into
that state at once, so this is a first-launch risk on every new container.

Fixed in the `nvim()` wrapper, not by a rebuild: `_nvim_unstick_clones` in
`.zshrc` (and the same few lines in the image's `/etc/zsh/zshrc`, so a fresh
container has it before the first config sync) drops a marker whose sibling
repo has a resolvable `HEAD` — proof the clone finished. An unresolvable HEAD
means the checkout really is unfinished, and lazy's own re-clone is then the
correct behaviour, so those are left alone. Cost on a healthy store is one
readdir and no git process. Deliberately *not* added to `udocker_dev.sh`: that
check runs on the host, whose RHEL7 git 1.8.3.1 refuses lazy's `blob:none`
partial clones (`repositoryformatversion=1`) and would silently never fire.

## Conventions that bite

* **Config sync is one-way.** `sync_configs.sh` rsyncs repo-owned files onto
  CIRCE (`.zshrc`, `bin/*`, `sh/term_session.sh`, `.config/*`,
  `.claude/CLAUDE.md`) with no reverse path. Any live fix on CIRCE — including
  edits made by third-party installers that rewrite `~/.zshrc` — is reverted by
  the next sync. **Always fix the repo copy.** Build time is likewise a dead end
  for `$HOME`: CIRCE's home bind-mounts over the image's.
* **Static binaries escape the container.** `git` (the static bundle), `gh` and
  `lazygit` are Go/musl statics that bypass `libfakechroot`, so the dynamic
  children they spawn get the RHEL7 host loader against the container's glibc:
  `relocation error: ... _dl_find_dso_for_object ... GLIBC_PRIVATE`. Distinct
  family from the reaper — "static spawned a dynamic child", not "files gone".
  Fixes in place: static git for lazygit *only*; a `gh` wrapper that puts
  symlinks to the container's own git/ssh/less/nvim, by absolute host path,
  first on gh's PATH, so the host exec lands on a PT_INTERP-patched binary that
  loads libfakechroot (every git-spawning subcommand: repo create/clone/fork,
  pr checkout, set-default).
  There is a **second, opposite** mismatch with the identical error text. `claude`
  is a 297 MB **dynamic** Bun ELF whose `PT_INTERP` F3's patchelf pass left alone
  (nvim's points at `<ROOT>//lib64/ld-linux-x86-64.so.2`; claude.exe still asks for
  a bare `/lib64/ld-linux-x86-64.so.2`). The kernel resolves `PT_INTERP` against
  the HOST root before any `LD_PRELOAD` exists, so RHEL7's glibc-2.17 loader starts
  it against the container's glibc-2.39 libc. Fix in `udocker_dev.sh`: a
  `/usr/local/bin/claude` wrapper naming the container's loader explicitly, by
  absolute host path. So: **static binary → its dynamic children break; unpatched
  dynamic binary → it breaks itself.** There is a **third**: a correctly patched
  binary that a reaper tar restore reverted to stock, covered above. Check
  `readelf -l <bin> | grep interpreter` to tell them apart — a container path
  means healthy, a bare `/lib64/...` means one of the latter two.

* **glibc reads locale data from the HOST, not the ROOT.** `setlocale()` opens
  its files via glibc-internal calls libfakechroot can't hook (the same wall as
  `resolv.conf`), so without help every process runs in the C locale.
  Symptom: `locale` prints `Cannot set LC_ALL`, and zsh counts multibyte
  characters by the byte. Fix: `udocker_dev.sh` compiles a
  directory-form `en_US.UTF-8` into the ROOT and passes
  `LOCPATH=<ROOT>/usr/lib/locale`; `.zshrc` sets it too for older tmux servers.
  Check: `s="░▒▓❯"; print ${(m)#s}` must be 4, not 12.
* **Prompt erases lines above on vi-mode switch = starship initialised twice.**
  The image's `/etc/zsh/zshrc` already runs `starship init zsh`; a second init in
  `.zshrc` wraps its `zle-keymap-select`, so `zle reset-prompt` runs twice per
  switch and zsh redraws the two-line prompt a row too high each time (2 lines
  lost per Esc/i). `.zshrc` now inits only if `prompt_starship_precmd` is
  undefined. Any other double `reset-prompt` in one widget does the same.
* **The bookokrat helpers are ONE file each, shared by Mac and container.**
  `bookokrat-{split,forward,inverse}`, `tmux-kitty-image-gc` and
  `tmux-resurrect-age` all run on both sides, and `sync_configs.sh` prefers the LIVE `~/.local/bin/` copy over the
  repo-root snapshot. So an edit made live must be copied back here, **and an
  edit made only here is thrown away by the next sync** — write both. Platform
  differences go inside the file (`uname -s`), not in two copies of it: that is
  how `bookokrat-split` picks `/opt/homebrew/bin/bookokrat` on the Mac and
  `/usr/local/bin/bookokrat` in the container. Anything launching the reader
  from a non-login shell must name the binary by absolute path; `zsh -c` never
  sources `.zshrc`.

  `tmux-resurrect-age` feeds the save-age pill (time since the last prefix
  Ctrl-s) on both status bars. The container builds the pill from
  `configs/tmux/modules/resurrect.conf`, a copy of the Mac's module that differs
  only in the catppuccin path. Its GNU/BSD `stat` order matters: GNU first. GNU
  `stat -f %m` prints filesystem info before failing, which breaks a BSD-first
  fallback on Linux.

  **The `~/.local/bin/override/bookokrat` wrapper is retired — do not bring it
  back.** It (with its `tmux` shim under `~/.local/libexec/`) answered
  bookokrat's outer-terminal probe with `kitty` to force the
  Unicode-placeholder anchor path on, the tmux-trackable one, so a PDF page
  would not survive a tmux window switch (bookokrat#179). Ghostty 1.3.1 does
  not implement the relative placements that path emits (Kitty keys `P=`/`Q=`):
  it drops them and paints the page at the cursor — on top of yazi, with the
  reader's pane left empty. Retired on the Mac 2026-09-04, and it could never
  have worked here anyway, the anchor path being implemented only over SHM
  transmission while bookokrat's shm object sits in `/dev/shm` on the compute
  node and Ghostty runs on the Mac. #179 is handled instead by
  `tmux-kitty-image-gc`: `configs/tmux/tmux.conf`'s `session-window-changed` /
  `client-session-changed` hooks call it, and `bookokrat-split` appends it to
  the reader's own command line for the exit case. It deletes only Kitty z-index
  -1 and image id 1 — where bookokrat draws and where yazi does not — so a
  preview in the neighbouring pane survives. Repaint costs ~1-1.5s here against
  ~100-300ms on the Mac; that is the remote page floor, not a fault.
* **No AI plugins in nvim — avante.nvim and Copilot were removed 2026-10-01**
  because they kept failing to build. They are gone from both sides at once:
  the Mac's `lazyvim.json` (canonical in `02_dotfiles`) dropped the `ai.avante`
  and `ai.copilot` extras and their `lua/plugins/{avante,copilot}.lua`, the
  nvim overlay carries that to CIRCE, the Dockerfile no longer installs
  `@github/copilot-language-server`, and `sync_configs.sh` no longer pushes
  `~/.config/{avante.nvim,github-copilot}`. Don't re-add them through
  `configs/nvim`; Claude Code (`claude`) is the in-container AI tool.
* **SSH to CIRCE is rate-limited by source IP** on a shared VPN pool address.
  One connection per session: use the `circe` alias, reuse the master
  (`ssh -O check`), and never re-run a refused command.
* **`.venv` in the analysis projects is not a real venv** —
  `.venv/bin/python3` → `/usr/bin/python3`, so it shares (and can't rescue) the
  system stdlib.
