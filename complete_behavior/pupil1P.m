function [pupil_raw, pupil_smooth, trigger] = pupil1P(root_folder, trigger_file)

filenames = natsortfiles(dir(root_folder));

%% Choose ROI and save mask

run_path = strcat(root_folder,filesep, filenames(floor(length(filenames)/2)).name);
t = Tiff(run_path,'r');
imageData = im2uint8(read(t));
figure('Position', [100 100 960 600]), imshow(imageData, 'InitialMagnification', 'fit')
title('Draw ellipse around the eye')
roi = drawellipse('Color','r');
disp('Adjust ROI, press enter to continue')
pause
disp('Calculating...')

mask = createMask(roi);

%% Create pupil dilation signal - darkest region tracking

dark_percentile = 40; % percent of darkest pixels to keep (tunable)
min_area = 50;        % minimum blob size to count as pupil

pupil = [];
for k = 3:(size(struct2table(filenames), 1))
    run_path = strcat(root_folder, filesep, filenames(k).name);
    t = Tiff(run_path,'r');
    imageData = im2uint8(read(t));
    if max(imageData(:)) > 5 % skip black frames
        roi_pixels = imageData(mask);
        thresh_val = prctile(roi_pixels, dark_percentile);
        dark_mask = (imageData <= thresh_val) & mask;
        CC = bwconncomp(dark_mask);
        if CC.NumObjects > 0
            num_pixels = cellfun(@numel, CC.PixelIdxList);
            [max_area, ~] = max(num_pixels);
            if max_area >= min_area
                pupil(1, k-2) = max_area;
            else
                pupil(1, k-2) = 0;
            end
        else
            pupil(1, k-2) = 0;
        end
    else
        pupil(1, k-2) = 0;
    end
end

clear imageData dark_mask CC roi_pixels t k

disp('Done. Yay!')

%% Trim edge frames (camera startup/shutdown artifacts)

trim = 5; % number of frames to trim from start and end
pupil(1:trim) = pupil(trim+1);
pupil(end-trim+1:end) = pupil(end-trim);

%% Blinking Correction

pupil = pupil(:);
pupil = (pupil - min(pupil)) / (max(pupil) - min(pupil));
pupil_raw = blinking(pupil);

%% Filter pupil signal

pupil_smooth = real(rescale(smooth1d(pupil_raw, 30)));
pupil_raw = rescale(pupil_raw);

% Force row vectors for consistent trigger multiplication
pupil_raw = pupil_raw(:)';
pupil_smooth = pupil_smooth(:)';

%% Load trigger and crop to imaging window

if nargin > 1 && isfile(trigger_file)
    trig_data = load(trigger_file);
    di = trig_data.data.di;
    tt = seconds(di.Time);
    b = di.baslerExposureTrigger > 0.5;     % behavior camera exposures
    a = di.AndorXylaTrigger > 0.5;          % SCAPE imaging
    tb = tt(find(diff(b) == 1) + 1);        % Basler frame onset times (one per camera frame)
    ta = tt(a);                             % Andor imaging times
    % Keep behavior frames that fall within the SCAPE imaging window
    keep = tb >= ta(1) & tb <= ta(end);
    n = min(numel(keep), length(pupil_raw));
    keep = keep(1:n);
    % Frame-length mask (1 inside imaging window, NaN outside)
    trigger = nan(1, n);
    trigger(keep) = 1;
    pupil_raw = pupil_raw(1:n);
    pupil_smooth = pupil_smooth(1:n);
    pupil_raw = pupil_raw(keep);
    pupil_smooth = pupil_smooth(keep);
else
    disp('No trigger applied.')
    trigger = ones(1, length(pupil_raw));
end
