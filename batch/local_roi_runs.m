function runs = local_roi_runs(stage_dir, order_how)
%LOCAL_ROI_RUNS  Build a find_runs-shaped runs struct from a staging manifest.
%
%   runs = LOCAL_ROI_RUNS(stage_dir)
%   runs = LOCAL_ROI_RUNS(stage_dir, order)   order: 'newest' (default) |
%                                             'oldest' | 'manifest'
%
%   ORDER controls the sequence in which runs are presented for ROI drawing.
%   Default 'newest' puts the most recent session first (matching find_runs), so
%   an interrupted drawing session still covers the freshest data.
%
%   Companion to stage_roi_frames.sh. That script stages ONE frame per run (the
%   middle frame) from the cluster into a local tree and writes a manifest CSV.
%   This function reads that manifest and returns a struct array shaped like
%   FIND_RUNS output so it can be handed straight to COLLECT_ROIS for LOCAL ROI
%   drawing -- but with two deliberate differences that make the local-draw /
%   cluster-consume split work:
%
%     * .camera_dir points at the LOCAL staging run directory (the folder that
%       holds the single staged frame), so collect_rois.m's middle_frame() can
%       actually read the frame from disk in a fast native window.
%
%     * .remote_camera_dir carries the CLUSTER camera_dir. collect_rois.m's
%       run_key() uses this as the ROI KEY when present, so the saved ROI entry
%       is keyed by the cluster path even though the frame was read locally.
%       This is essential: run_behavior_batch.m runs on the cluster and its
%       lookup_roi matches ROI entries to runs by the CLUSTER camera_dir. Key an
%       entry by the local path and every run fails there with "no ROI recorded".
%
%   INPUT
%     stage_dir : the local staging directory passed to stage_roi_frames.sh
%                 (its STAGE_DIR). Must contain 'stage_manifest.csv'.
%
%   OUTPUT
%     runs : 1xN struct array with the FIND_RUNS fields plus one extra:
%              .run_id            run folder id, e.g. 'Run001'
%              .mouse             mouse id (from the manifest)
%              .date              acquisition date (from the manifest)
%              .camera_dir        LOCAL staging run dir holding the frame
%              .n_frames          full frame count of the run (from the manifest)
%              .trigger_file      '' (triggers live on the cluster; unused here)
%              .base_name         '<mouse>_<date>_<run_id>' (blanks collapsed),
%                                 identical to find_runs so lookup_roi's
%                                 base_name fallback also matches on the cluster
%              .data_root         the stage_dir passed in
%              .remote_camera_dir CLUSTER camera_dir -> used as the ROI key
%
%   Every referenced local frame is validated to exist; if any are missing the
%   function errors and lists them (the staging step must be re-run).

    stage_dir = char(string(stage_dir));
    if isempty(stage_dir) || ~isfolder(stage_dir)
        error('local_roi_runs:badStageDir', ...
            'stage_dir is not an existing folder: %s', stage_dir);
    end

    manifest = fullfile(stage_dir, 'stage_manifest.csv');
    if ~isfile(manifest)
        error('local_roi_runs:noManifest', ...
            ['manifest not found: %s\n' ...
             'Run  stage_roi_frames.sh --go  first to stage frames + manifest.'], ...
            manifest);
    end

    % ---- parse the manifest (simple CSV; fields carry no embedded commas) ---
    [headers, data_rows] = read_csv(manifest);
    if isempty(headers)
        error('local_roi_runs:emptyManifest', 'manifest has no header: %s', manifest);
    end

    i_date    = col_index(headers, 'date');
    i_mouse   = col_index(headers, 'mouse');
    i_run     = col_index(headers, 'run_id');
    i_rcam    = col_index(headers, 'cluster_camera_dir');
    i_lframe  = col_index(headers, 'local_frame_path');
    i_nfr     = col_index(headers, 'n_frames');
    required = {i_date, i_mouse, i_run, i_rcam, i_lframe, i_nfr};
    names    = {'date', 'mouse', 'run_id', 'cluster_camera_dir', ...
                'local_frame_path', 'n_frames'};
    for c = 1:numel(required)
        if isempty(required{c})
            error('local_roi_runs:badManifest', ...
                'manifest %s is missing required column "%s".', manifest, names{c});
        end
    end

    n = numel(data_rows);
    if nargin < 2 || isempty(order_how)
        order_how = 'newest';
    end
    order_how = char(string(order_how));

    runs = empty_run([]);
    if n == 0
        warning('local_roi_runs:noRows', 'manifest %s has no run rows.', manifest);
        return;
    end
    runs = repmat(empty_run(1), 1, n);

    missing = {};
    for k = 1:n
        r = data_rows{k};
        date_str    = cell_at(r, i_date);
        mouse       = cell_at(r, i_mouse);
        run_id      = cell_at(r, i_run);
        remote_cam  = cell_at(r, i_rcam);
        local_frame = cell_at(r, i_lframe);
        nfr         = str2double(cell_at(r, i_nfr));

        % LOCAL camera_dir = folder that holds the single staged frame. That is
        % what collect_rois.m's middle_frame() lists; with one frame present it
        % returns exactly that frame.
        local_cam = fileparts(local_frame);

        if exist(local_frame, 'file') ~= 2
            missing{end+1} = local_frame; %#ok<AGROW>
        end

        runs(k).run_id            = run_id;
        runs(k).mouse             = mouse;
        runs(k).date              = date_str;
        runs(k).camera_dir        = local_cam;                       % LOCAL
        runs(k).n_frames          = nfr;
        runs(k).trigger_file      = '';
        runs(k).base_name         = make_base_name(mouse, date_str, run_id);
        runs(k).data_root         = stage_dir;
        runs(k).remote_camera_dir = remote_cam;                      % CLUSTER key
    end

    if ~isempty(missing)
        error('local_roi_runs:missingFrames', ...
            ['%d staged frame(s) referenced by the manifest are missing on ' ...
             'disk. Re-run stage_roi_frames.sh --go.\n%s'], ...
            numel(missing), strjoin(missing, newline));
    end

    % ---- presentation order ------------------------------------------------
    % Default NEWEST-FIRST, matching find_runs' default. This is the order the
    % human sees while drawing ROIs, so the most recent sessions get done first
    % and an interrupted session still covers the runs that matter most.
    % Dates are 'yy-mm-dd', which sort correctly as text within a century.
    runs = order_runs_local(runs, order_how);
