# Microconductivity chi

Microconductivity probe has an ADC filter that is hardwired into the SBE7 analog board. The EFE digitizes the output of the SBE7. The microconductivity probe takes over the s2 channel of the EFE board.

In the setup yml the probe is an AFE channel of type `microcond`, usually named `c1` in slot 4
(`acquisition/presets/fctd*.yml`: `ch4_type: microcond`). Like every EFE channel it's stored as
volts (`epsi.c1_volt`) at L0 and L1, and `mod_scan_get_spectra.m` makes its raw spectrum
(`spectra.c1_volt_f`) for each L2 scan. What's computed from it is decided by the channel type,
not by the fish (`fish_flag`): any vehicle with a `microcond` channel, a fitted gain and real CTD
T/S gets `microconductivity.chi_obs`, `chi_tot` and `eps_chi`, as any vehicle with an `fpo7` channel gets FP07 chi
([FP07 calibration and chi](L2_calc_chi.md)).

This is a port of MHA's v3 microconductivity chi (MOD_fish_lib
`FastCTD_MATLAB/Dehysteresis_and_microconductivity/microconductivity/`): the measured chi, and
its correction for the unresolved part of the spectrum (`chi_tot`, `eps_chi`, Alford and Pinkel
2000b). A vehicle has only one microconductivity probe, so L2's and the gridded data's
`microconductivity` struct has no channel in its names (`microconductivity.chi_obs`, ...); with
more than one `microcond` channel, L2 uses the first and warns.

## The chain

### 1. Gain: `MODprocess_L1_apply_ucond_calibration.m` (L0 → L1)

Fits the channel's gain [S/m per V] against the CTD conductivity, once per deployment, like the
FP07 `volts_to_C` fit. Run by `MODprocess_all_L0_to_L1.m` after the pressure record is built,
for a vehicle with its own CTD, on the same cadence as the FP07 fit (`'fpo7_refit_new_files'`).
Saved to `processed/<run>/meta/ucond_calibration.mat` (`volts_to_S_per_m.(ch)`, `sn`, `fitted`,
`n_L1_files`) and loaded back into `metadata.AFE.(ch).volts_to_S_per_m` by
`MODsetup_add_derived_metadata.m`, only for a channel that's still `microcond` with the same
probe SN. Both probe fits are listed in `setup/MODsetup_probe_fits.m`.

- Windows of `ucond.gain_fit_window_s` are placed in each stretch where the fish moves the whole
  time (`abs(dPdt)` above `profile_detection.speedLim_scan_m_s`) one way that
  `profile_detection.profile_dir` trusts, as many as fit, centered in the stretch.
