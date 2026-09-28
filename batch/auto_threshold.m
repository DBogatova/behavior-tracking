function [thr, info] = auto_threshold(signal, method)
%AUTO_THRESHOLD  Non-interactive threshold selection for behaviour signals.
%
%   [THR, INFO] = AUTO_THRESHOLD(SIGNAL, METHOD)
%
%   Replaces the interactive prompts
%       input("Input a thresholding value between [0 1]")
%   so the batch pipeline can run unattended. SIGNAL is expected to be the
%   [0,1]-normalized pupil/whisker trace, but arbitrary scales are handled.
%
%   METHOD (default 'otsu'):
%     'otsu'       Otsu's method via graythresh on the [0,1]-normalized
%                  signal; the level is mapped back onto the signal's range.
%     'percentile' threshold at the info.percentile-th percentile
%                  (default 75).
%     numeric      passthrough: use the given scalar as the threshold
%                  (lets a caller force a manual value).
%
%   OUTPUT
%     thr  : the chosen threshold (same scale as SIGNAL).
%     info : audit struct with fields
%              .method          method actually used
%              .percentile      percentile used ([] unless 'percentile')
%              .n_finite        number of finite samples
%              .fraction_above  fraction of finite samples >= thr
%              .warning         '' normally; explains any fallback/degeneracy
%
%   Never errors: degenerate input (empty, all-NaN, <2 finite samples,
%   constant signal) yields a sensible thr and a populated info.warning.

    if nargin < 2 || isempty(method)
        method = 'otsu';
    end

    info             = struct();
    info.method      = '';
    info.percentile  = [];
    info.n_finite    = 0;
    info.fraction_above = NaN;
    info.warning     = '';

    sig         = signal(:);
    finite_vals = sig(isfinite(sig));
    n_finite    = numel(finite_vals);
    info.n_finite = n_finite;

    % ----- degenerate-input guards (never error) -----
    if isempty(sig) || n_finite == 0
        thr = 0.5;
        info.method  = 'default';
        info.warning = 'Signal is empty or has no finite samples; returning default threshold 0.5.';
        return;
    end
    if n_finite < 2
        thr = 0.5;
        info.method  = 'default';
        info.fraction_above = mean(finite_vals >= thr);
        info.warning = sprintf('Only %d finite sample(s); returning default threshold 0.5.', n_finite);
        return;
    end

    smin = min(finite_vals);
    smax = max(finite_vals);

    if smax == smin
        thr = smin;                     % constant signal
        info.method  = 'constant';
        info.fraction_above = mean(finite_vals >= thr);   % == 1
        info.warning = 'Constant signal; threshold set equal to the constant value (all samples counted as >= thr).';
        return;
    end

    % ----- numeric passthrough (forced manual value) -----
    if isnumeric(method)
        if isscalar(method) && isfinite(method)
            thr = double(method);
            info.method = 'manual';
        else
            thr = 0.5;
            info.method  = 'manual';
            info.warning = 'Manual threshold was non-scalar or non-finite; using 0.5.';
        end
        info.fraction_above = mean(finite_vals >= thr);
        return;
    end

    % ----- named methods -----
    method = lower(char(method));
    switch method
        case 'otsu'
            norm_vals = (finite_vals - smin) ./ (smax - smin);   % -> [0,1]
            level     = graythresh(norm_vals);                   % in [0,1]
            thr       = smin + level * (smax - smin);            % back to scale
            info.method = 'otsu';
        case 'percentile'
            p               = 75;                                % default
            info.percentile = p;
            thr             = prctile(finite_vals, p);
            info.method     = 'percentile';
        otherwise
            % unknown method -> fall back to otsu, but warn
            norm_vals = (finite_vals - smin) ./ (smax - smin);
            level     = graythresh(norm_vals);
            thr       = smin + level * (smax - smin);
            info.method  = 'otsu';
            info.warning = sprintf('Unknown method "%s"; defaulted to otsu.', method);
    end

    info.fraction_above = mean(finite_vals >= thr);
end
