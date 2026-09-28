#!/usr/bin/env python
"""
behavior_panels.py -- stacked behavior panel plots for the batch pipeline.

Renders pupil / whisking / accelerometer (and, optionally, a binary
whisking-bins) panel stack from the CSV pair produced by the MATLAB stage:

    <base>_behavior.csv   (10 Hz)   columns:
        frame, time_s, aligned_time_s, in_imaging_window,
        pupil_raw, pupil_smooth, pupil_bins,
        whisker_raw_long, whisker_smooth_long,
        whisker_raw_pad,  whisker_smooth_pad, whisker_bins
    <base>_accel.csv      (~1000 Hz) columns:
        sample, accel_mag, accX, accY, accZ, time_s, aligned_time_s

The visual style matches the reference single-run script
    apical-dendrites-2025/code/Behavior-Analysis/behavior_plots.py
but this program is deliberately the OPPOSITE of that script's shape: it has no
hardcoded run identity (DATE/MOUSE/RUN), it is driven entirely by argparse, it
is headless (Agg backend, never calls plt.show()), and it has a --batch mode
that fans out over a directory of runs. That makes it safe to launch as an SGE /
qsub batch job on the BU SCC cluster.

ALIGNMENT NOTE (read before touching timing):
    Both CSVs already carry `aligned_time_s`, with t = 0 at the first imaging
    trigger (AndorXylaTrigger rising edge). That alignment -- including the
    Basler->SCAPE trigger offset -- is done UPSTREAM by the MATLAB stage
    (mat_to_csv.m). Do NOT re-apply any Basler/SCAPE offset here, or the signals
    will be double-corrected. This script only crops the already-aligned axis.

BINDING conventions carried over from the reference + steering doc:
    - Accelerometer panel y-limit is fixed 0..0.25 in ALL plotting scripts.
    - Accelerometer signal = the `accel_mag` column; `aligned_time_s` is the
      time axis, NOT the signal.
    - Vector-friendly fonts: sans-serif (Arial first) + pdf.fonttype = 42 so
      PDF text stays editable.
    - Stacked subplots sharing x, figsize (11, 1.6*n_panels); signal name drawn
      INSIDE each panel at (0.008, 0.94) axes coords, ha=left va=top, in the
      trace color, bold, fontsize 20; no y-axis label; grid off; top/right
      spines hidden; tick labelsize 16; y-axis MaxNLocator(nbins=3); xlabel
      'Time (s)' fontsize 18 on the bottom panel only; tight_layout(h_pad=0.4).
    - Colors: pupil blue, whisker orange, accelerometer purple.
    - Display smoothing: pupil gaussian sigma=2, whisker sigma=3,
      accelerometer np.abs() then sigma=10.
"""

import matplotlib
matplotlib.use("Agg")  # headless-safe: MUST precede pyplot import (cluster/qsub)

import argparse
import glob
import os
import sys

import numpy as np
import pandas as pd
import matplotlib as mpl
import matplotlib.pyplot as plt
from matplotlib.ticker import MaxNLocator
from scipy.ndimage import gaussian_filter1d

# ---- Vector-friendly fonts: Arial, embedded as editable TrueType in the PDF ---
mpl.rcParams["font.family"] = "sans-serif"
mpl.rcParams["font.sans-serif"] = ["Arial", "Helvetica", "DejaVu Sans"]
mpl.rcParams["pdf.fonttype"] = 42

# ---- Reference conventions (do not deviate) ---------------------------------
COLOR_PUPIL = "blue"
COLOR_WHISKER = "orange"
COLOR_ACCEL = "purple"
COLOR_BINS = "orange"          # bins are the whisking on/off state -> whisker family
ACCEL_YLIM = (0.0, 0.25)       # fixed in ALL plotting scripts
BINS_YLIM = (0.0, 2.0)
SIGMA_PUPIL = 2
SIGMA_WHISKER = 3
SIGMA_ACCEL = 10
LW_TRACE = 1.8
LW_BINS = 2.0
NAME_X, NAME_Y = 0.008, 0.94   # in-panel signal-name position (axes coords)


class PipelineError(Exception):
    """Recoverable, user-facing failure for one run (no traceback shown)."""


