function results = run_behavior_batch(runs_or_root, roi_file, out_dir, opts)
%RUN_BEHAVIOR_BATCH  Headless PASS 2: process every run with zero prompts.
%
%   results = RUN_BEHAVIOR_BATCH(runs_or_root, roi_file, out_dir, opts)
%
%   Fully NON-INTERACTIVE orchestration of the batch behavior pipeline. It is
%   safe to run under `matlab -batch` on a display-less cluster node: it makes
%   NO input(), NO pause, NO drawellipse/drawrectangle, NO imshow, and creates
%   no figures. All human choices that the original interactive script asked
%   for (1P/2P, ROI draws, pupil threshold, whisker signal, whisker threshold,
%   movie) are resolved automatically: ROIs come from PASS 1 (COLLECT_ROIS)
%   and thresholds come from AUTO_THRESHOLD.
%
%   For each run it:
%     1. looks up the saved ROIs (eye mask + two whisker rectangles),
%     2. computes the pupil trace           (PUPIL_TRACE),
%     3. computes the whisker traces         (WHISKER_TRACE),
%     4. aligns to the imaging trigger        (TRIGGER_ALIGN),
%     5. auto-thresholds pupil & whisker      (AUTO_THRESHOLD) -> bins,
%     6. exports the CSVs                      (EXPORT_BEHAVIOR_CSV),
%     7. saves a backward-compatible per-run .mat.
%
%   INPUTS
%     runs_or_root : struct array from FIND_RUNS, OR a data-root path (char/
%                    string) which is passed to FIND_RUNS to discover runs.
%     roi_file     : path to the ROI .mat produced by COLLECT_ROIS.
%     out_dir      : output root. CSVs go to out_dir/csv, per-run .mat files
%                    to out_dir/mat, and the manifest to out_dir/batch_manifest.csv
%     opts         : (optional) struct with any of:
%                      .overwrite        logical, reprocess done runs (false)
%                      .min_frames       forwarded to FIND_RUNS when a root is
%                                        given (default 100)
%                      .pupil_threshold  numeric manual pupil threshold ([])
%                      .whisker_threshold numeric manual whisker threshold ([])
%                      .pupil_method     'otsu'|'percentile' (default 'otsu')
%                      .whisker_method   'otsu'|'percentile' (default 'otsu')
%                      .whisker_binning  'long'|'pad' signal to bin ('long')
%                      .write_trigger_csv logical (default true)
%                      .crop_to_window   logical (default FALSE). false =
%                          store full-length traces in the .mat and let
%                          post-processing crop using the in_imaging_window
%                          flag / settings.keep. true = physically crop to the
%                          imaging window (legacy behaviour).
%                      .pupil            opts struct forwarded to PUPIL_TRACE
%                      .whisker          opts struct forwarded to WHISKER_TRACE
%                      .trigger          opts struct forwarded to TRIGGER_ALIGN
%                      .complete_behavior_path path added for shared helpers
%
%   OUTPUT
%     results : 1xN struct array (the manifest rows), one per run, with the
%               identity, status ('ok'|'failed'|'skipped'), thresholds,
%               resolved trigger channels + confidence, crop bookkeeping,
%               output paths, message and warnings for each run.
%
%   PER-RUN ERROR ISOLATION: every run is wrapped in try/catch, so one bad run
%   (unreadable frame, mask-size mismatch, corrupt trigger, ...) is recorded as
%   'failed' with its error message and stack, and the batch continues.
%
%   RESUMABILITY: runs whose outputs already exist are 'skipped' unless
%   opts.overwrite is true, so a batch can be safely re-run after partial
%   failures.
%
%   BACKWARD-COMPATIBLE .mat: saved (in v7 format for scipy.io.loadmat) with
%   the original nested layout so existing Python keeps working:
%       info    : mouse, date, run
%       settings: thresholds, channels, crop bookkeeping, provenance
%       pupil   : pupil_raw, pupil_smooth, pupil_bins
%       whisker : whisker_raw_long, whisker_smooth_long,
%                 whisker_raw_pad, whisker_smooth_pad, whisker_bins

    % ---- options --------------------------------------------------------
    if nargin < 4 || isempty(opts) || ~isstruct(opts)
        opts = struct();
    end
    defaults = struct('overwrite', false, 'min_frames', 100, ...
                      'pupil_threshold', [], 'whisker_threshold', [], ...
                      'pupil_method', 'otsu', 'whisker_method', 'otsu', ...
                      'whisker_binning', 'long', 'write_trigger_csv', true, ...
                      'crop_to_window', false, ...
                      'pupil_polarity', 'auto', ...
                      'complete_behavior_path', '');
    opts = fill_defaults(opts, defaults);
    if ~isfield(opts, 'pupil')   || ~isstruct(opts.pupil),   opts.pupil = struct();   end
    if ~isfield(opts, 'whisker') || ~isstruct(opts.whisker), opts.whisker = struct(); end
    if ~isfield(opts, 'trigger') || ~isstruct(opts.trigger), opts.trigger = struct(); end

    % ---- make sure shared helpers are on the path (headless-safe) -------
    this_dir = fileparts(mfilename('fullpath'));
    addpath(this_dir);
    % vendor/ holds verbatim copies of the helpers this pipeline calls
    % (natsortfiles, natsort, blinking, smooth1d). It is added FIRST so the
    % batch always uses a known-good version. The cluster's own
    % complete_behavior snapshot is older and lacks blinking.m, which made
    % every run fail with "Undefined function 'blinking'"; vendoring removes
    % that dependency entirely. See vendor/README.md.
    vendor_dir = fullfile(this_dir, 'vendor');
    if isfolder(vendor_dir)
        addpath(vendor_dir);
    end
    cb = opts.complete_behavior_path;
    if isempty(cb)
        cb = fullfile(this_dir, '..', 'complete_behavior');
    end
    if isfolder(cb)
        addpath(cb);
    end

    % ---- resolve the run inventory --------------------------------------
    if isstruct(runs_or_root)
        runs = runs_or_root;
    elseif ischar(runs_or_root) || isstring(runs_or_root)
        fopts = struct('min_frames', opts.min_frames, 'report', false, ...
                       'verbose', true);
        runs = find_runs(char(string(runs_or_root)), fopts);
    else
        error('run_behavior_batch:badRuns', ...
            'runs_or_root must be a runs struct array or a data-root path.');
    end

    results = make_manifest_row();
    results = results([]);   % empty manifest with the right fields
    if isempty(runs)
        fprintf('run_behavior_batch: no runs to process.\n');
        write_manifest(fullfile(out_dir, 'batch_manifest.csv'), results);
        return;
    end

    % ---- output layout --------------------------------------------------
    out_dir = char(string(out_dir));
    csv_dir = fullfile(out_dir, 'csv');
    mat_dir = fullfile(out_dir, 'mat');
    ensure_dir(out_dir);
    ensure_dir(csv_dir);
    ensure_dir(mat_dir);
    manifest_csv = fullfile(out_dir, 'batch_manifest.csv');

    % ---- load ROIs ------------------------------------------------------
    [roi_map_keys, roi_entries] = load_roi_map(roi_file);

    nRuns = numel(runs);
    fprintf('run_behavior_batch: %d run(s); ROI file %s (%d ROI entries)\n', ...
        nRuns, char(string(roi_file)), numel(roi_entries));

    results = repmat(make_manifest_row(), 1, nRuns);

    % ---- process each run (isolated) ------------------------------------
    for i = 1:nRuns
        run = runs(i);
        row = make_manifest_row();
        row.idx          = i;
        row.run_id       = getf(run, 'run_id', '');
        row.mouse        = getf(run, 'mouse', '');
        row.date         = getf(run, 'date', '');
        row.base_name    = base_name_of(run);
        row.camera_dir   = getf(run, 'camera_dir', '');
        row.trigger_file = getf(run, 'trigger_file', '');

        base = row.base_name;
        try
            row = process_one(run, row, base, csv_dir, mat_dir, ...
                              roi_map_keys, roi_entries, opts);
        catch ME
            row.status  = 'failed';
            row.message = one_line(ME.message);
            row.warnings = one_line(getReport(ME, 'basic'));
            fprintf('[%d/%d] FAILED  %s : %s\n', i, nRuns, base, row.message);
        end
        results(i) = row;
    end

    % ---- manifest + summary ---------------------------------------------
    write_manifest(manifest_csv, results);
    print_summary(results, manifest_csv);
