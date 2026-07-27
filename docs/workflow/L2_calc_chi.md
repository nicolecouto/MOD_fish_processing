# FP07 calibration and chi: the time-constant deconvolution

**Status:** working, tested against real `epsi_mako/blt2021_0715` data in a sandbox. Built on branch `chi_processing`, off `l1_to_l2_conversion`, following [L1 → L2: downcast-gated spectra](L1_to_L2_conversion.md).

## Why this branch exists

While documenting how `MOD_fish_lib` computes chi, we traced where the FP07 thermistor's dynamic time constant (`tau = 0.005 * w^-0.32`, `w` = fall speed) actually enters the calculation, since Nicole and Arnaud need to describe this exactly for a paper correction (the 2025 BLT paper - a wrong FP07 time constant would bias chi, and chi/epsilon errors that are individually unremarkable become a direct factor in gamma). Two things came out of that:

1. **The tau formula itself has never changed** in `MOD_fish_lib`'s git history (`h_fp07.m`, `get_filters_MADRE.m`, `mod_efe_scan_chi.m` all agree, unchanged since the repo's first commit).
2. **But the deconvolution that uses tau was silently dropped** from the live code path on 2025-10-06 (commit `051d80f`, "fix linear volts to C conversion"). That commit correctly fixed a stale `dTdV` calibration by replacing it with a `volts_to_C = [slope, intercept]` fit - but in doing so, replaced `Pt_T_f = (Pt_volt_f*dTdV^2) ./ filter_TF` with a direct `pwelch` of the calibrated-to-Celsius signal, and never re-added the `./ filter_TF` division. `filter_TF` (built from the same never-changed tau formula) is still computed in that function today - just never used.

Since `MOD_fish_lib` is off-limits to touch, this branch builds a from-scratch, documented version of the whole chain in `MOD_fish_processing`: FP07 in-situ calibration, the tau-based transfer function (tau exposed as an overridable parameter, not hardcoded), the FPO7 noise-floor cutoff, and a direct-integration chi. Built and tested one piece at a time against real `epsi_mako/blt2021_0715` data (the only deployment in `data_for_reorg` with a real onboard CTD - `epsi_deepsolo`'s external CTD is pressure-only and can't support any of this).

## The chain

### 1. `MODprocess_L1_apply_fpo7_calibration.m` — in-situ volts→degC calibration

```matlab
metadata = MODprocess_L1_apply_fpo7_calibration(L1_dir, metadata, PressureTimeseries)
```

For each FP07 channel (`metadata.AFE.(ch).type == 'fpo7'`), concatenates that channel's epsi volts and CTD temperature across every L1 file in the deployment (same sorted-by-file-start-time pattern as `MODprocess_L1_make_pressure_timeseries.m`), restricts to descending samples only (`PressureTimeseries.is_down`), despikes both series the same way the old `mod_epsi_linear_calibration_FP07.m` did (`fillmissing` + `filloutliers` movmedian on volts, movmean on CTD T), and fits `polyfit(volts, T, 1)` → `metadata.AFE.(ch).volts_to_C = [slope, intercept]`.

This is **not** a lookup like shear's `Sv` - an FP07 bead's sensitivity isn't a fixed, bench-measured probe property, it has to be fit in-situ per deployment against a real temperature reference. No CTD temperature (DeepSolo) → `volts_to_C` simply never gets set, same "missing calibration is not an error" convention as shear's `.cal`.

