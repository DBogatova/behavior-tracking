#!/usr/bin/env python3
"""
publish_to_project.py  --  install batch pipeline outputs into the layout that
the apical-dendrites-2025 analysis scripts already expect.

WHY THIS EXISTS
===============
The headless batch pipeline (run_behavior_batch.m + export_behavior_csv.m) emits
a FLAT producer directory:

    <batch-dir>/
      csv/<base>_behavior.csv
      csv/<base>_accel.csv
      csv/<base>_trigger.csv
      csv/<base>_info.txt
      mat/<base>_behavior.mat
      figures/<base>_panels.pdf
      figures/<base>_panels.png
      batch_manifest.csv

where  <base> = "<mouse>_<date>_<run_id>"  e.g. "rbp4_132_phpeb_26-05-12_Run005".

The CONSUMER scripts
    apical-dendrites-2025/code/Behavior-Analysis/behavior_plots.py
    apical-dendrites-2025/code/Behavior-Analysis/behavior_plots_concat.py
    apical-dendrites-2025/code/Traces-STEP3/combo_with_behavior.py
read a completely different, per-run tree:

    <project-root>/<YYYY-MM-DD>/<mouse>/<runN>/
      behavior/<mouse>_<yy-mm-dd>_Run<NNN>_behavior.mat
      trigger/Run<NNN>_t1_accel.csv
      trigger/Run<NNN>_t1_trigger.csv        (consumer finds it via glob '*_trigger.csv')

This tool copies the producer artifacts into the consumer tree, performing the
THREE naming conversions the consumer's own convention bakes in (verified
against the consumer source, see "CONSUMER EVIDENCE" below).

THE THREE NAMING CONVERSIONS (reproduced faithfully, NOT "fixed")
=================================================================
(a) DATE: four-digit year in the DIRECTORY ('2026-03-31') but two-digit year
    inside the MAT FILENAME ('26-03-31').
(b) RUN in the DIRECTORY: lowercase and NOT zero-padded ('run10', 'run7').
(c) RUN in FILENAMES: capitalized 'Run' and zero-padded to (at least) 3 digits
    ('Run010', 'Run007').  This matches behavior_plots.py which builds the accel
    filename as  RUN.replace('run','').zfill(3)  -> 'run7' -> 'Run007_t1_accel.csv'.

CONSUMER EVIDENCE (verbatim lines this tool matches)
====================================================
behavior_plots.py:
    DATE = "2026-02-17"
    MOUSE = "rbp4cre_138_phpeb"
    RUN = "run7"
    BASE = Path(".../apical-dendrites-2025/data") / DATE / MOUSE / RUN
    BEHAVIOR_MAT = BASE / "behavior" / "rbp4cre_138_phpeb_26-02-17_Run007_behavior.mat"
    ...
    run_num = RUN.replace("run", "").zfill(3)
    accel_csv = BASE / "trigger" / f"Run{run_num}_t1_accel.csv"
    ...
    trigger_csvs = list((BASE / "trigger").glob("*_trigger.csv"))

So for identity (mouse='rbp4cre_138_phpeb', date='2026-02-17', run_id='Run007'):
    dir   : <root>/2026-02-17/rbp4cre_138_phpeb/run7/
    mat   : behavior/rbp4cre_138_phpeb_26-02-17_Run007_behavior.mat
    accel : trigger/Run007_t1_accel.csv
    trig  : trigger/Run007_t1_trigger.csv    (glob '*_trigger.csv' finds it)

CENTURY ASSUMPTION (explicit, documented, tested)
=================================================
Two-digit years are interpreted as 20YY  ('26' -> '2026').  Four-digit years are
used as-is for the directory and truncated to their last two digits for the MAT
filename ('2026' -> '26').  Years are NEVER interpreted as 19YY -- all lab data
is from the 2020s.  If a date arrives as a two-digit year, the directory form is
reconstructed as '20' + yy.

PATH / NAME MAPPING TABLE
=========================
  producer source (under --batch-dir)   ->  consumer destination (under --project-root/<dir_date>/<mouse>/<dir_run>/)
  ---------------------------------------    ------------------------------------------------------------------------
  mat/<base>_behavior.mat                ->  behavior/<mouse>_<mat_date>_<FileRun>_behavior.mat   [PRIMARY, consumed]
  csv/<base>_accel.csv                   ->  trigger/<FileRun>_t1_accel.csv                       [PRIMARY, consumed]
  csv/<base>_trigger.csv                 ->  trigger/<FileRun>_t1_trigger.csv                     [PRIMARY, consumed via glob]
  csv/<base>_behavior.csv                ->  behavior/<mouse>_<mat_date>_<FileRun>_behavior.csv   [secondary: 10 Hz signals, kept alongside the .mat]
  csv/<base>_info.txt                    ->  behavior/<mouse>_<mat_date>_<FileRun>_info.txt       [secondary: provenance]
  figures/<base>_panels.pdf              ->  behavior/figures/<base>_panels.pdf                   [secondary: QC plot]
  figures/<base>_panels.png              ->  behavior/figures/<base>_panels.png                   [secondary: QC plot]

  where  dir_date = YYYY-MM-DD,  mat_date = yy-mm-dd,
         dir_run  = 'run' + <int(run_num)>            (lowercase, unpadded),
         FileRun  = 'Run' + <int(run_num) zero-padded to >=3>.

SAFETY MODEL
============
* DRY-RUN BY DEFAULT.  Nothing is written unless --apply is given.
* COPY, NEVER MOVE.  Sources are left untouched.
* NEVER DELETE anything.
* NEVER OVERWRITE an existing destination unless --overwrite is given.  When a
  destination exists and DIFFERS (by size or SHA-256) it is reported and skipped
  by default.  When it is byte-identical the publish is a NO-OP (not a conflict).
* Writes are atomic (copy to a temp file in the destination dir, then os.replace).
* Only runs whose manifest status is 'ok' are published.  'failed'/'skipped' rows
  are skipped with a printed reason.
* --require-qc PATH is a hard correctness gate: it reads qc_report.csv (from the
  sibling validate_outputs.py).  Any run whose QC verdict is FAIL is refused.
  Under --require-qc a run must have an explicit non-FAIL verdict to be published;
  a run with no QC entry is skipped (unvalidated).  If the QC report itself is
  missing, the tool refuses to publish ANYTHING rather than proceed blindly.
* The project root is validated first: if it does not exist, is not a directory,
  is a dangling symlink, or resolves onto an unmounted /Volumes/* drive, the tool
  fails with a helpful message instead of silently creating directories on the
  wrong filesystem.  (The project's 'data' entry is a symlink to /Volumes/IMAC/data,
  an external drive that is frequently NOT mounted.)
* Every action is recorded in a machine-readable publish_log.csv (default:
  <batch-dir>/publish_log.csv) with timestamps, sizes and hashes, so the operation
  is auditable and reversible by hand.

This module uses only the Python standard library.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import os
import re
import shutil
import sys
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Dict, List, Optional, Tuple


# --------------------------------------------------------------------------- #
# small utilities
# --------------------------------------------------------------------------- #

def eprint(*args, **kwargs) -> None:
    """Print to stderr."""
    print(*args, file=sys.stderr, **kwargs)


def fail(msg: str, code: int = 2) -> "None":
    """Print a helpful error and exit non-zero."""
    eprint("ERROR: " + msg)
    sys.exit(code)


def sha256_of(path: Path, _bufsize: int = 1024 * 1024) -> str:
    """SHA-256 hex digest of a file's contents."""
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        while True:
            chunk = fh.read(_bufsize)
            if not chunk:
                break
            h.update(chunk)
    return h.hexdigest()


