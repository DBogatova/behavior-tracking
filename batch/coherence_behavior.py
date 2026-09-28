#!/usr/bin/env python
"""coherence_behavior.py -- behaviour companion figure for a *_clean_coherence plot.

Writes a SEPARATE figure (never touches the existing coherence PNG/PDF) whose
x-axis is IMAGING FRAME, matching the coherence figure exactly, so the two can be
stacked. Overlays the multi-segment network events from
<run>_clean_coherence_network_events.csv on the behaviour traces, using the same
colour convention as the coherence figure (soma-led red, branch-led blue).

TIME MAPPING (the crux)
  The coherence figure's x-axis is imaging FRAME, while behaviour is on
  aligned_time_s (0 = first imaging-trigger rising edge). The imaging frame rate
  is not stored anywhere we can read, so it is DERIVED:

      rate = n_imaging_frames / settings.imaging_window_s span
      t(frame) = frame / rate          (frame 0 at aligned t = 0)

  For run7 of 06-25-2026 that gives 1431 / 240.120 = 5.9595 Hz. The nominal rate
  is presumably 6 Hz; assuming exactly 6 would place the last frame 1.6 s earlier
  (238.5 s vs 240.1 s), i.e. ~16 behaviour samples of drift by the end of the run.
  The derived rate is used because it is self-consistent with the trigger data:
  it forces frame 0 -> window start and the last frame -> window end. Pass
  --imaging-rate to override if you have the true value from the microscope.
"""
from __future__ import annotations
import argparse, sys, re
from pathlib import Path

import numpy as np
import pandas as pd
import matplotlib
matplotlib.use("Agg")           # headless-safe; never calls plt.show()
import matplotlib as mpl
import matplotlib.pyplot as plt
from matplotlib.ticker import MaxNLocator
from scipy.ndimage import gaussian_filter1d
from scipy.io import loadmat

mpl.rcParams["font.family"] = "sans-serif"
mpl.rcParams["font.sans-serif"] = ["Arial", "Helvetica", "DejaVu Sans"]
mpl.rcParams["pdf.fonttype"] = 42

# colours matched to behaviour_panels.py so figures look like one family
C_PUPIL, C_WHISK, C_ACCEL = "blue", "orange", "purple"
ACCEL_YMAX = 0.25               # project-wide convention


def find_imaging_frames(run_dir: Path) -> tuple[int, str]:
    """Number of imaging frames, from whichever per-segment trace file exists."""
    for pat in ("*_segment_traces.csv", "*_seg01.csv", "*_seg*.csv"):
        for f in sorted(run_dir.glob(pat)):
            try:
                n = len(pd.read_csv(f, usecols=[0]))
                if n > 1:
                    return n, f.name
            except Exception:
                continue
    # No trace CSV (the new pipeline does not write one): read T straight from the
    # cleaned 4D stack's TIFF header, which is the authoritative frame count anyway.
    for stk in sorted(run_dir.glob("*_clean.tif")):
        if stk.name.endswith("_denoised.tif"):
            continue
        try:
            import tifffile
            shape = tifffile.TiffFile(str(stk)).series[0].shape
            if len(shape) == 4:
                return int(shape[0]), f"{stk.name} (T axis)"
        except Exception:
            continue
    raise SystemExit(f"ERROR: no per-segment trace CSV or 4D *_clean.tif in {run_dir} to count imaging frames")


