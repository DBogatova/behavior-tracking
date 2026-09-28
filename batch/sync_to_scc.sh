#!/usr/bin/env bash
# =============================================================================
# sync_to_scc.sh
#
# Push the batch/ code directory to the BU SCC over the multiplexed `scc` SSH
# alias (defined in ~/.ssh/config with ControlMaster/ControlPath). This copies
# CODE ONLY -- it is not a data-sync tool.
#
# SAFETY MODEL
#   * DRY-RUN BY DEFAULT: running it with no flags shows exactly what WOULD be
#     transferred and changes nothing. You must pass --go to actually transfer.
#   * NEVER DELETES on the remote: we deliberately do NOT pass rsync --delete,
#     so files that exist only on the cluster (results, edits, other agents'
#     work) are never removed by a sync. This is intentional -- see the rsync
#     invocation below.
#   * FAILS FAST, NEVER HANGS: it refuses up front if there is no live
#     ControlMaster session, and uses ssh BatchMode so it can never block on a
#     password/Duo prompt.
#
# TWO-FACTOR NOTE
#   SCC requires Duo on every new SSH connection. This script does NOT
#   authenticate. You must first open (and Duo-approve) a master connection:
#         ssh scc
#   which creates the multiplexed control socket (~/.ssh/cm-...). This script
#   then reuses that socket. If the socket is missing, it refuses with
#   instructions instead of triggering an interactive prompt.
#
# USAGE
#   ./sync_to_scc.sh              # dry run (default) -- shows what would change
#   ./sync_to_scc.sh --go         # actually transfer
#   ./sync_to_scc.sh -h           # help
#
# OVERRIDES (environment variables)
#   SCC_HOST     ssh alias/host           (default: scc)
#   LOCAL_DIR    source dir               (default: this script's directory)
#   REMOTE_DIR   destination on cluster   (default: /projectnb/devorlab/daria/code/batch)
# =============================================================================

set -euo pipefail

# ---- configuration ----------------------------------------------------------
SCC_HOST="${SCC_HOST:-scc}"
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
LOCAL_DIR="${LOCAL_DIR:-${_SCRIPT_DIR}}"

# ---- SAFETY GUARDS (validated FIRST, before any connection attempt) --------
# Path confinement is unconditional: a bad override must fail for the RIGHT
# reason regardless of whether an SSH session happens to be live.
# shellcheck disable=SC1091
# Load the guard, then FAIL CLOSED if it did not actually define anything (an
# empty, truncated, or shadowed guard file sources without error).
if [ ! -s "${_SCRIPT_DIR}/scc_guard.sh" ]; then
    echo "SAFETY ABORT: ${_SCRIPT_DIR}/scc_guard.sh is missing or empty." >&2
    echo "  Refusing to touch the cluster unguarded. Re-sync batch/ and retry." >&2
    exit 3
fi
# shellcheck disable=SC1091
source "${_SCRIPT_DIR}/scc_guard.sh"
if ! declare -F guard_require >/dev/null 2>&1; then
    echo "SAFETY ABORT: scc_guard.sh loaded but defines no guards (corrupt file?)." >&2
    exit 3
fi
guard_require
REMOTE_DIR="$(assert_remote_path_allowed "${REMOTE_DIR:-/projectnb/devorlab/daria/code/batch}" "REMOTE_DIR (sync destination)")"
# Default remote is a sibling of the existing complete_behavior copy, so that
# run_behavior_batch's `../complete_behavior` path resolves on the cluster:
#   /projectnb/devorlab/daria/code/batch              <- this code
#   /projectnb/devorlab/daria/code/complete_behavior  <- shared legacy helpers
REMOTE_DIR="${REMOTE_DIR:-/projectnb/devorlab/daria/code/batch}"

usage() {
    sed -n '2,45p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# ---- parse arguments --------------------------------------------------------
DRY_RUN=1
while [ "$#" -gt 0 ]; do
    case "$1" in
        --go|--run|--transfer|--execute) DRY_RUN=0 ;;
        -n|--dry-run)                     DRY_RUN=1 ;;
        -h|--help)                        usage; exit 0 ;;
        *) echo "ERROR: unknown argument: $1" >&2; echo "Try -h for help." >&2; exit 2 ;;
    esac
    shift
