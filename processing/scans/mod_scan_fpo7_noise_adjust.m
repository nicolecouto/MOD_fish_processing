function adjust_spec = mod_scan_fpo7_noise_adjust(f, Pxx, noise_coefs, noise_adjusted_to_f, n_smooth_f_spectrum)
% mod_scan_fpo7_noise_adjust        Part of MOD_fish_processing
%
% adjust_spec = mod_scan_fpo7_noise_adjust(f, Pxx, noise_coefs, noise_adjusted_to_f, n_smooth_f_spectrum)
%
% DESCRIPTION
%   Scale factor that normalizes one scan's observed FP07 voltage
%   spectrum onto the bench-measured noise floor's scale (see
%   mod_scan_fpo7_bench_noise_f.m) - the two were not necessarily
%   measured under identical gain/conditions, so a direct level-for-level
%   comparison without this step would be comparing two different
%   absolute scales.
%
%   Computed as the median ratio of the (smoothed) observed spectrum to
%   the bench noise floor, over only the top noise_adjusted_to_f fraction
%   of the frequency range (close to Nyquist) - real turbulent signal has
%   long since rolled off there and what remains should be almost pure
%   instrument noise on both sides of the comparison.
%
%   Pulled out of mod_scan_fpo7_cutoff.m so this normalization has one
%   home, reusable anywhere a bench noise floor needs to be compared
%   against (or overlaid on) a real observed spectrum - e.g.
%   MODvis_spectra.m's "shifted" noise-floor checkboxes.
%
% INPUTS
%   f                    - frequency vector [Hz], already restricted to
%                           f > 0 (same convention as
%                           mod_scan_fpo7_bench_noise_f.m - log10(0) is
%                           undefined).
%   Pxx                  - observed FP07 channel power spectrum [V^2/Hz],
%                           same size as f.
%   noise_coefs          - struct with fields n0, n1, n2, n3, passed
%                           through to mod_scan_fpo7_bench_noise_f.m.
%   noise_adjusted_to_f  - fraction of f(end) (Nyquist) above which the
%                           comparison is made (e.g. 0.7).
%   n_smooth_f_spectrum  - movmean smoothing window [bins] applied to Pxx
%                           before comparing (e.g. 15).
%
% OUTPUTS
%   adjust_spec - scalar scale factor. Multiplying the bench noise floor
%                 by this value puts it on the same scale as this scan's
%                 observed spectrum.
%
% CALLED BY
%   mod_scan_fpo7_cutoff.m, MODvis_spectra.m
%
% CALLS
%   mod_scan_fpo7_bench_noise_f.m
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

noise_f = mod_scan_fpo7_bench_noise_f(f, noise_coefs);
medspec = smoothdata(Pxx, 'movmean', n_smooth_f_spectrum);
high_freq = f > noise_adjusted_to_f * f(end);
adjust_spec = median(medspec(high_freq) ./ noise_f(high_freq), 'omitmissing');

end %end function
