function L2data = MODprocess_single_L1_to_L2_profile(profile, TimeIndex, metadata)
% MODprocess_single_L1_to_L2_profile        Part of MOD_fish_processing
%
% L2data = MODprocess_single_L1_to_L2_profile(profile, TimeIndex, metadata)
%
% DESCRIPTION
%   Converts one detected profile (modProcess_detect_profiles.m) into a
%   Profile####.mat: always the profile's stitched, cropped CTD record
%   (profile_data.ctd, unchanged raw resolution - see OUTPUTS), and, only
%   when this deployment both has epsi hardware and trusts this profile's
%   direction for it, per-scan spectra too (mod_L2_tile_scans.m) - the
%   final science-quality counterpart to MODprocess_single_L1_to_L2.m's
%   per-file "realtime" mode (PLAN.md Section 6.3). When spectra are
%   computed, they're built by stitching the profile's raw epsi/ctd record
%   across however many L1 files it spans (modProcess_extract_profile.m)
%   before windowing, so a profile spanning two L1 files gets no coverage
%   gap at the seam - unlike realtime mode, which drops the trailing
%   partial window at every file end regardless of whether the underlying
%   sampling was actually continuous there.
%
%   Whether epsi spectra get computed for THIS profile:
%     compute_epsi = metadata.manifest.has_epsi && ...
%         (metadata.PROFILES.profile_dir is 'both', or matches profile.direction)
%   metadata.manifest.has_epsi (MODsetup_read_yaml.m) is false for a
%   deployment with no AFE/epsi board at all (a CTD-only vehicle) - no
%   amount of profile_dir tuning can produce spectra data that was never
%   recorded. metadata.PROFILES.profile_dir (default 'down') reflects
%   that, on an epsi-equipped deployment, the CTD/pressure sensor is
%   normally trustworthy on every cast, but shear/fpo7 usually is not
%   (vehicle wake turbulence on the untrusted direction) - so
%   modProcess_detect_profiles.m deliberately returns EVERY detected cast
%   (both directions), and this is the one place that decides, per
%   profile, whether its direction is one to compute epsi spectra for.
%   Every profile - matched direction or not, epsi hardware present or
%   not - still gets a Profile####.mat with its CTD record.
%
%   Pure transformation function - no file I/O beyond what
%   modProcess_extract_profile.m does to load the profile's contributing
%   L1 files. To process one profile by hand:
%       PressureTimeseries = load(fullfile(metadata.paths.meta, 'pressure_time_series.mat'));
%       TimeIndex = load(fullfile(metadata.paths.meta, 'time_index.mat'));
%       profiles = modProcess_detect_profiles(PressureTimeseries, metadata);
%       L2data = MODprocess_single_L1_to_L2_profile(profiles(1), TimeIndex, metadata);
%
% INPUTS
%   profile   - one element of modProcess_detect_profiles.m's output
%               struct array
%   TimeIndex - struct from MODprocess_L1_make_time_index.m
%               (meta/time_index.mat)
%   metadata  - metadata struct (from MODsetup_read_yaml.m). Uses
%               metadata.manifest.has_epsi and metadata.PROFILES.profile_dir
%               directly (profile_dir validated via
%               MODsetup_validate_metadata.m as the first executable line -
%               same point-of-use pattern mod_scan_get_spectra.m uses);
%               passed through, whole, to modProcess_extract_profile.m and
%               mod_L2_tile_scans.m - see those functions' headers for the
%               other fields each reads.
%
% OUTPUTS
%   L2data - always has:
%     ctd                  - profile_data.ctd (modProcess_extract_profile.m's
%                             OUTPUTS): the profile's own dnum/P/T/S/dzdt
%                             etc., stitched across contributing L1 files
%                             and cropped to [dnum_start, dnum_end], at raw
%                             CTD sample resolution (NOT interpolated onto
%                             scan centers) - present and populated
%                             regardless of compute_epsi, direction, or
%                             instrument_manifest, since this is the one
%                             piece of a profile every cast can provide.
%     profile_number, direction  - passthrough from `profile`
%     filenames                  - contributing L1 filenames, in time
%                                   order (from modProcess_extract_profile.m)
%     dnum_start, dnum_end       - passthrough from `profile`
%     profile_gap_fraction       - see NOTES; 0 when compute_epsi is false
%   When compute_epsi is true (see DESCRIPTION), also has
%   mod_L2_tile_scans.m's per-scan OUTPUTS (dnum, pressure, w, temperature,
%   salinity, spectra.*, chi_obs.*, chi_obs_kc.*,
%   nfft/dof/Fs_epsi/N_epsi/scan_step) - epsi's own raw record
%   (profile_data.epsi) is never itself saved into L2data, only these
%   derived per-scan products. When compute_epsi is false, these fields
%   are still present (mod_L2_tile_scans.m's empty-input shape) but every
%   value is empty/0 - a caller can always expect the same field set,
%   whether or not this profile actually has spectra.
%
% CALLED BY
%   MODprocess_all_L1_to_L2_profiles.m
%
% CALLS
%   modProcess_extract_profile.m, mod_L2_tile_scans.m,
%   MODsetup_validate_metadata.m
%
% NOTES
%   No PressureTimeseries is passed to mod_L2_tile_scans.m here (unlike
%   MODprocess_single_L1_to_L2.m's realtime call) - a profile from
%   modProcess_detect_profiles.m is already direction-pure by
%   construction (whatever direction it is - see DESCRIPTION), so per-scan
%   direction gating would be redundant.
%
%   profile_gap_fraction is computed from epsi.segment_id's coverage, not
%   from counting kept vs. candidate scans directly - see the local
%   subfunction below - so it reflects the fraction of raw sample *time*
%   affected, not the fraction of scan windows dropped (which, at 50%
%   overlap, would overcount every dropped scan's neighbors too). Left at
%   0 when compute_epsi is false: with no spectra computed, "fraction of
%   the profile lost to a gap-straddling window" has no meaning.
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

yaml_file = '';
if isfield(metadata, 'paths') && isfield(metadata.paths, 'setup_yml')
    yaml_file = metadata.paths.setup_yml;
end
metadata = MODsetup_validate_metadata(metadata, yaml_file, {'profile_dir'});

if ~any(strcmp(metadata.PROFILES.profile_dir, {'down', 'up', 'both'}))
    error('MODprocess_single_L1_to_L2_profile:invalidProfileDir', ...
        'metadata.PROFILES.profile_dir must be ''down'', ''up'', or ''both'' (got ''%s'').', ...
        metadata.PROFILES.profile_dir);
end

profile_data = modProcess_extract_profile(profile, TimeIndex, metadata);

compute_epsi = metadata.manifest.has_epsi && ...
    (strcmp(metadata.PROFILES.profile_dir, 'both') || strcmp(profile.direction, metadata.PROFILES.profile_dir));

if compute_epsi
    epsi_for_tiling = profile_data.epsi;
else
    % No PressureTimeseries and an empty-dnum epsi both make
    % mod_L2_tile_scans.m return its all-empty shape immediately - reused
    % here rather than duplicating that empty-output struct locally.
    epsi_for_tiling = struct('dnum', []);
end
L2data = mod_L2_tile_scans(epsi_for_tiling, profile_data.ctd, metadata);

L2data.ctd = profile_data.ctd;
L2data.profile_number = profile_data.profile_number;
L2data.direction = profile_data.direction;
L2data.filenames = profile_data.filenames;
L2data.dnum_start = profile_data.dnum_start;
L2data.dnum_end = profile_data.dnum_end;
if compute_epsi
    L2data.profile_gap_fraction = gap_fraction(profile_data.epsi);
else
    L2data.profile_gap_fraction = 0;
end

end %end function

%% Fraction of the epsi record's sample count that falls in a segment_id
% run other than the largest one - a cheap proxy for "how much of this
% profile's raw coverage was on the losing side of an internal gap." 0 for
% an empty/absent segment_id (no gap detected, or no epsi data at all).
function frac = gap_fraction(epsi)
frac = 0;
if ~isfield(epsi, 'segment_id') || isempty(epsi.segment_id)
    return
end
seg = epsi.segment_id;
n = numel(seg);
if n == 0
    return
end
counts = accumarray(seg, 1);
frac = 1 - max(counts) / n;
end
