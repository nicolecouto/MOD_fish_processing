# Epsilon (shear turbulence): coherence, direct integration, and MLE

**Status:** implemented and verified against synthetic data on branch `epsilon_processing`, following [FP07 calibration and chi](L2_calc_chi.md) and [Profile detection and extraction](profile_detection.md). Not yet run against a real deployment's shear data - see "Known limitations" and "History" below. Three epsilon estimators exist - `epsilon_obs`/`epsilon_obs_coh_corr` (direct wavenumber integration, raw and coherence-cleaned) and `epsilon_mle` (Nasmyth-spectrum MLE fit) - and `chi_mle` (previously standalone-only, see [FP07 calibration and chi](L2_calc_chi.md)) is now wired into the pipeline using the epsilon this module produces.

## Why this module exists

Nothing in `MOD_fish_processing` computed epsilon (turbulent kinetic energy dissipation rate) before this branch - `mod_scan_calc_chi_mle.m` was fully implemented but never wired into `mod_L2_tile_scans.m` for exactly that reason: it needs a per-scan `epsilon` estimate, and nothing produced one. `PLAN.md` Section 6.4 named the target module (`mod_scan_calc_epsilon.m`, "Not started") since 2026-08-18; a 2026-09-02 session log records a colleague's (Jen's) validated tuning from a real ASTRAL reprocess against the legacy `MOD_fish_lib` chain (prefer `epsilon_mle` over `epsilon_co`, `kmin=5` cpm for both the epsilon and chi MLE fits), registered in `MODsetup_metadata_field_registry.m` at the time but left unconsumed until this module existed to consume it.

This module ports MOD_fish_lib's `mod_efe_scan_epsilon.m`/`eps1_mmp.m`/`epsilon2_correct.m`/`nasmyth.m`/`mod_efe_scan_coherence.m` chain into this repo's `mod_scan_*` (scan, metadata, ...) convention, following the same 8-step pipeline order already established for chi: tile scans → per-scan spectra (all channels) → apply filters/find cutoffs → convert to wavenumber → coherence → chi/epsilon from spectra directly → chi/epsilon via MLE → figure of merit.

## The chain

### 1-2. Scan tiling and per-channel spectra - already built, no change