# --------------------------------------------------------------------------- #
# identity normalization (the three naming conversions live here)
# --------------------------------------------------------------------------- #

def normalize_date(raw: str) -> Tuple[str, str]:
    """Normalize a date string to (dir_date='YYYY-MM-DD', mat_date='yy-mm-dd').

    Accepts either 'YYYY-MM-DD' or 'yy-mm-dd'.  Two-digit years are interpreted
    as 20YY (CENTURY ASSUMPTION: all lab data is from the 2020s; never 19YY).

    >>> normalize_date('2026-03-31')
    ('2026-03-31', '26-03-31')
    >>> normalize_date('26-03-31')
    ('2026-03-31', '26-03-31')
    >>> normalize_date('2026-2-7')
    ('2026-02-07', '26-02-07')
    """
    if raw is None:
        raise ValueError("empty date")
    s = str(raw).strip()
    m = re.match(r"^(\d{2}|\d{4})-(\d{1,2})-(\d{1,2})$", s)
    if not m:
        raise ValueError(
            "date %r is not in 'YYYY-MM-DD' or 'yy-mm-dd' form" % raw)
    y, mo, d = m.group(1), int(m.group(2)), int(m.group(3))
    if not (1 <= mo <= 12):
        raise ValueError("date %r has month out of range" % raw)
    if not (1 <= d <= 31):
        raise ValueError("date %r has day out of range" % raw)
    if len(y) == 4:
        yyyy = y
        yy = y[2:]
    else:  # len == 2  -> CENTURY ASSUMPTION 20YY
        yy = y
        yyyy = "20" + y
    dir_date = "%s-%02d-%02d" % (yyyy, mo, d)
    mat_date = "%s-%02d-%02d" % (yy, mo, d)
    return dir_date, mat_date


