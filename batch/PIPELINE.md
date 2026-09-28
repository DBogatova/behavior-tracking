# PIPELINE.md — end-to-end operator guide

This is the guide for the **whole** behavior-processing flow: from raw camera
TIFFs + trigger MATs sitting on the BU SCC cluster, all the way to processed
files installed exactly where your existing analysis scripts read them. It ties
together the headless batch pipeline (documented in `README.md`) with the four
pieces that turn it into (almost) one command: **QC validation**, **results
fetch**, **publish**, and the **orchestrator**.

If you only read one section, read **§2 (what is automatic vs human)** and
**§4 (common commands)**.

---

## 1. The full data flow

```
   ┌─────────────────────────── BU SCC cluster ───────────────────────────┐
   │                                                                       │
   │  RAW DATA                                                             │
   │   /projectnb/devorlab/daria/Femtonics/behavior/                       │
   │     <run>/ …                per-run TIFF camera folders               │
   │     <run>_t1.mat            per-run trigger MAT (data.di, data.ai)     │
   │        │                                                              │
   │        │  find_runs.m  (PASS 0, headless)   ── inventory / validate   │
   │        ▼                                                              │
   │  collect_rois.m  (PASS 1) ▲ HUMAN + DISPLAY  ── eye ellipse + 2 whisker│
   │        │                  │  (SCC OnDemand / ssh -X)   rectangles     │
   │        ▼                  └─ writes  rois.mat                         │
   │  submit_behavior.qsub  (PASS 2 + 3, SGE batch, headless)              │
   │     run_behavior_batch.m → pupil/whisker/accel traces, trigger-align, │
   │                            crop, auto-threshold, CSV + .mat + manifest │
   │     behavior_panels.py   → stacked QC panel figures                   │
   │        │                                                              │
   │        ▼   OUT_DIR = …/behavior/processed/  (csv/ mat/ figures/ manifest)
   └────────┼──────────────────────────────────────────────────────────────┘
            │  fetch_results.sh   (rsync pull, over the multiplexed ssh)
            ▼
   ┌──────────────────────── this local machine ──────────────────────────┐
   │  results/  (local mirror: csv/ mat/ figures/ batch_manifest.csv)      │
   │        │                                                              │
   │        │  validate_outputs.py   ── QC GATE (exit 0/1/2) ─────────────▶│  qc_report.md/csv
   │        │  behavior_panels.py    ── (re)render panels locally          │
   │        ▼                                                              │
   │  publish_to_project.py   (DRY-RUN by default; --apply to write;       │
   │                           refuses any run whose QC verdict is FAIL)   │
   │        │  performs the 3 naming conversions (date / dir-run / file-run)│
   │        ▼                                                              │
   │  apical-dendrites-2025/scape-data/<YYYY-MM-DD>/<mouse>/<runN>/         │
   │     behavior/<mouse>_<yy-mm-dd>_Run<NNN>_behavior.mat                  │
   │     trigger/Run<NNN>_t1_accel.csv , Run<NNN>_t1_trigger.csv            │
   │        │                                                              │
   │        ▼                                                              │
   │  YOUR EXISTING ANALYSIS SCRIPTS read these unchanged:                 │
   │     code/Behavior-Analysis/behavior_plots.py                          │
   │     code/Behavior-Analysis/behavior_plots_concat.py                   │
   │     code/Traces-STEP3/combo_with_behavior.py                          │
   └───────────────────────────────────────────────────────────────────────┘
```

`run_pipeline.sh` drives the boxed stages as an explicit, individually-runnable
sequence:

```
preflight → sync-code → inventory → rois → submit → wait → fetch → qc → plots → publish
```

---

## 2. What is automatic, and what REQUIRES a human (do not oversell this)

Two steps are **irreducibly manual**. Everything else is automated.

