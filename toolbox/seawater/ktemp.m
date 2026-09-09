function ktemp = ktemp(SP, SR, T, P)
% ktemp        Part of MOD_fish_processing
%
% ktemp = ktemp(SP, SR, T, P)
%
% DESCRIPTION
%   Thermal diffusivity of seawater, ktemp = k / (rho * cp), where k is
%   thermal conductivity, rho is density, cp is specific heat at constant
%   pressure. This is the ktemp both mod_scan_calc_chi_obs.m
%   (chi_obs = 6*ktemp*dk*sum(temperature-gradient spectrum)) and
%   mod_scan_calc_chi_mle.m need - a physical property of the water
%   the FP07 is sitting in, not of the instrument.
%
%   Lives in toolbox/seawater/, alongside visc.m, rather than
%   processing/scans/ - both are seawater-property functions of
%   (S, T, P) with no scan-specific logic of their own (they don't touch
%   epsi/spectra/metadata), matching this repo's "toolbox/ holds generic,
%   reusable physics; processing/scans/ holds scan-level processing
%   steps" convention. Originally named mod_scan_thermal_diffusivity.m
%   under processing/scans/ - renamed and moved here to sit next to
%   visc.m (which it mirrors: both are per-scan seawater property calls
%   taking Practical/Reference Salinity, temperature, and pressure).
%
%   Density and specific heat are computed via the vendored GSW/TEOS-10
%   toolbox (toolbox/seawater/gsw/gsw_rho.m, gsw_cp_t_exact.m), migrated
%   from the CSIRO/UNESCO-1983 (EOS-80) toolbox/seawater/sw_dens.m and
%   sw_cp.m this function used before - deliberately NOT the old
%   MOD_fish_lib EPSILOMETER/EPSILON/process/density.m and cp.m, which
%   compute the same physics but in a confusingly different,
%   semi-documented unit convention (salinity as a 0-0.1ish mass fraction,
%   pressure in MPa, with an auto-detecting "if s>1, divide by 1000" guess
%   inside kt.m to paper over the mismatch with callers that actually pass
%   PSU). See docs/concepts/units_and_seawater.md for the sw_->gsw_
%   migration and the SR (Reference Salinity, SR ~= SA) shortcut this repo
%   uses throughout instead of exact Absolute Salinity.
%
%   Thermal conductivity itself has no GSW/TEOS-10 equivalent, so it's
%   still the ported local subfunction (not a separate file - nothing else
%   needs it standalone yet, matching this repo's "split into its own file
%   only when something else calls it" convention, e.g. PLAN.md Section
%   6.2's calibrate_ctd note) from MOD_fish_lib's thermometric_cond.m
%   (Caldwell, D.R. (1974), Deep-Sea Res., 21, 131-137), with its pressure
%   input corrected to take dbar (this repo's standard, e.g. ctd.P) and
%   convert to MPa internally (1 MPa = 100 dbar) - the original
%   thermometric_cond.m's docstring says its p argument should already be
%   in MPa, but its one caller in MOD_fish_lib
%   (mod_epsilometer_get_temperature_noise.m, via kt.m) passes CTD pressure
%   straight through in dbar, off by a factor of 100 on a term that is
%   itself already a small correction (thermal diffusivity varies only
%   mildly with P) - not the kind of bug this exercise is centrally about,
%   but flagged here rather than silently reproduced, same spirit as
%   mod_scan_fpo7_cutoff.m's NOTES. This term is an unrelated, pre-TEOS-10
%   empirical fit calibrated against Practical Salinity, not a GSW/EOS-80
%   density-family formula - it keeps taking SP, not SR (see INPUTS).
%
% INPUTS
%   SP - Practical Salinity [psu], scalar - feeds only the Caldwell
%        thermal-conductivity term, which was calibrated against PSU and
%        has no TEOS-10 equivalent to convert it to.
%   SR - Reference Salinity [g/kg], scalar (gsw_SR_from_SP(SP), typically
%        already available as ctd.SR - see docs/concepts/units_and_seawater.md)
%        - feeds the GSW density/heat-capacity/Conservative-Temperature calls.
%   T  - in-situ temperature [degC], scalar
%   P  - pressure [dbar], scalar
%
% OUTPUTS
%   ktemp - thermal diffusivity [m^2/s], scalar. Typical open-ocean value
%           is ~1.4e-7 m^2/s and varies only mildly with S/T/P - if this
%           comes out far from that, check units on the caller's side
%           first.
%
% CALLED BY
%   mod_L2_tile_scans.m (once per scan, from scan-center SP/SR/T/P - the
%   resulting ktemp is then passed into mod_scan_calc_chi_obs.m /
%   mod_scan_calc_chi_mle.m as an argument, not computed inside them)
%
% CALLS
%   gsw_CT_from_t.m, gsw_rho.m, gsw_cp_t_exact.m (toolbox/seawater/gsw)
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

CT  = gsw_CT_from_t(SR, T, P);
rho = gsw_rho(SR, CT, P);
c_p = gsw_cp_t_exact(SR, T, P);
k = thermal_conductivity(SP, T, P);

ktemp = k ./ (rho .* c_p);

end %end function

%% Thermal conductivity of seawater [W/(m*K)], Caldwell (1974).
% SP in psu, T in degC, P in dbar (converted to MPa here - see DESCRIPTION
% above for why this differs from thermometric_cond.m's original caller).
function k = thermal_conductivity(SP, T, P)
SP_frac = SP / 1000; % psu -> mass fraction, matches thermometric_cond.m's expected scale
P_MPa = P / 100;    % dbar -> MPa
k = 0.001365 * 418.55 .* (1.0 + 0.003.*T - 1.025e-5.*T.^2 + 6.53e-4.*P_MPa - 0.29.*SP_frac);
end
