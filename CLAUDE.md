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
  Fixes in place: static git for lazygit *only*, `gh` wrapper redirecting
  `repo clone` to the dynamic git.
* **SSH to CIRCE is rate-limited by source IP** on a shared VPN pool address.
  One connection per session: use the `circe` alias, reuse the master
  (`ssh -O check`), and never re-run a refused command.
* **`.venv` in the analysis projects is not a real venv** —
  `.venv/bin/python3` → `/usr/bin/python3`, so it shares (and can't rescue) the
  system stdlib.
