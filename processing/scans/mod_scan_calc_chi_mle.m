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
%        ktemp (batchelor_spectrum.m - the spectrum is
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
%     - The grid-search zoom itself (4-pass, 200-point log-spaced,
%       widen-on-edge-hit) is shared with mod_scan_calc_epsilon_mle.m via
%       toolbox/mod_scan_mle_grid_search.m - see that function's own
%       DESCRIPTION for the full design rationale (bounded widen/narrow
%       passes, why the starting search range is kept wide despite
%       widening being "free" of the pass budget - chi2pdf underflow
%       avoidance).
%     - No figure-of-merit (FOM) QC flag - MOD_fish_lib's mod_efe_scan_chi.m
%       computes one (compute_fom.m) alongside chi_mle. Left out for now
%       as a separate, later module, same "no QC flag yet" scoping
%       mod_scan_calc_chi_obs.m already used for chi_obs. (Epsilon's own
%       MLE fit, mod_scan_calc_epsilon_mle.m, does get a FOM -
%       mod_scan_calc_fom.m - since it shipped alongside epsilon rather
%       than being deferred a second time; chi's own FOM remains a
%       separate follow-up.)
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
%                  metadata.PROCESS.fft_segments_per_scan - fed to
%                    toolbox/mod_scan_dof.m to derive the power spectrum
%                    estimate's degrees of freedom, which sets how
%                    tightly the MLE trusts each spectral bin against the
%                    model. dof itself is not a yaml-configurable field -
%                    see mod_scan_dof.m/mod_L2_tile_scans.m for why it's
%                    derived instead of its own setting.
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
%                  to zero by batchelor_spectrum.m - typically
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
%   mod_L2_tile_scans.m - wired in for every scan where an epsilon
%   estimate is available (metadata.PROCESS.EPSILON.epsilon_final_source-
%   selected mean across this deployment's shear channels - see that
%   function's DESCRIPTION), now that modProcess_L2_calc_epsilon.m
%   produces one. Still fully callable standalone wherever an epsilon
%   estimate already exists from elsewhere - see
%   docs/workflow/L2_calc_chi.md's chi_obs-vs-chi_mle comparison.
%
% CALLS
%   MODsetup_validate_metadata.m, mod_scan_fpo7_volts_to_Tg_spectrum.m,
%   mod_scan_fpo7_cutoff.m, batchelor_spectrum.m, toolbox/mod_scan_dof.m,
%   toolbox/mod_scan_mle_grid_search.m
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

yaml_file = '';
if isfield(metadata, 'paths') && isfield(metadata.paths, 'setup_yml')
    yaml_file = metadata.paths.setup_yml;
end
metadata = MODsetup_validate_metadata(metadata, yaml_file, ...
    {'kmin_obs', 'chi_mle_start_search', 'chi_mle_end_search', ...
     'fft_segments_per_scan', ...
     'time_constant_s', 'fall_speed_exponent', ...
     'noise_adjusted_to_f', 'n_smooth_f_spectrum', 'sn_min', 'n_skip'});

dof = mod_scan_dof(metadata.PROCESS.fft_segments_per_scan);
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

scan.chi_mle = mod_scan_mle_grid_search(Pk_fit, dof, ...
    @(chi_grid) batchelor_spectrum(scan.epsilon, chi_grid, scan.nu, scan.ktemp, k_fit), ...
    chi_seed, chi_mle_start_search, chi_mle_end_search);
scan.chi_mle_kc = kc;

end %end function
