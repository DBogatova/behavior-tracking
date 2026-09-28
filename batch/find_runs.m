function runs = find_runs(data_root, opts)
%FIND_RUNS  Discover behavior-camera run folders beneath a data root.
%
%   runs = FIND_RUNS(data_root, opts)
%
%   Pure, side-effect-free discovery for the headless batch pipeline. It does
%   NOT hardcode the cluster folder layout: it finds run folders by detecting
%   directories that directly contain many TIFF frames, then INFERS the
%   run/mouse/date identity and a best-guess trigger MAT path from the path
%   structure. Contains no prompts and no plotting; it only prints an
%   inventory summary (always a one-liner; a full table in report mode).
%
%   This is intended to be the FIRST thing run against a new cluster layout
%   (in report mode) to validate the assumptions below before any heavy
%   processing or ROI drawing happens.
%
%   INPUTS
%     data_root : root directory to search recursively (char/string).
%     opts      : (optional) struct with any of:
%                   .min_frames  min TIFFs for a dir to count as a run (100)
%                   .report      logical; when true print the full inventory
%                                table (dry run). Default false.
%                   .verbose     logical; print the one-line summary (true).
%                   .max_trigger_levels how many ancestor levels to search
%                                for a 'trigger' directory (default 5).
%
%   OUTPUT
%     runs : 1xN struct array (N may be 0) with fields:
%              .run_id       run folder identifier, e.g. 'Run005'
%              .mouse        inferred mouse id ('' if not inferable)
%              .date         inferred acquisition date ('' if not inferable)
%              .camera_dir   absolute path to the folder holding the frames
%              .n_frames     number of TIFF frames found in that folder
%              .trigger_file best-guess trigger MAT path ('' if none found)
%              .base_name    '<mouse>_<date>_<run_id>' (blanks collapsed)
%              .data_root    the data_root passed in
%
%   ASSUMPTIONS (heuristics, not hard requirements):
%     * A run folder is a directory that DIRECTLY contains >= min_frames
%       files with a .tif/.tiff extension (case-insensitive).
%     * The historical sibling-project layout is
%           <root>/<date>/<mouse>/camera/<Run###>/  (frames)
%           <root>/<date>/<mouse>/trigger/<Run###>_t1.mat
%       Identity is inferred from that pattern when present, but the code
%       degrades gracefully (blanks) when it is not.
%
%   Never throws on a missing trigger file: it records '' instead.

    % ---- options --------------------------------------------------------
    if nargin < 2 || isempty(opts) || ~isstruct(opts)
        opts = struct();
    end
    defaults = struct('min_frames', 100, 'report', false, 'verbose', true, ...
                      'max_trigger_levels', 5, 'order', 'newest');
    opts = fill_defaults(opts, defaults);

    data_root = char(string(data_root));
    if isempty(data_root) || ~isfolder(data_root)
        error('find_runs:badRoot', 'data_root is not an existing folder: %s', data_root);
    end
    % normalize (strip trailing filesep for clean relative paths)
    if numel(data_root) > 1 && data_root(end) == filesep
        data_root = data_root(1:end-1);
    end

    % ---- recursively enumerate TIFF files -------------------------------
    exts = {'*.tif', '*.tiff', '*.TIF', '*.TIFF'};
    dlist = cell(1, numel(exts));
    for i = 1:numel(exts)
        dlist{i} = dir(fullfile(data_root, '**', exts{i}));
    end
    d = vertcat(dlist{:});

    runs = empty_runs();
    if isempty(d)
        if opts.verbose
            fprintf('find_runs: no TIFF files found under %s\n', data_root);
        end
        return;
    end

    % keep files only (dir '**' should not return dirs for a *.ext glob, but
    % guard anyway) and de-duplicate (a case-insensitive filesystem can match
    % the same file under both *.tif and *.TIF).
    d = d(~[d.isdir]);
    fullpaths = strcat({d.folder}, filesep, {d.name});
    [~, ia] = unique(fullpaths);
    d = d(ia);

    % ---- group by containing folder & count -----------------------------
    folders = {d.folder};
    [uf, ~, gi] = unique(folders);
    counts = accumarray(gi(:), 1);

    keep = counts >= opts.min_frames;
    uf = uf(keep);
    counts = counts(keep);

    if isempty(uf)
        if opts.verbose
            fprintf(['find_runs: no folder under %s had >= %d TIFF frames ' ...
                '(largest had %d).\n'], data_root, opts.min_frames, max([counts; 0]));
        end
        return;
    end

    % natural-order the run folders for stable, human-friendly output
    [uf, order] = sort_paths(uf);
    counts = counts(order);

    % ---- build the run inventory ----------------------------------------
    n = numel(uf);
    runs = repmat(empty_runs(1), 1, n);
    for j = 1:n
        camera_dir = uf{j};
        [run_id, mouse, dte, run_token] = infer_identity(camera_dir, data_root);
        trig = find_trigger(camera_dir, run_id, run_token, data_root, ...
                            opts.max_trigger_levels);

        runs(j).run_id       = run_id;
        runs(j).mouse        = mouse;
        runs(j).date         = dte;
        runs(j).camera_dir   = camera_dir;
        runs(j).n_frames     = counts(j);
        runs(j).trigger_file = trig;
        runs(j).base_name    = make_base_name(mouse, dte, run_id);
        runs(j).data_root    = data_root;
    end

    % ---- order the inventory --------------------------------------------
    % Default 'newest': most recent session first, so an interrupted batch
    % still delivers the freshest sessions.
    runs = order_runs(runs, char(string(opts.order)));

    % ---- print summary / report -----------------------------------------
    if opts.verbose
        n_trig = sum(~cellfun(@isempty, {runs.trigger_file}));
        fprintf('find_runs: discovered %d run folder(s) under %s (%d with a trigger MAT), order=%s.\n', ...
            n, data_root, n_trig, char(string(opts.order)));
    end
    if opts.report
        print_inventory(runs);
    end
