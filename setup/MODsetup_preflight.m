function [report, metadata] = MODsetup_preflight(run_yml, prompt, varargin)
% MODsetup_preflight        Part of MOD_fish_processing
%
% report = MODsetup_preflight(run_yml)
% [report, metadata] = MODsetup_preflight(run_yml, prompt, 'stages', {...}, 'ask_paths', tf)
%
% DESCRIPTION
%   Checks, before processing starts, that a processing run's yml
%   (meta/meta_data_<run>.yml, MODsetup_build_yaml.m) has every processing
%   parameter the stages about to run will need, so an unattended (matlab
%   -batch) run never stops to ask for one, and says what the run will
%   use: report.plan lists the yml, where raw, L0 and L1 come from, and
%   where the output goes (printed when called without an output). Run by
%   the realtime worker for each survey, and before any postprocessing.
%
%   Which registry parameters are needed (MODsetup_metadata_field_registry.m,
%   by yaml_section) depends on the stages:
%     - L0: none
%     - L1: afe, ctd, spectral, profile_detection. L0->L1 resolves the
%       electronics filters (fft_length/Fs_epsi, MODsetup_define_filters.m)
%       even on a CTD-only vehicle, and detects the profiling direction.
%     - casts: profile_detection
%     - L2: afe, ctd, spectral, profile_detection, plus chi if an AFE slot
%       is type fpo7 and epsilon if one is type shear (types matched
%       ignoring case, as processing does)
%     Exception: ctd.sample_rate (Fs_ctd) only when ctd.compute_spectra is
%     true. (grid: parameters are needed once the grid stage exists.)
%   A run that takes its L1 from another run (run.L1_from) doesn't run L0
%   or L1.
%
%   Also reported, as problems:
%     - calibrations_root isn't a folder on this computer. With ask_paths
%       true (postprocessing, with a display) a folder picker asks for it
%       and the answer is written into run_yml; otherwise (the realtime
%       worker) it is a problem and nothing is read.
%     - the yml (or a calibration file it points at) can't be read
%     - run.L1_from: that run's yml is missing, it takes its own L1 from
%       yet another run, it has no L1 yet, or its L1 settings differ from
%       this run's (MODsetup_L1_settings.m, compared with that run's saved
%       processed/<L1_from>/meta/metadata.mat - what its L1 was made with -
%       so the L1 would not be the one this run describes)
%     - for L2: shear probes whose calibration file is missing (epsilon is
%       skipped for them), and a missing shear charge-amp filter file
%       (calibrations_root/SHEAR/cap1nFres200Meg_5KohmInput.mat - epsilon
%       would have no electronics correction)
%   And as notes: a survey still holding the old layout (L1/, L2/ or
%   meta/depl_meta_data.yml directly in the survey folder) - those aren't
%   used or changed.
%
%   prompt = true (needs a display or console): each missing value is
%   asked for with the usual dialog (MODsetup_validate_metadata.m) and
%   saved to run_yml, then the yml is reread and checked again.
%
% INPUTS
%   run_yml - full path to the run's yml (meta/meta_data_<run>.yml; any
%             other yml MODsetup_read_yaml.m reads works too)
%   prompt  - (optional) default false
%   Name-value options:
%     'stages'    - stages about to run, any of {'L0','L1','casts','L2'}.
%                   Default: all four.
%     'ask_paths' - default = prompt. true: ask for a calibrations_root
%                   that isn't a folder here (needs a display)
%     'ask_fn'    - default @uigetdir: called as ask_fn(start, title),
%                   returns a folder or 0 (cancel). For tests.
%
% OUTPUTS
%   report   - struct:
%                .ok       - true when nothing is missing and there are no problems
%                .missing  - cellstr of registry names still without a value
%                .problems - cellstr of messages
%                .notes    - cellstr of messages that don't stop anything
%                .plan     - cellstr: what the run reads and writes
%                .yml      - run_yml
%   metadata - from MODsetup_read_yaml.m ([] if the yml couldn't be read)
%
% CALLED BY
%   MODprocess_deployment.m (each survey pass); the monitor app's Preflight
%   button (not built yet); by hand
%
% CALLS
%   MODsetup_read_yaml.m, MODsetup_metadata_field_registry.m,
%   MODsetup_validate_metadata.m, MODsetup_define_filters.m,
%   MODsetup_L1_settings.m, MODsetup_write_yaml_value.m
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

if nargin < 2 || isempty(prompt)
    prompt = false;
end
ip = inputParser;
addParameter(ip, 'stages', {'L0', 'L1', 'casts', 'L2'});
addParameter(ip, 'ask_paths', prompt);
addParameter(ip, 'ask_fn', @uigetdir);
parse(ip, varargin{:});
stages = cellstr(ip.Results.stages);
report = struct('ok', false, 'missing', {{}}, 'problems', {{}}, 'notes', {{}}, 'plan', {{}}, 'yml', run_yml);
metadata = [];

toolbox_dir = fullfile(fileparts(fileparts(mfilename('fullpath'))), 'toolbox', 'YAMLMatlab_0.4.3');
addpath(toolbox_dir);
try
    yml = ReadYaml(run_yml);
catch ME
    report.problems{end+1} = sprintf('Could not read %s: %s', run_yml, ME.message);
    report = done(report, nargout);
    return
end

% calibrations_root first - reading the yml loads calibration files from it
cal_root = '';
if isfield(yml, 'calibrations_root')
    cal_root = char(string(yml.calibrations_root));
end
if ~isfolder(cal_root) && ip.Results.ask_paths
    fprintf('calibrations_root in %s is not a folder on this computer:\n  %s\n', run_yml, cal_root);
    answer = ip.Results.ask_fn(pwd, 'Pick the MOD_fish_calibrations folder (calibrations_root)');
    if ischar(answer) || isstring(answer)
        cal_root = char(answer);
        MODsetup_write_yaml_value(run_yml, '', 'calibrations_root', cal_root);
        fprintf('  -> %s, saved in %s\n', cal_root, run_yml);
    end
end
if ~isfolder(cal_root)
    report.problems{end+1} = sprintf(['calibrations_root is not a folder on this computer: ''%s'' ' ...
        '(in %s). Set it there (a folder that works here is kept when the yml is rebuilt).'], cal_root, run_yml);
    report = done(report, nargout);
    return
end

try
    metadata = MODsetup_read_yaml(run_yml);
catch ME
    report.problems{end+1} = sprintf('Could not read %s: %s', run_yml, ME.message);
    report = done(report, nargout);
    return
end
if ~isempty(metadata.run.L1_from)
    stages = setdiff(stages, {'L0', 'L1'}, 'stable'); % L1 is the other run's
end

% Another run's L1: only if it was made with the same L1 settings. Compared
% with that run's saved metadata.mat (no paths; what its L1 was made with),
% so its yml's calibration files aren't reread - its calibrations_root may
% not be a folder here - and nothing is written into the other run's folder
if ~isempty(metadata.run.L1_from)
    from = metadata.run.L1_from;
    other_yml = fullfile(metadata.paths.survey_meta, ['meta_data_' from '.yml']);
    other_mat = fullfile(metadata.paths.L1_meta, 'metadata.mat');
    if ~isfile(other_yml)
        report.problems{end+1} = sprintf('L1_from: %s - there is no %s.', from, other_yml);
    else
        try
            other_y = ReadYaml(other_yml);
            if isfield(other_y, 'run') && isfield(other_y.run, 'L1_from') && ~isempty(other_y.run.L1_from)
                report.problems{end+1} = sprintf(['L1_from: %s takes its own L1 from run %s - point ' ...
                    'L1_from at %s instead.'], from, char(string(other_y.run.L1_from)), char(string(other_y.run.L1_from)));
            end
        catch ME
            report.problems{end+1} = sprintf('L1_from: could not read %s: %s', other_yml, ME.message);
        end
        if ~isfile(other_mat)
            report.problems{end+1} = sprintf('L1_from: %s has not made any L1 yet (no %s).', from, other_mat);
        else
            other = load(other_mat);
            diffs = differing_fields(MODsetup_L1_settings(metadata), MODsetup_L1_settings(other));
            if ~isempty(diffs)
                report.problems{end+1} = sprintf(['L1_from: %s - its L1 was made with different L1 ' ...
                    'settings (%s), so it isn''t this run''s L1. Make this run''s own L1 (no L1_from), ' ...
                    'or match those settings.'], from, strjoin(diffs, ', '));
            end
        end
        if any(ismember(stages, {'casts', 'L2'})) && isfile(other_mat) && isempty(dir(fullfile(metadata.paths.L1, '*.mat')))
            report.problems{end+1} = sprintf('L1_from: %s has no L1 files yet (%s).', from, metadata.paths.L1);
        end
    end
end

needed = needed_parameters(metadata, stages);
while true
    [~, report.missing] = MODsetup_validate_metadata(metadata, run_yml, needed, false);
    if ~prompt || isempty(report.missing)
        break
    end
    try
        MODsetup_validate_metadata(metadata, run_yml, report.missing, true);
        % Answered but not saved: the values were only for this session, so
        % the yml still lacks them and report.missing stays as it is.
        break
    catch ME
        if ~strcmp(ME.identifier, 'MODsetup_validate_metadata:yamlUpdated')
            rethrow(ME)
        end
        metadata = MODsetup_read_yaml(run_yml);
    end
end

if ismember('L2', stages)
    report = check_shear(report, metadata);
end

% the old survey-level layout, from before processed/<run>/
old = {};
for name = {'L1', 'L2', 'profiles_L1', 'profiles_L2'}
    if isfolder(fullfile(metadata.paths.data_root, name{1})) && ~strcmp(metadata.paths.run, metadata.paths.data_root)
        old{end+1} = [name{1} '/']; %#ok<AGROW>
    end
end
if isfile(fullfile(metadata.paths.survey_meta, 'depl_meta_data.yml'))
    old{end+1} = 'meta/depl_meta_data.yml';
end
if ~isempty(old)
    report.notes{end+1} = sprintf(['%s has the old layout too (%s): not used or changed - output now ' ...
        'goes to processed/<run>/. Move or delete them.'], metadata.paths.data_root, strjoin(old, ', '));
end

report.plan = plan_lines(metadata, run_yml, stages, report);
report.ok = isempty(report.missing) && isempty(report.problems);
report = done(report, nargout);
end %end function

%% Print when called without an output
function report = done(report, n_out)
if n_out == 0
    print_report(report);
end
end

%% Shear probes with no calibration file get no epsilon; shear needs the
% charge-amp response for epsilon (MODsetup_define_filters.m only warns and
% leaves the correction out). The filter check needs fft_length/Fs_epsi, so
% it runs only once nothing is missing.
function report = check_shear(report, metadata)
channels = {};
if isfield(metadata, 'AFE') && isstruct(metadata.AFE)
    channels = fieldnames(metadata.AFE);
end
for iC = 1:numel(channels)
    a = metadata.AFE.(channels{iC});
    if strcmpi(a.type, 'shear') && (~isfield(a, 'cal') || isempty(a.cal))
        sn = '';
        if isfield(a, 'SN')
            sn = char(string(a.SN));
        end
        report.problems{end+1} = sprintf(['Shear channel %s (SN %s) has no calibration file ' ...
            'in %s - no epsilon for it.'], channels{iC}, sn, ...
            fullfile(metadata.paths.calibrations_root, 'SHEAR_PROBES'));
    end
end
if isempty(report.missing) && any(strcmpi(cellfun(@(ch) metadata.AFE.(ch).type, channels, ...
        'UniformOutput', false), 'shear'))
    warnState = warning('off', 'MODsetup_define_filters:noChargeAmpFile');
    with_filters = MODsetup_define_filters(metadata);
    warning(warnState);
    for iC = 1:numel(channels)
        if strcmpi(with_filters.AFE.(channels{iC}).type, 'shear') ...
                && ~isfield(with_filters.AFE.(channels{iC}), 'electronics_filter')
            report.problems{end+1} = sprintf(['Shear channel %s: no charge-amp filter file ' ...
                '(%s) - epsilon would have no electronics correction.'], channels{iC}, ...
                fullfile(metadata.paths.calibrations_root, 'SHEAR', 'cap1nFres200Meg_5KohmInput.mat'));
        end
    end
end
end

%% What the run reads and writes
function lines = plan_lines(metadata, run_yml, stages, report)
p = metadata.paths;
rel = @(f) strrep(f, [p.data_root filesep], '');
n = @(f, pat) numel(dir(fullfile(f, pat)));
name = metadata.run.name;
if isempty(name)
    name = '(not a run yml)';
end
lines = {sprintf('Run %s - %s', name, run_yml)
    sprintf('  survey  %s', p.data_root)
    sprintf('  raw     %s (%d files)', rel(p.raw), n(p.raw, '*.modraw') + n(p.raw, '*.raw'))
    sprintf('  L0      %s (%d files, shared by every run)', rel(p.L0), n(p.L0, '*.mat'))};
if isempty(metadata.run.L1_from)
    lines{end+1} = sprintf('  L1      %s (%d files, this run''s own)', rel(p.L1), n(p.L1, '*.mat'));
else
    lines{end+1} = sprintf('  L1      %s (%d files, from run %s)', rel(p.L1), n(p.L1, '*.mat'), metadata.run.L1_from);
end
lines{end+1} = sprintf('  out     %s', rel(p.run));
lines{end+1} = sprintf('  stages  %s', strjoin(stages, ', '));
lines{end+1} = sprintf('  calibrations_root %s', p.calibrations_root);
if isempty(report.missing)
    lines{end+1} = '  missing parameters: none';
else
    lines{end+1} = sprintf('  missing parameters (%d): %s', numel(report.missing), strjoin(report.missing, ', '));
end
end

%% Field names whose values differ between two structs (by isequaln)
function names = differing_fields(a, b)
names = {};
for f = fieldnames(a)'
    if ~isfield(b, f{1}) || ~isequaln(a.(f{1}), b.(f{1}))
        names{end+1} = f{1}; %#ok<AGROW>
    end
end
end

%% Registry names the stages need, for this run's manifest
function names = needed_parameters(metadata, stages)
registry = MODsetup_metadata_field_registry();
sections = {};
if ismember('L1', stages)
    sections = [sections, {'afe', 'ctd', 'spectral', 'profile_detection'}];
end
if ismember('casts', stages)
    sections = [sections, {'profile_detection'}];
end
if ismember('L2', stages)
    sections = [sections, {'afe', 'ctd', 'spectral', 'profile_detection'}];
    types = {};
    if isfield(metadata, 'AFE') && isstruct(metadata.AFE)
        types = cellfun(@(ch) metadata.AFE.(ch).type, fieldnames(metadata.AFE), 'UniformOutput', false);
    end
    if any(strcmpi(types, 'fpo7'))
        sections{end+1} = 'chi';
    end
    if any(strcmpi(types, 'shear'))
        sections{end+1} = 'epsilon';
    end
end
names = {registry(ismember({registry.yaml_section}, unique(sections))).name};
% Fs_ctd is only read when CTD spectra are on (mod_scan_get_spectra.m)
compute_ctd_spectra = isfield(metadata, 'PROCESS') && isfield(metadata.PROCESS, 'compute_ctd_spectra') ...
    && logical(metadata.PROCESS.compute_ctd_spectra);
if ~compute_ctd_spectra
    names = setdiff(names, {'Fs_ctd'}, 'stable');
end
end

%% Readable summary when called without an output
function print_report(report)
fprintf('Preflight for %s\n', report.yml);
for iL = 1:numel(report.plan)
    fprintf('%s\n', report.plan{iL});
end
if report.ok
    fprintf('  OK - every parameter these stages need is set.\n');
end
for iP = 1:numel(report.problems)
    fprintf('  Problem: %s\n', report.problems{iP});
end
for iN = 1:numel(report.notes)
    fprintf('  Note: %s\n', report.notes{iN});
end
end
