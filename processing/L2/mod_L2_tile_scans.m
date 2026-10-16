function tiled_scans = mod_L2_tile_scans(epsi, metadata, PressureTimeseries)
% mod_L2_tile_scans        Part of MOD_fish_processing
%
% tiled_scans = mod_L2_tile_scans(epsi, metadata, PressureTimeseries)
%
% DESCRIPTION
%   Pure index math: decides where scan boundaries and within-scan fft
%   segment boundaries fall in one continuous epsi record - nothing about
%   spectra, CTD, or chi/epsilon (that's MODprocess_single_L1_to_L2.m,
%   which calls this first, then loops over the indices this returns to
%   slice data and compute everything else per scan).
%
%   Tiles epsi into N_epsi-sample scans overlapping by scan_overlap
%   (scan_step = (1-scan_overlap)*N_epsi) - N_epsi (scan_length) is derived
%   from fft_length/fft_segments_per_scan
%   (processing/scans/mod_scan_length_from_segments.m), not itself a yaml-
%   configurable field. Also derives the within-scan fft segment start
%   offsets (processing/scans/mod_scan_fft_seg_starts.m) - the same
%   relative pattern for every scan, since fft_length and the hardcoded
%   50% intra-scan overlap are fixed.
%
%   Two ways this generalizes for both callers of
%   MODprocess_single_L1_to_L2.m (a whole L1 file, or one already-
%   extracted profile):
%     - Direction gating (PressureTimeseries) is OPTIONAL (3rd arg).
%       MODprocess_all_L1_to_L2.m passes it - a scan's center time is nearest-matched
%       against it, and a scan is kept only when the fish was moving in a
%       direction metadata.PROFILES.profile_dir trusts: 'down'
%       (dPdt_smoothed > speedLim_scan_m_s), 'up' (dPdt_smoothed <
%       -speedLim_scan_m_s) or 'both' (either). A scan slower than that
%       (surface, turnarounds), in a gap in the pressure record (two
%       samples more than ctd_gap_factor median intervals apart) or
%       outside it is dropped. For a profile cut by
%       modProcess_detect_profiles.m (already one direction) this mostly
%       confirms the direction; called without it, every candidate scan
%       is kept.
%     - Gap-boundary safety: if epsi.segment_id is present (set only by
%       modProcess_extract_profile.m - never by the realtime per-file
%       path), any candidate scan window whose samples span more than one
%       segment_id is skipped - the profile-cut generalization of "a
%       trailing partial window that doesn't reach a full N_epsi samples
%       is dropped, not padded" (see NOTES). Absent epsi.segment_id, this
%       check is a no-op, so realtime-mode behavior is unchanged.
%
% INPUTS
%   epsi     - data.epsi (from an L1 file) or profile_data.epsi (from
%              modProcess_extract_profile.m) - one continuous record.
%              Optional field: segment_id (Nx1 int, only ever set by
%              modProcess_extract_profile.m) - see DESCRIPTION.
%   metadata - metadata struct (from MODsetup_read_yaml.m). Uses:
%              metadata.PROCESS.fft_length, .fft_segments_per_scan
%              (together derive N_epsi/scan_length, dof, and
%              fft_seg_starts - see OUTPUTS), .scan_overlap, .Fs_epsi,
%              and, with PressureTimeseries, PROFILES.profile_dir,
%              PROFILES.speedLim_scan_m_s and PROFILES.ctd_gap_factor.
%   PressureTimeseries - (optional) struct with dnum, dPdt_smoothed (from
%              mod_L1_detect_profiling_direction.m via
%              meta/pressure_time_series.mat) - the whole-deployment
%              record, not sliced to this epsi record. When provided,
%              each scan's center time is nearest-matched against it and
%              only scans in the profile_dir direction(s) are kept
%              (realtime mode). When
%              omitted or empty, every candidate scan is direction-ungated
%              (profile-cut mode - see DESCRIPTION).
%
% OUTPUTS
%   tiled_scans - struct with, for each kept scan:
%     idx0, idx1 - nbscan x 1 each, absolute sample bounds into epsi for
%                  this scan (idx1 = idx0 + N_epsi - 1)
%     dnum       - nbscan x 1, scan center time [datenum] - a byproduct of
%                  the same validity loop that computes idx0/idx1 (needed
%                  to check direction/segment gating), kept here rather
%                  than making every caller re-derive it from idx0/idx1.
%     fft_seg_starts - 1 x fft_segments_per_scan, within-scan fft segment
%                  start offsets (see mod_scan_fft_seg_starts.m) - the
%                  same for every scan, so this is not stacked per scan. A
%                  given scan's absolute per-segment start indices are
%                  idx0 + fft_seg_starts - 1.
%     fft_length, fft_segments_per_scan, dof, Fs_epsi, N_epsi, scan_step -
%                  provenance. fft_segments_per_scan is the actual
%                  yaml-configurable input; N_epsi (scan_length) is
%                  derived from it and fft_length
%                  (processing/scans/mod_scan_length_from_segments.m), and dof
%                  from fft_segments_per_scan alone (processing/scans/mod_scan_dof.m).
%   nbscan is 0 (idx0/idx1/dnum all empty) if epsi has no data, is too
%   short for even one scan, or (with PressureTimeseries) no scan lands on
%   a part of the record moving in the profile_dir direction(s).
%
% CALLED BY
%   MODprocess_single_L1_to_L2.m
%
% CALLS
%   MODsetup_validate_metadata.m, processing/scans/mod_scan_dof.m,
%   processing/scans/mod_scan_length_from_segments.m,
%   processing/scans/mod_scan_fft_seg_starts.m
%
% NOTES
%   File-boundary/segment-boundary coverage gaps (a partial window at the
%   end of the record - or, when epsi.segment_id is present, at any
%   internal gap - that doesn't reach a full N_epsi samples) is dropped,
%   not padded from beyond the boundary. In realtime mode this is an
%   accepted, documented limitation (see MODprocess_single_L1_to_L2.m); in
%   profile-cut mode it only ever triggers at a genuine timestamp gap
%   (modProcess_extract_profile.m's epsi_gap_factor threshold) - an
%   ordinary L1 file-rotation boundary with continuous sampling stitches
%   seamlessly and loses nothing.
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

yaml_file = '';
if isfield(metadata, 'paths') && isfield(metadata.paths, 'setup_yml')
    yaml_file = metadata.paths.setup_yml;
end
metadata = MODsetup_validate_metadata(metadata, yaml_file, ...
    {'fft_length', 'fft_segments_per_scan', 'scan_overlap', 'Fs_epsi'});

if nargin < 3
    PressureTimeseries = [];
end
have_direction_gate = ~isempty(PressureTimeseries);
if have_direction_gate
    metadata = MODsetup_validate_metadata(metadata, yaml_file, {'profile_dir', 'speedLim_scan_m_s', 'ctd_gap_factor'});
    profile_dir = lower(char(string(metadata.PROFILES.profile_dir)));
    if ~any(strcmp(profile_dir, {'down', 'up', 'both'}))
        error('mod_L2_tile_scans:badProfileDir', ...
            'profile_detection.profile_dir must be down, up or both (got ''%s'').', profile_dir);
    end
    if ~isfield(PressureTimeseries, 'dPdt_smoothed')
        error('mod_L2_tile_scans:noDPdt', ['Scan direction needs PressureTimeseries.dPdt_smoothed ' ...
            '(rebuild meta/pressure_time_series.mat with the current L0 -> L1).']);
    end
    speed_lim = metadata.PROFILES.speedLim_scan_m_s;
    if ~(isnumeric(speed_lim) && isscalar(speed_lim) && speed_lim >= 0)
        error('mod_L2_tile_scans:badSpeedLim', ...
            'profile_detection.speedLim_scan_m_s must be a number >= 0 dbar/s.');
    end
    % A scan center between two pressure samples further apart than
    % ctd_gap_factor * (median sample interval) is in a gap in the pressure
    % record (mod_L1_detect_profiling_direction.m STEP 1): dPdt_smoothed
    % isn't NaN there (it's computed per segment), so the gap is checked
    % here. A record of fewer than 2 samples has no direction anywhere.
    pt_dnum = PressureTimeseries.dnum(:);
    pt_index = (1:numel(pt_dnum))';
    max_gap = metadata.PROFILES.ctd_gap_factor * median(diff(pt_dnum));
end
have_segment_id = isfield(epsi, 'segment_id') && ~isempty(epsi.segment_id);

fft_length = metadata.PROCESS.fft_length;
fft_segments_per_scan = metadata.PROCESS.fft_segments_per_scan;
Fs_epsi = metadata.PROCESS.Fs_epsi;
N_epsi = mod_scan_length_from_segments(fft_length, fft_segments_per_scan);
scan_step = round((1 - metadata.PROCESS.scan_overlap) * N_epsi);
dof = mod_scan_dof(fft_segments_per_scan);
fft_seg_starts = mod_scan_fft_seg_starts(fft_length, fft_segments_per_scan);

tiled_scans = empty_tiled_scans(fft_length, fft_segments_per_scan, dof, Fs_epsi, N_epsi, ...
    scan_step, fft_seg_starts);

if isempty(epsi) || ~isfield(epsi, 'dnum') || isempty(epsi.dnum)
    return
end

n_samples = numel(epsi.dnum);
if n_samples < N_epsi
    return % too short for even one scan
end

scan_starts = 1:scan_step:(n_samples - N_epsi + 1);
nbscan_candidate = numel(scan_starts);

idx0_all = nan(nbscan_candidate, 1);
idx1_all = nan(nbscan_candidate, 1);
dnum_all = nan(nbscan_candidate, 1);
keep = false(nbscan_candidate, 1);

% Direction of every candidate scan at once, from dPdt_smoothed at its
% center time. Deliberately no 'extrap': a center outside
% [min(PressureTimeseries.dnum), max(PressureTimeseries.dnum)] has no real
% pressure information at all (e.g. epsi logging that started hours before
% DeepSolo's pressure record begins), and neither has one inside a gap -
% both get NaN, which counts as neither down nor up, rather than being
% nearest-matched to a potentially far-distant, meaningless sample.
if have_direction_gate
    centers = epsi.dnum(scan_starts + floor(N_epsi / 2) - 1);
    centers = centers(:);
    dPdt = nan(nbscan_candidate, 1);
    if numel(pt_dnum) >= 2
        i_before = interp1(pt_dnum, pt_index, centers, 'previous');
        i_after = interp1(pt_dnum, pt_index, centers, 'next');
        ok = ~isnan(i_before) & ~isnan(i_after);
        ok(ok) = pt_dnum(i_after(ok)) - pt_dnum(i_before(ok)) <= max_gap;
        dPdt(ok) = interp1(pt_dnum, PressureTimeseries.dPdt_smoothed(:), centers(ok), 'nearest');
    end
    is_down = dPdt > speed_lim;
    is_up = dPdt < -speed_lim;
    switch profile_dir
        case 'down'
            direction_ok = is_down;
        case 'up'
            direction_ok = is_up;
        otherwise
            direction_ok = is_down | is_up;
    end
end

for iScan = 1:nbscan_candidate
    idx0 = scan_starts(iScan);
    idx1 = idx0 + N_epsi - 1;

    if have_segment_id
        seg_window = epsi.segment_id(idx0:idx1);
        if any(seg_window ~= seg_window(1))
            continue % this window straddles a real gap - see GAP HANDLING
        end
    end

    center_idx = idx0 + floor(N_epsi / 2) - 1;
    center_dnum = epsi.dnum(center_idx);

    if have_direction_gate && ~direction_ok(iScan)
        continue
    end

    idx0_all(iScan) = idx0;
    idx1_all(iScan) = idx1;
    dnum_all(iScan) = center_dnum;
    keep(iScan) = true;
end

tiled_scans.idx0 = idx0_all(keep);
tiled_scans.idx1 = idx1_all(keep);
tiled_scans.dnum = dnum_all(keep);

end %end function

%% Empty-scan-count output shape, so callers get consistent fields even
% when there are no kept scans.
function tiled_scans = empty_tiled_scans(fft_length, fft_segments_per_scan, dof, Fs_epsi, ...
    N_epsi, scan_step, fft_seg_starts)
tiled_scans.idx0 = [];
tiled_scans.idx1 = [];
tiled_scans.dnum = [];
tiled_scans.fft_seg_starts = fft_seg_starts;
tiled_scans.fft_length = fft_length;
tiled_scans.fft_segments_per_scan = fft_segments_per_scan;
tiled_scans.dof = dof;
tiled_scans.Fs_epsi = Fs_epsi;
tiled_scans.N_epsi = N_epsi;
tiled_scans.scan_step = scan_step;
end
