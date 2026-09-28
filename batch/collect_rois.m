function roi_file = collect_rois(runs, roi_file, opts)
%COLLECT_ROIS  Interactive PASS 1: draw & persist the three ROIs per run.
%
%   roi_file = COLLECT_ROIS(runs, roi_file, opts)
%
%   This is the ONLY interactive component of the batch pipeline and the ONLY
%   place a display is required. For each run it shows a representative frame
%   (the middle frame, as the original interactive code did) and asks the
%   human to draw three ROIs:
%       1. an ELLIPSE around the eye        -> logical pupil mask + geometry
%       2. a RECTANGLE around the long whiskers -> [x y w h]
%       3. a RECTANGLE around the whisker pad   -> [x y w h]
%   Keeping the original UX: adjust the shape, then press ENTER to accept.
%   NOTHING ELSE is asked (no 1P/2P, no thresholds, no movie prompts) -- those
%   were the questions PASS 2 removes.
%
%   RESUMABILITY: an existing roi_file is loaded and any run already recorded
%   is SKIPPED, so a session can be interrupted and resumed and new runs
%   appended later. Results are saved incrementally AFTER EACH run, so a crash
%   (or Ctrl-C, or closing the figure) loses at most one run of clicking.
%
%   INPUTS
%     runs     : struct array from FIND_RUNS (needs .camera_dir; uses
%                .run_id/.mouse/.date/.base_name for labelling & keys).
%     roi_file : path to the .mat that stores the ROIs (created if absent).
%     opts     : (optional) struct with any of:
%                  .overwrite  logical (redo ALL) OR a cell array / string of
%                              run keys (base_name, run_id, or camera_dir) to
%                              redo. Default false (skip recorded runs).
%                  .ellipse_color  drawellipse color (default 'r')
%                  .rect_color     drawrectangle color (default 'r')
%
%   OUTPUT
%     roi_file : the same path, now containing a struct array variable `rois`.
%
%   PERSISTED per run (fields of each element of `rois`):
%     .key            unique key (the absolute camera_dir)
%     .run_id .mouse .date .base_name .camera_dir
%     .frame_used     filename of the frame shown
%     .frame_index    index of that frame among the non-dot entries
%     .frame_size     [rows cols] of that frame
%     .eye_ellipse    struct(.center,.semiaxes,.rotation_deg,.vertices)
%     .pupil_mask     logical mask (rasterized ellipse), frame-sized
%     .roi_long       [x y w h] rectangle around the long whiskers
%     .roi_pad        [x y w h] rectangle around the whisker pad
%     .timestamp      datestr when this run was annotated
%
%   Storing BOTH the ellipse geometry and the rasterized mask means the ROI
%   stays reinterpretable if the frame size ever changes downstream.
%
%   Requires the Image Processing Toolbox (drawellipse/drawrectangle/
%   createMask) and a display. natsortfiles must be on the path.

    if nargin < 3 || isempty(opts) || ~isstruct(opts)
        opts = struct();
    end
    defaults = struct('overwrite', false, 'ellipse_color', 'r', 'rect_color', 'r');
    opts = fill_defaults(opts, defaults);

    roi_file = char(string(roi_file));
    if isempty(roi_file)
        error('collect_rois:noFile', 'roi_file path must be provided.');
    end
    ensure_parent_dir(roi_file);

    if isempty(runs)
        fprintf('collect_rois: no runs supplied; nothing to do.\n');
        return;
    end

    % ---- load any existing ROIs (resume) --------------------------------
    rois = load_rois(roi_file);
    existing_keys = keys_of(rois);

    % ---- resolve overwrite set ------------------------------------------
    [overwrite_all, overwrite_set] = parse_overwrite(opts.overwrite);

    nRuns = numel(runs);
    fprintf('collect_rois: %d run(s) supplied; %d already recorded in %s\n', ...
        nRuns, numel(existing_keys), roi_file);

    % ---- main loop ------------------------------------------------------
    fig = [];
    for i = 1:nRuns
        run = runs(i);
        key = run_key(run);
        base = run_label(run);

        already = any(strcmp(existing_keys, key));
        redo = overwrite_all || is_in_set(overwrite_set, run);

        if already && ~redo
            fprintf('[%d/%d] SKIP (already recorded): %s\n', i, nRuns, base);
            continue;
        end

        fprintf('[%d/%d] annotate: %s\n', i, nRuns, base);

        % pick the representative (middle) frame
        try
            [frame_path, frame_name, frame_idx] = middle_frame(run.camera_dir);
        catch ME
            fprintf('   !! cannot read frames from %s (%s); skipping this run.\n', ...
                run.camera_dir, ME.message);
            continue;
        end

        % draw the three ROIs; a closed figure / interrupt ends the session
        try
            [fig, entry] = annotate_one(fig, frame_path, frame_name, frame_idx, ...
                                        run, key, opts);
        catch ME
            if strcmp(ME.identifier, 'collect_rois:userQuit') || ...
               figure_gone(fig)
                fprintf('   session ended by user; keeping %d recorded run(s).\n', ...
                    numel(rois));
                break;
            else
                fprintf('   !! error annotating %s (%s); skipping this run.\n', ...
                    base, ME.message);
                continue;
            end
        end

        % upsert into rois and SAVE INCREMENTALLY (crash-safe)
        rois = upsert(rois, entry);
        existing_keys = keys_of(rois);
        try
            save(roi_file, 'rois', '-v7');   %#ok<*NASGU>
            fprintf('   saved ROI for %s (%d run(s) recorded).\n', base, numel(rois));
        catch ME
            fprintf('   !! FAILED to save %s: %s\n', roi_file, ME.message);
        end
    end

    if ~isempty(fig) && isvalid(fig)
        close(fig);
    end
    fprintf('collect_rois: done. %d run(s) recorded in %s\n', numel(rois), roi_file);
