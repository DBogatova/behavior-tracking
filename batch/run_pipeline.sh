#!/usr/bin/env bash
# =============================================================================
# run_pipeline.sh
#
# Top-level orchestrator for the behavior-processing pipeline. It ties the
# whole multi-machine flow into as close to one command as is SAFELY possible:
#
#   raw TIFFs + trigger MATs on SCC
#        -> [rois]      draw ROIs (INTERACTIVE, needs a display)
#        -> [submit]    headless MATLAB PASS 2 + plots via qsub on SCC
#        -> [fetch]     rsync processed results back to this machine
#        -> [qc]        validate_outputs.py  (CORRECTNESS GATE)
#        -> [plots]     (re)render panels locally from the fetched CSVs
#        -> [publish]   publish_to_project.py into the analysis-script layout
#
# TWO STEPS CANNOT BE FULLY AUTOMATED, by design, and this script does not
# pretend otherwise:
#   1. Duo two-factor is required on EVERY new SSH connection. You must run
#      `ssh scc` and approve Duo ONCE; the multiplexed ControlMaster socket then
#      makes every subsequent ssh/rsync non-interactive. This script never
#      authenticates and never hangs on a prompt -- it refuses fast if the
#      socket is absent.
#   2. ROI drawing (collect_rois.m) needs a display, so the `rois` stage prints
#      guidance for running it on SCC OnDemand / X-forwarding instead of trying
#      (and failing) to automate it.
#
# STAGES (run in this order by default):
#   preflight sync-code inventory rois submit wait fetch qc plots publish
#
#   preflight   pass/fail checklist; STOPS before any work if something is wrong
#   sync-code   push this batch/ code to the cluster (sync_to_scc.sh --go)
#   inventory   find_runs report mode on the cluster (validate the layout)
#   rois        INTERACTIVE ROI collection -- guidance only (skips if done)
#   submit      qsub submit_behavior.qsub on the cluster; capture the job id
#   wait        poll qstat for the job; timeout + clear failure message
#   fetch       fetch_results.sh --go (pull results back)
#   qc          validate_outputs.py -- exit code GATES publishing
#   plots       behavior_panels.py --batch (local, from fetched CSVs)
#   publish     publish_to_project.py (DRY-RUN at tool level unless --publish-apply)
#
# GATES: a nonzero exit from any stage aborts the run by default. The qc stage's
# exit code specifically gates publish: QC FAIL never auto-publishes. --force
# overrides gate failures with a loud warning (and even then, publish's own
# --require-qc refuses individual FAIL runs, so bad data still cannot slip in).
#
# IDEMPOTENCE: re-running is safe. The underlying tools skip completed work
# (run_behavior_batch skips done runs; publish is a no-op on identical files;
# rsync has no --delete). submit refuses to launch a duplicate job if one named
# behavior_batch is already queued/running (unless --force).
#
# DRY-RUN: --dry-run prints every command it WOULD run and executes nothing.
# Publishing additionally stays dry-run at the TOOL level unless --publish-apply
# is given, regardless of orchestrator mode.
#
# Everything is logged, with a timestamp, to both the console and a local log
# file under ${LOG_DIR} (default: <scriptdir>/pipeline_logs/).
# =============================================================================

set -euo pipefail

# =============================================================================
# CONFIGURATION  (small block of variables; every one is env-overridable and
# documented inline. No magic strings are buried in the body below.)
# =============================================================================

# --- connection --------------------------------------------------------------
# ssh alias from ~/.ssh/config (User daria, HostName scc1.bu.edu, ControlMaster
# multiplexing + ControlPersist 8h already configured there).
SCC_HOST="${SCC_HOST:-scc}"
# ssh ConnectTimeout (seconds): a dead/closed socket fails fast, never hangs.
SSH_CONNECT_TIMEOUT="${SSH_CONNECT_TIMEOUT:-10}"

# --- cluster paths -----------------------------------------------------------
# Root scanned by find_runs (per-run TIFF folders + trigger MATs live under it).
DATA_ROOT="${DATA_ROOT:-/projectnb/devorlab/daria/Femtonics/behavior}"
# Cluster output dir written by run_behavior_batch / submit_behavior.qsub.
OUT_DIR="${OUT_DIR:-${DATA_ROOT}/processed}"
# ROI file produced by PASS 1 (collect_rois.m).
ROI_FILE="${ROI_FILE:-${DATA_ROOT}/rois.mat}"
# Where this batch/ code lives on the cluster (must sit beside complete_behavior
# so run_behavior_batch's ../complete_behavior path resolves). Matches
# sync_to_scc.sh's REMOTE_DIR default.
REMOTE_CODE_DIR="${REMOTE_CODE_DIR:-/projectnb/devorlab/daria/code/batch}"
# SGE environment module for MATLAB on the cluster (UNVERIFIED name; see PIPELINE.md).
# Verified present on scc1: matlab/2023a (same version tested locally).
# `module avail matlab` lists 2011b..2026a; default is 2026a.
MATLAB_MODULE="${MATLAB_MODULE:-matlab/2023a}"
# SGE job name used by submit_behavior.qsub (its `#$ -N` directive). qstat
# truncates job names to 10 chars, hence the *_10 form used for matching.
SGE_JOB_NAME="${SGE_JOB_NAME:-behavior_batch}"

# --- local paths -------------------------------------------------------------
# Directory holding this script and its sibling tools (validate_outputs.py, etc).
LOCAL_BATCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# Local mirror of OUT_DIR that fetch populates and qc/plots/publish read.
LOCAL_RESULTS_DIR="${LOCAL_RESULTS_DIR:-${LOCAL_BATCH_DIR}/results}"
# Consumer project data root the publisher installs into. NOTE: this defaults to
# the real on-disk 'scape-data' dir, NOT the 'data' symlink (which points at the
# frequently-unmounted /Volumes/IMAC/data).
PROJECT_ROOT="${PROJECT_ROOT:-/Users/daria/Desktop/Boston_University/Devor_Lab/apical-dendrites-2025/scape-data}"
# Local Python with numpy/pandas/scipy/matplotlib (used by qc/plots/publish).
# The default `python3` may lack these; point this at your venv/interpreter,
# e.g. PYTHON_BIN=python3.13 or PYTHON_BIN=/path/to/.venv/bin/python.
PYTHON_BIN="${PYTHON_BIN:-python3}"
# Timestamped run logs land here.
LOG_DIR="${LOG_DIR:-${LOCAL_BATCH_DIR}/pipeline_logs}"

