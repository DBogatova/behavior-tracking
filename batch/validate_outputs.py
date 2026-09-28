#!/usr/bin/env python
"""validate_outputs.py -- correctness / QC validation for the behavior batch pipeline.

This is the CORRECTNESS-CHECKING gate of the (mostly) automatic behavior-processing
pipeline. It reads a batch output directory produced by ``run_behavior_batch.m``
(containing ``csv/``, ``mat/`` and ``batch_manifest.csv``) and independently
re-verifies that every artifact is internally consistent, schema-conformant, and
free of the known silent-degeneracy failure modes -- BEFORE the data is published
to the downstream analysis scripts. A scientist should be able to open the emitted
``qc_report.md`` and immediately see which runs to distrust and why.

Nothing here is trusted on faith: every check reports the OBSERVED VALUE, not just a
verdict, so "behavior fs = 9.998 Hz (expected ~10)" rather than "fs check passed".

--------------------------------------------------------------------------------
CHECKS (each row is graded PASS / WARN / FAIL)
--------------------------------------------------------------------------------
  1  artifacts      behavior CSV + .mat present & non-empty (FAIL if missing);
                    accel CSV present unless legitimately absent.
  2  schema         all required behavior columns present; accel columns present
                    AND in exact order (reorder=WARN; missing accel_mag or
                    aligned_time_s=FAIL because it silently breaks behavior_plots.py).
  3  alignment      aligned_time_s strictly increasing; aligned == time_s - t0 for a
                    single consistent t0 (reported); behavior t0 == accel t0 within one
                    behavior frame period (mismatch=FAIL); reports presence/absence of
                    negative (pre-trigger) times.
  4  sampling_rate  behavior fs ~10 Hz, accel fs ~1000 Hz, inferred from median diff;
                    deviation=WARN, wildly off=FAIL. Observed values always reported.
  5  frame_acct     n_kept + n_dropped == n_used; n_used <= n_frames; in_imaging_window
                    true-count == n_kept. Arithmetic inconsistency=FAIL.
  6  signal_sanity  per signal (pupil_raw, pupil_smooth, whisker_smooth_long,
                    whisker_smooth_pad, accel_mag): CONSTANT/near-constant (the known
                    silent degeneracy -> FAIL for pupil/whisker), all-NaN/excess NaN,
                    out-of-[0,1] for normalized signals, excess exact-zeros, saturation
                    at exactly 0 or 1.
  7  bins_sanity    pupil_bins / whisker_bins contain only {0,1}; on-fraction of 0% or
                    100% is WARN (bad auto-threshold).
  8  duration       behavior in-window duration vs accel in-window duration agree within
                    tolerance; large mismatch=FAIL.
  9  mat_csv        scipy.io.loadmat resolves BOTH downstream access paths
                    (pupil.pupil_raw, whisker.whisker_smooth_long) and the stored trace
                    length equals the behavior CSV in-window sample count. Any failure=FAIL.
 10  manifest       every status=ok row's declared outputs exist on disk; every non-empty
                    warnings cell surfaced; trigger_confidence 'unresolved' or
                    trigger_applied==0 reported as WARN (data unaligned).
 11  cross_run      within one mouse+date, outliers in fs / duration / pupil & whisker
                    dynamic range are flagged (WARN) -- usually a bad ROI or wrong trigger.

--------------------------------------------------------------------------------
OUTPUTS
--------------------------------------------------------------------------------
  * qc_report.csv  -- machine readable, ONE ROW PER (run, check):
                      run_id, base_name, mouse, date, check, severity, observed, message
  * qc_report.md   -- human readable: overall verdict, summary table, per-run detail.
  * console        -- N runs / N pass / N warn / N fail + failing runs with reasons.

--------------------------------------------------------------------------------
EXIT CODE CONTRACT (this gates an automated pipeline)
--------------------------------------------------------------------------------
  0  all runs PASS, or only WARNs and --strict was NOT given.
  1  at least one FAIL (or, with --strict, at least one WARN).
  2  the QC tool itself could not run: missing --out-dir, or a missing/unreadable
     batch_manifest.csv. (A single corrupt run does NOT cause exit 2 -- it becomes a
     FAIL row; only a tool-level inability to start does.)

Malformed input never crashes the tool: a corrupt CSV / unreadable .mat becomes a
FAIL row with a readable reason, not a traceback.
"""

from __future__ import annotations

import argparse
import csv as _csv
import sys
import traceback
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import numpy as np
import pandas as pd

try:
    from scipy.io import loadmat
    import scipy as _scipy
    _SCIPY_VER = _scipy.__version__
except Exception as exc:  # pragma: no cover - scipy is a hard requirement
    loadmat = None
    _SCIPY_VER = f"UNAVAILABLE ({exc})"


# ----------------------------------------------------------------------------
# ground-truth schemas (verified against export_behavior_csv.m / run_behavior_batch.m)
# ----------------------------------------------------------------------------
BEHAVIOR_COLUMNS = [
    "frame", "time_s", "aligned_time_s", "in_imaging_window",
    "pupil_raw", "pupil_smooth", "pupil_bins",
    "whisker_raw_long", "whisker_smooth_long",
    "whisker_raw_pad", "whisker_smooth_pad", "whisker_bins",
]
ACCEL_COLUMNS = [
    "sample", "accel_mag", "accX", "accY", "accZ", "time_s", "aligned_time_s",
]

# signals expected to be rescale01-normalized to [0,1] in the CSV
NORMALIZED_SIGNALS = [
    "pupil_raw", "pupil_smooth",
    "whisker_raw_long", "whisker_smooth_long",
    "whisker_raw_pad", "whisker_smooth_pad",
]
# signals whose constancy makes the run UNUSABLE (=> FAIL); accel constancy is WARN
CRITICAL_SIGNALS = {"pupil_raw", "pupil_smooth", "whisker_smooth_long", "whisker_smooth_pad"}

EXPECTED_BEHAVIOR_FS = 10.0
EXPECTED_ACCEL_FS = 1000.0

PASS, WARN, FAIL = "PASS", "WARN", "FAIL"
_RANK = {PASS: 0, WARN: 1, FAIL: 2}


def worst(severities) -> str:
    """Return the highest-rank severity among the inputs (default PASS)."""
    s = list(severities)
    if not s:
        return PASS
    return max(s, key=lambda x: _RANK.get(x, 0))


