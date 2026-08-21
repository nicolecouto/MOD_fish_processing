function scan = mod_scan_calc_chi_obs(scan, metadata, channel, noise_coefs)
% mod_scan_calc_chi_obs        Part of MOD_fish_processing
%
% scan = mod_scan_calc_chi_obs(scan, metadata, channel, noise_coefs)
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
%     1. f/Pt_volt_f -> deconvolved temperature-gradient wavenumber spectrum:
%          scan = mod_scan_fpo7_volts_to_Tg_spectrum(scan, metadata, channel)
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
%   scan       - struct with:
%                  spectra.f         - frequency vector [Hz], nfreq x 1 or
%                          1 x nfreq (same shape as spectra.Pt_volt_f)
%                  spectra.Pt_volt_f - one scan's raw FP07 channel power
%                          spectrum [V^2/Hz], same shape as spectra.f
%                          (e.g. from mod_scan_get_spectra.m's
%                          scan.spectra.(channel)_volt_f, selected by the
%                          caller for this one channel)
%                  w     - fall speed at this scan's center [m/s], scalar.
%                          Sign does not matter (abs'd internally) - see
%                          mod_scan_fpo7_transfer_function.m for why w=0
%                          is not a meaningful input here.
%                  ktemp - thermal diffusivity of the water at this scan
%                          [m^2/s] (mod_scan_thermal_diffusivity.m, from
%                          scan-center S/T/P)
%   metadata   - metadata struct (from MODsetup_read_yaml.m). Validated up
%                front, via MODsetup_validate_metadata.m, against the full
%                set of PROCESS.CHI values this function AND both
%                sub-calls it makes need - resolving everything the whole
%                chain needs in one prompt-and-reload cycle rather than
%                letting each sub-call discover its own subset piecemeal.
%                Passed straight through to
%                mod_scan_fpo7_volts_to_Tg_spectrum.m
%                (metadata.AFE.(channel).volts_to_C, .electronics_filter,
%                metadata.PROCESS.CHI.time_constant_s, .fall_speed_exponent)
%                and mod_scan_fpo7_cutoff.m (metadata.PROCESS.CHI.
%                noise_adjusted_to_f/.n_smooth_f_spectrum/.sn_min/.n_skip -
%                see those functions for exact fields). Also used directly
%                here:
%                  metadata.PROCESS.CHI.kmin_obs - the low-wavenumber
%                    integration bound [cpm]
%                See MODsetup_metadata_field_registry.m for each field's
%                historical default (shown as the prompt's starting value).
%   channel    - channel name string (e.g. 't1'), selects which
%                metadata.AFE.(channel) to read.
%   noise_coefs - FP07 bench noise floor struct (n0..n3), passed straight
%                through to mod_scan_fpo7_cutoff.m
%
% OUTPUTS
%   scan - same struct, with added:
%     chi_obs    - thermal variance dissipation rate [degC^2/s]. NaN if
%                  the noise-floor cutoff kc does not exceed kmin (no
%                  valid wavenumber range to integrate over - a genuinely
%                  unusable scan for this channel, not a computation
%                  error).
%     chi_obs_kc - the noise-floor cutoff wavenumber used [cpm], or NaN
%                  alongside a NaN chi_obs. Returned for diagnostics/QC,
%                  e.g. checking whether a suspiciously small kc is
%                  dragging chi_obs down for a batch of scans.
%     spectra.k, spectra.Pt_Tg_k, spectra.fc_index - added by the
%                  mod_scan_fpo7_volts_to_Tg_spectrum.m/mod_scan_fpo7_cutoff.m
%                  calls below and left on the returned scan (not
%                  discarded) - the caller (MODprocess_single_L1_to_L2.m)
%                  persists these into L2data.spectra alongside chi_obs.
%                  Present even when chi_obs comes out NaN, since the
%                  deconvolution/cutoff search itself still ran fine.
%
% CALLED BY
%   MODprocess_single_L1_to_L2.m
%
% CALLS
%   MODsetup_validate_metadata.m, mod_scan_fpo7_volts_to_Tg_spectrum.m,
%   mod_scan_fpo7_cutoff.m
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

yaml_file = '';
if isfield(metadata, 'paths') && isfield(metadata.paths, 'setup_yml')
    yaml_file = metadata.paths.setup_yml;
end
metadata = MODsetup_validate_metadata(metadata, yaml_file, ...
    {'kmin_obs', 'time_constant_s', 'fall_speed_exponent', ...
     'noise_adjusted_to_f', 'n_smooth_f_spectrum', 'sn_min', 'n_skip'});

kmin = metadata.PROCESS.CHI.kmin_obs; % cpm

scan.spectra.f = scan.spectra.f(:)';
scan.spectra.Pt_volt_f = scan.spectra.Pt_volt_f(:)';

scan = mod_scan_fpo7_volts_to_Tg_spectrum(scan, metadata, channel);
scan = mod_scan_fpo7_cutoff(scan, metadata, noise_coefs);

k = scan.spectra.k;
Pt_Tg_k = scan.spectra.Pt_Tg_k;
kc = k(scan.spectra.fc_index);

if kc <= kmin
    scan.chi_obs = NaN;
    scan.chi_obs_kc = NaN;
    return
end

krange = k >= kmin & k <= kc;
dk = mean(diff(k), 'omitnan');
scan.chi_obs = 6 * scan.ktemp * dk * sum(Pt_Tg_k(krange), 'omitnan');
scan.chi_obs_kc = kc;

end %end function