def normalize_run(raw: str) -> Tuple[str, str, int]:
    """Normalize a run id to (dir_run='run<N>', file_run='Run<NNN>', n).

    Accepts 'Run005', 'run7', 'RUN10', '007', '5', etc.  The directory form is
    lowercase and NOT zero-padded; the filename form is capitalized 'Run' and
    zero-padded to at least 3 digits (mirroring behavior_plots.py's
    RUN.replace('run','').zfill(3)).

    >>> normalize_run('Run005')
    ('run5', 'Run005', 5)
    >>> normalize_run('run10')
    ('run10', 'Run010', 10)
    >>> normalize_run('7')
    ('run7', 'Run007', 7)
    """
    if raw is None:
        raise ValueError("empty run id")
    s = str(raw).strip()
    m = re.search(r"(\d+)", s)
    if not m:
        raise ValueError("run id %r contains no run number" % raw)
    n = int(m.group(1))
    dir_run = "run%d" % n
    file_run = "Run%03d" % n  # zfill(3)-equivalent: >=3 digits, no truncation
    return dir_run, file_run, n


# parse "<mouse>_<date>_<run>" when the explicit columns are unavailable.
_BASE_RE = re.compile(
    r"^(?P<mouse>.+)_(?P<date>\d{2,4}-\d{2}-\d{2})_(?P<run>[Rr][Uu][Nn]\d+)$")


def identity_from_row(row: Dict[str, str]) -> Tuple[str, str, str, str]:
    """Return (mouse, date, run_id, base_name) for a manifest row.

    Prefers the explicit 'mouse'/'date'/'run_id' columns; falls back to parsing
    'base_name'.  base_name is used to locate the producer source files on disk.
    """
    def g(k: str) -> str:
        v = row.get(k, "")
        return "" if v is None else str(v).strip()

    mouse = g("mouse")
    date = g("date")
    run_id = g("run_id")
    base = g("base_name")

    if not (mouse and date and run_id):
        # Fall back to parsing base_name.
        src = base or "_".join(x for x in (mouse, date, run_id) if x)
        m = _BASE_RE.match(src)
        if m:
            mouse = mouse or m.group("mouse")
            date = date or m.group("date")
            run_id = run_id or m.group("run")
    if not base:
        base = "_".join(x for x in (mouse, date, run_id) if x)
    return mouse, date, run_id, base


# --------------------------------------------------------------------------- #
# manifest + QC report loading
# --------------------------------------------------------------------------- #

def load_manifest(path: Path) -> List[Dict[str, str]]:
    if not path.is_file():
        fail("manifest not found: %s" % path)
    with open(path, newline="") as fh:
        reader = csv.DictReader(fh)
        rows = [dict(r) for r in reader]
    if not rows:
        eprint("WARNING: manifest %s has no data rows." % path)
    return rows