@dataclass
class Tolerances:
    """Tunable thresholds. ``--tolerance`` scales the fractional (fs/duration) knobs."""
    fs_pass_frac: float = 0.05        # within 5% of expected fs => PASS
    fs_warn_frac: float = 0.50        # within 50% => WARN, beyond => FAIL
    duration_frac: float = 0.05       # in-window duration agreement (fractional)
    duration_abs_s: float = 0.5       # ...or this absolute floor (seconds)
    t0_consistency_s: float = 1e-6    # spread of (time_s - aligned_time_s) within a CSV
    near_constant_std: float = 1e-3   # std below this (but >0) => near-constant
    nan_frac_warn: float = 0.02       # NaN fraction above this => WARN
    nan_frac_fail: float = 0.90       # NaN fraction above this => FAIL (critical signals)
    zero_frac_warn: float = 0.90      # exact-zero fraction above this => WARN
    saturation_frac_warn: float = 0.50  # fraction pinned at exactly 0 or 1 => WARN
    range_tol: float = 0.02           # allowed slack outside [0,1]
    range_fail_slack: float = 0.50    # beyond [0-slack, 1+slack] => FAIL (schema-level)
    outlier_mad_k: float = 5.0        # robust MAD multiplier for cross-run outliers
    outlier_rel: float = 0.25         # ...or fractional deviation floor

    def scaled(self, factor: float) -> "Tolerances":
        if factor is None or factor <= 0:
            return self
        return Tolerances(
            fs_pass_frac=self.fs_pass_frac * factor,
            fs_warn_frac=min(0.99, self.fs_warn_frac * factor),
            duration_frac=self.duration_frac * factor,
            duration_abs_s=self.duration_abs_s * factor,
            t0_consistency_s=self.t0_consistency_s,
            near_constant_std=self.near_constant_std,
            nan_frac_warn=self.nan_frac_warn,
            nan_frac_fail=self.nan_frac_fail,
            zero_frac_warn=self.zero_frac_warn,
            saturation_frac_warn=self.saturation_frac_warn,
            range_tol=self.range_tol,
            range_fail_slack=self.range_fail_slack,
            outlier_mad_k=self.outlier_mad_k,
            outlier_rel=self.outlier_rel,
        )


@dataclass
class CheckResult:
    check: str
    severity: str
    observed: str
    message: str


@dataclass
class RunReport:
    base_name: str
    run_id: str = ""
    mouse: str = ""
    date: str = ""
    status: str = ""
    results: list = field(default_factory=list)
    metrics: dict = field(default_factory=dict)  # for cross-run consistency

    def add(self, check: str, severity: str, observed: Any = "", message: str = "") -> None:
        self.results.append(CheckResult(check, severity, _fmt(observed), message))

    @property
    def verdict(self) -> str:
        return worst(r.severity for r in self.results)

    def counts(self):
        c = {PASS: 0, WARN: 0, FAIL: 0}
        for r in self.results:
            c[r.severity] = c.get(r.severity, 0) + 1
        return c

    def reasons(self, sev: str):
        return [f"{r.check}: {r.message}" for r in self.results if r.severity == sev]


# ----------------------------------------------------------------------------
# small formatting / numeric helpers
# ----------------------------------------------------------------------------
def _fmt(x: Any) -> str:
    if isinstance(x, float):
        if np.isnan(x):
            return "nan"
        return f"{x:.6g}"
    return str(x)


def _num(x, default=np.nan) -> float:
    try:
        if x is None:
            return default
        if isinstance(x, str) and x.strip() == "":
            return default
        v = float(x)
        return v
    except (TypeError, ValueError):
        return default


def signal_stats(values: np.ndarray) -> dict:
    """Robust descriptive stats for a 1-D signal, tolerant of NaN/empty."""
    a = np.asarray(values, dtype=float).ravel()
    n = a.size
    finite = a[np.isfinite(a)]
    nf = finite.size
    out = {
        "n": n, "n_finite": nf,
        "nan_frac": (n - nf) / n if n else 1.0,
        "min": float(np.min(finite)) if nf else np.nan,
        "max": float(np.max(finite)) if nf else np.nan,
        "std": float(np.std(finite)) if nf else np.nan,
        "ptp": float(np.ptp(finite)) if nf else np.nan,
        "n_unique": int(np.unique(finite).size) if nf else 0,
        "zero_frac": float(np.mean(finite == 0.0)) if nf else np.nan,
        "sat0_frac": float(np.mean(finite == 0.0)) if nf else np.nan,
        "sat1_frac": float(np.mean(finite == 1.0)) if nf else np.nan,
    }
    return out


def infer_fs(time_s: np.ndarray):
    """Infer sampling rate from the median positive diff of a time vector."""
    t = np.asarray(time_s, dtype=float).ravel()
    t = t[np.isfinite(t)]
    if t.size < 2:
        return np.nan, np.nan
    d = np.diff(t)
    d = d[np.isfinite(d)]
    if d.size == 0:
        return np.nan, np.nan
    dt = float(np.median(d))
    fs = 1.0 / dt if dt > 0 else np.nan
    return fs, dt


# ----------------------------------------------------------------------------
# artifact resolution
# ----------------------------------------------------------------------------
def resolve_artifact(declared: str, out_dir: Path, base_name: str, kind: str):
    """Locate an artifact on disk.

    The validator must validate the directory it is POINTED AT, so the canonical
    local layout (out_dir/csv, out_dir/mat) is tried FIRST. Manifest ``declared``
    paths are frequently *cluster* absolute paths (e.g. /projectnb/...) that either
    do not exist locally or point at a stale copy, so they are only a fallback.
    Returns a Path if found, else None.
    """
    subdir = "mat" if kind == "mat" else "csv"
    suffix = {"behavior": "_behavior.csv", "accel": "_accel.csv",
              "mat": "_behavior.mat"}[kind]
    candidates = [out_dir / subdir / f"{base_name}{suffix}"]  # canonical local first
    if declared:
        p = Path(declared)
        candidates.append(out_dir / subdir / p.name)          # declared basename, local
        candidates.append(p)                                  # literal declared path last
    for c in candidates:
        try:
            if c.is_file():
                return c
        except OSError:
            continue
    return None


def nonempty(path: Path) -> bool:
    try:
        return path.is_file() and path.stat().st_size > 0
    except OSError:
        return False


