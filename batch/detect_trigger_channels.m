function ch = detect_trigger_channels(di, hints)
%DETECT_TRIGGER_CHANNELS  Identify imaging & behavior-camera trigger channels.
%
%   ch = DETECT_TRIGGER_CHANNELS(di, hints)
%
%   Pure inspection of a digital timetable `di` (data.di). No file IO, no
%   plotting, no prompts. Robustly identifies which digital channel is the
%   IMAGING trigger (e.g. a Femtonics 2P frame/scan sync or a start-only
%   pulse) and which is the BEHAVIOR CAMERA exposure trigger (~10 Hz).
%
%   Detection is scored in three tiers, strongest first:
%     1. OVERRIDE  - explicit names supplied in hints.imaging / hints.camera
%     2. NAME      - case-insensitive keyword match on the channel names
%     3. SHAPE     - signal-shape heuristics on edge counts / inferred rate:
%                      * behavior camera  -> pulse rate consistent with ~10 Hz
%                      * per-frame imaging -> much higher pulse rate
%                      * start-only imaging -> very few edges (>=1)
%
%   INPUTS
%     di    : timetable (or table) of digital channels. Channel values are
%             thresholded at 0.5 and rising edges (0->1) are counted.
%     hints : (optional) struct with any of:
%               .imaging   char/string, force the imaging channel name
%               .camera    char/string, force the camera channel name
%               .fs        sampling rate (Hz), used to infer recording
%                          duration when `di` is not a timetable
%               .duration_s explicit recording duration in seconds
%
%   OUTPUT struct `ch` with fields:
%     .imaging            resolved imaging channel name ('' if unresolved)
%     .camera             resolved camera channel name  ('' if unresolved)
%     .candidates         1xN struct array: .name .edges .rate_hz for every
%                         channel (edges = rising-edge count)
%     .confidence         'override' | 'name' | 'shape' | 'unresolved'
%                         (weakest tier used across the two resolved roles;
%                          'unresolved' if either role is unresolved)
%     .imaging_confidence per-role confidence for the imaging channel
%     .camera_confidence  per-role confidence for the camera channel
%     .warning            concatenated warnings ('' when none)
%
%   This function never errors on unexpected input: it degrades to
%   unresolved with an explanatory .warning instead.

    if nargin < 2 || isempty(hints)
        hints = struct();
    end

    % ---- defaults / output skeleton ------------------------------------
    ch = struct();
    ch.imaging = '';
    ch.camera = '';
    ch.candidates = struct('name', {}, 'edges', {}, 'rate_hz', {});
    ch.confidence = 'unresolved';
    ch.imaging_confidence = 'unresolved';
    ch.camera_confidence = 'unresolved';
    ch.warning = '';
    warns = {};

    % ---- validate input -------------------------------------------------
    if isempty(di) || ~(istimetable(di) || istable(di))
        ch.warning = 'di is empty or not a table/timetable; cannot detect channels.';
        return;
    end
    names = di.Properties.VariableNames;
    nCh = numel(names);
    if nCh == 0
        ch.warning = 'di has no variables; cannot detect channels.';
        return;
    end

    % ---- recording duration (for rate inference) -----------------------
    duration_s = NaN;
    if istimetable(di) && height(di) > 1
        try
            rt = di.Properties.RowTimes;   % name-independent time access
            duration_s = seconds(rt(end) - rt(1));
        catch
            duration_s = NaN;
        end
    end
    if (isnan(duration_s) || duration_s <= 0) && isfield(hints, 'fs') ...
            && ~isempty(hints.fs) && height(di) > 1
        duration_s = (height(di) - 1) / double(hints.fs);
    end
    if isfield(hints, 'duration_s') && ~isempty(hints.duration_s)
        duration_s = double(hints.duration_s);
    end

    % ---- per-channel edge counts & inferred rates ----------------------
    edges_vec = nan(1, nCh);
    rate_vec  = nan(1, nCh);
    candidates = struct('name', cell(1, nCh), 'edges', cell(1, nCh), ...
                        'rate_hz', cell(1, nCh));
    for k = 1:nCh
        try
            v = double(di.(names{k}));
            v = v(:) > 0.5;
            e = sum(diff(v) > 0);   % count rising edges (0 -> 1)
        catch
            e = NaN;                % non-numeric channel: leave as NaN
        end
        edges_vec(k) = e;
        if ~isnan(e) && ~isnan(duration_s) && duration_s > 0
            rate_vec(k) = e / duration_s;
        end
        candidates(k).name = names{k};
        candidates(k).edges = e;
        candidates(k).rate_hz = rate_vec(k);
    end
    ch.candidates = candidates;

    % ---- name-based keyword scores -------------------------------------
    imaging_kw = {'femtonics', 'femto', 'imaging', 'scanner', 'frame', ...
                  'andor', 'xyla', 'scape', '2p', 'twophoton'};
    camera_kw  = {'basler', 'camera', 'cam', 'behavior', 'exposure'};
    img_name = zeros(1, nCh);
    cam_name = zeros(1, nCh);
    for k = 1:nCh
        ln = lower(names{k});
        img_name(k) = sum(cellfun(@(p) contains(ln, p), imaging_kw));
        cam_name(k) = sum(cellfun(@(p) contains(ln, p), camera_kw));
    end

    % camera rate band (~10 Hz behavior camera)
    CAM_TARGET = 10;
    CAM_LO = 4;
    CAM_HI = 20;

    % ---- tier 1: explicit overrides ------------------------------------
    if isfield(hints, 'imaging') && ~isempty(hints.imaging)
        nm = char(hints.imaging);
        if ismember(nm, names)
            ch.imaging = nm;
            ch.imaging_confidence = 'override';
        else
            warns{end+1} = sprintf(['hints.imaging "%s" not found in di; ' ...
                'ignoring override.'], nm);
        end
    end
    if isfield(hints, 'camera') && ~isempty(hints.camera)
        nm = char(hints.camera);
        if ismember(nm, names)
            ch.camera = nm;
            ch.camera_confidence = 'override';
        else
            warns{end+1} = sprintf(['hints.camera "%s" not found in di; ' ...
                'ignoring override.'], nm);
        end
    end

    % ---- tier 2: name-based --------------------------------------------
    if isempty(ch.imaging)
        cand = find(img_name > cam_name & img_name > 0);
        cand = cand(~strcmp(names(cand), ch.camera));
        if ~isempty(cand)
            best = pick_best(cand, img_name, rate_vec, 'imaging');
            ch.imaging = names{best};
            ch.imaging_confidence = 'name';
        end
    end
    if isempty(ch.camera)
        cand = find(cam_name > img_name & cam_name > 0);
        cand = cand(~strcmp(names(cand), ch.imaging));
        if ~isempty(cand)
            best = pick_best(cand, cam_name, rate_vec, 'camera');
            ch.camera = names{best};
            ch.camera_confidence = 'name';
        end
    end

    % ---- tier 3: signal-shape ------------------------------------------
    % Camera first: it is the well-defined anchor (~10 Hz).
    if isempty(ch.camera)
        best = ''; bestd = inf;
        for k = 1:nCh
            if strcmp(names{k}, ch.imaging), continue; end
            r = rate_vec(k);
            if ~isnan(r) && r >= CAM_LO && r <= CAM_HI
                d = abs(r - CAM_TARGET);
                if d < bestd
                    bestd = d;
                    best = names{k};
                end
            end
        end
        if ~isempty(best)
            ch.camera = best;
            ch.camera_confidence = 'shape';
        end
    end
    % Imaging: prefer a high-rate per-frame channel, else a start-only
    % channel (very few edges, >=1). Exclude the resolved camera channel.
    if isempty(ch.imaging)
        if ~isempty(ch.camera)
            cr = rate_vec(strcmp(names, ch.camera));
            cr = cr(1);
            if isnan(cr), cr = CAM_TARGET; end
            cref = max(20, 1.5 * cr);
        else
            cref = 20;
        end
        bestScore = -inf; best = '';
        for k = 1:nCh
            if strcmp(names{k}, ch.camera), continue; end
            e = edges_vec(k);
            r = rate_vec(k);
            if isnan(e) || e < 1, continue; end   % need at least one edge
            if ~isnan(r) && r >= cref
                score = 2000 + r;          % per-frame imaging trigger
            elseif e <= 5
                score = 1000 - e;          % start-only trigger (few edges)
            elseif ~isnan(r)
                score = r;                 % ambiguous fallback
            else
                score = 0;
            end
            if score > bestScore
                bestScore = score;
                best = names{k};
            end
        end
        if ~isempty(best)
            ch.imaging = best;
            ch.imaging_confidence = 'shape';
        end
    end

    % ---- finalize confidence & warnings --------------------------------
    if isempty(ch.imaging), ch.imaging_confidence = 'unresolved'; end
    if isempty(ch.camera),  ch.camera_confidence  = 'unresolved'; end

    levels = {'unresolved', 'shape', 'name', 'override'};
    overall = min(rankconf(ch.imaging_confidence), rankconf(ch.camera_confidence));
    ch.confidence = levels{overall + 1};

    if isempty(ch.imaging)
        warns{end+1} = 'Imaging trigger channel could not be resolved.';
    end
    if isempty(ch.camera)
        warns{end+1} = 'Behavior-camera trigger channel could not be resolved.';
    end
    if ~isempty(ch.imaging) && ~isempty(ch.camera) && strcmp(ch.imaging, ch.camera)
        warns{end+1} = ['Imaging and camera resolved to the same channel; ' ...
            'supply hints to disambiguate.'];
    end
    ch.warning = strjoin(warns, ' | ');
end

% ------------------------------------------------------------------------
function idx = pick_best(cand, primary, rate_vec, role)
%PICK_BEST  Choose the best candidate index by primary keyword score, with a
%   role-specific rate tie-break (camera -> closest to 10 Hz; imaging ->
%   highest rate, which favours a per-frame trigger over a stray channel).
    bestScore = -inf;
    idx = cand(1);
    for ii = 1:numel(cand)
        c = cand(ii);
        r = rate_vec(c);
        if strcmp(role, 'camera')
            if isnan(r), tie = 0; else, tie = -abs(r - 10); end
        else
            if isnan(r), tie = 0; else, tie = r; end
        end
        score = primary(c) * 1e6 + tie;
        if score > bestScore
            bestScore = score;
            idx = c;
        end
    end
end

% ------------------------------------------------------------------------
function r = rankconf(c)
%RANKCONF  Map a confidence label to an ordinal rank (higher = stronger).
    switch c
        case 'override', r = 3;
        case 'name',     r = 2;
        case 'shape',    r = 1;
        otherwise,       r = 0;   % 'unresolved'
    end
end