`mod_L2_tile_scans.m`'s windowing loop and `mod_scan_get_spectra.m`'s per-channel raw PSDs (including every shear channel's `s1_volt_f`/`s2_volt_f`) are unchanged - epsilon reuses both directly, the same way chi does.

### 3-4. `mod_scan_shear_transfer_function.m` + `mod_scan_shear_volts_to_shear_spectrum.m` - filters and wavenumber conversion

```matlab
H = mod_scan_shear_transfer_function(f, w, lc)              % lc default 0.02 m, Oakey (1982)
scan = mod_scan_shear_volts_to_shear_spectrum(scan, metadata, channel)
```

Same single-pole-low-pass shape as `mod_scan_fpo7_transfer_function.m`'s thermal rolloff, but with a fixed spatial cutoff wavelength `lc` rather than a fall-speed-dependent time constant - a shear probe's dynamic response scales with distance traveled through water, not elapsed time. Combined with `metadata.AFE.(ch).electronics_filter` (already resolved by `MODsetup_define_filters.m` for shear channels - charge-amp × sinc⁴ ADC - previously computed but unconsumed, see [FP07 calibration and chi](L2_calc_chi.md)), then the raw volts spectrum is deconvolved and converted: volts → velocity (via the probe's bench sensitivity `Sv`, `metadata.AFE.(ch).cal`, and Oakey's `2*g/(Sv*abs(w))` convention) → shear wavenumber spectrum `Ps_shear_k = (2*pi*k)^2 * Ps_velocity_f * abs(w)`.

**Unlike FP07, there is no noise-floor-cutoff search here** - shear has no bench-measured noise floor file in `MOD_fish_calibrations` the way FP07 does (`FPO7_benchnoise.mat`). Instead, the direct-integration step (Module 6 below) caps its own integration bound directly at a known contamination frequency (`contam_freq_hz`), mirroring chi's `contam_freq_hz` cap but applied differently.

### 5. `mod_scan_shear_accel_coherence.m` - vibration-contamination coherence

```matlab
scan = mod_scan_shear_accel_coherence(scan, metadata, channel)
```

Magnitude-squared coherence (MATLAB's `mscohere`, whole-scan detrend - not `mod_scan_get_spectra.m`'s per-segment-detrend Welch method, a deliberate simplification matching the legacy port exactly) between the shear channel and accelerometer channel `a3` (hardcoded, not looped over all three axes - matches legacy's own hardcoded choice: the vertical axis is the one most mechanically coupled to a shear probe's own vibration). Used downstream (in `mod_scan_calc_epsilon.m`, not this function) to build a coherence-cleaned shear spectrum: `Ps_velocity_co_f = Ps_velocity_f .* (1 - Cxy)`.

### 6. `mod_scan_calc_epsilon_obs.m` - direct-integration epsilon (`eps1_mmp.m` + `epsilon2_correct.m` port)

```matlab
scan = mod_scan_calc_epsilon_obs(scan, metadata)   % scan.spectra.k, .Ps_shear_k, .Ps_shear_co_k, .w, .nu in
                                                     % scan.epsilon_obs, .epsilon_obs_kc, .epsilon_obs_coh_corr, .epsilon_obs_coh_corr_kc added
```

Three-stage iterative Panchev/Nasmyth-referenced integration (Wesson & Gregg 1994):
1. Integrate the `stage1_kmin`-`stage1_kmax` band (default 2-10 cpm, not `kmin_obs` - the two polynomial fits this stage uses were derived specifically over that historical range, so these two fields are registered mainly for traceability, not because a different value is expected to be valid - see `MODsetup_metadata_field_registry.m`'s CAUTION) and pick one of two empirical polynomial fits depending on whether that integral already looks purely inertial-subrange, for a first-pass `eps1`.
2. Re-integrate from `kmin_obs` to the wavenumber containing 90% of a Panchev spectrum's variance at `eps1` (capped at `kmax = contam_freq_hz/abs(w)`) → `eps2`.
3. Repeat once more with `eps2`'s own 90%-variance wavenumber → `eps3`.
4. Floor at 1e-11 W/kg if smaller; otherwise a median-ratio adjustment against a Nasmyth spectrum at `eps3`, then `epsilon2_correct`'s missing-variance correction polynomial, for the final epsilon.

Run twice per call - once on the raw `Ps_shear_k`, once on the coherence-cleaned `Ps_shear_co_k` (when present) - producing `epsilon_obs`/`epsilon_obs_coh_corr` respectively, matching legacy's `epsilon`/`epsilon_co` pair. `kmin_obs` (default 3, matching legacy's hardcoded stage-2/3 value) is made tunable here, the same precedent chi's own `kmin_obs` field already set.

### 7. `toolbox/theoretical_spectra/nasmyth_spectrum.m` + `mod_scan_calc_epsilon_mle.m` - Nasmyth-spectrum MLE fit

```matlab
Psg = nasmyth_spectrum(epsilon, nu, k)     % epsilon can be a vector (grid) - Psg comes out numel(k) x numel(epsilon)
scan = mod_scan_calc_epsilon_mle(scan, metadata)    % scan.epsilon_obs_coh_corr, .epsilon_obs_coh_corr_kc in (from Module 6)
                                                      % scan.epsilon_mle added
```

Unlike chi_mle (which searches a pure amplitude `chi` with the Batchelor spectrum's shape fixed by an externally-supplied epsilon), this search is over epsilon itself - the Nasmyth spectrum's shape *and* amplitude are both set by epsilon. Always fits against the coherence-cleaned spectrum, seeded by Module 6's `epsilon_obs_coh_corr` and fit over `[kmin_mle, epsilon_obs_coh_corr_kc]` - `kmin_mle` (default 5, Jen's 2026 ASTRAL fork value) is a *separate* field from `kmin_obs`, not a reuse of it: legacy's live code always fit from the same `kmin=3` `eps1_mmp.m` itself used, and Jen's fork specifically overrode that to 5 cpm just for the MLE fit.

The grid-search zoom itself (`processing/scans/mod_scan_mle_grid_search.m`) is **shared with `mod_scan_calc_chi_mle.m`** - split out of what was originally chi_mle's own local `mle_search_chi` function once epsilon needed the identical machinery (4-pass, 200-point log-spaced zoom, widen-on-edge-hit, capped at 10 widenings - see that function's own DESCRIPTION for the full chi2pdf-underflow-avoidance rationale). Search width multipliers are registered separately per estimator: `mle_start_search`/`mle_end_search` (epsilon, default 0.1/10 - one decade each side) vs. `chi_mle_start_search`/`chi_mle_end_search` (chi, 1e-3/1e3 - three decades) - a real, deliberate difference in the legacy code between the two searches, not an oversight to reconcile.