def load_behaviour(project_root: Path, mouse: str, folder_date: str, base: str):
    beh = project_root / mouse / folder_date / "behavior" / f"{base}_behavior.csv"
    mat = project_root / mouse / folder_date / "behavior" / f"{base}_behavior.mat"
    if not beh.exists():
        raise SystemExit(f"ERROR: behaviour CSV not found: {beh}")
    b = pd.read_csv(beh)
    win = None
    if mat.exists():
        try:
            s = loadmat(mat)["settings"]
            w = s["imaging_window_s"][0][0].ravel()
            win = (float(w[0]), float(w[1]))
        except Exception:
            win = None
    return b, win, mat


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Behaviour companion figure on the coherence figure's imaging-frame axis.")
    ap.add_argument("--run-dir", required=True,
                    help="the preprocessed/<runN> directory holding *_clean_coherence.png")
    ap.add_argument("--mouse", required=True)
    ap.add_argument("--folder-date", required=True, help="e.g. 06-25-2026")
    ap.add_argument("--mat-date", required=True, help="e.g. 26-06-25")
    ap.add_argument("--run-id", required=True, help="e.g. Run007")
    ap.add_argument("--project-root", default="/Users/daria/Desktop/femtonics-data")
    ap.add_argument("--imaging-rate", type=float, default=None,
                    help="override the derived imaging frame rate (Hz)")
    ap.add_argument("--pupil-signal", choices=["raw", "smooth"], default="smooth")
    ap.add_argument("--out", default=None, help="output stem (default: alongside the coherence figure)")
    ap.add_argument("--formats", nargs="+", choices=["png", "pdf"], default=["png", "pdf"])
    ap.add_argument("--dpi", type=int, default=150)
    args = ap.parse_args()

    run_dir = Path(args.run_dir)
    if not run_dir.is_dir():
        raise SystemExit(f"ERROR: --run-dir does not exist: {run_dir}")
    root = Path(args.project_root)
    base = f"{args.mouse}_{args.mat_date}_{args.run_id}"

    n_img, src = find_imaging_frames(run_dir)
    b, win, mat = load_behaviour(root, args.mouse, args.folder_date, base)

    inw = b["in_imaging_window"] > 0.5
    if not inw.any():
        raise SystemExit("ERROR: no in-window behaviour samples")
    t_beh = b.loc[inw, "aligned_time_s"].to_numpy()

    span = (win[1] - win[0]) if win else (t_beh.max() - t_beh.min())
    rate = args.imaging_rate if args.imaging_rate else n_img / span
    print(f"imaging frames        : {n_img}  (from {src})")
    print(f"imaging window        : {span:.3f} s" + ("" if win else "  [from behaviour, no .mat]"))
    print(f"imaging rate used     : {rate:.4f} Hz" +
          ("  (--imaging-rate override)" if args.imaging_rate else "  (derived = frames/window)"))
    print(f"behaviour in-window   : {inw.sum()} samples, {t_beh.min():.2f}..{t_beh.max():.2f} s")

    # behaviour on the imaging-frame axis
    f_beh = t_beh * rate
    pcol = "pupil_smooth" if args.pupil_signal == "smooth" else "pupil_raw"
    pupil = gaussian_filter1d(b.loc[inw, pcol].to_numpy(), 2)
    whisk = gaussian_filter1d(b.loc[inw, "whisker_smooth_long"].to_numpy(), 3)

    # accelerometer, native rate, same mapping
    nnn = re.sub(r"\D", "", args.run_id).zfill(3)
    acc_csv = root / args.mouse / args.folder_date / "trigger" / f"Run{nnn}_t1_accel.csv"
    f_acc = acc = None
    if acc_csv.exists():
        a = pd.read_csv(acc_csv, usecols=["accel_mag", "aligned_time_s"])
        m = (a["aligned_time_s"] >= t_beh.min()) & (a["aligned_time_s"] <= t_beh.max())
        f_acc = a.loc[m, "aligned_time_s"].to_numpy() * rate
        acc = gaussian_filter1d(np.abs(a.loc[m, "accel_mag"].to_numpy()), 10)
        print(f"accelerometer         : {m.sum()} samples")
    else:
        print(f"accelerometer         : MISSING ({acc_csv.name}); panel omitted")

    # network events, coloured as in the coherence figure
    ev_files = list(run_dir.glob("*_coherence_network_events.csv"))
    ev = pd.read_csv(ev_files[0]) if ev_files else pd.DataFrame()
    if len(ev):
        print(f"network events         : {len(ev)} from {ev_files[0].name}")
        print("  lead_role counts    : " + ", ".join(f"{k}={v}" for k, v in
              ev['lead_role'].value_counts().items()))

    def ev_colour(role: str) -> str:
        r = str(role).lower()
        if "soma" in r:
            return "red"        # soma-led, matching the coherence figure
        if "branch" in r:
            return "blue"       # branch-led
        return "0.75"           # mid / other

    panels = [("Pupil", f_beh, pupil, C_PUPIL, (-0.05, 1.05)),
              ("Whisking", f_beh, whisk, C_WHISK, (-0.05, 1.05))]
    if acc is not None:
        panels.append(("Accelerometer", f_acc, acc, C_ACCEL, (0, ACCEL_YMAX)))

    fig, axes = plt.subplots(len(panels), 1, figsize=(13.5, 1.7 * len(panels)), sharex=True)
    if len(panels) == 1:
        axes = [axes]

    for ax, (label, x, y, colour, ylim) in zip(axes, panels):
        for _, r in ev.iterrows():
            ax.axvline(float(r["onset_frame"]), color=ev_colour(r["lead_role"]),
                       lw=0.8, alpha=0.55, zorder=1)
        ax.plot(x, y, color=colour, lw=1.4, zorder=3)
        ax.set_ylim(*ylim)
        ax.text(0.006, 0.93, label, transform=ax.transAxes, ha="left", va="top",
                color=colour, fontweight="bold", fontsize=15)
        ax.grid(False)
        ax.tick_params(labelsize=11)
        ax.spines["top"].set_visible(False)
        ax.spines["right"].set_visible(False)
        ax.yaxis.set_major_locator(MaxNLocator(nbins=3))

    axes[-1].set_xlabel("frame", fontsize=13)     # same label as the coherence figure
    axes[0].set_xlim(0, n_img)                    # same range, so the figures stack

    # seconds axis on top, for readers who want real time
    sec = axes[0].secondary_xaxis("top", functions=(lambda f: f / rate, lambda s: s * rate))
    sec.set_xlabel("time from imaging onset (s)", fontsize=11)
    sec.tick_params(labelsize=10)

    ttl = (f"{args.mouse}  {args.folder_date}  {args.run_id}   behaviour on the coherence frame axis\n"
           f"vlines = multi-segment network events (red = soma-led, blue = branch-led, grey = mid);  "
           f"imaging {rate:.3f} Hz")
    fig.suptitle(ttl, fontsize=11.5, y=1.02)
    plt.tight_layout(h_pad=0.35)

    stem = Path(args.out) if args.out else (run_dir / f"{run_dir.name}_clean_coherence_behavior")
    written = []
    for f in args.formats:
        p = stem.with_suffix(f".{f}")
        plt.savefig(p, dpi=args.dpi, bbox_inches="tight")
        written.append(p)
    plt.close(fig)
    for p in written:
        print(f"wrote {p}  ({p.stat().st_size/1024:.0f} KB)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
