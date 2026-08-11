function [chi_mle, kc] = mod_scan_calc_chi_mle(f, Pxx, w, volts_to_C, ktemp, nu, epsilon, dof, noise_coefs, tau0, exponent, electronics_filter)
% mod_scan_calc_chi_mle        Part of MOD_fish_processing
%
% [chi_mle, kc] = mod_scan_calc_chi_mle(f, Pxx, w, volts_to_C, ktemp, nu, epsilon, dof, noise_coefs, tau0, exponent, electronics_filter)
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
%     - A fixed 4-pass, 200-point log-spaced grid zoom (mle_search_chi)
%       replaces the original's open-ended while-loops that widen the
%       search range when the best fit lands on an edge - but the same
%       idea survives in bounded form: hitting an edge here still widens
%       (10x on the side that was hit) rather than narrows, and that
%       widening step does NOT consume one of the 4 narrowing passes.
%       Widening is capped at max_widen=10, matching mle_any_model.m's
%       own cc<10 guard - the legacy code budgets that cap separately per
%       edge (low, high), but since a single search here only ever climbs
%       in one direction at a time (never needs both budgets on the same
%       call), one shared cc<10-sized budget mirrors it directly rather
%       than doubling it. Seeding still starts three decades wide on each
%       side (chi_seed * [1e-3, 1e3]), not narrower, despite widening
%       being free of the pass budget now: spectral_loglikelihood computes
%       log(chi2pdf(z,dof)), and chi2pdf underflows to exactly 0 in double
%       precision once a candidate is many decades from the truth - so a
%       too-narrow starting grid can end up with EVERY candidate
%       underflowed (all(~isfinite(logL)) true) before the widen logic
%       ever runs, returning NaN having never gotten to widen at all. The
%       wide starting net keeps at least one edge candidate close enough
%       to stay numerically finite, giving widening something to act on.
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
%   electronics_filter - (optional) AFE electronics/ADC transfer function,
%                magnitude-squared, same shape as f - passed straight
%                through to mod_scan_fpo7_volts_to_Tg_spectrum.m (default
%                there: 1, no correction). Normally
%                metadata.AFE.(ch).electronics_filter from
%                MODsetup_define_filters.m - see mod_scan_calc_chi_obs.m's
%                matching parameter for why this matters.
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
if nargin < 12
    electronics_filter = [];
end

kmin = 3; % cpm - matches mod_scan_calc_chi_obs.m

f = f(:)';
Pxx = Pxx(:)';

[k, Pt_Tg_k] = mod_scan_fpo7_volts_to_Tg_spectrum(f, Pxx, w, volts_to_C, tau0, exponent, electronics_filter);

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
% Loop n_pass times through a n_grid-point array of possibilities between search_lo and search_hi,
% narrowing to the best candidate +/- 1 index each time. 
% If a search picks the best option as exactly
% search_lo, the low bound is divided by 10 and the high bound is set to the 2nd-lowest search value from before (mirror image
% if it lands at search_hi) - that's a widening step, not a narrowing one, so it does NOT count against
% n_pass. 
% Widening is capped at max_widen attempts (mirroring MOD_fish_lib's mle_any_model.m cc<10 guard)
% so a pathological scan can't loop forever.

n_grid = 200;
n_pass = 4;
max_widen = 10; % mirrors mle_any_model.m's per-edge cc<10 guard - one shared

search_lo = chi_seed * 1e-3;
search_hi = chi_seed * 1e3;

pass = 0;
n_widen = 0;
while pass < n_pass
    chi_grid = logspace(log10(search_lo), log10(search_hi), n_grid);
    Pt = mod_scan_batchelor_spectrum(epsilon, chi_grid, nu, ktemp, k); % nk x n_grid
    logL = spectral_loglikelihood(Pk, Pt, dof); % constant +N*log(dof) term included but irrelevant here - only the argmax below matters

    if all(~isfinite(logL))
        chi_fit = NaN;
        return
    end

    [~, best] = max(logL);
    if best == 1 || best == n_grid
        if n_widen >= max_widen
            chi_fit = chi_grid(best);
            return
        end
        if best == 1
            search_lo = search_lo / 10;
            search_hi = chi_grid(2);
        else
            search_hi = search_hi * 10;
            search_lo = chi_grid(n_grid - 1);
        end
        n_widen = n_widen + 1;
        continue %do not do pass=pass+1, loop through again with this new search range
    end

    search_lo = chi_grid(best - 1);
    search_hi = chi_grid(best + 1);
    pass = pass + 1;
end

chi_fit = chi_grid(best);
end