# ----------------------------------------------------------------------------
# manifest
# ----------------------------------------------------------------------------
def load_manifest(out_dir: Path):
    """Load batch_manifest.csv into a list of dict rows. Raises on unreadable file."""
    mpath = out_dir / "batch_manifest.csv"
    if not mpath.is_file():
        raise FileNotFoundError(f"manifest not found: {mpath}")
    df = pd.read_csv(mpath, dtype=str, keep_default_na=False)
    rows = df.to_dict(orient="records")
    return rows, list(df.columns)


# ============================================================================
# per-run checks
# ============================================================================
def check_run(row: dict, out_dir: Path, tol: Tolerances) -> RunReport:
    base = (row.get("base_name") or "").strip()
    if not base:
        base = (row.get("run_id") or "run").strip()
    rep = RunReport(
        base_name=base,
        run_id=(row.get("run_id") or "").strip(),
        mouse=(row.get("mouse") or "").strip(),
        date=(row.get("date") or "").strip(),
        status=(row.get("status") or "").strip().lower(),
    )

    # runs the writer itself marked failed: surface, don't deep-validate absent outputs
    if rep.status == "failed":
        rep.add("manifest", WARN, "status=failed",
                f"writer reported FAILED: {row.get('message', '')}".strip())
        return rep

    # -- resolve artifacts -----------------------------------------------------
    beh_path = resolve_artifact(row.get("behavior_csv", ""), out_dir, base, "behavior")
    mat_path = resolve_artifact(row.get("mat_path", ""), out_dir, base, "mat")
    accel_declared = (row.get("accel_csv") or "").strip()
    accel_path = resolve_artifact(accel_declared, out_dir, base, "accel")

    # 1) ARTIFACT PRESENCE -----------------------------------------------------
    if beh_path and nonempty(beh_path):
        rep.add("artifacts", PASS, beh_path.name, "behavior CSV present & non-empty")
    else:
        rep.add("artifacts", FAIL, str(beh_path or row.get("behavior_csv", "")),
                "behavior CSV missing or empty")
    if mat_path and nonempty(mat_path):
        rep.add("artifacts", PASS, mat_path.name, ".mat present & non-empty")
    else:
        rep.add("artifacts", FAIL, str(mat_path or row.get("mat_path", "")),
                ".mat missing or empty")
    if accel_path and nonempty(accel_path):
        rep.add("artifacts", PASS, accel_path.name, "accel CSV present & non-empty")
    elif accel_declared:
        rep.add("artifacts", FAIL, accel_declared,
                "accel CSV declared in manifest but missing/empty on disk")
    else:
        rep.add("artifacts", WARN, "(none)",
                "accel CSV absent (may be legitimate: no accelerometer channels in trigger MAT)")

    # -- load behavior CSV -----------------------------------------------------
    beh = None
    if beh_path and nonempty(beh_path):
        try:
            beh = pd.read_csv(beh_path)
        except Exception as exc:
            rep.add("schema", FAIL, beh_path.name,
                    f"behavior CSV unreadable: {type(exc).__name__}: {exc}")
            beh = None

    accel = None
    if accel_path and nonempty(accel_path):
        try:
            accel = pd.read_csv(accel_path)
        except Exception as exc:
            rep.add("schema", FAIL, accel_path.name,
                    f"accel CSV unreadable: {type(exc).__name__}: {exc}")
            accel = None

    # 2) SCHEMA CONFORMANCE ----------------------------------------------------
    if beh is not None:
        missing = [c for c in BEHAVIOR_COLUMNS if c not in beh.columns]
        if missing:
            rep.add("schema", FAIL, f"missing={missing}",
                    "behavior CSV missing required column(s)")
        else:
            order_ok = list(beh.columns[:len(BEHAVIOR_COLUMNS)]) == BEHAVIOR_COLUMNS
            extra = [c for c in beh.columns if c not in BEHAVIOR_COLUMNS]
            msg = "all required behavior columns present"
            if not order_ok:
                msg += " (order differs from canonical)"
            if extra:
                msg += f"; extra columns {extra}"
            rep.add("schema", PASS if order_ok else WARN,
                    f"n_cols={len(beh.columns)}", msg)

    if accel is not None:
        cols = list(accel.columns)
        if cols == ACCEL_COLUMNS:
            rep.add("schema", PASS, "exact order", "accel columns present in exact order")
        else:
            missing = [c for c in ACCEL_COLUMNS if c not in cols]
            if "accel_mag" in missing or "aligned_time_s" in missing:
                rep.add("schema", FAIL, f"cols={cols}",
                        "accel schema breaks behavior_plots.py: accel_mag/aligned_time_s "
                        f"missing or renamed (missing={missing})")
            elif set(cols) == set(ACCEL_COLUMNS):
                rep.add("schema", WARN, f"cols={cols}",
                        "accel columns present but REORDERED vs canonical order")
            else:
                rep.add("schema", WARN, f"cols={cols}",
                        f"accel columns differ (missing={missing})")

    # 3) ALIGNMENT INTEGRITY ---------------------------------------------------
    beh_t0 = np.nan
    beh_fs = np.nan
    if beh is not None and {"time_s", "aligned_time_s"}.issubset(beh.columns):
        beh_t0 = _alignment_check(rep, beh, "behavior", tol)
        beh_fs, _ = infer_fs(beh["time_s"].to_numpy())

    accel_t0 = np.nan
    if accel is not None and {"time_s", "aligned_time_s"}.issubset(accel.columns):
        accel_t0 = _alignment_check(rep, accel, "accel", tol)

    if np.isfinite(beh_t0) and np.isfinite(accel_t0):
        frame_period = 1.0 / beh_fs if (np.isfinite(beh_fs) and beh_fs > 0) else (1.0 / EXPECTED_BEHAVIOR_FS)
        dt0 = abs(beh_t0 - accel_t0)
        if dt0 <= frame_period:
            rep.add("alignment", PASS,
                    f"|dt0|={dt0:.6g}s (<= {frame_period:.4g}s)",
                    f"behavior t0 ({beh_t0:.6g}s) and accel t0 ({accel_t0:.6g}s) agree")
        else:
            rep.add("alignment", FAIL,
                    f"|dt0|={dt0:.6g}s (> {frame_period:.4g}s)",
                    f"t0 MISMATCH: behavior t0={beh_t0:.6g}s vs accel t0={accel_t0:.6g}s "
                    "-- the two streams disagree about time zero")

    # 4) SAMPLING RATE ---------------------------------------------------------
    if beh is not None and "time_s" in beh.columns:
        _fs_check(rep, beh["time_s"].to_numpy(), EXPECTED_BEHAVIOR_FS, "behavior", tol)
    if accel is not None and "time_s" in accel.columns:
        _fs_check(rep, accel["time_s"].to_numpy(), EXPECTED_ACCEL_FS, "accel", tol)

    # 5) FRAME ACCOUNTING ------------------------------------------------------
    n_frames = _num(row.get("n_frames"))
    n_used = _num(row.get("n_used"))
    n_kept = _num(row.get("n_kept"))
    n_dropped = _num(row.get("n_dropped"))
    in_win_count = np.nan
    if beh is not None and "in_imaging_window" in beh.columns:
        in_win_count = float((beh["in_imaging_window"].to_numpy(dtype=float) > 0.5).sum())
    _frame_accounting(rep, n_frames, n_used, n_kept, n_dropped, in_win_count)

    # 6) SIGNAL SANITY ---------------------------------------------------------
    if beh is not None:
        for name in ["pupil_raw", "pupil_smooth", "whisker_smooth_long", "whisker_smooth_pad"]:
            if name in beh.columns:
                _signal_sanity(rep, name, beh[name].to_numpy(dtype=float),
                               normalized=True, critical=(name in CRITICAL_SIGNALS), tol=tol)
    if accel is not None and "accel_mag" in accel.columns:
        _signal_sanity(rep, "accel_mag", accel["accel_mag"].to_numpy(dtype=float),
                       normalized=False, critical=False, tol=tol)

    # 7) BINS SANITY -----------------------------------------------------------
    if beh is not None:
        for name in ["pupil_bins", "whisker_bins"]:
            if name in beh.columns:
                _bins_sanity(rep, name, beh[name].to_numpy(dtype=float))

    # 8) DURATION CONSISTENCY --------------------------------------------------
    if beh is not None and accel is not None:
        _duration_consistency(rep, beh, accel, tol)

    # 9) MAT / CSV CROSS-CHECK -------------------------------------------------
    if mat_path and nonempty(mat_path):
        csv_row_count = float(len(beh)) if beh is not None else float("nan")
        # crop_to_window may be absent in manifests written before the option
        # existed; _num yields NaN and the check falls back to legacy behavior.
        _mat_csv_crosscheck(rep, mat_path, in_win_count,
                            csv_row_count, _num(row.get("crop_to_window")))
    else:
        rep.add("mat_csv", FAIL, "(no .mat)", "cannot cross-check: .mat missing")

    # 10) MANIFEST CROSS-CHECK -------------------------------------------------
    _manifest_crosscheck(rep, row, beh_path, mat_path, accel_path, accel_declared)

    # collect metrics for cross-run consistency (11) ---------------------------
    rep.metrics["behavior_fs"] = beh_fs
    if beh is not None and {"aligned_time_s", "in_imaging_window"}.issubset(beh.columns):
        m = beh["in_imaging_window"].to_numpy(dtype=float) > 0.5
        at = beh["aligned_time_s"].to_numpy(dtype=float)[m]
        at = at[np.isfinite(at)]
        rep.metrics["duration"] = float(at.max() - at.min()) if at.size >= 2 else np.nan
        for sig in ["pupil_smooth", "whisker_smooth_long"]:
            if sig in beh.columns:
                v = beh[sig].to_numpy(dtype=float)[m]
                v = v[np.isfinite(v)]
                rep.metrics[f"{sig}_range"] = float(np.ptp(v)) if v.size else np.nan

    return rep


