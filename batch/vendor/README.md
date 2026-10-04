# vendor/

Authorship: `blinking.m` and `smooth1d.m` are verbatim copies from **Dora Balog's** `../complete_behavior/`; `natsort.m` and `natsortfiles.m` are by Stephen Cobeldick (MATLAB File Exchange; copyright notices kept).

Copies of the shared helper functions the batch pipeline calls, taken from
`../complete_behavior/`.

## Why these are duplicated here

The batch code is rsynced to the cluster as a self-contained directory. The
cluster's own `/projectnb/devorlab/daria/code/complete_behavior` is an OLDER
snapshot that does **not** contain `blinking.m`, so relying on it made every
run fail with:

    Undefined function 'blinking' for input arguments of type 'double'.

Vendoring removes that dependency: `batch/` plus `batch/vendor/` is everything
the pipeline needs. `run_behavior_batch.m` adds this folder to the MATLAB path.

## Deliberately NOT vendored

`rescale.m` — it shadows the MATLAB builtin `rescale`. The batch functions use
a private `rescale01()` instead, so this file must stay out of the path.

## Keeping in sync

These are verbatim copies. If you change a helper in `../complete_behavior/`,
copy it here again and re-run `sync_to_scc.sh --go`.