# --- processing knobs (forwarded to submit_behavior.qsub via qsub -v) --------
MIN_FRAMES="${MIN_FRAMES:-100}"              # min TIFFs for a folder to count as a run
OVERWRITE="${OVERWRITE:-false}"              # 'true' reprocesses already-done runs
WHISKER_BINNING="${WHISKER_BINNING:-long}"   # 'long' | 'pad' : which whisker signal is binned
# 0 (default) = full-length traces in the .mat, crop later in post-processing.
# 1 = physically crop to the imaging window (legacy).
CROP_TO_WINDOW="${CROP_TO_WINDOW:-0}"
# 2P (Femtonics) pupils image BRIGHT; see submit_behavior.qsub.
PUPIL_POLARITY="${PUPIL_POLARITY:-bright}"
# 0 (default) = lightweight remote `find` for the inventory stage: no MATLAB
# and no license token on a shared login node. 1 = full find_runs report.
DEEP_INVENTORY="${DEEP_INVENTORY:-0}"
CROP_START="${CROP_START:-0}"                # seconds trimmed after alignment in the plots

# --- wait-stage polling ------------------------------------------------------
WAIT_TIMEOUT_S="${WAIT_TIMEOUT_S:-43200}"    # give up after this many seconds (12h == qsub h_rt)
WAIT_POLL_S="${WAIT_POLL_S:-30}"             # seconds between qstat polls

# =============================================================================
# runtime flags (set by argument parsing)
# =============================================================================
DRY_RUN=0            # --dry-run : print commands, execute nothing
FORCE=0              # --force   : continue past a failed stage / QC FAIL (loud)
PUBLISH_APPLY=0      # --publish-apply : pass --apply to publish (default: tool dry-run)
WITH_TRIGGER_CSV=1   # --no-trigger-csv : skip the large trigger CSVs on fetch.
                     # Default ON because publish_to_project.py treats the
                     # trigger CSV as a consumer-visible artifact.
QC_STRICT=0          # --strict  : treat QC WARN as a gate failure
JOB_ID="${JOB_ID:-}" # --job-id  : SGE job id for the wait stage (else read from state file)

# canonical ordered stage list
ALL_STAGES=(preflight sync-code inventory rois submit wait fetch qc plots publish)

SINGLE_STAGE=""
FROM_STAGE=""
TO_STAGE=""

usage() {
    cat <<EOF
run_pipeline.sh -- staged orchestrator for the behavior pipeline.

Stages (in order): ${ALL_STAGES[*]}

Usage:
  run_pipeline.sh [options]                 # default: run the full sequence
  run_pipeline.sh --stage STAGE             # run exactly one stage
  run_pipeline.sh --from STAGE [--to STAGE] # run an inclusive range

Options:
  --stage STAGE        Run only STAGE.
  --from STAGE         Start at STAGE (inclusive).
  --to STAGE           Stop after STAGE (inclusive).
  --dry-run            Print every command that would run; execute nothing.
  --force              Continue past a failed stage / QC FAIL (loud warning).
  --publish-apply      Pass --apply to publish_to_project.py (default: tool dry-run).
  --with-trigger-csv   Also fetch the large per-run trigger CSVs.
  --strict             Treat QC WARN as a gate failure (validate_outputs --strict).
  --job-id ID          SGE job id for the 'wait' stage (else read from state file).
  -h, --help           This help.

Key env overrides (see the CONFIGURATION block for the full, documented list):
  SCC_HOST DATA_ROOT OUT_DIR ROI_FILE REMOTE_CODE_DIR
  LOCAL_RESULTS_DIR PROJECT_ROOT PYTHON_BIN LOG_DIR
  MIN_FRAMES OVERWRITE WHISKER_BINNING CROP_TO_WINDOW PUPIL_POLARITY CROP_START WAIT_TIMEOUT_S WAIT_POLL_S
EOF
}

# =============================================================================
# argument parsing
# =============================================================================
while [ "$#" -gt 0 ]; do
    case "$1" in
        --stage)   SINGLE_STAGE="${2:-}"; shift ;;
        --from)    FROM_STAGE="${2:-}";   shift ;;
        --to)      TO_STAGE="${2:-}";     shift ;;
        --dry-run) DRY_RUN=1 ;;
        --force)   FORCE=1 ;;
        --publish-apply) PUBLISH_APPLY=1 ;;
        --with-trigger-csv) WITH_TRIGGER_CSV=1 ;;
        --no-trigger-csv)   WITH_TRIGGER_CSV=0 ;;
        --deep-inventory)   DEEP_INVENTORY=1 ;;
        --strict)  QC_STRICT=1 ;;
        --job-id)  JOB_ID="${2:-}";       shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "ERROR: unknown argument: $1" >&2; echo "Try -h for help." >&2; exit 2 ;;
    esac
    shift
done

# =============================================================================
# logging: tee everything (console + timestamped file)
# =============================================================================
mkdir -p "${LOG_DIR}"
RUN_TS="$(date +%Y%m%d_%H%M%S)"
LOG_FILE="${LOG_DIR}/run_pipeline_${RUN_TS}.log"
# Route stdout+stderr through tee so a long run is fully auditable afterwards.
exec > >(tee -a "${LOG_FILE}") 2>&1

# State file where 'submit' records the job id for 'wait' to pick up.
JOB_ID_FILE="${LOG_DIR}/last_job_id"