end

% ========================================================================
function [fig, entry] = annotate_one(fig, frame_path, frame_name, frame_idx, run, key, opts)
%ANNOTATE_ONE  Show the frame and collect the eye ellipse + two rectangles.
    tf = Tiff(frame_path, 'r');
    imageData = im2uint8(read(tf));
    close(tf);
    frame_size = size(imageData);

    fig = ensure_figure(fig);

    % 1) eye ellipse -> logical mask + geometry
    show_frame(fig, imageData, sprintf('%s  |  Draw ELLIPSE around the eye', run_label(run)));
    el = drawellipse('Color', opts.ellipse_color);
    disp('   adjust the ELLIPSE, then press ENTER to accept');
    wait_or_quit(fig);
    check_roi(el, fig);
    eye_ellipse = struct('center', el.Center, 'semiaxes', el.SemiAxes, ...
                         'rotation_deg', el.RotationAngle, 'vertices', el.Vertices);
    pupil_mask = createMask(el, imageData);

    % 2) long-whisker rectangle -> [x y w h]
    show_frame(fig, imageData, sprintf('%s  |  Draw RECTANGLE around the LONG whiskers', run_label(run)));
    r1 = drawrectangle('Color', opts.rect_color);
    disp('   adjust the RECTANGLE, then press ENTER to accept');
    wait_or_quit(fig);
    check_roi(r1, fig);
    roi_long = r1.Position;

    % 3) whisker-pad rectangle -> [x y w h]
    show_frame(fig, imageData, sprintf('%s  |  Draw RECTANGLE around the WHISKER PAD', run_label(run)));
    r2 = drawrectangle('Color', opts.rect_color);
    disp('   adjust the RECTANGLE, then press ENTER to accept');
    wait_or_quit(fig);
    check_roi(r2, fig);
    roi_pad = r2.Position;

    entry = struct();
    entry.key         = key;
    entry.run_id      = getfield_default(run, 'run_id', '');
    entry.mouse       = getfield_default(run, 'mouse', '');
    entry.date        = getfield_default(run, 'date', '');
    entry.base_name   = run_label(run);
    % Record the CLUSTER camera_dir here (== the ROI key), NOT the local staging
    % path the frame was read from: run_behavior_batch's lookup_roi falls back to
    % comparing entries' camera_dir, so this field must match what find_runs
    % produces on the cluster. In the normal on-cluster case key == run.camera_dir,
    % so this is unchanged; only the local-staging path (remote_camera_dir set)
    % differs, and there the cluster path is exactly what we must store.
    entry.camera_dir  = key;
    entry.frame_used  = frame_name;
    entry.frame_index = frame_idx;
    entry.frame_size  = frame_size;
    entry.eye_ellipse = eye_ellipse;
    entry.pupil_mask  = logical(pupil_mask);
    entry.roi_long    = roi_long;
    entry.roi_pad     = roi_pad;
    entry.timestamp   = char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss'));
