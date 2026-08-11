function [k, Pt_Tg_k] = mod_scan_fpo7_volts_to_Tg_spectrum(f, Pxx, w, volts_to_C, tau0, exponent, electronics_filter)
% mod_scan_fpo7_volts_to_Tg_spectrum        Part of MOD_fish_processing
%
% [k, Pt_Tg_k] = mod_scan_fpo7_volts_to_Tg_spectrum(f, Pxx, w, volts_to_C, tau0, exponent, electronics_filter)
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
%     2. Deconvolve the FP07 thermal rolloff AND the AFE's fixed
%        electronics/ADC response (sinc^4 anti-alias filter, resolved
%        once per deployment by MODsetup_define_filters.m -> see
%        electronics_filter below):
%          H_total = electronics_filter .* mod_scan_fpo7_transfer_function(f, w, tau0, exponent)
%          Pt_T_f = Pt_T_f ./ H_total
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
%   electronics_filter - (optional) AFE electronics/ADC transfer function,
%                magnitude-squared, same shape as f - normally
%                metadata.AFE.(ch).electronics_filter from
%                MODsetup_define_filters.m. Default 1 (no correction) if
%                omitted or empty, so existing callers that predate this
%                parameter (e.g. analysis/chi_tau_mle_comparison.m before
%                it was updated) keep working unchanged. This is the term
%                MOD_fish_lib's get_filters_SOM.m calls H.electFPO7 -
%                confirmed against a real Profile####.mat that omitting
%                it is why this repo's chi_obs came out systematically
%                low relative to MOD_fish_lib's (not a small correction:
%                a ~1.65x factor on top of the thermal rolloff by
%                f~62 Hz for a typical fall speed - see
%                docs/workflow/L2_calc_chi.md).
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
if nargin < 7 || isempty(electronics_filter)
    electronics_filter = 1;
end

f = f(:)';
Pxx = Pxx(:)';
electronics_filter = electronics_filter(:)';

Pt_T_f = Pxx * volts_to_C(1)^2;
H_thermal = mod_scan_fpo7_transfer_function(f, w, tau0, exponent);
H_total = electronics_filter .* H_thermal;
Pt_T_f = Pt_T_f ./ H_total;

k = f / abs(w);
Pt_Tg_k = (2*pi*k).^2 .* Pt_T_f * abs(w);

end %end function
