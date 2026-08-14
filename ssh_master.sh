#!/bin/bash
# ssh_master.sh — shared login-node connection budget helper.  SOURCE this, do
# not execute it:  . "${SCRIPT_DIR}/ssh_master.sh"
#
# ─── Why this exists ─────────────────────────────────────────────────────────
# CIRCE's login node rate-limits by SOURCE IP and answers over-limit traffic with
# ICMP host-prohibited, which ssh reports as "Connection refused" on every port
# (ping stops answering too).  The GlobalProtect VPN address is a SHARED pool
# address, so the budget is not entirely ours to spend — every script that talks
# to the login node must spend as little as possible.
#
# The leak was never failed auths; it was connection COUNT, and it was structural.
# Each script opened its own master on its own socket path, keyed by the RAW
# hostname (`gson@circe.rc.usf.edu`).  Two consequences, both silent:
#   1. `Host circe` in ~/.ssh/config does NOT match the raw hostname (ssh matches
#      Host patterns against the name on the command line), so IdentityFile
#      ~/.ssh/circe_key was never offered → password fallback → failed auths on a
#      key-only account.
#   2. A master killed by a VPN reconnect or laptop sleep leaves its socket file
#      behind.  ssh finds the dead socket, quietly declines to multiplex, and
#      dials fresh — with no warning that sharing stopped.  So a "one connection"
#      workflow degrades to 3+ per attempt, times every rerun after a failure.
#
# This helper gives every caller ONE connection, on the ONE socket path that
# ~/.ssh/config defines, and makes the rerun reflex impossible for 15 minutes
# after a refusal.  Contract:
#   * always address the login node by its ~/.ssh/config ALIAS (`circe`), never
#     by hostname — that is what supplies the key, the ControlPath and the
#     keepalives.
#   * never hardcode a ControlPath; ask ssh for it (circe_control_path).
#   * subsequent ssh/scp/rsync ride the master as CHANNELS — free, invisible to
#     the firewall.  Do NOT `ssh -O exit` it when you are done; ControlPersist
#     reaps it and the other scripts reuse it.
#
# connect_nvim.sh carries a STANDALONE copy of this logic (it is deployed to
# $HOME by itself and cannot source this file).  Keep the two in sync — the
# backoff stamp path is shared on purpose, so a refusal seen by one script is
# honoured by all of them.

# The ~/.ssh/config Host alias for the login node. Not a hostname — see above.
CIRCE_ALIAS="${CIRCE_ALIAS:-circe}"
# How long to sit out after a refusal. Matches connect_nvim.sh's BACKOFF_SECS.
CIRCE_BACKOFF_SECS="${CIRCE_BACKOFF_SECS:-900}"
# Shared across all three scripts, deliberately.
CIRCE_REFUSED_STAMP="$HOME/.ssh/sockets/.circe_refused"

# Ask ssh where the master socket for $CIRCE_ALIAS lives (%r/%h/%p already
# expanded). Single source of truth: edit ~/.ssh/config, not these scripts.
circe_control_path() {
  ssh -G "$CIRCE_ALIAS" 2>/dev/null | awk '/^controlpath /{print $2}'
}

# True if a master is alive. `ssh -O check` is the ONLY reliable liveness test —
# the socket file existing proves nothing (that is the stale-socket trap above).
circe_master_alive() {
  ssh -O check "$CIRCE_ALIAS" 2>/dev/null
}

# Honour an active backoff. Returns 1 (still blocked) or 0 (clear to dial).
# Prints guidance to stderr; callers should treat 1 as fatal.
circe_backoff_active() {
  [ -f "$CIRCE_REFUSED_STAMP" ] || return 1
  local age
  age=$(( $(date +%s) - $(stat -f %m "$CIRCE_REFUSED_STAMP") ))
  if [ "$age" -lt "$CIRCE_BACKOFF_SECS" ]; then
    {
      echo ""
      echo "The login node refused us $((age / 60))m ago; sitting out the"
      echo "remaining $(( (CIRCE_BACKOFF_SECS - age) / 60 ))m rather than redialing."
      echo ""
      echo "Retrying now extends the block. If you need in sooner, reconnect"
      echo "GlobalProtect for a new VPN address, then: rm $CIRCE_REFUSED_STAMP"
      echo ""
    } >&2
    return 0
  fi
  rm -f "$CIRCE_REFUSED_STAMP"
  return 1
}

# Open (or reuse) exactly ONE master to the login node.
# Exits 1 rather than degrading to per-transfer connections — a build or sync
# that prompts "individually" is precisely the burst that trips the limit.
circe_ensure_master() {
  mkdir -p "$HOME/.ssh/sockets"

  if circe_master_alive; then
    echo "✓ Reusing existing SSH master to ${CIRCE_ALIAS} (no new connection)"
    return 0
  fi

  if circe_backoff_active; then
    exit 1
  fi

  # Clear a dead master's leftovers first, or `ssh -MNf` hits "ControlSocket
  # already exists", silently disables multiplexing, and every later transfer
  # dials its own connection.
  #
  # Both lines below MUST NOT be allowed to fail the caller. sync_configs.sh and
  # build_container.sh run under `set -e`, and neither of these is an error:
  # `ssh -O exit` returns nonzero when there is no master to close (the normal
  # case on a cold start), and the `[ -n ]` test returns nonzero when ssh -G
  # reported no ControlPath. Without the guards the caller died HERE, silently,
  # before reaching the dial or any of the error messages below — which is
  # exactly what happened on 2026-08-14: `./sync_configs.sh` printed its local
  # install line and then just stopped, with the real cause (VPN down, so the
  # login node timed out) never shown. Unnoticed until now only because every
  # earlier run found a live master and returned before reaching this point.
  ssh -O exit "$CIRCE_ALIAS" 2>/dev/null || true
  local cp
  cp="$(circe_control_path)"
  if [ -n "$cp" ]; then rm -f "$cp"; fi

  echo "Opening master connection to ${CIRCE_ALIAS} (one for this whole run)..."
  local err
  if ! err=$(ssh -o ConnectTimeout=15 -MNf "$CIRCE_ALIAS" 2>&1); then
    if printf '%s' "$err" | grep -qi 'connection refused\|prohibited'; then
      date +%s > "$CIRCE_REFUSED_STAMP" 2>/dev/null
      {
        echo ""
        echo "${CIRCE_ALIAS} refused the connection."
        echo ""
        echo "This is a firewall reject, not sshd being down — the source IP is"
        echo "blocked. Do not rerun in a loop; that extends it. Either wait it"
        echo "out (~15m, backing off automatically) or reconnect GlobalProtect"
        echo "to get a new VPN address."
        echo ""
      } >&2
    else
      echo "Could not reach ${CIRCE_ALIAS}:" >&2
      printf '%s\n' "$err" >&2
    fi
    exit 1
  fi
  echo "✓ SSH master established"
}