end

% ========================================================================
function [run_id, mouse, dte, run_token] = infer_identity(camera_dir, data_root)
%INFER_IDENTITY  Infer run/mouse/date from the camera folder path.
    rel = camera_dir;
    if startsWith(camera_dir, data_root)
        rel = camera_dir(numel(data_root)+1:end);
    end
    parts = split_path(rel);
    if isempty(parts)
        parts = split_path(camera_dir);
    end

    if isempty(parts)
        run_id = ''; mouse = ''; dte = ''; run_token = '';
        return;
    end

    % run id = last path component; extract a normalized run token from it
    run_id = parts{end};
    run_token = regexpi(run_id, 'run[_-]?0*\d+', 'match', 'once');

    % locate a 'camera' anchor if present
    cam_idx = find(strcmpi(parts, 'camera'), 1, 'last');
    if ~isempty(cam_idx)
        mouse = getpart(parts, cam_idx - 1);
        dte   = getpart(parts, cam_idx - 2);
    else
        % assume [..., date, mouse, run]
        mouse = getpart(parts, numel(parts) - 1);
        dte   = getpart(parts, numel(parts) - 2);
    end

    % refine date: prefer any path component that looks like a date
    date_rx = '^\d{2,4}[-_]\d{1,2}[-_]\d{1,2}$';
    dmatch = '';
    for k = 1:numel(parts)
        if ~isempty(regexp(parts{k}, date_rx, 'once'))
            dmatch = parts{k};   % last match wins (closest to the run)
        end
    end
    if ~isempty(dmatch)
        dte = dmatch;
        % if the mouse slot accidentally grabbed the date, blank it
        if strcmp(mouse, dte)
            mouse = '';
        end
    end
end

% ========================================================================
function tf = find_trigger(camera_dir, run_id, run_token, data_root, max_levels)
%FIND_TRIGGER  Search nearby ancestors for a 'trigger' dir holding this run.
    tf = '';
    cur = camera_dir;
    for lvl = 1:max_levels
        parent = fileparts(cur);
        if isempty(parent) || strcmp(parent, cur)
            break;
        end
        cur = parent;
        % look for a subdirectory literally named 'trigger' (case-insensitive)
        dd = dir(cur);
        if isempty(dd)
            % stop if we have climbed above the data root
            if numel(cur) < numel(data_root)
                break;
            end
            continue;
        end
        dd = dd([dd.isdir]);
        dnames = {dd.name};
        ti = find(strcmpi(dnames, 'trigger'), 1);
        if ~isempty(ti)
            tdir = fullfile(cur, dnames{ti});
            tf = match_trigger_file(tdir, run_id, run_token);
            if ~isempty(tf)
                return;
            end
        end
        if numel(cur) <= numel(data_root)
            break;   % do not climb above the data root
        end
    end
end

% ========================================================================
function f = match_trigger_file(tdir, run_id, run_token)
%MATCH_TRIGGER_FILE  Pick a .mat in TDIR whose name references this run.
    f = '';
    m = dir(fullfile(tdir, '*.mat'));
    if isempty(m)
        m2 = dir(fullfile(tdir, '*.MAT'));
        m = [m; m2];
    end
    if isempty(m)
        return;
    end
    names = {m.name};
    lnames = lower(names);

    % 1) exact run_id substring (e.g. 'Run005' in 'Run005_t1.mat')
    idx = find_first(lnames, lower(run_id));
    % 2) run_token substring (e.g. 'run5')
    if isempty(idx) && ~isempty(run_token)
        idx = find_first(lnames, lower(run_token));
    end
    % 3) numeric match: 'run' followed by the same number (any zero padding)
    if isempty(idx)
        num = regexp(run_id, '\d+', 'match', 'once');
        if isempty(num) && ~isempty(run_token)
            num = regexp(run_token, '\d+', 'match', 'once');
        end
        if ~isempty(num)
            rx = sprintf('run[_-]?0*%d\\D', str2double(num));
            hit = ~cellfun(@isempty, regexpi(names, rx, 'once'));
            k = find(hit, 1);
            if ~isempty(k)
                idx = k;
            end
        end
    end

    if ~isempty(idx)
        f = fullfile(tdir, names{idx});
    end
