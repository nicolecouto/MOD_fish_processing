# FP07 calibration and chi: the time-constant deconvolution

**Status:** working, tested against real `epsi_mako/blt2021_0715` and `epsi_mako/astral` data in a sandbox. Built on branch `chi_processing`, off `l1_to_l2_conversion`, following [L1 → L2: downcast-gated spectra](L1_to_L2_conversion.md). Two chi estimators now exist - `chi_obs` (direct wavenumber integration) and `chi_mle` (Batchelor-spectrum MLE fit) - see Modules 5-8 below. The AFE electronics/ADC transfer function (`MODsetup_define_filters.m`, Module 2b) is now also implemented, closing a second gap from `MOD_fish_lib`'s chi calculation - see "Why this branch exists" and Module 2b.

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

Wired into `MODprocess_all_L0_to_L1.m`, gated on `~isempty(metadata.CTD.cal)` (real onboard CTD, not DeepSolo's P-only external CTD), right after `meta/pressure_time_series.mat` is built - persisted back to `meta/metadata.mat` via the existing `MODsetup_save_metadata.m` "derived value" convention.

**Real result** (`blt2021_0715` sandbox, whole deployment, descending samples only): `t1.volts_to_C = [-32.86, 51.70]` (n=725,673), `t2.volts_to_C = [-30.62, 45.53]` (same n). Both slopes negative (volts decrease as T increases, expected for this AFE's divider circuit), both intercepts land the predicted T in a physically sane 3-20°C range matching a July DY132/BLT water column. t1's (volts, T) scatter is tight; t2's is visibly noisier (see "Known limitation" below).

### 2. `mod_scan_fpo7_transfer_function.m` — the time-constant deconvolution filter

```matlab
H = mod_scan_fpo7_transfer_function(f, w, tau0, exponent)
% tau = tau0 * abs(w)^exponent          (defaults: tau0=0.005, exponent=-0.32)
% H   = 1 ./ (1 + (2*pi*tau*f).^2)      (magnitude-squared, single-pole low-pass)
```

The `tau ~ w^exponent` scaling (exponent = -0.32) is the tow-tank-measured flow-speed dependence of a glass-rod FP07 thermistor's time constant, from Gregg, M.C. and Meagher, T.B. (1980), "The dynamic response of glass rod thermistors," *J. Geophys. Res.*, 85(C5), 2779-2786, doi:10.1029/JC085iC05p02779 - see `docs/references.md`.

This is the one term the whole branch is about. A physical FP07 bead can't instantaneously track water temperature - it responds like a first-order low-pass filter, faster (smaller tau) at higher flow speed. `H(f)` is how much of the true temperature-gradient spectrum survives at each frequency once the bead's own thermal inertia has rolled it off; dividing an observed spectrum by `H` is the deconvolution that recovers what the water was actually doing.

`tau0`/`exponent` default to the historical, unchanged `MOD_fish_lib` values, but are real function arguments, not hardcoded - a tau sensitivity comparison is just calling this twice with different values and diffing the resulting chi (see "Running a tau sensitivity comparison" below).

**Deliberately narrow scope**: this is *only* the FP07 thermal rolloff. It does not bundle:
- The AFE electronics/ADC sinc⁴ filter response (`H.electFPO7` in the old `get_filters_MADRE.m`/`get_filters_SOM.m`) - **not actually a small correction** (see Module 2b below): confirmed by back-solving a real `Profile100.mat`'s own stored spectrum for the correction factor it was generated with, this term is already a ~1.65x factor on top of the thermal rolloff by f≈62 Hz for a typical fall speed, right in the frequency range chi's integration is most sensitive to. Resolved separately, once per deployment (it depends only on `f`/metadata, not per-scan fall speed) by `MODsetup_define_filters.m` -> `metadata.AFE.(ch).electronics_filter`, and combined with this function's output by `mod_scan_fpo7_volts_to_Tg_spectrum.m` (Module 5).
- The old "Tdiff" analog-differentiator filter term - only relevant for MADRE-era electronics with a physical dT/dt circuit ahead of the ADC. Confirmed via `MOD_fish_lib`'s actual `blt2021_0715` process config (`Meta_Data_Process_blt_2021.txt`) that `Meta_Data.MAP.temperature` was never `'Tdiff'` for this deployment - every deployment this repo processes uses raw, undifferentiated FP07 voltage, so this term simply doesn't apply here. Still not ported (see Module 2b) - no deployment this repo processes has ever used it.

**Verified**: the half-power (`H=0.5`) frequency matches the analytic `1/(2*pi*tau)` to within numerical grid resolution across several fall speeds (e.g. w=1.0 m/s → tau=0.005s → fc=31.83 Hz predicted vs. 31.77 Hz measured), and doubling `tau0` correctly shifts the rolloff to a lower frequency (stronger correction), as expected physically.

### 2b. `setup/MODsetup_define_filters.m` — AFE electronics/ADC transfer function

```matlab
metadata = MODsetup_define_filters(metadata)   % once per deployment, right after MODsetup_read_yaml.m
```

Ports the rest of `MOD_fish_lib`'s `get_filters_SOM.m` - everything that depends only on `f` (from `metadata.PROCESS.fft_length`/`.Fs_epsi`) and `metadata.AFE.(ch)`, not on per-scan fall speed, so (unlike Module 2's thermal rolloff) it's a genuine deployment-level constant, resolved once and persisted the same way `volts_to_C` is:

- **fpo7**: `electronics_filter = H_adc²`, where `H_adc = (sinc(f/(2*f(end))))⁴` is the AFE's sinc⁴ ADC anti-alias response (`metadata.AFE.(ch).ADCfilter`, defaulted to `'sinc4'` by `MODsetup_read_yaml.m` if the yaml doesn't specify one) - matches `get_filters_SOM.m`'s `H.electFPO7.^2` term inside `H.FPO7`.
- **shear**: `electronics_filter = (H_ca .* H_adc)²`, where `H_ca` is the probe's charge-amp response, interpolated from a network-analysis measurement (`cap1nFres200Meg_5KohmInput.mat`, vendored from `MOD_fish_lib` into `calibrations_root/SHEAR/` - not yet committed, see "Calibration file" below). Missing file → warning, channel left without `electronics_filter`, same "missing calibration is not exceptional" convention as shear's `.cal`/fpo7's `.volts_to_C`.
- **acc**: `electronics_filter = H_adc²` (gain 1).