# =============================================================================
# SAFETY GUARDS -- validate every cluster path BEFORE any stage runs.
#
# Each of these is env-overridable, so each is checked. An override that points
# outside your own directories aborts the whole run here, before a single remote
# command is sent. See scc_guard.sh for the invariants.
# =============================================================================
# Load the guard, then FAIL CLOSED if it did not actually define anything (an
# empty, truncated, or shadowed guard file sources without error).
if [ ! -s "${LOCAL_BATCH_DIR}/scc_guard.sh" ]; then
    echo "SAFETY ABORT: ${LOCAL_BATCH_DIR}/scc_guard.sh is missing or empty." >&2
    echo "  Refusing to touch the cluster unguarded. Re-sync batch/ and retry." >&2
    exit 3
fi
# shellcheck disable=SC1091
source "${LOCAL_BATCH_DIR}/scc_guard.sh"
if ! declare -F guard_require >/dev/null 2>&1; then
    echo "SAFETY ABORT: scc_guard.sh loaded but defines no guards (corrupt file?)." >&2
    exit 3
fi
guard_require
DATA_ROOT="$(assert_remote_path_allowed       "${DATA_ROOT}"       "DATA_ROOT (cluster data, read-only)")"
OUT_DIR="$(assert_remote_path_allowed         "${OUT_DIR}"         "OUT_DIR (cluster job output)")"
ROI_FILE="$(assert_remote_path_allowed        "${ROI_FILE}"        "ROI_FILE (cluster ROI file)")"
REMOTE_CODE_DIR="$(assert_remote_path_allowed "${REMOTE_CODE_DIR}" "REMOTE_CODE_DIR (cluster code copy)")"

# Non-path parameters are interpolated into a MATLAB statement and into the
# qsub -v list, so each is an injection vector too. Validate their SHAPE.
MIN_FRAMES="$(assert_safe_token      "${MIN_FRAMES}"      "MIN_FRAMES"      int)"
CROP_TO_WINDOW="$(assert_safe_token  "${CROP_TO_WINDOW}"  "CROP_TO_WINDOW"  bool)"
DEEP_INVENTORY="$(assert_safe_token  "${DEEP_INVENTORY}"  "DEEP_INVENTORY"  bool)"
CROP_START="$(assert_safe_token      "${CROP_START}"      "CROP_START"      number)"
OVERWRITE="$(assert_safe_token       "${OVERWRITE}"       "OVERWRITE"       bool)"
WHISKER_BINNING="$(assert_safe_token "${WHISKER_BINNING}" "WHISKER_BINNING" word)"
SGE_JOB_NAME="$(assert_safe_token    "${SGE_JOB_NAME}"    "SGE_JOB_NAME"    word)"
MATLAB_MODULE="$(assert_safe_token   "${MATLAB_MODULE}"   "MATLAB_MODULE"   module)"
SCC_HOST="$(assert_safe_token        "${SCC_HOST}"        "SCC_HOST"        word)"
case "${WHISKER_BINNING}" in
    long|pad) : ;;
    *) echo "SAFETY ABORT: WHISKER_BINNING must be 'long' or 'pad', got '${WHISKER_BINNING}'" >&2; exit 3 ;;
esac

# =============================================================================
# helpers
# =============================================================================

log()  { printf '%s %s\n' "[$(date +%H:%M:%S)]" "$*"; }
warn() { printf '%s WARNING: %s\n' "[$(date +%H:%M:%S)]" "$*" >&2; }
err()  { printf '%s ERROR: %s\n'   "[$(date +%H:%M:%S)]" "$*" >&2; }

# Loud, impossible-to-miss banner (used for gate overrides / QC FAIL).
banner() {
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" >&2
    printf '!! %s\n' "$@" >&2
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" >&2
}

# Run a command (given as separate args), honoring --dry-run. Uses %q so the
# printed form is copy-pasteable and correctly quoted. NEVER builds a command by
# string interpolation -- the argv array is passed through verbatim.
run_cmd() {
    if [ "${DRY_RUN}" -eq 1 ]; then
        printf 'DRY-RUN would run:'; printf ' %q' "$@"; printf '\n'
        return 0
    fi
    printf '+'; printf ' %q' "$@"; printf '\n'
    "$@"
}

# Non-interactive ssh over the multiplexed master. BatchMode => never prompts;
# ConnectTimeout => never hangs. Remote command is passed as a single argument.
ssh_scc() {
    # Every remote command is screened for destructive verbs before it leaves
    # this machine. The pipeline is read-only on the cluster apart from qsub and
    # the guarded rsync upload, so a match here means something is wrong.
    assert_remote_cmd_safe "$*"
    ssh -o BatchMode=yes -o ConnectTimeout="${SSH_CONNECT_TIMEOUT}" "${SCC_HOST}" "$@"
}

# True iff the ControlMaster socket is live (probes local socket only; cannot
# trigger Duo, cannot hang).
have_master() {
    ssh -o BatchMode=yes -o ConnectTimeout="${SSH_CONNECT_TIMEOUT}" -O check "${SCC_HOST}" >/dev/null 2>&1
}

# The exact message we print anywhere a live master is required but absent.
print_no_master() {
    cat >&2 <<EOF
No live SSH ControlMaster session for '${SCC_HOST}'.
Duo is required on every new SSH connection, so this pipeline reuses a
multiplexed master socket instead of authenticating itself.

Fix:
  1. Open and Duo-approve a session:   ssh ${SCC_HOST}
  2. Confirm the socket exists:        ls ~/.ssh/cm-*
  3. Re-run this command.
EOF
}

# ---- index helpers for the stage list ---------------------------------------
stage_index() {
    local want="$1" i
    for i in "${!ALL_STAGES[@]}"; do
        [ "${ALL_STAGES[$i]}" = "${want}" ] && { echo "$i"; return 0; }
    done
    return 1
}

validate_stage_name() {
    local s="$1"
    if ! stage_index "$s" >/dev/null; then
        err "unknown stage '${s}'. Valid stages: ${ALL_STAGES[*]}"
        exit 2
    fi
}