end

% ========================================================================
function idx = find_first(lnames, needle)
%FIND_FIRST  Index of first cell in LNAMES containing NEEDLE ('' -> []).
    idx = [];
    if isempty(needle)
        return;
    end
    hit = cellfun(@(x) contains(x, needle), lnames);
    idx = find(hit, 1);
end

% ========================================================================
function print_inventory(runs)
%PRINT_INVENTORY  Print the discovered runs as a fixed-width table.
    fprintf('\n%-4s  %-14s  %-20s  %-12s  %8s  %-4s  %s\n', ...
        '#', 'run_id', 'mouse', 'date', 'frames', 'trig', 'camera_dir');
    fprintf('%s\n', repmat('-', 1, 110));
    for j = 1:numel(runs)
        if isempty(runs(j).trigger_file)
            tflag = 'no';
        else
            tflag = 'yes';
        end
        fprintf('%-4d  %-14s  %-20s  %-12s  %8d  %-4s  %s\n', ...
            j, trunc(runs(j).run_id, 14), trunc(runs(j).mouse, 20), ...
            trunc(runs(j).date, 12), runs(j).n_frames, tflag, runs(j).camera_dir);
    end
    fprintf('%s\n', repmat('-', 1, 110));
    fprintf('%d run(s) total.\n\n', numel(runs));
end

% ========================================================================
function s = empty_runs(~)
%EMPTY_RUNS  Prototype run struct (0x0 if no arg, 1x1 if any arg given).
    proto = struct('run_id', '', 'mouse', '', 'date', '', 'camera_dir', '', ...
                   'n_frames', 0, 'trigger_file', '', 'base_name', '', ...
                   'data_root', '');
    if nargin < 1
        s = proto([]);   % 0x0 struct with the right fields
    else
        s = proto;
    end
end

% ========================================================================
function parts = split_path(p)
%SPLIT_PATH  Split a path into non-empty components (filesep or '/').
    p = char(string(p));
    raw = regexp(p, '[/\\]', 'split');
    parts = raw(~cellfun(@isempty, raw));
end

% ========================================================================
function v = getpart(parts, idx)
%GETPART  Return parts{idx} if in range, else ''.
    if idx >= 1 && idx <= numel(parts)
        v = parts{idx};
    else
        v = '';
    end
end

% ========================================================================
function name = make_base_name(mouse, dte, run_id)
%MAKE_BASE_NAME  Join identity fields with underscores, dropping blanks.
    pieces = {mouse, dte, run_id};
    pieces = pieces(~cellfun(@isempty, pieces));
    if isempty(pieces)
        name = 'run';
    else
        name = strjoin(pieces, '_');
    end
end

% ========================================================================
function runs = order_runs(runs, how)
%ORDER_RUNS  Sort discovered runs by acquisition order.
%   'newest' (default) : most recent session FIRST, then mouse, then run id.
%       Requested so a long batch produces the freshest data first -- if it is
%       interrupted you already have the sessions you care about most.
%   'oldest' : chronological.
%   'path'   : leave the natural-order path sort untouched.
%   Dates are 'yy-mm-dd' strings, which sort correctly as text within a
%   century, so no date parsing is required.
    if isempty(runs) || strcmpi(how, 'path')
        return;
    end
    keys = cell(numel(runs), 1);
    for ii = 1:numel(runs)
        keys{ii} = sprintf('%s|%s|%s', ...
            char(string(getf_local(runs(ii), 'date', ''))), ...
            char(string(getf_local(runs(ii), 'mouse', ''))), ...
            char(string(getf_local(runs(ii), 'run_id', ''))));
    end
    [~, idx] = sort(keys);
    if strcmpi(how, 'newest')
        idx = flip(idx);
    end
    runs = runs(idx);
end

% ========================================================================
function v = getf_local(s, f, d)
%GETF_LOCAL  Struct field with default.
    if isstruct(s) && isfield(s, f) && ~isempty(s.(f))
        v = s.(f);
    else
        v = d;
    end
end

% ========================================================================
function [sorted, order] = sort_paths(paths)
%SORT_PATHS  Natural-order sort of a cell array of path strings.
    if exist('natsortfiles', 'file') == 2 && exist('natsort', 'file') == 2
        try
            [sorted, order] = natsort(paths);
            return;
        catch
            % fall through to plain sort
        end
    end
    [sorted, order] = sort(paths);
end

% ========================================================================
function s = trunc(s, n)
%TRUNC  Truncate string S to at most N chars for table printing.
    s = char(string(s));
    if numel(s) > n
        s = [s(1:n-1) '~'];
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
