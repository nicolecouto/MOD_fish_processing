function u = MODunits_L3()
% MODunits_L3        Part of MOD_fish_processing
%
% u = MODunits_L3()
%
% DESCRIPTION
%   Static registry of every gridded.mat field's units and description
%   (MODprocess_grid.m's output), one entry per field name - see
%   MODunits_L0.m's own DESCRIPTION for the overall design. The
%   turbulence structs (epsilon, chi, microconductivity, kc, qc) and fluor are nested
%   here as in the grid, their per-channel leaves (<channel>_<variant>:
%   s1_obs, t2_mle, ...) documented once as channel_<variant>.
%   MODprocess_grid.m copies the entries for the fields a grid has into
%   gridded.variables, so a viewer can loop over them.
%
% OUTPUTS
%   u - struct, one field per grid field name. Each value is
%       struct('unit', ..., 'description', ...). nz = numel(gridded.z),
%       ncast = number of casts (columns).
%
% CALLED BY
%   MODprocess_grid.m
%
% CALLS
%   (none)
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

% --- axes ---
u.z = struct('unit', 'm, positive down', 'description', 'Depth bin centers, nz x 1: (k - 0.5) * z_bin_m. A bin holds depths from (k-1)*z_bin_m to k*z_bin_m: L1 ctd.z for the CTD samples, -gsw_z_from_p(pressure, metadata.PROCESS.latitude) for the scans (L1 ctd.z uses a GPS latitude when there is one - a difference far below a bin).');
u.z_bin_m = struct('unit', 'm', 'description', 'Depth bin size (grid.z_bin_m in the yml).');
u.grid_version = struct('unit', 'n/a', 'description', 'Version of MODprocess_grid.m that made the grid (2: with C; 3: GPS latitude/longitude per cast, no all-NaN epsilon_final; 4: first fix for Epsi downcasts from the ship; 5: long-form names, every L2 per-scan value, attitude and height above bottom; 6: microconductivity chi; 7: turbulence grouped in epsilon, chi, microconductivity, qc; 8: microconductivity chi_obs, chi_tot, eps_chi, n2; 9: reused casts keep every turbulence group; 10: each scan fills its footprint, n_scans counts the scans covering a bin; 11: L2''s fs_afe, n_samples_scan_afe; 12: fluor, L2''s cutoffs in kc, only the groups the data have; 13: qc.<accel>_std from L1 accel). A grid from another version is rebinned from scratch.');
u.latitude = struct('unit', 'degrees N', 'description', 'From the L1 GPS fixes (gps.latitude) during the cast, 1 x ncast: the first fix for an Epsi downcast from the ship (platform ship, fish_flag EPSI - it free falls where it was dropped), else their mean; NaN if the cast has none.');
u.longitude = struct('unit', 'degrees E', 'description', 'From the L1 GPS fixes (gps.longitude) during the cast, 1 x ncast, as latitude; NaN if the cast has none. A plain mean, so wrong for a cast that crosses 180 deg.');
u.time = struct('unit', 'MATLAB datenum', 'description', 'Mean time of the cast''s CTD samples, 1 x ncast (the middle of the cast if it has none).');
u.cast_start = struct('unit', 'MATLAB datenum', 'description', 'Cast start time from the cast table (casts.mat dnum_start), 1 x ncast - what a column is keyed by.');
u.cast_end = struct('unit', 'MATLAB datenum', 'description', 'Cast end time from the cast table (dnum_end), 1 x ncast.');
u.cast_direction = struct('unit', 'n/a (cellstr)', 'description', '''down'' or ''up'', 1 x ncast.');
u.cast_complete = struct('unit', 'logical', 'description', 'false for a cast still in progress (it runs into the end of the pressure record), 1 x ncast. Its column is rebinned every call until it ends.');
u.profile_number = struct('unit', 'n/a', 'description', 'The cast''s number in the cast table (Profile####.mat), 1 x ncast. Can change as the record grows - use cast_start to match casts.');

% --- CTD: mean of every L1 CTD sample in the bin ---
u.pressure = struct('unit', 'dbar', 'description', 'Mean CTD pressure (ctd.P) in the bin, nz x ncast.');
u.temperature = struct('unit', 'degC', 'description', 'Mean CTD in-situ temperature (ctd.T) in the bin, nz x ncast.');
u.conductivity = struct('unit', 'S/m', 'description', 'Mean CTD conductivity (ctd.C) in the bin, nz x ncast. S/m, not mS/cm.');
u.salinity_practical = struct('unit', 'psu (PSS-78)', 'description', 'Mean Practical Salinity (ctd.SP) in the bin, nz x ncast. Not despiked or smoothed.');
u.salinity_reference = struct('unit', 'g/kg', 'description', 'Mean Reference Salinity (ctd.SR = 35.16504/35 * SP) in the bin, nz x ncast. Used in place of Absolute Salinity throughout (docs/concepts/units_and_seawater.md).');
u.temperature_conservative = struct('unit', 'degC', 'description', 'Mean Conservative Temperature (ctd.CT, from salinity_reference) in the bin, nz x ncast.');
u.sigma0 = struct('unit', 'kg/m^3', 'description', 'Mean potential density anomaly referenced to 0 dbar (ctd.sigma0) in the bin, nz x ncast.');
u.fall_speed = struct('unit', 'm/s, positive during descent', 'description', 'Mean fall speed (ctd.dzdt) in the bin, nz x ncast.');

% --- other L1 records: mean of the samples in the bin, each at the CTD depth at its time ---
u.pitch = struct('unit', 'deg', 'description', 'Mean VectorNav pitch (vnav.pitch, nose up positive) in the bin, nz x ncast.');
u.tilt = struct('unit', 'deg', 'description', 'Mean VectorNav tilt (vnav.tilt: 0 = long axis straight up, 90 = horizontal, 180 = straight down) in the bin, nz x ncast.');
u.roll = struct('unit', 'deg', 'description', 'Circular mean of VectorNav roll (vnav.roll, -180 to 180) in the bin, nz x ncast: atan2 of the mean sine and cosine, since roll wraps at +-180.');
u.height_above_bottom = struct('unit', 'm', 'description', 'Mean altimeter height above bottom in the bin (isap.hab, or alt.hab without an isap), nz x ncast. Samples pegged at the altimeter''s maximum range (no bottom in range: the record''s largest dst, seen more than once - 120 m for the ISA500) are left out, so a bin with no bottom in range is NaN.');
u.fluor.bb = struct('unit', 'raw (ECOP, as L1)', 'description', 'Mean of the L1 fluor.bb (ECOP backscatter) samples in the bin, each at the CTD depth at its time, nz x ncast. Only when the L1 files have fluor.');
u.fluor.chla = struct('unit', 'raw (ECOP, as L1)', 'description', 'Mean of the L1 fluor.chla (ECOP chlorophyll-a) samples in the bin, as fluor.bb.');
u.fluor.fdom = struct('unit', 'raw (ECOP, as L1)', 'description', 'Mean of the L1 fluor.fDOM (ECOP fDOM) samples in the bin, as fluor.bb.');

% --- scans: mean of the L2 scans whose footprint covers the bin ---
u.n_scans = struct('unit', 'count', 'description', 'Number of L2 scans whose footprint (the depths the scan spans) covers the bin, nz x ncast. 0 where no scan does (the scan fields are NaN there).');
u.viscosity_kinematic = struct('unit', 'm^2/s', 'description', 'Mean of the scans'' kinematic viscosity (L2 nu) in the bin, nz x ncast.');
u.diffusivity_thermal_molecular = struct('unit', 'm^2/s', 'description', 'Mean of the scans'' molecular thermal diffusivity (L2 ktemp) in the bin, nz x ncast. Only with FP07 or microconductivity chi (L2 has it only for chi).');

% --- turbulence, grouped as in L2: gridded.<group>.<leaf>, each leaf the mean
% of the scans' values in the bin, nz x ncast. Per-channel leaves are
% <channel>_<variant> (s1_obs, t2_mle, ...), documented once per group as
% channel_<variant>. A group is there only when some cast has a value in it
% (an FCTD has no epsilon, chi or qc; an Epsi no microconductivity). kc holds
% the cutoff wavenumbers, named for the value they bound. ---
u.epsilon.final = struct('unit', 'W/kg', 'description', 'Mean of the scans'' epsilon.final in the bin, nz x ncast. Which epsilon it is: epsilon.final_source.');
u.epsilon.final_source = struct('unit', 'n/a (cellstr)', 'description', 'L2''s epsilon.final_source for the cast''s scans (''epsilon_mle'' or ''epsilon_co''), 1 x ncast; '''' for a cast without epsilon.');
u.epsilon.channel_obs = struct('unit', 'W/kg', 'description', 'Direct integration of the raw shear spectrum, one shear channel. Pattern: epsilon.<channel>_obs, e.g. epsilon.s1_obs.');
u.epsilon.channel_obs_coh_corr = struct('unit', 'W/kg', 'description', 'As _obs, from the coherence-cleaned shear spectrum. Pattern: epsilon.<channel>_obs_coh_corr.');
u.epsilon.channel_mle = struct('unit', 'W/kg', 'description', 'Nasmyth-spectrum MLE fit. Pattern: epsilon.<channel>_mle.');
u.epsilon.channel_fom_obs_coh_corr = struct('unit', 'dimensionless', 'description', 'Figure of merit of the _obs_coh_corr fit against the cleaned spectrum (lower is better). Pattern: epsilon.<channel>_fom_obs_coh_corr.');
u.epsilon.channel_fom_mle = struct('unit', 'dimensionless', 'description', 'Figure of merit of the MLE fit. Pattern: epsilon.<channel>_fom_mle.');
u.chi.channel_obs = struct('unit', 'degC^2/s', 'description', 'Direct integration of the deconvolved temperature-gradient spectrum, one fpo7 channel. Pattern: chi.<channel>_obs, e.g. chi.t1_obs.');
u.chi.channel_mle = struct('unit', 'degC^2/s', 'description', 'Batchelor-spectrum MLE fit. Pattern: chi.<channel>_mle.');
u.microconductivity.chi_obs = struct('unit', 'degC^2/s', 'description', 'Measured chi from the microconductivity probe (an underestimate; see MODunits_L2.m).');
u.microconductivity.chi_tot = struct('unit', 'degC^2/s', 'description', 'chi_obs corrected for the unresolved part (Alford and Pinkel 2000b), averaged after correcting each scan.');
u.microconductivity.eps_chi = struct('unit', 'W/kg', 'description', 'Epsilon implied by chi_obs (Alford and Pinkel 2000b), averaged after correcting each scan.');
u.microconductivity.n2 = struct('unit', 's^-2', 'description', 'Mean of the scans'' N^2 used for chi_tot/eps_chi.');
u.kc.channel_obs = struct('unit', 'cpm', 'description', 'Cutoff wavenumber of epsilon.<channel>_obs (a shear channel) or chi.<channel>_obs (an fpo7 channel, its noise-floor cutoff). Pattern: kc.<channel>_obs, e.g. kc.s1_obs, kc.t1_obs.');
u.kc.channel_obs_coh_corr = struct('unit', 'cpm', 'description', 'Cutoff wavenumber of epsilon.<channel>_obs_coh_corr. Pattern: kc.<channel>_obs_coh_corr.');
u.kc.channel_chi_obs = struct('unit', 'cpm', 'description', 'Upper integration bound of microconductivity.chi_obs, <channel> the microconductivity probe''s. Pattern: kc.<channel>_chi_obs, e.g. kc.c1_chi_obs.');
u.qc.channel_coherence_a1_sum = struct('unit', 'Hz', 'description', 'Shear-a1 coherence integrated over coherence_fmin_hz to coherence_fmax_hz (a vibration-contamination diagnostic), one shear channel. Pattern: qc.<channel>_coherence_a1_sum.');
u.qc.channel_coherence_a2_sum = struct('unit', 'Hz', 'description', 'As _coherence_a1_sum, against a2. Pattern: qc.<channel>_coherence_a2_sum.');
u.qc.channel_coherence_a3_sum = struct('unit', 'Hz', 'description', 'Shear-a3 coherence integrated over coherence_fmin_hz to coherence_fmax_hz (a vibration-contamination diagnostic; a3 is the accelerometer epsilon''s coh_corr uses), one shear channel. Pattern: qc.<channel>_coherence_a3_sum.');
u.qc.channel_std = struct('unit', 'g', 'description', 'Mean of the L1 accel.<channel>_std windows (std of epsi.<channel>_g over l1.accel_std_s) in the bin, each at the CTD depth at its time, nz x ncast - down and up casts both. Pattern: qc.<channel>_std, e.g. qc.a3_std.');

% --- record ---
u.variables = struct('unit', 'n/a (struct array)', 'description', 'name, unit and description of each gridded field present (from this registry).');
u.source = struct('unit', 'n/a (string)', 'description', '''file'' (L1/L2 files, through time_index.mat) or ''profile'' (profiles_L1/ and profiles_L2/).');
u.source_stamp = struct('unit', 'n/a (cell)', 'description', 'Per cast: its end time, complete flag, the yml latitude, whether its position is the first GPS fix, and the times of the files it was binned from. A column is rebinned when this changes.');
u.provenance = struct('unit', 'n/a (record)', 'description', 'What this grid was made from (MODutil_provenance.m): the L1 and L2 (or profile) files, the run yml and its SHA-256, the run, when, and the code version.');
end %end function