def _alignment_check(rep: RunReport, df: pd.DataFrame, label: str, tol: Tolerances) -> float:
    """Return inferred t0 (time_s - aligned_time_s). Emits alignment CheckResults."""
    time_s = df["time_s"].to_numpy(dtype=float)
    aligned = df["aligned_time_s"].to_numpy(dtype=float)
    fin = np.isfinite(time_s) & np.isfinite(aligned)
    if fin.sum() < 2:
        rep.add("alignment", FAIL, f"{label}: n_finite={int(fin.sum())}",
                f"{label}: too few finite time samples to validate alignment")
        return np.nan

    a = aligned[fin]
    # strictly increasing?
    d = np.diff(a)
    if np.all(d > 0):
        rep.add("alignment", PASS, f"{label}: min_step={d.min():.4g}s",
                f"{label} aligned_time_s strictly increasing")
    else:
        bad = int(np.sum(d <= 0))
        first = int(np.argmax(d <= 0))
        rep.add("alignment", FAIL,
                f"{label}: {bad} non-positive step(s), first at idx {first}",
                f"{label} aligned_time_s NOT strictly increasing "
                f"(step={d[first]:.4g}s at index {first})")

    # single consistent t0?
    t0_vec = time_s[fin] - a
    t0 = float(np.median(t0_vec))
    spread = float(np.ptp(t0_vec))
    if spread <= tol.t0_consistency_s:
        rep.add("alignment", PASS, f"{label}: t0={t0:.6g}s, spread={spread:.2e}s",
                f"{label}: aligned_time_s == time_s - t0 for a single t0={t0:.6g}s")
    else:
        rep.add("alignment", FAIL, f"{label}: t0~{t0:.6g}s, spread={spread:.4g}s",
                f"{label}: aligned_time_s != time_s - const; t0 varies by {spread:.4g}s "
                f"(> {tol.t0_consistency_s:.1g}s) -- inconsistent alignment")

    # negative (pre-trigger) times present?
    amin = float(a.min())
    if amin < 0:
        rep.add("alignment", PASS, f"{label}: min_aligned={amin:.4g}s",
                f"{label}: negative aligned times present (recording began before trigger t0)")
    else:
        rep.add("alignment", PASS, f"{label}: min_aligned={amin:.4g}s",
                f"{label}: no negative aligned times -- recording started at/after the trigger")
    return t0