`dof` uses this repo's own `processing/scans/mod_scan_dof.m` (1.9×`fft_segments_per_scan`, Nuttall 1971), **not** MOD_fish_lib's `mod_efe_scan_epsilon.m`, which computed a different, uncorrected raw-Welch-segment-count `dof` (`2*N/nfft - 1`) locally for its own coherence/epsilon calls. Deliberately not ported - `mod_scan_dof.m` is already this repo's single source of truth for every other MLE weighting (chi_mle included), and using two different `dof` definitions for two MLE fits sharing the same grid-search code would be a real, silent inconsistency, not a faithful port of a meaningful design choice.

### 8. `mod_scan_calc_fom.m` - figure of merit

```matlab
fom = mod_scan_calc_fom(k, Pobs, Pmodel, klim, dof)
```

Generic (not epsilon- or chi-specific): `mad(log10(Pobs(klim)./Pmodel(klim))) / sig_lnS / Tm`, where `sig_lnS`/`Tm` are the theoretical spectral-ratio standard deviation and small-sample correction MOD_fish_lib's `mod_efe_scan_epsilon.m` computes inline for its own `fom`/`fom_mle`. Values near 1 indicate a good fit. Computed for both `epsilon_obs_coh_corr` (against a Nasmyth model at that epsilon) and `epsilon_mle` (against a Nasmyth model at that epsilon) by the orchestrator (Module 9) - chi's own FOM (`mod_efe_scan_chi.m`'s separate `compute_fom` local subfunction, not read closely enough during this port to confirm it's the identical formula) remains a follow-up, not resolved by this module.

### 9. `mod_scan_calc_epsilon.m` - orchestrator

```matlab
scan = mod_scan_calc_epsilon(scan, metadata, channel)
```

Calls Modules 3-8 in order for one shear channel of one scan (coherence → epsilon → figure of merit, matching MOD_fish_lib's `get_scan_spectra.m`'s own call order of coherence → epsilon → chi). Called once per shear channel from `mod_L2_tile_scans.m`'s per-scan loop, mirroring how that loop already calls `mod_scan_calc_chi_obs.m` once per fpo7 channel.

## Wiring into `mod_L2_tile_scans.m`

Epsilon is computed for every shear channel with a resolved `metadata.AFE.(ch).cal` (bench `Sv`), gated on the same `have_ctd_ts` condition chi_obs uses - kinematic viscosity `nu` (`toolbox/seawater/visc.m`) needs real CTD T/S the same way thermal diffusivity `ktemp` does, so a DeepSolo-style P-only external CTD can never produce epsilon either, just like it can never produce chi. `nu` is computed once per scan (shared by every shear channel and, via `chi_mle`, every fpo7 channel too), and persisted as `L2data.nu` alongside `L2data.ktemp`.

`chi_mle` is then called for every fpo7 channel, for every scan where a finite `L2data.epsilon_final` is available - the mean, omitting NaN, across this deployment's shear channels of whichever variant `metadata.PROCESS.EPSILON.epsilon_final_source` selects (`'epsilon_mle'` by default, changed from the legacy `'epsilon_co'` default once this module shipped and could validate Jen's finding - see `MODsetup_metadata_field_registry.m`). The resolved variant is also recorded in the output itself, `L2data.epsilon_final_source` (`'epsilon_mle'`/`'epsilon_co'`/`''`) - an unrecognized `metadata.PROCESS.EPSILON.epsilon_final_source` value falls back to `'epsilon_co'`, same as it always has, but that fallback is now visible in the output rather than silent. **This per-scan mean is a deliberate simplification**, not the full profile-level ratio-based per-channel selection MOD_fish_lib's legacy pipeline does (comparing s1 vs. s2 across a whole profile and picking whichever channel looks more trustworthy, gated by a figure-of-merit threshold) - see "Known limitations."

## `setup.yml`/registry additions

