function [Pxx, f] = mod_scan_welch_psd(x, fft_length, seg_starts, Fs, taper, detrend_type)
% mod_scan_welch_psd        Part of MOD_fish_processing
%
% [Pxx, f] = mod_scan_welch_psd(x, fft_length, seg_starts, Fs, taper, detrend_type)
%
% DESCRIPTION
%   Welch-averaged one-sided power spectral density, with each segment
%   detrended individually before its own taper/FFT, then the per-segment
%   periodograms averaged. MATLAB's pwelch can't detrend per segment,
%   which is why this is done by hand - see mod_scan_get_spectra.m's NOTES
%   for the full rationale (onboard SOM processing and Rockland ODAS do
%   the same).
%
% INPUTS
%   x            - numeric vector, one channel's samples
%   fft_length   - segment length [samples], also the taper length (no
%                  zero-padding)
%   seg_starts   - 1-based start index of each segment in x (e.g. from
%                  mod_scan_fft_seg_starts.m); every segment must fit in x
%   Fs           - sample rate [Hz]
%   taper        - (optional) 'hamming' (default) or 'hann'
%   detrend_type - (optional) per-segment detrend: 'linear' (default),
%                  'constant' (remove the mean), or 'none'
%
% OUTPUTS
%   Pxx - PSD [x units^2/Hz], column, fft_length/2+1 bins
%   f   - frequency [Hz], column
%
% CALLED BY
%   mod_scan_get_spectra.m (hamming, linear), MODvis_spectra_L0.m
%
% CALLS
%   (MATLAB's Signal Processing Toolbox periodogram, detrend, hamming, hann)
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

if nargin < 5 || isempty(taper)
    taper = 'hamming';
end
if nargin < 6 || isempty(detrend_type)
    detrend_type = 'linear';
end

switch lower(taper)
    case 'hamming'
        window = hamming(fft_length);
    case 'hann'
        window = hann(fft_length);
    otherwise
        error('mod_scan_welch_psd:unknownTaper', 'Unknown taper "%s" - use hamming or hann.', taper);
end

nseg = numel(seg_starts);
Pxx = [];
f = [];
for iSeg = 1:nseg
    idx0 = seg_starts(iSeg);
    seg = x(idx0:idx0 + fft_length - 1);
    seg = seg(:);
    switch lower(detrend_type)
        case 'linear'
            seg = detrend(seg);
        case 'constant'
            seg = seg - mean(seg);
        case 'none'
        otherwise
            error('mod_scan_welch_psd:unknownDetrend', ...
                'Unknown detrend "%s" - use linear, constant or none.', detrend_type);
    end
    [Pseg, f] = periodogram(seg, window, fft_length, Fs, 'psd');
    if isempty(Pxx)
        Pxx = Pseg;
    else
        Pxx = Pxx + Pseg;
    end
end
Pxx = Pxx / nseg;

end %end function