# =============================================================================
# STAGE: preflight
# Verifies everything a long batch depends on, prints a pass/fail checklist, and
# returns nonzero if any check FAILs (so the orchestrator stops before any work).
# Cluster-side checks are SKIPPED (not failed) when no master socket exists, so
# one run still surfaces every locally-fixable problem alongside the socket one.
# =============================================================================
PF_FAIL=0
PF_WARN=0
pf_line() { printf '  [%-4s] %s\n' "$1" "$2"; }
pf_pass() { pf_line "PASS" "$1"; }
pf_warn() { pf_line "WARN" "$1"; PF_WARN=$((PF_WARN+1)); }
pf_fail() { pf_line "FAIL" "$1"; PF_FAIL=$((PF_FAIL+1)); }
pf_skip() { pf_line "SKIP" "$1"; }

stage_preflight() {
    log "STAGE preflight: verifying prerequisites"
    PF_FAIL=0; PF_WARN=0
    guard_summary

    if [ "${DRY_RUN}" -eq 1 ]; then
        echo "DRY-RUN preflight would check:"
        echo "  1. ControlMaster socket live         (ssh -O check ${SCC_HOST})"
        echo "  2. cluster reachable                 (ssh ${SCC_HOST} true)"
        echo "  3. data root exists on cluster       (test -d ${DATA_ROOT})"
        echo "  4. ROI file exists on cluster        (test -f ${ROI_FILE})"
        echo "  5. ROI file covers discovered runs   (only with --deep-inventory; skipped by default to keep the login node idle)"
        echo "  6. local Python has sci packages     (${PYTHON_BIN}: numpy/pandas/scipy/matplotlib)"
        echo "  7. local project root mounted        (${PROJECT_ROOT})"
        return 0
    fi

    # ---- 1) ControlMaster socket -------------------------------------------
    local master_ok=0
    if have_master; then
        pf_pass "ControlMaster socket live for '${SCC_HOST}'"
        master_ok=1
    else
        pf_fail "no ControlMaster socket for '${SCC_HOST}' -- run: ssh ${SCC_HOST} (approve Duo), then retry"
    fi

    # ---- 2-5) cluster-side checks (need the master) ------------------------
    if [ "${master_ok}" -eq 1 ]; then
        if ssh_scc "true" >/dev/null 2>&1; then
            pf_pass "cluster reachable over the multiplexed connection"
        else
            pf_fail "cluster not reachable even though a socket exists (stale socket? run: ssh ${SCC_HOST})"
        fi

        if ssh_scc "test -d '${DATA_ROOT}'" >/dev/null 2>&1; then
            pf_pass "data root exists on cluster: ${DATA_ROOT}"
        else
            pf_fail "data root missing on cluster: ${DATA_ROOT}"
        fi

        local roi_ok=0
        if ssh_scc "test -f '${ROI_FILE}'" >/dev/null 2>&1; then
            pf_pass "ROI file exists on cluster: ${ROI_FILE}"
            roi_ok=1
        else
            pf_fail "ROI file missing: ${ROI_FILE} -- draw ROIs first (run: run_pipeline.sh --stage rois)"
        fi

        # ---- 5) ROI coverage (best-effort MATLAB check) --------------------
        # UNVERIFIED against the cluster. Robustly degrades to WARN if the
        # remote MATLAB check cannot run; only a confirmed shortfall is a FAIL.
        if [ "${roi_ok}" -eq 1 ] && [ "${DEEP_INVENTORY}" -eq 0 ]; then
            # LOGIN-NODE COURTESY: verifying coverage means reading the ROI .mat
            # and walking the data tree, which needs MATLAB and a license token
            # on a login node. Skipped by default; the batch job validates ROIs
            # per run anyway and records any missing one as a failed run in the
            # manifest. Pass --deep-inventory to check up front.
            pf_warn "ROI coverage not verified (skipped to keep the login node idle; use --deep-inventory). The batch job validates ROIs per run."
        elif [ "${roi_ok}" -eq 1 ]; then
            local mstmt cov_out cov n
            mstmt="addpath('${REMOTE_CODE_DIR}'); r=find_runs('${DATA_ROOT}',struct('report',false,'verbose',false)); S=load('${ROI_FILE}'); if isfield(S,'rois'), k={S.rois.key}; else, k={}; end; c=0; for i=1:numel(r), if any(strcmp(k,r(i).camera_dir)), c=c+1; end; end; fprintf('ROI_COVERAGE %d %d\\n', c, numel(r));"
            if cov_out="$(ssh_scc "$(guard_nice_prefix)module load ${MATLAB_MODULE} 2>/dev/null; $(guard_nice_prefix)matlab -nodisplay -nosplash -singleCompThread -batch \"${mstmt}\"" 2>/dev/null)" \
                && echo "${cov_out}" | grep -q 'ROI_COVERAGE'; then
                cov="$(echo "${cov_out}" | sed -n 's/.*ROI_COVERAGE \([0-9]*\) \([0-9]*\).*/\1/p' | tail -1)"
                n="$(echo "${cov_out}"   | sed -n 's/.*ROI_COVERAGE \([0-9]*\) \([0-9]*\).*/\2/p' | tail -1)"
                if [ "${n:-0}" -gt 0 ] && [ "${cov:-0}" -eq "${n:-0}" ]; then
                    pf_pass "ROI file covers all ${n} discovered run(s)"
                elif [ "${n:-0}" -eq 0 ]; then
                    pf_warn "find_runs discovered 0 runs under ${DATA_ROOT} (check MIN_FRAMES / layout)"
                else
                    pf_fail "ROI coverage incomplete: ${cov}/${n} discovered runs have ROIs (draw the rest: --stage rois)"
                fi
            else
                pf_warn "could not verify ROI coverage remotely (MATLAB check unavailable); confirm manually"
            fi
        fi
    else
        pf_skip "cluster reachability      (blocked: no ControlMaster socket)"
        pf_skip "data root on cluster       (blocked: no ControlMaster socket)"
        pf_skip "ROI file on cluster        (blocked: no ControlMaster socket)"
        pf_skip "ROI coverage               (blocked: no ControlMaster socket)"
    fi

    # ---- 6) local Python packages ------------------------------------------
    if command -v "${PYTHON_BIN}" >/dev/null 2>&1; then
        if "${PYTHON_BIN}" -c "import numpy,pandas,scipy,matplotlib" >/dev/null 2>&1; then
            pf_pass "local Python (${PYTHON_BIN}) has numpy/pandas/scipy/matplotlib"
        else
            pf_fail "local Python (${PYTHON_BIN}) is missing numpy/pandas/scipy/matplotlib -- set PYTHON_BIN to a venv/interpreter that has them (e.g. PYTHON_BIN=python3.13)"
        fi
    else
        pf_fail "PYTHON_BIN not found on PATH: ${PYTHON_BIN}"
    fi

    # ---- 7) local project root mounted -------------------------------------
    if [ -d "${PROJECT_ROOT}" ]; then
        pf_pass "local project root present: ${PROJECT_ROOT}"
    elif [ -L "${PROJECT_ROOT}" ]; then
        pf_fail "project root is a dangling symlink (external volume not mounted?): ${PROJECT_ROOT}"
    else
        pf_fail "local project root missing: ${PROJECT_ROOT}"
    fi

    echo "  ----------------------------------------------------------"
    echo "  preflight: ${PF_FAIL} fail, ${PF_WARN} warn"
    if [ "${PF_FAIL}" -gt 0 ]; then
        err "preflight FAILED (${PF_FAIL} problem(s)); stopping before any work."
        return 1
    fi
    log "preflight OK"
    return 0
}

