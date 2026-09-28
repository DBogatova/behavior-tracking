#!/usr/bin/env bash
# =============================================================================
# fetch_results.sh
#
# Pull PROCESSED behavior results from the BU SCC cluster back to this local
# machine, over the multiplexed `scc` SSH connection (ControlMaster socket set
# up by `ssh scc`). This is the "results-fetch" step of the pipeline: it is the
# inverse of sync_to_scc.sh (which pushes CODE up). This tool only pulls DATA
# down.
#
# SAFETY MODEL (identical philosophy to sync_to_scc.sh)
#   * DRY-RUN BY DEFAULT: with no flags it shows exactly what WOULD be copied
#     and changes nothing. You must pass --go to actually transfer.
#   * NEVER DELETES anything, locally or remotely: we deliberately do NOT pass
#     rsync --delete. Files that exist only locally (older results, hand edits,
#     published copies) are never removed by a fetch, and nothing on the cluster
#     is ever touched (rsync only reads the source in a pull). See the rsync
#     invocation below -- the absence of --delete is intentional.
#   * FAILS FAST, NEVER HANGS: refuses up front if there is no live
#     ControlMaster session, and uses ssh BatchMode so it can never block on a
#     Duo/password prompt.
#
# WHAT IT FETCHES
#   By default only the SMALL, VALUABLE artifacts:
#       csv/<base>_behavior.csv   csv/<base>_accel.csv   csv/<base>_info.txt
#       mat/<base>_behavior.mat   figures/<base>_panels.{pdf,png}
#       batch_manifest.csv        (and any qc_report.* / publish_log.csv present)
#   The LARGE per-run trigger CSVs (csv/<base>_trigger.csv) are EXCLUDED unless
#   you pass --with-trigger-csv, because they can be very large and are only
#   needed for auditing channel detection.
#
# TWO-FACTOR NOTE
#   SCC requires Duo on every new SSH connection. This script does NOT
#   authenticate. First open (and Duo-approve) a master connection:
#         ssh scc
#   which creates the multiplexed control socket (~/.ssh/cm-...). This script
#   reuses that socket. If it is missing, it refuses with instructions rather
#   than triggering an interactive prompt.
#
# USAGE
#   ./fetch_results.sh                      # dry run (default) -- shows what would copy
#   ./fetch_results.sh --go                 # actually transfer
#   ./fetch_results.sh --go --with-trigger-csv   # also pull the large trigger CSVs
#   ./fetch_results.sh -h                   # help
#
# OVERRIDES (environment variables; every default is documented inline below)
#   SCC_HOST           ssh alias/host                  (default: scc)
#   REMOTE_OUT_DIR     cluster output dir to pull from (default:
#                        /projectnb/devorlab/daria/Femtonics/behavior/processed)
#   LOCAL_RESULTS_DIR  local destination dir           (default: <scriptdir>/results)
#   SSH_CONNECT_TIMEOUT  ssh ConnectTimeout seconds     (default: 10)
# =============================================================================

set -euo pipefail

# ---- configuration (env-overridable; defaults documented inline) ------------
# The ssh alias defined in ~/.ssh/config (User daria, HostName scc1.bu.edu,
# ControlMaster/ControlPath/ControlPersist already configured there).
SCC_HOST="${SCC_HOST:-scc}"
# Cluster directory that run_behavior_batch.m / submit_behavior.qsub write to
# (OUT_DIR there). Contains csv/, mat/, figures/, batch_manifest.csv.
REMOTE_OUT_DIR="${REMOTE_OUT_DIR:-/projectnb/devorlab/daria/Femtonics/behavior/processed}"
# Where the results land locally. Defaults to a 'results' dir beside this script.
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
LOCAL_RESULTS_DIR="${LOCAL_RESULTS_DIR:-${_SCRIPT_DIR}/results}"
# ssh connect timeout so a dead socket fails in seconds, never hangs.
SSH_CONNECT_TIMEOUT="${SSH_CONNECT_TIMEOUT:-10}"

# ---- SAFETY GUARDS (validated FIRST, before any connection attempt) --------
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
REMOTE_OUT_DIR="$(assert_remote_path_allowed "${REMOTE_OUT_DIR}" "REMOTE_OUT_DIR (fetch source)")"

# ---- defaults for parsed flags ----------------------------------------------
DRY_RUN=1              # 1 = dry-run (default), 0 = transfer (--go)
# Fetch *_trigger.csv by DEFAULT. publish_to_project.py treats it as a
# consumer-visible artifact (it lands in trigger/ where behavior_plots.py
# globs '*_trigger.csv'), so excluding it by default made every orchestrated
# run report "skipped-missing-source" at publish time. Pass --no-trigger-csv
# to skip it when you only need the behaviour/accel signals and want a
# faster transfer.
WITH_TRIGGER_CSV=1