```yaml
epsilon:                           # -> metadata.PROCESS.EPSILON.*
  epsilon_final_source: epsilon_mle  # 'epsilon_co' | 'epsilon_mle' - which variant feeds chi_mle
  kmin_obs: 3                        # cpm, direct-integration lower bound (mirrors chi's kmin_obs)
  stage1_kmin: 2                     # cpm, stage-1 band lower bound - CAUTION, see Module 6
  stage1_kmax: 10                    # cpm, stage-1 band upper bound - CAUTION, see Module 6
  contam_freq_hz: .inf               # Hz, shear contamination cap (mirrors chi's contam_freq_hz)
  oakey_lc_m: 0.02                   # m, Oakey transfer function spatial cutoff
  coherence_fmin_hz: 0               # Hz, coherence-sum diagnostic band - placeholder, see below
  coherence_fmax_hz: .inf            # Hz, coherence-sum diagnostic band - placeholder, see below
  kmin_mle: 5                        # cpm, MLE fit lower bound (separate from kmin_obs - see Module 7)
  mle_start_search: 0.1              # MLE grid-search low multiplier on the epsilon_obs_coh_corr seed
  mle_end_search: 10                 # MLE grid-search high multiplier
  qc_accel_method: rms_std           # registered, not yet consumed - see "Known limitations"
  qc_accel_threshold: 1.0e-5         # registered, not yet consumed
  qc_accel_nstd: 2                   # registered, not yet consumed
```

All validated via `MODsetup_validate_metadata.m` at point of use (prompted for, and offered to be saved into `setup.yml`, if missing) rather than silently defaulted - see `MODsetup_metadata_field_registry.m` for the authoritative list. `epsilon_final_source`'s registered default changed from the legacy `'epsilon_co'` to `'epsilon_mle'` with this module's arrival - a deliberate default change, not left as the historical value, since Jen's 2026 ASTRAL finding (epsilon_mle better-behaved) is exactly what this module now exists to act on.

`coherence_fmin_hz`/`coherence_fmax_hz` are placeholder defaults (0/Inf, i.e. the full band) - MOD_fish_lib's `mod_efe_scan_coherence.m` used `Meta_Data.PROCESS.fc1`/`.fc2` for the same band, but no historical numeric value was found in this repo's reference deployments during this port. A real value needs deriving per-deployment the same way chi's own `contam_freq_hz` does (see [FP07 calibration and chi](L2_calc_chi.md)'s "Contamination-frequency cap").

## How to run it

Epsilon is computed automatically as part of `mod_L2_tile_scans.m`, the same shared windowing core both the realtime (`MODprocess_single_L1_to_L2.m`) and postprocess (`MODprocess_single_L1_to_L2_profile.m` → `MODprocess_all_L1_to_L2_profiles.m`) paths already call - nothing extra to invoke. To exercise just the epsilon chain by hand on one scan (e.g. while debugging):

```matlab
addpath('/path/to/MOD_fish_processing/processing/L2');
addpath('/path/to/MOD_fish_processing/processing/scans');
addpath('/path/to/MOD_fish_processing/setup');
addpath('/path/to/MOD_fish_processing/toolbox');
addpath('/path/to/MOD_fish_processing/toolbox/theoretical_spectra'); % batchelor/panchev/nasmyth - addpath isn't recursive
addpath('/path/to/MOD_fish_processing/toolbox/seawater');
addpath('/path/to/MOD_fish_processing/toolbox/seawater/gsw');
addpath('/path/to/MOD_fish_processing/toolbox/seawater/gsw/library');
addpath('/path/to/MOD_fish_processing/toolbox/seawater/gsw/thermodynamics_from_t');

metadata = MODsetup_read_yaml('/path/to/deployment/meta/setup.yml');
scan.spectra.f = ...;          % from mod_scan_get_spectra.m
scan.spectra.Ps_volt_f = scan.spectra.s1_volt_f;
scan.epsi = ...;               % raw time series (for coherence): epsi.s1_volt, epsi.a3_g
scan.w = ...;                  % fall speed [m/s]
scan.nu = visc(SR, T, P);      % kinematic viscosity at scan center - Reference Salinity (see units_and_seawater.md)

scan = mod_scan_calc_epsilon(scan, metadata, 's1');
```

## Known limitations

