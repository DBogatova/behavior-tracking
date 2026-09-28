# Behavior batch pipeline — SCC operator's guide

Batched, mostly-non-interactive pupil / whisking / accelerometer analysis for
Femtonics behavior-camera runs, packaged to run headless on the Boston
University Shared Computing Cluster (SCC, Sun Grid Engine / `qsub`).

This directory (`batch/`) contains the whole pipeline. This README is written
for whoever runs it next — possibly you, months from now, having forgotten the
details. Read the **two-pass workflow** and the **alignment convention** before
touching anything.

---

## 1. Why two passes (read this first)

The pipeline is split into two passes **on purpose**, because exactly one step
needs a human looking at a screen and everything else must not:

- **PASS 1 — `collect_rois.m` — INTERACTIVE, needs a display.**
  For each run it shows a representative camera frame and asks you to draw three
  ROIs (eye ellipse → pupil mask, long-whisker rectangle, whisker-pad
  rectangle). Drawing requires a GUI (`drawellipse`/`drawrectangle`), so this
  must run **interactively** via **SCC OnDemand** (a desktop session) or SSH
  **X-forwarding**. It is the ONLY human interaction in the pipeline.

- **PASS 2 — `run_behavior_batch.m` — HEADLESS, no prompts.**
  Consumes the saved ROIs and processes every run with zero questions
  (thresholds are chosen automatically), exports CSVs + a backward-compatible
  `.mat` per run, and writes a manifest. This is what gets submitted to the
  scheduler with `matlab -batch -nodisplay`, so it can never block on a GUI.

A discovery step, **PASS 0 — `find_runs.m`**, runs first (headless, no prompts)
to inventory the runs. Run it in **report mode** against a new cluster layout to
validate discovery *before* drawing any ROIs.

**Do not try to run PASS 1 inside a `qsub` batch job.** Batch nodes have no
display; the ROI draw would fail or hang. Likewise, do not run PASS 2 on a login
node — login nodes are for light work only; real computation goes through the
scheduler.

---

## 2. Files in this directory

Pipeline stages (do not edit unless you own that stage):

| File | Pass | Role |
|------|------|------|
| `find_runs.m`                | 0 | Discover run folders + trigger MATs; report mode validates layout |
| `collect_rois.m`             | 1 | **Interactive** ROI drawing (needs display) |
| `run_behavior_batch.m`       | 2 | Headless per-run processing + CSV/MAT/manifest export |
| `detect_trigger_channels.m`  | 2 | Identify imaging vs camera trigger channels in the MAT |
| `trigger_align.m`            | 2 | Align frames to the imaging trigger; owns t=0 and the crop flag |
| `pupil_trace.m`              | 2 | Pupil signal from the eye mask |
| `whisker_trace.m`            | 2 | Long + pad whisker motion-energy signals |
| `auto_threshold.m`           | 2 | Otsu/percentile thresholds → binary bins |
| `export_behavior_csv.m`      | 2 | Write behavior / accel / trigger CSVs + info txt |
| `behavior_panels.py`         | 3 | Stacked panel plots (headless, `--batch` mode) |

Packaging / operations (this stage):

| File | Role |
|------|------|
| `submit_behavior.qsub` | SGE batch script: PASS 2 MATLAB + PASS 3 plots |
| `sync_to_scc.sh`       | rsync this code to the cluster over the `scc` alias |
| `README.md`            | this guide |

---

## 3. Cluster paths (defaults)

| What | Path |
|------|------|
| Data root (scanned by `find_runs`) | `/projectnb/devorlab/daria/Femtonics/behavior` |
| This code on the cluster           | `/projectnb/devorlab/daria/code/batch` |
| Shared legacy helpers              | `/projectnb/devorlab/daria/code/complete_behavior` |
| Output root (`OUT_DIR`)            | `<DATA_ROOT>/processed` |
| ROI file (`ROI_FILE`)              | `<DATA_ROOT>/rois.mat` |

