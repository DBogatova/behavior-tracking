#!/usr/bin/env bash
# =============================================================================
# stage_roi_frames.sh
#
# Stage ONE reference frame per run from the BU SCC cluster down to this local
# machine, so ROI drawing (collect_rois.m, PASS 1) can happen LOCALLY in a fast
# native MATLAB window instead of over slow X-forwarding / SCC OnDemand.
#
# WHY THIS EXISTS
#   The per-run Basler TIFF stacks (~1330-2030 frames, 960x600 8-bit, ~1.1 GB
#   per run) live on the cluster. But collect_rois.m only ever looks at ONE
#   frame per run -- the MIDDLE frame. So there is no reason to drag whole run
#   folders across the network to draw three ROIs: we stage just that single
#   ~0.6 MB frame per run, the human draws ROIs locally, and the tiny ROI file
#   is uploaded for the headless cluster batch job (submit_behavior.qsub).
#
# THE LOAD-BEARING MANIFEST
#   The ROI file is PRODUCED locally but CONSUMED on the cluster. run_behavior_
#   batch.m's lookup_roi matches ROI entries to runs by the CLUSTER camera_dir
#   first. So each ROI entry must be keyed by the CLUSTER camera_dir even though
#   the frame was read from a local staging path. This script therefore writes a
#   manifest CSV that carries, per run, the CLUSTER camera_dir alongside the
#   LOCAL frame path. local_roi_runs.m reads that manifest and hands both to
#   collect_rois.m (local camera_dir for the GUI to read the frame; cluster
#   camera_dir as the ROI key). Get this wrong and every run fails on the
#   cluster with "no ROI recorded". The manifest is the bridge -- treat it as
#   load-bearing.
#
# SAFETY MODEL (identical philosophy to fetch_results.sh)
#   * SOURCES scc_guard.sh and calls guard_require FIRST (fail-closed): if the
#     guard file is missing/empty/corrupt, refuse before touching the cluster.
#   * CONFINEMENT: every cluster path is validated with assert_remote_path_
#     allowed, so a mistyped override can never read outside your own dirs.
#   * NON-DESTRUCTION: rsync never gets --delete (asserted); the remote
#     enumeration command is screened with assert_remote_cmd_safe; and we only
#     ever rsync SINGLE files, never whole run folders.
#   * LOGIN-NODE COURTESY: run discovery is a nice'd, timeout-bounded remote
#     `find` -- it starts NO MATLAB and consumes NO MATLAB licence token.
#   * FAILS FAST, NEVER HANGS: refuses up front if there is no live
#     ControlMaster socket, and uses ssh BatchMode so it can never block on Duo.
#   * DRY-RUN BY DEFAULT: with no flags it shows what WOULD be staged and
#     changes nothing. Pass --go to actually transfer and write the manifest.
#
# USAGE
#   ./stage_roi_frames.sh                 # dry run (default): shows what would stage
#   ./stage_roi_frames.sh --go            # stage the frames + write the manifest
#   ./stage_roi_frames.sh -h              # help
#
# OVERRIDES (environment variables; every default is documented inline)
#   SCC_HOST             ssh alias/host                  (default: scc)
#   DATA_ROOT            cluster data root to enumerate  (default:
#                          /projectnb/devorlab/daria/Femtonics/behavior)
#   STAGE_DIR            local staging tree destination  (default:
#                          <scriptdir>/roi_stage)
#   MIN_FRAMES           min TIFFs for a dir to count as a run (default: 100)
#   SSH_CONNECT_TIMEOUT  ssh ConnectTimeout seconds       (default: 10)
#   SCC_ALLOWED_ROOTS    guard allowlist (see scc_guard.sh)
#   SCC_REMOTE_WALK_TIMEOUT  remote-find timeout seconds (see scc_guard.sh)
# =============================================================================

set -euo pipefail

# ---- configuration (env-overridable; defaults documented inline) ------------
# ssh alias in ~/.ssh/config (User daria, HostName scc1.bu.edu, ControlMaster
# multiplexing + ControlPersist already configured there).
SCC_HOST="${SCC_HOST:-scc}"
# Cluster data root scanned for per-run TIFF folders. Matches run_pipeline.sh.
DATA_ROOT="${DATA_ROOT:-/projectnb/devorlab/daria/Femtonics/behavior}"
# Where the single staged frames land locally, in a run-identity-preserving tree
# <STAGE_DIR>/<date>/<mouse>/<Run###>/<original_frame_name>.
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
STAGE_DIR="${STAGE_DIR:-${_SCRIPT_DIR}/roi_stage}"
# Min TIFFs for a directory to count as a run (mirrors find_runs' heuristic).
MIN_FRAMES="${MIN_FRAMES:-100}"
# ssh connect timeout so a dead socket fails in seconds, never hangs.
SSH_CONNECT_TIMEOUT="${SSH_CONNECT_TIMEOUT:-10}"
# Name of the manifest CSV written into STAGE_DIR. local_roi_runs.m reads this.
MANIFEST_NAME="stage_manifest.csv"

