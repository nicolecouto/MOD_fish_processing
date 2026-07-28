function [chi_mle, kc] = mod_scan_calc_chi_mle(f, Pxx, w, volts_to_C, ktemp, nu, epsilon, dof, noise_coefs, tau0, exponent)
% mod_scan_calc_chi_mle        Part of MOD_fish_processing
%
% [chi_mle, kc] = mod_scan_calc_chi_mle(f, Pxx, w, volts_to_C, ktemp, nu, epsilon, dof, noise_coefs, tau0, exponent)
%
% DESCRIPTION
%   Computes chi_mle (thermal variance dissipation rate, degC^2/s) for one
%   scan of one FP07 channel by fitting the theoretical Batchelor spectrum
%   to the observed temperature-gradient spectrum via Maximum Likelihood
%   Estimation (Ruddick, Ozsoy & Vagle 2000) - as opposed to
%   mod_scan_calc_chi_obs.m's chi_obs, which integrates the observed
%   spectrum directly. The MLE fit accounts for the fact that each
%   spectral estimate is chi-squared distributed (not exact), so it can
%   down-weight noisy individual bins in a principled way rather than
%   giving every bin in [kmin, kc] equal footing the way direct
%   integration does - and, by fitting a shape that includes the
%   diffusive rolloff past kc rather than truncating there, it recovers
%   some of the variance direct integration cannot see at all past the
%   noise floor.
%
%     1. f/Pxx -> deconvolved temperature-gradient wavenumber spectrum and
%        noise-floor cutoff, exactly as chi_obs does:
%          [k, Pt_Tg_k] = mod_scan_fpo7_volts_to_Tg_spectrum(f, Pxx, w, volts_to_C, tau0, exponent)
%          kc = mod_scan_fpo7_cutoff(f, Pxx, noise_coefs), converted to wavenumber
%     2. Restrict to the same healthy wavenumber range chi_obs integrates,
%        kmin = 3 cpm to kc.
%     3. Seed a search range from chi_obs's direct-integration value on
%        that same restricted spectrum (cheap to compute, and a
%        reasonable order-of-magnitude starting point - matches
%        MOD_fish_lib's mod_efe_scan_chi.m seeding its search off the
%        already-computed chi).
%     4. Grid-search MLE for the chi that best explains the observed
%        spectrum, given the Batchelor spectrum SHAPE fixed by epsilon/nu/
%        ktemp (mod_scan_batchelor_spectrum.m - the spectrum is
%        exactly linear in chi for fixed epsilon/nu/ktemp, so this is a
%        1-D amplitude search, not a nonlinear multi-parameter fit): at
%        each candidate chi, the log-likelihood of the observed/model
%        ratio under a scaled chi-squared distribution with `dof` degrees
%        of freedom is computed (Ruddick et al. 2000 eq. 16-17), and the
%        search zooms in around the best candidate over a few passes.
%
%   This is a from-scratch reimplementation of the same fixed-epsilon
%   Ruddick et al. (2000) method as MOD_fish_lib's
%   get_chi_mle.m/mle_any_model.m/logLikelihood.m - not a line-by-line
%   port. Two simplifications from that code, both deliberate:
%     - A fixed 4-pass, 200-point log-spaced grid zoom replaces the
%       original's open-ended while-loops that widen the search range
%       when the best fit lands on an edge. Four passes narrowing by
%       ~2 grid steps' worth of decades each time comfortably brackets a
%       chi_seed that's within the legacy code's typical [0.1x, 10x]
%       seed range even before centering, since seeding here starts three
%       decades wide on each side (chi_seed * [1e-3, 1e3]).
%     - No figure-of-merit (FOM) QC flag - MOD_fish_lib's mod_efe_scan_chi.m
%       computes one (compute_fom.m) alongside chi_mle. Left out for now
%       as a separate, later module, same "no QC flag yet" scoping
%       mod_scan_calc_chi_obs.m already used for chi_obs.
%
% INPUTS
%   f          - frequency vector [Hz], nfreq x 1 or 1 x nfreq (same shape
%                as Pxx)
%   Pxx        - one scan's raw FP07 channel power spectrum [V^2/Hz],
%                same shape as f (e.g. from mod_scan_get_spectra.m)
%   w          - fall speed at this scan's center [m/s], scalar - see
%                mod_scan_fpo7_transfer_function.m for why w=0 is not
%                a meaningful input here.
%   volts_to_C - [slope, intercept] from metadata.AFE.(channel).volts_to_C
%                (only slope is used - see mod_scan_fpo7_volts_to_Tg_spectrum.m)
%   ktemp      - thermal diffusivity of the water at this scan [m^2/s]
%                (mod_scan_thermal_diffusivity.m, from scan-center S/T/P)
%   nu         - kinematic viscosity of the water at this scan [m^2/s]
%                (toolbox/seawater/sw_visc.m, from scan-center S/T/P)
%   epsilon    - turbulent kinetic energy dissipation rate at this scan
%                [W/kg], scalar. NOT computed by this repo yet (PLAN.md's
%                modProcess_L2_calc_epsilon.m, shear-channel Nasmyth fit,
%                is not started) - callers must supply it from elsewhere.
%                For the chi_obs-vs-chi_mle/tau comparison this function
%                was built for, an old-format MOD_fish_lib Profile####.mat
%                already carries a per-scan epsilon_final field that works
%                directly - see docs/workflow/L2_calc_chi.md.
%   dof        - degrees of freedom of the power spectrum estimate
%                (metadata.PROCESS.dof) - sets how tightly the MLE trusts
%                each spectral bin against the model.
%   noise_coefs - FP07 bench noise floor struct (n0..n3), passed straight
%                through to mod_scan_fpo7_cutoff.m
%   tau0       - (optional) FP07 time-constant coefficient [s], passed
%                straight through (default in
%                mod_scan_fpo7_transfer_function.m: 0.005).
%   exponent   - (optional) fall-speed exponent, passed straight through
%                (default there: -0.32).
%
% OUTPUTS
%   chi_mle - thermal variance dissipation rate [degC^2/s], from the
%             Batchelor-spectrum MLE fit. NaN if the noise-floor cutoff kc
%             does not exceed kmin (same "genuinely unusable scan"
%             condition as chi_obs), if the direct-integration seed is
%             non-positive (a scan with no usable spectral power to seed a
%             log-spaced search from), or if every candidate in the search
%             range is equally unable to explain the data (all bins
%             clamped to zero by mod_scan_batchelor_spectrum.m -
%             typically kc sitting far past the Batchelor rolloff kb).
%   kc      - the noise-floor cutoff wavenumber used [cpm], or NaN
%             alongside a NaN chi_mle. Same value mod_scan_calc_chi_obs.m
%             would return for the same inputs (same
%             mod_scan_fpo7_cutoff.m call).
%
% CALLED BY
%   (not yet wired into MODprocess_single_L1_to_L2.m - blocked on
%   modProcess_L2_calc_epsilon.m for deployment-wide use, since epsilon
%   isn't computed anywhere in the automatic pipeline yet. Callable
%   standalone today wherever an epsilon estimate already exists - see
%   docs/workflow/L2_calc_chi.md's chi_obs-vs-chi_mle comparison.)
%
% CALLS
%   mod_scan_fpo7_volts_to_Tg_spectrum.m, mod_scan_fpo7_cutoff.m,
%   mod_scan_batchelor_spectrum.m
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

if nargin < 10
    tau0 = [];
end
if nargin < 11
    exponent = [];
end

kmin = 3; % cpm - matches mod_scan_calc_chi_obs.m

f = f(:)';
Pxx = Pxx(:)';

[k, Pt_Tg_k] = mod_scan_fpo7_volts_to_Tg_spectrum(f, Pxx, w, volts_to_C, tau0, exponent);

fc_index = mod_scan_fpo7_cutoff(f, Pxx, noise_coefs);
kc = k(fc_index);

if kc <= kmin
    chi_mle = NaN;
    kc = NaN;
    return
end

krange = k >= kmin & k <= kc;
k_fit = k(krange);
Pk_fit = Pt_Tg_k(krange);

dk = mean(diff(k), 'omitnan');
chi_seed = 6 * ktemp * dk * sum(Pk_fit, 'omitnan');

if ~isfinite(chi_seed) || chi_seed <= 0
    chi_mle = NaN;
    return
end

chi_mle = mle_search_chi(k_fit, Pk_fit, dof, epsilon, nu, ktemp, chi_seed);

end %end function

%% Grid-search MLE for the chi that best fits Pk (observed) with the
% Batchelor spectrum SHAPE fixed by epsilon/nu/ktemp - see DESCRIPTION.
function chi_fit = mle_search_chi(k, Pk, dof, epsilon, nu, ktemp, chi_seed)
n_grid = 200;
n_pass = 4;

search_lo = chi_seed * 1e-3;
search_hi = chi_seed * 1e3;

for pass = 1:n_pass
    chi_grid = logspace(log10(search_lo), log10(search_hi), n_grid);
    Pt = mod_scan_batchelor_spectrum(epsilon, chi_grid, nu, ktemp, k); % nk x n_grid
    logL = spectral_loglikelihood(Pk, Pt, dof);

    if all(~isfinite(logL))
        chi_fit = NaN;
        return
    end

    [~, best] = max(logL);
    if best == 1
        search_lo = search_lo / 10;
        search_hi = chi_grid(2);
    elseif best == n_grid
        search_hi = search_hi * 10;
        search_lo = chi_grid(n_grid - 1);
    else
        search_lo = chi_grid(best - 1);
        search_hi = chi_grid(best + 1);
    end
end

chi_fit = chi_grid(best);
end

%% Ruddick, Ozsoy & Vagle (2000) log-likelihood of observed spectrum Pk
% against candidate model spectra Pt (nk x ncandidate), assuming each
% spectral estimate is dof/Pt-scaled chi-squared distributed. dof is a
% constant multiplicative offset inside the log (dropped in the original
% too) - it doesn't affect which candidate maximizes logL.
function logL = spectral_loglikelihood(Pk, Pt, dof)
Pk = Pk(:);
z = dof * Pk ./ Pt;
logL = sum(log(chi2pdf(z, dof) ./ Pt), 1, 'omitnan');
end