The code layout matters: `run_behavior_batch.m` adds `../complete_behavior` to
the MATLAB path, so the batch code must live at `.../code/batch` next to
`.../code/complete_behavior`. `sync_to_scc.sh` defaults to exactly that.

---

## 4. Exact command sequence

### 4.1 Authenticate (once per ~8h, opens the multiplexed master)

```bash
ssh scc          # complete Duo when prompted; leave it or let ControlPersist hold it
ls ~/.ssh/cm-*   # confirm the control socket now exists
```

`sync_to_scc.sh` reuses this master so it never has to prompt. If the socket is
gone, the sync script refuses and tells you to run `ssh scc` again.

### 4.2 Sync the code up

```bash
cd /Users/daria/Desktop/behavior-tracking-daria/batch
./sync_to_scc.sh            # DRY RUN by default — shows what would transfer
./sync_to_scc.sh --go       # actually transfer
```

The sync is code-only, dry-run by default, and **never deletes** anything on the
cluster.

### 4.3 PASS 0 — inventory the runs (report mode) to validate the layout

On the cluster (a login node is fine for this light, no-plot step), in MATLAB
or via `matlab -batch`:

```matlab
addpath('/projectnb/devorlab/daria/code/batch');
runs = find_runs('/projectnb/devorlab/daria/Femtonics/behavior', ...
                 struct('report', true, 'min_frames', 100));
```

Read the printed inventory table carefully. Confirm the discovered `run_id`,
`mouse`, `date`, `camera_dir`, `n_frames`, and `trigger_file` match reality
**before** you draw any ROIs. If runs are missing, lower `min_frames`; if
identity fields are blank, see the Open Questions section.

### 4.4 PASS 1 — collect ROIs (INTERACTIVE — OnDemand / X-forwarding)

Start an SCC OnDemand desktop (or `ssh -X scc`), launch MATLAB **with a
display**, then:

```matlab
addpath('/projectnb/devorlab/daria/code/batch');
runs = find_runs('/projectnb/devorlab/daria/Femtonics/behavior', ...
                 struct('min_frames', 100));
collect_rois(runs, '/projectnb/devorlab/daria/Femtonics/behavior/rois.mat');
```

Draw the three ROIs per run (adjust the shape, press ENTER to accept). ROIs are
saved incrementally after **each** run, so the session is resumable: re-running
`collect_rois` skips runs already recorded. To redo specific runs, pass
`struct('overwrite', {{'Run005'}})` (or `true` to redo all).

### 4.5 PASS 2 + 3 — submit the headless batch

```bash
cd /projectnb/devorlab/daria/code/batch
mkdir -p logs                     # the qsub -o directive writes the log here
qsub submit_behavior.qsub
```

Override defaults without editing the script:

```bash
qsub -v DATA_ROOT=/projectnb/devorlab/daria/Femtonics/behavior,\
OUT_DIR=/projectnb/devorlab/daria/Femtonics/behavior/processed,\
ROI_FILE=/projectnb/devorlab/daria/Femtonics/behavior/rois.mat \
  submit_behavior.qsub
```

Other tunable env vars: `MIN_FRAMES`, `OVERWRITE` (`true`/`false`),
`WHISKER_BINNING` (`long`/`pad`), `CROP_START` (seconds trimmed in the plots),
`PY_VENV` / `PYTHON_BIN` (Python for the plotting stage). See the header of
`submit_behavior.qsub` for the full list and the SGE directive explanations.

### 4.6 Monitor

```bash
qstat -u daria            # your jobs and their state (qw=queued, r=running)
qstat -j <job_id>         # detailed scheduling info for one job
qdel <job_id>             # cancel a job
tail -f logs/behavior_batch.o<job_id>   # live log (stdout+stderr merged)
```

### 4.7 Inspect results

```bash
column -s, -t < /projectnb/devorlab/daria/Femtonics/behavior/processed/batch_manifest.csv | less -S
```

Check the `status` column: `ok`, `failed` (see `message`/`warnings`), or
`skipped` (already done). Failed runs do not abort the batch; fix the cause and
re-run with `OVERWRITE=true` (or just re-submit — done runs are skipped).