Not ported: the old "Tdiff" term (see Module 2's bullet above - no current deployment uses it).

`mod_scan_fpo7_volts_to_Tg_spectrum.m` (Module 5) is the fpo7/chi consumer; `mod_scan_shear_volts_to_shear_spectrum.m` (branch `epsilon_processing` - see [Epsilon (shear turbulence)](L2_calc_eps.md)) is now a second, shear/epsilon consumer of the same `metadata.AFE.(ch).electronics_filter` field, resolving the "not yet consumed" gap this paragraph used to flag. Deliberately no generic "apply this to any channel's spectrum" wrapper built alongside it (PLAN.md's `modProcess_L1_apply_filters.m` design note originally proposed one) - each consumer reads the field itself, the same pattern this repo has previously removed (`MODprocess_L2_kinematic_viscosity.m`).

**Verified**: resolves without error against a real `blt2021_0715` `setup.yml`/`metadata.mat` (sandboxed copy) for all 7 AFE channels (t1/t2 fpo7, s1/s2 shear, a1/a2/a3 acc); shear channels correctly get no `electronics_filter` (warning, not error) when `calibrations_root` doesn't have `SHEAR/cap1nFres200Meg_5KohmInput.mat` yet, and correctly resolve one (range differs from the fpo7/acc sinc⁴-only range, as expected from the extra charge-amp term) once it does.

### 3. `mod_scan_fpo7_cutoff.m` — noise-floor cutoff (kc)

```matlab
scan = mod_scan_fpo7_cutoff(scan, metadata, noise_coefs)   % scan.spectra.f, .Pt_volt_f in; scan.spectra.fc_index added
```

Finds where an observed FP07 volts spectrum drops into the instrument's own bench-measured noise floor (`noise_coefs.n0..n3`, a cubic fit in log10(f) vs. log10(noise power) - see "Calibration file" below), so chi only integrates over wavenumbers where the channel is measuring turbulence, not its own electronic noise. Ports the old `FPO7_cutoff.m`'s approach (movmean smoothing, `SN_min=3` threshold, skip the first 2 Fourier coefficients as unreliable) but **fixes two indexing bugs** found while tracing it - both would have made the old code cut off a couple of bins too early:
1. The old function dropped the f=0 bin internally and returned an index into that *shorter* array; its caller then indexed its own, still-full-length `f` with that number - off by one bin.
2. The old function's "skip the first 2 bins" search returned an index relative to that sub-array without ever adding the 2-bin offset back - off by two more.

This function tracks original-array indices throughout, so the index it returns is always valid against the exact `f`/`Pxx` passed in - no caller-side reindexing needed.

**Verified visually**: plotting the smoothed spectrum against the scaled noise floor for a real t1_volt scan shows the two curves clearly diverging below the returned cutoff and converging/tracking together above it - the crossing is visually exactly where the function says it is (fc ≈ 30.6 Hz for w≈0.65 m/s, sensibly in the same ballpark as the Module 2 thermal-rolloff cutoff for similar fall speeds).

#### Contamination-frequency cap (`contam_freq_hz`)

The noise-floor search above has no natural answer when chi is high enough that the observed spectrum never drops back into the bench noise floor at all - it just defaults to trusting the whole spectrum (`fc_index = valid(end)`). That is the same behavior MMP's thermistor cutoff (`thcut1_*_mmp.m`, `~/Dropbox/SIO/_instrument_software/mmp_matlab`) falls back to when its own noise-floor search never crosses. Rockland's ODAS shear/epsilon code (`get_diss_odas.m`, `~/Dropbox/SIO/_instrument_software/rockland/odas`) does the opposite: it imposes a hard wavenumber ceiling (`K_limit = min(K_AA, 150 cpm)`) independent of the noise floor. `MOD_fish_lib`'s own legacy epsilon code already follows Rockland's approach, but only for epsilon - `mod_efe_scan_epsilon.m` caps `kmax = fpump/w` where `fpump = Meta_Data.PROCESS.ctd_fc` ("arbitrary cutoff frequency, usually extracted from coherence spectra shear/accel"). `mod_efe_scan_chi.m` never had an equivalent cap.

This isn't hypothetical: a sandboxed copy of ASTRAL `Profile100_nfft1024.mat` has `Profile.fpump = 45 Hz`, and of 620 valid t1/t2 chi estimates in that one profile, 21 have `tg_fc` (the legacy equivalent of this function's cutoff) landing between 46 and 110 Hz - well past 45 Hz.

Looking directly at the raw per-channel spectra (median across all scans, both nfft=1024 and nfft=512, across 6 ASTRAL profiles - `Profile100` at both nfft, `Profile025`, `Profile145`, `Profile186`, `Profile233`) turned up two real, sharp, highly reproducible contamination tones - neither matching the stored 45 Hz:

| tone | t1/t2 (FP07) | s1/s2 (shear) | a1/a2/a3 (accel) |
|---|---|---|---|
| ~48.1-48.8 Hz | no elevation (~0.7-0.9x) | huge (~55-330x) | strong on a2/a3 (~30-150x), negligible on a1 (~2-3x) |
| ~58.75-59.4 Hz | strong (~15-50x) | huge (~40-220x) | no elevation (~0.9-1.1x) |

Consistent across every profile and both FFT lengths checked - a true fixed-Hz tone lands near the same frequency regardless of nfft/binning, and it does. Read as two physically distinct sources: ~48 Hz looks mechanical (shear+accel, not FP07 - likely the real identity of this deployment's nominal "45 Hz" `fpump`, which may just be an unverified/rounded figure for this deployment); ~59 Hz looks electrical, shared by the FP07 and shear analog front end but not the accelerometer path, and is the one that actually matters for chi.

A deconvolution-gain threshold (capping wherever `1/(H_thermal * H_electronics)`, from Module 2/2b, exceeds some limit) was considered as an alternative to a fixed frequency and rejected: at 59 Hz the gain is only ~9x for typical ASTRAL fall speeds (it only gets aggressive past ~80 Hz). Any gain threshold loose enough not to also truncate legitimate high-wavenumber signal at lower frequencies (where the correction is legitimately 5-8x) would have to sit below ~9x to catch this tone - it can't do both. A gain cap and a contamination-frequency notch guard against different failure modes (general amplification of noise near Nyquist vs. a specific deterministic tone at a specific frequency); gain alone doesn't solve this one.

`contam_freq_hz` is therefore a fixed, per-deployment, `setup.yml`-configurable frequency [Hz]: after the noise-floor search above produces `fc_index`, it's additionally capped so `f(fc_index) < contam_freq_hz`. Defaults to `Inf` (no cap) - **this is deliberately not silently populated with 59 Hz for every deployment**. ASTRAL is the only deployment characterized so far; a different deployment's electronics/rigging could easily have a different (or no) contamination line, and using an unverified value would be worse than no cap at all. Setting a real value for a given deployment means repeating this same median-spectrum-across-scans check against that deployment's own data first.

The crossing search itself (smoothing already applied by the caller, threshold comparison, `contam_freq_hz` cap) is factored out into `mod_scan_fpo7_cutoff_search.m` so a second caller can run the identical search against a different noise-floor curve - `MODvis_spectra.m`'s live "cutoff (modeled)" checkbox (see below) uses it to run this same search against the theoretical noise floor (`mod_scan_fpo7_modeled_noise_f.m`) instead of the bench-measured one, so the two noise-floor choices can be compared on an otherwise identical algorithm rather than mixing in unrelated algorithm differences.

### 4. `toolbox/seawater/ktemp.m` — ktemp

```matlab
ktemp = ktemp(SP, SR, T, P)   % [psu, g/kg, degC, dbar] -> m^2/s
```

Lives in `toolbox/seawater/` alongside `visc.m`, not `processing/scans/` - both are pure seawater-property functions of salinity/temperature/pressure with no `metadata`/scan-struct argument. Originally `processing/scans/mod_scan_thermal_diffusivity.m`; moved and renamed 2026-09-08 to sit next to `visc.m`, which it mirrors.

`ktemp = k / (rho * cp)` (thermal conductivity / density / specific heat). Density and specific heat are computed via the vendored GSW/TEOS-10 toolbox (`gsw_rho.m`/`gsw_cp_t_exact.m`, fed Reference Salinity - see [Units and the sw_->gsw_ migration](../concepts/units_and_seawater.md)), migrated 2026-09-08 from this repo's original CSIRO/UNESCO-1983 (EOS-80) `sw_dens.m`/`sw_cp.m` - deliberately **not** `MOD_fish_lib`'s bespoke `density.m`/`cp.m`, which compute the same physics in a confusingly different, semi-auto-detected unit convention (salinity as a ~0.03-scale mass fraction, pressure in MPa, with a "if s>1, guess it's PSU and divide by 1000" heuristic). Thermal conductivity itself (Caldwell 1974) has no GSW/TEOS-10 equivalent, so it's still ported as a local subfunction, still fed Practical Salinity (the formula it was calibrated against) rather than Reference Salinity - with its pressure term corrected to expect dbar (this repo's standard) and convert to MPa internally; the original's one caller in `MOD_fish_lib` passed CTD pressure straight through in dbar into a formula documented as wanting MPa, a small (not factor-of-2) error on an already-minor correction term, flagged rather than silently reproduced.

**Verified**: `ktemp(SP=35, SR=gsw_SR_from_SP(35), T=10, P=1000) ≈ 1.4e-7 m^2/s` - in the expected ~1.4e-7 m²/s range for seawater, with the correct (small) pressure sensitivity (see the GSW migration sandbox suite for a live re-check against the current `(SP, SR, T, P)` signature).

### 5. `mod_scan_fpo7_volts_to_Tg_spectrum.m` — shared spectrum conversion

```matlab
scan = mod_scan_fpo7_volts_to_Tg_spectrum(scan, metadata, channel)   % scan.spectra.f, .Pt_volt_f, scan.w in; scan.spectra.k, .Pt_Tg_k added
```

The first three steps both chi estimators need, split into its own function once `chi_mle` needed the identical conversion `chi_obs` already did (originally these lived inline in one monolithic `MODprocess_L2_calc_chi.m`):

1. `Pt_T_f = Pxx * volts_to_C(1)^2` (slope-squared - equivalent to a second `pwelch` of the calibrated-to-degC signal, since `pwelch` detrends and `detrend(a*x+b) = a*detrend(x)`, so no second FFT is needed).
2. Deconvolve both the FP07 thermal rolloff AND the AFE electronics/ADC response: `H_total = electronics_filter .* mod_scan_fpo7_transfer_function(f, w, tau0, exponent); Pt_T_f = Pt_T_f ./ H_total` - the thermal half is **the step that was missing from `MOD_fish_lib`**; `tau0`/`exponent` come from `metadata.PROCESS.CHI.time_constant_s`/`.fall_speed_exponent` (validated at the top of `mod_scan_fpo7_volts_to_Tg_spectrum.m` - see "Where these values live" below); the electronics half (`electronics_filter`, normally `metadata.AFE.(ch).electronics_filter` from Module 2b) is still optional (default 1, no correction) so existing callers built before that parameter existed keep working - it's a resolved calibration, not a yaml-configurable choice, so it isn't part of the validated set.
3. `k = f / abs(w)`; `Pt_Tg_k = (2*pi*k).^2 .* Pt_T_f * abs(w)` (temperature-gradient wavenumber spectrum).

Keeping this in one place means a tau sensitivity comparison (`tau0`/`exponent` overrides) applies identically to `chi_obs` and `chi_mle`, rather than risking the two drifting out of sync - same reasoning now extends to the electronics correction.

### 6. `mod_scan_calc_chi_obs.m` — direct-integration chi_obs

```matlab
scan = mod_scan_calc_chi_obs(scan, metadata, channel, noise_coefs)   % scan.spectra.f, .Pt_volt_f, scan.w, .ktemp in; scan.chi_obs, .chi_obs_kc added (scan.spectra.k, .Pt_Tg_k, .fc_index also kept, not discarded)
```

Renamed from `MODprocess_L2_calc_chi.m` once a second estimator (`chi_mle`, Module 8) existed and the ambiguous plain "chi" needed disambiguating everywhere - the function, its output variable, and every field/variable that held its result (`MODprocess_single_L1_to_L2.m`'s `L2data.chi`/`chi_kc` → `L2data.chi_obs`/`chi_obs_kc`) were all renamed together.

Calls Module 5, then integrates from `kmin = metadata.PROCESS.CHI.kmin_obs` (historically 3 cpm, unchanged from `mod_efe_scan_chi.m`, but now a real yaml-configurable value - see "Where these values live" below) to `kc` (the noise-floor cutoff, Module 7 below): `chi_obs = 6 * ktemp * dk * sum(Pt_Tg_k(kmin <= k <= kc))`.

`chi_obs` is `NaN` (not an error) if `kc <= kmin` - a scan where the FP07 signal never rises above the noise floor within the integrable wavenumber range at all.

`tau0`/`exponent` are resolved the same way as Module 5 (metadata, not function arguments) - a tau sensitivity comparison is a `metadata.PROCESS.CHI.time_constant_s` edit (see "Running a tau sensitivity comparison" below), not a code edit or a second function argument.

**No figure-of-merit QC flag** - `mod_efe_scan_chi.m` computes one (`compute_fom.m`) alongside its own chi/chi_mle. Left as a clearly-scoped-out follow-up, same as before.

Wired into `MODprocess_single_L1_to_L2.m`: scan-center `temperature`/`salinity` are interpolated the same way `pressure`/`w` already were, and `chi_obs.(channel)`/`chi_obs_kc.(channel)` get computed automatically for every fpo7 channel with a resolved `volts_to_C`, whenever the bench noise file (see below) is present - no changes needed to `MODprocess_all_L1_to_L2.m` itself, since it already calls through to the per-file function.

### 7. `toolbox/theoretical_spectra/batchelor_spectrum.m` — chi_mle's spectral model

```matlab
Psg = batchelor_spectrum(epsilon, chi, nu, ktemp, k)   % theoretical spectrum, evaluated at k
```

The theoretical Batchelor (1959) temperature-gradient spectrum, ported from the "evaluate at a given k" local subfunction inside `mod_efe_scan_chi.m` (not the self-gridding `EPSILOMETER/EPSILON/process/batchelor.m` variant used elsewhere purely for plotting). Physically: turbulence at rate `epsilon` stirs water past the FP07 down to the Kolmogorov scale, and molecular diffusion (`ktemp`) smooths structure below the Batchelor wavenumber `kb = (epsilon/nu/ktemp^2)^(1/4)` - `kb` sets the spectrum's *shape* and depends only on `epsilon`/`nu`/`ktemp`, while `chi` is a pure multiplicative *amplitude*: `Psg(k) = chi * shape(k; epsilon,nu,ktemp)`. This linearity is exactly what makes Module 8's MLE fit a 1-D amplitude search rather than a nonlinear multi-parameter one.

`nu` (kinematic viscosity, the other water property `kb` needs beside `ktemp`) is just `toolbox/seawater/visc.m`, called directly by whoever calls this function - no `MODprocess_L2_kinematic_viscosity.m` wrapper. GSW has no official kinematic-viscosity function, so `visc.m` is the one deliberate exception to this repo's otherwise-complete sw_->gsw_ migration - see [Units and the sw_->gsw_ migration](../concepts/units_and_seawater.md). Unlike `toolbox/seawater/ktemp.m` (which combines `gsw_rho`/`gsw_cp_t_exact` with a ported thermal-conductivity term nothing else in this repo has - genuinely new logic), a wrapper here would have been a single pass-through line with no logic of its own to justify a separate documented function.

### 8. `mod_scan_calc_chi_mle.m` — Batchelor-spectrum MLE chi_mle

```matlab
scan = mod_scan_calc_chi_mle(scan, metadata, channel, noise_coefs)   % scan.spectra.f, .Pt_volt_f, scan.w, .ktemp, .nu, .epsilon in; scan.chi_mle, .chi_mle_kc added (scan.spectra.k, .Pt_Tg_k, .fc_index also kept)
```

Fits the Batchelor spectrum to the same observed temperature-gradient spectrum `chi_obs` integrates directly, via Maximum Likelihood Estimation (Ruddick, Ozsoy & Vagle 2000) - a from-scratch reimplementation of the same fixed-epsilon method as `MOD_fish_lib`'s `get_chi_mle.m`/`mle_any_model.m`/`logLikelihood.m`, not a line-by-line port:

1. Module 5 + Module 7's noise-floor cutoff give the same `[kmin, kc]` range `chi_obs` uses.
2. Seed a search range from `chi_obs`'s own direct-integration value on that range (cheap, and a reasonable order-of-magnitude start - same idea as `mod_efe_scan_chi.m` seeding off its already-computed chi).
3. Grid-search for the `chi` that maximizes the log-likelihood of the observed spectrum given the model `chi * shape(k; epsilon,nu,ktemp)` under a `dof`-degree-of-freedom scaled chi-squared distribution (Ruddick et al. 2000 eq. 16-17) - a fixed 4-pass, 200-point log-spaced zoom around the best candidate each pass, rather than the original's open-ended edge-widening while-loops. This grid-search zoom (`processing/scans/mod_scan_mle_grid_search.m`) is shared with `mod_scan_calc_epsilon_mle.m` (branch `epsilon_processing`) - see [Epsilon (shear turbulence)](L2_calc_eps.md).

**`epsilon` is now wired in** - `modProcess_L2_calc_epsilon.m` (shear-channel Nasmyth fit, branch `epsilon_processing`) computes one, and `mod_L2_tile_scans.m` now calls `mod_scan_calc_chi_mle.m` for every scan where a finite epsilon estimate is available (the mean, per `metadata.PROCESS.EPSILON.epsilon_final_source`, across this deployment's shear channels - a per-scan simplification of the full profile-level selection MOD_fish_lib's legacy pipeline does; see [Epsilon (shear turbulence)](L2_calc_eps.md)'s "Known limitations"). Still fully usable standalone wherever an epsilon estimate already exists from elsewhere - which is exactly the case for the ASTRAL comparison below, since an old-format `MOD_fish_lib` `Profile####.mat` already carries a per-scan `epsilon_final`.

**No figure-of-merit QC flag either** - same scoping as `chi_obs`.

## Where these values live: `metadata.PROCESS.CHI.*` is never silently defaulted

`kmin_obs`, `time_constant_s`, `fall_speed_exponent`, `noise_adjusted_to_f`, `n_smooth_f_spectrum`,
`sn_min`, `n_skip`, `contam_freq_hz`, `chi_mle_start_search`,
`chi_mle_end_search` - the ten operator-tunable parameters this chain reads - are **not** filled with a historical default by
`MODsetup_read_yaml.m` when a deployment's `setup.yml` doesn't declare a `chi:` block (a FastCTD
deployment needs none of them, so silently populating all eleven for every deployment would be wrong,
not just undocumented). Instead, each of the five functions above validates exactly the values it
(and anything it calls in turn) needs, as literally the first thing it does:

```matlab
metadata = MODsetup_validate_metadata(metadata, yaml_file, {'kmin_obs', 'time_constant_s', ...});
```

If everything requested is already in `metadata`, this is a no-op. If something is missing,
`MODsetup_prompt_value.m` asks for it (a dialog if there's a display, a text prompt if not, a hard
error under `-batch` - never a silently-fabricated value) and offers to save the answer into
`setup.yml` via `MODsetup_write_yaml_value.m`. If saved, `MODsetup_validate_metadata.m` raises
`MODsetup_validate_metadata:yamlUpdated` instead of returning - the caller's enclosing loop (see
`MODprocess_all_L1_to_L2.m`'s per-file retry wrapper) is expected to catch that identifier, reload
metadata fresh via `MODsetup_read_yaml.m`, and retry from the start, rather than resuming mid-way
with two different metadata structs in play. See `setup/MODsetup_metadata_field_registry.m` for
every value's `setup.yml` location, `metadata` location, description, and historical default (shown
as the prompt's starting point only, never applied on its own).

## Calibration file: `MOD_fish_calibrations/FPO7/FPO7_benchnoise.mat`

Copied from `MOD_fish_lib/EPSILOMETER/CALIBRATION/FPO7/FPO7_notdiffnoise.mat`, renamed for clarity (see `MOD_fish_calibrations/FPO7/README.md` for full provenance) - contents (`n0`, `n1`, `n2`, `n3`) unchanged. "notdiffnoise" ("not differentiated") describes that this is the noise floor for raw FP07 voltage, as opposed to an analog-differentiated dT/dt signal (`FPO7_noise.mat`, the "Tdiff" variant - not copied, not relevant here, see Module 2 above). Not per-probe - one shared bench constant, resolved via `metadata.paths.calibrations_root` the same way SBE/shear cal files are, just without a per-SN subfolder.

**Not yet committed to `MOD_fish_calibrations`** - that repo has an unrelated, in-progress uncommitted `README.md` edit (tag-naming convention update) that shouldn't be swept up in this branch's commit.

## Calibration file: `MOD_fish_calibrations/SHEAR/cap1nFres200Meg_5KohmInput.mat`

Copied from `MOD_fish_lib/EPSILOMETER/EPSILON/FILTER/cap1nFres200Meg_5KohmInput.mat` (a network-analysis measurement, `freq`/`coef_filt`) - the shear probe charge-amp electronics filter `MODsetup_define_filters.m`'s shear branch needs. Not per-probe - one shared bench measurement, like the FPO7 noise file above. Also **not yet committed** to `MOD_fish_calibrations`, same reason as above.

## Running a tau/chi_obs-vs-chi_mle comparison

`analysis/chi_tau_mle_comparison.m` (a one-off comparison script, not a `MODprocess_` pipeline function - added in commit `6dfe18a`, removed again in `d1ebd5d` once its results below were recorded; not present in the working tree) was the actual point of this whole branch: call `mod_scan_calc_chi_obs.m` and `mod_scan_calc_chi_mle.m` each twice, once at the historical (wrong) `tau0=0.005` and once at a candidate `tau0=0.0086` (the middle of `astral_chi.md`'s documented 0.0083-0.0089 s range), and compare all four results. The numbers below are exactly as that script (and the scalar-arg `mod_scan_calc_chi_obs`/`mod_scan_calc_chi_mle` signatures that existed at the time) produced them. Reproducing the comparison today, against the current `(scan, metadata, channel, noise_coefs)` signature (PLAN.md's "mod_scan_* functions" guiding principle - `tau0` is now a metadata override, not a function argument) would look like (`metadata` here already has every other `PROCESS.CHI.*` value set - "Where these values live" above - only `time_constant_s` is being overridden for the comparison):

```matlab
metadata_default = metadata;
metadata_default.PROCESS.CHI.time_constant_s = 0.005;
metadata_candidate = metadata;
metadata_candidate.PROCESS.CHI.time_constant_s = 0.0086;

scan.spectra.f = f; scan.spectra.Pt_volt_f = Pxx; scan.w = w; scan.ktemp = ktemp;
chi_obs_default   = mod_scan_calc_chi_obs(scan, metadata_default,   channel, noise_coefs);
chi_obs_candidate = mod_scan_calc_chi_obs(scan, metadata_candidate, channel, noise_coefs);

scan.nu = nu; scan.epsilon = epsilon;
chi_mle_default   = mod_scan_calc_chi_mle(scan, metadata_default,   channel, noise_coefs);
chi_mle_candidate = mod_scan_calc_chi_mle(scan, metadata_candidate, channel, noise_coefs);
```

Run against a real ASTRAL profile (`epsi_mako/astral/profiles/Profile100.mat`) rather than `blt2021_0715` - an old-format `MOD_fish_lib` `Profile` struct, not this repo's own L2 output, but its `Pt_volt_f.(ch)` field is exactly the raw FP07 voltage spectrum both chi functions expect as `Pxx`, so no `.modraw` reprocessing was needed. It also already carries a per-scan `epsilon_final`, which is what makes `chi_mle` runnable at all here even though this repo doesn't compute epsilon yet (see Module 8, and the script's own header for the full list of old-format-specific assumptions - notably: `volts_to_C`'s slope comes from this file's own pressure-binned `cal_profile`, not a fresh `MODprocess_L1_apply_fpo7_calibration.m` fit).

## Real test results

### `blt2021_0715` sandbox, one descending profile, 1516→1782 dbar, 64 scans (chi_obs only, default tau)

| channel | n valid chi_obs | chi_obs range (degC²/s) | chi_obs median | kc range (cpm) |
|---|---|---|---|---|
| t1 | 64/64 | 9.0e-11 – 5.5e-8 | 3.1e-9 | 18.0 – 108.4 |
| t2 | 64/64 | 5.7e-9 – 2.3e-6 | 6.0e-7 | 59.7 – 217.8 |

t1's chi_obs looks like an unremarkable, quiet deep-water value. **t2 is ~200x higher, with a correspondingly higher kc** - consistent with t2's visibly noisier (volts, T) calibration scatter (see Module 1 above). Read as a real t2 data-quality issue (noise/vibration/probe difference letting extra spectral power past the noise-floor cutoff), not a bug in the chi calculation - same code path produces a clean t1 result from the same scan, same time.

### ASTRAL `Profile100.mat`, 317 scans, `analysis/chi_tau_mle_comparison.m`

| channel | chi_obs median (tau0=0.005 → 0.0086) | chi_mle median (tau0=0.005 → 0.0086) | chi_mle / chi_obs (default tau) |
|---|---|---|---|
| t1 | 3.23e-9 → 4.00e-9 (**1.24x**) | 6.49e-9 → 7.62e-9 (**1.17x**) | **2.01x** |
| t2 | 4.04e-9 → 5.12e-9 (**1.27x**) | 7.19e-9 → 8.68e-9 (**1.21x**) | **1.78x** |

(310/317 scans had a valid `chi_obs`/`chi_mle` noise-floor cutoff on both channels; 299/317 also had a positive `epsilon_final` needed for `chi_mle`.)

**Both changes push chi up, and both matter, but the MLE-vs-direct-integration choice is the bigger of the two on this profile**: correcting tau (0.005 → 0.0086) raises chi_obs/chi_mle by ~17-27%, while switching from chi_obs to chi_mle at a fixed tau roughly doubles chi (1.78-2.01x). Physically sensible in both directions - a larger tau means the FP07 rolloff correction boosts more high-wavenumber content before integration (larger tau -> more correction -> larger chi), and chi_mle recovering variance past the noise-floor cutoff that direct integration simply truncates is exactly the effect Module 8 exists to capture. Neither result should be read as "the other method is wrong" - they're answering slightly different questions (what's in the healthy spectrum vs. what the full Batchelor spectrum implies given that same data), which is why `astral_chi.md` wanted both computed side by side in the first place.

### ASTRAL `Profile100.mat` vs. `electronics_filter` (Module 2b) - does chi_obs now reproduce `Profile.chi`?

Back-solving `Profile100.mat`'s own stored `Pt_Tg_k` for the deconvolution it was generated with (frequency-by-frequency, against 10 points spanning the spectrum) matched `MOD_fish_lib`'s `H.FPO7 = H.electFPO7² .* H.magsq(speed)` to 4 significant figures - confirming Profile100.mat was itself computed at tau0=0.005 **with** the electronics term, not some other tau and not without it. Adding `electronics_filter` (Module 2b's sinc⁴ formula) to `chi_obs`/`chi_mle` at tau0=0.005 and comparing scan-by-scan against `Profile.chi(:,1)`/`(:,2)`:

- For scans where the noise-floor cutoff `kc` this repo computes matches `Profile.tg_kc` (most scans in the profile's upper-middle depth range, spot-checked against scans 5-27), `chi_obs` with `electronics_filter` now lands at **85-100% of `Profile.chi`** - a large improvement over the same scans without it (previously 30-90%, and often the wrong side of "systematically low" the original investigation flagged).
- Across the **full** 317-scan profile, though, the per-scan `chi_obs(elec) / Profile.chi` ratio has a much wider spread - median ~0.39-0.40, 10th/90th percentile ~0.13/~1.0 (see `analysis/chi_tau_mle_comparison.m`'s report). This is **not** attributable to `electronics_filter` itself (verified: using the old-format file's flat `Meta_Data.AFE.t1.cal` instead of its pressure-binned `cal_profile` makes the full-profile match *worse*, not better, ruling out calibration-source noise as the main driver) - it traces back to the same open `kc` question flagged under Module 3: recomputing the noise-floor cutoff from `Profile100.mat`'s own stored `Pt_volt_f` with the same bench noise coefficients doesn't reproduce `Profile.tg_kc` for a meaningful fraction of scans, for reasons not yet root-caused (see Known limitations).

## Known limitations

- **No figure-of-merit QC flag** for either chi_obs or chi_mle (see Modules 6 and 8). Deferred as a follow-up module.
- **t1/t2 chi discrepancy on `blt2021_0715` not yet root-caused** - see "Real test results" above. Worth investigating before trusting t2 for anything gamma-related on that deployment.
- **Full-profile `chi_obs`/`Profile.chi` match still has a wide residual even with `electronics_filter` applied** (see "ASTRAL `Profile100.mat` vs. `electronics_filter`" above) - median per-scan ratio ~0.4, not the ~0.9-1.0 seen for the subset of scans where `kc` matches `Profile.tg_kc`. Traced (not yet root-caused) to `kc` itself diverging from `Profile.tg_kc` for many scans despite identical bench noise coefficients and algorithm - not a gap in the electronics/thermal deconvolution math, which is independently verified against Profile100's own stored spectrum to 4 significant figures.
- **`cal_profile`-based `volts_to_C` in `analysis/chi_tau_mle_comparison.m` is old-format-specific** - it reads a pressure-binned in-situ calibration already present in `Profile100.mat`, not a fresh deployment-wide fit from `MODprocess_L1_apply_fpo7_calibration.m`. Fine for this comparison, but not a template for how this repo's own L1→L2 pipeline gets `volts_to_C`.
- **`FPO7_benchnoise.mat`/`cap1nFres200Meg_5KohmInput.mat` not yet committed** to `MOD_fish_calibrations` (see "Calibration file" sections above).

Two limitations this section used to list here are resolved as of branch `epsilon_processing` - `chi_mle` is now wired in (see Module 8 above) and shear/accel `electronics_filter` now has a real consumer (`mod_scan_shear_volts_to_shear_spectrum.m`) - see [Epsilon (shear turbulence)](L2_calc_eps.md) for what's still open on that side (its own "Known limitations" covers the epsilon-specific gaps: the per-scan, not profile-level, epsilon selection feeding `chi_mle` here; the unconfirmed coherence-band field values; `modProcess_L2_qc.m` not built).

## History

Built on branch `chi_processing`, off `l1_to_l2_conversion`. `chi_obs` (originally just "chi") - 2026-07-27, one module at a time, each tested standalone against real `epsi_mako/blt2021_0715` data in a scratchpad sandbox copy (`meta`/`calibrations`/`L1` only - `L0`/`raw` left out, ~930 MB not needed for this work) before being wired into the next piece. See PLAN.md Section 12 session log entry (2026-07-27) for full numbers. `chi_mle` (plus the `chi` → `chi_obs` rename across the codebase) - 2026-07-28, ported from `MOD_fish_lib`'s Ruddick-et-al.-2000 MLE machinery and validated end-to-end against real ASTRAL data. See PLAN.md Section 12 session log entry (2026-07-28).

**2026-09-08, branch `epsilon_processing`:** `chi_mle` wired into `mod_L2_tile_scans.m`, and its grid-search zoom (`mle_search_chi`) split out into the shared `toolbox/mod_scan_mle_grid_search.m` once `mod_scan_calc_epsilon_mle.m` needed the identical search machinery - see [Epsilon (shear turbulence)](L2_calc_eps.md) for the full epsilon module this unblocked. Verified behavior-preserving by a synthetic-data regression check (a known-chi Batchelor spectrum, noiseless, recovered to <0.01% by the refactored search) before and conceptually after the extraction - see that doc's "How to run it"/verification notes.

`MODsetup_define_filters.m` (AFE electronics/ADC term, Module 2b) - also 2026-07-28, found while comparing this repo's `chi_obs` directly against a real `Profile100.mat`'s `Profile.chi` (a comparison the `chi_mle` validation above didn't do): `chi_obs` came out systematically low, traced to the AFE sinc⁴ ADC response `mod_scan_fpo7_transfer_function.m`'s own docstring had already flagged as deliberately excluded. Implemented per PLAN.md Section 6.2's design note (fpo7/shear/acc, not just fpo7 - shear/acc resolved for future use, not yet consumed). See PLAN.md Section 12 session log entry (2026-07-28) and "ASTRAL `Profile100.mat` vs. `electronics_filter`" above for validation results and the residual full-profile `kc` question this surfaced.
