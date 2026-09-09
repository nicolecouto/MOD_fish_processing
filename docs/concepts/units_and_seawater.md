# Units and the sw_->gsw_ migration

This repo used to depend on the legacy CSIRO SEAWATER toolbox (`sw_*`, EOS-80/PSS-78), vendored
verbatim in `toolbox/seawater/`. As of 2026-09-08 (branch `epsilon_processing`), every `sw_*` call
site outside that toolbox has been replaced with its TEOS-10-equivalent `gsw_*` call from a fully
vendored GSW (Gibbs SeaWater) Oceanographic Toolbox, `toolbox/seawater/gsw/` (v3.06.16). Nicole's
2026-08-13 note (`PLAN.md` Section 12) is the origin of this work: *"There's strong, well-established
consensus: use GSW (TEOS-10), not the old SEAWATER (sw_) toolbox... We should get rid of sw_
dependence and move to gsw_. We should also keep very careful notes of what units all our variables
are in."*

## Why GSW/TEOS-10 over the old SEAWATER toolbox

The `sw_*` toolbox implements EOS-80 (the 1980 equation of state), built around Practical Salinity
(PSS-78, a conductivity-based scale with no direct physical unit) and potential temperature. GSW
implements TEOS-10 (2010), built around Absolute Salinity (SA, actual dissolved-mass concentration,
g/kg) and Conservative Temperature (CT) - the physically more correct quantities for density,
heat-content, and related calculations. TEOS-10 has been the international oceanographic community's
standard since 2010 (IOC/SCOR/IAPSO), and this repo was overdue to adopt it.

## The one deliberate exception: `visc.m`

GSW has no official kinematic-viscosity function - it's outside the TEOS-10 thermodynamic standard
(confirmed by inventory: zero `*visc*` files anywhere in the vendored 329-file GSW distribution).
The old `sw_visc.m` formula isn't EOS-80 either - it's a separate empirical fit (Dan Kelley's fit to
Knauss's Table II-8, contributed by D. Hebert 1986) that happened to live in the same toolbox; its
own header says it was "renamed sw_visc and added to seawater routines 9/9/98" when CSIRO folded it
in. Since there's no GSW alternative to replace it with, this repo kept it - restored to its
original name, `toolbox/seawater/visc.m`. Its density term originally called this toolbox's own
`sw_dens.m` (which pulled in `sw_dens0.m`/`sw_seck.m`/`sw_smow.m` as transitive CSIRO dependencies)
- switched to the vendored `gsw_rho.m` instead, fed Reference Salinity and Conservative
Temperature. This removes the CSIRO dependency chain entirely: `toolbox/seawater/` now holds zero
CSIRO/EOS-80 code, not even transitively - just `visc.m` (repo-owned, GSW-backed internally) and
the vendored `gsw/` toolbox.

`visc(SR, T, P)` takes Reference Salinity directly, not Practical Salinity - originally it took
`SP` and derived `SR` from it internally purely to feed the (new) density term, so the caller now
passes `SR` directly instead (already available at every call site, e.g. `ctd.SR`). The function's
empirical polynomial term (`0.02305*SR`) was calibrated against Practical Salinity, not Reference
Salinity - feeding it `SR` instead is a deliberate, accepted ~0.47% shift on that one term
(`SR/SP = 35.16504/35`), the same order of magnitude as every other EOS-80-vs-TEOS-10 difference in
this migration, not re-derived or re-fit.

## Reference Salinity (SR), not exact Absolute Salinity (SA)

TEOS-10's density/heat-capacity/Conservative-Temperature calculations formally want Absolute
Salinity, `SA = SR + deltaSA(lon, lat, p)`, where `SR = (35.16504/35)*SP` is a fixed conductivity
rescaling and `deltaSA` (the Absolute Salinity Anomaly) corrects for real spatial variation in
seawater's dissolved-ion composition - mostly a silicate/biogeochemical signature that accumulates
in old, deep water. Computing exact `SA` needs longitude, which this repo parses at L0
(`data.gps.longitude`) but doesn't currently thread past that point (only latitude survives, for
depth-from-pressure).

**This repo uses the SR shortcut (`SR ~= SA`) everywhere instead of computing exact SA** -
`ctd.SR = gsw_SR_from_SP(ctd.SP)`, persisted once in `process_ctd_fields`
(`MODprocess_single_L0_to_L1.m`) and threaded through `mod_L2_tile_scans.m` to every downstream GSW
call (`toolbox/seawater/ktemp.m`'s density/heat-capacity terms, and anywhere else a GSW
Absolute-Salinity-family input is needed). This avoids adding new longitude plumbing for a
correction that's negligible for this repo's deployments.

### How negligible, exactly - measured, not assumed

Rather than guess, this was checked against GSW's own real `deltaSA_atlas` reference lookup
(`toolbox/seawater/gsw/library/gsw_deltaSA_atlas.m`) at representative coordinates for two regions
this group actually works in - the Amundsen Sea (West Antarctica, including the Pine Island Bay
trough where the deep water driving Pine Island/Thwaites melt sits) and the Chukchi Sea (Alaska) -
translated into an actual density difference via `gsw_rho`, not left as an abstract salinity number:

| Location | Depth | deltaSA | rho(SA) - rho(SR) |
|---|---|---|---|
| Amundsen Sea (Pine Island Bay trough) | 500 dbar | 0.0069 g/kg | 0.0055 kg/m^3 |
| Amundsen Sea (Pine Island Bay trough) | 1000 dbar | 0.0078 g/kg | 0.0062 kg/m^3 |
| Chukchi Sea (central) | 500 dbar | 0.0035 g/kg | 0.0028 kg/m^3 |
| North Pacific deep, for scale (the open ocean's largest known anomaly) | 1000 dbar | 0.0187 g/kg | 0.0148 kg/m^3 |

Both regions come out *smaller* than the North Pacific reference point, not larger - a
~0.003-0.006 kg/m^3 density offset is small, comparable to or below typical CTD/microstructure
salinity-measurement noise. The extreme case where SR is genuinely wrong, not just imprecise, is
the Baltic Sea (a marginal sea with unusual freshwater/composition, `gsw_deltaSA_atlas` returns 0
for it by design - `gsw_SA_from_SP` handles it separately) - not a region this repo processes.

**One separate caveat the atlas doesn't capture**: heavy sea-ice-melt/river-influenced freshwater
(relevant to the Chukchi and the Arctic generally) can affect the conductivity-to-salinity
relationship itself - a measurement/PSS-78 issue, not a composition-anomaly issue - which is
outside what `deltaSA_atlas` checks either way.

**If a future deployment needs exact SA** (e.g. a region with a known large anomaly this repo
hasn't checked, or a precision requirement where the above margins matter): thread
`metadata.PROCESS.longitude` through the same way `metadata.PROCESS.latitude` already is, and swap
`ctd.SR = gsw_SR_from_SP(ctd.SP)` for `ctd.SA = gsw_SA_from_SP(ctd.SP, ctd.P, lon, lat)` at its one
call site - every downstream consumer would need updating too, since they all currently read
`ctd.SR`.

**Known bug in the vendored `gsw_deltaSA_atlas.m`/`gsw_SAAR.m`** (confirmed against both the
`MOD_fish_lib`-bundled copy and a freshly downloaded, current-release v3.06.16 - not a stale-copy
artifact): negative-longitude (`-180...+180`) input throws `Array indices must be positive
integers` for high-latitude/western coordinates, despite the docstring claiming both `[0...+360]`
and `[-180...+180]` work. Pass longitude in `0-360` form to either function until this is fixed
upstream - see `toolbox/seawater/Contents.m`.

## Field renames

| Old (`sw_`/EOS-80) | New (`gsw_`/TEOS-10) | Notes |
|---|---|---|
| `ctd.S` | `ctd.SP` | Practical Salinity - same quantity, explicitly-typed name (symmetric with the new `ctd.SR`) |
| `ctd.th` | `ctd.CT` | Potential temperature -> Conservative Temperature |
| `ctd.sgth` | `ctd.sigma0` | Potential density -> potential density anomaly (0 dbar reference) |
| *(new)* | `ctd.SR` | Reference Salinity, `gsw_SR_from_SP(ctd.SP)` - see above |
| `sw_salt` | `gsw_SP_from_C` | Takes conductivity directly in mS/cm - no `c3515` standard-ratio division needed |
| `sw_ptmp` | `gsw_CT_from_t` | |
| `sw_pden` | `gsw_sigma0` | |
| `sw_dpth` | `-gsw_z_from_p` | **Sign flip**: `gsw_z_from_p`'s convention is height (negative down); this repo's `z`/`dzdt` convention is positive down - negated at the one call site to preserve it exactly |
| `sw_dens`, `sw_cp` | `gsw_rho`, `gsw_cp_t_exact` | `toolbox/seawater/ktemp.m` - fed `SR`, not `SP` |
| `sw_visc` | `visc` | Kept, restored to its original name - see above |

The Caldwell (1974) thermal-conductivity term inside `toolbox/seawater/ktemp.m` has no GSW
equivalent (it's an unrelated, pre-TEOS-10 empirical fit) and still takes `SP`, not `SR` - it was
calibrated against Practical Salinity and there's no TEOS-10 formula to replace it with.

## Per-level units registries

`setup/MODunits_L0.m`, `MODunits_L1.m`, `MODunits_L2.m` (and a stub `MODunits_L3.m`, reserved until
`modProcess_L3_grid_profiles.m` exists) are static reference functions, each returning a struct
keyed by field name -> `struct('unit', ..., 'description', ...)` - one source of truth per
processing level for what every field means and what units it's in, callable any time without
needing real data in hand. Mirrors `setup/MODsetup_metadata_field_registry.m`'s existing pattern
(a static registry function, no data required), extended with a dedicated `unit` key that registry
never had (units there, where mentioned at all, were embedded in free-text `description` strings).
Dynamically-named per-channel fields (e.g. `chi_obs.(channel)`, `spectra.(channel)_f`) are
documented once as a *pattern*, not enumerated per possible channel name, matching how
`mod_L2_tile_scans.m`'s own header docstring already documents them.

`MODunits_L2.m` also documents two fields added to `L2data` as part of this migration: `L2data.SR`
and `L2data.nu`/`.ktemp` were computed every scan already (feeding the epsilon/chi_mle fits and the
thermal-diffusivity call) but were previously discarded rather than persisted to the final output -
promoted to real output fields so they're inspectable and so this registry has something real to
describe, following the legacy `MOD_fish_lib` `Profile` struct's own precedent of persisting
`kvis`/`ktemp`.