# =============================================================================
# STAGE: sync-code  (push this code to the cluster; sync_to_scc.sh --go)
# =============================================================================
stage_sync_code() {
    log "STAGE sync-code: pushing batch/ code to ${SCC_HOST}:${REMOTE_CODE_DIR}"
    if [ ! -x "${LOCAL_BATCH_DIR}/sync_to_scc.sh" ] && [ ! -f "${LOCAL_BATCH_DIR}/sync_to_scc.sh" ]; then
        err "sync_to_scc.sh not found in ${LOCAL_BATCH_DIR}"
        return 1
    fi
    # sync_to_scc.sh is dry-run by default; --go actually transfers. It does its
    # own ControlMaster guard and never deletes on the remote.
    run_cmd env SCC_HOST="${SCC_HOST}" REMOTE_DIR="${REMOTE_CODE_DIR}" LOCAL_DIR="${LOCAL_BATCH_DIR}" \
        bash "${LOCAL_BATCH_DIR}/sync_to_scc.sh" --go
}

# =============================================================================
# STAGE: inventory  (find_runs report mode on the cluster; validate the layout)
# =============================================================================
stage_inventory() {
    log "STAGE inventory: find_runs report mode on the cluster"
    if [ "${DRY_RUN}" -eq 0 ] && ! have_master; then
        print_no_master; return 1
    fi
    # LOGIN-NODE COURTESY: the default inventory is a plain `find` that counts
    # TIFFs per directory. It starts no MATLAB, consumes no license token, and
    # is wrapped in nice + timeout so it cannot load a shared login node. The
    # authoritative inventory happens inside the batch job anyway (that is what
    # run_behavior_batch calls find_runs for); this is operator information.
    local rcmd
    if [ "${DEEP_INVENTORY}" -eq 1 ]; then
        # Opt-in: the richer find_runs report (mouse/date/trigger association).
        # Still single-threaded and nice'd, but it DOES start MATLAB on a login
        # node and take a license, which is why it is not the default.
        local mstmt
        mstmt="addpath('${REMOTE_CODE_DIR}'); find_runs('${DATA_ROOT}', struct('report',true,'min_frames',${MIN_FRAMES}));"
        warn "inventory: --deep-inventory starts MATLAB on a LOGIN NODE (uses a license)."
        rcmd="$(guard_nice_prefix)module load ${MATLAB_MODULE} 2>/dev/null; $(guard_nice_prefix)matlab -nodisplay -nosplash -singleCompThread -batch \"${mstmt}\""
    else
        rcmd="$(guard_timeout_prefix)$(guard_nice_prefix)find '${DATA_ROOT}' -type f \( -iname '*.tif' -o -iname '*.tiff' \) -printf '%h\\n' 2>/dev/null | sort | uniq -c | sort -rn | awk -v m=${MIN_FRAMES} '\$1 >= m {printf \"%8d  %s\\n\", \$1, \$2}'"
        log "inventory: lightweight find (no MATLAB, no license). Use --deep-inventory for the full find_runs report."
    fi
    run_cmd ssh -o BatchMode=yes -o ConnectTimeout="${SSH_CONNECT_TIMEOUT}" "${SCC_HOST}" "${rcmd}"
}