end

% ========================================================================
function row = process_one(run, row, base, csv_dir, mat_dir, roi_keys, roi_entries, opts)
%PROCESS_ONE  Do the full single-run pipeline; fills and returns manifest row.
    camera_dir   = getf(run, 'camera_dir', '');
    trigger_file = getf(run, 'trigger_file', '');

    mat_path     = fullfile(mat_dir, [base '_behavior.mat']);
    behavior_csv = fullfile(csv_dir, [base '_behavior.csv']);
    row.mat_path     = mat_path;
    row.behavior_csv = behavior_csv;

    % ---- skip already-done runs ----------------------------------------
    if ~opts.overwrite && isfile(mat_path) && isfile(behavior_csv)
        row.status  = 'skipped';
        row.message = 'outputs already exist';
        fprintf('[%s] SKIP (already done)\n', base);
        return;
    end

    % ---- locate ROI entry ----------------------------------------------
    entry = lookup_roi(run, roi_keys, roi_entries);
    if isempty(entry)
        error('run_behavior_batch:noRoi', ...
            'no ROI recorded for this run (run PASS 1 collect_rois first)');
    end

    % ---- pupil ----------------------------------------------------------
    mask = logical(entry.pupil_mask);
    % Forward the dataset-level polarity choice into pupil_trace unless the
    % caller already set it explicitly in opts.pupil.
    popts = opts.pupil;
    if ~isfield(popts, 'polarity') || isempty(popts.polarity)
        popts.polarity = opts.pupil_polarity;
    end
    [pupil_raw, pupil_smooth, pdiag] = pupil_trace(camera_dir, mask, popts);
    row.n_frames = pdiag.n_frames;
    row.pupil_polarity = one_line(pdiag.polarity);

    % ---- whisker --------------------------------------------------------
    [w, ~] = whisker_trace(camera_dir, entry.roi_long, entry.roi_pad, opts.whisker);

    % ---- trigger alignment ---------------------------------------------
    n_frames = numel(pupil_raw);
    [aligned, tinfo] = trigger_align(trigger_file, n_frames, opts.trigger);
    row.imaging_channel     = chan(tinfo, 'imaging');
    row.camera_channel      = chan(tinfo, 'camera');
    row.trigger_confidence  = getf(tinfo, 'confidence', 'unresolved');
    row.trigger_applied     = double(logical(getf(aligned, 'applied', false)));
    row.n_camera_edges      = num_or_nan(getf(tinfo, 'n_camera_edges', NaN));
    row.n_tiff_frames       = num_or_nan(getf(tinfo, 'n_tiff_frames', NaN));
    row.n_used              = num_or_nan(getf(tinfo, 'n_used', NaN));

    % ---- reconcile lengths ---------------------------------------------
    keep_full = logical(aligned.keep(:).');
    n = min([numel(pupil_raw), numel(w.raw_long), numel(keep_full)]);
    n = max(0, n);

    pr  = row_slice(pupil_raw,     n);
    ps  = row_slice(pupil_smooth,  n);
    wrl = row_slice(w.raw_long,    n);
    wsl = row_slice(w.smooth_long, n);
    wrp = row_slice(w.raw_pad,     n);
    wsp = row_slice(w.smooth_pad,  n);
    keep = keep_full(1:n);

    row.n_kept    = sum(keep);
    row.n_dropped = n - row.n_kept;
    row.crop_to_window = double(logical(opts.crop_to_window));

    % ---- auto-threshold (on the in-window, cropped smooth signals) ------
    pupil_method   = threshold_method(opts.pupil_threshold,   opts.pupil_method);
    whisker_method = threshold_method(opts.whisker_threshold, opts.whisker_method);

    ps_crop  = ps(keep);
    if strcmpi(opts.whisker_binning, 'pad')
        wbin_src_full = wsp;
    else
        wbin_src_full = wsl;
    end
    wbin_src_crop = wbin_src_full(keep);

    [pupil_thr,   pinfo] = auto_threshold(ps_crop,       pupil_method);
    [whisker_thr, winfo] = auto_threshold(wbin_src_crop, whisker_method);
    row.pupil_threshold   = pupil_thr;
    row.whisker_threshold = whisker_thr;
    row.pupil_method      = one_line(pinfo.method);
    row.whisker_method    = one_line(winfo.method);

    % ---- CSV export: full (flagged) frames, aligned owns the crop flag --
    pupil_full = struct('pupil_raw', pr, 'pupil_smooth', ps, ...
        'pupil_bins', apply_threshold(ps, pupil_thr));
    whisker_full = struct( ...
        'whisker_raw_long',    wrl, 'whisker_smooth_long', wsl, ...
        'whisker_raw_pad',     wrp, 'whisker_smooth_pad',  wsp, ...
        'whisker_bins',        apply_threshold(wbin_src_full, whisker_thr));

    exopts = struct();
    exopts.write_trigger_csv = opts.write_trigger_csv;
    exopts.trigger_info      = tinfo;
    exopts.pupil_threshold   = pupil_thr;
    exopts.whisker_threshold = whisker_thr;
    exopts.root_folder       = camera_dir;
    exopts.thresholds = struct('pupil_threshold', pupil_thr, ...
                               'whisker_threshold', whisker_thr);
    files = export_behavior_csv(csv_dir, base, pupil_full, whisker_full, ...
                                aligned, trigger_file, exopts);
    if isfield(files, 'behavior'), row.behavior_csv = files.behavior; end
    if isfield(files, 'accel'),    row.accel_csv    = files.accel;    end

    % ---- per-run .mat -----------------------------------------------------
    % opts.crop_to_window controls whether the traces stored in the .mat are
    % physically cropped to the imaging window.
    %   false (DEFAULT): store FULL-LENGTH traces. Nothing is discarded; the
    %       behaviour CSV's in_imaging_window flag (and settings.keep below)
    %       records which samples fall inside the window so cropping can be
    %       done later in post-processing. This is the right mode for a 2P
    %       rig where the imaging trigger is a sparse start pulse rather than
    %       a per-frame trigger, and for any workflow that crops downstream.
    %   true: reproduce the legacy behaviour of the original interactive
    %       script, which physically cropped to the window.
    if opts.crop_to_window
        sel = keep;
    else
        sel = true(1, n);
    end
    pr_c  = pr(sel);
    ps_c  = ps(sel);
    wrl_c = wrl(sel);
    wsl_c = wsl(sel);
    wrp_c = wrp(sel);
    wsp_c = wsp(sel);
    wbin_src_sel = wbin_src_full(sel);
    nc = min([numel(pr_c), numel(wsl_c)]);
    nc = max(0, nc);

    info = struct('mouse', getf(run, 'mouse', ''), ...
                  'date',  getf(run, 'date', ''), ...
                  'run',   getf(run, 'run_id', ''));

    settings = struct();
    settings.root_folder       = camera_dir;
    settings.trigger_file      = char(string(trigger_file));
    settings.binning_choice    = lower(char(string(opts.whisker_binning)));
    settings.pupil_threshold   = pupil_thr;
    settings.whisker_threshold = whisker_thr;
    settings.pupil_method      = one_line(pinfo.method);
    settings.whisker_method    = one_line(winfo.method);
    settings.threshold         = whisker_thr;   % original field name kept
    settings.fs                = getf(aligned, 'fs', NaN);
    settings.trigger_applied   = logical(getf(aligned, 'applied', false));
    settings.imaging_channel   = chan(tinfo, 'imaging');
    settings.camera_channel    = chan(tinfo, 'camera');
    settings.trigger_confidence = getf(tinfo, 'confidence', 'unresolved');
    settings.imaging_window_s  = getf(aligned, 'imaging_window_s', [NaN NaN]);
    settings.n_frames          = n_frames;
    settings.n_kept            = row.n_kept;
    settings.n_dropped         = row.n_dropped;
    % Crop bookkeeping. When crop_to_window is false the traces above are
    % FULL LENGTH and `keep` is the mask of samples inside the imaging
    % window, so post-processing can crop with pupil_raw(settings.keep).
    settings.crop_to_window    = logical(opts.crop_to_window);
    settings.keep              = keep;
    settings.aligned_time_s    = row_slice(getf(aligned, 'frame_time_s', []), n);
    settings.frame_used        = getf(entry, 'frame_used', '');
    settings.eye_ellipse       = getf(entry, 'eye_ellipse', struct());
    settings.roi_long          = entry.roi_long;
    settings.roi_pad           = entry.roi_pad;

    pupil = struct('pupil_raw',    row_slice(pr_c, nc), ...
                   'pupil_smooth', row_slice(ps_c, nc), ...
                   'pupil_bins',   apply_threshold(row_slice(ps_c, nc), pupil_thr));

    whisker = struct( ...
        'whisker_raw_long',    row_slice(wrl_c, nc), ...
        'whisker_smooth_long', row_slice(wsl_c, nc), ...
        'whisker_raw_pad',     row_slice(wrp_c, nc), ...
        'whisker_smooth_pad',  row_slice(wsp_c, nc), ...
        'whisker_bins',        apply_threshold(row_slice(wbin_src_sel, nc), whisker_thr));

    save(mat_path, 'info', 'settings', 'pupil', 'whisker', '-v7');
    row.mat_path = mat_path;

    % ---- warnings + status ---------------------------------------------
    wparts = {};
    if ~isempty(getf(tinfo, 'warning', '')), wparts{end+1} = tinfo.warning; end
    if ~isempty(getf(pinfo, 'warning', '')), wparts{end+1} = ['pupil: ' pinfo.warning]; end
    if ~isempty(getf(winfo, 'warning', '')), wparts{end+1} = ['whisker: ' winfo.warning]; end
    row.warnings = one_line(strjoin(wparts, ' | '));
    row.status   = 'ok';

    fprintf(['[%s] OK  frames=%d kept=%d dropped=%d  pupilThr=%.3f whiskThr=%.3f  ' ...
        'img=%s cam=%s (%s)\n'], base, row.n_frames, row.n_kept, row.n_dropped, ...
        pupil_thr, whisker_thr, blankstr(row.imaging_channel), ...
        blankstr(row.camera_channel), row.trigger_confidence);
end

% ========================================================================
function [keys, entries] = load_roi_map(roi_file)
%LOAD_ROI_MAP  Load the ROI struct array; return keys + entries.
    keys = {};
    entries = struct([]);
    roi_file = char(string(roi_file));
    if isempty(roi_file) || ~isfile(roi_file)
        warning('run_behavior_batch:noRoiFile', ...
            'ROI file not found: %s (all runs will fail with no-ROI).', roi_file);
        return;
    end
    S = load(roi_file);
    if isfield(S, 'rois') && isstruct(S.rois) && ~isempty(S.rois)
        entries = S.rois;
        if isfield(entries, 'key')
            keys = {entries.key};
        else
            keys = repmat({''}, 1, numel(entries));
        end
    end
end

% ========================================================================
function entry = lookup_roi(run, keys, entries)
%LOOKUP_ROI  Find the ROI entry for RUN by camera_dir, then base_name/run_id.
    entry = [];
    if isempty(entries)
        return;
    end
    cam = getf(run, 'camera_dir', '');
    idx = find(strcmp(keys, cam), 1);
    if isempty(idx) && isfield(entries, 'camera_dir')
        idx = find(strcmp({entries.camera_dir}, cam), 1);
    end
    if isempty(idx) && isfield(entries, 'base_name')
        idx = find(strcmp({entries.base_name}, base_name_of(run)), 1);
    end
    if isempty(idx) && isfield(entries, 'run_id')
        rid = getf(run, 'run_id', '');
        if ~isempty(rid)
            idx = find(strcmp({entries.run_id}, rid), 1);
        end
    end
    if ~isempty(idx)
        entry = entries(idx);
    end
end

% ========================================================================
function m = threshold_method(manual_val, named)
%THRESHOLD_METHOD  Manual numeric override wins; else the named method.
    if ~isempty(manual_val) && isnumeric(manual_val) && isscalar(manual_val)
        m = manual_val;
    else
        m = named;
    end
end

% ========================================================================
function b = apply_threshold(sig, thr)
%APPLY_THRESHOLD  Binarize like thresholding.m (<thr->0, >=thr->1; NaN kept).
    b = sig;
    b(sig <  thr) = 0;
    b(sig >= thr) = 1;
end

% ========================================================================
function y = row_slice(x, n)
%ROW_SLICE  First N elements of X as a row vector (n<=0 -> []).
    x = x(:).';
    if n <= 0
        y = [];
    elseif numel(x) >= n
        y = x(1:n);
    else
        y = [x, nan(1, n - numel(x))];
    end
end

% ========================================================================
function write_manifest(manifest_csv, results)
%WRITE_MANIFEST  Write the manifest struct array to CSV (robust to 0 rows).
    ensure_dir(fileparts(manifest_csv));
    if isempty(results)
        hdr = fieldnames(make_manifest_row());
        fid = fopen(manifest_csv, 'w');
        if fid ~= -1
            fprintf(fid, '%s\n', strjoin(hdr(:).', ','));
            fclose(fid);
        end
        return;
    end
    % 'AsArray' is required for the single-run case: struct2table on a SCALAR
    % struct maps each field to a COLUMN, so an empty char field ('' -> 0 rows)
    % collides with scalar numeric fields (1 row) and errors out. Treating the
    % struct as a 1-row array avoids that. Harmless for numel(results) > 1.
    T = struct2table(results, 'AsArray', true);
    writetable(T, manifest_csv);
end

% ========================================================================
function print_summary(results, manifest_csv)
%PRINT_SUMMARY  Print N ok / failed / skipped and list any failures.
    stat = {results.status};
    nok   = sum(strcmp(stat, 'ok'));
    nfail = sum(strcmp(stat, 'failed'));
    nskip = sum(strcmp(stat, 'skipped'));
    fprintf('\n==================== batch summary ====================\n');
    fprintf('  ok      : %d\n', nok);
    fprintf('  failed  : %d\n', nfail);
    fprintf('  skipped : %d\n', nskip);
    if nfail > 0
        fprintf('  failures:\n');
        for i = 1:numel(results)
            if strcmp(results(i).status, 'failed')
                fprintf('    - %s : %s\n', results(i).base_name, results(i).message);
            end
        end
    end
    fprintf('  manifest: %s\n', manifest_csv);
    fprintf('=======================================================\n');
end

% ========================================================================
function row = make_manifest_row()
%MAKE_MANIFEST_ROW  Prototype manifest row with all fields (fixed types).
    row = struct( ...
        'idx', 0, 'run_id', '', 'mouse', '', 'date', '', 'base_name', '', ...
        'camera_dir', '', 'trigger_file', '', 'n_frames', NaN, ...
        'status', 'pending', 'message', '', ...
        'pupil_threshold', NaN, 'whisker_threshold', NaN, ...
        'pupil_method', '', 'whisker_method', '', ...
        'imaging_channel', '', 'camera_channel', '', ...
        'trigger_confidence', '', 'trigger_applied', NaN, ...
        'n_camera_edges', NaN, 'n_tiff_frames', NaN, 'n_used', NaN, ...
        'n_kept', NaN, 'n_dropped', NaN, 'crop_to_window', NaN, 'pupil_polarity', '', ...
        'mat_path', '', 'behavior_csv', '', 'accel_csv', '', 'warnings', '');
end

% ========================================================================
function s = base_name_of(run)
%BASE_NAME_OF  Prefer run.base_name; else join mouse_date_run_id.
    s = getf(run, 'base_name', '');
    if isempty(s)
        pieces = {getf(run, 'mouse', ''), getf(run, 'date', ''), getf(run, 'run_id', '')};
        pieces = pieces(~cellfun(@isempty, pieces));
        if isempty(pieces)
            s = 'run';
        else
            s = strjoin(pieces, '_');
        end
    end
end

% ========================================================================
function c = chan(tinfo, which)
%CHAN  Extract a resolved channel name from a trigger info struct.
    c = '';
    if isstruct(tinfo) && isfield(tinfo, 'channels') && isstruct(tinfo.channels) ...
            && isfield(tinfo.channels, which)
        c = char(string(tinfo.channels.(which)));
    end
end

% ========================================================================
function v = getf(s, f, d)
%GETF  Return s.(f) if present and non-empty, else default d.
    if isstruct(s) && isfield(s, f) && ~isempty(s.(f))
        v = s.(f);
    else
        v = d;
    end
end

% ========================================================================
function v = num_or_nan(x)
%NUM_OR_NAN  Coerce to a scalar double or NaN.
    if isnumeric(x) && isscalar(x)
        v = double(x);
    else
        v = NaN;
    end
end

% ========================================================================
function s = one_line(s)
%ONE_LINE  Collapse newlines/CR to ' | ' so a value stays on one CSV cell.
    s = char(string(s));
    s = regexprep(s, '[\r\n]+', ' | ');
end

% ========================================================================
function s = blankstr(x)
%BLANKSTR  '(none)' for an empty string, else the string itself.
    s = char(string(x));
    if isempty(s)
        s = '(none)';
    end
end

% ========================================================================
function ensure_dir(d)
%ENSURE_DIR  Create directory D (and parents) if missing.
    if ~isempty(d) && ~isfolder(d)
        mkdir(d);
    end
end

% ========================================================================
function s = fill_defaults(s, defaults)
%FILL_DEFAULTS  Copy missing/empty fields from DEFAULTS into S.
    if isempty(s) || ~isstruct(s)
        s = struct();
    end
    fn = fieldnames(defaults);
    for ii = 1:numel(fn)
        if ~isfield(s, fn{ii}) || isempty(s.(fn{ii}))
            s.(fn{ii}) = defaults.(fn{ii});
        end
    end
end
