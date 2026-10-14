# CIRCE container — operating notes

This file is synced from the `05_Container` repo (`configs/claude/CLAUDE.md` →
CIRCE `~/.claude/CLAUDE.md`) by `sync_configs.sh`. Edit the REPO copy; the next
sync overwrites this one.

## Read this before debugging anything "impossible" in the container

You are (probably) inside a udocker/Fakechroot-F3 container whose root
filesystem lives on **node-local `/tmp`**, which CIRCE age-prunes by **atime**
on a ~10-day window. `/tmp` is mounted `relatime` and `stat()` does not refresh
atime, so the files that die are exactly the ones nothing ever *opens* — while
anything the runtime opens on each launch stays fresh forever.

Every occurrence has the same shape: **a tree half-eaten along its hot/cold
seam**, presenting as a bug in whatever tool needed the cold half.

| Victim | Survivor (why it stayed hot) | Symptom |
| --- | --- | --- |
| python stdlib `*.py` | `__pycache__/*.pyc` — read on every start; the `.py` is only `stat`ed | `no codec search functions registered`, `Could not find platform independent libraries`; **python won't start at all** |
| zsh completion functions | the `.zwc` digests (autoloaded) | wall of text (`compinit`/`compdump` bodies) at every shell start |
| nvim `lazy/` plugin sources | each plugin's compact `.git` | LazyVim `module not found` cascade |
| udocker `bin/`, `lib/` | the one loaded `libfakechroot` | `patchelf executable not found` at setup |
| **nvim's own runtime** (`/usr/local/share/nvim/runtime`) | `lua/vim/{lsp,uri,glob,re}` — what an LSP session opens | `no file './vim.so'` traceback from lazy.nvim, `E216: No such group or event: filetypedetect`. **Looks like a LazyVim/plugin bug; the plugin store is fine** |
| R `site-library` | nothing — went to 1 of 43 packages | nvim's R LSP dies, no visible connection to R |
| (next one) | whatever it opens per launch | some tool insisting a file it shipped with is missing |

### Recognising it

Suspect the reaper — not a version, image, glibc, packaging, or script bug —
whenever **something that worked last week now behaves as if part of its own
install were missing**, and the missing part is under a `/tmp`-backed path
(`/usr/**` inside the container, `~/.local/share/nvim`, `/tmp/$USER/.udocker`).
Two tells that settle it fast:

* `ls` the directory and **count**: a reap leaves the directory and its
  hot files, so `encodings/` with 1 entry instead of ~120 is the signature.
  A surviving `__init__.py` proves nothing — the reap eats from the cold end.
* Check the container's age: `ls -l /usr/bin/python3.13` (the extract date).
  Past ~10 days on the same node, assume it.

Do **not** conclude "the image is broken", "the venv is misconfigured", or
"upgrade python" — the image is fine, and a rebuild costs an hour to fix a
problem a tar extract fixes in seconds.

### Fixing it

**Reconnect.** `./connect_nvim.sh` (from the Mac) execs `~/bin/udocker_dev.sh`
on the node, which repairs any gutted subtree from the rootfs tar and then
backgrounds an atime sweep across the whole ROOT. That is the entire procedure —
there is no separate tool and nothing to run in-container.

From a node shell (outside the container) you can also run
`~/bin/udocker_dev.sh --doctor`, which check/repairs and exits without starting
a container. Repair costs ~0.015s on a healthy ROOT, so it runs on every connect
unconditionally.

If a victim shows up that the guard table does not cover yet, **add a row to
`_REAP_GUARDS` in the repo's `udocker_dev.sh`** rather than fixing it by hand —
one line, and it stops the next recurrence. Prevention already covers unguarded
paths; only the repair half is table-limited.

## Other standing container facts

* **`.venv` here is not a real venv** — `.venv/bin/python3` symlinks to
  `/usr/bin/python3`, so it inherits the system stdlib and offers no fallback
  when that stdlib is damaged. Only `site-packages` is local.