- **`chi_mle` now recomputes the fpo7 deconvolution and noise-floor cutoff search a second time, on every scan, for every fpo7 channel.** `mod_scan_calc_chi_mle.m` was always designed to redo `mod_scan_fpo7_volts_to_Tg_spectrum.m`/`mod_scan_fpo7_cutoff.m` from scratch rather than reuse `mod_scan_calc_chi_obs.m`'s already-computed `spectra.k`/`.Pt_Tg_k`/`.fc_index` on the same scan/channel - a deliberate simplicity choice, the same "each mode/estimator recomputes independently, no cross-call result sharing" principle already applied to realtime-vs-profile-cut mode. That cost was previously paid only when `chi_mle` was invoked standalone for one-off analysis; wiring it into `mod_L2_tile_scans.m`'s production per-scan loop (this branch) means it now runs - and pays that redundant cost - on every scan of every profile of every deployment with a real onboard CTD and a resolved epsilon estimate. Not fixed this pass: doing so safely means changing `mod_scan_calc_chi_mle.m`'s contract (e.g. accepting already-computed `spectra.k`/`.Pt_Tg_k`/`.fc_index` and skipping recomputation when present), a real design change to an already-verified function that deserves its own careful pass and regression check, not a rushed edit alongside everything else in this branch.
- **Not yet run against a real deployment's shear data.** Verified so far only against synthetic data: `nasmyth_spectrum.m`'s shape/positivity, `processing/scans/mod_scan_mle_grid_search.m` recovering a known epsilon from a noiseless and a chi-squared-noised synthetic Nasmyth spectrum (and, unchanged after the chi_mle refactor, a known chi from a noiseless synthetic Batchelor spectrum), `mod_scan_shear_transfer_function.m`'s monotonic-rolloff sanity, `mod_scan_calc_epsilon_obs.m`'s direct integration recovering a known epsilon to within ~5% on a noiseless synthetic spectrum, `mod_scan_calc_epsilon_mle.m` recovering it near-exactly when seeded from that same estimate, `mod_scan_calc_fom.m` correctly scoring a good fit lower than a badly-mismatched one, and the full `mod_scan_calc_epsilon.m`/`mod_L2_tile_scans.m` chain running end to end with no errors on synthetic time-domain data (not recovering a specific injected epsilon from that particular run - the time-domain synthetic shear signal was unstructured noise, not a physically realistic turbulence spectrum). No `epsi_mako`-class real deployment was reprocessed through this module this session.
- **`epsilon_final` channel selection is per-scan, not profile-level.** `mod_L2_tile_scans.m` feeds `chi_mle` the mean (omitting NaN) across shear channels of the per-scan epsilon estimate - MOD_fish_lib's legacy pipeline instead compares each channel's epsilon across a *whole profile* and picks the more trustworthy channel via a ratio check plus a figure-of-merit threshold, at the profile level, not per scan. That full selection needs `modProcess_L2_qc.m` (below), not built yet.
- **`modProcess_L2_qc.m` (acceleration-based QC gate, profile-level epsilon_final ratio selection, pitch/roll, speed) is not built.** The registered `qc_accel_method`/`qc_accel_threshold`/`qc_accel_nstd` fields have no consumer yet. This QC is genuinely profile-level in the legacy code (comparing RMS/STD of accelerometer spectral power across an entire profile's scans, not any single scan in isolation) and needs pitch/roll (vnav/twist data, not currently part of `mod_L2_tile_scans.m`'s epsi/ctd-only scope) for the fuller legacy QC array - deferred rather than half-built. Chi shipped without a figure-of-merit-based QC gate too, for the same reason (see [FP07 calibration and chi](L2_calc_chi.md)).
- **`coherence_fmin_hz`/`coherence_fmax_hz` have placeholder defaults**, not a real per-deployment value - see "`setup.yml`/registry additions" above. The band-integrated coherence sum this drives (`L2data.coherence_sum.(channel)`) is a diagnostic only, not consumed by the epsilon calculation itself (which uses the full per-frequency coherence vector, unaffected by this band choice).
- **`calib_volt`/`calib_vel` (a shear-vs-a3-accelerometer ratio diagnostic near the contamination frequency, computed but never applied as a correction in the legacy code) was deliberately not ported** - cheap to add later if a real need for it surfaces; left out to keep this pass's scope to what's load-bearing for epsilon/chi_mle themselves.
- **No epsilon/chi cross-comparison against real ASTRAL or `blt2021_0715` data**, unlike chi_obs/chi_mle's own validation history (see [FP07 calibration and chi](L2_calc_chi.md)'s "Running a tau/chi_obs-vs-chi_mle comparison"). A real-data comparison against an old-format `MOD_fish_lib` `Profile####.mat`'s own `epsilon`/`epsilon_co`/`epsilon_mle` fields (the same trick that comparison used for chi) is the natural next validation step.

## History

