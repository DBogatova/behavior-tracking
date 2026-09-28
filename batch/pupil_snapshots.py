#!/usr/bin/env python3
"""pupil_snapshots.py -- visual-QC montages for the 2P pupil pipeline.

WHY THIS TOOL EXISTS
--------------------
The pupil is measured from the two-photon laser's retro-reflection: the pupil
images as a BRIGHT, usually clipped disc, and ``pupil_trace.m`` (bright mode)
records the area of the largest bright blob inside a hand-drawn eye ellipse.
Two failure modes are invisible to summary statistics but obvious in a single
frame:

  1. A SHARP RISE may be genuine dilation OR the bright blob merging with the
     adjacent saturated background (the frames are heavily overexposed).
  2. A LONG FLAT-SMALL stretch may be genuine constriction (the experimenter
     deliberately pre-constricts the pupil) OR lost detection.
  Sharp DROPS are usually blinks.

For each run this tool finds those interesting features in the published pupil
trace, pulls the corresponding source frames from the SCC cluster (guarded), and
renders a montage: the trace with event markers above cropped, nearest-neighbour
upscaled snapshots of the eye, each overlaid with the hand-drawn ellipse and the
pipeline's detected bright blob, so a human can adjudicate physiology vs artefact.

It also writes a machine-readable events CSV so the QC is auditable, not just
pretty.

BLOB OVERLAY FIDELITY
---------------------
The blob overlay mirrors ``pupil_trace.m`` bright mode EXACTLY so the picture
shows what the pipeline actually measured (see ``detect_blob``). Otsu is
reimplemented to match MATLAB ``graythresh`` (fixed 256-bin imhist over 0..255,
threshold = level*255); scikit-image is present in this environment but its
histogram binning differs subtly from MATLAB's, and exact fidelity to the
pipeline matters more here than reusing a library. Connectivity uses
``scipy.ndimage.label`` with 8-connectivity to match MATLAB ``bwconncomp``.

CLUSTER SAFETY
--------------
Frame fetching re-implements the SAME safety checks as ``scc_guard.sh`` in
Python (clearly marked below): remote paths must resolve inside
``SCC_ALLOWED_ROOTS`` (default /projectnb/devorlab/daria), no rsync --delete
family flag is ever passed, and fetching refuses fast (never hangs) unless a
live ssh ControlMaster socket exists. Local rsync is openrsync, which lacks
--info=stats and may exit 23 on a benign fchmodat warning while transferring
correctly, so exit codes 0 and 23 are treated as success and the arrival of
each expected file is verified explicitly.
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from pathlib import Path

import numpy as np
import pandas as pd
import scipy.io as sio
from scipy import ndimage

import matplotlib
matplotlib.use("Agg")  # headless; never call plt.show()
import matplotlib.pyplot as plt  # noqa: E402
from matplotlib.gridspec import GridSpec, GridSpecFromSubplotSpec  # noqa: E402

# Arial-ish font stack; embed real fonts in the PDF (Type 42 / TrueType).
matplotlib.rcParams["pdf.fonttype"] = 42
matplotlib.rcParams["ps.fonttype"] = 42
matplotlib.rcParams["font.family"] = "sans-serif"
matplotlib.rcParams["font.sans-serif"] = [
    "Arial", "Helvetica", "Liberation Sans", "DejaVu Sans", "sans-serif",
]

# --------------------------------------------------------------------------- #
# Defaults / constants
# --------------------------------------------------------------------------- #
DEFAULT_PROJECT_ROOT = "/Users/daria/Desktop/femtonics-data"
DEFAULT_BATCH_DIR = "/Users/daria/Desktop/behavior-tracking-daria/batch"

# Pipeline bright-mode parameters (must match pupil_trace.m defaults).
SAT_LEVEL = 250          # opts.sat_level
MIN_AREA_BRIGHT = 2      # opts.min_area for bright polarity
MIN_CONTRAST = 20        # opts.min_contrast (bright-mode Otsu guard)

# ssh host alias used by the cluster tooling (see scc_guard.sh users).
SCC_HOST = os.environ.get("SCC_HOST", "scc")

EVENT_TYPES = ["rise", "drop", "flat_small", "flat_high"]

# Colours for overlays.
COL_ELLIPSE = "#00e5ff"   # hand-drawn eye ellipse
COL_BLOB = "#ff3b30"      # pipeline-detected bright blob


class GuardError(RuntimeError):
    """Raised when a cluster safety guard refuses an operation."""


# =========================================================================== #
# SAFETY GUARDS -- these MIRROR batch/scc_guard.sh in Python.
# Any change here should be kept in sync with that file. They are re-implemented
# (rather than shelled out) so the fetch path has no bash dependency, but the
# semantics are identical: lexical path normalisation, confinement to
# SCC_ALLOWED_ROOTS, rejection of shell metacharacters, and refusal of every
# rsync --delete-family / truncating flag.
# =========================================================================== #
def _allowed_roots() -> list[str]:
    raw = os.environ.get("SCC_ALLOWED_ROOTS", "/projectnb/devorlab/daria")
    return [r for r in raw.split(":") if r]


def guard_normalize_path(p: str) -> str:
    """Lexically normalise an absolute path (no filesystem access, so it works
    for REMOTE paths): collapse '//' and '/./', resolve '/x/../' pairs, strip a
    trailing '/'. Returns '__GUARD_ESCAPE__' if the path escapes above root.
    Mirrors guard_normalize_path in scc_guard.sh."""
    if not p.startswith("/"):
        return p  # caller rejects non-absolute
    out: list[str] = []
    for part in p.split("/"):
        if part in ("", "."):
            continue
        if part == "..":
            if out:
                out.pop()
            else:
                return "__GUARD_ESCAPE__"
        else:
            out.append(part)
    return "/" + "/".join(out) if out else "/"


_METACHARS = set("$`;&|><()\n*?")


def assert_remote_path_allowed(raw: str, label: str = "path") -> str:
    """Abort unless <raw> is absolute, escape-free, metachar-free and inside
    SCC_ALLOWED_ROOTS. Returns the normalised path. Mirrors
    assert_remote_path_allowed in scc_guard.sh."""
    if not raw:
        raise GuardError(f"{label} is empty; refusing to operate on an unset remote path.")
    if not raw.startswith("/"):
        raise GuardError(f"{label} is not an absolute path: '{raw}'")
    if any(c in _METACHARS for c in raw):
        raise GuardError(
            f"{label} contains shell metacharacters: '{raw}' "
            "(refusing: this value would be interpolated into remote commands)."
        )
    norm = guard_normalize_path(raw)
    if norm == "__GUARD_ESCAPE__":
        raise GuardError(f"{label} escapes above the filesystem root: '{raw}'")
    protected = {
        "/", "/bin", "/boot", "/dev", "/etc", "/lib", "/lib64", "/proc",
        "/sbin", "/sys", "/usr", "/var", "/projectnb", "/project",
    }
    if norm in protected:
        raise GuardError(f"{label} resolves to a protected system path: '{norm}'")
    for root in _allowed_roots():
        rnorm = guard_normalize_path(root)
        if norm == rnorm or (norm + "/").startswith(rnorm + "/"):
            return norm
    raise GuardError(
        f"{label} is OUTSIDE the allowed roots.\n"
        f"  path    : {norm}\n"
        f"  allowed : {':'.join(_allowed_roots())}\n"
        "  This tool only ever reads your own directories on the shared cluster."
    )


_FORBIDDEN_RSYNC = {
    "--delete", "--del", "--remove-source-files", "--force", "--inplace",
}


def assert_rsync_nondestructive(args: list[str]) -> None:
    """Abort if any rsync argument would delete or truncate data on either side.
    Mirrors assert_rsync_nondestructive in scc_guard.sh."""
    for a in args:
        if a in _FORBIDDEN_RSYNC or a.startswith("--delete"):
            raise GuardError(
                f"refusing rsync flag '{a}': this tool never deletes or "
                "truncates data on the cluster."
            )


def controlmaster_alive(timeout: float = 10.0) -> bool:
    """True iff a live ssh ControlMaster socket exists for SCC_HOST. Uses
    BatchMode so it can never block on a password prompt. Mirrors the
    'no live socket -> refuse fast' expectation of the pipeline."""
    try:
        r = subprocess.run(
            ["ssh", "-o", "BatchMode=yes", "-O", "check", SCC_HOST],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout,
        )
        return r.returncode == 0
    except (subprocess.TimeoutExpired, OSError):
        return False


# =========================================================================== #
# Blob detection -- mirrors pupil_trace.m bright mode exactly.
# =========================================================================== #
def otsu_thresh_255(roi: np.ndarray) -> float:
    """Otsu threshold on a 0..255 scale, reproducing MATLAB graythresh()*255.

    MATLAB graythresh uses imhist with 256 bins whose centres are 0..255 for a
    uint8 image, maximises the between-class variance, and returns
    level = (idx-1)/255 (idx is the 1-based winning bin). pupil_trace.m then
    uses thr = level*255 == (idx-1). So the threshold on the 0..255 scale is the
    (0-based) intensity index of the winning bin."""
    counts = np.bincount(roi.ravel().astype(np.int64), minlength=256)[:256].astype(np.float64)
    total = counts.sum()
    if total == 0:
        return 0.0
    p = counts / total
    levels = np.arange(1, 257, dtype=np.float64)  # MATLAB (1:num_bins)
    omega = np.cumsum(p)
    mu = np.cumsum(p * levels)
    mu_t = mu[-1]
    denom = omega * (1.0 - omega)
    with np.errstate(divide="ignore", invalid="ignore"):
        sigma_b = (mu_t * omega - mu) ** 2 / denom
    sigma_b[~np.isfinite(sigma_b)] = 0.0
    maxval = sigma_b.max()
    idx0 = np.flatnonzero(sigma_b == maxval).mean()  # mean of 0-based indices on ties
    return float(idx0)  # == (idx_1based - 1) == graythresh*255


def detect_blob(frame: np.ndarray, mask: np.ndarray):
    """Reproduce pupil_trace.m bright-mode measurement for one frame.

    Returns (blob_mask, area, method) where blob_mask is the LARGEST connected
    component (8-connected) with area >= MIN_AREA_BRIGHT, area is its pixel
    count (0 if none), and method is one of 'clipped' | 'otsu' | 'no_sep' |
    'black' | 'no_blob'."""
    frame = frame.astype(np.float64)
    mask = mask.astype(bool)
    empty = np.zeros_like(mask, dtype=bool)

    if frame.max() <= 5:            # black frame (camera off) -> pipeline records 0
        return empty, 0, "black"

    roi = frame[mask]
    if roi.size == 0:
        return empty, 0, "no_blob"

    if np.count_nonzero(roi >= SAT_LEVEL) >= MIN_AREA_BRIGHT:
        cand = (frame >= SAT_LEVEL) & mask     # clipped core
        method = "clipped"
    else:
        thr = otsu_thresh_255(roi.astype(np.uint8) if roi.dtype != np.uint8 else roi)
        hi = roi[roi > thr]
        lo = roi[roi <= thr]
        if hi.size and lo.size and (hi.mean() - lo.mean()) >= MIN_CONTRAST:
            cand = (frame > thr) & mask
            method = "otsu"
        else:
            return empty, 0, "no_sep"       # no bimodal separation -> pipeline records 0

    # Largest 8-connected component with area >= MIN_AREA_BRIGHT (bwconncomp).
    lbl, n = ndimage.label(cand, structure=np.ones((3, 3), dtype=int))
    if n == 0:
        return empty, 0, "no_blob"
    sizes = ndimage.sum(np.ones_like(lbl), lbl, index=np.arange(1, n + 1))
    k = int(np.argmax(sizes)) + 1
    area = int(sizes[k - 1])
    if area < MIN_AREA_BRIGHT:
        return empty, 0, "no_blob"
    return (lbl == k), area, method


def mask_boundary(mask: np.ndarray) -> np.ndarray:
    """Perimeter pixels of the eye ellipse mask (mask minus its 8-erosion)."""
    er = ndimage.binary_erosion(mask, structure=np.ones((3, 3), dtype=int), border_value=0)
    return mask & ~er


# =========================================================================== #
# Inputs
# =========================================================================== #
def load_rois(batch_dir: Path) -> dict:
    """camera_dir -> dict(mask, ellipse_vertices, frame_size, base_name)."""
    p = batch_dir / "roi_stage" / "rois.mat"
    m = sio.loadmat(str(p), struct_as_record=False, squeeze_me=True)
    rois = np.atleast_1d(m["rois"])
    out = {}
    for e in rois:
        ell = getattr(e, "eye_ellipse", None)
        verts = None
        if ell is not None and hasattr(ell, "vertices"):
            verts = np.asarray(ell.vertices, dtype=float).reshape(-1, 2)
        out[str(e.key)] = {
            "mask": np.asarray(e.pupil_mask).astype(bool),
            "vertices": verts,
            "frame_size": np.asarray(e.frame_size).ravel().astype(int),
            "base_name": str(e.base_name),
        }
    return out


def load_stage_prefixes(batch_dir: Path) -> dict:
    """cluster_camera_dir -> filename prefix (frame name minus _NNNN.tiff)."""
    p = batch_dir / "roi_stage" / "stage_manifest.csv"
    df = pd.read_csv(p, dtype=str)
    out = {}
    for _, r in df.iterrows():
        fname = os.path.basename(str(r["cluster_frame_path"]))
        prefix = re.sub(r"_\d+\.tiff$", "", fname)
        out[str(r["cluster_camera_dir"])] = prefix
    return out


def published_csv_path(project_root: Path, mouse: str, date: str, base_name: str) -> Path:
    """<root>/<mouse>/<MM-DD-20yy>/behavior/<base>_behavior.csv (date is yy-mm-dd)."""
    yy, mm, dd = date.split("-")
    folder = f"{mm}-{dd}-20{yy}"
    return project_root / mouse / folder / "behavior" / f"{base_name}_behavior.csv"


def frame_filename(prefix: str, idx: int) -> str:
    return f"{prefix}_{idx:04d}.tiff"


def cache_frame_path(frame_cache: Path, base_name: str, prefix: str, idx: int) -> Path:
    return frame_cache / base_name / frame_filename(prefix, idx)


# =========================================================================== #
# Event detection
# =========================================================================== #
def _runs_of_true(flags: np.ndarray):
    """Yield (start, end_exclusive) index runs where flags is True."""
    if flags.size == 0:
        return
    idx = np.flatnonzero(flags)
    if idx.size == 0:
        return
    splits = np.flatnonzero(np.diff(idx) > 1)
    starts = np.concatenate(([0], splits + 1))
    ends = np.concatenate((splits + 1, [idx.size]))
    for s, e in zip(starts, ends):
        yield idx[s], idx[e - 1] + 1


def detect_events(win: pd.DataFrame, signal_col: str, dt: float,
                  n_events: int, min_flat_s: float, k_mad: float = 5.0,
                  abs_floor: float = 0.05, q_low: float = 0.20,
                  q_high: float = 0.80):
    """Detect events on the in-window samples.

    Rises/drops are computed on pupil_raw REGARDLESS of --signal, because a
    "sharp frame-to-frame" jump is by definition a raw-trace transient: the
    smoothed trace (Gaussian sigma~30 == ~3 s at 10 Hz) removes exactly these
    events by construction. Detecting them on the raw trace is what recovers the
    documented instability ordering (unstable runs surface many, clean runs few).

    Flat_small / flat_high use the selected --signal (default pupil_smooth),
    which is the correct instrument for a SUSTAINED plateau: smoothing suppresses
    per-frame noise so a genuine stuck stretch is not broken up.

    Threshold for rise/drop: |Δ| > max(abs_floor, k_mad * 1.4826 * MAD(Δ)),
    a per-run robust threshold (MAD is outlier-resistant, 1.4826 converts MAD to
    a Gaussian-sigma estimate). abs_floor guards very clean runs whose MAD is
    tiny. Returns (events, counts) where counts holds candidate totals per type
    (BEFORE truncating to n_events) so the ordering is visible in --dry-run.
    """
    frames = win["frame"].to_numpy()
    atime = win["aligned_time_s"].to_numpy()
    raw = win["pupil_raw"].to_numpy(dtype=float)
    sig = win[signal_col].to_numpy(dtype=float)

    events = []
    counts = {}

    # --- rise / drop on the raw trace -------------------------------------- #
    d = np.diff(raw)
    adj = np.diff(frames) == 1          # only true frame-to-frame steps
    d = np.where(adj, d, 0.0)
    med = np.median(d)
    mad = np.median(np.abs(d - med))
    rsigma = 1.4826 * mad
    thr = max(abs_floor, k_mad * rsigma)

    rise_idx = np.flatnonzero(d > thr)      # transition i -> i+1
    drop_idx = np.flatnonzero(d < -thr)
    counts["rise"] = int(rise_idx.size)
    counts["drop"] = int(drop_idx.size)
    counts["rise_thr"] = thr

    # top-N by magnitude; event attributed to the later frame (i+1)
    for typ, cand, key in (("rise", rise_idx, lambda i: d[i]),
                           ("drop", drop_idx, lambda i: -d[i])):
        order = sorted(cand, key=key, reverse=True)[:n_events]
        for i in sorted(order):
            j = i + 1
            events.append({
                "event_type": typ,
                "center_pos": int(j),
                "frame": int(frames[j]),
                "aligned_time_s": float(atime[j]),
                "sig_value": float(sig[j]),
                "raw_value": float(raw[j]),
                "jump": float(d[i]),
                "stretch_duration_s": "",
            })

    # --- flat_small / flat_high on the selected signal --------------------- #
    lo_thr = float(np.quantile(sig, q_low))
    hi_thr = float(np.quantile(sig, q_high))
    min_len = max(2, int(round(min_flat_s / dt)))

    for typ, flags in (("flat_small", sig <= lo_thr),
                       ("flat_high", sig >= hi_thr)):
        stretches = []
        for s, e in _runs_of_true(flags):
            # require frame contiguity within the stretch too
            if not np.all(np.diff(frames[s:e]) == 1):
                # split on any frame gap
                sub = np.arange(s, e)
                gaps = np.flatnonzero(np.diff(frames[s:e]) != 1)
                bounds = np.concatenate(([0], gaps + 1, [e - s]))
                for a, b in zip(bounds[:-1], bounds[1:]):
                    stretches.append((s + a, s + b))
            else:
                stretches.append((s, e))
        # keep stretches long enough, longest first
        long = [(s, e) for (s, e) in stretches if (e - s) >= min_len]
        long.sort(key=lambda se: se[1] - se[0], reverse=True)
        counts[typ] = len(long)
        for s, e in long[:n_events]:
            mid = s + (e - s) // 2
            dur = float(atime[e - 1] - atime[s])
            events.append({
                "event_type": typ,
                "center_pos": int(mid),
                "frame": int(frames[mid]),
                "aligned_time_s": float(atime[mid]),
                "sig_value": float(sig[mid]),
                "raw_value": float(raw[mid]),
                "jump": "",
                "stretch_duration_s": dur,
            })

    return events, counts


def offsets_for(context_s: float) -> list[float]:
    if context_s and context_s > 0:
        return [-abs(context_s), 0.0, abs(context_s)]
    return [0.0]


def nearest_row(win: pd.DataFrame, atime_arr: np.ndarray, target_t: float) -> int:
    """Positional index in win of the sample nearest target aligned-time."""
    return int(np.argmin(np.abs(atime_arr - target_t)))


# =========================================================================== #
# Frame fetch (guarded)
# =========================================================================== #
def fetch_frames(cluster_dir: str, prefix: str, indices: list[int],
                 dest_dir: Path, dry_run: bool, verbose=True):
    """rsync ONLY the requested frame files from the cluster into dest_dir.

    Returns a dict frame_index -> local Path for files that are present after
    the attempt (already-cached files are never re-fetched). Refuses (raising
    GuardError) if the remote dir is outside the allowed roots. If there is no
    live ControlMaster socket it refuses the fetch fast (prints, returns what is
    already cached) rather than hanging."""
    present = {}
    need = []
    for idx in indices:
        lp = dest_dir / frame_filename(prefix, idx)
        if lp.exists() and lp.stat().st_size > 0:
            present[idx] = lp
        else:
            need.append(idx)
    if not need:
        return present

    # Guard: confirm the remote directory is inside the allowed roots.
    norm_dir = assert_remote_path_allowed(cluster_dir, "cluster_camera_dir")
    remote_files = []
    for idx in need:
        rp = f"{norm_dir}/{frame_filename(prefix, idx)}"
        assert_remote_path_allowed(rp, "remote frame path")
        remote_files.append(rp)

    if dry_run:
        for rp in remote_files:
            print(f"      WOULD FETCH  {SCC_HOST}:{rp}")
        return present

    if not controlmaster_alive():
        print(
            "      SAFETY REFUSE: no live ssh ControlMaster socket for "
            f"'{SCC_HOST}'.\n"
            "        (`ssh -o BatchMode=yes -O check {h}` failed). Not fetching; "
            "montage will use whatever frames are already cached.\n"
            "        To fetch: open a master session, e.g. "
            "`ssh -M -S ~/.ssh/cm-... {h}` (see scc_guard.sh conventions)."
            .format(h=SCC_HOST)
        )
        return present

    # openrsync: no --info=stats; -e forces BatchMode so it can never hang on a
    # prompt. --delete family is never added (and asserted below).
    dest_dir.mkdir(parents=True, exist_ok=True)  # only now: a transfer will occur
    args = ["rsync", "-e", "ssh -o BatchMode=yes", "-t"]
    args += [f"{SCC_HOST}:{rp}" for rp in remote_files]
    args += [str(dest_dir) + "/"]
    assert_rsync_nondestructive(args)
    try:
        r = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           timeout=600)
    except (subprocess.TimeoutExpired, OSError) as ex:
        print(f"      rsync failed to run: {ex}")
        r = None
    # openrsync may exit 23 on a benign fchmodat warning while transferring
    # correctly -> treat 0 and 23 as success, then VERIFY arrivals explicitly.
    if r is not None and r.returncode not in (0, 23) and verbose:
        print(f"      rsync exit {r.returncode}: "
              f"{r.stderr.decode(errors='replace').strip()[:300]}")
    for idx in need:
        lp = dest_dir / frame_filename(prefix, idx)
        if lp.exists() and lp.stat().st_size > 0:
            present[idx] = lp
    fetched = len([i for i in need if i in present])
    if verbose:
        print(f"      fetched {fetched}/{len(need)} missing frame(s) into {dest_dir}")
    return present


def read_frame(path: Path) -> np.ndarray | None:
    """Read an 8-bit greyscale frame as a 2-D uint8 array (im2uint8-equivalent)."""
    try:
        import tifffile
        arr = tifffile.imread(str(path))
    except Exception:
        try:
            from PIL import Image
            arr = np.asarray(Image.open(path))
        except Exception:
            return None
    arr = np.asarray(arr)
    if arr.ndim == 3:
        arr = arr[..., 0]
    if arr.dtype != np.uint8:
        a = arr.astype(np.float64)
        if a.max() <= 1.0:
            a = a * 255.0
        elif arr.dtype == np.uint16:
            a = a / 257.0
        arr = np.clip(np.round(a), 0, 255).astype(np.uint8)
    return arr


# =========================================================================== #
# Montage rendering
# =========================================================================== #
def crop_box(mask: np.ndarray, margin_frac=0.6, min_margin=10):
    ys, xs = np.where(mask)
    r0, r1 = ys.min(), ys.max()
    c0, c1 = xs.min(), xs.max()
    mr = max(min_margin, int(round((r1 - r0 + 1) * margin_frac)))
    mc = max(min_margin, int(round((c1 - c0 + 1) * margin_frac)))
    H, W = mask.shape
    return (max(0, r0 - mr), min(H, r1 + 1 + mr),
            max(0, c0 - mc), min(W, c1 + 1 + mc))


def render_montage(base_name, win, signal_col, dt, panels, mask, vertices,
                   frame_imgs, out_dir: Path):
    """panels: list of event dicts, each with a 'cells' list of per-offset dicts
    already resolved (frame, t, values, blob info, img availability)."""
    n_cols = max(1, len(panels))
    offsets = panels[0]["offsets"] if panels else [0.0]
    n_rows = len(offsets)
    r0, r1, c0, c1 = crop_box(mask)

    fig_w = max(8.0, 1.9 * n_cols)
    fig_h = 3.0 + 2.1 * n_rows
    fig = plt.figure(figsize=(fig_w, fig_h))
    outer = GridSpec(2, 1, height_ratios=[3.0, 2.1 * n_rows], hspace=0.28,
                     left=0.06, right=0.98, top=0.93, bottom=0.04)

    # ---- top: trace panel ---- #
    ax = fig.add_subplot(outer[0])
    t = win["aligned_time_s"].to_numpy()
    ax.plot(t, win[signal_col].to_numpy(), color="#333333", lw=0.9,
            label=signal_col)
    ax.plot(t, win["pupil_raw"].to_numpy(), color="#bbbbbb", lw=0.5, alpha=0.7,
            zorder=0, label="pupil_raw")
    type_col = {"rise": "#e6550d", "drop": "#3182bd",
                "flat_small": "#31a354", "flat_high": "#756bb1"}
    seen = set()
    for p in panels:
        et = p["event_type"]
        tt = p["aligned_time_s"]
        vv = p["sig_value"]
        ax.plot([tt], [vv], "o", color=type_col.get(et, "k"), ms=6,
                mec="k", mew=0.4,
                label=et if et not in seen else None)
        seen.add(et)
        ax.annotate(f"{et}", (tt, vv), textcoords="offset points",
                    xytext=(0, 7), ha="center", fontsize=6,
                    color=type_col.get(et, "k"))
    ax.set_xlabel("aligned time (s)")
    ax.set_ylabel("pupil (rescaled)")
    ax.set_title(f"{base_name}   |   driving signal: {signal_col}   |   "
                 f"in-window n={len(win)}  dt={dt:.3f}s", fontsize=9)
    ax.legend(loc="upper right", fontsize=6, ncol=2, framealpha=0.8)
    ax.margins(x=0.01)

    # ---- bottom: snapshot grid ---- #
    if panels:
        grid = GridSpecFromSubplotSpec(n_rows, n_cols, subplot_spec=outer[1],
                                       wspace=0.08, hspace=0.35)
        for ci, p in enumerate(panels):
            for ri, off in enumerate(offsets):
                cell = p["cells"][ri]
                axi = fig.add_subplot(grid[ri, ci])
                axi.set_xticks([]); axi.set_yticks([])
                img = frame_imgs.get(cell["frame"])
                if img is None:
                    axi.text(0.5, 0.5, "frame\nmissing", ha="center",
                             va="center", fontsize=8, color="red",
                             transform=axi.transAxes)
                    axi.set_title(_cell_caption(p, cell, off), fontsize=5.5)
                    continue
                sub = img[r0:r1, c0:c1]
                axi.imshow(sub, cmap="gray", vmin=0, vmax=255,
                           interpolation="nearest")
                # hand-drawn ellipse (vertices are full-frame x,y)
                if vertices is not None:
                    vx = vertices[:, 0] - c0
                    vy = vertices[:, 1] - r0
                    vx = np.append(vx, vx[0]); vy = np.append(vy, vy[0])
                    axi.plot(vx, vy, color=COL_ELLIPSE, lw=1.0)
                # detected blob: translucent fill + contour
                blob = cell.get("blob")
                if blob is not None and blob.any():
                    bsub = blob[r0:r1, c0:c1]
                    rgba = np.zeros((*bsub.shape, 4))
                    rgba[bsub] = (1.0, 0.231, 0.188, 0.45)  # COL_BLOB tint
                    axi.imshow(rgba, interpolation="nearest")
                    axi.contour(bsub.astype(float), levels=[0.5],
                                colors=[COL_BLOB], linewidths=0.8)
                axi.set_title(_cell_caption(p, cell, off), fontsize=5.5)

    png = out_dir / f"{base_name}_snapshots.png"
    pdf = out_dir / f"{base_name}_snapshots.pdf"
    fig.savefig(png, dpi=150)
    fig.savefig(pdf)
    plt.close(fig)
    return png, pdf


def _cell_caption(panel, cell, off):
    et = panel["event_type"]
    tag = et if off == 0 else f"{et} {off:+.2f}s"
    lines = [tag, f"t={cell['aligned_time_s']:.2f}s  v={cell['sig_value']:.2f}"]
    if cell.get("blob_area") is None:
        lines.append("area=?")
    else:
        lines.append(f"area={cell['blob_area']}px  raw={cell['raw_value']:.2f}")
    hint = cell.get("hint")
    if hint:
        lines.append(hint)
    return "\n".join(lines)


# =========================================================================== #
# Per-run processing
# =========================================================================== #
def process_run(row, rois, prefixes, args, csv_rows, summary=None):
    """Returns 'written' | 'skipped' | 'error' for one manifest row."""
    base_name = str(row["base_name"])
    mouse = str(row["mouse"])
    date = str(row["date"])
    camera_dir = str(row["camera_dir"])

    csv_p = published_csv_path(Path(args.project_root), mouse, date, base_name)
    if not csv_p.exists():
        print(f"[skip] {base_name}: no published CSV at {csv_p}")
        return "skipped"

    df = pd.read_csv(csv_p)
    win = df[df["in_imaging_window"] > 0.5].reset_index(drop=True)
    if len(win) < 5:
        print(f"[skip] {base_name}: <5 in-window samples")
        return "skipped"
    dt = float(np.median(np.diff(win["time_s"].to_numpy())))
    if not np.isfinite(dt) or dt <= 0:
        dt = 0.1

    events, counts = detect_events(win, args.signal, dt, args.n_events,
                                   args.min_flat_s)

    if summary is not None:
        summary.append({
            "base_name": base_name,
            "rise": counts.get("rise", 0),
            "drop": counts.get("drop", 0),
            "flat_small": counts.get("flat_small", 0),
            "flat_high": counts.get("flat_high", 0),
            "jump_thr": counts.get("rise_thr", 0.0),
        })

    print(f"[run ] {base_name}: "
          f"rise_cand={counts.get('rise',0)} drop_cand={counts.get('drop',0)} "
          f"flat_small={counts.get('flat_small',0)} "
          f"flat_high={counts.get('flat_high',0)} "
          f"(jump_thr={counts.get('rise_thr',0):.3f}) "
          f"-> {len(events)} events shown")
    for ev in events:
        extra = (f" jump={ev['jump']:+.3f}" if ev["jump"] != "" else
                 f" dur={ev['stretch_duration_s']:.2f}s")
        print(f"        {ev['event_type']:11s} frame={ev['frame']:5d} "
              f"t={ev['aligned_time_s']:8.2f}s v={ev['sig_value']:.3f}{extra}")

    roi = rois.get(camera_dir)
    if roi is None:
        print(f"[skip] {base_name}: no ROI entry for {camera_dir}")
        return "skipped"
    mask = roi["mask"]
    vertices = roi["vertices"]
    prefix = prefixes.get(camera_dir)
    if prefix is None:
        print(f"[skip] {base_name}: no stage prefix for {camera_dir}")
        return "skipped"

    atime_arr = win["aligned_time_s"].to_numpy()
    offsets = offsets_for(args.context_s)

    # Resolve every panel cell (frame idx + trace values) and gather needed frames
    needed = set()
    for ev in events:
        cells = []
        for off in offsets:
            pos = nearest_row(win, atime_arr, ev["aligned_time_s"] + off)
            fr = int(win["frame"].iloc[pos])
            cells.append({
                "frame": fr,
                "aligned_time_s": float(win["aligned_time_s"].iloc[pos]),
                "sig_value": float(win[args.signal].iloc[pos]),
                "raw_value": float(win["pupil_raw"].iloc[pos]),
                "smooth_value": float(win["pupil_smooth"].iloc[pos]),
            })
            needed.add(fr)
        ev["cells"] = cells
        ev["offsets"] = offsets

    # Fetch (or dry-run list / refuse) the needed frames.
    dest = Path(args.frame_cache) / base_name
    if args.fetch or args.dry_run:
        present = fetch_frames(camera_dir, prefix, sorted(needed), dest,
                               dry_run=args.dry_run)
    else:
        present = {}
        for fr in needed:
            lp = dest / frame_filename(prefix, fr)
            if lp.exists() and lp.stat().st_size > 0:
                present[fr] = lp

    if args.dry_run:
        return "skipped"  # nothing rendered in dry-run

    # Load frames + compute blobs, once per unique frame.
    frame_imgs = {}
    blob_cache = {}
    boundary = mask_boundary(mask)
    n_missing = 0
    for fr in sorted(needed):
        lp = present.get(fr)
        img = read_frame(lp) if lp else None
        if img is None:
            n_missing += 1
            frame_imgs[fr] = None
            continue
        if img.shape != mask.shape:
            print(f"      note: frame {fr} shape {img.shape} != mask {mask.shape}; skipping overlay")
            frame_imgs[fr] = img
            blob_cache[fr] = (None, None, "shape_mismatch", False)
            continue
        frame_imgs[fr] = img
        bmask, area, method = detect_blob(img, mask)
        touches = bool(np.any(bmask & boundary)) if area > 0 else False
        blob_cache[fr] = (bmask if area > 0 else None, area, method, touches)
    if n_missing:
        print(f"      note: {n_missing} needed frame(s) missing; montage uses what is available")

    # Attach blob info + verdict hints to each cell, and record CSV rows.
    for ev in events:
        for ci, cell in enumerate(ev["cells"]):
            fr = cell["frame"]
            bc = blob_cache.get(fr)
            if bc is None:
                cell["blob"] = None
                cell["blob_area"] = None
                cell["hint"] = ""
                method = ""
                touches = ""
                area_out = ""
            else:
                bmask, area, method, touches = bc
                cell["blob"] = bmask
                cell["blob_area"] = area
                area_out = area
                if area == 0:
                    cell["hint"] = "NO BLOB (lost?)"
                elif touches:
                    cell["hint"] = "TOUCHES EDGE (merge?)"
                else:
                    cell["hint"] = ""
            is_center = (offsets[ci] == 0.0)
            csv_rows.append({
                "run": base_name,
                "event_type": ev["event_type"],
                "is_event_center": is_center,
                "context_offset_s": offsets[ci],
                "frame_index": fr,
                "aligned_time_s": round(cell["aligned_time_s"], 4),
                "signal": args.signal,
                "trace_value": round(cell["sig_value"], 5),
                "pupil_raw": round(cell["raw_value"], 5),
                "pupil_smooth": round(cell["smooth_value"], 5),
                "blob_area_px": area_out,
                "touches_boundary": touches,
                "detection_method": method,
                "stretch_duration_s": (round(ev["stretch_duration_s"], 3)
                                       if ev["stretch_duration_s"] != "" else ""),
                "frame_available": frame_imgs.get(fr) is not None,
            })

    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)
    if not events:
        print(f"[note] {base_name}: no events detected; writing trace-only montage")
    png, pdf = render_montage(base_name, win, args.signal, dt, events, mask,
                              vertices, frame_imgs, out_dir)
    print(f"[ok  ] {base_name}: wrote {png.name} ({png.stat().st_size} bytes) and {pdf.name}")
    return "written"


# =========================================================================== #
# CLI
# =========================================================================== #
def build_parser():
    p = argparse.ArgumentParser(
        description="Visual-QC montages of pupil-trace events with source-frame "
                    "snapshots (eye ellipse + pipeline blob overlaid).")
    p.add_argument("--runs", default=None,
                   help="regex, or comma-separated list of regexes, matched "
                        "against each run's base_name (default: all runs).")
    p.add_argument("--project-root", default=DEFAULT_PROJECT_ROOT,
                   help="published per-run data root (default: %(default)s)")
    p.add_argument("--batch-dir", default=DEFAULT_BATCH_DIR,
                   help="batch dir with manifests + rois.mat (default: %(default)s)")
    p.add_argument("--out", default=None,
                   help="output dir for montages + events CSV "
                        "(default: <batch-dir>/results/pupil_snapshots)")
    p.add_argument("--n-events", type=int, default=3,
                   help="max events of EACH type per run (default: 3)")
    p.add_argument("--context-s", type=float, default=0.5,
                   help="also show frames at +/- S seconds around each event "
                        "(default: 0.5; 0 = only the event frame)")
    p.add_argument("--min-flat-s", type=float, default=3.0,
                   help="minimum duration (s) for a sustained flat stretch "
                        "(default: 3.0)")
    p.add_argument("--signal", choices=["pupil_raw", "pupil_smooth"],
                   default="pupil_smooth",
                   help="trace that drives flat detection + plotting/reporting "
                        "(default: pupil_smooth). Sharp rise/drop events are "
                        "always detected on pupil_raw; see detect_events().")
    fetch = p.add_mutually_exclusive_group()
    fetch.add_argument("--fetch", dest="fetch", action="store_true",
                       help="rsync missing frames from the cluster (default)")
    fetch.add_argument("--no-fetch", dest="fetch", action="store_false",
                       help="never contact the cluster; use cached frames only")
    p.set_defaults(fetch=True)
    p.add_argument("--frame-cache", default=None,
                   help="frame cache dir (default: <batch-dir>/frame_cache)")
    p.add_argument("--dry-run", action="store_true",
                   help="list events and the frames that WOULD be pulled; "
                        "pull nothing and render nothing.")
    return p


def select_runs(manifest: pd.DataFrame, spec: str | None) -> pd.DataFrame:
    if not spec:
        return manifest
    pats = [s for s in spec.split(",") if s]
    try:
        regexes = [re.compile(s) for s in pats]
    except re.error as ex:
        raise SystemExit(f"bad --runs regex: {ex}")
    keep = manifest["base_name"].apply(
        lambda b: any(rx.search(str(b)) for rx in regexes))
    return manifest[keep]


def main(argv=None):
    args = build_parser().parse_args(argv)
    batch_dir = Path(args.batch_dir)
    if args.out is None:
        args.out = str(batch_dir / "results" / "pupil_snapshots")
    if args.frame_cache is None:
        args.frame_cache = str(batch_dir / "frame_cache")

    manifest_p = batch_dir / "results" / "batch_manifest.csv"
    if not manifest_p.exists():
        print(f"ERROR: manifest not found: {manifest_p}", file=sys.stderr)
        return 2
    manifest = pd.read_csv(manifest_p)
    manifest = manifest[manifest["status"].astype(str).str.lower() == "ok"] \
        if "status" in manifest.columns else manifest
    manifest = select_runs(manifest, args.runs)
    if manifest.empty:
        print("No runs matched --runs; nothing to do.", file=sys.stderr)
        return 2

    try:
        rois = load_rois(batch_dir)
        prefixes = load_stage_prefixes(batch_dir)
    except Exception as ex:
        print(f"ERROR loading ROIs/stage manifest: {ex}", file=sys.stderr)
        return 2

    print(f"pupil_snapshots: {len(manifest)} run(s) selected; signal={args.signal}; "
          f"fetch={'on' if args.fetch else 'off'}; dry_run={args.dry_run}")
    print(f"  allowed cluster roots: {':'.join(_allowed_roots())}")
    print(f"  out={args.out}  frame_cache={args.frame_cache}")

    csv_rows: list[dict] = []
    n_written = 0
    n_skipped = 0
    summary: list[dict] = []

    for _, row in manifest.iterrows():
        try:
            status = process_run(row, rois, prefixes, args, csv_rows, summary)
        except GuardError as ge:
            print(f"[safety] {row.get('base_name','?')}: {ge}")
            status = "skipped"
        except Exception as ex:
            print(f"[error] {row.get('base_name','?')}: {ex}")
            status = "skipped"
        if status == "written":
            n_written += 1
        elif status == "skipped":
            n_skipped += 1

    # Ordering sanity check: unstable runs should surface many rise/drop
    # candidates, clean runs few. Sorted so the ordering is self-evident.
    if summary:
        summary.sort(key=lambda d: d["rise"] + d["drop"], reverse=True)
        print("\n=== rise/drop candidate ranking (jumps on pupil_raw; more = less stable) ===")
        print(f"  {'run':32s} {'rise':>5s} {'drop':>5s} {'r+d':>5s} "
              f"{'flatS':>6s} {'flatH':>6s} {'thr':>7s}")
        for d in summary:
            print(f"  {d['base_name']:32s} {d['rise']:5d} {d['drop']:5d} "
                  f"{d['rise']+d['drop']:5d} {d['flat_small']:6d} "
                  f"{d['flat_high']:6d} {d['jump_thr']:7.3f}")

    # Events CSV (skip in dry-run: nothing was measured from frames).
    if not args.dry_run and csv_rows:
        out_dir = Path(args.out)
        out_dir.mkdir(parents=True, exist_ok=True)
        events_csv = out_dir / "pupil_snapshots_events.csv"
        cols = ["run", "event_type", "is_event_center", "context_offset_s",
                "frame_index", "aligned_time_s", "signal", "trace_value",
                "pupil_raw", "pupil_smooth", "blob_area_px", "touches_boundary",
                "detection_method", "stretch_duration_s", "frame_available"]
        pd.DataFrame(csv_rows, columns=cols).to_csv(events_csv, index=False)
        print(f"\nEvents CSV: {events_csv} ({len(csv_rows)} rows)")

    print(f"\nDone: {n_written} montage(s) written, {n_skipped} run(s) skipped.")
    if args.dry_run:
        print("(dry-run: no frames pulled, no montages or CSV written)")
        return 0
    # exit 0 iff at least one montage was written
    return 0 if n_written > 0 else 1


if __name__ == "__main__":
    sys.exit(main())