def _norm_verdict(v: str) -> str:
    v = (v or "").strip().upper()
    if v in ("FAIL", "FAILED", "F"):
        return "FAIL"
    if v in ("PASS", "OK", "P", "PASSED"):
        return "PASS"
    if v in ("WARN", "WARNING", "W"):
        return "WARN"
    return v  # unknown / empty


def load_qc(path: Path) -> Dict[str, str]:
    """Load qc_report.csv into {key: normalized_verdict}.

    Flexible about column names: the key column is one of
    base_name/base/run/run_id (base_name preferred); the verdict column is one
    of verdict/qc_verdict/qc/result/status.  Multiple keys are indexed per row
    (base_name AND run_id AND mouse_date_run) so a run can be matched several
    ways.
    """
    if not path.is_file():
        fail("--require-qc was given but the QC report does not exist: %s\n"
             "       Refusing to publish anything without QC validation. Run "
             "validate_outputs.py first, or drop --require-qc to publish "
             "without the correctness gate." % path)
    with open(path, newline="") as fh:
        reader = csv.DictReader(fh)
        fields = [f.strip() for f in (reader.fieldnames or [])]
        lower = {f.lower(): f for f in fields}

        def pick(*cands: str) -> Optional[str]:
            for c in cands:
                if c in lower:
                    return lower[c]
            return None

        # "run_verdict" is the column validate_outputs.py actually writes; the
        # others are accepted so a hand-edited or future report still works.
        verdict_col = pick("run_verdict", "verdict", "qc_verdict", "qc",
                           "result", "status")
        if verdict_col is None:
            fail("QC report %s has no verdict column (looked for "
                 "run_verdict/verdict/qc_verdict/qc/result/status)." % path)

        out: Dict[str, str] = {}
        for r in reader:
            verdict = _norm_verdict(r.get(verdict_col, ""))
            keys = set()
            for col in ("base_name", "base"):
                if col in lower and (r.get(lower[col]) or "").strip():
                    keys.add(r[lower[col]].strip())
            # composite mouse_date_run key + bare run id
            mouse = (r.get(lower.get("mouse", ""), "") or "").strip()
            date = (r.get(lower.get("date", ""), "") or "").strip()
            runid = (r.get(lower.get("run_id", ""), "")
                     or r.get(lower.get("run", ""), "") or "").strip()
            if mouse and date and runid:
                keys.add("%s_%s_%s" % (mouse, date, runid))
            if runid:
                keys.add(runid)
            for k in keys:
                out[k] = verdict
    return out


def qc_lookup(qc: Dict[str, str], mouse: str, date: str,
              run_id: str, base: str) -> Optional[str]:
    """Find a run's QC verdict trying several key forms; None if absent."""
    for k in (base, "%s_%s_%s" % (mouse, date, run_id), run_id):
        if k and k in qc:
            return qc[k]
    return None


# --------------------------------------------------------------------------- #
# project-root safety check
# --------------------------------------------------------------------------- #

def check_project_root(root: str) -> Path:
    """Validate the project root; exit helpfully on any problem.

    Detects a dangling symlink (external volume not mounted) and paths that
    resolve onto an unmounted /Volumes/* drive.
    """
    p = Path(root)

    if p.is_symlink():
        target = os.readlink(p)
        resolved = Path(os.path.realpath(p))
        if not resolved.exists():
            fail("project root %s is a symlink -> %s but the target does not "
                 "exist.\n       This usually means an external volume is not "
                 "mounted (e.g. /Volumes/IMAC). Mount the drive and retry.\n"
                 "       Refusing to create directories inside a dangling "
                 "symlink." % (p, target))

    if not p.exists():
        fail("project root does not exist: %s\n"
             "       Check the --project-root path (and whether the external "
             "data volume is mounted)." % p)

    if not p.is_dir():
        fail("project root is not a directory: %s" % p)

    real = Path(os.path.realpath(p))
    parts = real.parts
    # /Volumes/<name>/... -> confirm the mount point is present.
    if len(parts) >= 3 and parts[1] == "Volumes":
        mount = Path("/", parts[1], parts[2])
        if not mount.exists():
            fail("project root resolves to %s on volume %s, which is not "
                 "mounted.\n       Mount the external drive and retry." %
                 (real, mount))

    return real