**2026-09-08 (later same day) - renamed the three theoretical-spectrum functions, dropping `mod_scan_`.** `mod_scan_batchelor_spectrum.m`/`mod_scan_nasmyth_spectrum.m`/`mod_scan_panchev_spectrum.m` (moved into `toolbox/theoretical_spectra/` earlier the same day - see [Profile detection and extraction](profile_detection.md)'s sibling PLAN.md session log) renamed to `batchelor_spectrum.m`/`nasmyth_spectrum.m`/`panchev_spectrum.m`. Decision: keep this repo's own from-scratch reimplementations (confirmed, while reviewing this decision, to already match the legacy "evaluate at a given k" behavior these functions need - see each file's own PROVENANCE section for exactly which `MOD_fish_lib` source each is a faithful port of, including the batchelor.m/local-`batchelor`-subfunction distinction), but the `mod_scan_` prefix no longer fits now that they live outside `processing/scans/` and take no `scan`/`metadata` argument at all. Every call site and doc reference updated to match (`mod_scan_calc_chi_mle.m`, `mod_scan_calc_epsilon_obs.m`, `mod_scan_calc_epsilon_mle.m`, `mod_scan_calc_fom.m`'s docstring, `mod_scan_mle_grid_search.m`'s docstring, `modProcess_L2_calc_epsilon.m`, `MODvis_spectra.m`) - pure rename, `checkcode` clean, and the existing synthetic-data regression suite (Nasmyth shape, noiseless/noisy MLE recovery, direct-integration epsilon, FOM discrimination) re-run against the new names with identical results to before the rename.

Built on branch `epsilon_processing`, 2026-09-08, following [FP07 calibration and chi](L2_calc_chi.md) and the Phase A extraction/conversion refactor documented in [Profile detection and extraction](profile_detection.md). Ported from `MOD_fish_lib`'s `EPSILOMETER/EPSILON/mod_efe_scan_epsilon.m`, `process/eps1_mmp.m`, `process/epsilon2_correct.m`, `process/nasmyth.m` (also vendored, byte-identical, in `toolboxes/fitting_tools/nasmyth.m`), and `mod_efe_scan_coherence.m`, plus the MLE grid-search pattern from `toolboxes/fitting_tools/mle_any_model.m`/`logLikelihood.m` (the latter's formula already independently re-derived in this repo's `toolbox/spectral_loglikelihood.m` for chi_mle). All new/changed files: `mod_scan_shear_transfer_function.m`, `mod_scan_nasmyth_spectrum.m`, `mod_scan_shear_volts_to_shear_spectrum.m`, `mod_scan_shear_accel_coherence.m`, `mod_scan_calc_epsilon_obs.m`, `mod_scan_calc_epsilon_mle.m`, `mod_scan_calc_fom.m`, `toolbox/mod_scan_mle_grid_search.m` (new, split out of `mod_scan_calc_chi_mle.m`), `processing/L2/modProcess_L2_calc_epsilon.m` (new orchestrator), `mod_L2_tile_scans.m` (epsilon + chi_mle wiring), `MODsetup_metadata_field_registry.m` (7 new `PROCESS.EPSILON.*` entries, `epsilon_final_source`'s default changed to `epsilon_mle`).

Verified via a MATLAB sandbox (deleted when done): Nasmyth spectrum shape/positivity; the shared MLE grid search recovering a known epsilon from a noiseless synthetic Nasmyth spectrum exactly, and within a factor of ~2 from a single chi-squared-noised (dof≈5.7) realization; the same search recovering a known chi from a noiseless synthetic Batchelor spectrum exactly, confirming the `mod_scan_calc_chi_mle.m` refactor (extracting `toolbox/mod_scan_mle_grid_search.m`) is behavior-preserving; the shear transfer function's monotonic single-pole rolloff; `mod_scan_calc_epsilon_obs.m`'s ported `eps1_mmp`/`epsilon2_correct` integration recovering a known epsilon to ~4% on a noiseless synthetic spectrum; `mod_scan_calc_epsilon_mle.m` recovering it near-exactly (seeded from that estimate); `mod_scan_calc_fom.m` scoring a deliberately-wrong model spectrum worse than the correct one; and the full `modProcess_L2_calc_epsilon.m`/`mod_L2_tile_scans.m` chain (including the chi_obs → epsilon → chi_mle wiring) running end to end on synthetic time-domain data with no errors, correct output shapes, and the documented "bare empty struct when no channel qualifies" convention preserved. `checkcode` clean on every new/touched file (no new findings beyond the codebase's pre-existing `datestr`/`now` style notices elsewhere).