| Step | Automatic? | Why |
|------|-----------|-----|
| **`ssh scc` + Duo approval** | ❌ **HUMAN, once per ~8h** | SCC requires Duo two-factor on **every new SSH connection**. No script can approve Duo for you. You run `ssh scc` and approve **once**; the multiplexed ControlMaster socket (`~/.ssh/cm-…`, `ControlPersist 8h`) then makes every later `ssh`/`rsync`/`qsub`/`qstat` non-interactive. This is the *only* authentication step. |
| **`rois` — drawing ROIs** | ❌ **HUMAN + DISPLAY** | `collect_rois.m` calls `drawellipse`/`drawrectangle`, which need a GUI. Run it on an **SCC OnDemand** desktop or over **`ssh -X`**, never in a batch job. It is resumable and skips runs already drawn. |
| preflight, sync-code, inventory | ✅ automatic | read-only checks + code rsync + `find_runs` report, all over the multiplexed socket. |
| submit, wait | ✅ automatic | `qsub` the batch job, then poll `qstat` until it leaves the queue. |
| fetch, qc, plots, publish | ✅ automatic | rsync pull, `validate_outputs.py`, `behavior_panels.py`, `publish_to_project.py`. |

So the honest promise is: **two human touches** (Duo once; ROIs once per new
run) and the rest is one command. The orchestrator’s `preflight` stops the whole
thing *before* any long work if either human step is missing.

---

## 3. One-time setup

- **ssh alias `scc`** must exist in `~/.ssh/config` (User daria, HostName
  scc1.bu.edu) with `ControlMaster auto`, `ControlPath ~/.ssh/cm-%r@%h:%p`,
  `ControlPersist 8h`. (It does — this guide assumes it.)
- **Local Python** with `numpy`, `pandas`, `scipy`, `matplotlib` for the local
  `qc`/`plots`/`publish` stages. The bare `python3` on this machine may *not*
  have them; point `PYTHON_BIN` at one that does, e.g.:

  ```bash
  export PYTHON_BIN=python3.13        # or /path/to/.venv/bin/python
  ```

  `preflight` checks this and tells you if it is missing.

---

## 4. Common commands (copy-paste)

All commands are run from the local batch dir:

```bash
cd /Users/daria/Desktop/behavior-tracking-daria/batch
```

Always start each working session by opening the multiplexed connection:

```bash
ssh scc            # approve Duo; leave it open (ControlPersist keeps the socket ~8h)
ls ~/.ssh/cm-*     # confirm the control socket exists
```

### 4.1 First-time full run (no ROIs yet)

ROIs do not exist yet, so `preflight` will (correctly) refuse the full run.
Do the setup + interactive step first, then run the full pipeline:

```bash
# 1) push code, inventory the runs (skips the ROI gate)
./run_pipeline.sh --from sync-code --to inventory

# 2) draw ROIs — this prints the exact interactive commands to run on OnDemand
./run_pipeline.sh --stage rois
#    …follow the printed guidance in an SCC OnDemand desktop / ssh -X session…

# 3) now the full sequence: preflight passes, batch submits, waits, fetches,
#    QC-gates, plots, and shows a publish DRY-RUN
./run_pipeline.sh

# 4) inspect the publish plan and qc_report, then actually write into the project
./run_pipeline.sh --from publish --publish-apply
```

Prefer to inspect the whole plan without touching anything first?

```bash
./run_pipeline.sh --dry-run      # prints every command it would run, executes nothing
```

### 4.2 Adding a few new runs later

New TIFF folders were added under the data root. You need ROIs **only** for the
new runs (`collect_rois` skips ones already recorded), then re-run:

```bash
ssh scc                                   # (if the socket has expired)
./run_pipeline.sh --from sync-code --to inventory   # confirm the new runs are discovered
./run_pipeline.sh --stage rois                      # draw ROIs for the NEW runs only (resumable)
./run_pipeline.sh                                   # submit → … → publish DRY-RUN
./run_pipeline.sh --from publish --publish-apply    # write the new runs (done runs are no-ops)
```

`run_behavior_batch` skips already-processed runs, `rsync` has no `--delete`,
and `publish` is a no-op on byte-identical files — so this only does the new work.

### 4.3 Re-running after fixing ONE bad run

Say `Run005` had a bad ROI (see §6.1) or an unresolved trigger (see §6.2). Fix
the ROI, force just that run through PASS 2, then re-run the tail:

