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
% INPUTS
%   scan     - struct with:
%                epsi - data.epsi already sliced to exactly one scan's
%                       scan_length samples, by the caller
%                       (MODprocess_single_L1_to_L2.m, mod_L2_tile_scans.m)
%   metadata - metadata struct (from MODsetup_read_yaml.m). Uses:
%                metadata.PROCESS.channels, metadata.PROCESS.fft_length (also
%                the Hamming taper length - no separate zero-padding),
%                metadata.PROCESS.Fs_epsi, metadata.AFE.(channel).type
%                (to know each channel's field suffix - '_g' for acc,
%                '_volt' for everything else - same acc-vs-everything-else
%                split MODprocess_single_L0_to_L1.m's convert_efe_channels
%                uses). The Welch-segment overlap is a hardcoded 50%
%                (FFT_OVERLAP constant below, not a metadata field - see
%                NOTES). fft_length validated via MODsetup_validate_metadata.m
%                below - prompted for (and offered to be saved into
%                setup.yml) if not already in metadata; see
%                MODsetup_metadata_field_registry.m for its historical
%                default. Fs_epsi/channels are NOT yet validated the same
%                way (deferred follow-up - see PLAN.md) - still read
%                unconditionally, so a deployment whose setup.yml omits
%                afe.sample_rate will hit a plain "field not found" error
%                here instead of a helpful prompt.
%
% OUTPUTS
%   scan - same struct, with added:
%     spectra.f    - frequency vector [Hz], 1 x nfreq, shared across every
%                    channel below
%     spectra.(field)_f - power spectrum for channel ch, 1 x nfreq, one
%                    field per channel in metadata.PROCESS.channels (every
%                    channel gets one, regardless of type - see
%                    DESCRIPTION) - key is the channel's raw-timeseries
%                    field name (field = [ch '_g'] for type 'acc',
%                    [ch '_volt'] for every other type) with '_f' appended
%                    to mark it frequency-domain (e.g. 's1_volt_f',
%                    't1_volt_f', 'a2_g_f', or a future 'c1_volt_f' for a
%                    microconductivity channel), matching MOD_fish_lib's
%                    Ps_volt_f/Pt_volt_f/Pa_g_f convention
%
% CALLED BY
%   MODprocess_single_L1_to_L2.m
%
% CALLS
%   MODsetup_validate_metadata.m
%   (MATLAB's Signal Processing Toolbox periodogram, detrend, hamming)
%
% NOTES
%   Each channel's spectrum is Welch-averaged by hand (welch_psd_detrend_
%   per_segment, local function below) instead of calling pwelch directly
%   on the whole scan: fft_length-sized segments are cut from the scan at
%   a hardcoded 50% overlap, but each segment is detrended
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
%   (get_diss_odas.m) and feeds toolbox/mod_scan_dof.m's dof calculation
%   (1.9*fft_segments_per_scan, Nuttall 1971) - see mod_L2_tile_scans.m and
%   mod_scan_calc_chi_mle.m for where that dof is actually used. The 1.9
%   factor is only valid at exactly 50% overlap, which is why overlap is
%   hardcoded (FFT_OVERLAP below) rather than exposed as a tunable
%   fraction - see docs/concepts/spectral_windowing.md. This differs from
%   the old MOD_fish_lib mod_efe_scan_acceleration.m's single-periodogram-
%   per-scan spectra by design - see PLAN.md's session log for why. Minus
%   the h_freq transfer-function division and fc1/fc2 band integration
%   that function also did - both need calibration/filter machinery this
%   repo doesn't have yet.
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

yaml_file = '';
if isfield(metadata, 'paths') && isfield(metadata.paths, 'setup_yml')
    yaml_file = metadata.paths.setup_yml;
end
metadata = MODsetup_validate_metadata(metadata, yaml_file, {'fft_length', 'Fs_epsi'});

fft_length = metadata.PROCESS.fft_length;
Fs_epsi = metadata.PROCESS.Fs_epsi;
FFT_OVERLAP = 0.5; % hardcoded - the 1.9 Nuttall dof factor (mod_scan_dof.m) is only valid here

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

    [Pxx, f] = welch_psd_detrend_per_segment(scan.epsi.(field), fft_length, FFT_OVERLAP, Fs_epsi);
    scan.spectra.([field '_f']) = Pxx(:)';
end

scan.spectra.f = f(:)';

end %end function

%% Welch-average periodograms of overlapping segments, each individually
% detrended before its own Hamming window/FFT - see NOTES above for why
% this isn't just pwelch(detrend(x), fft_length, [], fft_length, Fs, 'psd'). Segment
% count matches Rockland ODAS's get_diss_odas.m num_of_ffts formula for
% the same fft_length/overlap - only the per-segment detrend is an addition
% pwelch itself can't do.
function [Pxx, f] = welch_psd_detrend_per_segment(x, fft_length, fft_overlap, Fs)
window = hamming(fft_length);
noverlap = round(fft_overlap * fft_length);
step = fft_length - noverlap;
nseg = floor((numel(x) - noverlap) / step);

Pxx = [];
for iSeg = 1:nseg
    idx0 = (iSeg - 1) * step + 1;
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