---

## 5. Output artifacts and their schemas

Everything lands under `OUT_DIR` (default `<DATA_ROOT>/processed`):

```
processed/
  csv/
    <base>_behavior.csv
    <base>_accel.csv
    <base>_trigger.csv     (optional; large)
    <base>_info.txt
  mat/
    <base>_behavior.mat
  figures/
    <base>_panels.pdf
    <base>_panels.png
  batch_manifest.csv
```

`<base>` is `<mouse>_<date>_<run_id>` (blanks collapsed).

### 5.1 `<base>_behavior.csv` (behavior signals, ~10 Hz)

Columns, in order:

```
frame, time_s, aligned_time_s, in_imaging_window,
pupil_raw, pupil_smooth, pupil_bins,
whisker_raw_long, whisker_smooth_long,
whisker_raw_pad,  whisker_smooth_pad, whisker_bins
```

- `time_s` — raw camera time; `aligned_time_s` — time with t=0 at the imaging
  trigger (see §6).
- `in_imaging_window` — 1 while the camera frame falls inside the imaging
  acquisition window, else 0. **The CSV keeps ALL frames** and flags them with
  this column; it does not physically crop. (The `.mat`, by contrast, stores the
  physically-cropped in-window signals — see §5.4.)
- `*_bins` — binary on/off from the auto-threshold.

### 5.2 `<base>_accel.csv` (accelerometer, ~1000 Hz)

```
sample, accel_mag, accX, accY, accZ, time_s, aligned_time_s
```

- `accX/accY/accZ` — raw per-axis values read from `data.ai.accX/Y/Z` in the
  trigger MAT (the legacy MATLAB code did not handle these at all; this pipeline
  adds them).
- `accel_mag` — L2 norm of the median-subtracted axes (magnitude of motion).
- `aligned_time_s` — same t=0 convention as the behavior CSV, so behavior and
  accel share a common time axis for joining/plotting.

### 5.3 `<base>_trigger.csv` (optional, large)

```
sample, time_s, aligned_time_s, <one column per digital channel present>
```

Written only when enabled (it can be large). Useful for auditing which digital
channels exist and confirming channel detection (see Open Questions).

### 5.4 `<base>_behavior.mat` (backward-compatible, `-v7`)

Saved in MATLAB `-v7` format so `scipy.io.loadmat` reads it (it is **not**
HDF5/v7.3). Top-level struct variables and their fields:

```
info    : mouse, date, run
settings: root_folder, trigger_file, binning_choice,
          pupil_threshold, whisker_threshold, pupil_method, whisker_method,
          threshold (legacy alias of whisker_threshold), fs, trigger_applied,
          imaging_channel, camera_channel, trigger_confidence,
          imaging_window_s, n_frames, n_kept, n_dropped,
          frame_used, eye_ellipse, roi_long, roi_pad
pupil   : pupil_raw, pupil_smooth, pupil_bins
whisker : whisker_raw_long, whisker_smooth_long,
          whisker_raw_pad,  whisker_smooth_pad, whisker_bins
```

