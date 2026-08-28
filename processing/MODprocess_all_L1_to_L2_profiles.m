function profile_files = MODprocess_all_L1_to_L2_profiles(metadata, profiles_dir, reprocess_all)
% MODprocess_all_L1_to_L2_profiles        Part of MOD_fish_processing
%
% profile_files = MODprocess_all_L1_to_L2_profiles(metadata, profiles_dir, reprocess_all)
%
% DESCRIPTION
%   Final science-quality L1->L2 path (PLAN.md Section 6.3), parallel to
%   MODprocess_all_L1_to_L2.m's per-file "realtime" orchestrator: detects
%   every profile in the deployment, both directions
%   (modProcess_detect_profiles.m), then converts each one to a
%   Profile####.mat (MODprocess_single_L1_to_L2_profile.m) - always
%   carrying that profile's own CTD record, and, only when this
%   deployment has epsi hardware and trusts this profile's direction for
%   it, per-scan spectra too, computed by stitching the profile's raw
%   record across L1 file boundaries before windowing.
%
%   Saves into its own profiles_dir (default metadata.paths.profiles, a
%   sibling of metadata.paths.L2 - not inside it), deliberately kept
%   separate from MODprocess_all_L1_to_L2.m's per-file realtime .mat
%   output.
%
%   Loads meta/pressure_time_series.mat and meta/time_index.mat once
%   (built by MODprocess_all_L0_to_L1.m) and passes them through, so the
%   per-profile work stays pure while the file-I/O cost of building them
%   is paid once per batch run.
%
%   Skips a profile if its Profile####.mat already exists and none of the
%   L1 files it touches are newer than that output - cheaply determined
%   from TimeIndex alone (no epsi/ctd data loaded just to decide this),
%   mirroring MODprocess_all_L1_to_L2.m's "skip unless stale" rule at
%   profile granularity instead of per-file. Every profile touching the
%   single most-recently-modified L1 file in the deployment is always
%   reprocessed, in case that file was still being written.
%
%   Each profile's MODprocess_single_L1_to_L2_profile.m call is wrapped in
%   the same retry-on-metadata-update loop MODprocess_all_L1_to_L2.m uses -
%   see that function's DESCRIPTION for why (a missing chi field fails
%   deterministically on the first chi call within a profile, so retrying
%   the whole profile after reloading metadata is always safe, never a
%   partial redo).
%
% INPUTS
%   metadata      - metadata struct (from MODsetup_read_yaml.m), read once
%                    per session and passed through - see PLAN.md Section 2.
%                    Uses metadata.paths.meta to find pressure_time_series.mat
%                    and time_index.mat, metadata.paths.L1 to load
%                    contributing L1 files, metadata.paths.profiles as the
%                    default output directory. metadata.manifest.has_epsi
%                    and metadata.PROFILES.profile_dir are read (inside
%                    MODprocess_single_L1_to_L2_profile.m) to decide, per
%                    profile, whether spectra get computed - this function
%                    itself runs unconditionally, since CTD-only output is
%                    still meaningful even when neither is true.
%   profiles_dir  - (optional) full path to save Profile####.mat files to.
%                    Default: metadata.paths.profiles.
%   reprocess_all - (optional) logical, default false. If true, ignores
%                    the up-to-date check and reconverts every profile.
%
% OUTPUTS
%   profile_files - cell array of full paths to all Profile####.mat files
%               in profiles_dir after this call (both newly converted and
%               pre-existing)
%
% CALLED BY
%   (top-level scripts / notebooks)
%
% CALLS
%   modProcess_detect_profiles.m, MODprocess_single_L1_to_L2_profile.m
%   MODsetup_read_yaml.m (only on the retry path)
%
% NOTES
%   Errors clearly (rather than silently producing nothing) if
%   meta/pressure_time_series.mat or meta/time_index.mat doesn't exist yet -
%   both are built by MODprocess_all_L0_to_L1.m, so that must have run
%   (with CTD data present) before this function can do anything useful.
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

if nargin < 2 || isempty(profiles_dir)
    profiles_dir = metadata.paths.profiles;
end
if nargin < 3 || isempty(reprocess_all)
    reprocess_all = false;
end
if ~exist(profiles_dir, 'dir')
    mkdir(profiles_dir);
end

