function L2data = MODprocess_single_L1_to_L2(data, metadata, PressureTimeseries)
% MODprocess_single_L1_to_L2        Part of MOD_fish_processing
%
% L2data = MODprocess_single_L1_to_L2(data, metadata, PressureTimeseries)
%
% DESCRIPTION
%   Converts one L1 file's epsi timeseries into per-scan spectra (L2),
%   keeping the whole file's scans in one output struct rather than
%   splitting into per-profile files (PLAN.md Section 4 - this is the
%   deliberate divergence from the old mod_fish_lib profile-based L2
%   approach). Scans tile data.epsi within this file only ("realtime"
%   mode - see PLAN.md's Context section):
%   N_epsi = scan_length samples per scan, step = (1-scan_overlap)*N_epsi.
%
%   Only scans classified as descending (PressureTimeseries.is_down at the
%   scan's center time) get spectra computed - see
%   mod_L1_detect_profiling_direction.m for why and how that
%   classification is made. This is a thin, pure wrapper around
%   mod_L2_tile_scans.m (the shared windowing/spectra core, also used by
%   MODprocess_single_L1_to_L2_profile.m's profile-cut path - PLAN.md
%   Section 6.3) - no file I/O here, and PressureTimeseries is a required
%   argument rather than self-loaded from meta/pressure_time_series.mat,
%   matching MODprocess_single_L0_to_L1.m's external_ctd-as-argument
%   precedent. To process a single L1 file by hand:
%       PressureTimeseries = load(fullfile(metadata.paths.meta, 'pressure_time_series.mat'));
%       data = load('L1/modsom_07.mat');
%       L2data = MODprocess_single_L1_to_L2(data, metadata, PressureTimeseries);
%
%   See mod_L2_tile_scans.m for the full chi_obs computation chain
%   (mod_scan_get_spectra.m, mod_scan_fpo7_transfer_function.m,
%   mod_scan_fpo7_cutoff.m, toolbox/seawater/ktemp.m,
%   mod_scan_calc_chi_obs.m) and docs/workflow/L2_calc_chi.md for the
%   full writeup.
%
% INPUTS
%   data      - struct from an L1 .mat file (has epsi, ctd, ...)
%   metadata  - metadata struct (from MODsetup_read_yaml.m). Passed
%               straight through to mod_L2_tile_scans.m - see that
%               function's header for the exact fields it reads.
%   PressureTimeseries - struct with dnum, is_down (from
%               mod_L1_detect_profiling_direction.m via
%               meta/pressure_time_series.mat) - the whole-deployment
%               record, not sliced to this file. Each scan's center time
%               is nearest-matched against it.
%
% OUTPUTS
%   L2data - see mod_L2_tile_scans.m's OUTPUTS - identical field shape.
%   nbscan is 0 (all fields empty) if this file has no epsi data or no
%   scans land on a descending part of the record.
%
% CALLED BY
%   MODprocess_all_L1_to_L2.m
%
% CALLS
%   mod_L2_tile_scans.m
%
% NOTES
%   File-boundary coverage gaps (a partial window at the end of this file
%   that doesn't reach a full N_epsi samples is dropped, not padded from
%   the next file) are an accepted, documented limitation of this
%   per-file "realtime" mode - see PLAN.md's Context section for why.
%   MODprocess_single_L1_to_L2_profile.m's profile-cut path is what
%   eliminates this gap for the final science-quality product, by
%   stitching the continuous raw record across L1 files first
%   (modProcess_extract_profile.m) before mod_L2_tile_scans.m windows it.
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

L2data = mod_L2_tile_scans(data.epsi, data.ctd, metadata, PressureTimeseries);

end %end function