class Panel:
    """One stacked panel: a time axis, a signal, a color, and a draw kind."""
    __slots__ = ("name", "t", "y", "color", "kind")

    def __init__(self, name, t, y, color, kind):
        self.name = name
        self.t = np.asarray(t, dtype=float)
        self.y = np.asarray(y, dtype=float)
        self.color = color
        self.kind = kind  # "line" | "accel" | "bins"

    def crop(self, lo, hi):
        """Keep samples with lo <= t <= hi (and finite t)."""
        m = np.isfinite(self.t) & (self.t >= lo) & (self.t <= hi)
        self.t = self.t[m]
        self.y = self.y[m]


# ---------------------------------------------------------------------------
# I/O helpers
# ---------------------------------------------------------------------------
def read_csv_safe(path):
    """Read a CSV, converting the common empty/missing cases into readable
    PipelineErrors instead of raw tracebacks (this runs unattended)."""
    try:
        df = pd.read_csv(path)
    except pd.errors.EmptyDataError:
        raise PipelineError(f"CSV is empty (no columns/data): {path}")
    except FileNotFoundError:
        raise PipelineError(f"CSV not found: {path}")
    if df.shape[0] == 0:
        raise PipelineError(f"CSV has a header but no data rows: {path}")
    return df


def _renorm(y):
    """Per-run min-max rescale to [0, 1] (used only when --renormalize)."""
    if not np.isfinite(y).any():
        return y
    lo = np.nanmin(y)
    hi = np.nanmax(y)
    if hi - lo <= 0:
        return y - lo
    return (y - lo) / (hi - lo)


# ---------------------------------------------------------------------------
# Panel builders
# ---------------------------------------------------------------------------
def behavior_panels(df, args):
    """Build pupil / whisking / bins panels from the behavior dataframe.

    Returns (pupil_panel|None, whisker_panel|None, bins_panel|None, notes).
    Raises PipelineError only if the required time axis is absent.
    """
    notes = []
    if "aligned_time_s" not in df.columns:
        raise PipelineError(
            "behavior CSV missing required column 'aligned_time_s' "
            f"(columns present: {list(df.columns)})"
        )
    t = df["aligned_time_s"].to_numpy(dtype=float)

    # --- Pupil --------------------------------------------------------------
    pupil_p = None
    pcol = f"pupil_{args.pupil_signal}"  # pupil_raw | pupil_smooth
    if pcol in df.columns:
        y = gaussian_filter1d(df[pcol].to_numpy(dtype=float), sigma=SIGMA_PUPIL)
        if args.renormalize:
            y = _renorm(y)
        pupil_p = Panel("Pupil", t, y, COLOR_PUPIL, "line")
    else:
        notes.append(f"pupil column '{pcol}' not found -> omitting Pupil panel")

    # --- Whisking -----------------------------------------------------------
    # --whisker-signal picks long vs pad; prefer the smoothed variant, fall
    # back to the raw variant (matches reference which used whisker_smooth_long).
    whisker_p = None
    wsm = f"whisker_smooth_{args.whisker_signal}"
    wrw = f"whisker_raw_{args.whisker_signal}"
    wcol = wsm if wsm in df.columns else (wrw if wrw in df.columns else None)
    if wcol is not None:
        y = gaussian_filter1d(df[wcol].to_numpy(dtype=float), sigma=SIGMA_WHISKER)
        if args.renormalize:
            y = _renorm(y)
        whisker_p = Panel("Whisking", t, y, COLOR_WHISKER, "line")
        if wcol == wrw:
            notes.append(f"whisker '{wsm}' absent, using raw '{wrw}'")
    else:
        notes.append(
            f"whisker columns '{wsm}'/'{wrw}' not found -> omitting Whisking panel"
        )

    # --- Whisking bins (binary on/off) -------------------------------------
    bins_p = None
    if args.bins:
        if "whisker_bins" in df.columns:
            b = df["whisker_bins"].to_numpy(dtype=float)
            # Match the MATLAB script: set the "off" (0) samples to NaN so the
            # panel is blank there rather than drawing a solid line at zero.
            b = np.where(b == 0, np.nan, b)
            bins_p = Panel("Whisking (bins)", t, b, COLOR_BINS, "bins")
        else:
            notes.append("whisker_bins column not found -> omitting Bins panel")

    return pupil_p, whisker_p, bins_p, notes


