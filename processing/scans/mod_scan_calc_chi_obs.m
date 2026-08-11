function [chi_obs, kc] = mod_scan_calc_chi_obs(f, Pxx, w, volts_to_C, ktemp, noise_coefs, tau0, exponent, electronics_filter)
% mod_scan_calc_chi_obs        Part of MOD_fish_processing
%
% [chi_obs, kc] = mod_scan_calc_chi_obs(f, Pxx, w, volts_to_C, ktemp, noise_coefs, tau0, exponent, electronics_filter)
%
% DESCRIPTION
%   Computes chi_obs (thermal variance dissipation rate, degC^2/s) for one
%   scan of one FP07 channel, by direct wavenumber integration of the
%   observed temperature-gradient spectrum - as opposed to
%   mod_scan_calc_chi_mle.m's chi_mle, which fits the theoretical
%   Batchelor spectrum to the same data instead of integrating it directly
%   (see that function for why that's a useful second estimate, not a
%   redundant one). "_obs" was added to this function's name (and to its
%   output) specifically to keep that distinction unambiguous now that a
%   second chi estimator exists - see docs/workflow/L2_calc_chi.md.
%
%     1. f/Pxx -> deconvolved temperature-gradient wavenumber spectrum:
%          [k, Pt_Tg_k] = mod_scan_fpo7_volts_to_Tg_spectrum(f, Pxx, w, volts_to_C, tau0, exponent)
%        (this is the step that includes dividing by the FP07 thermal
%        rolloff transfer function - the deconvolution that was silently
%        dropped from MOD_fish_lib's live chi calculation on 2025-10-06,
%        see mod_scan_fpo7_transfer_function.m's NOTES - the whole
%        reason this branch exists)
%     2. Integrate from kmin = 3 cpm (a fixed low-wavenumber cutoff -
%        unchanged from MOD_fish_lib's mod_efe_scan_chi.m, not something
%        that was ever tunable there) up to kc, the noise-floor cutoff
%        from mod_scan_fpo7_cutoff.m:
%          chi_obs = 6 * ktemp * dk * sum(Pt_Tg_k(kmin <= k <= kc))
%
%   Deliberately direct-integration chi_obs only - no figure-of-merit QC
%   flag, which MOD_fish_lib's mod_efe_scan_chi.m also computes alongside
%   its chi_mle. Left out for now as a separate, later module once chi_mle
%   (mod_scan_calc_chi_mle.m) is validated against real data.
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
%                see mod_scan_fpo7_volts_to_Tg_spectrum.m)
%   ktemp      - thermal diffusivity of the water at this scan [m^2/s]
%                (mod_scan_thermal_diffusivity.m, from scan-center
%                S/T/P)
%   noise_coefs - FP07 bench noise floor struct (n0..n3), passed straight
%                through to mod_scan_fpo7_cutoff.m
%   tau0       - (optional) FP07 time-constant coefficient [s], passed
%                straight through to mod_scan_fpo7_volts_to_Tg_spectrum.m
%                / mod_scan_fpo7_transfer_function.m (default there:
%                0.005). Exposed here so a tau sensitivity comparison is
%                just calling this function twice with different values,
%                not editing code.
%   exponent   - (optional) fall-speed exponent, passed straight through
%                the same way (default there: -0.32).
%   electronics_filter - (optional) AFE electronics/ADC transfer function,
%                magnitude-squared, same shape as f - passed straight
%                through to mod_scan_fpo7_volts_to_Tg_spectrum.m (default
%                there: 1, no correction). Normally
%                metadata.AFE.(ch).electronics_filter from
%                MODsetup_define_filters.m - see that function's
%                DESCRIPTION for why this matters as much as tau0 does.
%
% OUTPUTS
%   chi_obs - thermal variance dissipation rate [degC^2/s]. NaN if the
%         noise-floor cutoff kc does not exceed kmin (no valid wavenumber
%         range to integrate over - a genuinely unusable scan for this
%         channel, not a computation error).
%   kc  - the noise-floor cutoff wavenumber used [cpm], or NaN alongside
%         a NaN chi_obs. Returned for diagnostics/QC, e.g. checking
%         whether a suspiciously small kc is dragging chi_obs down for a
%         batch of scans.
%
% CALLED BY
%   MODprocess_single_L1_to_L2.m
%
% CALLS
%   mod_scan_fpo7_volts_to_Tg_spectrum.m, mod_scan_fpo7_cutoff.m
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

if nargin < 7
    tau0 = [];
end
if nargin < 8
    exponent = [];
end
if nargin < 9
    electronics_filter = [];
end

kmin = 3; % cpm - fixed, matches MOD_fish_lib's mod_efe_scan_chi.m

f = f(:)';
Pxx = Pxx(:)';

[k, Pt_Tg_k] = mod_scan_fpo7_volts_to_Tg_spectrum(f, Pxx, w, volts_to_C, tau0, exponent, electronics_filter);

fc_index = mod_scan_fpo7_cutoff(f, Pxx, noise_coefs);
kc = k(fc_index);

if kc <= kmin
    chi_obs = NaN;
    kc = NaN;
    return
end

krange = k >= kmin & k <= kc;
dk = mean(diff(k), 'omitnan');
chi_obs = 6 * ktemp * dk * sum(Pt_Tg_k(krange), 'omitnan');

end %end function