# --------------------------------------------------------------------------- #
# planning
# --------------------------------------------------------------------------- #

@dataclass
class Artifact:
    kind: str            # mat / accel / trigger / behavior_csv / info / fig_pdf / fig_png
    primary: bool
    src: Path
    dst: Path


@dataclass
class PlanRow:
    base: str
    mouse: str
    dir_date: str
    mat_date: str
    dir_run: str
    file_run: str
    artifact: str
    primary: bool
    src: Optional[Path]
    dst: Optional[Path]
    action: str
    reason: str = ""
    src_size: int = -1
    src_hash: str = ""
    dst_hash: str = ""


# actions
A_WOULD_PUBLISH = "would-publish"
A_WOULD_OVERWRITE = "would-overwrite"
A_WOULD_SKIP_EXISTS = "would-skip-exists"
A_WOULD_NOOP = "would-noop-identical"
A_PUBLISHED = "published"
A_OVERWRITTEN = "overwritten"
A_NOOP = "noop-identical"
A_SKIP_EXISTS = "skipped-exists"
A_SKIP_FAILED = "skipped-failed"
A_SKIP_STATUS = "skipped-status"
A_SKIP_QC = "skipped-qc"
A_SKIP_MISSING = "skipped-missing-source"


def femto_date(mat_date: str) -> str:
    """'yy-mm-dd' -> 'MM-DD-YYYY', the femtonics-data folder convention.

    Observed on disk: 06-08-2026, 06-12-2026, 06-17-2026, ... Century is taken
    as 2000+yy, consistent with dir_date elsewhere in this module.
    """
    m = re.match(r"^(\d{2})-(\d{2})-(\d{2})$", mat_date)
    if not m:
        raise ValueError("expected yy-mm-dd, got %r" % mat_date)
    yy, mm, dd = m.groups()
    return "%s-%s-20%s" % (mm, dd, yy)


def build_artifacts(batch_dir: Path, run_dir: Path, mouse: str, mat_date: str,
                    file_run: str, base: str) -> List[Artifact]:
    """Compute the (source -> destination) mapping for one run."""
    csvd = batch_dir / "csv"
    matd = batch_dir / "mat"
    figd = batch_dir / "figures"
    beh = run_dir / "behavior"
    trg = run_dir / "trigger"
    figs = beh / "figures"
    stem = "%s_%s_%s" % (mouse, mat_date, file_run)  # consumer stem
    return [
        # PRIMARY (read by the consumer scripts)
        Artifact("mat", True,
                 matd / ("%s_behavior.mat" % base),
                 beh / ("%s_behavior.mat" % stem)),
        Artifact("accel", True,
                 csvd / ("%s_accel.csv" % base),
                 trg / ("%s_t1_accel.csv" % file_run)),
        Artifact("trigger", True,
                 csvd / ("%s_trigger.csv" % base),
                 trg / ("%s_t1_trigger.csv" % file_run)),
        # SECONDARY (kept for provenance / reference; not read by name)
        Artifact("behavior_csv", False,
                 csvd / ("%s_behavior.csv" % base),
                 beh / ("%s_behavior.csv" % stem)),
        Artifact("info", False,
                 csvd / ("%s_info.txt" % base),
                 beh / ("%s_info.txt" % stem)),
        Artifact("fig_pdf", False,
                 figd / ("%s_panels.pdf" % base),
                 figs / ("%s_panels.pdf" % base)),
        Artifact("fig_png", False,
                 figd / ("%s_panels.png" % base),
                 figs / ("%s_panels.png" % base)),
    ]