def _fs_check(rep: RunReport, time_s: np.ndarray, expected: float, label: str, tol: Tolerances):
    fs, dt = infer_fs(time_s)
    if not np.isfinite(fs):
        rep.add("sampling_rate", FAIL, f"{label}: fs=nan",
                f"{label}: cannot infer sampling rate (need >=2 finite, increasing samples)")
        return
    rel = abs(fs - expected) / expected
    obs = f"{label} fs={fs:.4f} Hz (dt={dt:.6g}s, expected ~{expected:g})"
    if rel <= tol.fs_pass_frac:
        rep.add("sampling_rate", PASS, obs, f"{label} sampling rate within {tol.fs_pass_frac:.0%}")
    elif rel <= tol.fs_warn_frac:
        rep.add("sampling_rate", WARN, obs,
                f"{label} sampling rate off by {rel:.1%} (expected ~{expected:g} Hz)")
    else:
        rep.add("sampling_rate", FAIL, obs,
                f"{label} sampling rate wildly off by {rel:.1%} (expected ~{expected:g} Hz)")


def _frame_accounting(rep, n_frames, n_used, n_kept, n_dropped, in_win_count):
    obs = (f"n_frames={_fmt(n_frames)}, n_used={_fmt(n_used)}, n_kept={_fmt(n_kept)}, "
           f"n_dropped={_fmt(n_dropped)}, in_window_true={_fmt(in_win_count)}")

    # n_kept + n_dropped == n_used
    if np.isfinite(n_kept) and np.isfinite(n_dropped) and np.isfinite(n_used):
        if abs((n_kept + n_dropped) - n_used) < 0.5:
            rep.add("frame_acct", PASS, obs, "n_kept + n_dropped == n_used")
        else:
            rep.add("frame_acct", FAIL, obs,
                    f"arithmetic broken: n_kept+n_dropped={n_kept + n_dropped:g} != n_used={n_used:g}")
    else:
        rep.add("frame_acct", WARN, obs,
                "n_kept/n_dropped/n_used not all present (likely unaligned/degraded run)")

    # n_used <= n_frames
    if np.isfinite(n_used) and np.isfinite(n_frames):
        if n_used <= n_frames + 0.5:
            rep.add("frame_acct", PASS, f"n_used={_fmt(n_used)} <= n_frames={_fmt(n_frames)}",
                    "n_used <= n_frames")
        else:
            rep.add("frame_acct", FAIL, f"n_used={_fmt(n_used)} > n_frames={_fmt(n_frames)}",
                    "n_used exceeds n_frames (impossible: used more frames than exist)")

    # in_imaging_window true-count == n_kept
    if np.isfinite(in_win_count) and np.isfinite(n_kept):
        if abs(in_win_count - n_kept) < 0.5:
            rep.add("frame_acct", PASS,
                    f"in_window_true={_fmt(in_win_count)} == n_kept={_fmt(n_kept)}",
                    "in_imaging_window true-count matches n_kept")
        else:
            rep.add("frame_acct", FAIL,
                    f"in_window_true={_fmt(in_win_count)} != n_kept={_fmt(n_kept)}",
                    "in_imaging_window true-count disagrees with manifest n_kept")


def _signal_sanity(rep, name, values, normalized, critical, tol: Tolerances):
    s = signal_stats(values)
    obs = (f"{name}: n={s['n']}, nan={s['nan_frac']:.2%}, std={_fmt(s['std'])}, "
           f"range=[{_fmt(s['min'])},{_fmt(s['max'])}], uniq={s['n_unique']}, "
           f"zero={_fmt(s['zero_frac'])}, sat1={_fmt(s['sat1_frac'])}")

    # all-NaN
    if s["n_finite"] == 0:
        sev = FAIL if critical else WARN
        rep.add("signal_sanity", sev, obs, f"{name} is ALL-NaN (no finite samples)")
        return

    # CONSTANT / near-constant (the known silent-degeneracy failure)
    if s["n_unique"] <= 1 or s["std"] == 0.0 or s["ptp"] == 0.0:
        sev = FAIL if (critical or normalized) else WARN
        detail = "all zeros" if (s["min"] == 0 and s["max"] == 0) else f"constant value={_fmt(s['min'])}"
        rep.add("signal_sanity", sev, obs,
                f"{name} is CONSTANT ({detail}) -- silent degeneracy, data unusable")
    elif np.isfinite(s["std"]) and s["std"] < tol.near_constant_std:
        sev = FAIL if critical else WARN
        rep.add("signal_sanity", sev, obs,
                f"{name} is NEAR-CONSTANT (std={s['std']:.3g} < {tol.near_constant_std:g})")
    else:
        rep.add("signal_sanity", PASS, obs, f"{name} varies (std={s['std']:.3g})")

    # excessive NaN
    if s["nan_frac"] >= tol.nan_frac_fail and critical:
        rep.add("signal_sanity", FAIL, obs,
                f"{name} NaN fraction {s['nan_frac']:.1%} >= {tol.nan_frac_fail:.0%}")
    elif s["nan_frac"] > tol.nan_frac_warn:
        rep.add("signal_sanity", WARN, obs,
                f"{name} elevated NaN fraction {s['nan_frac']:.1%} (> {tol.nan_frac_warn:.0%})")

    # range for normalized signals
    if normalized and np.isfinite(s["min"]) and np.isfinite(s["max"]):
        lo, hi = s["min"], s["max"]
        if lo < -tol.range_fail_slack or hi > 1 + tol.range_fail_slack:
            rep.add("signal_sanity", FAIL, obs,
                    f"{name} grossly outside [0,1]: range=[{lo:.3g},{hi:.3g}] "
                    "-- likely wrong/renamed column")
        elif lo < -tol.range_tol or hi > 1 + tol.range_tol:
            rep.add("signal_sanity", WARN, obs,
                    f"{name} slightly outside [0,1]: range=[{lo:.3g},{hi:.3g}]")

    # excessive exact zeros / saturation
    if np.isfinite(s["zero_frac"]) and s["zero_frac"] > tol.zero_frac_warn and not (
        s["n_unique"] <= 1
    ):
        rep.add("signal_sanity", WARN, obs,
                f"{name} is {s['zero_frac']:.1%} exact zeros (> {tol.zero_frac_warn:.0%})")
    if np.isfinite(s["sat1_frac"]) and s["sat1_frac"] > tol.saturation_frac_warn:
        rep.add("signal_sanity", WARN, obs,
                f"{name} saturates at exactly 1 for {s['sat1_frac']:.1%} of samples")


