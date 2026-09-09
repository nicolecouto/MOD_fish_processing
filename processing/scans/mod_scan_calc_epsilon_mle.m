function scan = mod_scan_calc_epsilon_mle(scan, metadata)
% mod_scan_calc_epsilon_mle        Part of MOD_fish_processing
%
% scan = mod_scan_calc_epsilon_mle(scan, metadata)
%
% DESCRIPTION
%   Computes epsilon_mle (turbulent kinetic energy dissipation rate, W/kg)
%   for one scan of one shear channel by fitting the theoretical Nasmyth
%   spectrum (nasmyth_spectrum.m) to the coherence-cleaned shear
%   spectrum via Maximum Likelihood Estimation - the shear-channel analog
%   of mod_scan_calc_chi_mle.m, sharing its grid-search machinery
%   (processing/scans/mod_scan_mle_grid_search.m). Unlike chi_mle, which searches a
%   pure amplitude parameter (chi) with the Batchelor spectrum's shape
%   fixed by an externally-supplied epsilon, this search is over epsilon
%   itself - the Nasmyth spectrum's shape and amplitude are both set by
%   epsilon (see nasmyth_spectrum.m).
%
%   Always fit against the coherence-cleaned spectrum (never the raw
%   spectrum) - matches MOD_fish_lib's mod_efe_scan_epsilon.m, which only
%   ever computes epsilon_mle inside its "coherence available" branch,
%   seeded by that same branch's epsilon_co. Reuses
%   mod_scan_calc_epsilon_obs.m's own epsilon_obs_co/epsilon_obs_co_kc as
%   the search seed and upper wavenumber fit bound respectively, rather
%   than recomputing either - this function must therefore run after
%   mod_scan_calc_epsilon_obs.m on the same scan (see
%   modProcess_L2_calc_epsilon.m's call order).
%
%   The fit range's lower bound is metadata.PROCESS.EPSILON.kmin_mle - a
%   DIFFERENT, separately-tunable field from kmin_obs (mod_scan_calc_epsilon_obs.m's
%   direct-integration bound). MOD_fish_lib's live code always fits from
%   the same kmin eps1_mmp.m itself used (hardcoded 3 cpm, just echoed
%   back as an output) - a colleague's 2026 ASTRAL reprocess fork
%   overrode this to 5 cpm specifically for the MLE fit, which is the
%   provenance kmin_mle's registered default follows (see
%   MODsetup_metadata_field_registry.m, PLAN.md Session Log 2026-09-02).
%
% INPUTS
%   scan       - struct with:
%                  spectra.k             - wavenumber vector [cpm], from
%                        mod_scan_shear_volts_to_shear_spectrum.m
%                  spectra.Ps_shear_co_k - coherence-cleaned shear
%                        wavenumber spectrum [s^-2/cpm], same shape as
%                        spectra.k - absent or empty means epsilon_mle
%                        comes back NaN (no coherence computed for this
%                        scan/channel).
%                  nu                    - kinematic viscosity of the
%                        water at this scan [m^2/s]
%                  epsilon_obs_co        - direct-integration coherence-
%                        cleaned epsilon estimate (mod_scan_calc_epsilon_obs.m),
%                        used as the MLE search's seed
%                  epsilon_obs_co_kc     - same function's cutoff
%                        wavenumber, used as this fit's upper bound
%   metadata   - metadata struct (from MODsetup_read_yaml.m). Validated up
%                front via MODsetup_validate_metadata.m. Uses:
%                  metadata.PROCESS.fft_segments_per_scan - fed to
%                    processing/scans/mod_scan_dof.m to derive the power spectrum
%                    estimate's degrees of freedom, exactly the same dof
%                    mod_scan_calc_chi_mle.m computes - a single shared
%                    definition (Nuttall 1971), not the different, un-
%                    corrected raw-segment-count formula (2*N/nfft - 1)
%                    MOD_fish_lib's mod_efe_scan_epsilon.m computed locally
%                    for its own coherence/epsilon dof - deliberately not
%                    ported, since this repo's own mod_scan_dof.m is
%                    already the single source of truth every other MLE
%                    weighting in this repo uses (see that function's
%                    header).
%                  metadata.PROCESS.EPSILON.kmin_mle - low-wavenumber fit
%                    bound [cpm] (see DESCRIPTION)
%                  metadata.PROCESS.EPSILON.mle_start_search,
%                    .mle_end_search - multipliers on the epsilon_obs_co-
%                    seeded starting value bounding
%                    mod_scan_mle_grid_search.m's grid search. Registered
%                    separately from chi's own chi_mle_start_search/
%                    .chi_mle_end_search (1e-3/1e3) - MOD_fish_lib's
%                    epsilon MLE search used a narrower one-decade-each-
%                    side range (1e-1/1e1), a real, deliberate difference
%                    from chi's search width, not an oversight to
%                    reconcile.
%                See MODsetup_metadata_field_registry.m for each field's
%                historical default (shown as the prompt's starting value).
%
% OUTPUTS
%   scan - same struct, with added:
%     epsilon_mle - TKE dissipation rate [W/kg] from the Nasmyth-spectrum
%                   MLE fit. NaN if spectra.Ps_shear_co_k is absent, if
%                   epsilon_obs_co_kc does not exceed kmin_mle (no valid
%                   wavenumber range to fit over), if the seed
%                   (epsilon_obs_co) is non-positive or non-finite, or if
%                   every candidate in the search range is equally unable
%                   to explain the data (mod_scan_mle_grid_search.m's
%                   all-underflowed case).
%
% CALLED BY
%   modProcess_L2_calc_epsilon.m
%
% CALLS
%   MODsetup_validate_metadata.m, nasmyth_spectrum.m,
%   processing/scans/mod_scan_dof.m, processing/scans/mod_scan_mle_grid_search.m
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

yaml_file = '';
if isfield(metadata, 'paths') && isfield(metadata.paths, 'setup_yml')
    yaml_file = metadata.paths.setup_yml;
end
metadata = MODsetup_validate_metadata(metadata, yaml_file, ...
    {'kmin_mle', 'mle_start_search', 'mle_end_search', 'fft_segments_per_scan'});

scan.epsilon_mle = NaN;

if ~isfield(scan.spectra, 'Ps_shear_co_k') || isempty(scan.spectra.Ps_shear_co_k)
    return
end

kmin_mle = metadata.PROCESS.EPSILON.kmin_mle;
kc = scan.epsilon_obs_co_kc;
if ~isfinite(kc) || kc <= kmin_mle
    return
end

epsilon_seed = scan.epsilon_obs_co;
if ~isfinite(epsilon_seed) || epsilon_seed <= 0
    return
end

k = scan.spectra.k(:)';
Ps_shear_co_k = scan.spectra.Ps_shear_co_k(:)';
krange = k >= kmin_mle & k <= kc;
k_fit = k(krange)';
Pk_fit = Ps_shear_co_k(krange)';

dof = mod_scan_dof(metadata.PROCESS.fft_segments_per_scan);
mle_start_search = metadata.PROCESS.EPSILON.mle_start_search;
mle_end_search = metadata.PROCESS.EPSILON.mle_end_search;

scan.epsilon_mle = mod_scan_mle_grid_search(Pk_fit, dof, ...
    @(epsi_grid) nasmyth_spectrum(epsi_grid, scan.nu, k_fit), ...
    epsilon_seed, mle_start_search, mle_end_search);

end %end function