usage() {
    # Print the header block as help (lines 2..60, stripping the leading "# ").
    sed -n '2,60p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# ---- parse arguments --------------------------------------------------------
while [ "$#" -gt 0 ]; do
    case "$1" in
        --go|--run|--transfer|--execute) DRY_RUN=0 ;;
        -n|--dry-run)                     DRY_RUN=1 ;;
        --with-trigger-csv|--triggers)    WITH_TRIGGER_CSV=1 ;;
        --no-trigger-csv|--no-triggers)   WITH_TRIGGER_CSV=0 ;;
        -h|--help)                        usage; exit 0 ;;
        *) echo "ERROR: unknown argument: $1" >&2; echo "Try -h for help." >&2; exit 2 ;;
    esac
    shift
done

# ---- guard: refuse without a live ControlMaster session ---------------------
# `ssh -O check` only probes the LOCAL control socket; it never opens a new
# connection, so it cannot trigger Duo and cannot hang. BatchMode + a short
# ConnectTimeout make that guarantee explicit. No master -> exit non-zero and
# refuse cleanly (never fall through to an interactive prompt).
if ! ssh -o BatchMode=yes -o ConnectTimeout="${SSH_CONNECT_TIMEOUT}" -O check "${SCC_HOST}" >/dev/null 2>&1; then
    cat >&2 <<EOF
ERROR: no live SSH ControlMaster session for '${SCC_HOST}'.

This script reuses a multiplexed SSH connection so it never has to prompt for
Duo. That master connection is not currently open.

Fix:
  1. Open and Duo-approve a session:   ssh ${SCC_HOST}
     (leave it open; ControlPersist keeps the socket alive per your ssh config)
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
# --itemize-changes  per-file change summary (great for auditing a fetch)
# --prune-empty-dirs keep the local tree tidy when excludes empty a subdir
# -e "ssh ..."  reuse the multiplexed master; BatchMode so it fails instead of
#               prompting; short connect timeout so it never hangs.
#
# NOTE: there is deliberately NO --delete flag. A pull with --delete could wipe
# local files that are not on the cluster; we never do that. And because this is
# a pull, the remote (source) is only ever READ -- nothing on the cluster is
# modified or removed.
RSYNC_SSH="ssh -o BatchMode=yes -o ConnectTimeout=${SSH_CONNECT_TIMEOUT}"

RSYNC_ARGS=(
    -a -h -v
    --itemize-changes
    --prune-empty-dirs
    --exclude='.DS_Store'
    --exclude='*.tmp.*'          # never fetch publisher/atomic temp files
)

# The only large artifact: per-run trigger CSVs. Excluded unless opted in.
if [ "${WITH_TRIGGER_CSV}" -eq 0 ]; then
    RSYNC_ARGS+=(--exclude='*_trigger.csv')
fi

if [ "${DRY_RUN}" -eq 1 ]; then
    RSYNC_ARGS+=(--dry-run)
fi

# Trailing slash on the source copies the CONTENTS of REMOTE_OUT_DIR into
# LOCAL_RESULTS_DIR (not REMOTE_OUT_DIR nested inside it).
# ---- SAFETY GUARDS (see scc_guard.sh) --------------------------------------
# Read-only with respect to the cluster, but the source path is still confined
# so a mistyped override cannot read outside your own directories, and the
# rsync flags are still checked so nothing can be deleted on either side.
assert_rsync_nondestructive "${RSYNC_ARGS[@]}"

SRC="${SCC_HOST}:${REMOTE_OUT_DIR%/}/"
DST="${LOCAL_RESULTS_DIR%/}/"

echo "=============================================================="
echo "fetch_results.sh"
echo "  mode          : $([ "${DRY_RUN}" -eq 1 ] && echo 'DRY RUN (no changes; pass --go to transfer)' || echo 'TRANSFER (--go)')"
echo "  trigger CSVs  : $([ "${WITH_TRIGGER_CSV}" -eq 1 ] && echo 'INCLUDED (--with-trigger-csv)' || echo 'excluded (large; pass --with-trigger-csv to include)')"
echo "  from (remote) : ${SRC}"
echo "  to   (local)  : ${DST}"
echo "  delete        : NO (never; --delete is intentionally not used)"
echo "  confined      : ${SCC_ALLOWED_ROOTS}"
echo "=============================================================="

# Create the local destination only AFTER the socket check passes, so a refusal
# never leaves an empty results dir behind.
mkdir -p "${DST}"

rsync "${RSYNC_ARGS[@]}" -e "${RSYNC_SSH}" "${SRC}" "${DST}"
RSYNC_STATUS=$?

echo
if [ "${DRY_RUN}" -eq 1 ]; then
    echo "Dry run complete (exit ${RSYNC_STATUS}). Nothing was transferred."
    echo "Re-run with --go to perform the fetch."
else
    echo "Fetch complete (exit ${RSYNC_STATUS}). Results in ${DST}"
fi
exit "${RSYNC_STATUS}"
