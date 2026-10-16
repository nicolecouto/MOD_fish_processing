% MODtemplate_postprocess_steps        Part of MOD_fish_processing
%
% Postprocessing one survey, one line per level: the processing functions
% called one at a time, so you see what makes each level. Copy this script,
% edit the settings block, and run it one section at a time. See
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
% With L1_from set, skip sections 2 and 3: the L1 is that run's.
% An error stops the script at the line where it happened.
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

%% Settings - edit these
survey_folder     = '/path/to/Processed/<survey>'; % holds meta/dev1_setup.yml, raw/, L0/
run_name          = 'post1';     % letters, digits, _ and -: e.g. 'post1', 'nfft512'
cruise_yml        = '';          % this run's processing values: '' = the one it was built with,
                                 % or cruise_meta_data.yml next to the survey folder for a new run
L1_from           = '';          % use this run's L1 instead of making one ('' = own L1)

% MOD_fish_processing must be on the path, e.g.
% addpath(genpath('/path/to/MOD_fish_processing'))

%% 1. Metadata
% The run's yml: dev1_setup.yml + the cruise yml (rebuilt each time - edit those two)
run_yml = MODsetup_build_yaml(fullfile(survey_folder, 'meta'), cruise_yml, run_name, 'L1_from', L1_from);
% Check it, ask for anything missing (saved into run_yml), and read it.
% report.plan says which yml is used and where each level is read from and
% written to - all of those folders are in metadata.paths.
[report, metadata] = MODsetup_preflight(run_yml, true);
fprintf('%s\n', report.plan{:});
cellfun(@(p) fprintf('Problem: %s\n', p), report.problems);

%% 2. raw -> L0 (the survey's L0/, shared by every run)
L0_files = MODprocess_all_modraw_to_L0(metadata.paths.raw, metadata.paths.L0, [], metadata);

%% 3. L0 -> L1 (processed/<run>/L1/; also pressure_time_series.mat, time_index.mat,
% twist_time_series.mat and the FP07 fit in processed/<run>/meta/)
L1_files = MODprocess_all_L0_to_L1(metadata.paths.L0, metadata, metadata.paths.L1);

%% 4. Casts (processed/<run>/meta/casts.mat), from the L1's pressure record
casts = MODprocess_L1_update_cast_table(metadata);

%% 5. L1 -> profiles_L1 (processed/<run>/profiles_L1/Profile####.mat, one per cast)
profiles_L1_files = MODprocess_all_extract_profiles(metadata);

%% 6. profiles_L1 -> profiles_L2 (processed/<run>/profiles_L2/: scans only, same names)
profiles_L2_files = MODprocess_all_L1_to_L2(metadata.paths.profiles_L1, metadata, metadata.paths.profiles_L2);

% Or, instead of 5-6, L2 by file (whole L1 files tiled into scans, as realtime):
% L2_files = MODprocess_all_L1_to_L2(metadata.paths.L1, metadata, metadata.paths.L2);

%% 7. _README.txt in each folder (what's in it, the run, the steps, the parameters)
% (with L1_from set, leave out 'L1' - that README is the other run's)
for level = {'raw', 'L0', 'L1', 'profiles_L1', 'profiles_L2'}
    MODutil_write_folder_readme(metadata.paths.(level{1}), level{1}, metadata);
end

%% 8. Look at it
MODvis_timeseries(metadata.paths.profiles_L1);   % time series, one Profile####.mat at a time
MODvis_spectra(metadata.paths.profiles_L2);      % scans, with their profiles_L1 time series