def plan_run(row: Dict[str, str], batch_dir: Path, project_root: Path,
             qc: Optional[Dict[str, str]], layout: str = "apical") -> List[PlanRow]:
    """Produce plan rows for one manifest row (run)."""
    mouse, date, run_id, base = identity_from_row(row)
    status = (row.get("status") or "").strip().lower()

    # ---- manifest status gate --------------------------------------------
    if status != "ok":
        act = A_SKIP_FAILED if status == "failed" else A_SKIP_STATUS
        reason = "manifest status %r" % (status or "(missing)")
        return [PlanRow(base or "(unknown)", mouse, "", "", "", "",
                        "-", False, None, None, act, reason)]

    # ---- identity parse (needed for every artifact) ----------------------
    try:
        dir_date, mat_date = normalize_date(date)
        dir_run, file_run, _ = normalize_run(run_id)
    except ValueError as e:
        return [PlanRow(base or "(unknown)", mouse, "", "", "", "",
                        "-", False, None, None, A_SKIP_STATUS,
                        "cannot parse identity: %s" % e)]

    if not mouse:
        return [PlanRow(base or "(unknown)", mouse, dir_date, mat_date,
                        dir_run, file_run, "-", False, None, None,
                        A_SKIP_STATUS, "missing mouse in manifest")]

    # ---- QC gate ---------------------------------------------------------
    if qc is not None:
        verdict = qc_lookup(qc, mouse, date, run_id, base)
        if verdict == "FAIL":
            return [PlanRow(base, mouse, dir_date, mat_date, dir_run,
                            file_run, "-", False, None, None, A_SKIP_QC,
                            "QC verdict FAIL")]
        if verdict is None:
            return [PlanRow(base, mouse, dir_date, mat_date, dir_run,
                            file_run, "-", False, None, None, A_SKIP_QC,
                            "no QC entry (run not validated)")]
        # PASS / WARN / unknown-nonfail -> allowed (WARN noted)

    # ---- destination layout -------------------------------------------------
    # 'apical'    : <root>/<YYYY-MM-DD>/<mouse>/<runN>/{behavior,trigger}
    #               the apical-dendrites-2025 scape-data convention.
    # 'femtonics' : <root>/<mouse>/<MM-DD-YYYY>/{behavior,trigger}
    #               the femtonics-data convention. NOTE there is no per-run
    #               directory level here, so every run of a session shares one
    #               behavior/ and trigger/ folder and the RUN is carried by the
    #               FILENAME. behavior_plots.py still finds the .mat and the
    #               accel CSV because it builds those names explicitly from the
    #               run number; only its '*_trigger.csv' GLOB becomes ambiguous
    #               (it would match every run of that session and take the
    #               first). That glob is used solely to compute a Basler->
    #               imaging offset, which must NOT be applied to these CSVs --
    #               they are already aligned upstream. Keep
    #               APPLY_PUPIL_TRIGGER_OFFSET = False and the ambiguity is
    #               harmless.
    if layout == "femtonics":
        run_dir = project_root / mouse / femto_date(mat_date)
    else:
        run_dir = project_root / dir_date / mouse / dir_run
    arts = build_artifacts(batch_dir, run_dir, mouse, mat_date, file_run, base)

    out: List[PlanRow] = []
    for a in arts:
        pr = PlanRow(base, mouse, dir_date, mat_date, dir_run, file_run,
                     a.kind, a.primary, a.src, a.dst, "", "")
        if not a.src.exists():
            pr.action = A_SKIP_MISSING
            pr.reason = "source not present in batch dir"
            out.append(pr)
            continue
        pr.src_size = a.src.stat().st_size
        pr.src_hash = sha256_of(a.src)
        out.append(pr)
    return out


# --------------------------------------------------------------------------- #
# execution
# --------------------------------------------------------------------------- #

def atomic_copy(src: Path, dst: Path) -> None:
    """Copy src -> dst atomically (temp file in dst dir, then os.replace)."""
    dst.parent.mkdir(parents=True, exist_ok=True)
    tmp = dst.parent / ("%s.tmp.%d" % (dst.name, os.getpid()))
    try:
        shutil.copy2(src, tmp)
        os.replace(tmp, dst)  # atomic; only reached when writing is permitted
    finally:
        if tmp.exists():
            try:
                tmp.unlink()
            except OSError:
                pass