```bash
# redraw only Run005's ROIs
./run_pipeline.sh --stage rois        # or, in MATLAB on OnDemand:
#   collect_rois(runs, '<ROI_FILE>', struct('overwrite', {{'Run005'}}));

# reprocess (OVERWRITE=true forces re-run of done runs; others are quick skips)
OVERWRITE=true ./run_pipeline.sh --from submit --to wait

# fetch, re-QC, re-plot, and preview publish for the corrected results
./run_pipeline.sh --from fetch --to publish
./run_pipeline.sh --from publish --publish-apply
```

### 4.4 QC-only re-check (no cluster work)

Re-validate what you already fetched, without touching the cluster:

```bash
./run_pipeline.sh --stage qc                 # exit 0 pass / 1 fail / 2 tool-could-not-run
# equivalently, the tool directly:
"$PYTHON_BIN" validate_outputs.py results     # writes results/qc_report.{md,csv}
"$PYTHON_BIN" validate_outputs.py results --strict   # treat WARN as failure too
```

### 4.5 Fetch only (pull results, inspect, decide later)

```bash
./fetch_results.sh                 # DRY RUN — shows what would transfer
./fetch_results.sh --go            # transfer the small valuable artifacts
./fetch_results.sh --go --with-trigger-csv   # also pull the large trigger CSVs
```

---

## 5. Every gate, and what to do when it trips

A **nonzero exit from any stage aborts the run** by default. `--force` continues
past a failure with a loud banner (see the caveats below). The whole run is
logged to a timestamped file under `pipeline_logs/` for after-the-fact auditing.

| Gate | Trips when | What to do |
|------|-----------|-----------|
| **preflight** | socket missing, cluster unreachable, data root/ROI file missing, ROI coverage incomplete, local Python missing packages, or project root not mounted | Read the printed checklist. Fix the specific `[FAIL]` line. `[SKIP]` lines are cluster checks blocked by the missing socket — run `ssh scc` and re-run preflight. |
| **sync-code / inventory / submit / wait / fetch** | no live ControlMaster socket | Run `ssh scc`, approve Duo, retry. These stages never hang: they refuse fast via ssh `BatchMode`. |
| **wait** | job in SGE error state, or timeout (`WAIT_TIMEOUT_S`, default 12h) | The message points at the SGE log `…/code/batch/logs/behavior_batch.o<jobid>`. `qdel <jobid>` to cancel; inspect the log; fix and re-submit. |
| **qc** (THE correctness gate) | `validate_outputs.py` exits **1** (≥1 run FAIL, or any WARN under `--strict`) | Publishing is **blocked**. Open `results/qc_report.md`, find the failing run + reason, fix it (§6), re-run `--from submit` (or `--stage qc` if only re-checking). See §5.1 for the exit-code contract. |
| **qc** | `validate_outputs.py` exits **2** (tool could not run: missing dir/manifest) | Not a data problem — the fetch is incomplete or pointed at the wrong dir. Re-run `--stage fetch`, confirm `results/batch_manifest.csv` exists. |
| **plots** | a run’s CSV can’t be plotted | Non-blocking to the *data*: the fetched CSV/MAT are still valid and figures were also fetched from the cluster. If you just want to publish, `--from publish`. |
| **publish** | project root missing / dangling symlink (exit 2), or QC report missing under `--require-qc` (exit 2) | Mount the drive or fix `PROJECT_ROOT` (default is the real `scape-data`, **not** the `data` symlink to the often-unmounted `/Volumes/IMAC/data`). Ensure `results/qc_report.csv` exists (run `--stage qc`). |

### 5.1 The QC exit-code contract (verbatim behavior)

`validate_outputs.py` (its documented contract, honored by the orchestrator):

- **exit 0** — all runs PASS, or only WARNs and `--strict` was **not** given → **publish allowed**.
- **exit 1** — ≥1 run FAIL, or (with `--strict`) ≥1 WARN → **publish blocked**.
- **exit 2** — the tool itself could not run (missing `--out-dir` / unreadable
  `batch_manifest.csv`) → **abort** (a single corrupt run is a FAIL row, not exit 2).

`run_pipeline.sh`’s `qc` stage branches on exactly these three codes.

