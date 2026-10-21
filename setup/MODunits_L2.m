function u = MODunits_L2()
% MODunits_L2        Part of MOD_fish_processing
%
% u = MODunits_L2()
%
% DESCRIPTION
%   Static registry of every L2data field's units and description
%   (mod_L2_tile_scans.m's output, the empty_L2data shape), one entry per
%   field name - see MODunits_L0.m's own DESCRIPTION for the overall
%   design. Dynamically-named per-channel fields (chi.<channel>_obs,
%   spectra.(channel)_f, ...) are documented once as a *pattern*, not
%   enumerated per possible channel name - a deployment's actual channel
%   set (t1/t2/s1/s2/a1/a2/a3, etc.) varies, same convention
%   mod_L2_tile_scans.m's own header docstring already uses.
%
% OUTPUTS
%   u - struct, one field per L2data field name (dot-path flattened for
%       spectra, e.g. 'spectra_f' for L2data.spectra.f; the turbulence
%       structs nested as in L2data, e.g. u.epsilon.channel_obs). Each value is
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
u.nu = struct('unit', 'm^2/s', 'description', 'Kinematic viscosity at scan center (toolbox/seawater/visc.m) - feeds epsilon (mod_scan_calc_epsilon.m) and chi_mle.');
u.ktemp = struct('unit', 'm^2/s', 'description', 'Thermal diffusivity at scan center (toolbox/seawater/ktemp.m) - only populated when there is FP07 or microconductivity chi, NaN otherwise.');

% --- turbulence, grouped: L2data.<group>.<leaf>, nbscan x 1. A struct has
% no fields when the run has none of its kind. Per-channel leaves are
% <channel>_<variant>, documented once per group as channel_<variant>. ---
u.epsilon.final = struct('unit', 'W/kg', 'description', 'Only when epsilon is computed (no shear probes or no CTD T/S: no field). Per-scan epsilon fed to chi_mle - mean (omitting NaN) across shear channels of whichever variant final_source selects (_mle or _obs_coh_corr).');
u.epsilon.final_source = struct('unit', 'n/a (string)', 'description', 'Which variant final is this run - ''epsilon_mle'' or ''epsilon_co''; written only with final. Resolved once from metadata.PROCESS.EPSILON.epsilon_final_source; an unrecognized value there falls back to ''epsilon_co'', made visible here instead of silent.');
u.epsilon.channel_obs = struct('unit', 'W/kg', 'description', 'Direct-integration epsilon from the raw shear spectrum (eps1_mmp/epsilon2_correct port). Pattern: epsilon.<channel>_obs, one per shear channel with a resolved metadata.AFE.(channel).cal and real CTD T/S.');
u.epsilon.channel_obs_kc = struct('unit', 'cpm', 'description', 'Cutoff wavenumber of the _obs integration. Pattern: epsilon.<channel>_obs_kc.');
u.epsilon.channel_obs_coh_corr = struct('unit', 'W/kg', 'description', 'As _obs, from the coherence-cleaned shear spectrum. Pattern: epsilon.<channel>_obs_coh_corr.');
u.epsilon.channel_obs_coh_corr_kc = struct('unit', 'cpm', 'description', 'Cutoff wavenumber of _obs_coh_corr. Pattern: epsilon.<channel>_obs_coh_corr_kc.');
u.epsilon.channel_mle = struct('unit', 'W/kg', 'description', 'Nasmyth-spectrum MLE-fit epsilon, seeded from _obs_coh_corr. Pattern: epsilon.<channel>_mle.');
u.epsilon.channel_fom_obs_coh_corr = struct('unit', 'dimensionless', 'description', 'Figure of merit (MAD-based log-ratio of observed vs. model spectrum) of the _obs_coh_corr fit against the coherence-cleaned spectrum - lower is a better fit. Pattern: epsilon.<channel>_fom_obs_coh_corr.');
u.epsilon.channel_fom_mle = struct('unit', 'dimensionless', 'description', 'Figure of merit of the MLE fit. Pattern: epsilon.<channel>_fom_mle.');
u.chi.channel_obs = struct('unit', 'degC^2/s', 'description', 'Direct-integration thermal variance dissipation rate. Pattern: chi.<channel>_obs, one per fpo7 channel with both a resolved volts_to_C and real CTD T/SP.');
u.chi.channel_obs_kc = struct('unit', 'cpm', 'description', 'Noise-floor cutoff wavenumber of the _obs integration. Pattern: chi.<channel>_obs_kc.');
u.chi.channel_mle = struct('unit', 'degC^2/s', 'description', 'Batchelor-spectrum MLE-fit chi; NaN where epsilon.final is not finite. Pattern: chi.<channel>_mle.');
u.microconductivity.channel_obs = struct('unit', 'degC^2/s', 'description', 'chi from microconductivity (mod_scan_calc_chi_ucond.m): 6*ktemp*(dT/dC)^2 times the conductivity-gradient spectrum integrated from ucond.kmin_cpm to _obs_kmax. An underestimate - kmax is far below the Batchelor wavenumber (no Alford/Pinkel 2000b correction yet). NaN for a railed scan. Pattern: microconductivity.<channel>_obs, one per microcond channel with a fitted volts_to_S_per_m and real CTD T/SP.');
u.microconductivity.channel_obs_kmax = struct('unit', 'cpm', 'description', 'Upper integration bound of _obs, min(ucond.kmax_cpm, ucond.fmax_hz/abs(w)). Pattern: microconductivity.<channel>_obs_kmax.');
u.qc.channel_coherence_a3_sum = struct('unit', 'Hz (magnitude-squared coherence integrated over frequency)', 'description', 'Band-integrated shear-vs-a3 coherence over coherence_fmin_hz to coherence_fmax_hz, a vibration-contamination diagnostic - not used by the epsilon calculation itself (which uses the full per-frequency coherence). Pattern: qc.<channel>_coherence_a3_sum, one per shear channel with epsilon.');

% --- spectra (shared axes + per-channel patterns) ---
u.spectra_f = struct('unit', 'Hz', 'description', 'Frequency vector, shared across all scans and channels, 1 x nfreq.');
u.spectra_channel_f = struct('unit', 'V^2/Hz (every non-acc channel) or g^2/Hz (accel)', 'description', 'Raw power spectrum. Pattern: spectra.(channel)_f, nbscan x nfreq, one field per configured channel.');
u.spectra_k = struct('unit', 'cpm', 'description', 'Wavenumber matrix, k = f / abs(w) - nbscan x nfreq. Only populated when there is FP07 or microconductivity chi (byproduct of that computation).');
u.spectra_channel_Tg_k = struct('unit', 'degC^2/m /cpm', 'description', 'Deconvolved temperature-gradient wavenumber spectrum. Pattern: spectra.(channel)_Tg_k, one field per fpo7 channel with chi.');
u.spectra_channel_fc_index = struct('unit', 'index (dimensionless)', 'description', 'Noise-floor cutoff index into spectra.f/.k/.(channel)_f. Pattern: spectra.(channel)_fc_index, one field per fpo7 channel with chi.');
u.spectra_channel_dCdz_k = struct('unit', '(S/m)^2/m^2 /cpm', 'description', 'Conductivity-gradient wavenumber spectrum after the gain and electronics response (what microconductivity.<channel>_obs integrates). Pattern: spectra.(channel)_dCdz_k, one field per microcond channel with chi.');
u.spectra_channel_shear_k = struct('unit', 's^-2/cpm', 'description', 'Raw shear wavenumber spectrum. Pattern: spectra.(channel)_shear_k, one field per shear channel.');
u.spectra_channel_shear_co_k = struct('unit', 's^-2/cpm', 'description', 'Coherence-cleaned shear wavenumber spectrum. Same pattern as spectra.(channel)_shear_k.');

% --- provenance (scalars, not per-scan) ---
u.fft_length = struct('unit', 'samples', 'description', 'Welch-segment FFT length used to build every spectrum this L2data holds (setup.yml spectral.fft_length).');
u.fft_segments_per_scan = struct('unit', 'count', 'description', 'Number of Welch segments averaged per scan (setup.yml spectral.fft_segments_per_scan).');
u.dof = struct('unit', 'dimensionless', 'description', 'Spectral degrees of freedom, 1.9*fft_segments_per_scan (Nuttall 1971, processing/scans/mod_scan_dof.m).');
u.Fs_epsi = struct('unit', 'Hz', 'description', 'Epsi sample rate this L2data was tiled at.');
u.N_epsi = struct('unit', 'samples', 'description', 'Scan length in samples, derived from fft_length/fft_segments_per_scan.');
u.scan_step = struct('unit', 'samples', 'description', 'Step between consecutive scan starts (accounts for scan_overlap).');

u.provenance = struct('unit', 'n/a (record)', 'description', 'What this file was made from (MODutil_provenance.m): the L1 file (.files - processed/<run>/L1/<name>.mat, or the L1_from run''s; for profiles_L2 the profiles_L1 Profile####.mat), the yml (.yml) and its SHA-256 when read (.yml_sha256), .run, .survey, .made_utc and the code commit (.code). Paths are relative to the survey folder.');
end %end function