def _bins_sanity(rep, name, values):
    a = np.asarray(values, dtype=float).ravel()
    finite = a[np.isfinite(a)]
    if finite.size == 0:
        rep.add("bins_sanity", WARN, f"{name}: all-NaN", f"{name} has no finite samples")
        return
    uniq = np.unique(finite)
    non_binary = uniq[(uniq != 0.0) & (uniq != 1.0)]
    on_frac = float(np.mean(finite == 1.0))
    uniq_disp = [float(x) for x in uniq[:6]]
    nonbin_disp = [float(x) for x in non_binary[:6]]
    obs = f"{name}: on_frac={on_frac:.2%}, unique={uniq_disp}"
    if non_binary.size > 0:
        rep.add("bins_sanity", FAIL, obs,
                f"{name} contains non-binary values {nonbin_disp}")
        return
    if on_frac == 0.0 or on_frac == 1.0:
        rep.add("bins_sanity", WARN, obs,
                f"{name} degenerate on-fraction {on_frac:.0%} -- bad auto-threshold")
    else:
        rep.add("bins_sanity", PASS, obs, f"{name} is binary with on-fraction {on_frac:.1%}")


def _duration_consistency(rep, beh, accel, tol: Tolerances):
    need_b = {"aligned_time_s", "in_imaging_window"}.issubset(beh.columns)
    need_a = "aligned_time_s" in accel.columns
    if not (need_b and need_a):
        rep.add("duration", WARN, "missing columns",
                "cannot compare durations (missing aligned_time_s / in_imaging_window)")
        return
    m = beh["in_imaging_window"].to_numpy(dtype=float) > 0.5
    bt = beh["aligned_time_s"].to_numpy(dtype=float)[m]
    bt = bt[np.isfinite(bt)]
    if bt.size < 2:
        rep.add("duration", WARN, f"behavior in-window n={bt.size}",
                "too few in-window behavior samples to measure duration")
        return
    t_lo, t_hi = float(bt.min()), float(bt.max())
    beh_dur = t_hi - t_lo

    at = accel["aligned_time_s"].to_numpy(dtype=float)
    at = at[np.isfinite(at)]
    inwin = at[(at >= t_lo) & (at <= t_hi)]
    accel_dur = float(inwin.max() - inwin.min()) if inwin.size >= 2 else 0.0

    diff = abs(beh_dur - accel_dur)
    allow = max(tol.duration_abs_s, tol.duration_frac * beh_dur)
    obs = f"behavior_in_window={beh_dur:.4g}s, accel_in_window={accel_dur:.4g}s, |diff|={diff:.4g}s"
    if diff <= allow:
        rep.add("duration", PASS, obs, f"in-window durations agree within {allow:.3g}s")
    else:
        rep.add("duration", FAIL, obs,
                f"in-window duration mismatch |{diff:.4g}s| > {allow:.3g}s "
                "-- behavior and accel cover different spans")


def _mat_csv_crosscheck(rep, mat_path: Path, in_win_count: float,
                        csv_row_count: float = float("nan"),
                        crop_to_window: float = float("nan")):
    if loadmat is None:
        rep.add("mat_csv", FAIL, "scipy unavailable", f"scipy.io.loadmat not importable: {_SCIPY_VER}")
        return
    try:
        mat = loadmat(str(mat_path))
    except Exception as exc:
        rep.add("mat_csv", FAIL, mat_path.name,
                f".mat unreadable by scipy.io.loadmat ({type(exc).__name__}: {exc}) "
                "-- breaks downstream analysis")
        return

    # exact downstream access paths
    try:
        pupil_raw = np.asarray(mat["pupil"]["pupil_raw"][0][0]).ravel()
    except Exception as exc:
        rep.add("mat_csv", FAIL, mat_path.name,
                f"downstream path mat['pupil']['pupil_raw'][0][0] failed: {type(exc).__name__}: {exc}")
        pupil_raw = None
    try:
        whisker = np.asarray(mat["whisker"]["whisker_smooth_long"][0][0]).ravel()
    except Exception as exc:
        rep.add("mat_csv", FAIL, mat_path.name,
                f"downstream path mat['whisker']['whisker_smooth_long'][0][0] failed: "
                f"{type(exc).__name__}: {exc}")
        whisker = None

    if pupil_raw is None or whisker is None:
        return

    obs = (f"mat pupil_raw len={pupil_raw.size}, whisker_smooth_long len={whisker.size}, "
           f"csv in_window_count={_fmt(in_win_count)}, csv_rows={_fmt(csv_row_count)}, "
           f"crop_to_window={_fmt(crop_to_window)}")
    if pupil_raw.size != whisker.size:
        rep.add("mat_csv", FAIL, obs,
                f".mat pupil ({pupil_raw.size}) and whisker ({whisker.size}) lengths differ")
        return

    # Which length SHOULD the .mat hold? It depends on the crop mode recorded
    # in the manifest:
    #   crop_to_window = 1  -> traces were cropped, so expect the in-window count
    #   crop_to_window = 0  -> traces are full length, so expect the CSV row count
    # Defaulting to the in-window count keeps older manifests (which predate the
    # crop_to_window column) validating exactly as before.
    if crop_to_window == 0:
        expected = csv_row_count
        expected_label = "CSV total row count (crop_to_window=0, full-length .mat)"
    else:
        expected = in_win_count
        expected_label = "CSV in-window count (crop_to_window=1, cropped .mat)"

    if not np.isfinite(expected):
        rep.add("mat_csv", WARN, obs,
                f"both downstream paths resolve, but {expected_label} unavailable to compare")
        return

    if abs(pupil_raw.size - expected) < 0.5:
        rep.add("mat_csv", PASS, obs,
                f"both downstream access paths resolve; stored length == {expected_label}")
    else:
        rep.add("mat_csv", FAIL, obs,
                f".mat stored trace length {pupil_raw.size} != {expected_label} "
                f"{int(expected)} -- downstream will mis-slice")


def _manifest_crosscheck(rep, row, beh_path, mat_path, accel_path, accel_declared):
    status = (row.get("status") or "").strip().lower()

    # declared outputs exist for ok/skipped rows
    if status in ("ok", "skipped"):
        missing = []
        if not (beh_path and nonempty(beh_path)):
            missing.append("behavior_csv")
        if not (mat_path and nonempty(mat_path)):
            missing.append("mat_path")
        if accel_declared and not (accel_path and nonempty(accel_path)):
            missing.append("accel_csv")
        if missing:
            rep.add("manifest", FAIL, f"status={status}, missing={missing}",
                    f"manifest status={status} but declared output(s) absent: {missing}")
        else:
            rep.add("manifest", PASS, f"status={status}",
                    "all declared outputs present on disk")

    # surface non-empty warnings
    warns = (row.get("warnings") or "").strip()
    if warns:
        rep.add("manifest", WARN, "warnings cell",
                f"manifest warnings: {warns}")

    # trigger confidence / applied
    conf = (row.get("trigger_confidence") or "").strip().lower()
    applied = _num(row.get("trigger_applied"))
    if conf == "unresolved":
        rep.add("manifest", WARN, f"trigger_confidence={conf}",
                "trigger channels UNRESOLVED -- data is not trigger-aligned")
    if np.isfinite(applied) and applied == 0:
        rep.add("manifest", WARN, "trigger_applied=0",
                "trigger alignment NOT applied -- aligned_time_s is a fallback timebase")


