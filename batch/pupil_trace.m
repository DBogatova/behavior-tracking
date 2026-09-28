function [pupil_raw, pupil_smooth, diag] = pupil_trace(root_folder, mask, opts)
%PUPIL_TRACE  Headless pupil-dilation trace, polarity-aware (1P dark / 2P bright).
%
%   [PUPIL_RAW, PUPIL_SMOOTH, DIAG] = PUPIL_TRACE(ROOT_FOLDER, MASK, OPTS)
%
%   Batch/headless replacement for the interactive pupil1P.m / pupil2P.m.
%   Those two files were byte-identical apart from comments -- both tracked the
%   DARKEST region -- so the 1P/2P distinction they were named for was never
%   actually implemented. That distinction is PUPIL POLARITY:
%
%     1P / widefield : the pupil is the DARKEST thing in the eye. Track the
%                      largest dark connected component.
%     2P (Femtonics) : the excitation laser retro-reflects out through the
%                      pupil, so the pupil images as a BRIGHT, usually
%                      CLIPPED (255) disc. Track the largest saturated blob.
%
%   Measuring 2P data with dark-region tracking does not merely add noise: the
%   dark region is the iris/eyelid shadow, which SHRINKS as the pupil dilates,
%   so the resulting trace is structureless or inverted. Verified on real
%   Femtonics data: the saturated-area trace is exactly 0 outside the imaging
%   window, steps up at laser onset, shows pupil dynamics, and falls at laser
%   offset (in-window CV 31%), whereas the dark-blob trace has CV 7% inside the
%   window and RISES after the laser turns off.
%
%   A further trap this fixes: the legacy estimator thresholded at a fixed
%   PERCENTILE (prctile(roi,40)), which by construction selects exactly 40% of
%   the ROI's pixels. When those pixels are contiguous the "pupil area" is
%   pinned near 0.40*numel(ROI) regardless of the real pupil size (measured
%   blob/threshold ratio 0.95-0.97 on real data). Because the trace is then
%   min-max rescaled to [0,1], a degenerate signal still LOOKS like a rich
%   trace. Bright mode uses an absolute saturation level instead, so the area
%   genuinely scales with the pupil.
%
%   This function contains NO figure, drawellipse, imshow, pause or input
%   calls and is safe under `matlab -batch` on a display-less cluster node.
%
%   INPUTS
%     root_folder : folder containing the individual per-frame TIFFs. Frames
%                   are enumerated with natsortfiles(dir(root_folder)); the
%                   first two entries ('.' and '..') are skipped.
%     mask        : logical array, same size as one frame, marking the eye.
%     opts        : struct of options (any subset; missing fields default):
%                     .polarity        'auto' (default) | 'bright' | 'dark'
%                                      'auto' samples frames and picks bright
%                                      if a persistent saturated blob exists
%                                      inside the mask (the 2P signature).
%                     .sat_level       intensity counted as saturated (250),
%                                      used by bright mode.
%                     .dark_percentile percent of darkest ROI pixels kept (40),
%                                      used by dark mode only (legacy).
%                     .min_area        min connected-component area. Default
%                                      depends on polarity: 50 dark (legacy),
%                                      5 bright (a constricted 2P pupil is
%                                      genuinely small at this resolution).
%                     .trim            edge frames trimmed each end (5)
%                     .smooth_sigma    sigma passed to smooth1d (30)
%
%   OUTPUTS
%     pupil_raw    : 1xN row vector, blink-corrected pupil trace in [0,1].
%     pupil_smooth : 1xN row vector, smoothed pupil trace in [0,1].
%     diag         : struct for batch auditing with fields
%                       .n_frames                 number of frame values
%                       .n_black_frames_skipped   frames with max<=5 (skipped)
%                       .n_frames_no_blob         non-black frames with no
%                                                 valid pupil blob (set to 0)
%                       .n_blink_events           blink corrections applied
%                       .polarity                 polarity actually used
%                       .polarity_source          'auto' | 'forced'
%                       .sat_frac_frames          fraction of sampled frames
%                                                 with a saturated eye blob
%                       .area_px_mean/.area_px_cv raw area stats BEFORE
%                                                 rescaling -- a CV of only a
%                                                 few percent means the
%                                                 estimator is degenerate even
%                                                 though the rescaled trace
%                                                 will still span [0,1]
%                       .opts                     the options actually used
%
%   NOTE: no trigger cropping is performed here (alignment is owned
%   elsewhere); full-length traces are returned. For 2P data the laser on/off
%   transitions sit exactly at the imaging-window edges, so cropping to
%   in_imaging_window removes the sharp rise/fall artifacts.
%
%   DEPENDENCIES (must be on the MATLAB path): natsortfiles, blinking,
%   smooth1d (all in ../complete_behavior). rescale() is deliberately NOT
%   used because the repo shadows the builtin; a local rescale01() is used.

    % ----- fill option defaults -----
    if nargin < 3
        opts = struct();
    end
    defaults = struct('polarity',        'auto', ...
                      'sat_level',       250, ...
                      'min_contrast',    20,  ...   % bright-mode Otsu guard
                      'min_solidity',    0.85, ...  % bright-mode shape gate
                      'dark_percentile', 40, ...
                      'min_area',        [],  ...   % resolved after polarity
                      'trim',            5,   ...
                      'smooth_sigma',    30);
    opts = fill_defaults(opts, defaults);

    mask = logical(mask);
    % centroid of the drawn eye ellipse, used by the crescent cleanup to prefer
    % the survivor nearest the eye centre over boundary-hugging glare
    [mrow, mcol] = find(mask);
    mask_center = [mean(mcol), mean(mrow)];   % [x y], regionprops convention
    % one-pixel boundary ring of the ellipse; blobs overlapping it are treated
    % as suspect glare by the bright-mode blob selection
    edge_mask = mask & ~imerode(mask, strel('disk', 1));

    % ----- enumerate frames -----
    % Filter to TIFFs explicitly. The legacy pattern skipped the first two
    % dir() entries assuming '.' and '..', but natsortfiles does not keep them
    % adjacent when a stray file (.DS_Store, sidecar CSV) is present, which
    % made position-based skipping read '..' as a frame and throw.
    filenames = natsortfiles(dir(root_folder));
    isframe = ~[filenames.isdir] & ~cellfun('isempty', ...
        regexpi({filenames.name}, '\.tiff?$', 'once'));
    filenames = filenames(isframe);
    nFrames = numel(filenames);
    if nFrames < 1
        error('pupil_trace:noFrames', ...
            'No TIFF frames found in %s.', root_folder);
    end

    % ----- resolve polarity -------------------------------------------------
    % 2P signature: the laser retro-reflection makes a persistent CLIPPED blob
    % inside the eye ROI. Sample frames across the run rather than trusting a
    % single frame, because the laser is off for part of the recording.
    [sat_frac, polarity_auto] = detect_polarity(root_folder, filenames, mask, opts.sat_level);
    if strcmpi(opts.polarity, 'auto')
        polarity = polarity_auto;
        polarity_source = 'auto';
    else
        polarity = lower(char(string(opts.polarity)));
        polarity_source = 'forced';
    end
    if ~ismember(polarity, {'bright','dark'})
        error('pupil_trace:badPolarity', ...
            'opts.polarity must be ''auto'', ''bright'' or ''dark''; got ''%s''.', polarity);
    end
    if isempty(opts.min_area)
        if strcmp(polarity, 'bright')
            % A PRECONSTRICTED 2P pupil is genuinely tiny (a handful of pixels
            % at 288x150), so this must stay small or real constriction gets
            % zeroed. 2 rejects single hot pixels while keeping real signal.
            opts.min_area = 2;
        else
            opts.min_area = 50;   % legacy default for dark tracking
        end
    end

    % ----- per-frame pupil area --------------------------------------------
    n_black   = 0;   % frames skipped because max pixel <= 5
    n_no_blob = 0;   % non-black frames that produced no valid pupil blob
    n_sat     = 0;   % bright mode: frames measured from a CLIPPED core
    n_otsu    = 0;   % bright mode: frames measured via in-ROI Otsu
    n_reject  = 0;   % bright mode: frames with no bimodal separation
    n_low_solidity = 0; % bright mode: frames needing the shape cleanup

    pupil = zeros(1, nFrames);
    for k = 1:nFrames
        run_path  = fullfile(root_folder, filenames(k).name);
        % imread is ~6x faster than a Tiff object for these small single-page
        % frames (0.25 vs 1.5 ms/frame, measured); at ~180k reads per batch the
        % difference is minutes. Frames are 8-bit; guard the odd one out.
        imageData = imread(run_path);
        if ~isa(imageData, 'uint8')
            imageData = im2uint8(imageData);
        end

        if k == 1 && ~isequal(size(mask), size(imageData))
            error('pupil_trace:maskSize', ...
                'mask size %s does not match frame size %s.', ...
                mat2str(size(mask)), mat2str(size(imageData)));
        end

        if max(imageData(:)) > 5                 % skip black frames
            if strcmp(polarity, 'bright')
                % 2P: the pupil is the bright retro-reflection. Its brightness
                % varies by session -- sometimes CLIPPED at 255, sometimes just
                % a light grey disc well below clipping. Verified on real data:
                % 26-06-12 saturates the whole pupil, while 26-06-08 shows an
                % unclipped grey disc that a fixed >=250 test misses entirely.
                % So: use the clipped test when there IS a clipped core, else
                % fall back to Otsu WITHIN the ellipse, which finds the real
                % bright/dark boundary rather than a fixed fraction of the ROI.
                roi_pixels = imageData(mask);
                if sum(roi_pixels >= opts.sat_level) >= opts.min_area
                    blob_mask = (imageData >= opts.sat_level) & mask;
                    n_sat = n_sat + 1;
                else
                    thr01 = graythresh(roi_pixels);
                    thr    = thr01 * 255;
                    hiPix  = double(roi_pixels(roi_pixels >  thr));
                    loPix  = double(roi_pixels(roi_pixels <= thr));
                    % Demand genuine bimodal separation. Without this guard an
                    % essentially unimodal ROI still yields a split, and the
                    % resulting "area" would be an artefact of the threshold
                    % rather than a measurement of the pupil.
                    if ~isempty(hiPix) && ~isempty(loPix) && ...
                            (mean(hiPix) - mean(loPix)) >= opts.min_contrast
                        blob_mask = (double(imageData) > thr) & mask;
                        n_otsu = n_otsu + 1;
                    else
                        blob_mask = false(size(mask));
                        n_reject = n_reject + 1;
                    end
                end
            else
                % 1P: legacy darkest-region tracking.
                roi_pixels = imageData(mask);
                thresh_val = prctile(roi_pixels, opts.dark_percentile);
                blob_mask  = (imageData <= thresh_val) & mask;
            end
            CC = bwconncomp(blob_mask);
            if CC.NumObjects > 0
                if strcmp(polarity, 'bright')
                    % SHAPE-AWARE measurement (bright mode only).
                    %
                    % Failure mode found by visual QC on real data: the bright
                    % blob merges with saturated eyelid glare into an irregular
                    % CRESCENT hugging the ellipse boundary, whose area tracks
                    % eyelid position, not pupil size. 30% of QC-sampled event
                    % frames were affected (54-58% in the worst sessions).
                    %
                    % Fix, validated on 158 real contaminated frames:
                    %   1. If the largest blob is compact (solidity >=
                    %      min_solidity), accept it as-is (clean case, 98% of
                    %      good frames are untouched by this change).
                    %   2. Otherwise apply a radius-1 morphological OPENING to
                    %      break the thin bridge to the glare, then take the
                    %      largest surviving blob. On the contaminated frames
                    %      this moved median solidity 0.72 -> 0.89 and median
                    %      area 89 -> 63 px (toward the true pupil core).
                    %   3. If opening kills everything (6% of contaminated
                    %      frames; also tiny preconstricted pupils), fall back
                    %      to the un-opened largest blob so real constriction
                    %      is never zeroed by the cleanup itself.
                    [max_area, needed] = best_bright_blob(CC, blob_mask, ...
                        edge_mask, mask_center, opts.min_area, opts.min_solidity);
                    if needed
                        n_low_solidity = n_low_solidity + 1;
                    end
                else
                    max_area = max(cellfun(@numel, CC.PixelIdxList));
                end
                if max_area >= opts.min_area
                    pupil(k) = max_area;
                else
                    pupil(k) = 0;
                    n_no_blob  = n_no_blob + 1;
                end
            else
                pupil(k) = 0;
                n_no_blob  = n_no_blob + 1;
            end
        else
            pupil(k) = 0;
            n_black    = n_black + 1;
        end
    end

    n_frames = numel(pupil);

    % raw-area statistics BEFORE any rescaling. This is the honest degeneracy
    % check: rescale01 below will stretch ANY residual variation to span [0,1],
    % so a plausible-looking normalised trace proves nothing on its own.
    nz = pupil(pupil > 0);
    if isempty(nz)
        area_mean = 0; area_cv = NaN;
    else
        area_mean = mean(nz);
        area_cv   = 100 * std(nz) / max(area_mean, eps);
    end

    % ----- trim edge frames (camera startup/shutdown artifacts) -----
    trim = opts.trim;
    if n_frames > 2 * trim
        pupil(1:trim)           = pupil(trim + 1);
        pupil(end-trim+1:end)   = pupil(end - trim);
    end

    % ----- normalize to [0,1] then blink-correct -----
    pupil = pupil(:);
    pupil = rescale01(pupil);

    % count blink events for auditing (mirrors blinking.m's detector) BEFORE
    % delegating the actual correction to the shared blinking() function.
    n_blink  = count_blink_events(pupil);
    pupil_raw = blinking(pupil);

    % ----- smoothing + final rescale (matches original ordering) -----
    pupil_smooth = real(rescale01(smooth1d(pupil_raw, opts.smooth_sigma)));
    pupil_raw    = rescale01(pupil_raw);

    % force row vectors (consistent with original for trigger multiplication)
    pupil_raw    = pupil_raw(:)';
    pupil_smooth = pupil_smooth(:)';

    % ----- diagnostics -----
    diag                         = struct();
    diag.n_frames                = n_frames;
    diag.n_black_frames_skipped  = n_black;
    diag.n_frames_no_blob        = n_no_blob;
    diag.n_blink_events          = n_blink;
    diag.polarity                = polarity;
    diag.polarity_source         = polarity_source;
    diag.sat_frac_frames         = sat_frac;
    diag.n_frames_saturated_core = n_sat;
    diag.n_frames_otsu           = n_otsu;
    diag.n_frames_no_separation  = n_reject;
    diag.n_frames_low_solidity   = n_low_solidity;
    diag.area_px_mean            = area_mean;
    diag.area_px_cv              = area_cv;
    diag.opts                    = opts;
end

% ------------------------------------------------------------------------
function [sat_frac, polarity] = detect_polarity(root_folder, filenames, mask, sat_level)
%DETECT_POLARITY  Decide bright (2P) vs dark (1P) from the frames themselves.
%   Samples up to 60 frames spread across the run and asks, per frame, whether
%   the eye ROI contains a plausible BRIGHT pupil. Sampling across the run
%   matters because the 2P laser is off for part of the recording.
%
%   A bright pupil counts if EITHER
%     (a) there is a clipped core (>= sat_level), or
%     (b) in-ROI Otsu finds a genuinely brighter sub-region (>= 20 grey levels
%         of class separation).
%   Case (b) is essential: on some sessions the retro-reflection is an
%   UNCLIPPED grey disc, which a clipped-only test would miss and then
%   mis-classify the whole run as 1P/dark.
    nF = numel(filenames);   % already filtered to TIFF frames by the caller
    idx = unique(round(linspace(1, nF, min(60, nF))));
    if isempty(idx)
        sat_frac = 0; polarity = 'dark'; return;
    end
    hits = 0; usable = 0;
    for j = 1:numel(idx)
        try
            im = imread(fullfile(root_folder, filenames(idx(j)).name));
            if ~isa(im, 'uint8')
                im = im2uint8(im);
            end
        catch
            continue;
        end
        if ~isequal(size(im), size(mask)) || max(im(:)) <= 5
            continue;
        end
        usable = usable + 1;
        roi = im(mask);
        isBright = false;
        if sum(roi >= sat_level) >= 2
            isBright = true;                      % clipped core
        else
            thr = graythresh(roi) * 255;
            hi = double(roi(roi >  thr));
            lo = double(roi(roi <= thr));
            if ~isempty(hi) && ~isempty(lo) && (mean(hi) - mean(lo)) >= 20
                % a brighter sub-region exists; require it to be compact rather
                % than a diffuse gradient, i.e. a disc-like blob
                bw = (double(im) > thr) & mask;
                cc = bwconncomp(bw);
                if cc.NumObjects > 0
                    a = max(cellfun(@numel, cc.PixelIdxList));
                    if a >= 2 && a <= 0.75 * sum(mask(:))
                        isBright = true;
                    end
                end
            end
        end
        if isBright
            hits = hits + 1;
        end
    end
    if usable == 0
        sat_frac = 0; polarity = 'dark'; return;
    end
    sat_frac = hits / usable;
    % A 2P run has the laser on for most of the recording, so demand a clear
    % majority rather than an occasional specular glint.
    if sat_frac >= 0.5
        polarity = 'bright';
    else
        polarity = 'dark';
    end
end

% ------------------------------------------------------------------------
function s = fill_defaults(s, defaults)
%FILL_DEFAULTS  Copy any missing/empty fields from DEFAULTS into S.
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

% ------------------------------------------------------------------------
function y = rescale01(x)
%RESCALE01  Local [0,1] min-max scaling (avoids the shadowed rescale.m and
%   the ambiguity with the MATLAB builtin rescale). Constant input -> zeros.
    mn = min(x(:));
    mx = max(x(:));
    if mx == mn
        y = zeros(size(x));
    else
        y = (x - mn) ./ (mx - mn);
    end
end

% ------------------------------------------------------------------------
function n = count_blink_events(pupil)
%COUNT_BLINK_EVENTS  Count the artifacts that blinking.m would correct.
%   Mirrors blinking.m exactly (spike/drop threshold 0.25, hold 5, dp taken
%   once from the input) so the returned count matches the corrections that
%   blinking() applies. Used only for diag; the real correction is delegated
%   to blinking().
    pupil        = pupil(:);
    spike_thresh = 0.25;
    drop_thresh  = 0.25;
    hold_len     = 5;
    dp           = [0; diff(pupil)];
    n = 0;
    i = 2;
    while i <= length(pupil) - hold_len
        if dp(i) > spike_thresh || dp(i) < -drop_thresh
            idx_end = min(i + hold_len, length(pupil));
            n = n + 1;
            i = idx_end + 1;
        else
            i = i + 1;
        end
    end
end

% ------------------------------------------------------------------------
function [area, needed_cleanup] = best_bright_blob(CC, blob_mask, edge_mask, ...
    mask_center, min_area, min_solidity)
%BEST_BRIGHT_BLOB  Pick the blob that is the PUPIL, not eyelid glare.
%
%   The physical priors, in order of strength:
%     1. Glare hugs the drawn ellipse BOUNDARY (it comes from the eyelid
%        margin); the pupil sits in the eye's interior. So a blob touching
%        the boundary is suspect and an interior blob is preferred.
%     2. The pupil is near the ellipse CENTRE; glare is not.
%     3. Area alone is NOT a reliable prior: glare can be larger than the
%        pupil, either merged with it (low-solidity crescent) or as a
%        separate compact blob (which even passes a solidity gate).
%
%   Selection:
%     a. Candidates = blobs with area >= max(min_area, 5% of the largest)
%        (the floor stops a 2-3 px hot pixel from outranking a real pupil).
%     b. If any candidate does NOT touch the ellipse boundary, take the
%        non-touching one nearest the ellipse centre.
%     c. Otherwise, if the winner is an irregular crescent (solidity <
%        min_solidity), apply a radius-1 opening to sever the glare bridge
%        and re-run the same selection on the survivors.
%     d. If everything still touches (a genuinely large pupil in a snug
%        ellipse does), fall back to the largest blob.
%
%   needed_cleanup is true when step (b) failed on the raw blobs, i.e. the
%   frame required boundary/shape reasoning beyond plain largest-area.
    st = regionprops(CC, 'Area', 'Solidity', 'Centroid', 'PixelIdxList');
    if isempty(st)
        area = 0; needed_cleanup = false;
        return;
    end
    [~, gi] = max([st.Area]);
    area = st(gi).Area;                      % default: legacy largest
    needed_cleanup = false;                  %#ok<NASGU> (set on every exit path)

    pick = select_blob(st, edge_mask, mask_center, min_area);
    if ~isempty(pick) && ~pick.touches
        area = pick.Area;
        needed_cleanup = (pick.Area ~= st(gi).Area) || blob_touches(st(gi), edge_mask);
        return;
    end
    % every candidate touches the boundary
    needed_cleanup = true;
    if st(gi).Solidity < min_solidity
        opened = imopen(blob_mask, strel('disk', 1));
        CCo = bwconncomp(opened);
        if CCo.NumObjects > 0
            sto = regionprops(CCo, 'Area', 'Solidity', 'Centroid', 'PixelIdxList');
            picko = select_blob(sto, edge_mask, mask_center, min_area);
            if ~isempty(picko)
                area = picko.Area;
                return;
            end
        end
        % opening destroyed everything (tiny pupil): keep the un-opened area
    end
    % compact but touching = plausibly a large pupil in a snug ellipse: keep it
end

% ------------------------------------------------------------------------
function tf = blob_touches(stat, edge_mask)
%BLOB_TOUCHES  True if the blob overlaps the ellipse boundary ring.
    tf = any(edge_mask(stat.PixelIdxList));
end

% ------------------------------------------------------------------------
function pick = select_blob(st, edge_mask, mask_center, min_area)
%SELECT_BLOB  Prefer interior blobs near the centre; else largest.
%   Returns a struct with .Area and .touches, or [] when st is empty.
    if isempty(st)
        pick = [];
        return;
    end
    areas = [st.Area];
    floor_area = max(min_area, 0.05 * max(areas));
    best = 0; bestd = inf;
    for ii = 1:numel(st)
        if areas(ii) < floor_area || blob_touches(st(ii), edge_mask)
            continue;
        end
        dxy = st(ii).Centroid - mask_center;
        dd  = dxy(1)^2 + dxy(2)^2;
        if dd < bestd
            bestd = dd; best = ii;
        end
    end
    if best > 0
        pick = struct('Area', st(best).Area, 'touches', false);
    else
        [~, gi] = max(areas);
        pick = struct('Area', st(gi).Area, 'touches', true);
    end
end