def execute(rows: List[PlanRow], dry_run: bool, overwrite: bool) -> None:
    """Decide + perform the copy for each planned artifact row (in place)."""
    for pr in rows:
        # run-level skips already carry a terminal action
        if pr.src is None or pr.action in (
                A_SKIP_FAILED, A_SKIP_STATUS, A_SKIP_QC, A_SKIP_MISSING):
            continue

        dst = pr.dst
        exists = dst.exists()
        if exists:
            dsize = dst.stat().st_size
            pr.dst_hash = sha256_of(dst)
            identical = (dsize == pr.src_size and pr.dst_hash == pr.src_hash)
            if identical:
                pr.action = A_WOULD_NOOP if dry_run else A_NOOP
                pr.reason = "identical (no change needed)"
                continue
            # differs
            if not overwrite:
                pr.action = A_WOULD_SKIP_EXISTS if dry_run else A_SKIP_EXISTS
                pr.reason = "destination exists and DIFFERS (pass --overwrite)"
                continue
            # differs + overwrite allowed
            if dry_run:
                pr.action = A_WOULD_OVERWRITE
                pr.reason = "would overwrite differing destination"
            else:
                atomic_copy(pr.src, dst)
                pr.action = A_OVERWRITTEN
                pr.reason = "overwrote differing destination"
        else:
            if dry_run:
                pr.action = A_WOULD_PUBLISH
            else:
                atomic_copy(pr.src, dst)
                pr.action = A_PUBLISHED


# --------------------------------------------------------------------------- #
# reporting
# --------------------------------------------------------------------------- #

_WROTE_ACTIONS = {A_PUBLISHED, A_OVERWRITTEN}
_PLAN_WRITE_ACTIONS = {A_WOULD_PUBLISH, A_WOULD_OVERWRITE}


def _rel(path: Optional[Path], base: Path) -> str:
    if path is None:
        return "-"
    try:
        return str(path.relative_to(base))
    except ValueError:
        return str(path)


def print_plan(rows: List[PlanRow], batch_dir: Path, project_root: Path,
               dry_run: bool) -> None:
    header = ["run", "artifact", "source", "destination", "action", "reason"]
    table = [header]
    for pr in rows:
        table.append([
            pr.base,
            pr.artifact,
            _rel(pr.src, batch_dir),
            _rel(pr.dst, project_root),
            pr.action,
            pr.reason,
        ])
    widths = [max(len(r[i]) for r in table) for i in range(len(header))]
    widths = [min(w, 70) for w in widths]

    def fmt(r):
        return "  ".join(str(c)[:w].ljust(w) for c, w in zip(r, widths))

    mode = "DRY-RUN (no files written; pass --apply to write)" if dry_run \
        else "APPLY (writing files)"
    print("=" * 100)
    print("PUBLISH PLAN  --  %s" % mode)
    print("  batch-dir    : %s" % batch_dir)
    print("  project-root : %s" % project_root)
    print("=" * 100)
    print(fmt(header))
    print("  ".join("-" * w for w in widths))
    for r in table[1:]:
        print(fmt(r))
    print("=" * 100)


def print_summary(rows: List[PlanRow]) -> None:
    counts: Dict[str, int] = {}
    for pr in rows:
        counts[pr.action] = counts.get(pr.action, 0) + 1
    print("SUMMARY (by action):")
    for act in sorted(counts):
        print("  %-24s : %d" % (act, counts[act]))
    n_runs = len({pr.base for pr in rows})
    print("  %-24s : %d" % ("distinct runs", n_runs))


