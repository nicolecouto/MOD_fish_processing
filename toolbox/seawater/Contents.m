% toolbox/seawater - seawater property functions
%
% This directory has three parts, kept together because they're all
% "seawater physical properties," not because they're the same toolbox:
%
% 1. visc.m - the one deliberate exception to this repo's migration off
%    the legacy CSIRO SEAWATER (EOS-80/PSS-78) toolbox to GSW/TEOS-10.
%    GSW has no official kinematic-viscosity function, and visc.m's
%    formula was never actually EOS-80 in the first place (D. Hebert,
%    contributed independently, prefixed sw_visc only when CSIRO folded
%    it into their toolbox on 9/9/98 - restored to its original name
%    here). Its density term now uses the vendored gsw_rho.m (Reference
%    Salinity/Conservative Temperature) instead of the CSIRO sw_dens.m it
%    originally depended on - so this directory has ZERO CSIRO/EOS-80
%    code left in it at all, not even as a transitive dependency. Every
%    other function that used to live here (the rest of the CSIRO
%    SEAWATER Library v2.0.1, Phillip P. Morgan, CSIRO, 22-Apr-1998,
%    including visc.m's former sw_dens/sw_dens0/sw_seck/sw_smow
%    dependency chain) has been removed.
%
% 2. ktemp.m - thermal diffusivity, ktemp = k/(rho*cp), GSW-backed
%    (gsw_rho.m, gsw_cp_t_exact.m) with a ported Caldwell (1974)
%    thermal-conductivity term (no GSW/TEOS-10 equivalent exists). Same
%    shape as visc.m - pure seawater-property math with no metadata/scan
%    argument - so it lives here too, not in processing/scans/, where it
%    was originally named mod_scan_thermal_diffusivity.m before being
%    moved and renamed on 2026-09-08 (see PLAN.md Section 12 session log).
%
% 3. gsw/ - the full vendored GSW (Gibbs SeaWater) Oceanographic Toolbox,
%    TEOS-10, v3.06.16 - unmodified third-party code. This is what every
%    other seawater-property call in this repo uses now (density, heat
%    capacity, Conservative/Reference Salinity, depth from pressure,
%    etc.) - see docs/concepts/units_and_seawater.md for the migration
%    rationale and the Reference-Salinity-shortcut design decision.
%
%    addpath needs THREE entries for gsw/, not one - confirmed while
%    building this migration: the base directory, gsw/library/ (e.g.
%    gsw_SAAR.m, gsw_deltaSA_atlas.m), and gsw/thermodynamics_from_t/
%    (e.g. gsw_cp_t_exact.m - lives only here in v3.06.16, no top-level
%    duplicate the way some older GSW distributions had).
%
%    Known bug, confirmed against this exact vendored copy (v3.06.16),
%    not just an older/stale one: gsw_deltaSA_atlas.m (and gsw_SAAR.m,
%    same underlying lookup) throws "Array indices must be positive
%    integers" for negative (-180...+180 convention) longitude at
%    high-latitude/western coordinates, despite its own docstring
%    claiming both [0...+360] and [-180...+180] work. Pass longitude in
%    0-360 form to either function until this is fixed upstream.
