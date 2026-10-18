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
%   the processing run and its yml (and, for L2, profiles_L1 and
%   profiles_L2, which run's L1 they were made from), and the git commit of the MOD_fish_processing code. Rewritten only when
%   that content changes (the "updated" line alone doesn't count), so it's
%   cheap to call on every realtime pass.
%
% INPUTS
%   folder   - the level folder (e.g. metadata.paths.L1)
%   level    - 'raw', 'L0', 'L1', 'L2', 'profiles_L1', 'profiles_L2' or 'grid'
%   metadata - from MODsetup_read_yaml.m (for the deployment and parameters)
%
% OUTPUTS
%   written - true if _README.txt was (re)written
%
% CALLED BY
%   MODprocess_deployment.m
%
% CALLS
%   MODsetup_metadata_field_registry.m, MODutil_code_version.m
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

switch level
    case 'raw'
        what = {'This survey''s raw files (.modraw), as fctd_epsi wrote them. On DEV3 each is a hard link to the same file in the cruise-wide RAW_full_cruise/ folder: a real file, so a copy of this folder has the data.'};
        steps = {'Linked here by MODutil_route_raw_by_survey.m from the CTD.survey line in each file''s header. Nothing is changed in the raw files.'};
        sections = {};
    case 'L0'
        what = {'One .mat per raw file: every block parsed (epsi, ctd, alt, vnav, gps, fluor, ...), with raw_file_info (name, bytes).'
                'EFE channels in volts/g using the standard EFE board (epsi_conversion records the counts <-> volts/g conversion).'};
        steps = {'MODprocess_all_modraw_to_L0.m -> MODprocess_single_modraw_to_L0.m. No calibration besides the standard EFE conversion.'
                 'Each file keeps its SBE calibration as ctd_cal (applied at L1): the raw file''s $DCAL (what the SBE reports), else calibrations_root/SBE/<SN>.CAL; ctd_cal.source says which. The survey''s calibration is recorded in <survey>/meta/ctd_calibration.mat.'};
        sections = {};
    case 'L1'
        what = {'One .mat per raw file: physical-unit timeseries - epsi (t1/t2/s1/s2/a1-a3 volts/g with this deployment''s channel names), ctd (P, T, C, SP, CT, SR, sigma0, z, dzdt), alt (hab), vnav (with tilt, spin, pitch, roll, yaw), gps, twist, ...'
                'This is the raw data turned into real data: no spectral or cast choices yet - the starting point for postprocessing.'};
        steps = {'MODprocess_all_L0_to_L1.m -> MODprocess_single_L0_to_L1.m: the run yml''s EFE settings, SBE CTD calibration (the L0 file''s ctd_cal), derived CTD fields (GSW/TEOS-10), altimeter height above bottom, per-file twist.'
                 'Files built from this L1 are in this run''s meta/ (next to L1/): time_index.mat, pressure_time_series.mat (profiling direction), twist_time_series.mat, gps_time_series.mat (the GPS track), fpo7_calibration.mat, l1_file_cache.mat.'};
        sections = {'afe', 'ctd', 'profile_detection'};
    case 'L2'
        what = {'One .mat per L1 file, with the same name: per-scan spectra and turbulence (chi from FP07, epsilon from shear) for the scans in the direction(s) set by profile_detection.profile_dir. Scans only - the time series are in the L1 file of the same name.'};
        steps = {'MODprocess_all_L1_to_L2.m -> MODprocess_single_L1_to_L2.m (whole L1 files tiled into scans - the realtime product).'};
        sections = {'spectral', 'ctd', 'profile_detection', 'chi', 'epsilon'};
    case 'profiles_L1'
        what = {'One Profile####.mat per cast in this run''s meta/casts.mat: the L1 epsi/ctd record stitched across L1 files for that cast.'};
        steps = {'MODprocess_all_extract_profiles.m -> modProcess_extract_profile.m (postprocessing).'};
        sections = {'profile_detection', 'spectral'};
    case 'profiles_L2'
        what = {'One Profile####.mat per cast, with the same name as in profiles_L1/: the same per-scan spectra and turbulence as L2, computed on the whole cast. Scans only - the time series are in profiles_L1/.'};
        steps = {'MODprocess_all_L1_to_L2.m pointed at profiles_L1/ (postprocessing).'};
        sections = {'spectral', 'ctd', 'profile_detection', 'chi', 'epsilon'};
    case 'grid'
        what = {'grid.mat: one column per cast in this run''s meta/casts.mat (down and up), one row per depth bin of grid.z_bin_m m. CTD = mean of every L1 CTD sample in the bin; turbulence = mean of the L2 scans whose center is in the bin (NaN where there is none, see n_scans; no epsilon_final without shear probes). Per cast: latitude/longitude = the first GPS fix for an Epsi downcast from the ship (it free falls where it was dropped), else the mean fix during the cast. grid.variables lists each field''s unit and description.'};
        steps = {'MODprocess_grid.m, from the L1 and L2 files (by file) or profiles_L1/ and profiles_L2/ (by profile) - see grid.source. Only new or changed casts are rebinned.'};
        sections = {'grid', 'profile_detection'};
    otherwise
        error('MODutil_write_folder_readme:unknownLevel', 'Unknown level "%s".', level);
end

survey = '';
if isfield(metadata, 'paths') && isfield(metadata.paths, 'data_root')
    [~, survey] = fileparts(metadata.paths.data_root);
end
L = {sprintf('%s/ - %s', level, survey)};
run_name = '';
if isfield(metadata, 'run') && ~isempty(metadata.run.name)
    run_name = metadata.run.name;
end
if ismember(level, {'raw', 'L0'}) && ~isempty(run_name)
    L{end+1, 1} = 'Shared by every processing run of this survey (processed/<run>/).';
elseif ~isempty(run_name)
    L{end+1, 1} = sprintf('Processing run: %s (settings: meta/meta_data_%s.yml in the survey folder)', run_name, run_name);
    if ismember(level, {'L2', 'profiles_L1', 'profiles_L2', 'grid'})
        if isempty(metadata.run.L1_from)
            L{end+1, 1} = sprintf('From L1: this run''s own (processed/%s/L1)', run_name);
        else
            L{end+1, 1} = sprintf('From L1: run %s''s (processed/%s/L1)', metadata.run.L1_from, metadata.run.L1_from);
        end
    end
end
L = [L; {''; 'What''s in these files:'}];
L = [L; strcat({'  '}, what)];
L = [L; {''; 'What was done:'}; strcat({'  '}, steps)];
param_lines = parameter_lines(metadata, sections);
if ~isempty(param_lines)
    yml_name = 'the yml';
    if isfield(metadata, 'paths') && isfield(metadata.paths, 'setup_yml')
        [~, n, e] = fileparts(metadata.paths.setup_yml);
        yml_name = ['meta/' n e];
    end
    L = [L; {''; ['Parameters (from ' yml_name '):']}; param_lines];
end
L = [L; {''; ['Vehicle: ' field_or(metadata, 'vehicle_name') ', fish: ' field_or(metadata, 'fish_flag')]
         ['Code: MOD_fish_processing ' MODutil_code_version()]
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
