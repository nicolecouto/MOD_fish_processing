function [report, metadata] = MODsetup_preflight(depl_yml, prompt)
% MODsetup_preflight        Part of MOD_fish_processing
%
% report = MODsetup_preflight(depl_yml)
% [report, metadata] = MODsetup_preflight(depl_yml, prompt)
%
% DESCRIPTION
%   Checks, before processing starts, that a deployment's yml has every
%   processing parameter its instrument_manifest will need, so an
%   unattended (matlab -batch) run never stops to ask for one. Run by the
%   realtime worker when it starts a survey, and from the monitor app's
%   Preflight button.
%
%   Which registry parameters are needed (MODsetup_metadata_field_registry.m,
%   by yaml_section):
%     - always: afe, ctd, spectral, profile_detection, grid. L0->L1 needs
%       fft_length/Fs_epsi (MODsetup_define_filters.m) even on a CTD-only
%       vehicle, and every vehicle gets casts and a grid. Exception:
%       ctd.sample_rate (Fs_ctd) only when ctd.compute_spectra is true.
%     - chi: only if an AFE slot is type fpo7.
%     - epsilon: only if an AFE slot is type shear.
%     (Types are matched ignoring case, as processing does.)
%   Also reported, as problems: the yml (or a calibration file it points
%   at) can't be read, and shear probes whose calibration file is missing
%   (epsilon is skipped for them).
%
%   prompt = true (needs a display or console): each missing value is
%   asked for with the usual dialog (MODsetup_validate_metadata.m) and
%   saved to depl_yml, then the yml is reread and checked again.
%
% INPUTS
%   depl_yml - full path to the deployment's yml (depl_meta_data.yml)
%   prompt   - (optional) default false
%
% OUTPUTS
%   report   - struct:
%                .ok       - true when nothing is missing and there are no problems
%                .missing  - cellstr of registry names still without a value
%                .problems - cellstr of messages
%                .yml      - depl_yml
%   metadata - from MODsetup_read_yaml.m ([] if the yml couldn't be read)
%
% CALLED BY
%   (the realtime worker and monitor app - not built yet; see
%   docs/workflow/realtime_processing.md)
%
% CALLS
%   MODsetup_read_yaml.m, MODsetup_metadata_field_registry.m,
%   MODsetup_validate_metadata.m
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

if nargin < 2 || isempty(prompt)
    prompt = false;
end
report = struct('ok', false, 'missing', {{}}, 'problems', {{}}, 'yml', depl_yml);

metadata = [];
try
    metadata = MODsetup_read_yaml(depl_yml);
catch ME
    report.problems{end+1} = sprintf('Could not read %s: %s', depl_yml, ME.message);
    if nargout == 0
        print_report(report);
    end
    return
end

needed = needed_parameters(metadata);
while true
    [~, report.missing] = MODsetup_validate_metadata(metadata, depl_yml, needed, false);
    if ~prompt || isempty(report.missing)
        break
    end
    try
        MODsetup_validate_metadata(metadata, depl_yml, report.missing, true);
        % Answered but not saved: the values were only for this session, so
        % the yml still lacks them and report.missing stays as it is.
        break
    catch ME
        if ~strcmp(ME.identifier, 'MODsetup_validate_metadata:yamlUpdated')
            rethrow(ME)
        end
        metadata = MODsetup_read_yaml(depl_yml);
    end
end

% Shear probes with no calibration file get no epsilon
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

report.ok = isempty(report.missing) && isempty(report.problems);

if nargout == 0
    print_report(report);
end
end %end function

%% Registry names this deployment's manifest needs
function names = needed_parameters(metadata)
registry = MODsetup_metadata_field_registry();
sections = {'afe', 'ctd', 'spectral', 'profile_detection', 'grid'};
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
names = {registry(ismember({registry.yaml_section}, sections)).name};
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
if report.ok
    fprintf('  OK - every parameter this deployment needs is set.\n');
    return
end
if ~isempty(report.missing)
    fprintf('  Missing (%d): %s\n', numel(report.missing), strjoin(report.missing, ', '));
end
for iP = 1:numel(report.problems)
    fprintf('  Problem: %s\n', report.problems{iP});
end
end