# =============================================================================
# STAGE: rois  (INTERACTIVE -- guidance, never automated)
# Skips cleanly if the ROI file already covers the discovered runs.
# =============================================================================
stage_rois() {
    log "STAGE rois: ROI collection (interactive)"
    if [ "${DRY_RUN}" -eq 1 ]; then
        echo "DRY-RUN rois: would check ROI coverage; if incomplete, print interactive"
        echo "          guidance (SCC OnDemand / ssh -X) and STOP. This step is NEVER"
        echo "          automated -- collect_rois.m needs a display to draw ROIs."
        return 0
    fi

    # If the ROI file already covers every discovered run, there is nothing to do.
    if have_master && ssh_scc "test -f '${ROI_FILE}'" >/dev/null 2>&1; then
        local mstmt cov_out cov n
        mstmt="addpath('${REMOTE_CODE_DIR}'); r=find_runs('${DATA_ROOT}',struct('report',false,'verbose',false)); S=load('${ROI_FILE}'); if isfield(S,'rois'), k={S.rois.key}; else, k={}; end; c=0; for i=1:numel(r), if any(strcmp(k,r(i).camera_dir)), c=c+1; end; end; fprintf('ROI_COVERAGE %d %d\\n', c, numel(r));"
        if cov_out="$(ssh_scc "$(guard_nice_prefix)module load ${MATLAB_MODULE} 2>/dev/null; $(guard_nice_prefix)matlab -nodisplay -nosplash -singleCompThread -batch \"${mstmt}\"" 2>/dev/null)" \
            && echo "${cov_out}" | grep -q 'ROI_COVERAGE'; then
            cov="$(echo "${cov_out}" | sed -n 's/.*ROI_COVERAGE \([0-9]*\) \([0-9]*\).*/\1/p' | tail -1)"
            n="$(echo "${cov_out}"   | sed -n 's/.*ROI_COVERAGE \([0-9]*\) \([0-9]*\).*/\2/p' | tail -1)"
            if [ "${n:-0}" -gt 0 ] && [ "${cov:-0}" -eq "${n:-0}" ]; then
                log "ROIs already collected: ${cov}/${n} runs covered -- nothing to draw. Continuing."
                return 0
            fi
            warn "ROI coverage incomplete (${cov:-?}/${n:-?}). Interactive drawing required below."
        fi
    fi

    cat <<EOF

  ============================================================
  INTERACTIVE STEP -- cannot be automated (needs a display)
  ============================================================
  collect_rois.m draws the eye ellipse + two whisker rectangles per run and
  therefore needs a GUI. Run it on an SCC OnDemand desktop or over X-forwarding:

    1. Start an SCC OnDemand "Desktop" session (recommended), OR:  ssh -X ${SCC_HOST}
    2. Launch MATLAB WITH a display, then:

         addpath('${REMOTE_CODE_DIR}');
         runs = find_runs('${DATA_ROOT}', struct('min_frames', ${MIN_FRAMES}));
         collect_rois(runs, '${ROI_FILE}');

    3. For each run draw the 3 ROIs, adjust, press ENTER to accept. ROIs are
       saved after EACH run, so the session is resumable and re-running skips
       runs already recorded. To redo specific runs:
         collect_rois(runs, '${ROI_FILE}', struct('overwrite', {{'Run005'}}));

  TIP (avoids the "constant pupil trace" failure): draw the eye ellipse TIGHT.
  The pupil algorithm uses dark_percentile=40, so the pupil must fill ~40%+ of
  the ellipse. Too generous an ellipse -> a constant/degenerate pupil trace that
  QC will FAIL.

  When ROIs are complete, resume the pipeline:
     run_pipeline.sh --from submit
  ============================================================
EOF
    err "rois stage requires human interaction; stopping so you can draw ROIs, then resume with --from submit"
    return 1
}

# =============================================================================
# STAGE: submit  (qsub submit_behavior.qsub; capture the job id; idempotent)
# =============================================================================
stage_submit() {
    log "STAGE submit: qsub submit_behavior.qsub on the cluster"
    if [ "${DRY_RUN}" -eq 0 ] && ! have_master; then
        print_no_master; return 1
    fi

    # Idempotence: refuse to launch a duplicate job if one is already queued or
    # running (unless --force). qstat truncates the job name to 10 chars.
    if [ "${DRY_RUN}" -eq 0 ]; then
        local jobname10 existing
        jobname10="$(printf '%s' "${SGE_JOB_NAME}" | cut -c1-10)"
        existing="$(ssh_scc "qstat 2>/dev/null" | awk -v n="${jobname10}" 'NR>2 && $3==n {print $1}' || true)"
        if [ -n "${existing}" ]; then
            if [ "${FORCE}" -eq 1 ]; then
                warn "a '${SGE_JOB_NAME}' job (id ${existing}) is already active; --force: submitting anyway"
            else
                warn "a '${SGE_JOB_NAME}' job (id ${existing}) is already queued/running; not submitting a duplicate."
                echo "${existing}" | head -1 > "${JOB_ID_FILE}"
                log "recorded existing job id $(head -1 "${JOB_ID_FILE}") for the wait stage"
                return 0
            fi
        fi
    fi

    # Build the remote qsub command. Overrides are passed via `qsub -v VAR=...`;
    # every value is a config variable (no untrusted interpolation).
    local remote_cmd
    remote_cmd="cd '${REMOTE_CODE_DIR}' && mkdir -p logs && qsub \
-v DATA_ROOT='${DATA_ROOT}',OUT_DIR='${OUT_DIR}',ROI_FILE='${ROI_FILE}',MIN_FRAMES='${MIN_FRAMES}',OVERWRITE='${OVERWRITE}',WHISKER_BINNING='${WHISKER_BINNING}',CROP_TO_WINDOW='${CROP_TO_WINDOW}',PUPIL_POLARITY='${PUPIL_POLARITY}',CROP_START='${CROP_START}' \
submit_behavior.qsub"

    if [ "${DRY_RUN}" -eq 1 ]; then
        assert_remote_cmd_safe "${remote_cmd}"
        run_cmd ssh -o BatchMode=yes -o ConnectTimeout="${SSH_CONNECT_TIMEOUT}" "${SCC_HOST}" "${remote_cmd}"
        return 0
    fi

    local out jobid
    printf '+ ssh %q %q\n' "${SCC_HOST}" "${remote_cmd}"
    out="$(ssh_scc "${remote_cmd}")" || { err "qsub submission failed"; echo "${out}"; return 1; }
    echo "${out}"
    # Parse "Your job 123456 (...) has been submitted"
    jobid="$(printf '%s\n' "${out}" | sed -n 's/.*[Yy]our job \([0-9][0-9]*\).*/\1/p' | head -1)"
    if [ -z "${jobid}" ]; then
        err "could not parse a job id from qsub output above; wait stage will need --job-id"
        return 1
    fi
    echo "${jobid}" > "${JOB_ID_FILE}"
    log "submitted job id ${jobid} (recorded in ${JOB_ID_FILE})"
    return 0
}