end

% ========================================================================
function runs = order_runs_local(runs, how)
%ORDER_RUNS_LOCAL  Sort runs by session date, then mouse, then run id.
%   how: 'newest' (default) | 'oldest' | 'manifest' (leave as read)
    if isempty(runs) || strcmpi(how, 'manifest')
        return;
    end
    keys = cell(numel(runs), 1);
    for ii = 1:numel(runs)
        keys{ii} = sprintf('%s|%s|%s', runs(ii).date, runs(ii).mouse, runs(ii).run_id);
    end
    [~, idx] = sort(keys);
    if strcmpi(how, 'newest')
        idx = flip(idx);
    end
    runs = runs(idx);
end

% ========================================================================
function [headers, rows] = read_csv(fpath)
%READ_CSV  Minimal CSV reader: header cellstr + cell-of-cellstr data rows.
%   Fields are split on ',' WITHOUT collapsing delimiters (so empty fields keep
%   their column position). This pipeline's manifest never embeds commas in a
%   field, so no quote handling is needed.
    headers = {};
    rows = {};
    fid = fopen(fpath, 'r');
    if fid < 0
        error('local_roi_runs:openFailed', 'cannot open manifest: %s', fpath);
    end
    closer = onCleanup(@() fclose(fid));

    hline = fgetl(fid);
    if ~ischar(hline)
        return;
    end
    headers = split_csv_line(hline);

    while true
        line = fgetl(fid);
        if ~ischar(line)
            break;
        end
        if isempty(strtrim(line))
            continue;
        end
        rows{end+1} = split_csv_line(line); %#ok<AGROW>
    end
end

% ========================================================================
function parts = split_csv_line(line)
%SPLIT_CSV_LINE  Split one CSV line on ',' and trim CR/whitespace per field.
    line = regexprep(line, '\r$', '');   % tolerate CRLF line endings
    parts = strsplit(line, ',', 'CollapseDelimiters', false);
    parts = cellfun(@strtrim, parts, 'UniformOutput', false);
end

% ========================================================================
function idx = col_index(headers, name)
%COL_INDEX  Index of the column named NAME ('' -> [] if absent).
    idx = find(strcmp(headers, name), 1);
end

% ========================================================================
function v = cell_at(r, idx)
%CELL_AT  r{idx} as char if in range, else ''.
    if ~isempty(idx) && idx >= 1 && idx <= numel(r)
        v = char(string(r{idx}));
    else
        v = '';
    end
end

% ========================================================================
function name = make_base_name(mouse, dte, run_id)
%MAKE_BASE_NAME  Join identity fields with '_', dropping blanks (like find_runs).
    pieces = {mouse, dte, run_id};
    pieces = pieces(~cellfun(@isempty, pieces));
    if isempty(pieces)
        name = 'run';
    else
        name = strjoin(pieces, '_');
    end
end

% ========================================================================
function s = empty_run(~)
%EMPTY_RUN  Prototype run struct (0x0 with no arg, 1x1 with any arg). Field
%   order matches find_runs, with remote_camera_dir appended.
    proto = struct('run_id', '', 'mouse', '', 'date', '', 'camera_dir', '', ...
                   'n_frames', 0, 'trigger_file', '', 'base_name', '', ...
                   'data_root', '', 'remote_camera_dir', '');
    if nargin < 1
        s = proto([]);
    else
        s = proto;
    end
end
