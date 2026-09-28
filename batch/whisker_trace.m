function [w, diag] = whisker_trace(root_folder, roi_long, roi_pad, opts)
%WHISKER_TRACE  Headless whisker motion-energy trace with precomputed ROIs.
%
%   [W, DIAG] = WHISKER_TRACE(ROOT_FOLDER, ROI_LONG, ROI_PAD, OPTS)
%
%   Batch/headless replacement for the interactive whisking.m. Instead of
%   drawing two rectangles in a GUI it takes PRECOMPUTED [x y w h] rectangles
%   (imcrop convention) for the long whiskers and the whisker pad. Contains
%   NO figure, drawrectangle, imshow, pause or input calls and is safe under
%   `matlab -batch` on a display-less cluster node.
%
%   INPUTS
%     root_folder : folder of per-frame TIFFs. Frames are enumerated with
%                   natsortfiles(dir(root_folder)); '.' and '..' are skipped.
%     roi_long    : [x y w h] rectangle around the long whiskers.
%     roi_pad     : [x y w h] rectangle around the whisker pad.
%     opts        : struct of options (any subset; missing fields default):
%                     .noise_floor   camera-noise cutoff on |frame diff| (5)
%                     .smooth_sigma  sigma passed to smooth1d (30)
%
%   OUTPUT
%     w    : struct with 1xN row-vector fields (downstream names)
%              .raw_long    rescaled long-whisker motion energy [0,1]
%              .smooth_long smoothed long-whisker motion energy [0,1]
%              .raw_pad     rescaled whisker-pad motion energy [0,1]
%              .smooth_pad  smoothed whisker-pad motion energy [0,1]
%     diag : struct for batch auditing with fields
%              .n_frames  number of frame values
%              .roi_long, .roi_pad   the ROIs used
%              .area_long, .area_pad ROI areas (pixels) used to normalize
%              .opts      the options actually used
%
%   Each TIFF is read ONCE per frame and both ROIs are cropped from it.
%   No trigger cropping is performed here; full-length traces are returned.
%
%   DEPENDENCIES (must be on the MATLAB path): natsortfiles, smooth1d
%   (in ../complete_behavior). rescale() is deliberately NOT used (the repo
%   shadows the builtin); a local rescale01() is used instead.

    % ----- fill option defaults -----
    if nargin < 4
        opts = struct();
    end
    defaults = struct('noise_floor', 5, 'smooth_sigma', 30);
    opts = fill_defaults(opts, defaults);

    % ----- enumerate frames -----
    % Filter to TIFFs explicitly rather than skipping the first two dir()
    % entries: natsortfiles does not keep '.'/'..' adjacent when a stray file
    % (.DS_Store, sidecar CSV) is present, so position-based skipping could
    % read '..' as a frame and throw, dropping the whole run.
    filenames = natsortfiles(dir(root_folder));
    isframe = ~[filenames.isdir] & ~cellfun('isempty', ...
        regexpi({filenames.name}, '\.tiff?$', 'once'));
    filenames = filenames(isframe);
    nFrames   = numel(filenames);
    if nFrames < 1
        error('whisker_trace:noFrames', ...
            'No TIFF frames found in %s.', root_folder);
    end

    whisker_signal  = zeros(1, nFrames);   % long whiskers  (roi_long)
    whisker_signal2 = zeros(1, nFrames);   % whisker pad     (roi_pad)

    % ROI areas (pixels) for normalization
    area1 = round(roi_long(3)) * round(roi_long(4));
    area2 = round(roi_pad(3))  * round(roi_pad(4));

    img_prev  = [];
    img_prev2 = [];
    noise_floor = opts.noise_floor;

    for k = 1:nFrames
        run_path  = fullfile(root_folder, filenames(k).name);
        % imread is ~6x faster than a Tiff object for these small frames
        imageData = imread(run_path);    % read each TIFF ONCE
        if ~isa(imageData, 'uint8')
            imageData = im2uint8(imageData);
        end

        % crop both ROIs from the single loaded frame
        Icropped  = imcrop(imageData, roi_long);
        Icropped2 = imcrop(imageData, roi_pad);

        % 3x3 median filter to suppress salt-and-pepper noise
        Icropped  = medfilt2(Icropped,  [3 3]);
        Icropped2 = medfilt2(Icropped2, [3 3]);

        if k == 1
            img_prev          = Icropped;
            img_prev2         = Icropped2;
            whisker_signal(1)  = 0;
            whisker_signal2(1) = 0;
        else
            % motion energy: absolute frame difference vs previous frame
            diff1 = abs(double(Icropped)  - double(img_prev));
            diff2 = abs(double(Icropped2) - double(img_prev2));

            % zero out sub-noise-floor differences
            diff1(diff1 < noise_floor) = 0;
            diff2(diff2 < noise_floor) = 0;

            % normalize by ROI area (pixels)
            whisker_signal(k)  = sum(diff1(:)) / area1;
            whisker_signal2(k) = sum(diff2(:)) / area2;

            img_prev  = Icropped;
            img_prev2 = Icropped2;
        end
    end

    % ----- rescale + smooth (matches original ordering) -----
    w = struct();
    w.raw_long    = rescale01(whisker_signal);
    w.smooth_long = real(rescale01(smooth1d(whisker_signal,  opts.smooth_sigma)));
    w.raw_pad     = rescale01(whisker_signal2);
    w.smooth_pad  = real(rescale01(smooth1d(whisker_signal2, opts.smooth_sigma)));

    % force row vectors
    w.raw_long    = w.raw_long(:)';
    w.smooth_long = w.smooth_long(:)';
    w.raw_pad     = w.raw_pad(:)';
    w.smooth_pad  = w.smooth_pad(:)';

    % ----- diagnostics -----
    diag           = struct();
    diag.n_frames  = nFrames;
    diag.roi_long  = roi_long;
    diag.roi_pad   = roi_pad;
    diag.area_long = area1;
    diag.area_pad  = area2;
    diag.opts      = opts;
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