def accel_panel(df, args):
    """Build the accelerometer panel. Returns (panel, note|None).

    Keeps physical units (never renormalized) so the fixed 0..0.25 y-limit is
    meaningful. Uses accel_mag as the signal and aligned_time_s as the axis.
    """
    missing = [c for c in ("aligned_time_s", "accel_mag") if c not in df.columns]
    if missing:
        raise PipelineError(f"accel CSV missing column(s): {missing}")
    t = df["aligned_time_s"].to_numpy(dtype=float)
    y = np.abs(df["accel_mag"].to_numpy(dtype=float))
    y = gaussian_filter1d(y, sigma=SIGMA_ACCEL)
    return Panel("Accelerometer", t, y, COLOR_ACCEL, "accel"), None


def build_panels(behavior_csv, accel_csv, args, log):
    """Assemble the ordered panel list: Pupil, Whisking, Accelerometer, Bins.

    A missing accel CSV (or an unusable one) is non-fatal: it just omits that
    panel with a printed note. A behavior CSV that cannot yield a time axis is
    fatal (raises PipelineError).
    """
    notes = []
    bdf = read_csv_safe(behavior_csv)  # fatal on empty / no-rows
    pupil_p, whisker_p, bins_p, bnotes = behavior_panels(bdf, args)
    notes += bnotes

    accel_p = None
    if accel_csv is None:
        notes.append("no accelerometer CSV -> omitting Accelerometer panel")
    elif not os.path.exists(accel_csv):
        notes.append(
            f"accelerometer CSV not found ({accel_csv}) -> omitting Accelerometer panel"
        )
    else:
        try:
            adf = read_csv_safe(accel_csv)
            accel_p, anote = accel_panel(adf, args)
            if anote:
                notes.append(anote)
        except PipelineError as exc:
            notes.append(f"accelerometer CSV unusable ({exc}) -> omitting Accelerometer panel")

    ordered = [p for p in (pupil_p, whisker_p, accel_p, bins_p) if p is not None]
    return ordered, notes


# ---------------------------------------------------------------------------
# Cropping + summaries
# ---------------------------------------------------------------------------
def crop_panels(panels, crop_start):
    """Crop every panel to a common window on the aligned time axis.

    Start: drop t < 0 (before the imaging trigger) AND cut the first
    `crop_start` seconds -> keep t >= max(0, crop_start). End: trim all panels
    to the SHORTEST common end time so the stacked panels line up exactly.
    (No re-zeroing: the x axis stays true `aligned_time_s`, t=0 at the trigger.)
    """
    start_cut = max(0.0, float(crop_start))
    for p in panels:
        p.crop(start_cut, np.inf)
    ends = [p.t.max() for p in panels if p.t.size]
    if not ends:
        raise PipelineError(f"no usable data after cropping at t >= {start_cut:g}s")
    t_end = min(ends)
    for p in panels:
        p.crop(start_cut, t_end)
    panels = [p for p in panels if p.t.size]
    if not panels:
        raise PipelineError("no usable data (all panels empty after common end-crop)")
    return panels, start_cut, t_end


def summarize(p):
    """One auditable line per panel for the batch log."""
    n = p.t.size
    if n == 0:
        return f"{p.name:16s} EMPTY"
    dur = float(p.t.max() - p.t.min())
    with np.errstate(all="ignore"):
        if np.all(np.isnan(p.y)):
            ymin = ymax = float("nan")
        else:
            ymin = float(np.nanmin(p.y))
            ymax = float(np.nanmax(p.y))
    return (
        f"{p.name:16s} n={n:6d}  dur={dur:7.1f}s  "
        f"t=[{p.t.min():7.1f},{p.t.max():7.1f}]  y=[{ymin:.3f},{ymax:.3f}]"
    )


