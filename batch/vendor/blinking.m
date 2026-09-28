function pupil_clean = blinking(pupil)
% BLINKING - Corrects blink artifacts in pupil area signal.
% With darkest-region tracking, a blink causes a sudden SPIKE in area
% (eyelid covers ROI -> entire ROI is dark -> huge blob).
% Also catches sudden drops (partial occlusion / lost tracking).
%
% INPUT:  pupil - 1D array, pupil size normalized to [0, 1]
% OUTPUT: pupil_clean - blink-corrected pupil signal

pupil_clean = pupil(:);

% Parameters
spike_thresh = 0.25;  % detect sudden increases (blink = area spike)
drop_thresh = 0.25;   % detect sudden decreases (tracking loss)
hold_len = 5;         % samples to replace after artifact

dp = [0; diff(pupil_clean)];

i = 2;
while i <= length(pupil_clean) - hold_len
    if dp(i) > spike_thresh || dp(i) < -drop_thresh
        last_good = pupil_clean(i-1);
        idx_end = min(i + hold_len, length(pupil_clean));
        pupil_clean(i:idx_end) = last_good;
        i = idx_end + 1;
    else
        i = i + 1;
    end
end

end