* **PDFs open in bookokrat, in a half split beside the caller.** yazi's `o` on a
  `*.pdf`/`*.epub`, snacks-explorer's `o`, `gx`/`vim.ui.open` and VimTeX's
  `<localleader>lv` all end up in `~/.local/bin/bookokrat-split`, which splits the
  current window and starts `/usr/local/bin/bookokrat` there. Opening a second PDF
  reuses that reader pane (`respawn-pane`) instead of splitting again; opening one
  already on screen just jumps to it. Panes are tagged with the pane option
  `@bkfile`, which is how both of those are recognised.

  **A page left painted over the window you switched to is a known bug
  (bookokrat#179), and the cleanup is already wired.** Under Ghostty the page is a
  classic Kitty placement, and tmux holds no cell that stands for it, so tmux
  cannot repaint it away. `~/.local/bin/tmux-kitty-image-gc` deletes it by writing
  the Kitty delete escape straight to the client tty — `~/.config/tmux/tmux.conf`
  calls it from `session-window-changed` / `client-session-changed`, and
  `bookokrat-split` appends it to the reader's own command line so quitting the
  reader also clears the page. Returning to a reader costs a ~1-1.5s repaint
  (remote render + re-upload); that is the SSH page floor, not a fault.

  Do **not** reintroduce `~/.local/bin/override/bookokrat` or its `tmux` shim.
  That wrapper forced bookokrat's Unicode-placeholder anchor path on, which
  Ghostty 1.3.1 does not implement — the page lands on top of yazi and the
  reader's pane stays empty — and the anchor path needs SHM transmission, which
  cannot reach a terminal on another machine anyway.
* **Config files are one-way** from the `05_Container` repo. `~/.zshrc`,
  `~/bin/*`, `~/.config/*` and this file are rsynced over by `sync_configs.sh`;
  any live edit here is silently reverted by the next sync. Fix the repo copy.
* **Static binaries escape the container.** `git` (the static one), `gh`,
  `lazygit` are Go/musl statics that bypass `libfakechroot`, so their child
  processes get the RHEL7 host loader against the container's glibc:
  `relocation error: ... _dl_find_dso_for_object ... GLIBC_PRIVATE`. That error
  is a *different* family from the reaper — it means "a static binary spawned a
  dynamic child", not "files are missing".

  There is a **second, opposite** mismatch with the identical error text. `claude`
  is a 297 MB **dynamic** Bun ELF whose `PT_INTERP` F3's patchelf pass left alone
  (nvim's points at `<ROOT>//lib64/ld-linux-x86-64.so.2`; claude.exe still asks for
  a bare `/lib64/ld-linux-x86-64.so.2`). The kernel resolves `PT_INTERP` against
  the HOST root before any `LD_PRELOAD` exists, so RHEL7's glibc-2.17 loader starts
  it against the container's glibc-2.39 libc. Fix in `udocker_dev.sh`: a
  `/usr/local/bin/claude` wrapper naming the container's loader explicitly, by
  absolute host path. So: **static binary → its dynamic children break; unpatched
  dynamic binary → it breaks itself.** Check `readelf -l <bin> | grep interpreter`
  to tell them apart.

  `herdr` is the exception that proves the rule: the image builds it from source
  as a dynamic binary because the static release would break every pane. Do not
  `herdr update` or install the release binary here.

  A static binary also *reads* the host tree, which broke Quarto:
  `cannot open /opt/quarto/share/filters/qmd-reader.lua: No such file or
  directory` from its bundled static pandoc (typst had the same problem with
  its fonts and packages). The image now replaces both with dynamic builds of
  the same versions. If that error comes back, `file
  /opt/quarto/bin/tools/x86_64/pandoc` will say "statically linked", which means
  the container predates the fix and needs the rebuilt image. Do not suggest udocker P1/proot (slow) or
  `QUARTO_PANDOC=/usr/bin/pandoc` (3.1.3 is too old). Paths under `$HOME`,
  `/work` and `/tmp` look the same from both sides, so a static tool that only
  reads those is fine.
