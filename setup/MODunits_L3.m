function u = MODunits_L3()
% MODunits_L3        Part of MOD_fish_processing
%
% u = MODunits_L3()
%
% DESCRIPTION
%   Static registry of every grid.mat field's units and description
%   (MODprocess_grid.m's output), one entry per field name - see
%   MODunits_L0.m's own DESCRIPTION for the overall design. Per-channel
%   fields (chi_obs_t1, chi_mle_t2, ...) are documented once as a pattern.
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
u.z = struct('unit', 'm, positive down', 'description', 'Depth bin centers, nz x 1: (k - 0.5) * z_bin_m. A bin holds depths from (k-1)*z_bin_m to k*z_bin_m: L1 ctd.z for the CTD samples, -gsw_z_from_p(pressure, latitude) for the scans (L1 ctd.z uses a GPS latitude when there is one - a difference far below a bin).');
u.z_bin_m = struct('unit', 'm', 'description', 'Depth bin size (grid.z_bin_m in the yml).');
u.grid_version = struct('unit', 'n/a', 'description', 'Version of MODprocess_grid.m that made the grid (2: with C). A grid from another version is rebinned from scratch.');
u.latitude = struct('unit', 'degrees N', 'description', 'Latitude used for the scans'' depth (metadata.PROCESS.latitude). A change rebins every cast.');
u.time = struct('unit', 'MATLAB datenum', 'description', 'Mean time of the cast''s CTD samples, 1 x ncast (the middle of the cast if it has none).');
u.cast_start = struct('unit', 'MATLAB datenum', 'description', 'Cast start time from the cast table (casts.mat dnum_start), 1 x ncast - what a column is keyed by.');
u.cast_end = struct('unit', 'MATLAB datenum', 'description', 'Cast end time from the cast table (dnum_end), 1 x ncast.');
u.cast_direction = struct('unit', 'n/a (cellstr)', 'description', '''down'' or ''up'', 1 x ncast.');
u.cast_complete = struct('unit', 'logical', 'description', 'false for a cast still in progress (it runs into the end of the pressure record), 1 x ncast. Its column is rebinned every call until it ends.');
u.profile_number = struct('unit', 'n/a', 'description', 'The cast''s number in the cast table (Profile####.mat), 1 x ncast. Can change as the record grows - use cast_start to match casts.');

% --- CTD: mean of every L1 CTD sample in the bin ---
u.P = struct('unit', 'dbar', 'description', 'Mean CTD pressure in the bin, nz x ncast.');
u.T = struct('unit', 'degC', 'description', 'Mean CTD in-situ temperature (ctd.T) in the bin, nz x ncast.');
u.C = struct('unit', 'S/m', 'description', 'Mean CTD conductivity (ctd.C) in the bin, nz x ncast. S/m, not mS/cm.');
u.SP = struct('unit', 'psu (PSS-78)', 'description', 'Mean Practical Salinity (ctd.SP) in the bin, nz x ncast. Not despiked or smoothed.');
u.SR = struct('unit', 'g/kg', 'description', 'Mean Reference Salinity (ctd.SR) in the bin, nz x ncast.');
u.CT = struct('unit', 'degC', 'description', 'Mean Conservative Temperature (ctd.CT) in the bin, nz x ncast.');
u.sigma0 = struct('unit', 'kg/m^3', 'description', 'Mean potential density anomaly (ctd.sigma0) in the bin, nz x ncast.');
u.w = struct('unit', 'm/s, positive during descent', 'description', 'Mean fall speed (ctd.dzdt) in the bin, nz x ncast.');

% --- turbulence: mean of the L2 scans whose center is in the bin ---
u.n_scans = struct('unit', 'count', 'description', 'Number of L2 scans whose center is in the bin, nz x ncast. 0 where there is no scan (the turbulence fields are NaN there).');
u.epsilon_final = struct('unit', 'W/kg', 'description', 'Mean of the scans'' epsilon_final in the bin, nz x ncast.');
u.chi_obs_channel = struct('unit', 'degC^2/s', 'description', 'Mean of the scans'' chi_obs for one fpo7 channel in the bin, nz x ncast. Pattern: chi_obs_<channel>, e.g. chi_obs_t1.');
u.chi_mle_channel = struct('unit', 'degC^2/s', 'description', 'Mean of the scans'' chi_mle for one fpo7 channel in the bin, nz x ncast. Pattern: chi_mle_<channel>.');

% --- record ---
u.variables = struct('unit', 'n/a (struct array)', 'description', 'name, unit and description of each gridded field present (from this registry).');
u.source = struct('unit', 'n/a (string)', 'description', '''file'' (L1/L2 files, through time_index.mat) or ''profile'' (profiles_L1/ and profiles_L2/).');
u.source_stamp = struct('unit', 'n/a (cell)', 'description', 'Per cast: its end time, complete flag and the times of the files it was binned from. A column is rebinned when this changes.');
u.provenance = struct('unit', 'n/a (record)', 'description', 'What this grid was made from (MODutil_provenance.m): the L1 and L2 (or profile) files, the run yml and its SHA-256, the run, when, and the code version.');
end %end function