# =============================================================================
# STAGE: wait  (poll qstat for the job; timeout; clear failure message)
# =============================================================================
stage_wait() {
    log "STAGE wait: polling qstat for the batch job"
    local jobid="${JOB_ID}"
    if [ -z "${jobid}" ] && [ -f "${JOB_ID_FILE}" ]; then
        jobid="$(head -1 "${JOB_ID_FILE}" 2>/dev/null || true)"
    fi

    if [ "${DRY_RUN}" -eq 1 ]; then
        echo "DRY-RUN wait: would poll every ${WAIT_POLL_S}s (timeout ${WAIT_TIMEOUT_S}s):"
        run_cmd ssh -o BatchMode=yes -o ConnectTimeout="${SSH_CONNECT_TIMEOUT}" "${SCC_HOST}" "qstat -j ${jobid:-<job_id>}"
        echo "         on completion it inspects the SGE log:"
        echo "           ${REMOTE_CODE_DIR}/logs/${SGE_JOB_NAME}.o${jobid:-<job_id>}"
        return 0
    fi

    if ! have_master; then print_no_master; return 1; fi
    if [ -z "${jobid}" ]; then
        err "no job id (no --job-id, JOB_ID, or ${JOB_ID_FILE}). Run the submit stage first, or pass --job-id."
        return 1
    fi

    local remote_log="${REMOTE_CODE_DIR}/logs/${SGE_JOB_NAME}.o${jobid}"
    log "waiting on job ${jobid} (poll ${WAIT_POLL_S}s, timeout ${WAIT_TIMEOUT_S}s); log: ${remote_log}"

    local elapsed=0 state line
    while [ "${elapsed}" -lt "${WAIT_TIMEOUT_S}" ]; do
        # qstat -j returns 0 while the job is known to the scheduler (queued or
        # running); nonzero once it has left the queue (finished or failed).
        if ! ssh_scc "qstat -j '${jobid}'" >/dev/null 2>&1; then
            log "job ${jobid} is no longer in the queue -- it has finished."
            break
        fi
        # Report the current state (qw=queued, r=running, Eqw=error, etc).
        line="$(ssh_scc "qstat 2>/dev/null" | awk -v j="${jobid}" 'NR>2 && $1==j {print}' || true)"
        state="$(printf '%s' "${line}" | awk '{print $5}')"
        log "  job ${jobid} state=${state:-?} (elapsed ${elapsed}s)"
        # An SGE error state (E in the state) will not clear on its own.
        if printf '%s' "${state}" | grep -q 'E'; then
            err "job ${jobid} is in an ERROR state (${state}). Inspect: ${remote_log}"
            err "and: ssh ${SCC_HOST} 'qstat -j ${jobid}'   /   qdel ${jobid} to cancel."
            return 1
        fi
        sleep "${WAIT_POLL_S}"
        elapsed=$((elapsed + WAIT_POLL_S))
    done

    if [ "${elapsed}" -ge "${WAIT_TIMEOUT_S}" ]; then
        err "timed out after ${WAIT_TIMEOUT_S}s waiting for job ${jobid}."
        err "It may still be running. Check: ssh ${SCC_HOST} 'qstat -j ${jobid}'  and the log ${remote_log}"
        return 1
    fi

    # Job left the queue: inspect the SGE log for the batch summary / failures.
    log "checking the SGE log tail for the batch summary ..."
    ssh_scc "tail -30 '${remote_log}' 2>/dev/null" || warn "could not read ${remote_log} (it may not exist yet)"
    # submit_behavior.qsub exits with the MATLAB status; a failed MATLAB stage
    # prints this marker. Treat its presence as a hard failure.
    if ssh_scc "grep -q 'MATLAB stage FAILED' '${remote_log}' 2>/dev/null"; then
        err "the MATLAB stage FAILED (see ${remote_log}). Not proceeding."
        return 1
    fi
    log "wait: job ${jobid} completed; see ${remote_log} for full detail."
    return 0
}

# =============================================================================
# STAGE: fetch  (pull results back via fetch_results.sh --go)
# =============================================================================
stage_fetch() {
    log "STAGE fetch: pulling results ${SCC_HOST}:${OUT_DIR} -> ${LOCAL_RESULTS_DIR}"
    local fetch_args=(--go)
    if [ "${WITH_TRIGGER_CSV}" -eq 1 ]; then
        fetch_args+=(--with-trigger-csv)
    else
        fetch_args+=(--no-trigger-csv)
    fi
    # fetch_results.sh does its own ControlMaster guard and never deletes.
    run_cmd env SCC_HOST="${SCC_HOST}" REMOTE_OUT_DIR="${OUT_DIR}" LOCAL_RESULTS_DIR="${LOCAL_RESULTS_DIR}" \
        bash "${LOCAL_BATCH_DIR}/fetch_results.sh" "${fetch_args[@]}"
}

# =============================================================================
# STAGE: qc  (validate_outputs.py -- its EXIT CODE gates publishing)
# Exit-code contract (from validate_outputs.py):
#   0 = all pass (or warns without --strict)  -> proceed
#   1 = >=1 FAIL (or WARN with --strict)       -> do NOT publish (gate)
#   2 = tool could not run (missing dir/manifest) -> abort
# =============================================================================
QC_RC=0
stage_qc() {
    log "STAGE qc: validate_outputs.py on ${LOCAL_RESULTS_DIR}"
    local qc_args=("${LOCAL_RESULTS_DIR}")
    [ "${QC_STRICT}" -eq 1 ] && qc_args+=(--strict)

    if [ "${DRY_RUN}" -eq 1 ]; then
        run_cmd "${PYTHON_BIN}" "${LOCAL_BATCH_DIR}/validate_outputs.py" "${qc_args[@]}"
        QC_RC=0
        return 0
    fi

    printf '+'; printf ' %q' "${PYTHON_BIN}" "${LOCAL_BATCH_DIR}/validate_outputs.py" "${qc_args[@]}"; printf '\n'
    set +e
    "${PYTHON_BIN}" "${LOCAL_BATCH_DIR}/validate_outputs.py" "${qc_args[@]}"
    QC_RC=$?
    set -e

    case "${QC_RC}" in
        0) log "qc: OVERALL PASS (exit 0). Publishing is allowed."; return 0 ;;
        1) err "qc: OVERALL FAIL (exit 1) -- at least one run failed QC$( [ "${QC_STRICT}" -eq 1 ] && echo ' (or WARN under --strict)' )."
           err "Publishing is BLOCKED. Inspect ${LOCAL_RESULTS_DIR}/qc_report.md"
           return 1 ;;
        2) err "qc: the QC tool could not run (exit 2) -- missing dir/manifest? Inspect ${LOCAL_RESULTS_DIR}"
           return 2 ;;
        *) err "qc: unexpected exit code ${QC_RC}"; return "${QC_RC}" ;;
    esac
}

