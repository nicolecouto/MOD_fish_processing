function written = MODutil_write_folder_readme(folder, level, metadata)
% MODutil_write_folder_readme        Part of MOD_fish_processing
%
% written = MODutil_write_folder_readme(folder, level, metadata)
%
% DESCRIPTION
%   Writes <folder>/_README.txt so it's clear from the folder what its
%   files hold and what has been done to them: the level, what each file
%   contains, the processing steps, the parameters that level used (values
%   from metadata, via MODsetup_metadata_field_registry.m), the deployment,
%   and the git commit of the MOD_fish_processing code. Rewritten only when
%   that content changes (the "updated" line alone doesn't count), so it's
%   cheap to call on every realtime pass.
%
% INPUTS
%   folder   - the level folder (e.g. metadata.paths.L1)
%   level    - 'raw', 'L0', 'L1', 'L2', 'profiles_L1' or 'profiles_L2'
%   metadata - from MODsetup_read_yaml.m (for the deployment and parameters)
%
% OUTPUTS
%   written - true if _README.txt was (re)written
%
% CALLED BY
%   MODprocess_deployment.m
%
% CALLS
%   MODsetup_metadata_field_registry.m
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

switch level
    case 'raw'
        what = {'Links to this survey''s raw files (.modraw) in the cruise-wide RAW_full_cruise/ folder, as fctd_epsi wrote them.'};
        steps = {'Linked here by MODutil_route_raw_by_survey.m from the CTD.survey line in each file''s header. Nothing is changed in the raw files.'};
        sections = {};
    case 'L0'
        what = {'One .mat per raw file: every block parsed (epsi, ctd, alt, vnav, gps, fluor, ...), with raw_file_info (name, bytes).'
                'EFE channels in volts/g using the standard EFE board (epsi_conversion records the counts <-> volts/g conversion).'};
        steps = {'MODprocess_all_modraw_to_L0.m -> MODprocess_single_modraw_to_L0.m. No calibration besides the standard EFE conversion.'};
        sections = {};
    case 'L1'
        what = {'One .mat per raw file: physical-unit timeseries - epsi (t1/t2/s1/s2/a1-a3 volts/g with this deployment''s channel names), ctd (P, T, C, SP, CT, SR, sigma0, z, dzdt), alt (hab), vnav, gps, twist, ...'
                'This is the raw data turned into real data: no spectral or cast choices yet - the starting point for postprocessing.'};
        steps = {'MODprocess_all_L0_to_L1.m -> MODprocess_single_L0_to_L1.m: depl_meta_data.yml EFE settings, SBE CTD calibration, derived CTD fields (GSW/TEOS-10), altimeter height above bottom, per-file twist.'
                 'Deployment-wide files built from L1 are in meta/: time_index.mat, pressure_time_series.mat (profiling direction), twist_time_series.mat, fpo7_calibration.mat, casts.mat.'};
        sections = {'afe', 'ctd', 'profile_detection'};
    case 'L2'
        what = {'One .mat per L1 file: per-scan spectra and turbulence (chi from FP07, epsilon from shear) for the scans in the direction(s) set by profile_detection.profile_dir, with the CTD record.'};
        steps = {'MODprocess_all_L1_to_L2.m -> MODprocess_single_L1_to_L2.m (whole L1 files tiled into scans - the realtime product).'};
        sections = {'spectral', 'ctd', 'profile_detection', 'chi', 'epsilon'};
    case 'profiles_L1'
        what = {'One Profile####.mat per cast in meta/casts.mat: the L1 epsi/ctd record stitched across L1 files for that cast.'};
        steps = {'MODprocess_all_extract_profiles.m -> modProcess_extract_profile.m (postprocessing).'};
        sections = {'profile_detection', 'spectral'};
    case 'profiles_L2'
        what = {'One Profile####.mat per cast: the same per-scan spectra and turbulence as L2, computed on the whole cast.'};
        steps = {'MODprocess_all_L1_to_L2.m pointed at profiles_L1/ (postprocessing).'};
        sections = {'spectral', 'ctd', 'profile_detection', 'chi', 'epsilon'};
    otherwise
        error('MODutil_write_folder_readme:unknownLevel', 'Unknown level "%s".', level);
end

survey = '';
if isfield(metadata, 'paths') && isfield(metadata.paths, 'data_root')
    [~, survey] = fileparts(metadata.paths.data_root);
end
L = {sprintf('%s/ - %s', level, survey)
     ''
     'What''s in these files:'};
L = [L; strcat({'  '}, what)];
L = [L; {''; 'What was done:'}; strcat({'  '}, steps)];
param_lines = parameter_lines(metadata, sections);
if ~isempty(param_lines)
    L = [L; {''; 'Parameters (from meta/depl_meta_data.yml):'}; param_lines];
end
L = [L; {''; ['Vehicle: ' field_or(metadata, 'vehicle_name') ', fish: ' field_or(metadata, 'fish_flag')]
         ['Code: MOD_fish_processing ' code_version()]
         'Units of every field: setup/MODunits_L0.m ... MODunits_L3.m in MOD_fish_processing.'}];

readme = fullfile(folder, '_README.txt');
old = '';
if isfile(readme)
    old = fileread(readme);
    old = regexprep(old, '\nUpdated: [^\n]*\n?$', '');
end
new_text = strjoin(L, newline);
written = ~strcmp(strtrim(old), strtrim(new_text));
if written && isfolder(folder)
    stamp = char(datetime('now', 'TimeZone', 'UTC', 'Format', 'yyyy-MM-dd HH:mm:ss'));
    fid = fopen(readme, 'w');
    fprintf(fid, '%s\nUpdated: %s UTC\n', new_text, stamp);
    fclose(fid);
end
end %end function

%% '  section.key = value' for each registry parameter in these sections
function lines = parameter_lines(metadata, sections)
lines = {};
for spec = MODsetup_metadata_field_registry()
    if ~ismember(spec.yaml_section, sections)
        continue
    end
    v = get_path(metadata, spec.metadata_path);
    if isempty(v) && ~ischar(v)
        continue % not set (not needed for this deployment)
    end
    if isnumeric(v) || islogical(v)
        v = mat2str(v);
    end
    lines{end+1, 1} = sprintf('  %s.%s = %s', spec.yaml_section, spec.yaml_key, char(string(v))); %#ok<AGROW>
end
end

function v = get_path(s, path)
v = [];
for i = 1:numel(path)
    if ~isstruct(s) || ~isfield(s, path{i})
        return
    end
    s = s.(path{i});
end
v = s;
end

function s = field_or(m, f)
s = '';
if isfield(m, f)
    s = char(string(m.(f)));
end
end

%% Short git commit of this repo, with "+ local changes" if the tree is dirty
function v = code_version()
persistent cached % the code doesn't change during a run
if ~isempty(cached)
    v = cached;
    return
end
repo = fileparts(fileparts(mfilename('fullpath')));
[status, sha] = system(sprintf('git -C "%s" rev-parse --short HEAD', repo));
if status ~= 0
    v = '(not a git checkout)';
    return
end
v = ['commit ' strtrim(sha)];
[~, dirty] = system(sprintf('git -C "%s" status --porcelain --untracked-files=no', repo));
if ~isempty(strtrim(dirty))
    v = [v ' + local changes'];
end
cached = v;
end
