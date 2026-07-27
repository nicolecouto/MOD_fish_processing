function [chi, kc] = MODprocess_L2_calc_chi(f, Pxx, w, volts_to_C, ktemp, noise_coefs)
% MODprocess_L2_calc_chi        Part of MOD_fish_processing
%
% [chi, kc] = MODprocess_L2_calc_chi(f, Pxx, w, volts_to_C, ktemp, noise_coefs)
%
% DESCRIPTION
%   Computes chi (thermal variance dissipation rate, degC^2/s) for one
%   scan of one FP07 channel, by direct wavenumber integration of the
%   temperature-gradient spectrum:
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
%          Pt_T_f = Pt_T_f ./ MODprocess_L2_fpo7_transfer_function(f, w)
%        This is the step that was silently dropped from MOD_fish_lib's
%        live chi calculation on 2025-10-06 (see
%        MODprocess_L2_fpo7_transfer_function.m's NOTES) - the whole
%        reason this branch exists.
%     3. Convert to a temperature-gradient wavenumber spectrum:
%          k = f / abs(w)
%          Pt_Tg_k = (2*pi*k).^2 .* Pt_T_f .* abs(w)
%     4. Integrate from kmin = 3 cpm (a fixed low-wavenumber cutoff -
%        unchanged from MOD_fish_lib's mod_efe_scan_chi.m, not something
%        that was ever tunable there) up to kc, the noise-floor cutoff
%        from MODprocess_L2_fpo7_cutoff.m:
%          chi = 6 * ktemp * dk * sum(Pt_Tg_k(kmin <= k <= kc))
%
%   Deliberately direct-integration chi only - no Batchelor spectrum MLE
%   fit (chi_mle) and no figure-of-merit QC flag, both of which
%   MOD_fish_lib's mod_efe_scan_chi.m also computes. Left out for now as a
%   separate, later module once this simpler version is validated against
%   real data (see PLAN.md chi_processing branch notes) - deliberately
%   scoped small so a tau sensitivity comparison (this whole exercise's
%   actual goal) is a clean, auditable calculation, not entangled with a
%   second, more complex statistical fit.
%
% INPUTS
%   f          - frequency vector [Hz], nfreq x 1 or 1 x nfreq (same shape
%                as Pxx)
%   Pxx        - one scan's raw FP07 channel power spectrum [V^2/Hz],
%                same shape as f (e.g. from MODprocess_L2_get_scan_spectra.m)
%   w          - fall speed at this scan's center [m/s], scalar. Sign
%                does not matter (abs'd internally) - see
%                MODprocess_L2_fpo7_transfer_function.m for why w=0 is not
%                a meaningful input here.
%   volts_to_C - [slope, intercept] from
%                metadata.AFE.(channel).volts_to_C (only slope is used -
%                see step 1 above)
%   ktemp      - thermal diffusivity of the water at this scan [m^2/s]
%                (MODprocess_L2_thermal_diffusivity.m, from scan-center
%                S/T/P)
%   noise_coefs - FP07 bench noise floor struct (n0..n3), passed straight
%                through to MODprocess_L2_fpo7_cutoff.m
%
% OUTPUTS
%   chi - thermal variance dissipation rate [degC^2/s]. NaN if the
%         noise-floor cutoff kc does not exceed kmin (no valid wavenumber
%         range to integrate over - a genuinely unusable scan for this
%         channel, not a computation error).
%   kc  - the noise-floor cutoff wavenumber used [cpm], or NaN alongside
%         a NaN chi. Returned for diagnostics/QC, e.g. checking whether a
%         suspiciously small kc is dragging chi down for a batch of scans.
%
% CALLED BY
%   MODprocess_single_L1_to_L2.m
%
% CALLS
%   MODprocess_L2_fpo7_transfer_function.m, MODprocess_L2_fpo7_cutoff.m
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

kmin = 3; % cpm - fixed, matches MOD_fish_lib's mod_efe_scan_chi.m

f = f(:)';
Pxx = Pxx(:)';

Pt_T_f = Pxx * volts_to_C(1)^2;
H = MODprocess_L2_fpo7_transfer_function(f, w);
Pt_T_f = Pt_T_f ./ H;

k = f / abs(w);
Pt_Tg_k = (2*pi*k).^2 .* Pt_T_f * abs(w);

fc_index = MODprocess_L2_fpo7_cutoff(f, Pxx, noise_coefs);
kc = k(fc_index);

if kc <= kmin
    chi = NaN;
    kc = NaN;
    return
end

krange = k >= kmin & k <= kc;
dk = mean(diff(k), 'omitnan');
chi = 6 * ktemp * dk * sum(Pt_Tg_k(krange), 'omitnan');

end %end function
