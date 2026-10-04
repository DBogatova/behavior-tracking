%% Complete behavior analysis with trigger detection

close all
clear all
clc

%% Mouse data - adjust info!

date = '26-05-12'; 
mouse = 'rbp4_132_phpeb';
run = 'Run005';

%% Set up directories

%root_folder = uigetdir('/projectnb/devorlab/daria/SCAPE/behavior/26-02-17/rbp4cre_138_phpeb/camera/'); % adjust root directory
%save_folder = '/projectnb/devorlab/daria/SCAPE/behavior/26-02-17/'; % adjust save folder
root_folder = '/Users/daria/Desktop/behavior-tracking/Run005/';
save_folder = '/Users/daria/Desktop/behavior-tracking/';

% Trigger file: folder + run number + '_t1.mat' suffix
trigger_folder = '/projectnb/devorlab/daria/SCAPE/behavior/26-05-12/rbp4_132_phpeb/trigger';
trigger_file = fullfile(trigger_folder, [run '_t1.mat']);
if ~isfolder(save_folder)
    mkdir(save_folder)
end

save_fig = strcat(save_folder, 'fig/');
if ~isfolder(save_fig) 
    mkdir(save_fig)
end

save_mat = strcat(save_folder, 'mat/');
if ~isfolder(save_mat) 
    mkdir(save_mat)
end

%% Sort Files

% Natural-Order Filename Sort - MATLAB FCN
% alphanumeric sort of filenames
filenames = natsortfiles(dir(root_folder));

%% Pupil

answer = input("Are you working with 1P or 2P data? 1P=1, 2P=0\n");
if answer == 1
    [pupil_raw, pupil_smooth, trigger] = pupil1P(root_folder, trigger_file);
elseif answer == 0
    [pupil_raw, pupil_smooth, trigger] = pupil2P(root_folder, trigger_file);
end

%% Figure 1 - Plot pupil signal

time_pupil = (0:length(pupil_raw)-1) / 10;

t = tiledlayout(2,1);
t.Title.String = strcat(strrep(mouse, '_', '-'), '-', date, '-', run);
t.Title.FontWeight = 'bold';

nexttile
plot(time_pupil, pupil_raw)
title('raw pupil signal')
xlim('tight')
xlabel('time [s]')
ylabel('pupil dilation [%]')

nexttile
plot(time_pupil, pupil_smooth)
title('smooth pupil signal')
xlim('tight')
xlabel('time [s]')
ylabel('pupil dilation [%]')
 
%% Save pupil png

save_filename = strcat(mouse, '_', date, '_', run,'_pupil.png');
exportgraphics(t, strcat(save_fig,save_filename))

%% Bin pupil signal

pupil_threshold = input("Input a pupil thresholding value between [0 1]:\n");
pupil_bins = thresholding(pupil_smooth, pupil_threshold);

%% Whisker

[whisker_raw_pad, whisker_smooth_pad, whisker_raw_long, whisker_smooth_long] = whisking(root_folder, save_folder, mouse, date, run);

%% Trigger whiskers

whisker_raw_pad_t = whisker_raw_pad.*trigger;
whisker_raw_pad = whisker_raw_pad_t(~isnan(whisker_raw_pad_t));

whisker_smooth_pad_t = whisker_smooth_pad.*trigger;
whisker_smooth_pad = whisker_smooth_pad_t(~isnan(whisker_smooth_pad_t));

whisker_raw_long_t = whisker_raw_long.*trigger;
whisker_raw_long = whisker_raw_long_t(~isnan(whisker_raw_long_t));

whisker_smooth_long_t = whisker_smooth_long.*trigger;
whisker_smooth_long = whisker_smooth_long_t(~isnan(whisker_smooth_long_t));

%% Ensure all signals and time vector have the same length

nSamples = min([length(pupil_raw), length(whisker_smooth_long)]);
pupil_raw = pupil_raw(1:nSamples);
pupil_smooth = pupil_smooth(1:nSamples);
whisker_raw_pad = whisker_raw_pad(1:nSamples);
whisker_smooth_pad = whisker_smooth_pad(1:nSamples);
whisker_raw_long = whisker_raw_long(1:nSamples);
whisker_smooth_long = whisker_smooth_long(1:nSamples);
time = (0:nSamples-1) / 10;

%% Figure 2 - Plot whisker signal

%figure('Position',[0 0 1500 500])
t = tiledlayout(2,1, 'TileSpacing','compact', 'Padding','compact');
t.Title.String = strcat(strrep(mouse, '_', '-'), '-', date, '-', run);
t.Title.FontWeight = 'bold'

nexttile
plot(time, whisker_smooth_long)
xlim('tight')
hold on 
plot(time, whisker_raw_long)
title('Long whiskers')
xlabel('time [s]')
ylabel('speed [%]')

