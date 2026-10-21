# Microconductivity chi

Microconductivity probe has an ADC filter that is hardwired into the SBE7 analog board. The EFE digitizes the output of the SBE7. The microconductivity probe takes over the s2 channel of the EFE board.

In the setup yml the probe is an AFE channel of type `microcond`, usually named `c1` in slot 4
(`acquisition/presets/fctd*.yml`: `ch4_type: microcond`). Like every EFE channel it's stored as
volts (`epsi.c1_volt`) at L0 and L1, and `mod_scan_get_spectra.m` makes its raw spectrum
(`spectra.c1_volt_f`) for each L2 scan. What's computed from it is decided by the channel type,
not by the fish (`fish_flag`): any vehicle with a `microcond` channel, a fitted gain and real CTD
T/S gets `microconductivity.<channel>_obs`, as any vehicle with an `fpo7` channel gets FP07 chi
([FP07 calibration and chi](L2_calc_chi.md)).

This is a port of MHA's v3 microconductivity chi (MOD_fish_lib
`FastCTD_MATLAB/Dehysteresis_and_microconductivity/microconductivity/`), **chi only**: the
correction for the unresolved part of the spectrum (`chi_tot`, `eps_chi`) waits for the
stratification step - see [Not ported yet](#not-ported-yet).

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

NaN for a railed scan. L2 gets `microconductivity.<ch>_obs` (the chi), `microconductivity.<ch>_obs_kmax`
and the spectrum it integrated, `spectra.<ch>_dCdz_k` (and `spectra.k` when there's no FP07 chi);
the grid gets `microconductivity.<ch>_obs` and `microconductivity.<ch>_obs_kmax`. kmax is far below
the Batchelor wavenumber, so **this chi is an underestimate**, by a factor that grows with epsilon.

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
| `chi_tot`, `eps_chi` (Alford and Pinkel 2000b, Rrho = 5) | Not yet |

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

## Not ported yet

- **`chi_tot` and `eps_chi`** (`add_chi_microMHA_v3.m`, Alford and Pinkel 2000b): from the
  measured chi, N^2 and Rrho, assuming gamma = 0.2, it estimates epsilon and corrects chi for the
  unresolved part. It needs the stratification around each scan, the same open question as the
  diffusivities; legacy hard-codes Rrho = 5 and smooths N^2 over 500 CTD samples.

## Known limitations

- Whether `antialias_sinc_power` = 2 (SBE7's filter) and the EFE ADC filter should both be
  divided out: the note at the top says the SBE7 filter is on the analog board and the EFE
  digitizes its output, so both are applied. At 50 Hz they're 0.71 and 0.72.
- An L2 file made before the gain was fit (or before a refit) isn't redone when the fit changes:
  the same as for FP07 chi.
- The gain is one number per deployment (a mean over windows); a probe that drifts within a
  deployment isn't followed.

## History

**2026-10-21 - Names** (branch `main-fork`). `chi_ucond.(ch)`/`chi_ucond_kmax.(ch)` are now
`microconductivity.<ch>_obs`/`microconductivity.<ch>_obs_kmax`, in L2 and the grid (the
turbulence structs - see [Processing data](processing_data.md) History). Test results above use
the old names.

**2026-10-20 - Microconductivity chi** (branch `main-fork`). Ported MHA's v3 chi (chi only) as
above: `MODprocess_L1_apply_ucond_calibration.m`, `mod_scan_ucond_electronics_filter.m`,
`mod_scan_calc_chi_ucond.m`, the `ucond` yml block, `MODsetup_probe_fits.m` (the FP07 and
microconductivity fits saved and reloaded by the same code), `chi_ucond` in L2 and the grid
(grid version 6). Tested as in Test results.