# ---- SAFETY GUARDS (validated FIRST, before any connection attempt) --------
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

# Confine + validate cluster paths and interpolated tokens BEFORE anything else,
# so an out-of-allowlist DATA_ROOT aborts (exit 3) even without a live socket.
DATA_ROOT="$(assert_remote_path_allowed "${DATA_ROOT}" "DATA_ROOT (cluster data, read-only)")"
MIN_FRAMES="$(assert_safe_token "${MIN_FRAMES}" "MIN_FRAMES" int)"
SCC_HOST="$(assert_safe_token "${SCC_HOST}" "SCC_HOST" word)"

# ---- defaults for parsed flags ----------------------------------------------
DRY_RUN=1              # 1 = dry-run (default), 0 = transfer (--go)

usage() {
    # Print the header comment block as help (lines 2..60, stripping "# ").
    sed -n '2,60p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# ---- parse arguments --------------------------------------------------------
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
# `ssh -O check` only probes the LOCAL control socket; it never opens a new
# connection, so it cannot trigger Duo and cannot hang. BatchMode + a short
# ConnectTimeout make that guarantee explicit. No master -> exit non-zero and
# refuse cleanly (never fall through to an interactive prompt). This happens
# BEFORE we create anything locally, so a refusal leaves the filesystem
# untouched.
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

# ---- discover runs + their MIDDLE frame remotely (NO MATLAB, NO licence) ----
# LOGIN-NODE COURTESY: this is a plain `find` wrapped in nice + timeout (via the
# guard prefixes). It starts no MATLAB and takes no licence token.
#
# HOW THE MIDDLE FRAME IS PICKED (deterministic, and matches collect_rois.m):
#   find emits "<dir>\t<filename>\t<bytes>" for every TIFF, then `sort` orders
#   the stream. Because the Basler frame names carry a ZERO-PADDED index at the
#   END (e.g. ..._0989.tiff) with an otherwise constant/monotonic prefix, plain
#   lexicographic sort == natural numeric order == capture order, which is
#   exactly what collect_rois.m's natsortfiles-based middle_frame() produces.
#   awk then, per directory, counts N frames and selects the frame at 1-based
#   index floor(N/2) (clamped to >= 1) -- byte-for-byte the same rule as
#   collect_rois.m: frame_idx = max(1, floor(numel(frames)/2)). Only dirs with
#   >= MIN_FRAMES TIFFs directly inside qualify as runs (find_runs' heuristic).
TAB="$(printf '\t')"
WALK_CMD="$(guard_timeout_prefix)$(guard_nice_prefix)find '${DATA_ROOT}' -type f \( -iname '*.tif' -o -iname '*.tiff' \) -printf '%h\t%f\t%s\n' 2>/dev/null | sort | awk -F'\t' -v m=${MIN_FRAMES} '{c[\$1]++; k=c[\$1]; nm[\$1 SUBSEP k]=\$2; sz[\$1 SUBSEP k]=\$3} END {for (d in c){t=c[d]; if(t<m) continue; i=int(t/2); if(i<1) i=1; printf \"%s\t%s\t%s\t%s\n\", t, nm[d SUBSEP i], sz[d SUBSEP i], d}}'"

# Screen the remote command for destructive verbs / clobbering redirects before
# it leaves this machine. This enumeration is strictly read-only on the cluster.
assert_remote_cmd_safe "${WALK_CMD}"

echo "=============================================================="
echo "stage_roi_frames.sh"
echo "  mode          : $([ "${DRY_RUN}" -eq 1 ] && echo 'DRY RUN (no changes; pass --go to stage)' || echo 'STAGE (--go)')"
echo "  from (remote) : ${SCC_HOST}:${DATA_ROOT}"
echo "  to   (local)  : ${STAGE_DIR}"
echo "  min frames    : ${MIN_FRAMES}"
echo "  delete        : NO (never; --delete is intentionally not used)"
echo "  confined      : ${SCC_ALLOWED_ROOTS}"
echo "=============================================================="
guard_summary
echo "--------------------------------------------------------------"
echo "discovering runs + middle frames on the cluster (find only; no MATLAB)..."

ENUM_OUT="$(ssh -o BatchMode=yes -o ConnectTimeout="${SSH_CONNECT_TIMEOUT}" "${SCC_HOST}" "${WALK_CMD}")"

if [ -z "${ENUM_OUT//[[:space:]]/}" ]; then
    echo "No runs found under ${DATA_ROOT} (>= ${MIN_FRAMES} TIFF frames)."
    echo "Nothing to stage."
    exit 0
fi

# ---- rsync scaffolding (single files only; never --delete) ------------------
RSYNC_SSH="ssh -o BatchMode=yes -o ConnectTimeout=${SSH_CONNECT_TIMEOUT}"
MANIFEST_PATH="${STAGE_DIR%/}/${MANIFEST_NAME}"

# In TRANSFER mode, create the staging root and start the manifest with a header
# row. The manifest is written incrementally (one row per successfully-staged
# run) so an interrupted transfer still yields a usable, consistent manifest.
if [ "${DRY_RUN}" -eq 0 ]; then
    mkdir -p "${STAGE_DIR}"
    # Manifest schema (LOAD-BEARING -- carries the cluster camera_dir to the
    # local ROI step; see the header block above):
    printf '%s\n' "date,mouse,run_id,cluster_camera_dir,cluster_frame_path,local_frame_path,n_frames" > "${MANIFEST_PATH}"
fi

# ---- iterate discovered runs (current shell; process substitution) ----------
n_runs=0
total_bytes=0
# Sort the enumeration by cluster camera_dir (field 4) for a stable manifest.
while IFS="${TAB}" read -r n_frames frame_name frame_size camera_dir; do
    [ -n "${camera_dir}" ] || continue

    # Confine every discovered cluster path (defence in depth: the root was
    # validated, but each child dir and the frame path are re-checked; this also
    # rejects any frame name carrying shell metacharacters).
    camera_dir="$(assert_remote_path_allowed "${camera_dir}" "discovered camera_dir")"
    cluster_frame_path="$(assert_remote_path_allowed "${camera_dir}/${frame_name}" "discovered frame path")"

    # Derive date / mouse / run_id from the path, anchored on 'camera' like
    # find_runs; degrade gracefully to the last three components otherwise.
    run_id="$(basename "${camera_dir}")"
    parent="$(dirname "${camera_dir}")"
    if [ "$(basename "${parent}")" = "camera" ]; then
        mouse="$(basename "$(dirname "${parent}")")"
        date_str="$(basename "$(dirname "$(dirname "${parent}")")")"
    else
        mouse="$(basename "${parent}")"
        date_str="$(basename "$(dirname "${parent}")")"
    fi

    local_run_dir="${STAGE_DIR%/}/${date_str}/${mouse}/${run_id}"
    local_frame_path="${local_run_dir}/${frame_name}"

    n_runs=$((n_runs + 1))
    total_bytes=$((total_bytes + frame_size))

    printf '  [%02d] %-10s %-18s %-8s frames=%-5s middle=%s\n' \
        "${n_runs}" "${date_str}" "${mouse}" "${run_id}" "${n_frames}" "${frame_name}"

    if [ "${DRY_RUN}" -eq 0 ]; then
        mkdir -p "${local_run_dir}"
        # Only the single middle frame is transferred -- NEVER the whole run
        # folder. No --delete anywhere. Reuse the multiplexed master via -e.
        RSYNC_ARGS=(-a -h --itemize-changes)
        assert_rsync_nondestructive "${RSYNC_ARGS[@]}"
        rsync "${RSYNC_ARGS[@]}" -e "${RSYNC_SSH}" \
            "${SCC_HOST}:${cluster_frame_path}" "${local_frame_path}"
        # Append the manifest row AFTER the frame is on disk.
        printf '%s,%s,%s,%s,%s,%s,%s\n' \
            "${date_str}" "${mouse}" "${run_id}" \
            "${camera_dir}" "${cluster_frame_path}" "${local_frame_path}" "${n_frames}" \
            >> "${MANIFEST_PATH}"
    else
        printf '       would rsync %s\n              -> %s\n' \
            "${SCC_HOST}:${cluster_frame_path}" "${local_frame_path}"
    fi
done < <(printf '%s\n' "${ENUM_OUT}" | sort -t"${TAB}" -k4,4)

# ---- summary ----------------------------------------------------------------
# Human-readable byte total (MiB) without depending on bc.
mib="$(awk -v b="${total_bytes}" 'BEGIN{printf "%.2f", b/1048576}')"
echo "--------------------------------------------------------------"
echo "runs found        : ${n_runs}"
echo "bytes to transfer : ${total_bytes} (${mib} MiB)  [one middle frame per run]"
if [ "${DRY_RUN}" -eq 1 ]; then
    echo "mode              : DRY RUN -- nothing was staged and no manifest was written."
    echo "Re-run with --go to stage the frames and write ${MANIFEST_NAME}."
else
    echo "mode              : STAGED"
    echo "manifest          : ${MANIFEST_PATH}"
    echo
    echo "Next: draw ROIs locally, then upload the ROI file for the cluster job:"
    echo "  matlab>  runs = local_roi_runs('${STAGE_DIR}');"
    echo "  matlab>  collect_rois(runs, '${STAGE_DIR%/}/rois.mat');"
fi
echo "=============================================================="