- Microconductivity works on up- and downcasts, so FCTD deployments use `profile_dir: both` (Start
  New Deployment's Profiling menu; the FCTD presets start as `both`). Then L2 has scans, and the
  fit has windows, in both directions.
- A window is skipped when either record has a gap (`ctd_gap_factor` / `epsi_gap_factor` times
  the median sample interval) or the probe is railed (a sample at `ucond.rail_fraction` of the
  channel's `full_range` or beyond).
- In each window: `gain = sqrt(mean P_C / mean(P_c1 / H2))` from 0 to `ucond.gain_fit_fmax_hz`,
  where `P_C` is the CTD conductivity spectrum, `P_c1` the `c1_volt` spectrum and `H2` the
  electronics response (step 2). Each is one Hann-windowed periodogram of the whole window.
- Windows above `ucond.gain_fit_max` are left out and the rest averaged. The console prints the
  gain, how many windows it's from and their standard deviation.

### 2. Electronics: `mod_scan_ucond_electronics_filter.m`

Set once per deployment as `metadata.AFE.(ch).electronics_filter` by
`MODsetup_define_filters.m` (`microcond` case), and used again by the gain fit at its own
frequencies. Measured power = true power × `H2`, with three terms:

- **SBE pre-emphasis**, which boosts high frequencies above the ADC noise:
  `H_pre = 1 + Rf*R22/(R22^2 + w1^2) + i*Rf*w1/(R22^2 + w1^2)`, `Rf = R24 + R25`,
  `w1 = 1/(2*pi*f*C19)`, following Steve Anderson and Alford and Pinkel (2000). Legacy removed
  it from the time series (`remove_sbe_preemphasisMHA.m`); here it's divided out of the
  spectrum, which is the same for chi.
- **The SBE7 anti-alias filter** (the note above): `sinc(f/f_Nyquist)^p` on the power spectrum,
  `p = ucond.antialias_sinc_power` (legacy `DoOneChi_MHA_v3.m`: 2).
- **The EFE ADC filter** (`mod_scan_adc_filter.m`), squared, as for every EFE channel.

### 3. chi: `mod_scan_calc_chi_ucond.m` (L1 → L2, each scan)

1. `P_C(f) = c1_volt_f * gain^2 / electronics_filter`
2. `k = f/abs(w)`, `Phi_dCdz(k) = (2*pi*k)^2 * P_C(f) * abs(w)`
3. `dT/dC = 1/(dC/dT)`, with `dC/dT` from GSW (`gsw_C_from_SP`, a centered difference in T) at
   the scan's SP, T and P
4. `chi_ucond = 6 * ktemp * (dT/dC)^2 * dk * sum(Phi_dCdz)` from `ucond.kmin_cpm` to
   `kmax = min(ucond.kmax_cpm, ucond.fmax_hz/abs(w))`

NaN for a railed scan. kmax is far below the Batchelor wavenumber, so **this chi is an
underestimate**, by a factor that grows with epsilon. Step 5 corrects for that.

### 4. N^2 around the scan: `mod_scan_n2_local.m`

The CTD samples that stay within `ucond.stratification_half_dz_m` of the scan-center depth,
walking out from the scan center in time both ways (so only the scan's own cast); their sigma0
sorted into a stable profile (a Thorpe sort, which takes out overturns - where the turbulence is);
and a least-squares line of sorted sigma0 against depth: `N^2 = g/rho0 * d(sigma0)/dz`, never
negative. Sorting only the window works the same in realtime as by profile (sorting the whole
cast first is only possible by profile). A line over a depth
window keeps one noisy sample or the fish's wobble from setting the gradient, and a window in
meters doesn't depend on fall speed. NaN when the samples span less than half the window (the
window runs off the end of the file or the cast).

### 5. chi_tot and eps_chi (Alford and Pinkel 2000b), in `mod_scan_calc_chi_ucond.m`

Assuming stratified turbulence with mixing efficiency gamma:

- `chi_pe = g*alpha/rho * chi_obs/N^2 * (1 + 1/Rrho^2)`
- `eps_chi = (2*gamma*c)^(-1/(p+1)) * chi_pe^(1/(p+1))`
- `r = c * eps_chi^p` (the fraction of chi resolved), `chi_tot = chi_obs / r`

alpha, rho and g are from GSW at the scan (legacy used g = 9.8 and rho = 1026); Rrho, gamma, c
and p are yml values. NaN where N^2 <= 0. Each scan is corrected before gridding, as legacy
corrected each sample: eps_chi goes as chi^1.67, so the mean of corrected scans isn't the
correction of the mean.

**The `chi_pe` expression is legacy's as written.** It isn't the textbook buoyancy flux,
`(g*alpha)^2 * chi / (2*N^2)`; the two are equal only when `g*alpha*rho = 2`, i.e. alpha near
2e-4 /K. MHA fit c (5e-5) with this form, so it's kept; ask MHA before changing either.

**Outputs.** L2's `microconductivity` struct:
- `chi_obs`, the measured chi
- `chi_obs_kmax`
- `chi_tot`
- `eps_chi`
- `n2`, the N^2 used

L2 also keeps the spectrum it integrated, `spectra.<ch>_dCdz_k` (and `spectra.k` when there's no
FP07 chi). The gridded data gets the same five as bin means of the corrected scans.

## Parameters: the yml's `ucond` block

Nothing is hard-coded: each value is in the cruise yml's `ucond` block (registered in
`MODsetup_metadata_field_registry.m`, needed by preflight whenever a channel is `microcond`).
A missing value makes the survey wait for parameters; it's never filled in silently.

| Key | Suggested | What |
|---|---|---|
| `preemphasis_R22_ohm`, `preemphasis_R24_ohm`, `preemphasis_R25_ohm`, `preemphasis_C19_F` | 266.1, 1e6, 577e3, 1e-6 | Pre-emphasis circuit design values (not a calibration), for removing the pre-emphasis filter following Steve Anderson and Alford/Pinkel 2000 |
| `antialias_sinc_power` | 2 | SBE7 anti-alias correction power (0 = none) |
| `gain_fit_window_s` | 30 | Gain-fit window. Must fit inside one profile: FCTD upcasts at ~2.3 m/s over 100 m last ~50 s |
| `gain_fit_fmax_hz` | 2 | Gain-fit band, 0 to this |
| `gain_fit_max` | 100 | Windows with a larger gain are left out |
| `rail_fraction` | 0.999 | A sample at this fraction of `full_range` or beyond means the probe is railed |
| `kmin_cpm`, `kmax_cpm` | 1, 12.5 | Integration band |
| `fmax_hz` | 50 | Never integrate past this frequency (`kmax <= fmax_hz/abs(w)`) |
| `stratification_half_dz_m` | 10 | N^2 depth window: CTD samples within this of the scan's depth, on its cast |
| `rrho` | 5 | Density ratio, one constant (legacy 5; MHA: the dependence on it is weak) |
| `ap00b_gamma` | 0.2 | Mixing efficiency |
| `ap00b_c`, `ap00b_p` | 5e-5, -0.4 | `r = c*eps^p`; Alford and Pinkel 2000b used c = 2.5e-5, MHA found 5e-5 for kmax = 12.5 cpm (Feb 2025) |

## Differences from legacy

| Legacy (MOD_fish_lib) | Here |
|---|---|
| Pre-emphasis removed from the time series by FFT | Divided out of each scan's spectrum |
| Gain in counts/2^24 (nominal 22) | Gain in S/m per V (the 25_0409 survey: 1.57; 22/5 = 4.4 would be legacy's nominal in these units) |
| Gain windows: 100 s around the middle of each profile, across turnarounds | Windows inside one steady, trusted-direction stretch; railed windows skipped |
| `FCTD_ucon_cal.m` ucon spectrum with `dt = 1/160` on 320 Hz data | The real sample rate |
| 2 s windows every 0.25 s, 0.5 s FFTs, then interpolated to 16 Hz | This deployment's L2 scans (`fft_length`, `fft_segments_per_scan`, `scan_overlap`) |
| D = 1.4e-7 | The scan's `ktemp` |
| dC/dT = 0.1(1 + 0.006(T - 20)) | From GSW at the scan's SP, T, P |
| Spectrum of the first difference | `(2*pi*k)^2`, the exact derivative (as FP07 chi) |
| No EFE ADC filter correction | EFE ADC filter divided out on top of the SBE7 sinc^2 |
| N^2: density (`sw_pden`) smoothed over 500 CTD samples along the record (~31 s, ~70 m at 2.3 m/s, across turnarounds), differenced against pressure | A line of sigma0 vs depth within `stratification_half_dz_m` on the scan's cast |
| Rrho computed, then overwritten with 5 | `rrho` from the yml (5) |
| g = 9.8, rho = 1026, alpha from `sw_alpha` | GSW at the scan |
| Corrected per 16 Hz sample | Corrected per scan |

## Test results

**25_0409 dye survey (FCTD1), first 24 raw files (07:26-09:35), sandbox** (2026-10-20). The
probe is railed at -2.5 V from 08:01 on: windows and scans after that are skipped.

- Gain: 1.571 S/m per V, from 8 windows (std 0.17). With the fixed 100 s windows first tried, no
  window fit inside an upcast; without the rail check, the railed windows gave gains of 0.7 to
  4000.
- L2: 1041 scans, 320 with `chi_ucond` (the others railed or too slow); median 5e-8 degC^2/s
  (5-95%: 3.5e-9 to 1.2e-6). kmax was 12.5 cpm on every scan (`abs(w)` < 4 m/s).
- Against legacy `DoOneChi_MHA_v3.m`, run on the same L1 (`c1_volt` through
  `remove_sbe_preemphasisMHA.m` times the same gain), at each scan with the scan's length and FFT
  length: `chi_ucond / legacy` median 1.10 (IQR 0.62-1.66, 267 scans). `ktemp / 1.4e-7`
  accounts for 1.02 and `(dT/dC GSW / SBE)^2` for 1.035; the rest is the spectrum. On fast scans
  (`abs(w)` > 1 m/s, 107) the ratio is 1.14 (IQR 0.90-1.37); the remaining scatter follows the
  different fall speeds (here the CTD `dzdt` at the scan center, legacy a smoothed `dPdt` mean
  over the window). With legacy's own 2 s windows and 0.5 s FFTs: median 1.34 (IQR 0.78-3.35).
- An Epsi survey (26_1019_mako2_test2, 6 files) gives identical L2 with and without this change.
- **chi_tot and eps_chi** (2026-10-21, same 319 scans before the probe railed):
  - 318 have eps_chi; 1 has no N^2 (its window ran off the file).
  - N^2 here vs legacy's: median ratio 1.21 over all scans (IQR 0.69-1.71), and 0.99 on fast scans
    (`abs(w)` > 1 m/s, 109 scans). Most of the scatter is near the surface, where the fish spent
    much of this stretch.
  - eps_chi vs legacy's formula with legacy's N^2 and alpha, on the same chi_obs: median ratio
    0.71 overall (IQR 0.40-1.76), 1.00 on fast scans; chi_tot median ratio 0.87. **The scan-by-scan
    scatter is large:** only 42% of scans have eps_chi within a factor 2 of legacy's (57% below
    20 dbar with `abs(w)` > 1 m/s; N^2 within 2x: 65% and 80%).
  - All of the eps_chi difference is the N^2 difference: eps_chi ratio / (N^2 ratio)^-1.67 is
    within 10% of 1 on every scan, so the formula port is exact. eps_chi goes as N^2^-1.67: a
    factor 2 in N^2 is a factor 3.2 in eps_chi.
  - N^2 depends strongly on the window, and no window matches legacy's along-record smoothing:

    | `stratification_half_dz_m` | N^2 within 2x of the 10 m one | within 2x of legacy (all / below 20 dbar, fast) |
    |---|---|---|
    | 2.5 | 53% | 42% / 69% |
    | 5 | 82% | 51% / 73% |
    | 10 | - | 65% / 80% |
    | 20 | 93% | 62% / 78% |
    | 35 | 61% | 63% / 72% |

  - Sorting the window's density before the fit (Nicole: "find density around the scan, sort
    it, and fit that") changed these by a few percent at most: eps_chi is small here (median
    1e-8 W/kg), so the overturns are small. Legacy's N^2 isn't a truth to match - it's density
    smoothed over 31 s along the record, across turnarounds and the surface - so this compares
    two choices rather than validating one.
  - The correction is large: chi_tot/chi_obs has median 13 (IQR 7-29).
  - Median eps_chi is 1.2e-8 W/kg.

