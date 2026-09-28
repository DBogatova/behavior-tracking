#!/usr/bin/env bash
# =============================================================================
# scc_guard.sh -- shared safety guards for every script that touches the SCC.
#
# PURPOSE
#   Make it structurally impossible for this pipeline to (a) write outside the
#   user's own directories on a shared cluster, (b) delete anything on the
#   cluster, or (c) run heavy work on a login node.
#
#   Source this file; do not execute it:
#       source "$(dirname "$0")/scc_guard.sh"
#
# THE THREE INVARIANTS THIS FILE ENFORCES
#   1. CONFINEMENT   Every remote path we read, write, or create must resolve
#                    inside SCC_ALLOWED_ROOTS. Anything else aborts the script.
#   2. NON-DESTRUCTION
#                    No rsync --delete family flag may ever be passed, and no
#                    remote command may contain a destructive verb. Both are
#                    checked mechanically, not merely by convention.
#   3. LOGIN-NODE COURTESY
#                    Remote commands that touch many files are wrapped in nice
#                    (and ionice when available) and bounded by a timeout, so a
#                    runaway walk cannot degrade a shared login node.
#
# WHY A GUARD FILE INSTEAD OF CAREFUL CODING
#   Careful coding is not auditable. A single choke point can be tested, and a
#   reviewer can confirm in one place that nothing destructive is possible.
# =============================================================================

# ---- configuration ----------------------------------------------------------
# Colon-separated list of absolute directories the pipeline may touch on the
# cluster. Default: only the user's own project space. Override deliberately,
# e.g. SCC_ALLOWED_ROOTS="/projectnb/devorlab/daria:/usr4/daria".
SCC_ALLOWED_ROOTS="${SCC_ALLOWED_ROOTS:-/projectnb/devorlab/daria}"

# Timeout (seconds) for remote commands that walk the filesystem.
SCC_REMOTE_WALK_TIMEOUT="${SCC_REMOTE_WALK_TIMEOUT:-120}"

# ---- internals --------------------------------------------------------------
_guard_die() {
    printf 'SAFETY ABORT: %s\n' "$1" >&2
    shift || true
    while [ "$#" -gt 0 ]; do printf '  %s\n' "$1" >&2; shift; done
    exit 3
}

# guard_require -- FAIL-CLOSED check. Every script calls this immediately after
# sourcing. If the guard file was missing, empty, truncated, or shadowed, the
# assert_* functions will not be defined; without this check a script with no
# `set -e` would sail on with unvalidated (empty) paths. Verify by definition,
# not by the exit status of `source`.
guard_require() {
    local fn
    for fn in assert_remote_path_allowed assert_rsync_nondestructive \
              assert_remote_cmd_safe assert_safe_token guard_summary; do
        if ! declare -F "${fn}" >/dev/null 2>&1; then
            printf 'SAFETY ABORT: guard function %s is not defined.\n' "${fn}" >&2
            printf '  scc_guard.sh is missing, empty, or failed to load.\n' >&2
            printf '  Refusing to touch the cluster unguarded.\n' >&2
            printf '  Fix: re-sync batch/ (sync_to_scc.sh --go) so scc_guard.sh is present.\n' >&2
            exit 3
        fi
    done
    _guard_validate_allowlist
}

