function profile_files = MODprocess_all_extract_profiles(metadata, profiles_dir, reprocess_all)
% MODprocess_all_extract_profiles        Part of MOD_fish_processing
%
% profile_files = MODprocess_all_extract_profiles(metadata, profiles_dir, reprocess_all)
%
% DESCRIPTION
%   Extraction-only half of the profile pipeline (PLAN.md Phase A
%   refactor, Section 6.3): takes every profile in the deployment, both
%   directions, from the cast table (MODprocess_L1_update_cast_table.m,
%   which runs modProcess_detect_profiles.m and saves meta/casts.mat - the
%   same casts realtime gridding uses), then stitches each one's
%   raw epsi/ctd record across L1 file boundaries
%   (modProcess_extract_profile.m) and saves it as Profile####.mat - the
%   stitched-but-not-yet-converted record, no spectra/chi/epsilon. This
%   used to happen inline inside a dedicated per-profile conversion
%   wrapper; pulling it out here means the resulting Profile####.mat files
%   are just another directory of epsi/ctd-shaped .mat files -
%   MODprocess_all_L1_to_L2.m (the same driver realtime mode uses,
%   pointed at this function's output directory instead of an L1
%   directory) converts them via MODprocess_single_L1_to_L2.m with no
%   profile-specific code path at all - see that driver's DESCRIPTION.
%
%   Saves into its own profiles_dir (default metadata.paths.profiles_L1),
%   a sibling of metadata.paths.profiles_L2 (the L2/converted output
%   directory, unchanged) and metadata.paths.L2.
%
%   Skips a profile if its Profile####.mat already exists and none of the
%   L1 files it touches are newer than that output - cheaply determined
%   from TimeIndex alone (no epsi/ctd data loaded just to decide this),
%   mirroring MODprocess_all_L1_to_L2.m's "skip unless stale" rule at
%   profile granularity instead of per-file. Every profile touching the
%   single most-recently-modified L1 file in the deployment is always
%   reprocessed, in case that file was still being written.
%
%   Each profile's modProcess_extract_profile.m call is wrapped in a
%   retry-on-metadata-update loop - see MODprocess_all_L1_to_L2.m's
%   DESCRIPTION for why (a missing field fails deterministically on the
%   first validation call, so retrying the whole profile after reloading
%   metadata is always safe, never a partial redo).
%
% INPUTS
%   metadata      - metadata struct (from MODsetup_read_yaml.m). Uses
%                    metadata.paths.L1_meta to find pressure_time_series.mat
%                    and time_index.mat (the meta/ next to the L1 they
%                    were built from), metadata.paths.meta for this run's
%                    casts.mat, metadata.paths.L1 to load
%                    contributing L1 files, metadata.paths.profiles_L1 as
%                    the default output directory.
%   profiles_dir  - (optional) full path to save Profile####.mat files to.
%                    Default: metadata.paths.profiles_L1.
%   reprocess_all - (optional) logical, default false. If true, ignores
%                    the up-to-date check and re-extracts every profile.
%
% OUTPUTS
%   profile_files - cell array of full paths to all Profile####.mat files
%               in profiles_dir after this call (both newly extracted and
%               pre-existing)
%
% CALLED BY
%   MODprocess_deployment.m ('by', 'profile'), top-level scripts - followed by
%   MODprocess_all_L1_to_L2.m pointed at this function's output directory)
%
% CALLS
%   MODprocess_L1_update_cast_table.m, modProcess_extract_profile.m,
%   MODsetup_read_yaml.m (only on the retry path), MODutil_provenance.m
%
% NOTES
%   Errors clearly (rather than silently producing nothing) if
%   meta/pressure_time_series.mat or meta/time_index.mat doesn't exist yet -
%   both are built by MODprocess_all_L0_to_L1.m, so that must have run
%   (with CTD data present) before this function can do anything useful.
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