nexttile
plot(time, whisker_smooth_pad)
xlim('tight')
hold on 
plot(time, whisker_raw_pad)
title('Whisker pad')
xlabel('time [s]')
ylabel('speed [%]')

%% Save whisker png

save_filename = strcat(mouse, '_', date, '_', run,'_whisker.png');
exportgraphics(t, strcat(save_fig,save_filename))

%% Choose whisker signal

answer = input('Choose whisker signal for binning (all signals will be saved in the mat file):\nLong=0 Pad=1\n');
if answer == 0
    whisker = whisker_smooth_long;
    settings.binning_choice = 'long';
elseif answer == 1
    whisker = whisker_smooth_pad;
    settings.binning_choice = 'pad';
else
    error('Unexpected whisker signal choice: %g. Expected 0 (Long) or 1 (Pad).', answer);
end

%% Bin whisker signal

threshold = input("Input a thresholding value between [0 1]:\n");
whisker_bins = thresholding(whisker, threshold);

%% Figure 3 - Plot binned whisker signal

%figure('Position',[0 0 1500 500])
t = tiledlayout(2,1, 'TileSpacing','compact', 'Padding','compact');
t.Title.String = strcat(strrep(mouse, '_', '-'), '-', date, '-', run);
t.Title.FontWeight = 'bold'

nexttile
plot(time, whisker)
xlim('tight')
title('Whisking')
xlabel('time [s]')
ylabel('speed [%]')

bins = whisker_bins;
bins(whisker_bins==0) = nan; 
nexttile
plot(time, bins)
xlim('tight')
ylim([0,2])
title('Bins')
xlabel('time [s]')
ylabel('on/off')

%% Save bins png

save_filename = strcat(mouse, '_', date, '_', run,'_bins.png');
exportgraphics(t, strcat(save_fig,save_filename))


%% Movie

answer = input('Do you want to create a movie showing all behavioral data? Yes=1 No=0\n');
if answer ==1
    %% Choose pupil & whisker signal for movie

answer = input('Choose pupil signal for movie & big plot (both will be saved in mat file): Smooth=1 Raw=0\n');
if answer == 1
    pupil_movie = pupil_smooth;
elseif answer == 0
    pupil_movie = pupil_raw;
else
    error('Unexpected pupil signal choice: %g. Expected 1 (Smooth) or 0 (Raw).', answer);
end

answer = input("Choose whisker signal for movie & big plot (all will be saved in mat file): Long=1 Pad=0\n");
if answer == 0
    whisker_movie = whisker_smooth_pad;
elseif answer == 1
    whisker_movie = whisker_smooth_long;
end

%% Figure 4 - Plot all behavior

%figure('Position',[0 0 1500 500])
t = tiledlayout(3,1, 'TileSpacing','compact', 'Padding','compact');
t.Title.String = strcat(strrep(mouse, '_', '-'), '-', date, '-', run);
t.Title.FontWeight = 'bold';

nexttile
plot(time, pupil_movie)
xlim('tight')
title('Pupil')
xlabel('time [s]')
ylabel('dilation [%]')

nexttile
plot(time, whisker_movie)
xlim('tight')
title('Whisking')
xlabel('time [s]')
ylabel('speed [%]')

nexttile
plot(time, bins)
xlim('tight')
ylim([0,2])
title('Bins')
xlabel('time [s]')
ylabel('on/off')


%% Save all behavior png

save_filename = strcat(mouse, '_', date, '_', run,'_comparison.png');
exportgraphics(t, strcat(save_fig,save_filename))

    movie(root_folder, save_folder, date, mouse, run, pupil_movie, whisker_movie, whisker_bins, time); % movie magic

elseif answer==0
    disp('Ok, your loss')
end

%% Save .mat file

info.mouse = mouse;
info.date = date;
info.run = run;
clear mouse date run 

settings.filenames = filenames;
settings.root_folder = root_folder;
settings.save_folder = save_folder;
settings.threshold = threshold;
settings.trigger = trigger;
clear filenames root_folder save_folder threshold trigger

clear whisker
whisker.whisker_bins = whisker_bins;
whisker.whisker_raw_long = whisker_raw_long;
whisker.whisker_raw_pad = whisker_raw_pad;
whisker.whisker_smooth_long = whisker_smooth_long;
whisker.whisker_smooth_pad = whisker_smooth_pad;
clear whisker_bins whisker_raw_long whisker_raw_pad whisker_smooth_long whisker_smooth_pad

pupil.pupil_raw = pupil_raw;
pupil.pupil_smooth = pupil_smooth;
pupil.pupil_bins = pupil_bins;
clear pupil_raw pupil_smooth pupil_bins

clear pupil_movie whisker_movie t time answer save_fig save_filename
clear whisker_raw_long_t whisker_raw_pad_t whisker_smooth_pad_t whisker_smooth_long_t
save([save_mat, [info.mouse, '_', info.date, '_', info.run],'_behavior.mat']);