def write_log(rows: List[PlanRow], log_path: Path, dry_run: bool) -> None:
    ts = datetime.now().isoformat(timespec="seconds")
    mode = "dry-run" if dry_run else "apply"
    header = ["timestamp", "mode", "run", "mouse", "dir_date", "mat_date",
              "dir_run", "file_run", "artifact", "primary", "action", "reason",
              "source", "destination", "src_size", "src_sha256",
              "dst_sha256_before"]
    log_path.parent.mkdir(parents=True, exist_ok=True)
    with open(log_path, "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(header)
        for pr in rows:
            w.writerow([
                ts, mode, pr.base, pr.mouse, pr.dir_date, pr.mat_date,
                pr.dir_run, pr.file_run, pr.artifact,
                "1" if pr.primary else "0", pr.action, pr.reason,
                "" if pr.src is None else str(pr.src),
                "" if pr.dst is None else str(pr.dst),
                pr.src_size if pr.src_size >= 0 else "",
                pr.src_hash, pr.dst_hash,
            ])
    print("Wrote publish log: %s" % log_path)


# --------------------------------------------------------------------------- #
# CLI
# --------------------------------------------------------------------------- #

def parse_args(argv: Optional[List[str]] = None) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        prog="publish_to_project.py",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        description=(
            "Publish batch pipeline outputs into the apical-dendrites-2025 "
            "consumer layout.\nDRY-RUN by default; pass --apply to actually "
            "write."),
        epilog=(
            "examples:\n"
            "  # preview (writes nothing):\n"
            "  publish_to_project.py --batch-dir processed --project-root "
            ".../apical-dendrites-2025/scape-data\n"
            "  # apply, gated on QC:\n"
            "  publish_to_project.py --batch-dir processed --project-root "
            ".../scape-data --require-qc processed/qc_report.csv --apply\n"),
    )
    p.add_argument("--batch-dir", required=True,
                   help="producer output directory (contains csv/, mat/, "
                        "figures/, batch_manifest.csv)")
    p.add_argument("--project-root", required=True,
                   help="consumer data root, e.g. .../apical-dendrites-2025/"
                        "scape-data or .../data")
    p.add_argument("--layout", choices=["apical", "femtonics"], default="apical",
                   help="destination layout. 'apical': "
                        "<root>/<YYYY-MM-DD>/<mouse>/<runN>/{behavior,trigger} "
                        "(apical-dendrites-2025 scape-data). 'femtonics': "
                        "<root>/<mouse>/<MM-DD-YYYY>/{behavior,trigger} "
                        "(femtonics-data; run is carried by the filename).")
    p.add_argument("--manifest", default=None,
                   help="manifest CSV (default: <batch-dir>/batch_manifest.csv)")
    p.add_argument("--require-qc", metavar="PATH", default=None,
                   help="path to qc_report.csv; refuse to publish any run "
                        "whose QC verdict is FAIL (correctness gate). If the "
                        "report is missing, refuse to publish anything.")
    p.add_argument("--overwrite", action="store_true",
                   help="overwrite destination files that exist and DIFFER "
                        "(identical files are always a no-op)")
    p.add_argument("--log", default=None,
                   help="publish log CSV (default: <batch-dir>/publish_log.csv)")
    mode = p.add_mutually_exclusive_group()
    mode.add_argument("--apply", action="store_true",
                      help="actually copy files (default is dry-run)")
    mode.add_argument("--dry-run", action="store_true",
                      help="explicit dry-run (this is already the default)")
    return p.parse_args(argv)


def main(argv: Optional[List[str]] = None) -> int:
    args = parse_args(argv)
    dry_run = not args.apply  # DRY-RUN BY DEFAULT

    batch_dir = Path(args.batch_dir)
    if not batch_dir.is_dir():
        fail("batch dir does not exist or is not a directory: %s" % batch_dir)

    manifest_path = Path(args.manifest) if args.manifest \
        else batch_dir / "batch_manifest.csv"
    log_path = Path(args.log) if args.log else batch_dir / "publish_log.csv"

    # Validate the project root FIRST (unmounted-volume / dangling-symlink guard).
    project_root = check_project_root(args.project_root)

    # QC gate: load (or refuse) before doing anything.
    qc: Optional[Dict[str, str]] = None
    if args.require_qc:
        qc = load_qc(Path(args.require_qc))
        print("QC gate ON: loaded %d verdict key(s) from %s"
              % (len(qc), args.require_qc))

    rows = load_manifest(manifest_path)

    plan: List[PlanRow] = []
    for row in rows:
        plan.extend(plan_run(row, batch_dir, project_root, qc, args.layout))

    execute(plan, dry_run=dry_run, overwrite=args.overwrite)

    print_plan(plan, batch_dir, project_root, dry_run)
    print_summary(plan)
    write_log(plan, log_path, dry_run)

    if dry_run:
        print("\nDRY-RUN complete. No files were written. Re-run with --apply "
              "to publish.")
    else:
        wrote = sum(1 for pr in plan if pr.action in _WROTE_ACTIONS)
        print("\nAPPLY complete. %d file(s) written." % wrote)
    return 0


if __name__ == "__main__":
    sys.exit(main())