if nargin < 2 || isempty(profiles_dir)
    profiles_dir = metadata.paths.profiles_L1;
end
if nargin < 3 || isempty(reprocess_all)
    reprocess_all = false;
end
if ~exist(profiles_dir, 'dir')
    mkdir(profiles_dir);
end

pressure_timeseries_file = fullfile(metadata.paths.L1_meta, 'pressure_time_series.mat');
if ~exist(pressure_timeseries_file, 'file')
    error('MODprocess_all_extract_profiles:noPressureTimeseries', ...
        ['%s does not exist yet. It is built by MODprocess_all_L0_to_L1.m ' ...
         '(via MODprocess_L1_make_pressure_timeseries.m and ' ...
         'mod_L1_detect_profiling_direction.m) once this deployment has ' ...
         'CTD data in its L1 files - run that first.'], pressure_timeseries_file);
end

time_index_file = fullfile(metadata.paths.L1_meta, 'time_index.mat');
if ~exist(time_index_file, 'file')
    error('MODprocess_all_extract_profiles:noTimeIndex', ...
        ['%s does not exist yet. It is built by MODprocess_all_L0_to_L1.m ' ...
         '(via MODprocess_L1_make_time_index.m) - run that first.'], time_index_file);
end
TimeIndex = load(time_index_file);

% The one cast table (meta/casts.mat) - realtime grids by the same casts.
% Every cast is extracted, including one that runs into the end of the record.
[profiles, metadata] = MODprocess_L1_update_cast_table(metadata);

if isempty(profiles)
    disp('MODprocess_all_extract_profiles: no profiles detected for this deployment.')
    profile_files = {};
    return
end

% The single most-recently-modified L1 file in the whole deployment -
% any profile touching it is always re-extracted, in case that file was
% still being written when this last ran.
L1_listing = dir(fullfile(metadata.paths.L1, '*.mat'));
[~, i_newest] = max([L1_listing.datenum]);
newest_L1_filename = L1_listing(i_newest).name;

for i = 1:numel(profiles)
    profile = profiles(i);
    profile_file = fullfile(profiles_dir, sprintf('Profile%04d.mat', profile.profile_number));

    touching = touching_filenames(profile, TimeIndex);
    touches_newest = any(strcmp(touching, newest_L1_filename));

    already_extracted = false;
    if exist(profile_file, 'file')
        profile_info = dir(profile_file);
        touching_dates = nan(numel(touching), 1);
        for iT = 1:numel(touching)
            d = dir(fullfile(metadata.paths.L1, touching{iT}));
            if ~isempty(d)
                touching_dates(iT) = d.datenum;
            end
        end
        already_extracted = isempty(touching_dates) || profile_info.datenum >= max(touching_dates);
    end

    if ~reprocess_all && already_extracted && ~touches_newest
        continue
    end

    fprintf(1, '%s | profile %04d (%s, %s -> %s) --> Profile%04d.mat | ', ...
        datestr(now, 'YYYY.mm.dd HH:MM:SS'), profile.profile_number, profile.direction, ...
        datestr(profile.dnum_start, 'HH:MM:SS'), datestr(profile.dnum_end, 'HH:MM:SS'), ...
        profile.profile_number);

    while true
        try
            profile_data = modProcess_extract_profile(profile, TimeIndex, metadata);
            break
        catch ME
            if strcmp(ME.identifier, 'MODsetup_validate_metadata:yamlUpdated')
                metadata = MODsetup_read_yaml(metadata.paths.setup_yml);
                continue % retry this same profile with fresh, complete metadata
            end
            rethrow(ME)
        end
    end

    profile_data.provenance = MODutil_provenance(fullfile(metadata.paths.L1, profile_data.filenames), metadata);
    save(profile_file, '-struct', 'profile_data')
    fprintf(1, '%d epsi samples, %d ctd samples\n', ...
        numel(profile_data.epsi.dnum), numel(profile_data.ctd.dnum));

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