### 5.2 What `--force` does — and the backstop that still protects you

`--force` lets the sequence continue past a failed stage (including a QC exit 1)
with a loud banner. **Even then, bad data cannot silently publish:**
`publish_to_project.py` is always invoked with `--require-qc results/qc_report.csv`,
so it independently **refuses any individual run whose QC verdict is FAIL**, and
refuses everything if the QC report is missing. So `--force` past QC means
"publish the runs that passed, skip the ones that failed" — never "publish
failures". Use it deliberately.

### 5.3 Publishing is dry-run by default at two levels

1. The orchestrator’s `publish` stage passes **no** `--apply` unless you give
   `--publish-apply`.
2. `publish_to_project.py` is itself **dry-run by default** and only writes with
   `--apply`.

So a publish only writes when you *explicitly* ask (`--publish-apply`), and even
then it is QC-gated, copy-only, never-overwrite-without-`--overwrite`, and
never-delete.

---

## 6. Troubleshooting (real symptoms → cause → fix)

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| **Pupil trace is CONSTANT** (QC: `signal_sanity FAIL … pupil_raw is CONSTANT`) | The eye ellipse in `rois.mat` was drawn **too generously**. The pupil algorithm’s `dark_percentile = 40`, so the pupil must fill **~40%+** of the ellipse; a loose ellipse dilutes the dark pupil below threshold and the trace degenerates. | Redraw a **tight** ellipse hugging the eye: `--stage rois` → `collect_rois(runs, ROI_FILE, struct('overwrite',{{'Run00X'}}))`, then `OVERWRITE=true ./run_pipeline.sh --from submit`. |
| **Trigger unresolved / not applied** (manifest `trigger_confidence=unresolved` or `trigger_applied=0`; QC `manifest WARN`) | This rig’s digital channel names differ from the legacy **Andor/Basler** names the detector keys on (Femtonics likely uses e.g. a `Femto2P_ScannerSync`-style imaging channel). `detect_trigger_channels.m` fell back to signal-shape or gave up. | Fetch a trigger CSV to see the real names: `./fetch_results.sh --go --with-trigger-csv`, open `results/csv/<base>_trigger.csv`. Then pass explicit hints so detection is name-based: forward `opts.trigger.hints.imaging` / `.camera` (see `detect_trigger_channels.m` / `README.md §7`) and reprocess with `OVERWRITE=true --from submit`. |
| `preflight` all cluster lines say `[SKIP] blocked: no ControlMaster socket` | The multiplexed master isn’t open. | `ssh scc` (approve Duo), then re-run. |
| `preflight` `[FAIL] local Python … missing numpy/pandas/scipy/matplotlib` | `PYTHON_BIN` points at an interpreter without the sci stack. | `export PYTHON_BIN=python3.13` (or a venv python), re-run. |
| `preflight` `[FAIL] project root is a dangling symlink` | `PROJECT_ROOT` was set to the `data` symlink and `/Volumes/IMAC` isn’t mounted. | Mount the drive, or use the default `scape-data` root. |
| `fetch`/`sync`/`submit` prints “no live SSH ControlMaster session” and exits 1 | Socket expired (>8h) or never opened. | `ssh scc`, then retry. It refuses rather than hanging on Duo. |
| `wait` times out | Batch legitimately long, or stuck. | Raise `WAIT_TIMEOUT_S`, or check `qstat -j <jobid>` and the SGE log path printed by the stage. |
| QC `sampling_rate FAIL … fs=100 Hz` or `alignment FAIL` | Wrong/renamed columns, double-corrected alignment, or a bad trigger. | Open `qc_report.md` per-run detail; usually traces to the trigger issue above. Do **not** re-apply any Basler→SCAPE offset locally (alignment is upstream — see `README.md §6`). |
| `publish` shows `skipped-qc "QC verdict FAIL"` for a run | That run failed QC and is being (correctly) withheld. | Fix the run (§6.1/§6.2) and reprocess; the rest publish normally. |

---

## 7. Configuration knobs

`run_pipeline.sh` reads a documented config block at its top; every value is
env-overridable. Most-used:

| Variable | Default | Meaning |
|----------|---------|---------|
| `SCC_HOST` | `scc` | ssh alias for the cluster |
| `DATA_ROOT` | `/projectnb/devorlab/daria/Femtonics/behavior` | root scanned by `find_runs` |
| `OUT_DIR` | `${DATA_ROOT}/processed` | cluster output dir |
| `ROI_FILE` | `${DATA_ROOT}/rois.mat` | ROIs from PASS 1 |
| `REMOTE_CODE_DIR` | `/projectnb/devorlab/daria/code/batch` | code location on cluster |
| `LOCAL_RESULTS_DIR` | `<batch>/results` | local mirror of `OUT_DIR` |
| `PROJECT_ROOT` | `…/apical-dendrites-2025/scape-data` | publish destination |
| `PYTHON_BIN` | `python3` | local python with the sci stack |
| `LOG_DIR` | `<batch>/pipeline_logs` | timestamped run logs |
| `MIN_FRAMES` | `100` | min TIFFs to count as a run |
| `OVERWRITE` | `false` | reprocess already-done runs |
| `WHISKER_BINNING` | `long` | `long`/`pad` signal to bin |
| `CROP_START` | `0` | seconds trimmed in plots |
| `WAIT_TIMEOUT_S` / `WAIT_POLL_S` | `43200` / `30` | wait-stage timeout / poll interval |

`fetch_results.sh` reads `SCC_HOST`, `REMOTE_OUT_DIR`, `LOCAL_RESULTS_DIR`,
`SSH_CONNECT_TIMEOUT`.

---

## Cluster safety

The SCC is a **shared** cluster. The pipeline's cluster-facing behavior is
funnelled through one sourced guard library, `scc_guard.sh`, so the safety
rules live in a single auditable place. Every script that can touch the cluster
sources it: `run_pipeline.sh`, `sync_to_scc.sh`, `fetch_results.sh`, and the
compute-node job `submit_behavior.qsub`. This section states plainly what the
pipeline can and cannot touch — **including the defects an adversarial audit
found and that are still present in the code.** Read the residual-risk table at
the end before trusting any of the guarantees against a hostile input.

### The three invariants the guard enforces

1. **Confinement** — every remote path the pipeline reads, writes, or creates
   must resolve inside the allowlist `SCC_ALLOWED_ROOTS`. Operationally: a path
   that is not absolute, contains shell metacharacters, escapes above `/`, hits
   a protected system dir, or falls outside the allowed roots aborts the script
   (`assert_remote_path_allowed`, `scc_guard.sh:76`).
2. **Non-destruction** — no `rsync --delete`-family flag may ever be passed
   (`assert_rsync_nondestructive` refuses `--delete|--delete-*|--del|--remove-source-files|--force|--inplace`,
   `scc_guard.sh:132,136`), and remote command strings are screened for
   destructive verbs (`assert_remote_cmd_safe`, `scc_guard.sh` — see the caveat
   below: this screen is advisory, not a boundary). Operationally: no automated
   step is supposed to be able to remove or truncate anything already on the
   cluster.
3. **Login-node courtesy** — remote filesystem walks are meant to run `nice`'d
   and time-bounded so a runaway walk cannot degrade a shared login node
   (`guard_nice_prefix` / `guard_timeout_prefix`, `scc_guard.sh:165,172`).
   Operationally: light work on the login node, all heavy work on a compute
   node via `qsub`. (See residual risk: the timeout half is **not** wired up.)

### Which paths are validated, and where the allowlist comes from

`SCC_ALLOWED_ROOTS` is a colon-separated list of absolute directories the
pipeline may touch. Its default is the user's own project space only:

```sh
SCC_ALLOWED_ROOTS="${SCC_ALLOWED_ROOTS:-/projectnb/devorlab/daria}"   # scc_guard.sh:34
```

Every env-overridable cluster path is passed through `assert_remote_path_allowed`
before any connection:

| Script | Paths validated |
|--------|-----------------|
| `run_pipeline.sh` (213–216) | `DATA_ROOT`, `OUT_DIR`, `ROI_FILE`, `REMOTE_CODE_DIR` |
| `sync_to_scc.sh` (51) | `REMOTE_DIR` (the sync destination) |
| `fetch_results.sh` (72) | `REMOTE_OUT_DIR` (the fetch source) |
| `submit_behavior.qsub` (110–112) | `DATA_ROOT`, `OUT_DIR`, `ROI_FILE` |

To widen the allowlist deliberately — e.g. to also allow the user's home
directory — set a second root explicitly (the guard's own documented example):

```sh
SCC_ALLOWED_ROOTS="/projectnb/devorlab/daria:/usr4/daria"   # scc_guard.sh:33
```

### What happens on a violation

`_guard_die` prints `SAFETY ABORT:` with the **offending variable's label**
(e.g. `OUT_DIR (cluster job output)`) and **`exit 3`** (`scc_guard.sh:44`),
**before any remote command is sent**. Exit code 3 is used only for a guard
safety abort, so it is distinguishable in logs from ordinary failures (a missing
ControlMaster socket exits 1; a bad CLI argument exits 2). `submit_behavior.qsub`
also uses `exit 3` for a missing guard file, keeping the "3 == refused for
safety" convention consistent.

### The only script that writes to the cluster

`sync_to_scc.sh` is the **only** script that writes to the cluster filesystem
from the local side (`sync_to_scc.sh:127`) — it rsyncs the `batch/` **code** up.
It is **dry-run by default** (`DRY_RUN=1`, `sync_to_scc.sh:63`); nothing
transfers until you pass `--go`. `fetch_results.sh` is also dry-run by default
(`fetch_results.sh:75`) but it only *pulls*, so the cluster is read-only for it.

### The compute-node job creates, never deletes

`submit_behavior.qsub` runs on a compute node and **creates** its output under
`OUT_DIR`, which defaults to `${DATA_ROOT}/processed`
(`submit_behavior.qsub:89`; with the default `DATA_ROOT` that is
`/projectnb/devorlab/daria/Femtonics/behavior/processed`). The MATLAB stage only
`save`s / `writetable`s / `fopen 'w'`s / `mkdir`s into `csv/`, `mat/`,
`figures/`, and `batch_manifest.csv` — the audit found **no** `delete`/`rmdir`/
`movefile`, and the output filenames are distinct from the raw TIFFs/trigger
MATs, so raw data is not clobbered. Already-processed runs are **skipped, not
recomputed or removed** (`OVERWRITE` defaults to `false`,
`submit_behavior.qsub:95`; set `OVERWRITE=true` to force reprocessing).

### Login-node behavior

The default `inventory` stage is a lightweight `nice`'d `find` that counts TIFFs
per directory — **no MATLAB and no license token** (`run_pipeline.sh:458`, which
also logs `inventory: lightweight find (no MATLAB, no license)`). Passing
`--deep-inventory` opts into the richer `find_runs` MATLAB report
(`run_pipeline.sh:449`); this **starts MATLAB on a login node and consumes a
shared license token**, which is why it is not the default and prints a warning.
All real processing runs on a compute node via `qsub submit_behavior.qsub`, not
on the login node.

### Blast radius at a glance

| On the cluster, the pipeline DOES | The pipeline does NOT |
|-----------------------------------|-----------------------|
| Read-only inspection (`test`, `qstat`, `tail`, `grep`, `find`) over one multiplexed ssh | Authenticate/approve Duo itself — it refuses fast (BatchMode + ConnectTimeout) if no master socket, never hangs |
| Upload **code** into `REMOTE_CODE_DIR` via rsync, dry-run by default (`sync_to_scc.sh` only) | Pass any `rsync --delete`-family flag (verified: none present) |
| Submit **one** `qsub` batch job | Loop-submit jobs (no submission loop exists; `WAIT_TIMEOUT_S`/`WAIT_POLL_S`-bounded wait) |
| CREATE output under `OUT_DIR` (`csv/ mat/ figures/ batch_manifest.csv`) on a compute node | Delete, truncate, `mv`, or overwrite raw TIFFs/trigger MATs |
| Default inventory: `nice`'d `find`, no MATLAB/license | Run heavy work, or (by default) MATLAB, on a login node |

### Residual risk (audit findings — several are UNFIXED in the current code)

The following defects were execution-verified by the preceding audit and are
**still present** in the scripts as written. They are stated here so an operator
is not misled by the guarantees above:

- **Command injection via unvalidated knobs (UNFIXED, high).** `MIN_FRAMES`,
  `OVERWRITE`, `WHISKER_BINNING`, `CROP_TO_WINDOW`, `CROP_START` are interpolated
  into the remote `qsub -v` string inside single quotes with **no validation**
  (`run_pipeline.sh:557`) and again into the MATLAB statement
  (`submit_behavior.qsub:162`, some unquoted). A single quote in any of these
  breaks out; the audit produced remote code execution this way. Single-quote
  wrapping is **not** a security boundary. Until these are whitelisted, an
  attacker-controlled or mistaken value can run arbitrary code on the cluster —
  which can in turn write anywhere and delete data, defeating all three
  invariants.
- **`assert_remote_cmd_safe` is an advisory denylist, not a boundary (UNFIXED).**
  The audit bypassed it with variable indirection (`R=rm; $R -rf …`),
  `base64 -d | sh`, `cp`, `curl | sh`, relative-path clobber, and a tab before
  `rm`. Treat it as defence-in-depth only, not protection against a hostile
  command string.
- **False positives break normal operation (UNFIXED).** The `'>/'` and `'> /'`
  patterns (`scc_guard.sh:152`) also match `2>/dev/null`, so legitimate commands
  routed through `ssh_scc` (which screens every command) are wrongly refused.
  Verified consequences: the submit duplicate-job guard is silently defeated
  (its subshell aborts and yields empty, so re-running `submit` can queue a
  duplicate job), and the `wait` stage's completion check can hard-exit the
  whole orchestrator with exit 3.
- **`submit_behavior.qsub` fails OPEN on an empty/corrupt guard (UNFIXED).** It
  uses only `set -o pipefail` (`submit_behavior.qsub:73`, no `set -e`) and checks
  only that `scc_guard.sh` *exists*, not that it defines the guard functions.
  With an empty guard file it proceeds with empty paths into `module load
  matlab`, bypassing confinement. (A *missing* guard file does fail closed with
  `exit 3`; the three `.sh` scripts fail closed under `set -euo pipefail`.)
- **Login-node courtesy only half-wired (UNFIXED).** `guard_timeout_prefix` is
  defined (`scc_guard.sh:172`) but **never called anywhere**, so remote walks are
  `nice`'d but **not** time-bounded, despite `guard_summary` claiming
  "timeout … s". Separately, the `rois`-stage coverage check launches MATLAB on a
  login node with **no `nice` and no `-singleCompThread`** and **regardless of
  `--deep-inventory`** (`run_pipeline.sh:481`), contradicting the guarantee that
  login-node MATLAB/license use is opt-in.
- **`SCC_ALLOWED_ROOTS` is itself env-overridable and unvalidated (design
  limit).** Confinement holds for the **default** root only. Widening the root to
  a broader-but-normal prefix (e.g. `/projectnb/devorlab` or `/projectnb`) lets
  paths reach other users'/labs' space. (`SCC_ALLOWED_ROOTS="/"` is accidentally
  safe because of normalization.) Strict single-user confinement depends on not
  widening the root carelessly.
- **Lower-severity unvalidated values (UNFIXED).** `MATLAB_MODULE` is
  interpolated unquoted into `module load`; `SGE_JOB_NAME` flows into a remote
  log path; `BATCH_DIR` into `addpath('…')`; and `SCC_HOST` is the ssh target,
  so a value beginning with `-` could enable ssh option injection.

Cannot be verified without cluster access (Duo-gated, no live session):

- **Symlink escape.** `guard_normalize_path` is purely lexical (correct for
  offline remote checking), so a symlink **inside** an allowed root that points
  **outside** it would pass the check yet write outside. Detecting this needs
  `readlink -f` on the cluster and requires a pre-existing malicious/mistaken
  symlink in the user's own tree.
- **SGE/module names.** `h_rt`, the `matlab`/`mem` complex names, and the MATLAB/
  Python module names in the qsub are unverified offline; whether the scheduler
  accepts the requests cannot be confirmed here. No submission loop exists, so
  the code itself poses no queue-flood risk.
- **Output vs raw filename collision.** `OUT_DIR` defaults inside `DATA_ROOT`; as
  written the job emits only `csv`/`mat`/`manifest` names, so raw files are not
  clobbered, but this depends on the actual on-disk layout.

---

## 8. UNVERIFIED assumptions (cluster was unreachable during development)

Everything cluster-side below is **unverified** because SCC requires Duo and no
live session existed while these tools were written. Each row names the **exact
command that confirms it on first real use**. (The local behaviors — script
syntax, the ControlMaster-absent refusals, the QC/publish/panels CLIs, dry-run
plan — *were* verified locally; see §9.)

| Assumption | Confirm with |
|-----------|--------------|
| The ControlMaster socket + multiplexing actually make ssh non-interactive after one Duo | `ssh scc` (approve Duo), then `ssh -O check scc` → “Master running”; then `ssh scc true` returns instantly |
| `find_runs` discovers the real Femtonics layout and infers identity correctly | `./run_pipeline.sh --stage inventory` and read the printed table (see `README.md §7 Q1`) |
| `rois.mat` keys (`camera_dir`) match `find_runs`’ `camera_dir` so coverage is detected | `preflight`’s “ROI file covers all N runs” line; if it WARNs it couldn’t verify remotely |
| MATLAB module name (`module load matlab`) and license resource (`-l matlab=1`) | `ssh scc 'module avail matlab'` and `ssh scc 'qconf -sc | grep -i matlab'` (see `submit_behavior.qsub` header) |
| `qsub` accepts `submit_behavior.qsub`, and the printed job id parses as `Your job <N>` | `./run_pipeline.sh --stage submit` — it echoes qsub’s output and records the id in `pipeline_logs/last_job_id` |
| `qstat` job-name column is truncated to `behavior_b…` (used for duplicate-job detection) and `qstat -j <id>` returns 0 while queued/running | `ssh scc qstat` while a job is queued; compare column 3 |
| The SGE log path `…/code/batch/logs/behavior_batch.o<jobid>` is where output lands | after `submit`, `ssh scc 'ls …/code/batch/logs/'` |
| Cluster Python for PASS 3 plots has numpy/pandas/matplotlib/scipy | it runs inside the qsub job; check the SGE log’s plotting section, or set `PY_VENV` (see `submit_behavior.qsub`) |
| The trigger channel names resolve (not `unresolved`) for this rig | the manifest `trigger_confidence` column after the first batch (see §6.2) |

The **local** publish path was validated end-to-end against a synthetic tree by
the publish stage’s own tests, and `PROJECT_ROOT` defaults to the real,
currently-mounted `scape-data` (the `data` symlink to `/Volumes/IMAC/data` is
dangling and is intentionally **not** the default).

---

## 9. What WAS verified locally

- `bash -n` and `shellcheck` (0.11.0, `-S style`) pass clean on
  `fetch_results.sh` and `run_pipeline.sh`.
- `run_pipeline.sh --dry-run` prints the full plan and executes nothing.
- `run_pipeline.sh --stage preflight` (real) correctly **FAILs (exit 1)** on the
  missing ControlMaster socket, SKIPs the cluster checks it can’t reach, and
  still reports the local Python/project-root checks.
- `fetch_results.sh` (default and `--go`) **refuses cleanly (exit 1)** with no
  socket and does not hang.
- The exact invocations the orchestrator emits match the real CLIs of
  `validate_outputs.py`, `publish_to_project.py`, `behavior_panels.py`, and the
  `run_behavior_batch.m` signature (see the delivery report / §5.1).

---

## 10. Related docs

- `README.md` — the batch pipeline itself (two-pass workflow, output schemas,
  alignment convention, legacy bugs fixed, open questions).
- Tool headers — `validate_outputs.py`, `publish_to_project.py`,
  `fetch_results.sh`, `run_pipeline.sh`, `submit_behavior.qsub` each document
  their own flags and safety model.
