% MODtemplate_postprocess        Part of MOD_fish_processing
%
% Postprocessing one survey: copy this script, edit the settings block, run
% it. It runs the same stages, with the same code, as the realtime worker
% (MODprocess_deployment.m) - only the run and its settings differ. See
% docs/workflow/processing_data.md, "Postprocessing".
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
run_name          = 'post1';     % letters, digits, _ and -: e.g. 'post1', 'nfft512'
cruise_yml        = '';          % this run's processing values: '' = the one it was built with,
                                 % or cruise_meta_data.yml next to the survey folder for a new run
L1_from           = '';          % use this run's L1 instead of making one ('' = own L1)
by                = 'file';      % 'file': whole L1 files tiled into scans; 'profile': per cast
until_stage       = 'L2';        % last stage: 'yml', 'L0', 'L1', 'casts' or 'L2'

% MOD_fish_processing must be on the path, e.g.
% addpath(genpath('/path/to/MOD_fish_processing'))
assert(exist('MODprocess_deployment', 'file') == 2, 'Add MOD_fish_processing to the Matlab path first.');
opts = {'run', run_name, 'cruise_yml', cruise_yml, 'L1_from', L1_from, 'by', by};

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
