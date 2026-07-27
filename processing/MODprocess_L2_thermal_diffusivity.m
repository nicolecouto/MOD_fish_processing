function ktemp = MODprocess_L2_thermal_diffusivity(S, T, P)
% MODprocess_L2_thermal_diffusivity        Part of MOD_fish_processing
%
% ktemp = MODprocess_L2_thermal_diffusivity(S, T, P)
%
% DESCRIPTION
%   Thermal diffusivity of seawater, ktemp = k / (rho * cp), where k is
%   thermal conductivity, rho is density, cp is specific heat at constant
%   pressure. This is the ktemp MODprocess_L2_calc_chi.m needs
%   (chi = 6*ktemp*dk*sum(temperature-gradient spectrum)) - a physical
%   property of the water the FP07 is sitting in, not of the instrument.
%
%   Density and specific heat are the already-vendored, standard CSIRO/
%   UNESCO-1983 (EOS-80) toolbox/seawater/sw_dens.m and sw_cp.m -
%   deliberately NOT the old MOD_fish_lib EPSILOMETER/EPSILON/process/
%   density.m and cp.m, which compute the same physics but in a
%   confusingly different, semi-documented unit convention (salinity as a
%   0-0.1ish mass fraction, pressure in MPa, with an auto-detecting
%   "if s>1, divide by 1000" guess inside kt.m to paper over the mismatch
%   with callers that actually pass PSU). Reusing sw_dens/sw_cp - which
%   this repo already vendors and already feeds real PSU/degC/dbar
%   ctd.S/.T/.P into elsewhere (MODprocess_single_L0_to_L1.m's
%   process_ctd_fields) - avoids introducing a second, differently-scaled
%   copy of the same EOS-80 polynomials.
%
%   Thermal conductivity itself has no equivalent already in this repo's
%   seawater toolbox, so it's ported here (as a local subfunction, not a
%   separate file - nothing else needs it standalone yet, matching this
%   repo's "split into its own file only when something else calls it"
%   convention, e.g. PLAN.md Section 6.2's calibrate_ctd note) from
%   MOD_fish_lib's thermometric_cond.m (Caldwell, D.R. (1974), Deep-Sea
%   Res., 21, 131-137), with its pressure input corrected to take dbar
%   (this repo's standard, e.g. ctd.P) and convert to MPa internally
%   (1 MPa = 100 dbar) - the original thermometric_cond.m's docstring
%   says its p argument should already be in MPa, but its one caller in
%   MOD_fish_lib (mod_epsilometer_get_temperature_noise.m, via kt.m)
%   passes CTD pressure straight through in dbar, off by a factor of 100
%   on a term that is itself already a small correction (thermal
%   diffusivity varies only mildly with P) - not the kind of bug this
%   exercise is centrally about, but flagged here rather than silently
%   reproduced, same spirit as MODprocess_L2_fpo7_cutoff.m's NOTES.
%
% INPUTS
%   S - salinity [psu], scalar
%   T - temperature [degC], scalar
%   P - pressure [dbar], scalar
%
% OUTPUTS
%   ktemp - thermal diffusivity [m^2/s], scalar. Typical open-ocean value
%           is ~1.4e-7 m^2/s and varies only mildly with S/T/P - if this
%           comes out far from that, check units on the caller's side
%           first.
%
% CALLED BY
%   MODprocess_single_L1_to_L2.m (once per scan, from scan-center S/T/P -
%   the resulting ktemp is then passed into MODprocess_L2_calc_chi.m as an
%   argument, not computed inside it)
%
% CALLS
%   sw_dens.m, sw_cp.m (toolbox/seawater)
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

rho = sw_dens(S, T, P);
c_p = sw_cp(S, T, P);
k = thermal_conductivity(S, T, P);

ktemp = k ./ (rho .* c_p);

end %end function

%% Thermal conductivity of seawater [W/(m*K)], Caldwell (1974).
% S in psu, T in degC, P in dbar (converted to MPa here - see DESCRIPTION
% above for why this differs from thermometric_cond.m's original caller).
function k = thermal_conductivity(S, T, P)
S_frac = S / 1000; % psu -> mass fraction, matches thermometric_cond.m's expected scale
P_MPa = P / 100;    % dbar -> MPa
k = 0.001365 * 418.55 .* (1.0 + 0.003.*T - 1.025e-5.*T.^2 + 6.53e-4.*P_MPa - 0.29.*S_frac);
end