# ============================================================================
# cross-run consistency (check 11)
# ============================================================================
def cross_run_consistency(reports, tol: Tolerances):
    groups = {}
    for rep in reports:
        if rep.status == "failed":
            continue
        groups.setdefault((rep.mouse, rep.date), []).append(rep)

    metric_labels = {
        "behavior_fs": "behavior fs (Hz)",
        "duration": "in-window duration (s)",
        "pupil_smooth_range": "pupil dynamic range",
        "whisker_smooth_long_range": "whisker dynamic range",
    }

    for (mouse, date), members in groups.items():
        if len(members) < 3:
            for rep in members:
                rep.add("cross_run", PASS,
                        f"group ({mouse},{date}) n={len(members)}",
                        "insufficient runs (<3) in mouse+date family for outlier detection")
            continue
        for key, label in metric_labels.items():
            vals = np.array([rep.metrics.get(key, np.nan) for rep in members], dtype=float)
            fin = np.isfinite(vals)
            if fin.sum() < 3:
                continue
            med = float(np.median(vals[fin]))
            mad = float(np.median(np.abs(vals[fin] - med)))
            thresh = max(tol.outlier_mad_k * 1.4826 * mad, tol.outlier_rel * abs(med), 1e-9)
            for rep in members:
                v = rep.metrics.get(key, np.nan)
                if not np.isfinite(v):
                    continue
                dev = abs(v - med)
                if dev > thresh:
                    rep.add("cross_run", WARN,
                            f"{label}={v:.4g} vs family median {med:.4g} (dev={dev:.4g})",
                            f"{label} is an OUTLIER within mouse={mouse} date={date} "
                            "-- possible bad ROI or wrong trigger file")
                else:
                    rep.add("cross_run", PASS,
                            f"{label}={v:.4g} (median {med:.4g})",
                            f"{label} consistent with mouse+date family")


# ============================================================================
# reporting
# ============================================================================
def write_csv_report(path: Path, reports):
    with open(path, "w", newline="") as f:
        w = _csv.writer(f)
        w.writerow(["run_id", "base_name", "mouse", "date", "run_verdict",
                    "check", "severity", "observed", "message"])
        for rep in reports:
            v = rep.verdict
            if not rep.results:
                w.writerow([rep.run_id, rep.base_name, rep.mouse, rep.date, v,
                            "(none)", PASS, "", "no checks produced"])
            for r in rep.results:
                w.writerow([rep.run_id, rep.base_name, rep.mouse, rep.date, v,
                            r.check, r.severity, r.observed, r.message])


_BADGE = {PASS: "PASS", WARN: "WARN", FAIL: "FAIL"}


def write_md_report(path: Path, reports, overall, tol: Tolerances, out_dir: Path):
    n = len(reports)
    npass = sum(1 for r in reports if r.verdict == PASS)
    nwarn = sum(1 for r in reports if r.verdict == WARN)
    nfail = sum(1 for r in reports if r.verdict == FAIL)

    lines = []
    lines.append("# Behavior pipeline QC report")
    lines.append("")
    lines.append(f"**OVERALL VERDICT: {overall}**")
    lines.append("")
    lines.append(f"- Output directory: `{out_dir}`")
    lines.append(f"- Runs checked: **{n}**  |  PASS: **{npass}**  |  WARN: **{nwarn}**  |  FAIL: **{nfail}**")
    lines.append(f"- numpy {np.__version__}, pandas {pd.__version__}, scipy {_SCIPY_VER}")
    lines.append("")
    if nfail:
        lines.append("> :x: **Do not trust the FAIL runs.** See per-run detail below.")
    elif nwarn:
        lines.append("> :warning: All runs usable, but WARN runs merit a look before publishing.")
    else:
        lines.append("> :white_check_mark: All runs passed every check.")
    lines.append("")

    # summary table
    lines.append("## Summary")
    lines.append("")
    lines.append("| Run | Verdict | FAIL | WARN | Top reasons |")
    lines.append("|-----|---------|------|------|-------------|")
    for rep in reports:
        c = rep.counts()
        reasons = rep.reasons(FAIL) or rep.reasons(WARN)
        top = "; ".join(reasons[:2]) if reasons else "-"
        top = top.replace("|", "\\|")
        lines.append(f"| {rep.base_name or rep.run_id} | {rep.verdict} | "
                     f"{c[FAIL]} | {c[WARN]} | {top} |")
    lines.append("")

    # per-run detail
    lines.append("## Per-run detail")
    lines.append("")
    for rep in reports:
        lines.append(f"### {rep.base_name or rep.run_id}  --  {rep.verdict}")
        meta = [f"run_id={rep.run_id}", f"mouse={rep.mouse}", f"date={rep.date}",
                f"status={rep.status}"]
        lines.append("`" + "  ".join(m for m in meta if m.split("=", 1)[1]) + "`")
        lines.append("")
        lines.append("| Check | Severity | Observed | Message |")
        lines.append("|-------|----------|----------|---------|")
        for r in rep.results:
            obs = r.observed.replace("|", "\\|")
            msg = r.message.replace("|", "\\|")
            lines.append(f"| {r.check} | {r.severity} | {obs} | {msg} |")
        lines.append("")

    lines.append("---")
    lines.append("")
    lines.append("### Tolerances used")
    lines.append("")
    lines.append(f"- behavior fs expected {EXPECTED_BEHAVIOR_FS} Hz, accel fs expected "
                 f"{EXPECTED_ACCEL_FS} Hz")
    lines.append(f"- fs PASS band ±{tol.fs_pass_frac:.0%}, WARN band ±{tol.fs_warn_frac:.0%}")
    lines.append(f"- duration agreement: max({tol.duration_abs_s}s, {tol.duration_frac:.0%})")
    lines.append(f"- t0 spread tolerance {tol.t0_consistency_s:g}s; "
                 f"near-constant std < {tol.near_constant_std:g}")
    lines.append("")
    lines.append("Exit codes: 0 = all pass (or warns w/o --strict), 1 = >=1 FAIL "
                 "(or WARN w/ --strict), 2 = QC tool could not run.")
    lines.append("")
    path.write_text("\n".join(lines))


