%% DRAW_ROIS  PASS 1 of the behaviour pipeline: draw ROIs for every run.
%
% Open this file in the MATLAB editor and press Run (or F5). Nothing else to
% set up -- it locates its own folder, so it does not matter what the current
% directory is when you start.
%
% WHAT YOU WILL DO
%   For each run you draw three shapes, pressing ENTER after each one:
%       1. an ELLIPSE around the eye
%       2. a RECTANGLE around the long whiskers
%       3. a RECTANGLE around the whisker pad
%
% THE ONE THING THAT MATTERS MOST
%   Draw the eye ellipse TIGHT around the eye, excluding the bright
%   overexposed background around it. On this 2P rig the pupil is the
%   SATURATED WHITE DISC (the laser retro-reflects out through the pupil), and
%   the algorithm measures the largest connected saturated blob inside your
%   ellipse. If the ellipse includes background saturation that touches the
%   pupil, the two merge into one blob and the measurement is ruined. Snug to
%   the eyelids is correct.
%
% RESUMABLE
%   Progress is saved after EVERY run. You can close the figure to stop, then
%   press Run again to carry on exactly where you left off; runs already drawn
%   are skipped automatically.
%
% ORDER
%   Newest session first (26-06-26 ... back to 26-06-08), as requested.

%% ---- locate this script's folder and set up the path --------------------
here = fileparts(mfilename('fullpath'));
if isempty(here)
    here = pwd;   % fallback if run as a selection rather than a file
end
addpath(here);
addpath(fullfile(here, '..', 'complete_behavior'));   % natsortfiles lives here

stage_dir = fullfile(here, 'roi_stage');
roi_file  = fullfile(stage_dir, 'rois.mat');

%% ---- sanity checks before you invest any clicking -----------------------
assert(isfolder(stage_dir), ...
    'Staging folder not found: %s\nRun stage_roi_frames.sh --go first.', stage_dir);
assert(exist('natsortfiles', 'file') == 2, ...
    'natsortfiles not on the path -- expected in %s', ...
    fullfile(here, '..', 'complete_behavior'));
assert(exist('drawellipse', 'file') > 0, ...
    'drawellipse not available; Image Processing Toolbox is required.');

runs = local_roi_runs(stage_dir);      % newest-first by default
fprintf('\n%d run(s) staged for ROI drawing.\n', numel(runs));
if isfile(roi_file)
    S = load(roi_file, 'rois');
    if isfield(S, 'rois')
        fprintf('Resuming: %d run(s) already recorded; those will be skipped.\n', ...
            numel(S.rois));
    end
else
    fprintf('Fresh start (no rois.mat yet).\n');
end
fprintf('Saving to: %s\n', roi_file);
fprintf('Reminder: keep the eye ellipse TIGHT, excluding bright background.\n\n');

%% ---- draw ---------------------------------------------------------------
collect_rois(runs, roi_file);

%% ---- what to do next ----------------------------------------------------
fprintf('\nDone for now. Progress is saved in:\n  %s\n', roi_file);
fprintf('Re-run this script any time to continue where you stopped.\n');
fprintf('When all runs are drawn, tell Kiro and the cluster batch can be submitted.\n');
