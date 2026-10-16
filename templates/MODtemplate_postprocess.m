% MODtemplate_postprocess        Part of MOD_fish_processing
%
% Postprocessing one survey: copy this script, edit the settings block, run
% it. It runs the same stages, with the same code, as the realtime worker
% (MODprocess_deployment.m) - only the run and its settings differ. See
% docs/workflow/processing_data.md, "Postprocessing".
%
% A processing run is one yml, <survey>/meta/meta_data_<run>.yml, plus one
% output folder, <survey>/processed/<run>/. raw/ and L0/ in the survey
% folder are shared by every run. A new run name makes a new run (its yml
% is made once, from dev1_setup.yml + cruise_meta_data.yml or from
% base_run, with overrides); the same name continues that run, with the
% settings in its yml - edit that file to change them. base_run, L1_from
% and overrides only apply when the run is new. The exception is
% 'realtime': its yml is rebuilt from dev1_setup.yml + cruise_meta_data.yml
% every time (edit those instead), and it takes no base_run, L1_from or
% overrides - use another run name to try other settings.
%
% Step 1 builds the yml and prints what the run will use: which yml, where
% raw, L0 and L1 come from, where output goes, and any missing
% parameters. When calibrations_root isn't a folder on this computer it
% asks for it (and saves the answer in the run yml); missing parameters
% are asked for the same way.
%
% For one stage at a time, see MODtemplate_postprocess_by_stage.m.
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

%% Settings - edit these
survey_folder     = '/path/to/Processed/<survey>'; % holds meta/dev1_setup.yml, raw/, L0/
run_name          = 'realtime';  % letters, digits, _ and -: e.g. 'realtime', 'nfft512'
base_run          = '';          % new run only: start from this run's yml ('' = from the sources)
L1_from           = '';          % new run only: use this run's L1 instead of making one ('' = own L1)
overrides         = {};          % new run only, e.g. {'spectral.fft_length', 512}
by                = 'file';      % 'file': whole L1 files tiled into scans; 'profile': per cast
until_stage       = 'L2';        % last stage: 'yml', 'L0', 'L1', 'casts' or 'L2'
calibrations_root = '';          % '' = the yml's (asked for if it isn't a folder here)

% MOD_fish_processing must be on the path, e.g.
% addpath(genpath('/path/to/MOD_fish_processing'))
assert(exist('MODprocess_deployment', 'file') == 2, 'Add MOD_fish_processing to the Matlab path first.');
opts = {'run', run_name, 'base', base_run, 'L1_from', L1_from, 'overrides', overrides, ...
    'by', by, 'calibrations_root', calibrations_root};

%% 1. Build and check the run yml - prints what it will use
% (checks every stage through L2; step 2 only needs what its stages use)
summary = MODprocess_deployment(survey_folder, opts{:}, 'until', 'yml');
if isempty(summary) || isempty(summary.preflight) || ~summary.preflight.ok
    fprintf('Check the problems and missing parameters above before going on.\n');
end

%% 2. Process
summary = MODprocess_deployment(survey_folder, opts{:}, 'until', until_stage);
fprintf('%s, run %s: %s, %d file(s) processed, %d cast(s), %d problem(s)\n', summary.survey, ...
    summary.run, summary.state, summary.n_processed, summary.n_casts, summary.n_problems);

%% 3. Look at it (L1 time series; L2 spectra with their L1 context)
run_folder = fullfile(survey_folder, 'processed', run_name);
MODvis_timeseries(run_folder);
% MODvis_spectra(run_folder);