# =============================================================================
# STAGE: plots  (behavior_panels.py --batch, local, from the fetched CSVs)
# Idempotent: figures are derived artifacts; regenerating simply overwrites them.
# =============================================================================
stage_plots() {
    log "STAGE plots: behavior_panels.py --batch (local)"
    run_cmd "${PYTHON_BIN}" "${LOCAL_BATCH_DIR}/behavior_panels.py" \
        --batch "${LOCAL_RESULTS_DIR}/csv" \
        --out "${LOCAL_RESULTS_DIR}/figures" \
        --crop-start "${CROP_START}"
}

# =============================================================================
# STAGE: publish  (publish_to_project.py -- DRY-RUN at tool level unless
# --publish-apply). Always gated by --require-qc so individual FAIL runs are
# refused even when the operator forced past the qc-stage gate.
# =============================================================================
stage_publish() {
    log "STAGE publish: publish_to_project.py -> ${PROJECT_ROOT}"
    local pub_args=(--batch-dir "${LOCAL_RESULTS_DIR}"
                    --project-root "${PROJECT_ROOT}"
                    --require-qc "${LOCAL_RESULTS_DIR}/qc_report.csv")
    if [ "${PUBLISH_APPLY}" -eq 1 ]; then
        pub_args+=(--apply)
        warn "publish: --publish-apply given -> writing into the project layout (QC-gated)."
    else
        log "publish: DRY-RUN at tool level (no files written). Pass --publish-apply to write."
    fi
    run_cmd "${PYTHON_BIN}" "${LOCAL_BATCH_DIR}/publish_to_project.py" "${pub_args[@]}"
}

# =============================================================================
# stage dispatch
# =============================================================================
run_stage() {
    local s="$1" fn rc
    fn="stage_${s//-/_}"
    if [ "${s}" = "qc" ]; then
        # qc manages its own exit code (QC_RC) but still returns it for gating.
        if stage_qc; then rc=0; else rc=$?; fi
    else
        if "${fn}"; then rc=0; else rc=$?; fi
    fi
    return "${rc}"
}

# Decide the ordered list of stages to run from --stage / --from / --to.
compute_plan() {
    local start=0 end=$(( ${#ALL_STAGES[@]} - 1 ))
    if [ -n "${SINGLE_STAGE}" ]; then
        if [ -n "${FROM_STAGE}" ] || [ -n "${TO_STAGE}" ]; then
            err "--stage cannot be combined with --from/--to"; exit 2
        fi
        validate_stage_name "${SINGLE_STAGE}"
        start="$(stage_index "${SINGLE_STAGE}")"; end="${start}"
    else
        if [ -n "${FROM_STAGE}" ]; then validate_stage_name "${FROM_STAGE}"; start="$(stage_index "${FROM_STAGE}")"; fi
        if [ -n "${TO_STAGE}" ];   then validate_stage_name "${TO_STAGE}";   end="$(stage_index "${TO_STAGE}")"; fi
    fi
    if [ "${start}" -gt "${end}" ]; then
        err "--from '${FROM_STAGE}' comes after --to '${TO_STAGE}'"; exit 2
    fi
    PLAN=()
    local i
    for (( i=start; i<=end; i++ )); do PLAN+=("${ALL_STAGES[$i]}"); done
}

# =============================================================================
# main
# =============================================================================
main() {
    compute_plan

    echo "=============================================================="
    echo "run_pipeline.sh"
    echo "  time        : $(date)"
    echo "  mode        : $([ "${DRY_RUN}" -eq 1 ] && echo 'DRY-RUN (no execution)' || echo 'EXECUTE')"
    echo "  stages      : ${PLAN[*]}"
    echo "  force       : $([ "${FORCE}" -eq 1 ] && echo yes || echo no)"
    echo "  publish     : $([ "${PUBLISH_APPLY}" -eq 1 ] && echo '--apply (writes, QC-gated)' || echo 'dry-run at tool level')"
    echo "  SCC_HOST    : ${SCC_HOST}"
    echo "  DATA_ROOT   : ${DATA_ROOT}"
    echo "  OUT_DIR     : ${OUT_DIR}"
    echo "  ROI_FILE    : ${ROI_FILE}"
    echo "  RESULTS_DIR : ${LOCAL_RESULTS_DIR}"
    echo "  PROJECT_ROOT: ${PROJECT_ROOT}"
    echo "  PYTHON_BIN  : ${PYTHON_BIN}"
    echo "  log file    : ${LOG_FILE}"
    echo "=============================================================="

    local s rc
    for s in "${PLAN[@]}"; do
        echo
        echo "--------------------------------------------------------------"
        if run_stage "${s}"; then
            rc=0
        else
            rc=$?
        fi

        if [ "${rc}" -ne 0 ]; then
            if [ "${FORCE}" -eq 1 ]; then
                banner "STAGE '${s}' FAILED (exit ${rc}) -- CONTINUING because --force was given." \
                       "This may publish or process incomplete/incorrect data. You asked for it."
                if [ "${s}" = "qc" ]; then
                    banner "QC did not pass but --force is set. publish_to_project.py --require-qc" \
                           "is still active and will refuse any individual run whose verdict is FAIL."
                fi
                continue
            fi
            err "aborting: stage '${s}' exited ${rc} (use --force to override; see ${LOG_FILE})"
            exit "${rc}"
        fi
    done

    echo
    log "pipeline finished: stages [${PLAN[*]}] completed. Log: ${LOG_FILE}"
}

main
