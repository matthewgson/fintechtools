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
* **Config files are one-way** from the `05_Container` repo. `~/.zshrc`,
  `~/bin/*`, `~/.config/*` and this file are rsynced over by `sync_configs.sh`;
  any live edit here is silently reverted by the next sync. Fix the repo copy.
* **Static binaries escape the container.** `git` (the static one), `gh`,
  `lazygit` are Go/musl statics that bypass `libfakechroot`, so their child
  processes get the RHEL7 host loader against the container's glibc:
  `relocation error: ... _dl_find_dso_for_object ... GLIBC_PRIVATE`. That error
  is a *different* family from the reaper — it means "a static binary spawned a
  dynamic child", not "files are missing".