end

% ========================================================================
function wait_or_quit(fig)
%WAIT_OR_QUIT  Pause for a keypress; treat a closed figure as a clean quit.
    if figure_gone(fig)
        error('collect_rois:userQuit', 'Figure closed by user.');
    end
    pause;   % wait for ENTER / keypress (original UX)
    if figure_gone(fig)
        error('collect_rois:userQuit', 'Figure closed by user.');
    end
end

% ========================================================================
function check_roi(roi, fig)
%CHECK_ROI  Ensure the ROI object is still valid (figure not closed).
    if figure_gone(fig) || isempty(roi) || ~isvalid(roi)
        error('collect_rois:userQuit', 'ROI not completed (figure closed).');
    end
end

% ========================================================================
function tf = figure_gone(fig)
%FIGURE_GONE  True if the figure handle is no longer a valid open figure.
    tf = isempty(fig) || ~ishandle(fig) || ~isvalid(fig);
end

% ========================================================================
function fig = ensure_figure(fig)
%ENSURE_FIGURE  Return a valid figure handle, creating one if needed.
    if figure_gone(fig)
        fig = figure('Position', [100 100 960 600], 'Name', 'collect_rois', ...
                     'NumberTitle', 'off');
    end
end

% ========================================================================
function show_frame(fig, imageData, ttl)
%SHOW_FRAME  Display a frame in FIG with a title (clears previous drawing).
    figure(fig);
    clf(fig);
    imshow(imageData, 'InitialMagnification', 'fit');
    title(ttl, 'Interpreter', 'none');
end

% ========================================================================
function [frame_path, frame_name, frame_idx] = middle_frame(camera_dir)
%MIDDLE_FRAME  Path/name/index of the middle frame (natsortfiles, no dotdirs).
    listing = natsortfiles(dir(camera_dir));
    names = {listing.name};
    isdot = strcmp(names, '.') | strcmp(names, '..');
    isdirf = [listing.isdir];
    keep = ~isdot & ~isdirf;
    frames = listing(keep);
    if isempty(frames)
        error('collect_rois:noFrames', 'No frames found in %s', camera_dir);
    end
    frame_idx = max(1, floor(numel(frames) / 2));
    frame_name = frames(frame_idx).name;
    frame_path = fullfile(camera_dir, frame_name);
end

% ========================================================================
function rois = load_rois(roi_file)
%LOAD_ROIS  Load the existing `rois` struct array or return an empty one.
    rois = struct([]);
    if isfile(roi_file)
        try
            S = load(roi_file);
            if isfield(S, 'rois') && isstruct(S.rois)
                rois = S.rois;
            end
        catch ME
            warning('collect_rois:loadFailed', ...
                'Could not load existing %s (%s); starting fresh.', roi_file, ME.message);
        end
    end
end

% ========================================================================
function rois = upsert(rois, entry)
%UPSERT  Insert ENTRY into ROIS, replacing any element with the same key.
    if isempty(rois)
        rois = entry;
        return;
    end
    ks = keys_of(rois);
    idx = find(strcmp(ks, entry.key), 1);
    % align fields so struct assignment/concatenation stays consistent
    entry = orderfields_like(entry, rois);
    if isempty(idx)
        rois(end+1) = entry;
    else
        rois(idx) = entry;
    end