done

# ---- guard: refuse without a live ControlMaster session ---------------------
# `ssh -O check` asks whether the multiplexed master is running. It only probes
# the local control socket; it never opens a new connection, so it cannot
# trigger Duo and cannot hang. BatchMode + a short timeout make that guarantee
# explicit. If there is no master, it exits non-zero and we refuse cleanly.
if ! ssh -o BatchMode=yes -o ConnectTimeout=5 -O check "${SCC_HOST}" >/dev/null 2>&1; then
    cat >&2 <<EOF
ERROR: no live SSH ControlMaster session for '${SCC_HOST}'.

This script reuses a multiplexed SSH connection so it never has to prompt for
Duo. That master connection is not currently open.

Fix:
  1. Open and Duo-approve a session:   ssh ${SCC_HOST}
     (you can leave it open, or it persists per your ControlPersist setting)
  2. Confirm the control socket now exists:   ls ~/.ssh/cm-*
  3. Re-run this script.

Refusing now rather than hanging on a password/Duo prompt.
EOF
    exit 1
fi

# ---- build the rsync command ------------------------------------------------
# -a  archive (recurse + preserve perms/times/symlinks)
# -h  human-readable sizes
# -v  verbose (list files)
# --itemize-changes  show a per-file change summary (great for auditing a sync)
# -e "ssh ..."  reuse the multiplexed master; BatchMode so it fails instead of
#               prompting; short connect timeout so it never hangs.
#
# NOTE: there is deliberately NO --delete flag. We never remove anything on the
# remote side, so cluster-only files (results, other stages' outputs) survive.
RSYNC_SSH="ssh -o BatchMode=yes -o ConnectTimeout=10"

RSYNC_ARGS=(
    -a -h -v
    --itemize-changes
    --exclude='.DS_Store'
    --exclude='*.asv'
    --exclude='.git'
    --exclude='.git/'
    --exclude='__pycache__/'
    --exclude='*.pyc'
    --exclude='pipeline_logs/'   # local run logs; no value on the cluster
    --exclude='results/'         # locally fetched results; never push these up
)

if [ "${DRY_RUN}" -eq 1 ]; then
    RSYNC_ARGS+=(--dry-run)
fi

# Trailing slash on the source copies the CONTENTS of LOCAL_DIR into REMOTE_DIR
# (not LOCAL_DIR nested inside it).
# ---- SAFETY GUARDS (see scc_guard.sh) --------------------------------------
# This is the only script that WRITES to the cluster, so it is guarded twice:
# the destination must resolve inside the allowed roots, and the rsync argument
# list must contain no delete/truncate flag.
assert_rsync_nondestructive "${RSYNC_ARGS[@]}"

SRC="${LOCAL_DIR%/}/"
DST="${SCC_HOST}:${REMOTE_DIR%/}/"

echo "=============================================================="
echo "sync_to_scc.sh"
echo "  mode      : $([ "${DRY_RUN}" -eq 1 ] && echo 'DRY RUN (no changes; pass --go to transfer)' || echo 'TRANSFER (--go)')"
echo "  from      : ${SRC}"
echo "  to        : ${DST}"
echo "  delete    : NO (never; --delete is intentionally not used)"
echo "  confined  : ${SCC_ALLOWED_ROOTS}"
echo "=============================================================="

rsync "${RSYNC_ARGS[@]}" -e "${RSYNC_SSH}" "${SRC}" "${DST}"
RSYNC_STATUS=$?

echo
if [ "${DRY_RUN}" -eq 1 ]; then
    echo "Dry run complete (exit ${RSYNC_STATUS}). Nothing was transferred."
    echo "Re-run with --go to perform the transfer."
else
    echo "Transfer complete (exit ${RSYNC_STATUS})."
fi
exit "${RSYNC_STATUS}"
