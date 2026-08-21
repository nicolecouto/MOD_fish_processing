function scan = mod_scan_calc_chi_mle(scan, metadata, channel, noise_coefs)
% mod_scan_calc_chi_mle        Part of MOD_fish_processing
%
% scan = mod_scan_calc_chi_mle(scan, metadata, channel, noise_coefs)
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
%     1. f/Pt_volt_f -> deconvolved temperature-gradient wavenumber spectrum
%        and noise-floor cutoff, exactly as chi_obs does:
%          scan = mod_scan_fpo7_volts_to_Tg_spectrum(scan, metadata, channel)
%          scan = mod_scan_fpo7_cutoff(scan, metadata, noise_coefs)
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
%       than doubling it. Seeding defaults to three decades wide on each
%       side (chi_seed * [1e-3, 1e3], metadata.PROCESS.CHI.
%       chi_mle_start_search/.chi_mle_end_search below), not narrower,
%       despite widening being free of the pass budget now:
%       spectral_loglikelihood computes log(chi2pdf(z,dof)), and chi2pdf
%       underflows to exactly 0 in double precision once a candidate is
%       many decades from the truth - so a too-narrow starting grid can
%       end up with EVERY candidate underflowed (all(~isfinite(logL))
%       true) before the widen logic ever runs, returning NaN having
%       never gotten to widen at all. The wide starting net keeps at
%       least one edge candidate close enough to stay numerically finite,
%       giving widening something to act on. A deployment that narrows
%       this via metadata.PROCESS.CHI (e.g. the temp_to_chi.ipynb-
%       documented 0.1/10, one decade each side) trades away some of
%       that safety margin - widening still recovers if the true chi
%       lands outside the narrower net, but a scan whose seed is already
%       many decades from the true chi is more likely to hit the
%       all-underflowed NaN case before widening gets a chance to run.
%     - No figure-of-merit (FOM) QC flag - MOD_fish_lib's mod_efe_scan_chi.m
%       computes one (compute_fom.m) alongside chi_mle. Left out for now
%       as a separate, later module, same "no QC flag yet" scoping
%       mod_scan_calc_chi_obs.m already used for chi_obs.
%
% INPUTS
%   scan       - struct with:
%                  spectra.f         - frequency vector [Hz], nfreq x 1 or
%                            1 x nfreq (same shape as spectra.Pt_volt_f)
%                  spectra.Pt_volt_f - one scan's raw FP07 channel power
%                            spectrum [V^2/Hz], same shape as spectra.f
%                            (e.g. from mod_scan_get_spectra.m's
%                            scan.spectra.(channel)_volt_f, selected by
%                            the caller for this one channel)
%                  w       - fall speed at this scan's center [m/s],
%                            scalar - see mod_scan_fpo7_transfer_function.m
%                            for why w=0 is not a meaningful input here.
%                  ktemp   - thermal diffusivity of the water at this scan
%                            [m^2/s] (mod_scan_thermal_diffusivity.m, from
%                            scan-center S/T/P)
%                  nu      - kinematic viscosity of the water at this scan
%                            [m^2/s] (toolbox/seawater/sw_visc.m, from
%                            scan-center S/T/P)
%                  epsilon - turbulent kinetic energy dissipation rate at
%                            this scan [W/kg], scalar. NOT computed by
%                            this repo yet (PLAN.md's
%                            modProcess_L2_calc_epsilon.m, shear-channel
%                            Nasmyth fit, is not started) - callers must
%                            supply it from elsewhere. For the
%                            chi_obs-vs-chi_mle/tau comparison this
%                            function was built for, an old-format
%                            MOD_fish_lib Profile####.mat already carries
%                            a per-scan epsilon_final field that works
%                            directly - see docs/workflow/L2_calc_chi.md.
%   metadata   - metadata struct (from MODsetup_read_yaml.m). Validated up
%                front, via MODsetup_validate_metadata.m, against the full
%                set of PROCESS values this function AND both sub-calls it
%                makes need - resolving everything the whole chain needs
%                in one prompt-and-reload cycle rather than letting each
%                sub-call discover its own subset piecemeal. Passed
%                straight through to mod_scan_fpo7_volts_to_Tg_spectrum.m
%                (metadata.AFE.(channel).volts_to_C, .electronics_filter,
%                metadata.PROCESS.CHI.time_constant_s, .fall_speed_exponent)
%                and mod_scan_fpo7_cutoff.m (metadata.PROCESS.CHI.
%                noise_adjusted_to_f/.n_smooth_f_spectrum/.sn_min/.n_skip -
%                see those functions for exact fields). Also used directly
%                here:
%                  metadata.PROCESS.dof - degrees of freedom of the power
%                    spectrum estimate, sets how tightly the MLE trusts
%                    each spectral bin against the model
%                  metadata.PROCESS.CHI.kmin_obs - low-wavenumber
%                    integration bound [cpm], matches mod_scan_calc_chi_obs.m
%                  metadata.PROCESS.CHI.chi_mle_start_search,
%                    .chi_mle_end_search - multipliers on the
%                    chi_obs-seeded starting value bounding
%                    mle_search_chi's grid search (see DESCRIPTION)
%                See MODsetup_metadata_field_registry.m for each field's
%                historical default (shown as the prompt's starting value).
%   channel    - channel name string (e.g. 't1'), selects which
%                metadata.AFE.(channel) to read.
%   noise_coefs - FP07 bench noise floor struct (n0..n3), passed straight
%                through to mod_scan_fpo7_cutoff.m
%
% OUTPUTS
%   scan - same struct, with added:
%     chi_mle    - thermal variance dissipation rate [degC^2/s], from the
%                  Batchelor-spectrum MLE fit. NaN if the noise-floor
%                  cutoff kc does not exceed kmin (same "genuinely
%                  unusable scan" condition as chi_obs), if the
%                  direct-integration seed is non-positive (a scan with
%                  no usable spectral power to seed a log-spaced search
%                  from), or if every candidate in the search range is
%                  equally unable to explain the data (all bins clamped
%                  to zero by mod_scan_batchelor_spectrum.m - typically
%                  kc sitting far past the Batchelor rolloff kb).
%     chi_mle_kc - the noise-floor cutoff wavenumber used [cpm], or NaN
%                  alongside a NaN chi_mle (only in the kc<=kmin case -
%                  the non-positive-seed and all-underflowed cases still
%                  return the valid kc, since kc itself was fine; only
%                  the fit failed). Same value mod_scan_calc_chi_obs.m
%                  would return for the same inputs (same
%                  mod_scan_fpo7_cutoff.m call).
%     spectra.k, spectra.Pt_Tg_k, spectra.fc_index - added by the
%                  mod_scan_fpo7_volts_to_Tg_spectrum.m/mod_scan_fpo7_cutoff.m
%                  calls below and left on the returned scan (not
%                  discarded), same as mod_scan_calc_chi_obs.m.
%
% CALLED BY
%   (not yet wired into MODprocess_single_L1_to_L2.m - blocked on
%   modProcess_L2_calc_epsilon.m for deployment-wide use, since epsilon
%   isn't computed anywhere in the automatic pipeline yet. Callable
%   standalone today wherever an epsilon estimate already exists - see
%   docs/workflow/L2_calc_chi.md's chi_obs-vs-chi_mle comparison.)
%
% CALLS
%   MODsetup_validate_metadata.m, mod_scan_fpo7_volts_to_Tg_spectrum.m,
%   mod_scan_fpo7_cutoff.m, mod_scan_batchelor_spectrum.m
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

yaml_file = '';
if isfield(metadata, 'paths') && isfield(metadata.paths, 'setup_yml')
    yaml_file = metadata.paths.setup_yml;
end
metadata = MODsetup_validate_metadata(metadata, yaml_file, ...
    {'kmin_obs', 'chi_mle_start_search', 'chi_mle_end_search', 'dof', ...
     'time_constant_s', 'fall_speed_exponent', ...
     'noise_adjusted_to_f', 'n_smooth_f_spectrum', 'sn_min', 'n_skip'});

dof = metadata.PROCESS.dof;
kmin = metadata.PROCESS.CHI.kmin_obs; % cpm
chi_mle_start_search = metadata.PROCESS.CHI.chi_mle_start_search; % multiplier on chi_seed
chi_mle_end_search = metadata.PROCESS.CHI.chi_mle_end_search;

scan.spectra.f = scan.spectra.f(:)';
scan.spectra.Pt_volt_f = scan.spectra.Pt_volt_f(:)';

scan = mod_scan_fpo7_volts_to_Tg_spectrum(scan, metadata, channel);
scan = mod_scan_fpo7_cutoff(scan, metadata, noise_coefs);

k = scan.spectra.k;
Pt_Tg_k = scan.spectra.Pt_Tg_k;
kc = k(scan.spectra.fc_index);

if kc <= kmin
    scan.chi_mle = NaN;
    scan.chi_mle_kc = NaN;
    return
end

krange = k >= kmin & k <= kc;
k_fit = k(krange);
Pk_fit = Pt_Tg_k(krange);

dk = mean(diff(k), 'omitnan');
chi_seed = 6 * scan.ktemp * dk * sum(Pk_fit, 'omitnan');

if ~isfinite(chi_seed) || chi_seed <= 0
    scan.chi_mle = NaN;
    scan.chi_mle_kc = kc;
    return
end

scan.chi_mle = mle_search_chi(k_fit, Pk_fit, dof, scan.epsilon, scan.nu, scan.ktemp, chi_seed, ...
    chi_mle_start_search, chi_mle_end_search);
scan.chi_mle_kc = kc;

end %end function

%% Grid-search MLE for the chi that best fits Pk (observed) with the
% Batchelor spectrum SHAPE fixed by epsilon/nu/ktemp - see DESCRIPTION.
function chi_fit = mle_search_chi(k, Pk, dof, epsilon, nu, ktemp, chi_seed, ...
    chi_mle_start_search, chi_mle_end_search)
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

search_lo = chi_seed * chi_mle_start_search;
search_hi = chi_seed * chi_mle_end_search;

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
