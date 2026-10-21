function n2 = mod_scan_n2_local(ctd, center_dnum, half_dz, g)
% mod_scan_n2_local        Part of MOD_fish_processing
%
% n2 = mod_scan_n2_local(ctd, center_dnum, half_dz, g)
%
% DESCRIPTION
%   Background buoyancy frequency squared around one scan, from the
%   full-rate CTD:
%     1. the CTD samples that stay within half_dz of the scan-center
%        depth, walking out from the scan center in time both ways (so
%        only the cast the scan is on)
%     2. sigma0 sorted into a stable profile: the densities in increasing
%        order placed at the depths in increasing order (a Thorpe sort),
%        which takes out the overturns - they're where the turbulence is,
%        and an unsorted fit there gives a low or negative gradient
%     3. a least-squares line of sorted sigma0 against depth:
%          n2 = g / rho0 * d(sigma0)/dz,  rho0 = 1000 + mean(sigma0)
%        (z positive down, so n2 >= 0)
%   Sorting only the window, not the whole cast, works the same in
%   realtime (one L1 file at a time) as by profile. Fitting a line over a
%   depth window keeps one noisy sample, or the fish's wobble, from
%   setting the gradient, and the window is in meters, so it doesn't
%   depend on fall speed.
%
%   NaN when the samples found span less than half_dz in depth (the
%   window runs off the end of the file or the cast).
%
% INPUTS
%   ctd         - L1 ctd: dnum, z [m, positive down], sigma0 [kg/m^3]
%   center_dnum - the scan center time
%   half_dz     - half the depth window [m] (ucond.stratification_half_dz_m)
%   g           - gravity [m/s^2] (gsw_grav at the scan)
%
% OUTPUTS
%   n2 - [s^-2]
%
% CALLED BY
%   MODprocess_single_L1_to_L2.m
%
% CALLS
%   (none)
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

n2 = NaN;
z = ctd.z(:);
[~, i0] = min(abs(ctd.dnum(:) - center_dnum));
zc = z(i0);
if ~isfinite(zc)
    return
end
in_band = abs(z - zc) <= half_dz;
first = find(~in_band(1:i0), 1, 'last') + 1;
if isempty(first)
    first = 1;
end
last = i0 - 1 + find(~in_band(i0:end), 1, 'first') - 1;
if isempty(last)
    last = numel(z);
end
zs = z(first:last);
ss = ctd.sigma0(first:last);
ok = isfinite(zs) & isfinite(ss(:));
zs = zs(ok);
ss = ss(ok);
if numel(zs) < 2 || max(zs) - min(zs) < half_dz
    return
end
fit = polyfit(sort(zs), sort(ss(:)), 1);
n2 = g / (1000 + mean(ss)) * fit(1);

end %end function