# ---------------------------------------------------------------------------
# Figure
# ---------------------------------------------------------------------------
def build_figure(panels, title=None):
    """Create the stacked-panel figure in the reference visual style.

    Returns (fig, axes). Caller is responsible for saving and closing.
    """
    n = len(panels)
    fig, axes = plt.subplots(n, 1, figsize=(11, 1.6 * n), sharex=True)
    if n == 1:
        axes = [axes]

    for ax, p in zip(axes, panels):
        lw = LW_BINS if p.kind == "bins" else LW_TRACE
        ax.plot(p.t, p.y, color=p.color, linewidth=lw)

        if p.kind == "accel":
            ax.set_ylim(*ACCEL_YLIM)     # fixed physical-unit limit
        elif p.kind == "bins":
            ax.set_ylim(*BINS_YLIM)

        ax.set_ylabel("")
        ax.text(NAME_X, NAME_Y, p.name, transform=ax.transAxes,
                ha="left", va="top", color=p.color, fontweight="bold", fontsize=20)
        ax.grid(False)
        ax.tick_params(labelsize=16)
        ax.spines["top"].set_visible(False)
        ax.spines["right"].set_visible(False)
        ax.yaxis.set_major_locator(MaxNLocator(nbins=3))

    axes[-1].set_xlabel("Time (s)", fontsize=18)
    if title:
        fig.suptitle(title, fontsize=14)
    fig.tight_layout(h_pad=0.4)
    return fig, axes


def save_figure(fig, out_paths, dpi):
    """Save the figure to each requested path (format inferred from extension).
    Never calls plt.show() -- this must stay headless for batch jobs."""
    for op in out_paths:
        parent = os.path.dirname(os.path.abspath(op))
        if parent and not os.path.isdir(parent):
            os.makedirs(parent, exist_ok=True)
        fmt = "pdf" if op.lower().endswith(".pdf") else "png"
        fig.savefig(op, format=fmt, dpi=dpi, bbox_inches="tight")


# ---------------------------------------------------------------------------
# Orchestration for a single run
# ---------------------------------------------------------------------------
def process_one(behavior_csv, accel_csv, out_base, title, args, log=print):
    """Full pipeline for one run: build -> crop -> summarize -> render -> save.
    Returns the list of written output paths. Raises PipelineError on failure."""
    panels, notes = build_panels(behavior_csv, accel_csv, args, log)
    for nt in notes:
        log(f"  note: {nt}")

    panels, start_cut, t_end = crop_panels(panels, args.crop_start)

    for p in panels:
        log("  " + summarize(p))
    log(f"  common window: [{start_cut:.1f}, {t_end:.1f}] s across "
        f"{len(panels)} panel(s)")

    fig, _ = build_figure(panels, title)
    formats = list(dict.fromkeys(args.format))  # dedup, preserve order
    out_paths = [f"{out_base}.{fmt}" for fmt in formats]
    try:
        save_figure(fig, out_paths, args.dpi)
    finally:
        plt.close(fig)

    for op in out_paths:
        size = os.path.getsize(op) if os.path.exists(op) else 0
        log(f"  wrote {op} ({size} bytes)")
    return out_paths


# ---------------------------------------------------------------------------
# Name / path helpers
# ---------------------------------------------------------------------------
def _run_name(behavior_csv):
    b = os.path.basename(behavior_csv)
    if b.endswith("_behavior.csv"):
        return b[: -len("_behavior.csv")]
    return os.path.splitext(b)[0]


def _out_base_single(behavior_csv, out_arg):
    if out_arg:
        base = out_arg
        for ext in (".pdf", ".png"):
            if base.lower().endswith(ext):
                return base[: -len(ext)]
        return base
    d = os.path.dirname(os.path.abspath(behavior_csv))
    return os.path.join(d, _run_name(behavior_csv) + "_panels")


# ---------------------------------------------------------------------------
# Run modes
# ---------------------------------------------------------------------------
def run_single(args):
    if not args.behavior_csv:
        print("error: --behavior-csv is required (or use --batch DIR)", file=sys.stderr)
        return 2
    if not os.path.exists(args.behavior_csv):
        print(f"error: behavior CSV not found: {args.behavior_csv}", file=sys.stderr)
        return 2

    run_name = _run_name(args.behavior_csv)
    title = args.title if args.title is not None else run_name
    out_base = _out_base_single(args.behavior_csv, args.out)

    print(f"[{run_name}] behavior={args.behavior_csv} "
          f"accel={args.accel_csv if args.accel_csv else '<none>'}")
    try:
        process_one(args.behavior_csv, args.accel_csv, out_base, title, args)
    except PipelineError as exc:
        print(f"[{run_name}] ERROR: {exc}", file=sys.stderr)
        return 1
    print(f"[{run_name}] done")
    return 0


