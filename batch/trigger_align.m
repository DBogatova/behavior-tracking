function [aligned, info] = trigger_align(trigger_file, n_behavior_frames, opts)
%TRIGGER_ALIGN  Align behavior-camera frames to the imaging trigger window.
%
%   [aligned, info] = TRIGGER_ALIGN(trigger_file, n_behavior_frames, opts)
%
%   Loads a per-run trigger MAT file (containing struct `data` with digital
%   timetable data.di and analog timetable data.ai), auto-detects the
%   imaging and behavior-camera channels via DETECT_TRIGGER_CHANNELS,
%   determines the sampling rate, and builds a t0-referenced time base where
%   t0 is the FIRST RISING EDGE of the imaging trigger (apical-dendrites
%   convention). Behavior-camera frame onset times are derived from the
%   camera channel's rising edges and flagged for whether they fall inside
%   the imaging window.
%
%   This function is headless: no plotting, no prompts, no display use, and
%   it NEVER throws on a bad/missing run. On any failure it degrades to an
%   identity alignment (keep = all true, frame_time_s = (0:n-1)/10) so the
%   batch can continue.
%
%   INPUTS
%     trigger_file      path to the run's trigger MAT (e.g. 'Run005_t1.mat')
%     n_behavior_frames number of behavior TIFF frames actually on disk
%                       (may be [] / NaN if unknown)
%     opts              (optional) struct with any of:
%                         .fs           force sampling rate (Hz)
%                         .camera_rate  fallback camera rate (default 10 Hz)
%                         .hints        struct forwarded to
%                                       DETECT_TRIGGER_CHANNELS (.imaging,
%                                       .camera overrides)
%
%   OUTPUT `aligned` struct:
%     .t0_sample        zero-based sample index of the first imaging rising
%                       edge (matches mat_to_csv start_sample convention)
%     .t0_time_s        t0 in seconds from the recording start
%     .imaging_window_s [start stop] of the imaging window, relative to t0.
%                       The window spans EVERY sample where the imaging
%                       channel is high (legacy pupil1P.m convention), so
%                       start may be slightly NEGATIVE when the channel is
%                       already high before the first rising edge (= t0).
%     .frame_time_s     1xN t0-referenced onset time for each behavior frame
%     .keep             1xN logical, true where a frame lies in the window
%     .fs               sampling rate used (Hz)
%     .channels         struct('imaging',..,'camera',..) channels used
%     .applied          true if real alignment was applied, false if degraded
%
%   OUTPUT `info` struct (provenance): .applied .warning .warnings (cell)
%     .fs .channels .candidates .confidence .n_camera_edges .n_tiff_frames
%     .n_used .t0_sample .t0_time_s .imaging_window_s .trigger_file

    if nargin < 3 || isempty(opts), opts = struct(); end
    if nargin < 2, n_behavior_frames = NaN; end
    if isempty(n_behavior_frames), n_behavior_frames = NaN; end

    camera_rate = getdef(opts, 'camera_rate', 10);
    hints = getdef(opts, 'hints', struct());

    % ---- info skeleton --------------------------------------------------
    info = struct();
    info.trigger_file = char(string(trigger_file));
    info.applied = false;
    info.warning = '';
    info.warnings = {};
    info.fs = NaN;
    info.channels = struct('imaging', '', 'camera', '');
    info.candidates = struct('name', {}, 'edges', {}, 'rate_hz', {});
    info.confidence = 'unresolved';
    info.n_camera_edges = NaN;
    info.n_tiff_frames = n_behavior_frames;
    info.n_used = NaN;
    info.t0_sample = NaN;
    info.t0_time_s = 0;
    info.imaging_window_s = [NaN NaN];

    % provisional fs (refined after load)
    fs = getdef(opts, 'fs', NaN);
    if isnan(fs), fs = 1000; end

    % ---- missing file ---------------------------------------------------
    if isempty(trigger_file) || ~(ischar(trigger_file) || isstring(trigger_file)) ...
            || ~isfile(trigger_file)
        info.warnings{end+1} = sprintf('Trigger file not found: %s', info.trigger_file);
        aligned = degraded_aligned(n_behavior_frames, fs, camera_rate, info.channels);
        info = finalize(info, aligned);
        return;
    end

    % ---- load -----------------------------------------------------------
    try
        S = load(trigger_file);
    catch ME
        info.warnings{end+1} = sprintf('Failed to load trigger file: %s', ME.message);
        aligned = degraded_aligned(n_behavior_frames, fs, camera_rate, info.channels);
        info = finalize(info, aligned);
        return;
    end

    if isfield(S, 'data')
        data = S.data;
    elseif isfield(S, 'di')
        data = S;
    else
        info.warnings{end+1} = 'MAT file has no "data" struct with digital channels.';
        aligned = degraded_aligned(n_behavior_frames, fs, camera_rate, info.channels);
        info = finalize(info, aligned);
        return;
    end

    if ~isfield(data, 'di') || isempty(data.di)
        info.warnings{end+1} = 'No data.di digital timetable present.';
        aligned = degraded_aligned(n_behavior_frames, fs, camera_rate, info.channels);
        info = finalize(info, aligned);
        return;
    end
    di = data.di;

    % ---- sampling rate --------------------------------------------------
    if ~isnan(getdef(opts, 'fs', NaN))
        fs = double(opts.fs);
    else
        fs = derive_fs(S, data, di);
    end

    % ---- resolve channels ----------------------------------------------
    hints.fs = fs;
    ch = detect_trigger_channels(di, hints);
    info.candidates = ch.candidates;
    info.confidence = ch.confidence;
    info.channels = struct('imaging', ch.imaging, 'camera', ch.camera);
    if ~isempty(ch.warning)
        info.warnings{end+1} = ch.warning;
    end

    if isempty(ch.imaging) || isempty(ch.camera)
        info.warnings{end+1} = ['Imaging and/or camera channel unresolved; ' ...
            'alignment not applied.'];
        aligned = degraded_aligned(n_behavior_frames, fs, camera_rate, info.channels);
        info = finalize(info, aligned);
        return;
    end

    % ---- imaging first rising edge & window ----------------------------
    vi = double(di.(ch.imaging));
    vi = vi(:) > 0.5;
    hi = find(vi);
    rise = find(diff(vi) > 0) + 1;
    if isempty(rise)
        if ~isempty(hi)
            rise = hi(1);        % signal already high at sample 1
        else
            info.warnings{end+1} = ['Imaging channel has no rising edge or high ' ...
                'samples; alignment not applied.'];
            aligned = degraded_aligned(n_behavior_frames, fs, camera_rate, info.channels);
            info = finalize(info, aligned);
            return;
        end
    end
    first_edge = rise(1);              % 1-based sample of first rising edge
    first_hi   = hi(1);                % 1-based first high sample
    last_hi    = hi(end);              % 1-based last high sample

    % TWO DISTINCT CONCEPTS, deliberately decoupled:
    %
    %   t0 (time zero)      = first RISING edge. This is the alignment reference
    %                         and must match mat_to_csv.m, which the downstream
    %                         Python already assumes. Do not change it.
    %
    %   imaging window      = EVERY sample where the imaging channel is high,
    %                         i.e. [first high sample, last high sample]. This
    %                         matches the legacy pupil1P.m definition (ta=tt(a))
    %                         and is the user's chosen convention.
    %
    % These coincide only when the channel starts low. In real data the Zyla
    % channel is sometimes already HIGH at sample 1, so the first high sample
    % (t=0.000) precedes the first rising edge (t=0.018). Keeping them separate
    % means the window can legitimately begin slightly BEFORE t0, which is why
    % imaging_window_s(1) is not hard-coded to 0.
    t0_sample  = first_edge - 1;       % zero-based (matches mat_to_csv)
    t0_time_s  = t0_sample / fs;
    img_start_time_s = (first_hi - 1) / fs;
    img_stop_time_s  = (last_hi  - 1) / fs;
    imaging_window_s = [img_start_time_s - t0_time_s, ...
                        img_stop_time_s  - t0_time_s];

    % ---- camera frame onsets -------------------------------------------
    vc = double(di.(ch.camera));
    vc = vc(:) > 0.5;
    cam_rise = find(diff(vc) > 0) + 1;     % 1-based onset samples
    n_camera_edges = numel(cam_rise);

    % ---- reconcile lengths (never throw on mismatch) -------------------
    n_tiff = n_behavior_frames;
    if isempty(n_tiff) || ~isfinite(n_tiff)
        n_used = n_camera_edges;
    else
        n_used = min(n_camera_edges, double(n_tiff));
    end
    n_used = max(0, floor(n_used));
    cam_rise = cam_rise(1:n_used);

    frame_time_s = ((cam_rise(:).' - 1) / fs) - t0_time_s;   % 1xN, t0-referenced
    keep = frame_time_s >= imaging_window_s(1) & frame_time_s <= imaging_window_s(2);

    % ---- assemble outputs ----------------------------------------------
    aligned = struct();
    aligned.t0_sample = t0_sample;
    aligned.t0_time_s = t0_time_s;
    aligned.imaging_window_s = imaging_window_s;
    aligned.frame_time_s = frame_time_s;
    aligned.keep = logical(keep);
    aligned.fs = fs;
    aligned.channels = struct('imaging', ch.imaging, 'camera', ch.camera);
    aligned.applied = true;

    info.n_camera_edges = n_camera_edges;
    info.n_tiff_frames = n_tiff;
    info.n_used = n_used;
    if isfinite(n_tiff) && n_camera_edges ~= n_tiff
        info.warnings{end+1} = sprintf(['Camera rising edges (%d) do not match ' ...
            'TIFF frames (%g); truncated to %d.'], n_camera_edges, n_tiff, n_used);
    end
    info = finalize(info, aligned);
end

% ------------------------------------------------------------------------
function a = degraded_aligned(n, fs, crate, chans)
%DEGRADED_ALIGNED  Identity alignment used when the trigger cannot be applied.
    if isempty(n) || ~isfinite(n) || n < 0, n = 0; end
    n = double(floor(n));
    a = struct();
    a.t0_sample = NaN;
    a.t0_time_s = 0;
    if n > 0
        a.frame_time_s = (0:n-1) / crate;
        ws = (n - 1) / crate;
    else
        a.frame_time_s = [];
        ws = 0;
    end
    a.imaging_window_s = [0, ws];
    a.keep = true(1, n);
    a.fs = fs;
    a.channels = chans;
    a.applied = false;
end

% ------------------------------------------------------------------------
function info = finalize(info, aligned)
%FINALIZE  Mirror alignment provenance into info and collapse warnings.
    info.applied = aligned.applied;
    info.fs = aligned.fs;
    info.channels = aligned.channels;
    info.t0_sample = aligned.t0_sample;
    info.t0_time_s = aligned.t0_time_s;
    info.imaging_window_s = aligned.imaging_window_s;
    if isempty(info.warnings)
        info.warning = '';
    else
        info.warning = strjoin(info.warnings, ' | ');
    end
end

% ------------------------------------------------------------------------
function fs = derive_fs(S, data, di)
%DERIVE_FS  Resolve sampling rate from device metadata or timetable timing.
    fs = NaN;
    dev = [];
    if isfield(S, 'device')
        dev = S.device;
    elseif isstruct(data) && isfield(data, 'device')
        dev = data.device;
    end
    if ~isempty(dev) && isstruct(dev)
        if isfield(dev, 'actualRate') && ~isempty(dev.actualRate)
            fs = double(dev.actualRate);
        elseif isfield(dev, 'rate') && ~isempty(dev.rate)
            fs = double(dev.rate);
        end
    end
    if (isnan(fs) || fs <= 0) && istimetable(di) && height(di) > 1
        rt = di.Properties.RowTimes;   % name-independent time-dimension access
        dt = median(seconds(diff(rt)));
        if dt > 0
            fs = 1 / dt;
        end
    end
    if isnan(fs) || fs <= 0
        fs = 1000;   % documented fallback
    end
end

% ------------------------------------------------------------------------
function v = getdef(s, f, d)
%GETDEF  Return s.(f) if present and non-empty, else default d.
    if isstruct(s) && isfield(s, f) && ~isempty(s.(f))
        v = s.(f);
    else
        v = d;
    end
end