Wired into `MODprocess_all_L0_to_L1.m`, gated on `~isempty(metadata.CTD.cal)` (real onboard CTD, not DeepSolo's P-only external CTD), right after `meta/PressureTimeseries.mat` is built - persisted back to `meta/metadata.mat` via the existing `MODsetup_save_metadata.m` "derived value" convention.

**Real result** (`blt2021_0715` sandbox, whole deployment, descending samples only): `t1.volts_to_C = [-32.86, 51.70]` (n=725,673), `t2.volts_to_C = [-30.62, 45.53]` (same n). Both slopes negative (volts decrease as T increases, expected for this AFE's divider circuit), both intercepts land the predicted T in a physically sane 3-20°C range matching a July DY132/BLT water column. t1's (volts, T) scatter is tight; t2's is visibly noisier (see "Known limitation" below).

### 2. `MODprocess_L2_fpo7_transfer_function.m` — the time-constant deconvolution filter

```matlab
H = MODprocess_L2_fpo7_transfer_function(f, w, tau0, exponent)
% tau = tau0 * abs(w)^exponent          (defaults: tau0=0.005, exponent=-0.32)
% H   = 1 ./ (1 + (2*pi*tau*f).^2)      (magnitude-squared, single-pole low-pass)
```

This is the one term the whole branch is about. A physical FP07 bead can't instantaneously track water temperature - it responds like a first-order low-pass filter, faster (smaller tau) at higher flow speed. `H(f)` is how much of the true temperature-gradient spectrum survives at each frequency once the bead's own thermal inertia has rolled it off; dividing an observed spectrum by `H` is the deconvolution that recovers what the water was actually doing.

`tau0`/`exponent` default to the historical, unchanged `MOD_fish_lib` values, but are real function arguments, not hardcoded - a tau sensitivity comparison is just calling this twice with different values and diffing the resulting chi (see "Running a tau sensitivity comparison" below).

**Deliberately narrow scope**: this is *only* the FP07 thermal rolloff. It does not bundle:
- The AFE electronics/ADC sinc⁴ filter response (`H.electFPO7` in the old `get_filters_MADRE.m`) - a separate, much smaller correction whose rolloff sits near Nyquist, far above where the thermal rolloff (tens of Hz) matters. That belongs to `modProcess_L1_apply_filters.m` (PLAN.md Section 6.2, not started).
- The old "Tdiff" analog-differentiator filter term - only relevant for MADRE-era electronics with a physical dT/dt circuit ahead of the ADC. Confirmed via `MOD_fish_lib`'s actual `blt2021_0715` process config (`Meta_Data_Process_blt_2021.txt`) that `Meta_Data.MAP.temperature` was never `'Tdiff'` for this deployment - every deployment this repo processes uses raw, undifferentiated FP07 voltage, so this term simply doesn't apply here.

**Verified**: the half-power (`H=0.5`) frequency matches the analytic `1/(2*pi*tau)` to within numerical grid resolution across several fall speeds (e.g. w=1.0 m/s → tau=0.005s → fc=31.83 Hz predicted vs. 31.77 Hz measured), and doubling `tau0` correctly shifts the rolloff to a lower frequency (stronger correction), as expected physically.

### 3. `MODprocess_L2_fpo7_cutoff.m` — noise-floor cutoff (kc)

```matlab
fc_index = MODprocess_L2_fpo7_cutoff(f, Pxx, noise_coefs)
```

Finds where an observed FP07 volts spectrum drops into the instrument's own bench-measured noise floor (`noise_coefs.n0..n3`, a cubic fit in log10(f) vs. log10(noise power) - see "Calibration file" below), so chi only integrates over wavenumbers where the channel is measuring turbulence, not its own electronic noise. Ports the old `FPO7_cutoff.m`'s approach (movmean smoothing, `SN_min=3` threshold, skip the first 2 Fourier coefficients as unreliable) but **fixes two indexing bugs** found while tracing it - both would have made the old code cut off a couple of bins too early:
1. The old function dropped the f=0 bin internally and returned an index into that *shorter* array; its caller then indexed its own, still-full-length `f` with that number - off by one bin.
2. The old function's "skip the first 2 bins" search returned an index relative to that sub-array without ever adding the 2-bin offset back - off by two more.

This function tracks original-array indices throughout, so the index it returns is always valid against the exact `f`/`Pxx` passed in - no caller-side reindexing needed.

**Verified visually**: plotting the smoothed spectrum against the scaled noise floor for a real t1_volt scan shows the two curves clearly diverging below the returned cutoff and converging/tracking together above it - the crossing is visually exactly where the function says it is (fc ≈ 30.6 Hz for w≈0.65 m/s, sensibly in the same ballpark as the Module 2 thermal-rolloff cutoff for similar fall speeds).

### 4. `MODprocess_L2_thermal_diffusivity.m` — ktemp

```matlab
ktemp = MODprocess_L2_thermal_diffusivity(S, T, P)   % [psu, degC, dbar] -> m^2/s
```

`ktemp = k / (rho * cp)` (thermal conductivity / density / specific heat). Reuses this repo's already-vendored, standard CSIRO/UNESCO-1983 (EOS-80) `sw_dens.m`/`sw_cp.m` for density and specific heat - deliberately **not** `MOD_fish_lib`'s bespoke `density.m`/`cp.m`, which compute the same physics in a confusingly different, semi-auto-detected unit convention (salinity as a ~0.03-scale mass fraction, pressure in MPa, with a "if s>1, guess it's PSU and divide by 1000" heuristic). Thermal conductivity itself (Caldwell 1974) has no existing equivalent in this repo's seawater toolbox, so it's ported as a local subfunction - with its pressure term corrected to expect dbar (this repo's standard) and convert to MPa internally; the original's one caller in `MOD_fish_lib` passed CTD pressure straight through in dbar into a formula documented as wanting MPa, a small (not factor-of-2) error on an already-minor correction term, flagged rather than silently reproduced.

**Verified**: `ktemp(S=35,T=10,P=1000) = 1.434e-7 m^2/s`, `ktemp(S=35,T=10,P=0) = 1.422e-7 m^2/s` - both in the expected ~1.4e-7 m²/s range for seawater, with the correct (small) pressure sensitivity.

### 5. `MODprocess_L2_calc_chi.m` — putting it together

```matlab
[chi, kc] = MODprocess_L2_calc_chi(f, Pxx, w, volts_to_C, ktemp, noise_coefs)
```

1. `Pt_T_f = Pxx * volts_to_C(1)^2` (slope-squared - equivalent to a second `pwelch` of the calibrated-to-degC signal, since `pwelch` detrends and `detrend(a*x+b) = a*detrend(x)`, so no second FFT is needed).
2. Deconvolve: `Pt_T_f = Pt_T_f ./ MODprocess_L2_fpo7_transfer_function(f, w)` - **the step that was missing from `MOD_fish_lib`**.
3. `k = f / abs(w)`; `Pt_Tg_k = (2*pi*k).^2 .* Pt_T_f * abs(w)` (temperature-gradient wavenumber spectrum).
4. Integrate from `kmin = 3` cpm (fixed, unchanged from `mod_efe_scan_chi.m`) to `kc` (from step 3 above): `chi = 6 * ktemp * dk * sum(Pt_Tg_k(kmin <= k <= kc))`.

`chi` is `NaN` (not an error) if `kc <= kmin` - a scan where the FP07 signal never rises above the noise floor within the integrable wavenumber range at all.

**Deliberately direct-integration chi only** - no Batchelor-spectrum MLE fit (`chi_mle`) and no figure-of-merit QC flag, both of which `mod_efe_scan_chi.m` also computes. Left as a clearly-scoped-out follow-up once this simpler version is validated, so a tau sensitivity comparison stays a clean, auditable calculation rather than being entangled with a second statistical fit.

Wired into `MODprocess_single_L1_to_L2.m`: scan-center `temperature`/`salinity` are now interpolated the same way `pressure`/`w` already were, and `chi.(channel)`/`chi_kc.(channel)` get computed automatically for every fpo7 channel with a resolved `volts_to_C`, whenever the bench noise file (see below) is present - no changes needed to `MODprocess_all_L1_to_L2.m` itself, since it already calls through to the per-file function.

## Calibration file: `MOD_fish_calibrations/FPO7/FPO7_benchnoise.mat`

Copied from `MOD_fish_lib/EPSILOMETER/CALIBRATION/FPO7/FPO7_notdiffnoise.mat`, renamed for clarity (see `MOD_fish_calibrations/FPO7/README.md` for full provenance) - contents (`n0`, `n1`, `n2`, `n3`) unchanged. "notdiffnoise" ("not differentiated") describes that this is the noise floor for raw FP07 voltage, as opposed to an analog-differentiated dT/dt signal (`FPO7_noise.mat`, the "Tdiff" variant - not copied, not relevant here, see Module 2 above). Not per-probe - one shared bench constant, resolved via `metadata.paths.calibrations_root` the same way SBE/shear cal files are, just without a per-SN subfolder.

**Not yet committed to `MOD_fish_calibrations`** - that repo has an unrelated, in-progress uncommitted `README.md` edit (tag-naming convention update) that shouldn't be swept up in this branch's commit.

## Running a tau sensitivity comparison

The actual point of this whole branch - call `MODprocess_L2_fpo7_transfer_function.m` (directly, or via `MODprocess_L2_calc_chi.m`) twice with different `tau0`/`exponent` and compare:

```matlab
chi_default = MODprocess_L2_calc_chi(f, Pxx, w, volts_to_C, ktemp, noise_coefs); % tau0=0.005, exponent=-0.32

% ...to compare against a candidate "wrong" tau, edit MODprocess_L2_fpo7_transfer_function.m's
% call inside MODprocess_L2_calc_chi.m, or temporarily call it with overrides directly:
H_alt = MODprocess_L2_fpo7_transfer_function(f, w, 0.010, -0.32); % e.g. 2x tau0
```

Not yet run as a real comparison against `blt2021_0715` - next step once documentation catches up with the code (this doc).

## Real test results (`blt2021_0715` sandbox, one descending profile, 1516→1782 dbar, 64 scans)

| channel | n valid chi | chi range (degC²/s) | chi median | kc range (cpm) |
|---|---|---|---|---|
| t1 | 64/64 | 9.0e-11 – 5.5e-8 | 3.1e-9 | 18.0 – 108.4 |
| t2 | 64/64 | 5.7e-9 – 2.3e-6 | 6.0e-7 | 59.7 – 217.8 |

t1's chi looks like an unremarkable, quiet deep-water value. **t2 is ~200x higher, with a correspondingly higher kc** - consistent with t2's visibly noisier (volts, T) calibration scatter (see Module 1 above). Read as a real t2 data-quality issue (noise/vibration/probe difference letting extra spectral power past the noise-floor cutoff), not a bug in the chi calculation - same code path produces a clean t1 result from the same scan, same time.

## Known limitations

- **No Batchelor MLE fit or figure-of-merit QC** - direct-integration chi only (see Module 5). Deferred as a follow-up module.
- **t1/t2 chi discrepancy not yet root-caused** - see "Real test results" above. Worth investigating before trusting t2 for anything gamma-related on this deployment.
- **Tau sensitivity comparison not yet actually run** - the machinery (Module 2's overridable `tau0`/`exponent`) is built and unit-tested, but a real side-by-side chi comparison against `blt2021_0715` hasn't been done yet.
- **`FPO7_benchnoise.mat` not yet committed** to `MOD_fish_calibrations` (see above).

## History

Built on branch `chi_processing`, off `l1_to_l2_conversion` (2026-07-27), one module at a time, each tested standalone against real `epsi_mako/blt2021_0715` data in a scratchpad sandbox copy (`meta`/`calibrations`/`L1` only - `L0`/`raw` left out, ~930 MB not needed for this work) before being wired into the next piece. See PLAN.md Section 12 session log entry (2026-07-27) for full numbers.