def run_batch(args):
    d = args.batch
    if not os.path.isdir(d):
        print(f"error: --batch path is not a directory: {d}", file=sys.stderr)
        return 2

    files = sorted(glob.glob(os.path.join(d, "**", "*_behavior.csv"), recursive=True))
    if not files:
        print(f"error: no *_behavior.csv found under {d}", file=sys.stderr)
        return 1

    outdir = args.out
    if outdir:
        os.makedirs(outdir, exist_ok=True)

    print(f"batch: {len(files)} run(s) under {d}")
    n_ok = n_fail = 0
    for bf in files:
        run_name = _run_name(bf)
        accel = bf[: -len("_behavior.csv")] + "_accel.csv"
        accel = accel if os.path.exists(accel) else None
        out_base = (os.path.join(outdir, run_name + "_panels")
                    if outdir else
                    os.path.join(os.path.dirname(bf), run_name + "_panels"))
        title = args.title if args.title is not None else run_name

        print(f"[{run_name}] behavior={bf} accel={accel if accel else '<none>'}")
        try:
            process_one(bf, accel, out_base, title, args)
            n_ok += 1
            print(f"[{run_name}] done")
        except PipelineError as exc:
            print(f"[{run_name}] ERROR: {exc}", file=sys.stderr)
            n_fail += 1

    print(f"batch summary: {n_ok} ok, {n_fail} failed, {len(files)} total")
    return 0 if (n_fail == 0 and n_ok > 0) else 1


def parse_args(argv=None):
    p = argparse.ArgumentParser(
        prog="behavior_panels.py",
        description="Stacked pupil/whisking/accelerometer panel plots from the "
                    "MATLAB-stage behavior/accel CSV pair (headless batch tool).",
    )
    p.add_argument("--behavior-csv",
                   help="Path to a <base>_behavior.csv (required unless --batch).")
    p.add_argument("--accel-csv", default=None,
                   help="Path to the matching <base>_accel.csv (optional).")
    p.add_argument("--batch", default=None, metavar="DIR",
                   help="Directory to recursively glob for *_behavior.csv; each "
                        "is paired with its sibling *_accel.csv. Primary mode.")
    p.add_argument("--out", default=None,
                   help="Single mode: output file path/base (extension optional). "
                        "Batch mode: output directory (default: beside each CSV).")
    p.add_argument("--title", default=None,
                   help="Figure suptitle (default: the run name).")
    p.add_argument("--crop-start", type=float, default=0.0, metavar="SECONDS",
                   help="Cut the first N seconds after alignment (t<0 is always "
                        "dropped). Default 0.")
    p.add_argument("--format", nargs="+", choices=["pdf", "png"],
                   default=["pdf", "png"],
                   help="Output format(s); may be both. Default: pdf png.")
    p.add_argument("--dpi", type=int, default=200, help="Raster DPI. Default 200.")
    p.add_argument("--pupil-signal", choices=["raw", "smooth"], default="smooth",
                   help="Which pupil column to plot. Default smooth.")
    p.add_argument("--whisker-signal", choices=["long", "pad"], default="long",
                   help="Which whisker variant to plot. Default long.")
    # Bins are OFF by default: the binary on/off panel duplicates what the
    # continuous whisking trace already shows. Pass --bins to include it.
    p.add_argument("--bins", action="store_true",
                   help="add a binary whisking on/off panel (off by default)")
    p.add_argument("--renormalize", action="store_true",
                   help="Per-run min-max rescale of pupil & whisker to [0,1]. "
                        "Accelerometer always keeps physical units.")
    return p.parse_args(argv)


def main(argv=None):
    args = parse_args(argv)
    if args.batch:
        return run_batch(args)
    return run_single(args)


if __name__ == "__main__":
    sys.exit(main())
