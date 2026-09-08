function profile_files = MODprocess_all_L1_to_L2_profiles(metadata, profiles_dir, profiles_raw_dir, reprocess_all)
% MODprocess_all_L1_to_L2_profiles        Part of MOD_fish_processing
%
% profile_files = MODprocess_all_L1_to_L2_profiles(metadata, profiles_dir, profiles_raw_dir, reprocess_all)
%
% DESCRIPTION
%   Final science-quality L1->L2 path (PLAN.md Section 6.3), parallel to
%   MODprocess_all_L1_to_L2.m's per-file "realtime" orchestrator. Two
%   phases, run in sequence (PLAN.md Phase A refactor):
%     1. Extraction (MODprocess_all_extract_profiles.m): detect every
%        profile in the deployment, both directions, and stitch each
%        one's raw epsi/ctd record across L1 file boundaries, saved as
%        profiles_raw_dir/Profile####.mat.
%     2. Conversion (MODprocess_single_L1_to_L2_profile.m): load each
%        already-extracted profile and, always carrying its own CTD
%        record and, only when this deployment has epsi hardware and
%        trusts this profile's direction for it, per-scan spectra too,
%        save as profiles_dir/Profile####.mat.
%   Splitting these means MODprocess_single_L1_to_L2_profile.m no longer
%   needs to know how its input was produced - see that function's
%   DESCRIPTION.
%
%   Saves L2 output into its own profiles_dir (default
%   metadata.paths.profiles, a sibling of metadata.paths.L2 and
%   metadata.paths.profiles_raw - not inside either), deliberately kept
%   separate from MODprocess_all_L1_to_L2.m's per-file realtime .mat
%   output and from the raw-extraction directory.
%
%   Skips a profile's conversion if its Profile####.mat already exists and
%   is not older than the corresponding profiles_raw_dir/Profile####.mat -
%   i.e. staleness is now checked one link at a time (L2 vs. its raw
%   extraction input; the raw extraction's own staleness against L1 files
%   is MODprocess_all_extract_profiles.m's job), rather than reaching all
%   the way back to L1 file mtimes directly the way the pre-refactor
%   single-phase version did. A profile whose raw extraction was just
%   redone (e.g. because it touched the newest L1 file) automatically gets
%   reconverted too, since its profiles_raw_dir file's mtime just advanced
%   past its profiles_dir file's mtime - no separate "touches newest" case
%   needed at this phase.
%
%   Each profile's MODprocess_single_L1_to_L2_profile.m call is wrapped in
%   the same retry-on-metadata-update loop MODprocess_all_L1_to_L2.m uses -
%   see that function's DESCRIPTION for why (a missing chi/epsilon field
%   fails deterministically on the first call within a profile, so
%   retrying the whole profile after reloading metadata is always safe,
%   never a partial redo).
%
% INPUTS
%   metadata          - metadata struct (from MODsetup_read_yaml.m), read
%                        once per session and passed through - see PLAN.md
%                        Section 2. Uses metadata.paths.profiles/
%                        .profiles_raw as default output directories;
%                        everything else (paths.meta, paths.L1,
%                        manifest.has_epsi, PROFILES.profile_dir) is read
%                        inside MODprocess_all_extract_profiles.m /
%                        MODprocess_single_L1_to_L2_profile.m.
%   profiles_dir      - (optional) full path to save converted
%                        Profile####.mat files to. Default:
%                        metadata.paths.profiles.
%   profiles_raw_dir  - (optional) full path to save/read raw-extracted
%                        Profile####.mat files. Default:
%                        metadata.paths.profiles_raw.
%   reprocess_all     - (optional) logical, default false. If true,
%                        ignores every up-to-date check (both phases) and
%                        reconverts every profile.
%
% OUTPUTS
%   profile_files - cell array of full paths to all converted
%               Profile####.mat files in profiles_dir after this call
%               (both newly converted and pre-existing)
%
% CALLED BY
%   (top-level scripts / notebooks)
%
% CALLS
%   MODprocess_all_extract_profiles.m, MODprocess_single_L1_to_L2_profile.m,
%   MODsetup_read_yaml.m (only on the retry path)
%
% NOTES
%   Delegates extraction's own missing-prerequisite errors
%   (meta/pressure_time_series.mat, meta/time_index.mat) to
%   MODprocess_all_extract_profiles.m - nothing in this function reads
%   either file directly anymore.
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

if nargin < 2 || isempty(profiles_dir)
    profiles_dir = metadata.paths.profiles;
end
if nargin < 3 || isempty(profiles_raw_dir)
    profiles_raw_dir = metadata.paths.profiles_raw;
end
if nargin < 4 || isempty(reprocess_all)
    reprocess_all = false;
end
if ~exist(profiles_dir, 'dir')
    mkdir(profiles_dir);
end

raw_files = MODprocess_all_extract_profiles(metadata, profiles_raw_dir, reprocess_all);

for iP = 1:numel(raw_files)
    raw_file = raw_files{iP};
    [~, raw_name] = fileparts(raw_file);
    profile_number = sscanf(raw_name, 'Profile%d');
    profile_file = fullfile(profiles_dir, sprintf('Profile%04d.mat', profile_number));

    raw_info = dir(raw_file);
    already_converted = false;
    if exist(profile_file, 'file')
        L2_info = dir(profile_file);
        % Strictly newer, not >= : on a coarse-mtime filesystem, a raw
        % re-extraction and a stale existing L2 file can land on the same
        % tick - erring toward reprocessing (a wasted cycle) rather than
        % skipping (silently stale output) is the safer default here.
        already_converted = L2_info.datenum > raw_info.datenum;
    end

    if ~reprocess_all && already_converted
        continue
    end

    fprintf(1, '%s | profile %04d --> %s | ', ...
        datestr(now, 'YYYY.mm.dd HH:MM:SS'), profile_number, profile_file);

    while true
        try
            profile_data = load(raw_file);
            L2data = MODprocess_single_L1_to_L2_profile(profile_data, metadata);
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
