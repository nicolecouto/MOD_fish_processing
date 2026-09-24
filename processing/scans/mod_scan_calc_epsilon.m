function scan = mod_scan_calc_epsilon(scan, metadata, channel)
% mod_scan_calc_epsilon        Part of MOD_fish_processing
%
% scan = mod_scan_calc_epsilon(scan, metadata, channel)
%
% DESCRIPTION
%   Orchestrates the full per-channel epsilon (turbulent kinetic energy
%   dissipation rate) chain for one shear channel of one scan, mirroring
%   how mod_L2_tile_scans.m already calls mod_scan_calc_chi_obs.m per
%   fpo7 channel - the epsilon analog of that call, called once per shear
%   channel from mod_L2_tile_scans.m's per-scan loop. In order (matching
%   MOD_fish_lib's get_scan_spectra.m: coherence -> epsilon -> chi):
%
%     1. mod_scan_shear_volts_to_shear_spectrum.m - transfer function
%        deconvolution, raw shear wavenumber spectrum (Ps_shear_k) and the
%        intermediate velocity spectrum (Ps_velocity_f) needed by step 3.
%     2. mod_scan_shear_accel_coherence.m - coherence with accelerometer
%        channel a3, for the coherence-cleaned spectrum built here (step
%        3) - not itself a spectra.* field the direct-integration/MLE
%        functions read directly.
%     3. Ps_velocity_co_f = Ps_velocity_f .* (1 - Cxy); wavenumber-convert
%        it the same way step 1 did, into spectra.Ps_shear_co_k. Small
%        enough (2 lines) to inline here rather than its own file - see
%        mod_scan_shear_volts_to_shear_spectrum.m's DESCRIPTION for why
%        this step lives downstream of it rather than inside it.
%     4. mod_scan_calc_epsilon_obs.m - direct-integration epsilon, from
%        both the raw and coherence-cleaned spectra.
%     5. mod_scan_calc_epsilon_mle.m - Nasmyth-spectrum MLE fit epsilon,
%        from the coherence-cleaned spectrum, seeded by step 4's
%        epsilon_obs_coh_corr.
%     6. mod_scan_calc_fom.m - figure of merit for both epsilon_obs_coh_corr and
%        epsilon_mle, comparing the coherence-cleaned spectrum against a
%        Nasmyth model spectrum evaluated at each.
%
% INPUTS
%   scan       - struct with:
%                  spectra.f              - frequency vector [Hz]
%                  spectra.Ps_volt_f      - this channel's raw shear power
%                        spectrum [V^2/Hz] (e.g. mod_scan_get_spectra.m's
%                        scan.spectra.(channel)_volt_f, selected by the
%                        caller for this one channel)
%                  epsi.(channel)_volt, epsi.a3_g - raw time series, for
%                        mod_scan_shear_accel_coherence.m
%                  w                      - fall speed [m/s]
%                  nu                     - kinematic viscosity [m^2/s]
%   metadata   - metadata struct (from MODsetup_read_yaml.m). Passed
%                through, whole, to every sub-call below - see each one's
%                own header for the specific fields it reads.
%   channel    - shear channel name string (e.g. 's1').
%
% OUTPUTS
%   scan - same struct, with added: spectra.k, spectra.Ps_velocity_f,
%     spectra.Ps_shear_k, spectra.Ps_shear_co_k (absent if this
%     scan/channel had no usable coherence - see
%     mod_scan_shear_accel_coherence.m), spectra.(channel)_coh_a3(_sum),
%     epsilon_obs, epsilon_obs_kc, epsilon_obs_coh_corr, epsilon_obs_coh_corr_kc,
%     epsilon_mle, fom, fom_mle. fom/fom_mle are NaN when their underlying
%     epsilon estimate is NaN or spectra.Ps_shear_co_k is absent.
%
% CALLED BY
%   mod_L2_tile_scans.m
%
% CALLS
%   mod_scan_shear_volts_to_shear_spectrum.m,
%   mod_scan_shear_accel_coherence.m, mod_scan_calc_epsilon_obs.m,
%   mod_scan_calc_epsilon_mle.m, mod_scan_calc_fom.m,
%   nasmyth_spectrum.m, processing/scans/mod_scan_dof.m,
%   MODsetup_validate_metadata.m
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

yaml_file = '';
if isfield(metadata, 'paths') && isfield(metadata.paths, 'setup_yml')
    yaml_file = metadata.paths.setup_yml;
end
metadata = MODsetup_validate_metadata(metadata, yaml_file, {'epsilon_kmin_obs', 'fft_segments_per_scan'});

scan = mod_scan_shear_volts_to_shear_spectrum(scan, metadata, channel);
scan = mod_scan_shear_accel_coherence(scan, metadata, channel);

coh_field = [channel '_coh_a3'];
if isfield(scan.spectra, coh_field) && ~isempty(scan.spectra.(coh_field))
    Cxy = scan.spectra.(coh_field);
    Ps_velocity_co_f = scan.spectra.Ps_velocity_f .* (1 - Cxy);
    k = scan.spectra.k;
    scan.spectra.Ps_shear_co_k = (2*pi*k).^2 .* Ps_velocity_co_f * abs(scan.w);
end

scan = mod_scan_calc_epsilon_obs(scan, metadata);
scan = mod_scan_calc_epsilon_mle(scan, metadata);

dof = mod_scan_dof(metadata.PROCESS.fft_segments_per_scan);
kmin = metadata.PROCESS.EPSILON.kmin_obs;
k = scan.spectra.k;

scan.fom = NaN;
scan.fom_mle = NaN;
if isfield(scan.spectra, 'Ps_shear_co_k') && ~isempty(scan.spectra.Ps_shear_co_k) ...
        && isfinite(scan.epsilon_obs_coh_corr) && isfinite(scan.epsilon_obs_coh_corr_kc)
    klim = [kmin, scan.epsilon_obs_coh_corr_kc];
    Pmodel_co = nasmyth_spectrum(scan.epsilon_obs_coh_corr, scan.nu, k);
    scan.fom = mod_scan_calc_fom(k, scan.spectra.Ps_shear_co_k, Pmodel_co, klim, dof);

    if isfinite(scan.epsilon_mle)
        Pmodel_mle = nasmyth_spectrum(scan.epsilon_mle, scan.nu, k);
        scan.fom_mle = mod_scan_calc_fom(k, scan.spectra.Ps_shear_co_k, Pmodel_mle, klim, dof);
    end
end

end %end function
