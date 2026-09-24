function scan = mod_scan_shear_volts_to_shear_spectrum(scan, metadata, channel)
% mod_scan_shear_volts_to_shear_spectrum        Part of MOD_fish_processing
%
% scan = mod_scan_shear_volts_to_shear_spectrum(scan, metadata, channel)
%
% DESCRIPTION
%   Converts one scan's raw shear channel voltage power spectrum into a
%   wavenumber shear spectrum [s^-2/cpm] - the shared first stage both
%   mod_scan_calc_epsilon_obs.m (direct integration) and
%   mod_scan_calc_epsilon_mle.m (Nasmyth MLE fit) need before they diverge
%   on what to do with it. Mirrors mod_scan_fpo7_volts_to_Tg_spectrum.m's
%   role for the chi chain, ported from steps 3-7 of MOD_fish_lib's
%   mod_efe_scan_epsilon.m:
%
%     1. Deconvolve the probe's own dynamic response (Oakey) AND the AFE's
%        fixed electronics/ADC response (charge-amp x sinc^4, resolved
%        once per deployment by MODsetup_define_filters.m -> see
%        metadata.AFE.(channel).electronics_filter below):
%          H_total = electronics_filter .* mod_scan_shear_transfer_function(f, w, lc)
%     2. Ps_volt_f (raw volts^2/Hz) -> velocity frequency spectrum,
%        via the probe's bench-measured sensitivity Sv [V/(rad/s)] and
%        gravity g (Oakey's shear-probe convention - the probe measures a
%        cross-stream velocity fluctuation referenced to gravity, not a
%        directly dimensionless voltage-to-velocity gain):
%          Ps_velocity_f = (2*g / (Sv*abs(w)))^2 * Ps_volt_f ./ H_total
%     3. Convert to a shear wavenumber spectrum:
%          k = f / abs(w)
%          Ps_shear_k = (2*pi*k).^2 .* Ps_velocity_f .* abs(w)
%
%   Also leaves the intermediate Ps_velocity_f on the returned scan (not
%   discarded) - mod_scan_shear_accel_coherence.m's caller
%   (mod_scan_calc_epsilon.m) needs it to build the coherence-cleaned
%   spectrum Ps_shear_co_k, which this function does not itself compute
%   (unlike the FP07 chain, shear's spectrum has two variants - raw and
%   coherence-cleaned - built from the same Ps_velocity_f by a step
%   downstream of this one).
%
% INPUTS
%   scan       - struct with:
%                  spectra.f       - frequency vector [Hz], nfreq x 1 or
%                        1 x nfreq (same shape as spectra.Ps_volt_f)
%                  spectra.Ps_volt_f - one scan's raw shear channel power
%                        spectrum [V^2/Hz], same shape as spectra.f (e.g.
%                        from mod_scan_get_spectra.m's
%                        scan.spectra.(channel)_volt_f, selected by the
%                        caller for this one channel)
%                  w               - fall speed at this scan's center
%                        [m/s], scalar. Sign does not matter (abs'd
%                        internally throughout) - matches
%                        mod_scan_fpo7_transfer_function.m's convention.
%   metadata   - metadata struct (from MODsetup_read_yaml.m). Uses:
%                  metadata.AFE.(channel).cal - shear probe's bench
%                    sensitivity Sv [V/(rad/s)] (MODsetup_read_yaml.m's
%                    existing shear-probe calibration lookup)
%                  metadata.AFE.(channel).electronics_filter (optional) -
%                    AFE electronics/ADC transfer function, magnitude-
%                    squared, same shape as spectra.f, from
%                    MODsetup_define_filters.m. Defaults to 1 (no
%                    correction) if metadata.AFE.(channel) has no such
%                    field - same convention as
%                    mod_scan_fpo7_volts_to_Tg_spectrum.m.
%                  metadata.PROCESS.EPSILON.oakey_lc_m - shear probe's
%                    spatial cutoff wavelength [m], passed straight
%                    through to mod_scan_shear_transfer_function.m.
%                Validated at the top of this function via
%                MODsetup_validate_metadata.m - prompted for (and offered
%                to be saved into setup.yml) if not already present; see
%                MODsetup_metadata_field_registry.m for its historical
%                default.
%   channel    - channel name string (e.g. 's1'), selects which
%                metadata.AFE.(channel) to read.
%
% OUTPUTS
%   scan - same struct, with added:
%     spectra.k             - wavenumber vector [cpm], same shape as
%                              spectra.f, k = f / abs(w)
%     spectra.Ps_velocity_f - deconvolved velocity frequency spectrum,
%                              same shape as spectra.f - kept for the
%                              coherence-cleaning step downstream (see
%                              DESCRIPTION), not itself a final product.
%     spectra.Ps_shear_k    - shear wavenumber spectrum, same shape as
%                              spectra.k
%
% CALLED BY
%   mod_scan_calc_epsilon.m
%
% CALLS
%   MODsetup_validate_metadata.m, mod_scan_shear_transfer_function.m
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

yaml_file = '';
if isfield(metadata, 'paths') && isfield(metadata.paths, 'setup_yml')
    yaml_file = metadata.paths.setup_yml;
end
metadata = MODsetup_validate_metadata(metadata, yaml_file, {'oakey_lc_m'});

G = 9.81; % gravity [m/s^2] - Oakey's shear-probe voltage-to-velocity convention
Sv = metadata.AFE.(channel).cal;

electronics_filter = 1;
if isfield(metadata.AFE.(channel), 'electronics_filter')
    electronics_filter = metadata.AFE.(channel).electronics_filter;
end

lc = metadata.PROCESS.EPSILON.oakey_lc_m;

f = scan.spectra.f(:)';
Ps_volt_f = scan.spectra.Ps_volt_f(:)';
electronics_filter = electronics_filter(:)';
w = scan.w;

H_oakey = mod_scan_shear_transfer_function(f, w, lc);
H_total = electronics_filter .* H_oakey;

Ps_velocity_f = ((2*G / (Sv*abs(w)))^2) .* Ps_volt_f ./ H_total;

k = f / abs(w);
Ps_shear_k = (2*pi*k).^2 .* Ps_velocity_f * abs(w);

scan.spectra.k = k;
scan.spectra.Ps_velocity_f = Ps_velocity_f;
scan.spectra.Ps_shear_k = Ps_shear_k;

end %end function