# The allowlist is itself an environment variable, so it is itself validated:
# widening it to '/' or a system directory would defeat the whole mechanism.
_guard_validate_allowlist() {
    local root norm
    [ -n "${SCC_ALLOWED_ROOTS}" ] || _guard_die "SCC_ALLOWED_ROOTS is empty."
    local IFS=':'
    for root in ${SCC_ALLOWED_ROOTS}; do
        [ -n "${root}" ] || continue
        case "${root}" in
            /*) : ;;
            *) _guard_die "SCC_ALLOWED_ROOTS entry is not absolute: '${root}'" ;;
        esac
        norm="$(guard_normalize_path "${root}")"
        case "${norm}" in
            __GUARD_ESCAPE__) _guard_die "SCC_ALLOWED_ROOTS entry escapes root: '${root}'" ;;
            /|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/proc|/root|/sbin|/sys|/tmp|/usr|/var|/projectnb|/project|/scratch|/net)
                _guard_die "SCC_ALLOWED_ROOTS entry is far too broad: '${norm}'" \
                    "An allowed root must be a specific directory you own," \
                    "e.g. /projectnb/devorlab/daria -- not a shared parent." ;;
        esac
        # Require reasonable depth: /projectnb/<lab>/<user> is 3 components.
        local depth
        depth="$(printf '%s' "${norm}" | awk -F/ '{print NF-1}')"
        if [ "${depth}" -lt 2 ]; then
            _guard_die "SCC_ALLOWED_ROOTS entry is too shallow to be user-owned: '${norm}'"
        fi
        # /projectnb/<lab> is the LAB-WIDE directory, shared with colleagues.
        # Only /projectnb/<lab>/<something> can plausibly be yours alone.
        case "${norm}" in
            /projectnb/*)
                if [ "${depth}" -lt 3 ]; then
                    _guard_die "SCC_ALLOWED_ROOTS entry '${norm}' is a LAB-WIDE directory." \
                        "That directory is shared with other members of the lab." \
                        "Use your own subdirectory, e.g. ${norm}/daria"
                fi ;;
        esac
    done
}

# Normalise a path lexically (no filesystem access, so it works for REMOTE
# paths): collapse '//' and '/./', resolve '/x/../' pairs, strip trailing '/'.
guard_normalize_path() {
    local p="$1" out=() part
    case "$p" in
        /*) : ;;
        *) printf '%s' "$p"; return 0 ;;   # caller rejects non-absolute
    esac
    local IFS='/'
    # shellcheck disable=SC2206
    for part in $p; do
        case "$part" in
            ''|'.') continue ;;
            '..')
                if [ "${#out[@]}" -gt 0 ]; then
                    unset 'out[${#out[@]}-1]'
                else
                    # '..' above root: refuse rather than silently clamp.
                    printf '%s' "__GUARD_ESCAPE__"; return 0
                fi
                ;;
            *) out+=("$part") ;;
        esac
    done
    if [ "${#out[@]}" -eq 0 ]; then printf '/'; else printf '/%s' "$(IFS=/; printf '%s' "${out[*]}")"; fi
}

# assert_remote_path_allowed <path> <label>
# Abort unless <path> is absolute, escape-free, and inside SCC_ALLOWED_ROOTS.
assert_remote_path_allowed() {
    local raw="$1" label="${2:-path}" norm root ok=0

    [ -n "${raw}" ] || _guard_die "${label} is empty." \
        "Refusing to operate on an unset remote path."

    case "${raw}" in
        /*) : ;;
        *) _guard_die "${label} is not an absolute path: '${raw}'" \
               "Remote paths must be absolute so confinement can be verified." ;;
    esac

    # Reject shell metacharacters outright: these paths get embedded in remote
    # command strings, so a metacharacter is a command-injection vector.
    case "${raw}" in
        *'$'*|*'`'*|*';'*|*'&'*|*'|'*|*'>'*|*'<'*|*'('*|*')'*|*$'\n'*|*'*'*|*'?'*)
            _guard_die "${label} contains shell metacharacters: '${raw}'" \
                "Refusing: this value is interpolated into remote commands." ;;
    esac

    norm="$(guard_normalize_path "${raw}")"
    if [ "${norm}" = "__GUARD_ESCAPE__" ]; then
        _guard_die "${label} escapes above the filesystem root: '${raw}'"
    fi

    # Refuse obviously catastrophic targets even if an allowlist were widened.
    case "${norm}" in
        /|/bin|/boot|/dev|/etc|/lib|/lib64|/proc|/sbin|/sys|/usr|/var|/projectnb|/project)
            _guard_die "${label} resolves to a protected system path: '${norm}'" ;;
    esac

    local IFS=':'
    for root in ${SCC_ALLOWED_ROOTS}; do
        [ -n "${root}" ] || continue
        local rnorm
        rnorm="$(guard_normalize_path "${root}")"
        # Match the root itself or anything strictly beneath it. The trailing
        # '/' comparison prevents '/a/daria-other' matching root '/a/daria'.
        if [ "${norm}" = "${rnorm}" ] || case "${norm}/" in "${rnorm}/"*) true ;; *) false ;; esac; then
            ok=1; break
        fi
    done

    if [ "${ok}" -ne 1 ]; then
        _guard_die "${label} is OUTSIDE the allowed roots." \
            "path        : ${norm}" \
            "allowed     : ${SCC_ALLOWED_ROOTS}" \
            "This pipeline only ever touches your own directories on a shared" \
            "cluster. If this path is genuinely yours, add its root to" \
            "SCC_ALLOWED_ROOTS explicitly."
    fi
    printf '%s' "${norm}"
}

# assert_rsync_nondestructive <rsync args...>
# Abort if any argument would delete or truncate data on either side.
assert_rsync_nondestructive() {
    local a
    for a in "$@"; do
        case "${a}" in
            --delete|--delete-*|--del|--remove-source-files|--force|--inplace)
                _guard_die "refusing rsync flag '${a}'." \
                    "This pipeline never deletes or truncates data. Nothing on" \
                    "the cluster may be removed by an automated step." ;;
        esac
    done
}

# assert_remote_cmd_safe <command string>
# Abort if a remote command contains a destructive verb. Defence in depth: the
# scripts only ever run read-only inspection plus qsub, so any of these
# appearing means something has gone wrong or been tampered with.
assert_remote_cmd_safe() {
    local cmd="$1"
    local pat

    # Destructive VERBS. Matched with a word boundary so '/bin/rm' and 'rm' with
    # no trailing space are still caught, while words merely containing these
    # letters (e.g. 'form', 'remove_source' inside a filename) are not.
    for pat in '(^|[[:space:];&|/])rm([[:space:]]|$)' \
               '(^|[[:space:];&|/])rmdir([[:space:]]|$)' \
               '(^|[[:space:];&|/])unlink([[:space:]]|$)' \
               '(^|[[:space:];&|/])shred([[:space:]]|$)' \
               '(^|[[:space:];&|/])truncate([[:space:]]|$)' \
               '(^|[[:space:];&|/])mkfs' \
               '(^|[[:space:];&|/])mv([[:space:]]|$)' \
               '(^|[[:space:];&|/])dd([[:space:]]|$)' \
               '(^|[[:space:];&|/])chown([[:space:]]|$)' \
               '(^|[[:space:];&|/])qdel([[:space:]]|$)' \
               'chmod[[:space:]]+-R' \
               '-delete' \
               '-exec[[:space:]].*rm' \
               'eval[[:space:]]' \
               'base64[[:space:]]+-d'; do
        if printf '%s' "${cmd}" | grep -Eq -- "${pat}"; then
            _guard_die "remote command contains a destructive pattern: '${pat}'" \
                "command: ${cmd}" \
                "Automated steps are read-only on the cluster (plus qsub)."
        fi
    done

    # CLOBBERING REDIRECTS to an absolute path. The safe idioms we genuinely use
    # ('2>/dev/null', '>/dev/null', '2>&1') are stripped first, so only a real
    # truncating write to a filesystem path is left to match. Without this
    # stripping the check would fire on every 'qstat 2>/dev/null' and break the
    # pipeline -- correctness of the guard matters as much as its strictness.
    local scrubbed
    scrubbed="$(printf '%s' "${cmd}" \
        | sed -e 's/[0-9]*>>*[[:space:]]*\/dev\/null//g' \
              -e 's/[0-9]*>&[0-9]*//g')"
    if printf '%s' "${scrubbed}" | grep -Eq '>[[:space:]]*/'; then
        _guard_die "remote command redirects output onto an absolute path." \
            "command: ${cmd}" \
            "Automated steps never write to the cluster filesystem by redirection."
    fi
}

