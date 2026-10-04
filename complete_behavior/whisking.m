function [whisker_raw_pad, whisker_smooth_pad, whisker_raw_long, whisker_smooth_long] = whisking(root_folder, save_folder, mouse, date, run)

%% Sort Files

filenames = natsortfiles(dir(root_folder));

%% Select whisker ROIs

run_path = strcat(root_folder, filesep, filenames(floor(length(filenames)/2)).name);
t = Tiff(run_path,'r');
imageData = im2uint8(read(t));

figure('Position', [100 100 960 600]), imshow(imageData, 'InitialMagnification', 'fit')
title('Select ROI around long whiskers')
r = drawrectangle('Color','r');
roi1 = r.Position;
disp('After adjusting the ROI, press enter to continue')
pause

figure('Position', [100 100 960 600]), imshow(imageData, 'InitialMagnification', 'fit')
title('Select ROI around whisker pad')
r2 = drawrectangle('Color','r');
roi2 = r2.Position;
disp('After adjusting the ROI, press enter to continue')
pause
disp('Calculating...')

close all

%% Calculate whisker signal with median filtering

nFrames = size(struct2table(filenames), 1) - 2;
whisker_signal = zeros(1, nFrames);
whisker_signal2 = zeros(1, nFrames);

% ROI areas for normalization
area1 = round(roi1(3)) * round(roi1(4));
area2 = round(roi2(3)) * round(roi2(4));

for k = 3:(nFrames + 2)
    run_path = strcat(root_folder, filesep, filenames(k).name);
    t = Tiff(run_path,'r');
    imageData = im2uint8(read(t));
    
    Icropped = imcrop(imageData, roi1);
    Icropped2 = imcrop(imageData, roi2);
    
    % Apply 3x3 median filter to suppress salt-and-pepper noise
    Icropped = medfilt2(Icropped, [3 3]);
    Icropped2 = medfilt2(Icropped2, [3 3]);
    
    if k == 3
        img_prev = Icropped;
        img_prev2 = Icropped2;
        whisker_signal(1) = 0;
        whisker_signal2(1) = 0;
    else
        % Motion energy: absolute frame difference
        diff1 = abs(double(Icropped) - double(img_prev));
        diff2 = abs(double(Icropped2) - double(img_prev2));
        
        % Threshold out low-level noise (camera noise floor)
        noise_floor = 5;
        diff1(diff1 < noise_floor) = 0;
        diff2(diff2 < noise_floor) = 0;
        
        % Normalize by ROI area
        whisker_signal(k-2) = sum(diff1(:)) / area1;
        whisker_signal2(k-2) = sum(diff2(:)) / area2;
        
        img_prev = Icropped;
        img_prev2 = Icropped2;
    end
end

clear Icropped Icropped2 imageData img_prev img_prev2 diff1 diff2

disp('Done whisking. Yay!')

%% Rescale & smooth whisker signal

whisker_smooth_long = real(rescale(smooth1d(whisker_signal, 30)));
whisker_raw_long = rescale(whisker_signal);

whisker_smooth_pad = real(rescale(smooth1d(whisker_signal2, 30)));
whisker_raw_pad = rescale(whisker_signal2);
