function scan = mod_scan_calc_epsilon_obs(scan, metadata)
% mod_scan_calc_epsilon_obs        Part of MOD_fish_processing
%
% scan = mod_scan_calc_epsilon_obs(scan, metadata)
%
% DESCRIPTION
%   Computes epsilon_obs (turbulent kinetic energy dissipation rate, W/kg)
%   for one scan of one shear channel, by direct wavenumber integration of
%   the shear spectrum against a Panchev/Nasmyth-referenced iterative
%   scheme (Wesson & Gregg 1994) - the shear-channel analog of
%   mod_scan_calc_chi_obs.m. Computed twice per call, from the two shear
%   spectra mod_scan_shear_volts_to_shear_spectrum.m/
%   mod_scan_shear_accel_coherence.m produce: epsilon_obs (the raw
%   spectrum) and epsilon_obs_co (the coherence-cleaned spectrum, when
%   available) - matching MOD_fish_lib's mod_efe_scan_epsilon.m computing
%   both epsilon/epsilon_co from the same eps1_mmp.m routine.
%
%   Ported from MOD_fish_lib's eps1_mmp.m + epsilon2_correct.m (kept as
%   local subfunctions below - nothing else in this repo calls the raw
%   3-stage integration standalone). Three-stage iterative estimate:
%     1. Integrate the shear spectrum over the stage1_kmin-stage1_kmax cpm
%        band (default 2-10; not kmin_obs - see NOTES) and use one of two
%        polynomial fits (chosen by whether that integral already looks
%        purely inertial-subrange) to get a first-pass epsilon estimate,
%        eps1.
%     2. Re-integrate from kmin_obs up to the wavenumber containing 90% of
%        a Panchev spectrum's variance at eps1 (capped at kmax, see
%        below) -> eps2.
%     3. Repeat once more with eps2's own 90%-variance wavenumber -> eps3.
%     4. Floor eps3 at 1e-11 W/kg if smaller; otherwise apply a median-
%        ratio adjustment against a Nasmyth spectrum evaluated at eps3,
%        then a missing-variance correction (epsilon2_correct, an
%        empirical polynomial fit accounting for shear variance lost
%        above the integration cutoff) to get the final epsilon.
%   kmax caps the integration upper bound at a known contamination
%   frequency, contam_freq_hz / abs(w) - the shear-channel analog of chi's
%   own contam_freq_hz cap (mod_scan_fpo7_cutoff.m), but applied as a
%   direct integration-bound cap here rather than a noise-floor-crossing
%   search, since shear has no bench-measured noise floor file to search
%   against the way FP07 does (see mod_scan_shear_volts_to_shear_spectrum.m's
%   DESCRIPTION).
%
% INPUTS
%   scan       - struct with:
%                  spectra.k          - wavenumber vector [cpm], from
%                        mod_scan_shear_volts_to_shear_spectrum.m
%                  spectra.Ps_shear_k - raw shear wavenumber spectrum
%                        [s^-2/cpm], same shape as spectra.k
%                  spectra.Ps_shear_co_k - (optional) coherence-cleaned
%                        shear wavenumber spectrum, same shape as
%                        spectra.k - set by modProcess_L2_calc_epsilon.m
%                        from mod_scan_shear_accel_coherence.m's output.
%                        epsilon_obs_co comes back NaN if absent.
%                  w                  - fall speed at this scan's center
%                        [m/s], scalar - sign does not matter (abs'd
%                        internally).
%                  nu                 - kinematic viscosity of the water
%                        at this scan [m^2/s] (toolbox/seawater/visc.m,
%                        from scan-center S/T/P)
%   metadata   - metadata struct (from MODsetup_read_yaml.m). Validated at
%                the top of this function via MODsetup_validate_metadata.m.
%                Uses:
%                  metadata.PROCESS.EPSILON.kmin_obs - low-wavenumber
%                    integration bound [cpm] for stages 2-3 (NOT stage 1 -
%                    see NOTES)
%                  metadata.PROCESS.EPSILON.contam_freq_hz - known
%                    vibration/electrical contamination frequency [Hz] for
%                    this deployment, or Inf if none is known - caps kmax
%                    (kmax = contam_freq_hz / abs(w))
%                  metadata.PROCESS.EPSILON.stage1_kmin/.stage1_kmax -
%                    stage-1 integration band [cpm] (default 2/10 - see
%                    NOTES for why changing these away from their default
%                    is not generally safe)
%                See MODsetup_metadata_field_registry.m for each field's
%                historical default (shown as the prompt's starting value).
%
% OUTPUTS
%   scan - same struct, with added:
%     epsilon_obs       - TKE dissipation rate [W/kg] from the raw shear
%                          spectrum. NaN if there are too few spectral
%                          bins in the stage-1 band (stage1_kmin-
%                          stage1_kmax, default 2-10 cpm) to estimate
%                          anything (a genuinely unusable scan for this
%                          channel).
%     epsilon_obs_kc    - the final-stage integration cutoff wavenumber
%                          used [cpm] (snapped to the nearest actual k
%                          bin), or NaN alongside a NaN epsilon_obs.
%     epsilon_obs_co    - TKE dissipation rate [W/kg] from the coherence-
%                          cleaned shear spectrum. NaN if
%                          spectra.Ps_shear_co_k is absent (no coherence
%                          computed for this scan/channel) or, same as
%                          epsilon_obs, too few stage-1 bins.
%     epsilon_obs_co_kc - same as epsilon_obs_kc, for the cleaned-spectrum
%                          estimate. This is the kc mod_scan_calc_epsilon_mle.m
%                          reuses as its own fit's upper wavenumber bound.
%
% CALLED BY
%   modProcess_L2_calc_epsilon.m
%
% CALLS
%   MODsetup_validate_metadata.m, nasmyth_spectrum.m
%
% NOTES
%   Stage 1's integration band (stage1_kmin-stage1_kmax, default 2-10 cpm)
%   is a distinct field from kmin_obs, not a duplicate or a typo - the two
%   polynomial fits it feeds (eps_fit_shear10/shtotal_fit_shear10 below)
%   were derived specifically over the historical 2-10 cpm band and are
%   not valid elsewhere, so changing stage1_kmin/stage1_kmax away from
%   their default is not generally safe (see
%   MODsetup_metadata_field_registry.m's CAUTION for these two fields).
%   They were a fixed literal (not even a caller-supplied argument) in
%   both MOD_fish_lib's eps1_mmp.m and this port's first pass - made
%   tunable here for traceability/consistency with every other formerly-
%   hardcoded epsilon/chi bound in this repo, not because a different
%   value is expected to be valid. kmin_obs only governs stages 2-3's
%   re-integration bound, exactly matching where the ported eps1_mmp.m
%   itself applies its own (there, hardcoded at 3 cpm) kmin - making that
%   value configurable here, rather than hardcoding 3, follows this
%   repo's existing precedent for chi's kmin_obs field, which was also a
%   legacy hardcoded constant made tunable.
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

yaml_file = '';
if isfield(metadata, 'paths') && isfield(metadata.paths, 'setup_yml')
    yaml_file = metadata.paths.setup_yml;
end
metadata = MODsetup_validate_metadata(metadata, yaml_file, ...
    {'epsilon_kmin_obs', 'contam_freq_hz_shear', 'epsilon_stage1_kmin', 'epsilon_stage1_kmax'});

kmin = metadata.PROCESS.EPSILON.kmin_obs;
kmax = metadata.PROCESS.EPSILON.contam_freq_hz / abs(scan.w);
stage1_kmin = metadata.PROCESS.EPSILON.stage1_kmin;
stage1_kmax = metadata.PROCESS.EPSILON.stage1_kmax;

k = scan.spectra.k;

[scan.epsilon_obs, scan.epsilon_obs_kc] = calc_epsilon_direct(k, scan.spectra.Ps_shear_k, scan.nu, kmin, kmax, stage1_kmin, stage1_kmax);

if isfield(scan.spectra, 'Ps_shear_co_k') && ~isempty(scan.spectra.Ps_shear_co_k)
    [scan.epsilon_obs_co, scan.epsilon_obs_co_kc] = calc_epsilon_direct(k, scan.spectra.Ps_shear_co_k, scan.nu, kmin, kmax, stage1_kmin, stage1_kmax);
else
    scan.epsilon_obs_co = NaN;
    scan.epsilon_obs_co_kc = NaN;
end

end %end function

%% Ported from MOD_fish_lib's eps1_mmp.m - see DESCRIPTION above for the
% 3-stage algorithm this implements.
function [epsilon, kc] = calc_epsilon_direct(k, Psheark, kvis, kmin, kmax, stage1_kmin, stage1_kmax)

k = k(:)';
Psheark = Psheark(:)';

% Stage 1: stage1_kmin-stage1_kmax band, default 2-10 cpm (NOT kmin - see NOTES).
krange = find(k >= stage1_kmin & k < stage1_kmax);
if numel(krange) <= 2
    epsilon = NaN;
    kc = NaN;
    return
end
shear10 = trapz(k(krange), Psheark(krange));
logshear10 = log10(shear10);

% eps_fit_shear10/shtotal_fit_shear10: empirical polynomial fits to
% log10(shear10) - ported verbatim, provenance not otherwise documented
% in the source (its own comment: "I have no idea how these coefficients
% are computed").
eps_fit_shear10 = [8.6819e-04, -3.4473e-03, -1.3373e-03, 1.5248, -3.1607];
shtotal_fit_shear10 = [6.9006e-04, -4.2461e-03, -7.0832e-04, 1.5275, 1.8564];

if logshear10 > -3 % stage-1 band lies entirely in the inertial subrange
    eps1 = 10^polyval(eps_fit_shear10, logshear10);
else
    eps1 = 7.5 * kvis * 10^polyval(shtotal_fit_shear10, logshear10);
end

% Stage 2: re-integrate to the wavenumber containing 90% of a Panchev
% spectrum's variance at eps1, capped at kmax.
kc2 = min(2*0.0816*(eps1/kvis^3)^(1/4), kmax);
krange = find(k >= kmin & k <= kc2);
if numel(krange) > 2
    eps2 = 7.5 * kvis * trapz(k(krange), Psheark(krange));
else
    eps2 = 1e-12;
end

% Stage 3: repeat with eps2's own 90%-variance wavenumber.
kc = min(0.0816*(eps2/kvis^3)^(1/4), kmax);
krange = find(k >= kmin & k <= kc);
if numel(krange) > 2
    eps3 = 7.5 * kvis * trapz(k(krange), Psheark(krange));
else
    eps3 = 1e-12;
end

if eps3 < 1e-11
    epsilon = 1e-11;
else
    Ppan3 = nasmyth_spectrum(eps3, kvis, k);
    idx1 = find(k >= kmin, 1, 'first');
    idx2 = find(k >= kc, 1, 'first');
    idx_range = idx1:idx2;
    adjust = median(Psheark(idx_range), 'omitnan') / median(Ppan3(idx_range), 'omitnan');
    eps4 = eps3 * adjust;
    mf = epsilon2_correct(eps4, kvis);
    epsilon = mf * eps4;
end

% Snap to the nearest actual k bin, matching eps1_mmp.m.
kc_idx = find(k > kc, 1, 'first');
if isempty(kc_idx)
    kc = k(end);
else
    kc = k(kc_idx);
end

end

%% Ported from MOD_fish_lib's epsilon2_correct.m - missing-variance
% correction for shear variance lost above the integration cutoff kc,
% relative to the full Nasmyth/Panchev spectrum's tail. Empirical 8th-
% order polynomial fit, provenance not otherwise documented in the
% source. Legacy's signature also accepted kmin/kmax arguments that its
% live code path never used (only referenced in commented-out code) -
% dropped here rather than kept as unused parameters.
function mf = epsilon2_correct(eps_res, kvis)

pf = [-3.12067617e-05, -1.31492870e-03, -2.29864661e-02, -2.18323426e-01, -1.23597906, ...
      -4.29137352, -8.91987933, -9.58856889, -2.41486526];

ler = log10(eps_res);
if ler <= -5
    lf_eps = 0;
elseif ler > -5 && ler <= -1
    lf_eps = polyval(pf, ler);
    if ler < -2
        lf_eps = lf_eps + 0.05*(ler+6)*(1.3e-6-kvis)/(0.3e-6);
    end
else % ler > -1
    lf_eps = polyval(pf, -1);
end

mf = 10^lf_eps;

end