end

% ========================================================================
function e = orderfields_like(e, template)
%ORDERFIELDS_LIKE  Reorder E's fields to match TEMPLATE's field order.
    if isempty(template)
        return;
    end
    tf = fieldnames(template);
    ef = fieldnames(e);
    if isequal(tf, ef)
        return;
    end
    % add any missing fields (in either direction) then order like template
    for k = 1:numel(tf)
        if ~isfield(e, tf{k})
            e.(tf{k}) = [];
        end
    end
    e = orderfields(e, tf);
end

% ========================================================================
function ks = keys_of(rois)
%KEYS_OF  Cell array of keys for a rois struct array ({} if empty).
    if isempty(rois) || ~isfield(rois, 'key')
        ks = {};
    else
        ks = {rois.key};
    end
end

% ========================================================================
function k = run_key(run)
%RUN_KEY  Unique key for a run (absolute camera_dir).
%   If the run carries a non-empty `remote_camera_dir` field it is used as the
%   key instead. This is set by local_roi_runs.m when the reference frame was
%   staged LOCALLY for ROI drawing: the ROI file is CONSUMED on the cluster, so
%   the key MUST be the CLUSTER camera_dir that run_behavior_batch's lookup_roi
%   searches for -- not the local staging path the frame was read from. When the
%   field is absent (the normal on-cluster case) behaviour is unchanged.
    ov = getfield_default(run, 'remote_camera_dir', '');
    if ~isempty(ov)
        k = char(string(ov));
    else
        k = char(string(getfield_default(run, 'camera_dir', '')));
    end
end

% ========================================================================
function s = run_label(run)
%RUN_LABEL  Human-friendly label for a run.
    s = char(string(getfield_default(run, 'base_name', '')));
    if isempty(s)
        pieces = {getfield_default(run, 'mouse', ''), ...
                  getfield_default(run, 'date', ''), ...
                  getfield_default(run, 'run_id', '')};
        pieces = pieces(~cellfun(@isempty, pieces));
        if isempty(pieces)
            s = run_key(run);
        else
            s = strjoin(pieces, '_');
        end
    end
end

% ========================================================================
function [all_flag, set_cell] = parse_overwrite(ov)
%PARSE_OVERWRITE  Interpret opts.overwrite as (redo-all) + (set of keys).
    all_flag = false;
    set_cell = {};
    if islogical(ov) || isnumeric(ov)
        all_flag = ~isempty(ov) && all(logical(ov(:)));
    elseif ischar(ov) || isstring(ov)
        set_cell = cellstr(string(ov));
    elseif iscell(ov)
        set_cell = cellfun(@(x) char(string(x)), ov, 'UniformOutput', false);
    end
end

% ========================================================================
function tf = is_in_set(set_cell, run)
%IS_IN_SET  True if RUN matches any key in SET_CELL (base_name/run_id/dir).
    tf = false;
    if isempty(set_cell)
        return;
    end
    cand = {run_key(run), getfield_default(run, 'base_name', ''), ...
            getfield_default(run, 'run_id', '')};
    cand = cand(~cellfun(@isempty, cand));
    for k = 1:numel(set_cell)
        if any(strcmp(cand, set_cell{k}))
            tf = true;
            return;
        end
    end
end

% ========================================================================
function v = getfield_default(s, f, d)
%GETFIELD_DEFAULT  Return s.(f) if present, else default d.
    if isstruct(s) && isfield(s, f) && ~isempty(s.(f))
        v = s.(f);
    else
        v = d;
    end
end

% ========================================================================
function ensure_parent_dir(fpath)
%ENSURE_PARENT_DIR  Create the parent directory of FPATH if it is missing.
    parent = fileparts(fpath);
    if ~isempty(parent) && ~isfolder(parent)
        mkdir(parent);
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