Unlike the CSV, the arrays in the `.mat` are **cropped to the imaging window**
(matching the original interactive script's semantics).

> NOTE (from the PASS-2 stage): the `.mat` was verified by its MAT5/`-v7`
> header + exact nested field names in MATLAB, **not** by an actual
> `scipy.io.loadmat` call (scipy was unavailable in that environment). The
> header format and field names are what `loadmat` consumes, but if you rely on
> the Python read path, do a one-time `scipy.io.loadmat` smoke test.

### 5.5 `<base>_info.txt`

Human-readable provenance: source folder, trigger file, resolved channels,
thresholds, crop bookkeeping, and any warnings for that run.

### 5.6 `batch_manifest.csv` (one row per run)

Header (verbatim):

```
idx,run_id,mouse,date,base_name,camera_dir,trigger_file,n_frames,status,message,
pupil_threshold,whisker_threshold,pupil_method,whisker_method,imaging_channel,
camera_channel,trigger_confidence,trigger_applied,n_camera_edges,n_tiff_frames,
n_used,n_kept,n_dropped,mat_path,behavior_csv,accel_csv,warnings
```

`status` ∈ {`ok`, `failed`, `skipped`}. For `failed` rows the numeric fields are
`NaN` and the error is in `message` / `warnings`. This is your first stop when a
batch finishes.

### 5.7 Figures — `<base>_panels.{pdf,png}`

Stacked panels (Pupil, Whisking, Accelerometer, Whisking-bins) in the reference
project's visual style. The accelerometer panel uses a fixed 0–0.25 y-limit and
`accel_mag` as its signal. Produced by `behavior_panels.py --batch`.

---

## 6. Alignment convention (do not double-correct)

**t = 0 is the first rising edge of the imaging trigger.** Alignment happens
**once**, in the MATLAB stage (`trigger_align.m`): it finds the imaging
trigger's first rising edge, sets that as t=0, computes `aligned_time_s` for
both the behavior and accelerometer streams, and flags/crops the imaging window.
Both CSVs carry `aligned_time_s` already aligned.

Therefore the Python plotting stage **must NOT re-apply any camera-to-imaging
(Basler→SCAPE) offset.** `behavior_panels.py` only crops the already-aligned
axis; it applies no offset (documented in its header). 

> **Warning — double-correction.** The older reference script
> (`apical-dendrites-2025/code/Behavior-Analysis/behavior_plots.py`) *recomputed
> and applied* the Basler→SCAPE offset itself from the trigger CSV. If you port
> logic from that script, or add an "offset" flag here, you will shift the
> signals **twice** and every trace will be misaligned by that offset. Alignment
> is upstream now; keep it there.

---

## 7. Open questions (unresolved — cluster was unreachable)

These could not be settled because the cluster requires Duo on every connection
and was not reachable during development. Resolve them on first real use:

1. **The real directory layout under the Femtonics behavior root.**
   `find_runs.m` does **not** hardcode the layout; it discovers run folders by
   TIFF density and *infers* mouse/date/run from the path (it expects something
   like `<root>/<date>/<mouse>/camera/<Run###>/` with triggers under a sibling
   `trigger/` dir, but degrades to blanks otherwise). The Femtonics tree may
   differ. **How to surface the answer:** run `find_runs` in **report mode**
   (§4.3) and read the inventory table. If identity fields are blank or trigger
   files are unmatched, the real layout differs from the heuristic and the
   identity inference in `find_runs.m` needs adjusting to the actual tree.

2. **The actual digital trigger channel names on the Femtonics rig.**
   The legacy code hardcoded rig-specific names (Andor/Xyla imaging trigger,
   Basler camera exposure trigger). The Femtonics rig almost certainly uses
   **different** channel names (e.g. a `Femto2P_ScannerSync`-style imaging
   channel). **How to surface the answer:** `detect_trigger_channels.m`
   auto-identifies the imaging vs camera channels by name keywords, then by
   signal shape (edge counts / inferred rate), and reports a `confidence` of
   `override` / `name` / `shape` / `unresolved`. Check the `imaging_channel`,
   `camera_channel`, and `trigger_confidence` columns in the manifest. If
   confidence is `shape` or `unresolved`, inspect a `<base>_trigger.csv` to see
   the real channel names and, if needed, pass explicit hints
   (`hints.imaging` / `hints.camera`) so detection is name-based and certain.

---

## 8. Legacy bugs fixed (does this affect old results?)

The batch pipeline was rebuilt from the interactive
`complete_behavior/DB_complete_analysis_trigger.m`. Two classes of legacy
behavior are worth knowing when judging previously generated `.mat` results.

### 8.1 Whisker/pupil signal selection was silently INVERTED

The original script selected which signal to bin/plot with a **malformed
`switch`/`case`**. From the autosaved original (`DB_complete_analysis_trigger.asv`):

```matlab
answer = input('... Long=0 Pad=1\n');
switch answer
    case answer==0                       % <-- BUG
        whisker = whisker_smooth_long;
        settings.binning_choice = 'long';
    case answer==1                       % <-- BUG
        whisker = whisker_smooth_pad;
        settings.binnig_choice = 'smooth';   % <-- also a typo'd field + wrong value
end
```

`case answer==0` does **not** mean "when answer is 0". MATLAB first evaluates the
expression `answer==0` to a logical `0`/`1`, and `switch answer` then compares
`answer` against that `0`/`1`. The result: the branches are matched by the
*truth value* of the comparisons, not the value you typed, so the mapping is
inverted — choosing **Long** actually binned the **Pad** signal and choosing
**Pad** binned **Long**. The pupil movie selection (`Smooth=1 Raw=0`) used the
same broken idiom. There was also a typo'd field, `binnig_choice = 'smooth'`
(misspelled key, and `'smooth'` instead of `'pad'`).

**Impact on old results:** any `.mat` produced through that `switch`/`case` path
may have the whisker binning applied to the *opposite* signal from what the
operator intended (and a misspelled/incorrect `binning_choice` record). All
four whisker signals were always saved, so the *raw traces* are fine — it is the
**binned** `whisker_bins` and the recorded `binning_choice` that are suspect.
Re-derive bins from the correct signal if in doubt.

**Fixed here:** `run_behavior_batch.m` selects the binning source explicitly and
correctly (`opts.whisker_binning` = `'long'`|`'pad'`, mapped with a plain
`if strcmpi(...,'pad')`), and records `binning_choice` accurately. There is no
`switch answer / case answer==K` construct anywhere in the batch code.

### 8.2 Accelerometer was not handled at all

The legacy code ignored `data.ai.accX/Y/Z` entirely. This pipeline reads those
axes, computes `accel_mag`, aligns them to the same imaging trigger, and exports
`<base>_accel.csv`. Old `.mat` files therefore contain **no** accelerometer
data; only outputs from this pipeline do.

---

## 9. What could NOT be verified without cluster access

Everything cluster-side is **unverified** and marked as such inline in
`submit_behavior.qsub`. In particular, confirm on first use:

- **MATLAB module name/version** — `module avail matlab`, then pin one.
- **MATLAB license resource name** — `qconf -sc | grep -i matlab` (script uses
  `-l matlab=1`).
- **Python for plotting** — a `python3` module or a venv with
  numpy/pandas/matplotlib/scipy (`module avail python3`; or set `PY_VENV`).
- **Queue limits** (wall-clock, memory, PE names) — `qconf -sq` / `qconf -sc` /
  `qconf -spl`.
- **The two Open Questions in §7** (real data layout, real trigger channel
  names).

The scripts themselves were syntax-checked locally (`bash -n`), the
sync-guard's refusal path was exercised locally (no ControlMaster socket → clean
refusal), and the qsub/plot invocations were checked against the actual
`run_behavior_batch.m` signature and `behavior_panels.py` argparse flags. The
scheduler behavior itself (qsub acceptance, module loads, license grant) can
only be confirmed by an actual submission once you are authenticated.

---

## 10. End-to-end orchestration → see `PIPELINE.md`

This README documents the batch pipeline stages themselves. For the **whole
flow as (almost) one command** — preflight checks, code sync, inventory, ROI
guidance, `qsub` submit + `qstat` wait, results fetch, QC gating, plotting, and
publishing into the analysis-script layout — see **`PIPELINE.md`**, which also
covers the newer tooling in this directory:

| File | Role |
|------|------|
| `run_pipeline.sh`       | Single orchestrator: staged (`--stage`/`--from`/`--to`), preflight + gates, `--dry-run`, timestamped logging |
| `fetch_results.sh`      | rsync processed results **down** from the cluster (dry-run by default, never deletes) |
| `validate_outputs.py`   | QC/correctness validator; its exit code (0/1/2) gates publishing |
| `publish_to_project.py` | Installs outputs into the `apical-dendrites-2025` consumer layout (dry-run by default) |

`PIPELINE.md` also lists which steps **require a human** (Duo once; ROI drawing
needs a display) and every cluster-side assumption still to confirm on first use.
