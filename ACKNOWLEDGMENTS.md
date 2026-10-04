# Acknowledgments and authorship

This repository is a fork of **Dora Balog's** behavior-tracking code:
[github.com/dorabalog/behavior-tracking](https://github.com/dorabalog/behavior-tracking).

## Who wrote what

| Part | Author | Notes |
|---|---|---|
| `complete_behavior/`, `pupil/`, `whisking/` and the top-level `README.md` | **Dora Balog** (Boston University) | The original pupil-dilation, whisking (motion energy, after Stringer et al. 2019), blinking and trigger-detection analysis. All credit for these methods and their implementation goes to her. |
| `batch/` (except `batch/vendor/`) | Daria Bogatova | Batch / headless SCC pipeline for Femtonics two-photon runs. It calls Dora Balog's functions; it does not replace them. |
| `batch/vendor/blinking.m`, `batch/vendor/smooth1d.m` | from **Dora Balog's** `complete_behavior/` | Verbatim copies, vendored so the cluster job is self-contained. |
| `natsort.m`, `natsortfiles.m` (in `complete_behavior/` and `batch/vendor/`) | Stephen Cobeldick, (c) 2012-2022 | From MATLAB Central File Exchange; their copyright notices are kept in the files. |

The commit history keeps each author's own commits: Dora Balog's original commits come first, and Daria Bogatova's additions are on top.

## Using this code

If you use the pupil, whisking or blinking analysis, please credit Dora Balog and cite her repository above. The original repository does not include a license. Please contact her before you reuse or redistribute her code beyond viewing and forking it on GitHub.
