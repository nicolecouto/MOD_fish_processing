function [k, Pt_Tg_k] = mod_scan_fpo7_volts_to_Tg_spectrum(f, Pxx, w, volts_to_C, tau0, exponent)
% mod_scan_fpo7_volts_to_Tg_spectrum        Part of MOD_fish_processing
%
% [k, Pt_Tg_k] = mod_scan_fpo7_volts_to_Tg_spectrum(f, Pxx, w, volts_to_C, tau0, exponent)
%
% DESCRIPTION
%   Converts one scan's raw FP07 channel voltage power spectrum into a
%   deconvolved temperature-gradient wavenumber spectrum - the shared
%   first stage both mod_scan_calc_chi_obs.m (direct wavenumber
%   integration) and mod_scan_calc_chi_mle.m (Batchelor-spectrum MLE
%   fit) need before they diverge on what to do with it:
%
%     1. Pxx (raw volts^2/Hz) -> temperature frequency spectrum:
%          Pt_T_f = Pxx * volts_to_C(1)^2
%        (volts_to_C(1) is the linear calibration's slope, degC/volt -
%        see MODprocess_L1_apply_fpo7_calibration.m. Squaring the slope
%        and multiplying is equivalent to re-computing the spectrum from
%        the calibrated-to-degC timeseries directly, since pwelch detrends
%        its input and detrend(a*x+b) = a*detrend(x) - no second pwelch
%        call needed.)
%     2. Deconvolve the FP07 thermal rolloff:
%          Pt_T_f = Pt_T_f ./ mod_scan_fpo7_transfer_function(f, w, tau0, exponent)
%     3. Convert to a temperature-gradient wavenumber spectrum:
%          k = f / abs(w)
%          Pt_Tg_k = (2*pi*k).^2 .* Pt_T_f .* abs(w)
%
%   Split out of what was originally one monolithic MODprocess_L2_calc_chi.m
%   (chi_obs's direct-integration steps) once mod_scan_calc_chi_mle.m
%   needed to start from the exact same deconvolved spectrum - keeping this
%   conversion in one place means a tau sensitivity comparison (tau0/
%   exponent overrides) automatically applies identically to both chi_obs
%   and chi_mle, rather than risking the two drifting out of sync.
%
% INPUTS
%   f          - frequency vector [Hz], nfreq x 1 or 1 x nfreq (same shape
%                as Pxx)
%   Pxx        - one scan's raw FP07 channel power spectrum [V^2/Hz],
%                same shape as f (e.g. from mod_scan_get_spectra.m)
%   w          - fall speed at this scan's center [m/s], scalar. Sign
%                does not matter (abs'd internally) - see
%                mod_scan_fpo7_transfer_function.m for why w=0 is not
%                a meaningful input here.
%   volts_to_C - [slope, intercept] from
%                metadata.AFE.(channel).volts_to_C (only slope is used -
%                see step 1 above)
%   tau0       - (optional) FP07 time-constant coefficient [s], passed
%                straight through to mod_scan_fpo7_transfer_function.m
%                (default there: 0.005). Exposed here, not hardcoded, so a
%                tau sensitivity comparison is just calling this function
%                twice.
%   exponent   - (optional) fall-speed exponent, passed straight through
%                to mod_scan_fpo7_transfer_function.m (default there:
%                -0.32).
%
% OUTPUTS
%   k       - wavenumber vector [cpm], same shape as f, k = f / abs(w)
%   Pt_Tg_k - deconvolved temperature-gradient wavenumber spectrum, same
%             shape as k
%
% CALLED BY
%   mod_scan_calc_chi_obs.m, mod_scan_calc_chi_mle.m
%
% CALLS
%   mod_scan_fpo7_transfer_function.m
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

if nargin < 5
    tau0 = [];
end
if nargin < 6
    exponent = [];
end

f = f(:)';
Pxx = Pxx(:)';

Pt_T_f = Pxx * volts_to_C(1)^2;
H = mod_scan_fpo7_transfer_function(f, w, tau0, exponent);
Pt_T_f = Pt_T_f ./ H;

k = f / abs(w);
Pt_Tg_k = (2*pi*k).^2 .* Pt_T_f * abs(w);

end %end function
