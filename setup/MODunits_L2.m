function u = MODunits_L2()
% MODunits_L2        Part of MOD_fish_processing
%
% u = MODunits_L2()
%
% DESCRIPTION
%   Static registry of every L2data field's units and description
%   (mod_L2_tile_scans.m's output, the empty_L2data shape), one entry per
%   field name - see MODunits_L0.m's own DESCRIPTION for the overall
%   design. Dynamically-named per-channel fields (chi_obs.(channel),
%   spectra.(channel)_f, ...) are documented once as a *pattern*, not
%   enumerated per possible channel name - a deployment's actual channel
%   set (t1/t2/s1/s2/a1/a2/a3, etc.) varies, same convention
%   mod_L2_tile_scans.m's own header docstring already uses.
%
% OUTPUTS
%   u - struct, one field per L2data field name (dot-path flattened for
%       nested ones, e.g. 'spectra_f' for L2data.spectra.f). Each value is
%       struct('unit', ..., 'description', ...). All top-level numeric
%       fields are nbscan x 1 unless noted otherwise.
%
% CALLED BY
%   (none yet - reference registry)
%
% CALLS
%   (none)
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

% --- per-scan scalars ---
u.dnum = struct('unit', 'MATLAB datenum', 'description', 'Scan center time.');
u.pressure = struct('unit', 'dbar', 'description', 'CTD pressure at scan center, interpolated from ctd.P.');
u.w = struct('unit', 'm/s, positive during descent', 'description', 'Fall speed at scan center, interpolated from ctd.dzdt.');
u.temperature = struct('unit', 'degC', 'description', 'CTD in-situ temperature at scan center, interpolated from ctd.T. Only populated with a real onboard CTD (have_ctd_ts) - NaN otherwise.');
u.salinity = struct('unit', 'psu (PSS-78)', 'description', 'CTD Practical Salinity (ctd.SP) at scan center, interpolated - same have_ctd_ts condition as temperature.');
u.SR = struct('unit', 'g/kg', 'description', 'Reference Salinity at scan center, gsw_SR_from_SP(salinity) (interpolated from ctd.SR the same way) - see docs/concepts/units_and_seawater.md for why SR (not exact Absolute Salinity) is used throughout.');
u.nu = struct('unit', 'm^2/s', 'description', 'Kinematic viscosity at scan center (toolbox/seawater/visc.m) - feeds epsilon (modProcess_L2_calc_epsilon.m) and chi_mle.');
u.ktemp = struct('unit', 'm^2/s', 'description', 'Thermal diffusivity at scan center (toolbox/seawater/ktemp.m) - only populated when chi_obs_channels is non-empty, NaN otherwise.');
u.epsilon_final = struct('unit', 'W/kg', 'description', 'Per-scan epsilon actually fed to chi_mle - mean (omitting NaN) across shear channels of whichever variant epsilon_final_source selects (epsilon_mle or epsilon_obs_co).');
u.epsilon_final_source = struct('unit', 'n/a (string)', 'description', 'Which variant epsilon_final actually is this run - ''epsilon_mle'', ''epsilon_co'', or '''' if epsilon was never computed at all. Resolved once from metadata.PROCESS.EPSILON.epsilon_final_source; an unrecognized/invalid value there falls back to ''epsilon_co'', made visible here instead of silent.');

% --- per-channel patterns (chi, fpo7 channels) ---
u.chi_obs = struct('unit', 'degC^2/s', 'description', 'Direct-integration thermal variance dissipation rate. Pattern: chi_obs.(channel), one field per fpo7 channel with both a resolved volts_to_C AND real CTD T/SP - struct has no fields at all otherwise.');
u.chi_obs_kc = struct('unit', 'cpm', 'description', 'Noise-floor cutoff wavenumber used for chi_obs''s integration. Same pattern as chi_obs.');
u.chi_mle = struct('unit', 'degC^2/s', 'description', 'Batchelor-spectrum MLE-fit chi. Same pattern as chi_obs; additionally requires a finite per-scan epsilon.');

% --- per-channel patterns (epsilon, shear channels) ---
u.epsilon_obs = struct('unit', 'W/kg', 'description', 'Direct-integration epsilon from the raw shear spectrum (eps1_mmp/epsilon2_correct port). Pattern: epsilon_obs.(channel), one field per shear channel with a resolved metadata.AFE.(channel).cal.');
u.epsilon_obs_kc = struct('unit', 'cpm', 'description', 'Cutoff wavenumber used for epsilon_obs''s integration. Same pattern as epsilon_obs.');
u.epsilon_obs_co = struct('unit', 'W/kg', 'description', 'Same as epsilon_obs, but from the coherence-cleaned shear spectrum. Same pattern.');
u.epsilon_obs_co_kc = struct('unit', 'cpm', 'description', 'Cutoff wavenumber for epsilon_obs_co. Same pattern.');
u.epsilon_mle = struct('unit', 'W/kg', 'description', 'Nasmyth-spectrum MLE-fit epsilon, seeded from epsilon_obs_co. Same pattern.');
u.fom = struct('unit', 'dimensionless', 'description', 'Figure of merit (MAD-based log-ratio of observed vs. model spectrum) for the direct-integration epsilon fit. Same pattern - lower is a better fit.');
u.fom_mle = struct('unit', 'dimensionless', 'description', 'Figure of merit for the MLE epsilon fit. Same pattern.');
u.coherence_sum = struct('unit', 'dimensionless (0-1, magnitude-squared coherence)', 'description', 'Band-integrated shear-vs-accelerometer coherence, a contamination diagnostic - not consumed by the epsilon calculation itself (which uses the full per-frequency coherence vector). Same pattern.');

% --- spectra (shared axes + per-channel patterns) ---
u.spectra_f = struct('unit', 'Hz', 'description', 'Frequency vector, shared across all scans and channels, 1 x nfreq.');
u.spectra_channel_f = struct('unit', 'V^2/Hz (fpo7/shear) or g^2/Hz (accel)', 'description', 'Raw power spectrum. Pattern: spectra.(channel)_f, nbscan x nfreq, one field per configured shear/fpo7/acc channel.');
u.spectra_k = struct('unit', 'cpm', 'description', 'Wavenumber matrix, k = f / abs(w) - nbscan x nfreq. Only populated when chi_obs_channels is non-empty (byproduct of that computation).');
u.spectra_channel_Tg_k = struct('unit', 'degC^2/m /cpm', 'description', 'Deconvolved temperature-gradient wavenumber spectrum. Pattern: spectra.(channel)_Tg_k, one field per fpo7 channel in chi_obs_channels.');
u.spectra_channel_fc_index = struct('unit', 'index (dimensionless)', 'description', 'Noise-floor cutoff index into spectra.f/.k/.(channel)_f. Pattern: spectra.(channel)_fc_index, one field per fpo7 channel in chi_obs_channels.');
u.spectra_channel_shear_k = struct('unit', 's^-2/cpm', 'description', 'Raw shear wavenumber spectrum. Pattern: spectra.(channel)_shear_k, one field per shear channel.');
u.spectra_channel_shear_co_k = struct('unit', 's^-2/cpm', 'description', 'Coherence-cleaned shear wavenumber spectrum. Same pattern as spectra.(channel)_shear_k.');

% --- provenance (scalars, not per-scan) ---
u.fft_length = struct('unit', 'samples', 'description', 'Welch-segment FFT length used to build every spectrum this L2data holds (setup.yml spectral.fft_length).');
u.fft_segments_per_scan = struct('unit', 'count', 'description', 'Number of Welch segments averaged per scan (setup.yml spectral.fft_segments_per_scan).');
u.dof = struct('unit', 'dimensionless', 'description', 'Spectral degrees of freedom, 1.9*fft_segments_per_scan (Nuttall 1971, processing/scans/mod_scan_dof.m).');
u.Fs_epsi = struct('unit', 'Hz', 'description', 'Epsi sample rate this L2data was tiled at.');
u.N_epsi = struct('unit', 'samples', 'description', 'Scan length in samples, derived from fft_length/fft_segments_per_scan.');
u.scan_step = struct('unit', 'samples', 'description', 'Step between consecutive scan starts (accounts for scan_overlap).');

end %end function
