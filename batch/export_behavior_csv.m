function files = export_behavior_csv(out_dir, base_name, pupil, whisker, aligned, trigger_file, opts)
%EXPORT_BEHAVIOR_CSV  Write aligned behavior/accel/trigger signals to CSV.
%
%   files = EXPORT_BEHAVIOR_CSV(out_dir, base_name, pupil, whisker, ...
%                               aligned, trigger_file, opts)
%
%   Produces the stable CSV schema consumed by the downstream Python plotting
%   code (behavior_plots.py) and matching mat_to_csv.m. All behavior signals
%   stay at their native 10 Hz frame rate; accelerometer stays at its native
%   ~1000 Hz rate. They are NOT resampled here -- they are joined downstream
%   on the shared aligned_time_s column.
%
%   Files written into out_dir (created if absent):
%     <base>_behavior.csv : frame, time_s, aligned_time_s, in_imaging_window,
%                           pupil_raw, pupil_smooth, pupil_bins,
%                           whisker_raw_long, whisker_smooth_long,
%                           whisker_raw_pad, whisker_smooth_pad, whisker_bins
%     <base>_accel.csv    : sample, accel_mag, accX, accY, accZ,
%                           time_s, aligned_time_s
%                           (exact order/naming from mat_to_csv.m;
%                            accel_mag = L2 norm of median-subtracted
%                            accX/accY/accZ; accX/Y/Z columns are raw)
%     <base>_trigger.csv  : sample, time_s, aligned_time_s, then every
%                           digital channel present (optional; large)
%     <base>_info.txt     : human-readable provenance
%
%   INPUTS
%     out_dir      output directory (created if it does not exist)
%     base_name    file stem, e.g. 'rbp4_132_phpeb_26-05-12_Run005'
%     pupil        struct with fields pupil_raw / pupil_smooth / pupil_bins
%     whisker      struct with fields whisker_raw_long / whisker_smooth_long /
%                  whisker_raw_pad / whisker_smooth_pad / whisker_bins
%     aligned      struct from TRIGGER_ALIGN (frame_time_s, keep, fs,
%                  t0_time_s, t0_sample, imaging_window_s, channels)
%     trigger_file path to the run's trigger MAT (for accel + trigger CSVs)
%     opts         (optional) struct with any of:
%                    .write_trigger_csv  logical, default true
%                    .camera_rate        fallback frame rate (default 10 Hz)
%                    .trigger_info       info struct from TRIGGER_ALIGN
%                                        (for richer provenance)
%                    .pupil_threshold    recorded in info.txt
%                    .whisker_threshold  recorded in info.txt
%                    .thresholds         struct of extra thresholds to log
%                    .root_folder        behavior source folder (logged)
%                    .extra              struct of extra key/value provenance
%
%   OUTPUT struct `files` with the paths actually written (.behavior always;
%   .accel / .trigger only when produced; .info when the info file is written).
%
%   Robust by design: a missing trigger file or missing accelerometer
%   channels raises a WARNING (recorded in info.txt) and skips the affected
%   CSV, rather than throwing and killing the batch run.

    if nargin < 7 || isempty(opts), opts = struct(); end
    write_trigger = getdef(opts, 'write_trigger_csv', true);
    camera_rate = getdef(opts, 'camera_rate', 10);

    files = struct();
    warns = {};

    % ---- ensure output dir ---------------------------------------------
    if ~isempty(out_dir) && ~isfolder(out_dir)
        mkdir(out_dir);
    end

    % ---- alignment-derived scalars -------------------------------------
    fs = 1000;
    if isfield(aligned, 'fs') && ~isempty(aligned.fs) && isfinite(aligned.fs)
        fs = double(aligned.fs);
    end
    t0_time_s = 0;
    if isfield(aligned, 't0_time_s') && ~isempty(aligned.t0_time_s) ...
            && isfinite(aligned.t0_time_s)
        t0_time_s = double(aligned.t0_time_s);
    end
    if isfield(aligned, 'frame_time_s')
        frame_time_s = aligned.frame_time_s(:);
    else
        frame_time_s = [];
    end
    if isfield(aligned, 'keep')
        keep = logical(aligned.keep(:));
    else
        keep = [];
    end

    % ---- behavior signals ----------------------------------------------
    pr  = getsig(pupil,   'pupil_raw');
    ps  = getsig(pupil,   'pupil_smooth');
    pb  = getsig(pupil,   'pupil_bins');
    wrl = getsig(whisker, 'whisker_raw_long');
    wsl = getsig(whisker, 'whisker_smooth_long');
    wrp = getsig(whisker, 'whisker_raw_pad');
    wsp = getsig(whisker, 'whisker_smooth_pad');
    wb  = getsig(whisker, 'whisker_bins');

    sig_names = {'pupil_raw','pupil_smooth','pupil_bins','whisker_raw_long', ...
        'whisker_smooth_long','whisker_raw_pad','whisker_smooth_pad','whisker_bins'};
    sigs = {pr, ps, pb, wrl, wsl, wrp, wsp, wb};
    for k = 1:numel(sigs)
        if isempty(sigs{k})
            warns{end+1} = sprintf('Behavior signal "%s" missing/empty; column filled with NaN.', ...
                sig_names{k}); %#ok<AGROW>
        end
    end

    % common length = min over all non-empty length-bearing inputs
    lens = [];
    pool = [{frame_time_s}, sigs];
    for k = 1:numel(pool)
        if ~isempty(pool{k})
            lens(end+1) = numel(pool{k}); %#ok<AGROW>
        end
    end
    if isempty(lens)
        N = 0;
    else
        N = min(lens);
    end

    frame = (0:N-1).';
    if isempty(frame_time_s)
        aligned_time_s = (0:N-1).' / camera_rate;   % degraded: t0 unknown
    else
        aligned_time_s = fit_len(frame_time_s, N);
    end
    time_s = aligned_time_s + t0_time_s;
    if isempty(keep)
        in_win = true(N, 1);
    else
        in_win = logical(fit_len(double(keep), N));
    end

    behavior_tbl = table(frame, time_s, aligned_time_s, double(in_win), ...
        col_or_nan(pr, N), col_or_nan(ps, N), col_or_nan(pb, N), ...
        col_or_nan(wrl, N), col_or_nan(wsl, N), col_or_nan(wrp, N), ...
        col_or_nan(wsp, N), col_or_nan(wb, N), ...
        'VariableNames', {'frame','time_s','aligned_time_s','in_imaging_window', ...
        'pupil_raw','pupil_smooth','pupil_bins', ...
        'whisker_raw_long','whisker_smooth_long','whisker_raw_pad', ...
        'whisker_smooth_pad','whisker_bins'});
    behavior_csv = fullfile(out_dir, [base_name '_behavior.csv']);
    writetable(behavior_tbl, behavior_csv);
    files.behavior = behavior_csv;

    % ---- load MAT for accel + trigger CSVs -----------------------------
    have_mat = false;
    di = [];
    ai = [];
    if ~isempty(trigger_file) && (ischar(trigger_file) || isstring(trigger_file)) ...
            && isfile(trigger_file)
        try
            S = load(trigger_file);
            if isfield(S, 'data')
                dat = S.data;
            else
                dat = S;
            end
            if isstruct(dat) && isfield(dat, 'di'), di = dat.di; end
            if isstruct(dat) && isfield(dat, 'ai'), ai = dat.ai; end
            have_mat = true;
        catch ME
            warns{end+1} = sprintf('Could not load trigger file for accel/trigger CSV: %s', ...
                ME.message);
        end
    else
        warns{end+1} = sprintf(['Trigger file not available (%s); skipping accel ' ...
            'and trigger CSVs.'], char(string(trigger_file)));
    end

    % ---- accel CSV (native ~1000 Hz) -----------------------------------
    if have_mat && ~isempty(ai) && (istimetable(ai) || istable(ai))
        ain = ai.Properties.VariableNames;
        if all(ismember({'accX','accY','accZ'}, ain))
            accX = double(ai.accX(:));
            accY = double(ai.accY(:));
            accZ = double(ai.accZ(:));
            nAcc = numel(accX);
            acc_sample = (0:nAcc-1).';
            acc_time_s = acc_sample / fs;
            acc_aligned = acc_time_s - t0_time_s;
            aX0 = accX - median(accX, 'omitnan');
            aY0 = accY - median(accY, 'omitnan');
            aZ0 = accZ - median(accZ, 'omitnan');
            accel_mag = sqrt(aX0.^2 + aY0.^2 + aZ0.^2);
            accel_tbl = table(acc_sample, accel_mag, accX, accY, accZ, ...
                acc_time_s, acc_aligned, ...
                'VariableNames', {'sample','accel_mag','accX','accY','accZ', ...
                'time_s','aligned_time_s'});
            accel_csv = fullfile(out_dir, [base_name '_accel.csv']);
            writetable(accel_tbl, accel_csv);
            files.accel = accel_csv;
        else
            warns{end+1} = ['Accelerometer channels (accX/accY/accZ) missing in ' ...
                'data.ai; accel CSV skipped.'];
        end
    elseif have_mat
        warns{end+1} = 'No analog timetable data.ai; accel CSV skipped.';
    end

    % ---- trigger CSV (optional, large) ---------------------------------
    if write_trigger && have_mat && ~isempty(di) && (istimetable(di) || istable(di))
        nTrig = height(di);
        tsample = (0:nTrig-1).';
        ttime = tsample / fs;
        taligned = ttime - t0_time_s;
        trig_tbl = table(tsample, ttime, taligned, ...
            'VariableNames', {'sample','time_s','aligned_time_s'});
        dn = di.Properties.VariableNames;
        for k = 1:numel(dn)
            try
                trig_tbl.(dn{k}) = double(di.(dn{k})(:));
            catch
                warns{end+1} = sprintf('Skipped non-numeric digital channel "%s".', ...
                    dn{k}); %#ok<AGROW>
            end
        end
        trigger_csv = fullfile(out_dir, [base_name '_trigger.csv']);
        writetable(trig_tbl, trigger_csv);
        files.trigger = trigger_csv;
    elseif ~write_trigger
        warns{end+1} = 'Trigger CSV disabled via opts.write_trigger_csv = false.';
    end

    % ---- info.txt provenance -------------------------------------------
    info_txt = fullfile(out_dir, [base_name '_info.txt']);
    ti = getdef(opts, 'trigger_info', struct());
    fid = fopen(info_txt, 'w');
    if fid ~= -1
        fprintf(fid, 'Behavior CSV export provenance\n');
        fprintf(fid, '==============================\n\n');

        fprintf(fid, 'Base name        : %s\n', base_name);
        fprintf(fid, 'Output directory : %s\n', out_dir);
        fprintf(fid, 'Trigger MAT      : %s\n', char(string(trigger_file)));
        if isfield(opts, 'root_folder') && ~isempty(opts.root_folder)
            fprintf(fid, 'Behavior source  : %s\n', char(string(opts.root_folder)));
        end
        fprintf(fid, '\n');

        imaging = ''; camera = '';
        if isfield(aligned, 'channels') && isstruct(aligned.channels)
            if isfield(aligned.channels, 'imaging'), imaging = aligned.channels.imaging; end
            if isfield(aligned.channels, 'camera'),  camera  = aligned.channels.camera;  end
        end
        fprintf(fid, 'Resolved channels\n');
        fprintf(fid, '  imaging trigger : %s\n', blank(imaging));
        fprintf(fid, '  camera trigger  : %s\n', blank(camera));
        fprintf(fid, '  detection conf. : %s\n', blank(getdef(ti, 'confidence', 'n/a')));
        fprintf(fid, '\n');

        if isfield(ti, 'candidates') && ~isempty(ti.candidates)
            fprintf(fid, 'Channel candidates (name : rising_edges : rate_Hz)\n');
            for k = 1:numel(ti.candidates)
                c = ti.candidates(k);
                fprintf(fid, '  %-24s : %6g : %8.3f\n', c.name, c.edges, c.rate_hz);
            end
            fprintf(fid, '\n');
        end

        applied = getfield_default(aligned, 'applied', getdef(ti, 'applied', false));
        fprintf(fid, 'Alignment\n');
        fprintf(fid, '  applied         : %d\n', applied);
        fprintf(fid, '  sampling rate   : %.6f Hz\n', fs);
        fprintf(fid, '  t0 sample       : %s (zero-based, first imaging rising edge)\n', ...
            numstr(getfield_default(aligned, 't0_sample', NaN)));
        fprintf(fid, '  t0 time         : %.6f s\n', t0_time_s);
        iw = getfield_default(aligned, 'imaging_window_s', [NaN NaN]);
        if numel(iw) >= 2
            fprintf(fid, '  imaging window  : [%.6f %.6f] s (relative to t0)\n', iw(1), iw(2));
        end
        fprintf(fid, '\n');

        fprintf(fid, 'Frame counts\n');
        fprintf(fid, '  camera edges    : %s\n', numstr(getdef(ti, 'n_camera_edges', NaN)));
        fprintf(fid, '  TIFF frames     : %s\n', numstr(getdef(ti, 'n_tiff_frames', NaN)));
        fprintf(fid, '  frames used     : %s\n', numstr(getdef(ti, 'n_used', NaN)));
        fprintf(fid, '  behavior rows   : %d\n', N);
        fprintf(fid, '\n');

        fprintf(fid, 'Thresholds\n');
        if isfield(opts, 'pupil_threshold') && ~isempty(opts.pupil_threshold)
            fprintf(fid, '  pupil_threshold : %g\n', opts.pupil_threshold);
        end
        if isfield(opts, 'whisker_threshold') && ~isempty(opts.whisker_threshold)
            fprintf(fid, '  whisker_threshold : %g\n', opts.whisker_threshold);
        end
        if isfield(opts, 'thresholds') && isstruct(opts.thresholds)
            tf = fieldnames(opts.thresholds);
            for k = 1:numel(tf)
                val = opts.thresholds.(tf{k});
                if isnumeric(val) && isscalar(val)
                    fprintf(fid, '  %s : %g\n', tf{k}, val);
                end
            end
        end
        fprintf(fid, '\n');

        % combined warnings: trigger_align + this export
        allw = {};
        if isfield(ti, 'warnings') && iscell(ti.warnings)
            allw = [allw, ti.warnings(:).'];
        end
        allw = [allw, warns];
        fprintf(fid, 'Warnings (%d)\n', numel(allw));
        if isempty(allw)
            fprintf(fid, '  (none)\n');
        else
            for k = 1:numel(allw)
                fprintf(fid, '  - %s\n', allw{k});
            end
        end
        fprintf(fid, '\n');

        fprintf(fid, 'Files written\n');
        fn = fieldnames(files);
        for k = 1:numel(fn)
            fprintf(fid, '  %-9s : %s\n', fn{k}, files.(fn{k}));
        end
        fprintf(fid, '  %-9s : %s\n', 'info', info_txt);

        fclose(fid);
        files.info = info_txt;
    else
        warns{end+1} = sprintf('Could not open info file for writing: %s', info_txt); %#ok<NASGU>
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

% ------------------------------------------------------------------------
function v = getfield_default(s, f, d)
%GETFIELD_DEFAULT  Return s.(f) if the field exists (even if empty), else d.
    if isstruct(s) && isfield(s, f)
        v = s.(f);
    else
        v = d;
    end
end

% ------------------------------------------------------------------------
function y = getsig(s, f)
%GETSIG  Extract a signal field as a column vector, or [] if absent/empty.
    if isstruct(s) && isfield(s, f) && ~isempty(s.(f))
        y = double(s.(f));
        y = y(:);
    else
        y = [];
    end
end

% ------------------------------------------------------------------------
function y = fit_len(x, N)
%FIT_LEN  Truncate or NaN-pad a vector to length N.
    x = x(:);
    if numel(x) >= N
        y = x(1:N);
    else
        y = [x; nan(N - numel(x), 1)];
    end
end

% ------------------------------------------------------------------------
function y = col_or_nan(x, N)
%COL_OR_NAN  Column of length N from x, or all-NaN column if x is empty.
    if isempty(x)
        y = nan(N, 1);
    else
        y = fit_len(x, N);
    end
end

% ------------------------------------------------------------------------
function s = blank(x)
%BLANK  Render '' for empty channel names in the info file.
    if isempty(x)
        s = '(unresolved)';
    else
        s = char(string(x));
    end
end

% ------------------------------------------------------------------------
function s = numstr(x)
%NUMSTR  Compact numeric-or-NaN string for the info file.
    if isempty(x)
        s = 'n/a';
    elseif isnumeric(x) && isscalar(x) && ~isfinite(x)
        s = 'n/a';
    else
        s = num2str(x);
    end
end
