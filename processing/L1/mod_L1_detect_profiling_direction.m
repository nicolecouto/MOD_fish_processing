function PressureTimeseries = mod_L1_detect_profiling_direction(PressureTimeseries, metadata)
% mod_L1_detect_profiling_direction        Part of MOD_fish_processing
%
% PressureTimeseries = mod_L1_detect_profiling_direction(PressureTimeseries, metadata)
%
% DESCRIPTION
%   Smooths a deployment-length pressure timeseries (from
%   MODprocess_L1_make_pressure_timeseries.m) and computes its rate of
%   change, dPdt_smoothed, plus is_down (dPdt > 0, buffered). This is a
%   rough "going down or up" for realtime processing, not a profile picker
%   (that's modProcess_detect_profiles.m, with its own speed limits):
%   mod_L2_tile_scans.m keeps a scan as down or up from dPdt_smoothed and
%   speedLim_scan_m_s, and MODprocess_L1_apply_fpo7_calibration.m fits on
%   is_down samples. This is deliberately an L1-level function, not L2 -
%   it operates purely on the pressure record, the same data level as
%   ctd.dPdt itself, and its output (meta/pressure_time_series.mat) is small
%   enough that any single-L1-file L2 call can just load it, rather than L2
%   needing to recompute direction from the whole deployment itself.
%
%   Written to be read, not just run - the four steps below are the actual
%   algorithm, in order, each with the reasoning for why it's built this
%   way.
%
% INPUTS
%   PressureTimeseries - struct with dnum, P (from
%                         MODprocess_L1_make_pressure_timeseries.m)
%   metadata - metadata struct (from MODsetup_read_yaml.m). Uses:
%     metadata.PROFILES.lowpass_sec - default 1. Lowpass cutoff period
%         [s]; the sample rate sets how many samples that is - see STEP 2.
%         Larger = more smoothing.
%     metadata.PROFILES.ctd_gap_factor - default 5. A gap between
%         consecutive samples wider than ctd_gap_factor * (whole-record
%         median sample interval) splits the record into independent
%         segments - see STEP 1. Named ctd_gap_factor (not gap_factor) to
%         pair with metadata.PROCESS.epsi_gap_factor
%         (modProcess_extract_profile.m) - the two operate on different
%         timebases (sparse/irregular ctd vs. uniformly clocked epsi) with
%         different consequences, so they are deliberately separate,
%         symmetrically-named fields rather than one shared threshold.
%     metadata.PROFILES.buffer_bins - default 1. Number of raw pressure
%         *samples* (not epsi scans) to pad onto each end of every
%         detected descending run, so real descent time isn't clipped by
%         the coarse sample spacing - see STEP 4.
%
% OUTPUTS
%   PressureTimeseries - same struct, with two fields added:
%     dPdt_smoothed - smoothed pressure rate of change [dbar/s], one value
%                     per input sample. NaN where the point falls inside a
%                     too-short segment to filter (see STEP 2) or was
%                     forced excluded (see STEP 1).
%     is_down       - logical, one value per input sample. true where this
%                     sample is classified as (or buffered next to)
%                     descending. MODprocess_L1_apply_fpo7_calibration.m
%                     fits on these samples; mod_L2_tile_scans.m uses
%                     dPdt_smoothed instead (with speedLim_scan_m_s).
%
% CALLED BY
%   MODprocess_all_L0_to_L1.m
%
% CALLS
%   (none - uses MATLAB's Signal Processing Toolbox cheby2/filtfilt)
%
% NOTES
%   Ported in spirit from
%   MOD_fish_lib/EPSILOMETER/epsilib/epsiProcess_get_profiles_from_PressureTimeseries.m's
%   cheby2 + filtfilt lowpass with a cutoff period in seconds (4 s there,
%   lowpass_sec here). A record too sparse for that cutoff to be a real
%   filter (e.g. DeepSolo's fallrise data, 60-120 s/sample) is used
%   unsmoothed - see STEP 2.
%
%   This function does not build actual profile objects (start/end indices,
%   merging adjacent same-direction casts, minimum-length filtering, etc.)
%   the way the old profile-picker does - it only classifies direction
%   per-sample. A full profile-picker (modProcess_detect_profiles.m,
%   PLAN.md Section 6.3) is separate, later work.
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

yaml_file = '';
if isfield(metadata, 'paths') && isfield(metadata.paths, 'setup_yml')
    yaml_file = metadata.paths.setup_yml;
end
metadata = MODsetup_validate_metadata(metadata, yaml_file, {'lowpass_sec', 'ctd_gap_factor', 'buffer_bins'});
lowpass_sec = metadata.PROFILES.lowpass_sec;
ctd_gap_factor = metadata.PROFILES.ctd_gap_factor;
buffer_bins = metadata.PROFILES.buffer_bins;
if ~(isnumeric(lowpass_sec) && isscalar(lowpass_sec) && lowpass_sec > 0)
    error('mod_L1_detect_profiling_direction:invalidLowpassSec', ...
        'metadata.PROFILES.lowpass_sec must be one number > 0 s (got %s).', mat2str(lowpass_sec));
end

dnum = PressureTimeseries.dnum(:);
P    = PressureTimeseries.P(:);
n = numel(dnum);

dPdt_smoothed = nan(n, 1);
is_down = false(n, 1);

if n < 2
    PressureTimeseries.dPdt_smoothed = dPdt_smoothed;
    PressureTimeseries.is_down = is_down;
    return
end

%% STEP 1 - Split into gap-free segments first, before any smoothing.
% dt(i) is the time from sample i to sample i+1. A gap wider than
% ctd_gap_factor * (whole-record median dt) - e.g. the ~9982 s (2.77 h) gap
% seen in real DeepSolo fallrise data against a ~60-120 s median - almost
% certainly spans an unrelated stretch of the deployment (comms dropout,
% instrument surfaced and stopped logging, etc.). Diffing or filtering
% straight across it would produce a "dPdt" that isn't a real velocity, so
% each gap becomes a hard boundary: samples get grouped into independent
% segments, and the two samples flanking a gap are always excluded
% (is_down stays false) since there is no reliable local rate at the gap
% edge itself.
dt = diff(dnum) * 86400; % seconds
whole_record_median_dt = median(dt);
gap_after = dt > ctd_gap_factor * whole_record_median_dt;

seg_starts = [1; find(gap_after) + 1];
seg_ends   = [find(gap_after); n];

for iSeg = 1:numel(seg_starts)
    i0 = seg_starts(iSeg);
    i1 = seg_ends(iSeg);
    seg_n = i1 - i0 + 1;

    if seg_n < 2
        continue % lone sample between two gaps - nothing to diff
    end

    seg_dnum = dnum(i0:i1);
    seg_P    = P(i0:i1);
    seg_dt   = diff(seg_dnum) * 86400;
    seg_median_dt = median(seg_dt);

    %% STEP 2 - Cheby2 lowpass with a cutoff period of lowpass_sec.
    % The normalized cutoff passed to cheby2 (1.0 = Nyquist) is
    %   Fc = (1/lowpass_sec) / (Fs/2) = 2 * seg_median_dt / lowpass_sec,
    % so the sample rate sets how many samples the cutoff spans (16 for
    % lowpass_sec = 1 at 16 Hz). Fc >= 1 means lowpass_sec is two samples
    % or less - nothing to filter - so the pressure is used as it is (also
    % for Fc = 0, a segment whose median interval is 0 from repeated
    % times).
    %
    % filtfilt (zero-phase) needs a minimum segment length to pad the
    % edges - roughly 3x the filter order. A cheby2 order-3 filter needs
    % this segment to have at least ~13 samples; shorter segments (e.g. a
    % short stretch trapped between two gaps) also use the raw pressure -
    % still a usable (if noisier) dPdt sign, rather than erroring or
    % silently skipping real data.
    Fc = 2 * seg_median_dt / lowpass_sec;
    min_len_for_filter = 13;
    if Fc > 0 && Fc < 1 && seg_n >= min_len_for_filter
        [b, a] = cheby2(3, 20, Fc, 'low');
        seg_P_smooth = filtfilt(b, a, fillmissing(seg_P, 'linear'));
    else
        seg_P_smooth = seg_P;
    end

    %% STEP 3 - dPdt from the smoothed pressure, same "compute at
    % midpoints then interpolate back to the sample grid" approach as the
    % old profile-picker, so dPdt_smoothed has one value per input sample
    % rather than per sample-pair.
    dPdt_mid = diff(seg_P_smooth) ./ seg_dt;
    seg_dPdt = interp1(linspace(0, 1, seg_n - 1), dPdt_mid, linspace(0, 1, seg_n), 'linear')';

    %% STEP 4 - Classify, then buffer around the edges of each descending
    % run. Buffering happens in raw-pressure-sample units, not epsi-scan
    % units: this pressure record is sparse (each sample can be 60-120 s
    % apart), so padding a down-run by a couple of these coarse samples is
    % the meaningful way to "make sure we get it all" near a turnaround -
    % padding by epsi-scan-sized units (a few seconds) would be far too
    % small relative to the actual uncertainty in exactly when the
    % turnaround happened between two sparse pressure fixes. Buffering is
    % done within this segment only (never dilating across a gap into an
    % unrelated stretch of the deployment).
    seg_is_down = seg_dPdt > 0;
    if buffer_bins > 0 && any(seg_is_down)
        window = 2 * buffer_bins + 1;
        seg_is_down = movmax(double(seg_is_down), window) > 0;
    end

    dPdt_smoothed(i0:i1) = seg_dPdt;
    is_down(i0:i1) = seg_is_down;
end

% Gap-flanking samples are always excluded, regardless of what STEP 4
% computed for them locally (see STEP 1).
gap_idx = find(gap_after);
is_down(gap_idx) = false;
is_down(gap_idx + 1) = false;

PressureTimeseries.dPdt_smoothed = dPdt_smoothed;
PressureTimeseries.is_down = is_down;

end %end function
