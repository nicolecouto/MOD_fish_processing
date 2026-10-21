function u = MODunits_L3()
% MODunits_L3        Part of MOD_fish_processing
%
% u = MODunits_L3()
%
% DESCRIPTION
%   Static registry of every grid.mat field's units and description
%   (MODprocess_grid.m's output), one entry per field name - see
%   MODunits_L0.m's own DESCRIPTION for the overall design. Per-channel
%   fields (<L2 name>_<channel>: epsilon_mle_s1, chi_obs_t2, ...) are
%   documented once as a pattern, <L2 name>_channel.
%   MODprocess_grid.m copies the entries for the fields a grid has into
%   grid.variables, so a viewer can loop over them.
%
% OUTPUTS
%   u - struct, one field per grid field name. Each value is
%       struct('unit', ..., 'description', ...). nz = numel(grid.z),
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
u.grid_version = struct('unit', 'n/a', 'description', 'Version of MODprocess_grid.m that made the grid (2: with C; 3: GPS latitude/longitude per cast, no all-NaN epsilon_final; 4: first fix for Epsi downcasts from the ship; 5: long-form names, every L2 per-scan value, attitude and height above bottom; 6: microconductivity chi). A grid from another version is rebinned from scratch.');
u.latitude = struct('unit', 'degrees N', 'description', 'From the L1 GPS fixes (gps.latitude) during the cast, 1 x ncast: the first fix for an Epsi downcast from the ship (platform ship, fish_flag EPSI - it free falls where it was dropped), else their mean; NaN if the cast has none.');
u.longitude = struct('unit', 'degrees E', 'description', 'From the L1 GPS fixes (gps.longitude) during the cast, 1 x ncast, as latitude; NaN if the cast has none. A plain mean, so wrong for a cast that crosses 180 deg.');
u.time = struct('unit', 'MATLAB datenum', 'description', 'Mean time of the cast''s CTD samples, 1 x ncast (the middle of the cast if it has none).');
u.cast_start = struct('unit', 'MATLAB datenum', 'description', 'Cast start time from the cast table (casts.mat dnum_start), 1 x ncast - what a column is keyed by.');
u.cast_end = struct('unit', 'MATLAB datenum', 'description', 'Cast end time from the cast table (dnum_end), 1 x ncast.');
u.cast_direction = struct('unit', 'n/a (cellstr)', 'description', '''down'' or ''up'', 1 x ncast.');
u.cast_complete = struct('unit', 'logical', 'description', 'false for a cast still in progress (it runs into the end of the pressure record), 1 x ncast. Its column is rebinned every call until it ends.');
u.profile_number = struct('unit', 'n/a', 'description', 'The cast''s number in the cast table (Profile####.mat), 1 x ncast. Can change as the record grows - use cast_start to match casts.');
u.epsilon_final_source = struct('unit', 'n/a (cellstr)', 'description', 'L2''s epsilon_final_source for the cast''s scans (''epsilon_mle'' or ''epsilon_co''): which epsilon epsilon_final is, 1 x ncast; '''' for a cast without epsilon.');

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

% --- scans: mean of the L2 scans whose center is in the bin ---
u.n_scans = struct('unit', 'count', 'description', 'Number of L2 scans whose center is in the bin, nz x ncast. 0 where there is no scan (the scan fields are NaN there).');
u.viscosity_kinematic = struct('unit', 'm^2/s', 'description', 'Mean of the scans'' kinematic viscosity (L2 nu) in the bin, nz x ncast.');
u.diffusivity_thermal_molecular = struct('unit', 'm^2/s', 'description', 'Mean of the scans'' molecular thermal diffusivity (L2 ktemp) in the bin, nz x ncast. Only with fpo7 channels (L2 has it only for chi).');
u.epsilon_final = struct('unit', 'W/kg', 'description', 'Mean of the scans'' epsilon_final in the bin, nz x ncast. Which epsilon it is: epsilon_final_source.');
u.epsilon_obs_channel = struct('unit', 'W/kg', 'description', 'Mean of the scans'' epsilon_obs (direct integration of the raw shear spectrum) for one shear channel in the bin, nz x ncast. Pattern: epsilon_obs_<channel>, e.g. epsilon_obs_s1.');
u.epsilon_obs_kc_channel = struct('unit', 'cpm', 'description', 'Mean of the scans'' epsilon_obs integration cutoff wavenumber, nz x ncast. Pattern: epsilon_obs_kc_<channel>.');
u.epsilon_obs_coh_corr_channel = struct('unit', 'W/kg', 'description', 'Mean of the scans'' epsilon_obs_coh_corr (as epsilon_obs, from the coherence-cleaned shear spectrum), nz x ncast. Pattern: epsilon_obs_coh_corr_<channel>.');
u.epsilon_obs_coh_corr_kc_channel = struct('unit', 'cpm', 'description', 'Mean of the scans'' epsilon_obs_coh_corr cutoff wavenumber, nz x ncast. Pattern: epsilon_obs_coh_corr_kc_<channel>.');
u.epsilon_mle_channel = struct('unit', 'W/kg', 'description', 'Mean of the scans'' epsilon_mle (Nasmyth-spectrum MLE fit), nz x ncast. Pattern: epsilon_mle_<channel>.');
u.fom_channel = struct('unit', 'dimensionless', 'description', 'Mean of the scans'' figure of merit for the direct-integration epsilon fit (lower is better), nz x ncast. Pattern: fom_<channel>.');
u.fom_mle_channel = struct('unit', 'dimensionless', 'description', 'Mean of the scans'' figure of merit for the MLE epsilon fit, nz x ncast. Pattern: fom_mle_<channel>.');
u.coherence_sum_channel = struct('unit', 'Hz', 'description', 'Mean of the scans'' shear-a3 coherence integrated over coherence_fmin_hz to coherence_fmax_hz (a vibration-contamination diagnostic), nz x ncast. Pattern: coherence_sum_<channel>.');
u.chi_obs_channel = struct('unit', 'degC^2/s', 'description', 'Mean of the scans'' chi_obs (direct integration) for one fpo7 channel in the bin, nz x ncast. Pattern: chi_obs_<channel>, e.g. chi_obs_t1.');
u.chi_obs_kc_channel = struct('unit', 'cpm', 'description', 'Mean of the scans'' chi_obs noise-floor cutoff wavenumber, nz x ncast. Pattern: chi_obs_kc_<channel>.');
u.chi_mle_channel = struct('unit', 'degC^2/s', 'description', 'Mean of the scans'' chi_mle (Batchelor-spectrum MLE fit) for one fpo7 channel in the bin, nz x ncast. Pattern: chi_mle_<channel>.');
u.chi_ucond_channel = struct('unit', 'degC^2/s', 'description', 'Mean of the scans'' chi_ucond (microconductivity; an underestimate, see MODunits_L2.m) for one microcond channel in the bin, nz x ncast. Pattern: chi_ucond_<channel>, e.g. chi_ucond_c1.');
u.chi_ucond_kmax_channel = struct('unit', 'cpm', 'description', 'Mean of the scans'' chi_ucond upper integration bound, nz x ncast. Pattern: chi_ucond_kmax_<channel>.');

% --- record ---
u.variables = struct('unit', 'n/a (struct array)', 'description', 'name, unit and description of each gridded field present (from this registry).');
u.source = struct('unit', 'n/a (string)', 'description', '''file'' (L1/L2 files, through time_index.mat) or ''profile'' (profiles_L1/ and profiles_L2/).');
u.source_stamp = struct('unit', 'n/a (cell)', 'description', 'Per cast: its end time, complete flag, the yml latitude, whether its position is the first GPS fix, and the times of the files it was binned from. A column is rebinned when this changes.');
u.provenance = struct('unit', 'n/a (record)', 'description', 'What this grid was made from (MODutil_provenance.m): the L1 and L2 (or profile) files, the run yml and its SHA-256, the run, when, and the code version.');
end %end function