## Known limitations

- **eps_chi and chi_tot are only as good as N^2**, and N^2 is the weak link: it changes by more
  than 2x between reasonable windows on a fifth to a third of the scans (Test results), which is
  3.2x or more in eps_chi. The window is a science choice, not settled here.
- **To do, by profile:** when postprocessing by profile (`'by', 'profile'`), sort the whole
  profile's density first, then take the window around each scan and fit (Nicole, 2026-10-21).
  Realtime keeps the window-only sort, since it has one L1 file at a time. Nicole also asked
  whether to smooth N^2 over 30 s instead, as legacy does; for now the depth window stays.
- `ap00b_c` was fit for kmax = 12.5 cpm; where `fmax_hz/abs(w)` sets a lower kmax (abs(w) > 4 m/s)
  the same c is used, as legacy does.
- MHA's caveat on the method: eps_chi "seems to be somewhat high when N2 is low" and "should be
  ... used with caution".
- Whether `antialias_sinc_power` = 2 (SBE7's filter) and the EFE ADC filter should both be
  divided out: the note at the top says the SBE7 filter is on the analog board and the EFE
  digitizes its output, so both are applied. At 50 Hz they're 0.71 and 0.72.
- An L2 file made before the gain was fit (or before a refit) isn't redone when the fit changes:
  the same as for FP07 chi.
- The gain is one number per deployment (a mean over windows); a probe that drifts within a
  deployment isn't followed.

## History

**2026-10-21 (evening) - Upcasts** (branch `main-fork`). Nicole: "microconductivity can be
calculated for both up and downcasts." No code here: Start New Deployment got a `both` Profiling
option, and the FCTD presets start with it. On a sandbox copy of 26_1021_fctd2_rupture_disc
reprocessed from L1 with `both`: the gain fit used 126 windows (28 from downcasts only) and gave
4.31 S/m per V (the worker's was 4.47). Every upcast has chi, and for each down/up pair the median
log10(up/down) chi_obs over shared bins is between -0.26 and 0.14.

**2026-10-21 - chi_tot and eps_chi** (branch `main-fork`). Nicole: "Let's do microconductivity
chi_tot and eps_chi." Her choices: N^2 per scan in L2 from the L1 CTD within a yml depth window, sorted
before the fit (`mod_scan_n2_local.m`), Rrho a yml constant, and no channel in the names ("we will only ever have
one microconductivity probe"): `microconductivity.chi_obs`, `.chi_obs_kmax`, `.chi_tot`,
`.eps_chi`, `.n2`. New yml values `stratification_half_dz_m`, `rrho`, `ap00b_gamma`, `ap00b_c`,
`ap00b_p`. Grid version 8. Tested as in Test results.

**2026-10-21 - Names** (branch `main-fork`). `chi_ucond.(ch)`/`chi_ucond_kmax.(ch)` are now
`microconductivity.<ch>_obs`/`microconductivity.<ch>_obs_kmax`, in L2 and the grid (the
turbulence structs - see [Processing data](processing_data.md) History). Test results above use
the old names.

**2026-10-20 - Microconductivity chi** (branch `main-fork`). Ported MHA's v3 chi (chi only) as
above: `MODprocess_L1_apply_ucond_calibration.m`, `mod_scan_ucond_electronics_filter.m`,
`mod_scan_calc_chi_ucond.m`, the `ucond` yml block, `MODsetup_probe_fits.m` (the FP07 and
microconductivity fits saved and reloaded by the same code), `chi_ucond` in L2 and the grid
(grid version 6). Tested as in Test results.
