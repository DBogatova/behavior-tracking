%% test_pupil_Run005.m
% Non-interactive test of the improved pupil detection on Run005.
% Run this in MATLAB from the complete_behavior folder.
% It will display the middle frame so you can draw the ROI,
% then process all frames automatically and save results.

close all; clear; clc;

%% Setup
root_folder = fullfile(fileparts(pwd), 'Run005');
addpath(pwd); % ensure helper functions are on path

filenames = natsortfiles(dir(root_folder));
nFrames = size(struct2table(filenames), 1) - 2; % subtract . and ..
fprintf('Found %d frames in Run005\n', nFrames);

%% Draw ROI (one-time interactive step)
run_path = fullfile(root_folder, filenames(floor(length(filenames)/2)).name);
t = Tiff(run_path, 'r');
imageData = im2uint8(read(t));
figure, imshow(imageData)
title('Draw ellipse around the eye - press ENTER when done')
roi = drawellipse('Color','r');
pause
mask = createMask(roi);
close

%% Run new pupil detection
fprintf('Processing %d frames...\n', nFrames);

dark_percentile = 40;
min_area = 50;

pupil = zeros(1, nFrames);
tic
for k = 3:(nFrames + 2)
    run_path = fullfile(root_folder, filenames(k).name);
    t = Tiff(run_path, 'r');
    imageData = im2uint8(read(t));
    if max(imageData(:)) > 5
        roi_pixels = imageData(mask);
        thresh_val = prctile(roi_pixels, dark_percentile);
        dark_mask = (imageData <= thresh_val) & mask;
        CC = bwconncomp(dark_mask);
        if CC.NumObjects > 0
            num_pixels = cellfun(@numel, CC.PixelIdxList);
            [max_area, ~] = max(num_pixels);
            if max_area >= min_area
                pupil(k-2) = max_area;
            end
        end
    end
end
elapsed = toc;
fprintf('Done in %.1f seconds (%.0f ms/frame)\n', elapsed, elapsed/nFrames*1000);

%% Normalize and correct blinks
pupil = pupil(:);
pupil = (pupil - min(pupil)) / (max(pupil) - min(pupil));
pupil_raw = blinking(pupil);

%% Smooth
pupil_smooth = real(rescale(smooth1d(pupil_raw, 30)));
pupil_raw = rescale(pupil_raw);

%% Plot results
time = (0:length(pupil_raw)-1) / 10; % assuming 10 Hz

figure('Position', [100 100 1200 500])
t_layout = tiledlayout(2,1);
t_layout.Title.String = 'Run005 - Improved Pupil Detection';
t_layout.Title.FontWeight = 'bold';

nexttile
plot(time, pupil_raw)
title('Raw (blink-corrected)')
xlim('tight'); xlabel('time [s]'); ylabel('pupil dilation [norm]')

nexttile
plot(time, pupil_smooth)
title('Smoothed')
xlim('tight'); xlabel('time [s]'); ylabel('pupil dilation [norm]')

%% Save
save_path = fullfile(fileparts(pwd), 'Run005_pupil_test.mat');
save(save_path, 'pupil_raw', 'pupil_smooth', 'time');
fprintf('Saved results to %s\n', save_path);

exportgraphics(t_layout, fullfile(fileparts(pwd), 'Run005_pupil_test.png'));
fprintf('Saved figure to Run005_pupil_test.png\n');
