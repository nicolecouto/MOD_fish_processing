    function visc=visc(SR,T,P)
%  function visc=VISC(SR,T,P)
%
%  kinematic viscosity (nu) (no pressure dependence examined)
%
%  based on dan kelley's fit to knauss's table ii-8
%
%  SR Reference Salinity [g/kg] (gsw_SR_from_SP(SP) - typically already
%     available as ctd.SR, see docs/concepts/units_and_seawater.md).
%     Uppercase to match ctd's own field naming (ctd.SR/.T/.P).
%     Originally took Practical Salinity (SP, ppt) - the formula's only
%     other use of salinity was to derive SR for the density term below,
%     so the caller now passes SR directly instead of this function
%     converting it internally. The empirical polynomial term
%     (0.02305*SR below) was calibrated against Practical Salinity, not
%     Reference Salinity - feeding it SR instead introduces a deliberate,
%     accepted ~0.47% shift on that one term (SR/SP = 35.16504/35), the
%     same order of magnitude as every other EOS-80-vs-TEOS-10 difference
%     in this migration - not re-derived/re-fit, just accepted.
%  T  temperature (deg. c)
%  P  pressure (dbars)
%
%  visc  kinematic viscosity  (m**2 s-1)
%
%  visc(40.,40.,1000.)=8.200167608e-7 (original CSIRO sw_dens-based
%  formula, with SP=40 - not re-verified for the current SR-input,
%  gsw_rho-based formula; same ballpark expected, not digit-for-digit
%  comparable)
%
%                                        dave hebert  11/04/86
%
% renamed sw_visc and added to seawater routines 9/9/98 (CSIRO SEAWATER
% Library v2.0.1). Restored to its original name here (MOD_fish_processing,
% branch epsilon_processing) as part of the sw_->gsw_/TEOS-10 migration:
% GSW has no official kinematic-viscosity function to replace this with,
% and this formula was never actually EOS-80 - just prefixed on import
% into that toolbox. Density now comes from the vendored GSW toolbox's
% gsw_rho.m (fed Reference Salinity - the same SR-approximates-SA
% shortcut used throughout this repo's other GSW calls, see
% docs/concepts/units_and_seawater.md) instead of this toolbox's own
% former sw_dens.m, which pulled in sw_dens0.m/sw_seck.m/sw_smow.m as
% transitive dependencies - the last CSIRO/EOS-80 code left anywhere in
% this repo. This removes the CSIRO dependency chain entirely - nothing
% in toolbox/seawater/ calls sw_* anymore.

      CT = gsw_CT_from_t(SR, T, P);
      rho = gsw_rho(SR, CT, P);
      visc=1e-4*(17.91-0.5381*T+0.00694*T.*T+0.02305*SR)./rho;