pressure_timeseries_file = fullfile(metadata.paths.meta, 'pressure_time_series.mat');
if ~exist(pressure_timeseries_file, 'file')
    error('MODprocess_all_L1_to_L2_profiles:noPressureTimeseries', ...
        ['%s does not exist yet. It is built by MODprocess_all_L0_to_L1.m ' ...
         '(via MODprocess_L1_make_pressure_timeseries.m and ' ...
         'mod_L1_detect_profiling_direction.m) once this deployment has ' ...
         'CTD data in its L1 files - run that first.'], pressure_timeseries_file);
end
PressureTimeseries = load(pressure_timeseries_file);

time_index_file = fullfile(metadata.paths.meta, 'time_index.mat');
if ~exist(time_index_file, 'file')
    error('MODprocess_all_L1_to_L2_profiles:noTimeIndex', ...
        ['%s does not exist yet. It is built by MODprocess_all_L0_to_L1.m ' ...
         '(via MODprocess_L1_make_time_index.m) - run that first.'], time_index_file);
end
TimeIndex = load(time_index_file);

profiles = modProcess_detect_profiles(PressureTimeseries, metadata);

if isempty(profiles)
    disp('MODprocess_all_L1_to_L2_profiles: no profiles detected for this deployment.')
    profile_files = {};
    return
end

% The single most-recently-modified L1 file in the whole deployment -
% any profile touching it is always reprocessed, in case that file was
% still being written when this last ran.
L1_listing = dir(fullfile(metadata.paths.L1, '*.mat'));
[~, i_newest] = max([L1_listing.datenum]);
newest_L1_filename = L1_listing(i_newest).name;

for i = 1:numel(profiles)
    profile = profiles(i);
    profile_file = fullfile(profiles_dir, sprintf('Profile%04d.mat', profile.profile_number));

    touching = touching_filenames(profile, TimeIndex);
    touches_newest = any(strcmp(touching, newest_L1_filename));

    already_converted = false;
    if exist(profile_file, 'file')
        profile_info = dir(profile_file);
        touching_dates = nan(numel(touching), 1);
        for iT = 1:numel(touching)
            d = dir(fullfile(metadata.paths.L1, touching{iT}));
            if ~isempty(d)
                touching_dates(iT) = d.datenum;
            end
        end
        already_converted = isempty(touching_dates) || profile_info.datenum >= max(touching_dates);
    end

    if ~reprocess_all && already_converted && ~touches_newest
        continue
    end

    fprintf(1, '%s | profile %04d (%s, %s -> %s) --> Profile%04d.mat | ', ...
        datestr(now, 'YYYY.mm.dd HH:MM:SS'), profile.profile_number, profile.direction, ...
        datestr(profile.dnum_start, 'HH:MM:SS'), datestr(profile.dnum_end, 'HH:MM:SS'), ...
        profile.profile_number);

    while true
        try
            L2data = MODprocess_single_L1_to_L2_profile(profile, TimeIndex, metadata);
            break
        catch ME
            if strcmp(ME.identifier, 'MODsetup_validate_metadata:yamlUpdated')
                metadata = MODsetup_read_yaml(metadata.paths.setup_yml);
                continue % retry this same profile with fresh, complete metadata
            end
            rethrow(ME)
        end
    end

    save(profile_file, '-struct', 'L2data')
    fprintf(1, '%d scans\n', numel(L2data.dnum));

end %end loop through profiles

profile_listing = dir(fullfile(profiles_dir, 'Profile*.mat'));
profile_files = fullfile({profile_listing.folder}, {profile_listing.name})';

end %end function

%% Cheap (TimeIndex-only, no data loaded) lookup of which L1 filenames a
% profile's time range touches - same file-range logic
% modProcess_extract_profile.m uses to actually load them, duplicated here
% (not shared) since this call site only needs filenames, not data.
function names = touching_filenames(profile, TimeIndex)
startFile = find(profile.dnum_start >= TimeIndex.dnum_start, 1, 'last');
endFile = find(profile.dnum_end <= TimeIndex.dnum_end, 1, 'first');
if isempty(startFile)
    startFile = 1;
end
if isempty(endFile)
    endFile = numel(TimeIndex.dnum_end);
end
if isempty(TimeIndex.dnum_start) || endFile < startFile
    names = {};
    return
end
names = TimeIndex.filename(startFile:endFile);
end