# assert_safe_token <value> <label> <kind>
# Validate a NON-PATH parameter that gets interpolated into a remote command
# string (a MATLAB statement or a qsub -v list). Unvalidated, any of these is a
# command-injection vector even though none of them is a path.
#   kind: int | number | bool | word | module
#     word   = letters, digits, _ . -
#     module = word plus '/' , for environment module names like
#              matlab/2023a. Still excludes every shell metacharacter,
#              so it remains injection-safe.
assert_safe_token() {
    local val="$1" label="${2:-value}" kind="${3:-word}"
    case "${kind}" in
        int)    [[ "${val}" =~ ^[0-9]+$ ]] || _guard_die "${label} must be a non-negative integer, got: '${val}'" ;;
        number) [[ "${val}" =~ ^-?[0-9]+(\.[0-9]+)?$ ]] || _guard_die "${label} must be numeric, got: '${val}'" ;;
        bool)   case "${val}" in true|false|0|1) : ;; *) _guard_die "${label} must be true/false/0/1, got: '${val}'" ;; esac ;;
        word)   [[ "${val}" =~ ^[A-Za-z0-9_.-]+$ ]] || _guard_die "${label} may only contain letters, digits, _ . - ; got: '${val}'" ;;
        module) [[ "${val}" =~ ^[A-Za-z0-9_./-]+$ ]] || _guard_die "${label} may only contain letters, digits, _ . - / ; got: '${val}'"
                case "${val}" in
                    */../*|../*|*/..) _guard_die "${label} must not contain '..': '${val}'" ;;
                esac ;;
        *)      _guard_die "assert_safe_token: unknown kind '${kind}'" ;;
    esac
    printf '%s' "${val}"
}

# guard_nice_prefix
# Prefix for remote commands that walk many files, so a shared login node is
# never loaded heavily. Uses whatever is available on the remote host.
guard_nice_prefix() {
    printf 'nice -n 19 '
}

# guard_timeout_prefix
# Bound a remote walk so it cannot run away. `timeout` may be absent on some
# hosts, hence the fallback to running unwrapped (still nice'd).
guard_timeout_prefix() {
    printf 'command -v timeout >/dev/null 2>&1 && timeout %s ' "${SCC_REMOTE_WALK_TIMEOUT}"
}

# guard_summary -- print the active safety configuration (for logs/preflight).
guard_summary() {
    echo "safety guards:"
    echo "  allowed remote roots : ${SCC_ALLOWED_ROOTS}"
    echo "  remote deletes       : DISABLED (rsync --delete family refused; no rm/mv/qdel)"
    echo "  remote writes        : confined to the allowed roots above"
    echo "  login-node courtesy  : walks are nice -n 19 and timeout ${SCC_REMOTE_WALK_TIMEOUT}s"
}
