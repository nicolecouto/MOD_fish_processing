function scan = mod_scan_get_spectra(scan, metadata)
% mod_scan_get_spectra        Part of MOD_fish_processing
%
% scan = mod_scan_get_spectra(scan, metadata)
%
% DESCRIPTION
%   Computes a raw (uncorrected) power spectrum vs. frequency for every
%   shear/fpo7/accelerometer channel in one scan's worth of epsi data.
%   "Raw" because the SOM instrument transfer function isn't applied here -
%   MODprocess_L1_apply_filters.m (PLAN.md Section 6.2) isn't implemented
%   yet, so these spectra are uncorrected, and that's documented rather
%   than silently glossed over. No epsilon/chi/coherence either - this is
%   deliberately the minimal first cut (PLAN.md Section 4): spectra only.
%
% INPUTS
%   scan     - struct with:
%                epsi - data.epsi already sliced to exactly one scan's
%                       N_epsi samples (N_epsi = (dof-1)*nfft), by the
%                       caller (MODprocess_single_L1_to_L2.m)
%   metadata - metadata struct (from MODsetup_read_yaml.m). Uses:
%                metadata.PROCESS.channels, metadata.PROCESS.nfft,
%                metadata.PROCESS.Fs_epsi, metadata.AFE.(channel).type
%                (to know each channel's field suffix - '_volt' for
%                shear/fpo7, '_g' for acc, same branch
%                MODprocess_single_L0_to_L1.m's convert_efe_channels uses),
%                metadata.PROCESS.CHI.hamming_window_length_nfft (optional -
%                pwelch's Hamming window length, as a fraction of nfft;
%                default 1, i.e. window length = nfft, if
%                metadata.PROCESS.CHI is absent or the field is missing -
%                this function's historical hardcoded window length)
%
% OUTPUTS
%   scan - same struct, with added:
%     spectra.f    - frequency vector [Hz], 1 x nfreq, shared across every
%                    channel below
%     spectra.(field)_f - power spectrum for channel ch, 1 x nfreq, one
%                    field per channel in metadata.PROCESS.channels whose
%                    type is shear/fpo7/acc - key is the channel's
%                    raw-timeseries field name (field = [ch '_volt'] or
%                    [ch '_g']) with '_f' appended to mark it
%                    frequency-domain (e.g. 's1_volt_f', 't1_volt_f',
%                    'a2_g_f'), matching MOD_fish_lib's
%                    Ps_volt_f/Pt_volt_f/Pa_g_f convention
%
% CALLED BY
%   MODprocess_single_L1_to_L2.m
%
% CALLS
%   (none - uses MATLAB's Signal Processing Toolbox pwelch, detrend)
%
% NOTES
%   pwelch call shape (`pwelch(detrend(x), window_length, [], nfft, Fs_epsi, 'psd')`,
%   window_length = hamming_window_length_nfft*nfft, default window_length
%   = nfft) matches the old MOD_fish_lib mod_efe_scan_acceleration.m
%   exactly at the default ratio, minus the h_freq transfer-function
%   division and fc1/fc2 band integration that
%   function also did - both need calibration/filter machinery this repo
%   doesn't have yet.
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

nfft = metadata.PROCESS.nfft;
Fs_epsi = metadata.PROCESS.Fs_epsi;

hamming_window_length_nfft = 1;
if isfield(metadata.PROCESS, 'CHI') && isfield(metadata.PROCESS.CHI, 'hamming_window_length_nfft')
    hamming_window_length_nfft = metadata.PROCESS.CHI.hamming_window_length_nfft;
end
window_length = round(hamming_window_length_nfft * nfft);

scan.spectra = struct();
f = [];
for iC = 1:numel(metadata.PROCESS.channels)
    ch = metadata.PROCESS.channels{iC};
    switch lower(metadata.AFE.(ch).type)
        case 'acc'
            field = [ch '_g'];
        case {'shear', 'fpo7'}
            field = [ch '_volt'];
        otherwise
            continue
    end

    if ~isfield(scan.epsi, field)
        continue
    end

    [Pxx, f] = pwelch(detrend(scan.epsi.(field)), window_length, [], nfft, Fs_epsi, 'psd');
    scan.spectra.([field '_f']) = Pxx(:)';
end

scan.spectra.f = f(:)';

end %end function