def print_console_summary(reports, overall, quiet: bool):
    n = len(reports)
    npass = sum(1 for r in reports if r.verdict == PASS)
    nwarn = sum(1 for r in reports if r.verdict == WARN)
    nfail = sum(1 for r in reports if r.verdict == FAIL)
    print("=" * 64)
    print(f"QC SUMMARY: {n} run(s)  |  PASS {npass}  WARN {nwarn}  FAIL {nfail}  "
          f"=>  OVERALL {overall}")
    print("=" * 64)
    if nfail:
        print("FAIL runs:")
        for rep in reports:
            if rep.verdict == FAIL:
                reasons = rep.reasons(FAIL)
                print(f"  - {rep.base_name or rep.run_id}:")
                for why in reasons[: (None if not quiet else 1)]:
                    print(f"      * {why}")
    if nwarn and not quiet:
        print("WARN runs:")
        for rep in reports:
            if rep.verdict == WARN:
                reasons = rep.reasons(WARN)
                print(f"  - {rep.base_name or rep.run_id}: "
                      + ("; ".join(reasons[:3]) if reasons else ""))


# ============================================================================
# main
# ============================================================================
def resolve_report_dir(report_arg, out_dir: Path):
    """Return (dir, csv_path, md_path). --report may be a dir or a file stem."""
    if not report_arg:
        d = out_dir
        return d, d / "qc_report.csv", d / "qc_report.md"
    p = Path(report_arg)
    if p.suffix.lower() in (".md", ".csv"):
        stem = p.with_suffix("")
        return p.parent, stem.with_suffix(".csv"), stem.with_suffix(".md")
    return p, p / "qc_report.csv", p / "qc_report.md"


def build_arg_parser():
    ap = argparse.ArgumentParser(
        prog="validate_outputs.py",
        description="Correctness/QC validator for the behavior batch pipeline outputs.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="Exit codes: 0 all-pass (or warns w/o --strict); 1 >=1 FAIL "
               "(or WARN w/ --strict); 2 QC tool could not run.",
    )
    ap.add_argument("out_dir_pos", nargs="?", default=None,
                    help="batch output directory (containing csv/, mat/, batch_manifest.csv)")
    ap.add_argument("--out-dir", dest="out_dir_opt", default=None,
                    help="alternative to the positional out-dir argument")
    ap.add_argument("--report", default=None,
                    help="output path for the written report (a directory, or a .md/.csv "
                         "stem). Default: the out-dir itself.")
    ap.add_argument("--format", choices=["md", "csv", "both"], default="both",
                    help="which report file(s) to write (default: both)")
    ap.add_argument("--strict", action="store_true",
                    help="treat any WARN as a failure for the exit code (exit 1)")
    ap.add_argument("--tolerance", type=float, default=None,
                    help="scale factor for the fractional fs/duration tolerances "
                         "(e.g. 2.0 doubles the allowed sampling-rate deviation)")
    ap.add_argument("--quiet", action="store_true",
                    help="minimal console output (report files are still written)")
    return ap


def main(argv=None) -> int:
    ap = build_arg_parser()
    args = ap.parse_args(argv)

    out_dir_str = args.out_dir_opt or args.out_dir_pos
    if not out_dir_str:
        print("ERROR: no output directory given (positional out_dir or --out-dir).",
              file=sys.stderr)
        return 2
    out_dir = Path(out_dir_str).expanduser()
    if not out_dir.is_dir():
        print(f"ERROR: output directory does not exist: {out_dir}", file=sys.stderr)
        return 2

    try:
        rows, _cols = load_manifest(out_dir)
    except FileNotFoundError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2
    except Exception as exc:
        print(f"ERROR: could not read batch_manifest.csv: {type(exc).__name__}: {exc}",
              file=sys.stderr)
        return 2

    tol = Tolerances().scaled(args.tolerance) if args.tolerance else Tolerances()

    if not rows:
        print("WARNING: manifest is empty; no runs to validate.", file=sys.stderr)

    # per-run validation (never crash: wrap each run)
    reports = []
    for row in rows:
        base = (row.get("base_name") or row.get("run_id") or "run").strip()
        try:
            reports.append(check_run(row, out_dir, tol))
        except Exception:
            rep = RunReport(base_name=base, run_id=(row.get("run_id") or "").strip(),
                            mouse=(row.get("mouse") or "").strip(),
                            date=(row.get("date") or "").strip(),
                            status=(row.get("status") or "").strip().lower())
            rep.add("internal", FAIL, "exception",
                    "QC crashed on this run (treated as FAIL): "
                    + traceback.format_exc().splitlines()[-1])
            reports.append(rep)

    # cross-run consistency
    try:
        cross_run_consistency(reports, tol)
    except Exception as exc:  # never let this sink the whole tool
        for rep in reports:
            rep.add("cross_run", WARN, "skipped",
                    f"cross-run consistency skipped: {type(exc).__name__}: {exc}")

    # overall verdict
    overall = worst(r.verdict for r in reports) if reports else PASS

    # write reports
    rdir, csv_path, md_path = resolve_report_dir(args.report, out_dir)
    try:
        rdir.mkdir(parents=True, exist_ok=True)
        if args.format in ("csv", "both"):
            write_csv_report(csv_path, reports)
        if args.format in ("md", "both"):
            write_md_report(md_path, reports, overall, tol, out_dir)
    except Exception as exc:
        print(f"WARNING: failed to write report file(s): {type(exc).__name__}: {exc}",
              file=sys.stderr)

    # console
    print_console_summary(reports, overall, args.quiet)
    if not args.quiet:
        if args.format in ("csv", "both"):
            print(f"  wrote {csv_path}")
        if args.format in ("md", "both"):
            print(f"  wrote {md_path}")

    # exit code contract
    any_fail = any(r.verdict == FAIL for r in reports)
    any_warn = any(r.verdict == WARN for r in reports)
    if any_fail:
        return 1
    if any_warn and args.strict:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
