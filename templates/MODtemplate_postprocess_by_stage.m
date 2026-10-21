% MODtemplate_postprocess_by_stage        Part of MOD_fish_processing
%
% Postprocessing one survey a stage at a time, to look at each stage's
% output before the next: copy this script, edit the settings block, and
% run it one section at a time. Each section calls MODprocess_deployment.m
% (the realtime worker's driver) for just that stage ('from' and 'until'),
% so the stages and their order are the driver's - nothing here can drift
% from realtime processing. See docs/workflow/processing_data.md,
% "Postprocessing", and MODtemplate_postprocess.m for the whole run in one
% call (the settings block is the same).
%
% A processing run is one yml, <survey>/meta/meta_data_<run>.yml, plus one
% output folder, <survey>/processed/<run>/; raw/ and L0/ in the survey
% folder are shared by every run. The run's yml is dev1_setup.yml + one
% cruise yml with the processing values, rebuilt every time - edit those
% two, not the run yml. To try other values: copy cruise_meta_data.yml,
% change the copy, and give it as cruise_yml with a new run_name. The same
% run_name again continues that run (it remembers its cruise yml and
% L1_from).
%
% A run that takes its L1 from another run (L1_from) skips the L0 and L1
% sections - they're that run's.
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

%% Settings - edit these
survey_folder     = '/path/to/Processed/<survey>'; % holds meta/dev1_setup.yml, raw/, L0/
run_name          = 'post1';     % letters, digits, _ and -: e.g. 'post1', 'nfft512'
cruise_yml        = '';          % this run's processing values: '' = the one it was built with,
                                 % or cruise_meta_data.yml next to the survey folder for a new run
L1_from           = '';          % use this run's L1 instead of making one ('' = own L1)
by                = 'file';      % 'file': whole L1 files tiled into scans; 'profile': per cast

% MOD_fish_processing must be on the path, e.g.
% addpath(genpath('/path/to/MOD_fish_processing'))
assert(exist('MODprocess_deployment', 'file') == 2, 'Add MOD_fish_processing to the Matlab path first.');
opts = {'run', run_name, 'cruise_yml', cruise_yml, 'L1_from', L1_from, 'by', by};
run_folder = fullfile(survey_folder, 'processed', run_name);

%% 1. Build and check the run yml - prints what it will use
summary = MODprocess_deployment(survey_folder, opts{:}, 'until', 'yml');

%% 2. raw -> L0 (survey's L0/, shared by every run)
summary = MODprocess_deployment(survey_folder, opts{:}, 'from', 'L0', 'until', 'L0');

%% 3. L0 -> L1 (processed/<run>/L1/, plus pressure/time/twist series in its meta/)
summary = MODprocess_deployment(survey_folder, opts{:}, 'from', 'L1', 'until', 'L1');
MODvis_timeseries(run_folder);

%% 4. Cast table (processed/<run>/meta/casts.mat)
summary = MODprocess_deployment(survey_folder, opts{:}, 'from', 'casts', 'until', 'casts');
fprintf('%d cast(s)\n', summary.n_casts);

%% 5. L1 -> L2 (scans; or profiles_L1/ -> profiles_L2/ when by = 'profile')
summary = MODprocess_deployment(survey_folder, opts{:}, 'from', 'L2', 'until', 'L2');
MODvis_spectra(run_folder);

%% 6. Grid (processed/<run>/gridded/gridded.mat: one column per cast, in depth bins)
summary = MODprocess_deployment(survey_folder, opts{:}, 'from', 'grid', 'until', 'grid');
gridded = load(fullfile(run_folder, 'gridded', 'gridded.mat'));   % not 'grid': that's Matlab's grid on/off
