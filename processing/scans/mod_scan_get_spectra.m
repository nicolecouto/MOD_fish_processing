function scan = mod_scan_get_spectra(scan, metadata)
% mod_scan_get_spectra        Part of MOD_fish_processing
%
% scan = mod_scan_get_spectra(scan, metadata)
%
% DESCRIPTION
%   Computes a raw (uncorrected) power spectrum vs. frequency for every
%   channel in one scan's worth of epsi data - accelerometer channels get
%   their gravity-unit spectrum, every other channel type (shear, fpo7,
%   or anything else - e.g. a microconductivity or fluorometer probe
%   physically wired into a slot that's usually shear/fpo7, see
%   MODsetup_read_yaml.m's instrument_manifest.afe) gets its raw-volts
%   spectrum, matching MODprocess_single_L0_to_L1.m's convert_efe_channels,
%   which already applies that same acc-vs-everything-else split when
%   converting counts to physical units. Only 'acc' gets special handling
%   here; this function does not otherwise care what physical sensor a
%   channel is - channel-specific processing (calibration, chi, etc.) is
%   a separate, later step (see chi's own precedent:
%   MODprocess_L1_apply_fpo7_calibration.m, mod_scan_calc_chi_obs.m -
%   both filter to type 'fpo7' themselves, downstream of this function).
%   "Raw" because the SOM instrument transfer function isn't applied here -
%   MODprocess_L1_apply_filters.m (PLAN.md Section 6.2) isn't implemented
%   yet, so these spectra are uncorrected, and that's documented rather
%   than silently glossed over. No epsilon/chi/coherence either - this is
%   deliberately the minimal first cut (PLAN.md Section 4): spectra only.
%
%   Also computes a spectrum for whichever of ctd.P/ctd.T/ctd.C the caller
%   supplies in scan.ctd - deliberately by a DIFFERENT method than the
%   epsi channels above, not just the same Welch average at a different
%   rate. CTD samples far slower than epsi (e.g. 16 Hz SBE49 vs 320 Hz
%   epsi), so one scan's worth of ctd data is only a handful of native
%   samples (e.g. ~100 at 16 Hz over a ~6 s scan) - not enough to segment-
%   average the way epsi's fft_length/fft_segments_per_scan does. Instead:
%   a single periodogram per scan, no segments, no overlap, at ctd's own
%   native Fs_ctd - see NOTES for why this isn't upsampled onto the epsi
%   grid instead.
%
% INPUTS
%   scan     - struct with:
%                epsi - data.epsi already sliced to exactly one scan's
%                       scan_length samples, by the caller
%                       (MODprocess_single_L1_to_L2.m)
%                ctd  - (optional) data.ctd time-window-selected to this
%                       scan's span (MODprocess_single_L1_to_L2.m) - not
%                       resampled/interpolated, just whichever native ctd
%                       samples fall in the window. Absent P/T/C fields
%                       (e.g. a P-only external CTD) are simply skipped,
%                       the same way an epsi channel absent from
%                       scan.epsi is skipped below.
%   metadata - metadata struct (from MODsetup_read_yaml.m). Uses:
%                metadata.PROCESS.channels, metadata.PROCESS.fft_length (also
%                the Hamming taper length - no separate zero-padding),
%                metadata.PROCESS.fft_segments_per_scan,
%                metadata.PROCESS.Fs_epsi, metadata.PROCESS.compute_ctd_spectra
%                (gates whether metadata.PROCESS.Fs_ctd is even asked for -
%                see OUTPUTS/NOTES), metadata.AFE.(channel).type
%                (to know each channel's field suffix - '_g' for acc,
%                '_volt' for everything else - same acc-vs-everything-else
%                split MODprocess_single_L0_to_L1.m's convert_efe_channels
%                uses). The Welch-segment overlap is a hardcoded 50%
%                (see mod_scan_fft_seg_starts.m - NOTES below).
%
% OUTPUTS
%   scan - same struct, with added:
%     spectra.f    - frequency vector [Hz], 1 x nfreq, shared across every
%                    epsi channel below
%     spectra.(field)_f - power spectrum for epsi channel ch, 1 x nfreq,
%                    one field per channel in metadata.PROCESS.channels
%                    (every channel gets one, regardless of type - see
%                    DESCRIPTION) - key is the channel's raw-timeseries
%                    field name (field = [ch '_g'] for type 'acc',
%                    [ch '_volt'] for every other type) with '_f' appended
%                    to mark it frequency-domain (e.g. 's1_volt_f',
%                    't1_volt_f', 'a2_g_f', or a future 'c1_volt_f' for a
%                    microconductivity channel), matching MOD_fish_lib's
%                    Ps_volt_f/Pt_volt_f/Pa_g_f convention
%     spectra.f_ctd - frequency vector [Hz], 1 x nfreq_ctd, shared across
%                    every ctd channel below - a DIFFERENT vector from
%                    spectra.f (different rate, different method - see
%                    DESCRIPTION/NOTES). Present only if scan.ctd has at
%                    least one of P/T/C AND metadata.PROCESS.compute_ctd_spectra
%                    is true - absent entirely (no Fs_ctd asked for) whenever
%                    setup.yml declares compute_ctd_spectra false, e.g. a
%                    deployment whose CTD telemetry has no fixed, scan-
%                    duration-relative sample rate (DeepSolo), even though
%                    scan.ctd.P is populated there.
%     spectra.P_f, spectra.T_f, spectra.C_f - single-periodogram power
%                    spectrum for whichever of ctd.P/.T/.C is present and
%                    non-empty in scan.ctd, 1 x nfreq_ctd each.
%
% CALLED BY
%   MODprocess_single_L1_to_L2.m
%
% CALLS
%   MODsetup_validate_metadata.m, mod_scan_length_from_segments.m,
%   mod_scan_fft_seg_starts.m
%   (MATLAB's Signal Processing Toolbox periodogram, detrend, hamming)
%
% NOTES
%   Each epsi channel's spectrum is Welch-averaged by hand
%   (welch_psd_detrend_per_segment, local function below) instead of
%   calling pwelch directly on the whole scan: fft_length-sized segments
%   are cut from the scan at a hardcoded 50% overlap (segment start
%   offsets from mod_scan_fft_seg_starts.m), but each segment is detrended
%   individually, before its own Hamming window/FFT, then the per-segment
%   periodograms are averaged - matching both the onboard SOM processing
%   and Rockland ODAS's clean_shear_spec.m/csd_matrix_odas (method=
%   'linear', n_fft/2 overlap), which detrend every segment before
%   averaging, rather than detrending the whole scan once up front. A
%   single whole-scan detrend removes only one linear trend across the
%   entire scan and leaves any trend local to one segment (e.g. probe
%   drift within a single fft block) uncorrected in every segment but one
%   - the same mismatch San identified between APEX's onboard vs.
%   post-processed spectra, and the exact reason Rockland's csd_odas.m
%   gives for not using MATLAB's pwelch/cpsd at all ("their new methods
%   do not support the linear detrending of each segment before calling
%   the fft... which can leave undesirable low-frequency artifacts").
%   Segment count matches Rockland's own num_of_ffts formula
%   (get_diss_odas.m) and feeds processing/scans/mod_scan_dof.m's dof calculation
%   (1.9*fft_segments_per_scan, Nuttall 1971) - see mod_L2_tile_scans.m and
%   mod_scan_calc_chi_mle.m for where that dof is actually used. The 1.9
%   factor is only valid at exactly 50% overlap, which is why overlap is
%   hardcoded rather than exposed as a tunable fraction - see
%   docs/concepts/spectral_windowing.md. This differs from the old
%   MOD_fish_lib mod_efe_scan_acceleration.m's single-periodogram-per-scan
%   spectra by design - see PLAN.md's session log for why. Minus the
%   h_freq transfer-function division and fc1/fc2 band integration that
%   function also did - both need calibration/filter machinery this repo
%   doesn't have yet.
%
%   ctd spectra are NOT computed the same way, on purpose. Two options
%   were considered and rejected: (1) interpolating ctd.P/T/C onto the
%   epsi grid so the same Welch machinery applies - rejected because no
%   interpolation method can put real spectral content above ctd's own
%   Nyquist (e.g. 8 Hz for a 16 Hz SBE49) into the series; anything above
%   that in the resulting spectrum would be a pure interpolation artifact,
%   not ocean signal. (2) downsampling epsi to ctd's rate - rejected
%   because it would defeat the entire purpose of epsi's high sample rate
%   for the epsi channels themselves. Instead, ctd channels get a single
%   periodogram from whichever native-rate samples actually fall in the
%   scan's time window (see docs/concepts/spectral_windowing.md's "CTD
%   spectra" section) - genuinely different dof/overlap properties than
%   the epsi spectra above, not just "the same thing at a different rate."
%   nfft is fixed per deployment (N_ctd, derived from the scan's known
%   duration and Fs_ctd, not from how many raw samples actually landed in
%   this particular scan) so every scan's ctd frequency vector matches,
%   which matters once a caller stacks P_f/T_f/C_f across scans.
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

yaml_file = '';
if isfield(metadata, 'paths') && isfield(metadata.paths, 'setup_yml')
    yaml_file = metadata.paths.setup_yml;
end
metadata = MODsetup_validate_metadata(metadata, yaml_file, ...
    {'fft_length', 'fft_segments_per_scan', 'Fs_epsi'});

fft_length = metadata.PROCESS.fft_length;
fft_segments_per_scan = metadata.PROCESS.fft_segments_per_scan;
Fs_epsi = metadata.PROCESS.Fs_epsi;
fft_seg_starts = mod_scan_fft_seg_starts(fft_length, fft_segments_per_scan);

scan.spectra = struct();
f = [];
for iC = 1:numel(metadata.PROCESS.channels)
    ch = metadata.PROCESS.channels{iC};
    switch lower(metadata.AFE.(ch).type)
        case 'acc'
            field = [ch '_g'];
        otherwise
            % Every non-acc channel defaults to the raw-volts field name -
            % matches MODprocess_single_L0_to_L1.m's convert_efe_channels,
            % which already converts any non-acc channel to volts
            % regardless of type. This makes a channel type this repo
            % doesn't have dedicated processing for yet (e.g.
            % microconductivity, fluorometer - a probe physically wired
            % into a slot that's usually shear/fpo7) still get a raw
            % spectrum computed, rather than being silently dropped -
            % channel-specific processing (calibration, chi, etc.) is
            % added as its own dedicated step later, the same precedent
            % set for fpo7 (MODprocess_L1_apply_fpo7_calibration.m,
            % mod_scan_calc_chi_obs.m).
            field = [ch '_volt'];
    end

    if ~isfield(scan.epsi, field)
        continue
    end

    [Pxx, f] = welch_psd_detrend_per_segment(scan.epsi.(field), fft_length, fft_seg_starts, Fs_epsi);
    scan.spectra.([field '_f']) = Pxx(:)';
end

scan.spectra.f = f(:)';

%% ctd.P/T/C: single periodogram at native Fs_ctd - see NOTES above
% compute_ctd_spectra is an explicit per-deployment setup.yml flag (not
% inferred from vehicle_name/fish_flag - see
% MODsetup_metadata_field_registry.m's compute_ctd_spectra entry), only
% ever asked for when there's actual ctd data on this scan to consider.
% False for a deployment whose CTD telemetry has no fixed, scan-duration-
% relative sample rate (e.g. DeepSolo's sparse ~60-120s external pressure
% telemetry - a scan window there holds 0-1 native samples, not "a
% handful," so Fs_ctd/N_ctd would have no meaning) - Fs_ctd is then never
% even asked for, rather than prompting/erroring for a value that
% wouldn't be usable anyway.
if isfield(scan, 'ctd') && ~isempty(scan.ctd)
    metadata = MODsetup_validate_metadata(metadata, yaml_file, {'compute_ctd_spectra'});
    if metadata.PROCESS.compute_ctd_spectra
        metadata = MODsetup_validate_metadata(metadata, yaml_file, {'Fs_ctd'});
        Fs_ctd = metadata.PROCESS.Fs_ctd;
        N_epsi = mod_scan_length_from_segments(fft_length, fft_segments_per_scan);
        N_ctd = round(N_epsi / Fs_epsi * Fs_ctd);

        f_ctd = [];
        ctd_channels = {'P', 'T', 'C'};
        for iC = 1:numel(ctd_channels)
            ch = ctd_channels{iC};
            if ~isfield(scan.ctd, ch) || isempty(scan.ctd.(ch))
                continue
            end
            [Pxx, f_ctd] = periodogram(detrend(scan.ctd.(ch)(:)), [], N_ctd, Fs_ctd, 'psd');
            scan.spectra.([ch '_f']) = Pxx(:)';
        end
        if ~isempty(f_ctd)
            scan.spectra.f_ctd = f_ctd(:)';
        end
    end
end

end %end function

%% Welch-average periodograms of overlapping segments, each individually
% detrended before its own Hamming window/FFT - see NOTES above for why
% this isn't just pwelch(detrend(x), fft_length, [], fft_length, Fs, 'psd').
% seg_starts (mod_scan_fft_seg_starts.m) fixes both the segment count and
% their positions - a scan built to mod_scan_length_from_segments.m's
% scan_length always has exactly numel(seg_starts) segments with no
% leftover samples.
function [Pxx, f] = welch_psd_detrend_per_segment(x, fft_length, seg_starts, Fs)
window = hamming(fft_length);
nseg = numel(seg_starts);

Pxx = [];
for iSeg = 1:nseg
    idx0 = seg_starts(iSeg);
    seg = detrend(x(idx0:idx0 + fft_length - 1));
    [Pseg, f] = periodogram(seg, window, fft_length, Fs, 'psd');
    if isempty(Pxx)
        Pxx = Pseg;
    else
        Pxx = Pxx + Pseg;
    end
end
Pxx = Pxx / nseg;
end
