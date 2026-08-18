# L1 → L2: downcast-gated spectra

**Status:** working, tested against real DeepSolo deployment files. Built on branch `l1_to_l2_conversion`, following [L0 → L1: converting raw counts to physical units](L0_to_L1_conversion.md).

## What this step does, and why it's different from the old approach

The old `mod_fish_lib` L1→L2 step first splits a deployment into discrete `Profile####.mat` casts, then computes spectra on a pressure grid *within* each profile (`get_scan_spectra.m`). This step deliberately does something different for `epsi_deepsolo`: it computes per-scan spectra across an entire L1 file's continuous timeseries, keeping the same one-`.mat`-per-L1-file layout L0 and L1 already use. Scans tile each L1 file's `epsi` timeseries independently - this is "realtime" mode, processing each file as it lands with no cross-file I/O. A "post-processing" mode (either a continuous whole-deployment time grid, or working profile-by-profile off real profile indices once `modProcess_detect_profiles.m`, PLAN.md Section 6.3, exists) is future work - not attempted here. The small coverage gap at each file boundary (a partial window that doesn't reach a full scan length gets dropped, not padded from the next file) is an accepted, documented cost of realtime mode.

**Why DeepSolo needs this at all:** DeepSolo gives us shear and high-resolution temperature only on the way down. It also gives us two CTD products, neither directly usable yet for time-aligning spectra:
- Pressure-binned up/down CTD profiles (P/T/S) - not time-aligned with the epsi/shear timebase, alignment not solved yet.
- A sparse, **time**-binned pressure-only series ("fallrise" data, `ctd/DeepSoloFallrise.mat`) - dense-ish on the way up (~60 s), sparser on the way down (~120 s), occasional multi-hour gaps. This is the only thing available to gate scans by direction, so it's what this step uses.

**Spectra are computed only for scans classified as descending** (`dPdt > 0`, `P` increasing), with a buffer around the edges of each descending run so the sparse sampling doesn't clip real descent time.

This first cut computes **raw, uncorrected power spectra only** - no epsilon, no coherence. Epsilon is a natural next step (shear `Sv` calibration is already resolved in `metadata.AFE`), but is deliberately deferred to keep this step reviewable on its own. Chi was blocked for the same reason `MODprocess_L2_get_scan_spectra.m` below still returns uncorrected spectra: FPO7 `dTdV`/`volts_to_C` needs real, time-aligned CTD temperature to fit in-situ, which DeepSolo's fallrise file doesn't have. **Update (branch `chi_processing`):** for deployments that *do* have a real onboard CTD (e.g. `epsi_mako`), chi is now implemented - see [FP07 calibration and chi](L2_calc_chi.md). `MODprocess_L2_get_scan_spectra.m` itself is unchanged (still raw/uncorrected); the FP07 time-constant deconvolution happens downstream, in `MODprocess_L2_calc_chi.m`. DeepSolo specifically remains blocked, since it still has no CTD T.

## Profiling-direction detection is an L1 concern, not L2

`ctd.P`/`dPdt` are computed in L1 already (`process_ctd_fields`, see [L0 → L1](L0_to_L1_conversion.md)). Classifying up/down from that pressure record is naturally an L1-level derived product too - not something L2 computes for itself. This mirrors the cable-twist-counting pattern (`mod_L1_add_twist.m` computes a per-file field; `MODprocess_L1_accumulate_twist_timeseries.m` chains all files into a deployment-level `meta/TwistTimeseries.mat`): two functions, called once per deployment from the end of `MODprocess_all_L0_to_L1.m`, build `meta/PressureTimeseries.mat`.

This also directly answers "can I process a single L1 file to L2 on its own?" - **yes**, because all the direction information a single L1 file needs already lives in a small, cheap `meta/PressureTimeseries.mat`, rather than something L2 has to compute from the whole deployment on the fly.

### `MODprocess_L1_make_pressure_timeseries.m`

```matlab
PressureTimeseries = MODprocess_L1_make_pressure_timeseries(L1_dir)
```

Concatenates `ctd.dnum`/`ctd.P` out of every L1 `.mat` file in `L1_dir`, sorted by file start time (loads only the `ctd` field per file, not full files). Pure - no metadata needed, no file writing. This is the deployment-length pressure record PLAN.md Section 6.3 originally sketched as `modProcess_make_pressure_timeseries.m`.

### `mod_L1_detect_profiling_direction.m`

```matlab
PressureTimeseries = mod_L1_detect_profiling_direction(PressureTimeseries, metadata)
```

Adds `dPdt_smoothed` and a logical `is_down` (descending) to every sample. Four steps, in order:

1. **Gap detection first, before any smoothing.** A gap between consecutive samples wider than `metadata.PROFILES.gap_factor × (whole-record median sample interval)` (default `gap_factor = 5`) splits the record into independent segments - real DeepSolo data has at least one ~9982 s (2.77 h) gap against a ~60-120 s median, and diffing or filtering straight across it would produce a "dPdt" that isn't a real velocity. The two samples flanking any such gap are always excluded (`is_down = false`), since there's no reliable local rate at the gap edge.

2. **Cheby2 lowpass + `filtfilt`**, per gap-free segment - same shape as the old `MOD_fish_lib` profile-picker (`epsiProcess_get_profiles_from_PressureTimeseries.m`), but **re-derived for how sparse this data actually is**. That function's cutoff was a fixed 4 s, which assumed ~Hz-rate pressure sampling (a fast CTD stream) where 4 s covers many samples - on DeepSolo's 60-120 s/sample data, a fixed 4 s window would be sub-sample and not a real filter at all.

   Here the cutoff period is `lowpass_factor × (this segment's median sample interval)`, default `lowpass_factor = 3`. The normalized cutoff passed to `cheby2`, `Fc`, works out to exactly `2 / lowpass_factor` - independent of the actual sample spacing. `Fc` must be strictly less than 1 (Nyquist) for `cheby2` to accept it, so `lowpass_factor` must be `> 2`; `lowpass_factor = 2` gives `Fc = 1` exactly (degenerate, rejected with an error). `3` (`Fc ≈ 0.67`) is the default: the smallest safely-valid choice, i.e. as little smoothing as the math allows while still being a real filter - "should not smooth much or at all," given how sparse the source data is. Segments too short for `filtfilt`'s edge-padding requirement (fewer than ~13 samples) fall back to the raw, unsmoothed pressure for that stretch.

3. `dPdt_smoothed` is computed at segment midpoints from the lowpass-filtered pressure, then linearly interpolated back onto the original per-sample grid (same shape as the old profile-picker's approach) - one value per input sample.

4. **Buffer, on the raw pressure-sample grid, not the epsi scan grid.** Contiguous runs where `dPdt_smoothed > 0` get padded by `metadata.PROFILES.buffer_bins` pressure *samples* (default `1`) on each end before finalizing `is_down`, within each gap-free segment only (never dilating across a gap into an unrelated stretch of the deployment). "A few bins around" is read as bins of the coarse pressure series (60-120 s each) - padding by epsi-scan-sized bins (~3 s) would be far too small relative to the actual timing uncertainty near a turnaround.

`setup.yml`'s `profile_detection:` block controls all three parameters (see below); namespaced under `metadata.PROFILES` to match the old `Meta_Data.PROFILES.*` convention, so a future full profile-picker port can extend the same section.

### Diagnostic: does the classification look right?

Real output, `epsi_deepsolo/26_0520_ljc` (sandbox test run, 2026-07-26): pressure sawtooths between the surface and ~250-420 dbar, with `is_down` landing cleanly on each steep descending leg and `dPdt_smoothed` crossing zero right at each turnaround - `P`, `dPdt_smoothed`, and `is_down` all visually consistent across the whole 757-sample deployment record (30.1% classified `is_down`). Worth re-plotting (`plot(PressureTimeseries.dnum, PressureTimeseries.P)`, overlay `is_down` as a scatter) any time `lowpass_factor`/`gap_factor`/`buffer_bins` change or a new deployment's fallrise data looks different in character.

## L2 spectra

### `mod_scan_get_spectra.m` (`processing/scans/`)

```matlab
scan = mod_scan_get_spectra(scan, metadata)
```

Pure function - `scan.epsi` is `data.epsi` already sliced to one scan's `N_epsi = (dof-1)*nfft` samples. For each channel in `metadata.PROCESS.channels` whose `metadata.AFE.(ch).type` is `shear`/`fpo7`/`acc`, computes `[Pxx, f] = pwelch(detrend(x), nfft, [], nfft, Fs_epsi, 'psd')` - the same call shape as the old `mod_efe_scan_acceleration.m`, minus the `h_freq` transfer-function correction (SOM filters, PLAN.md Section 6.2, aren't implemented yet - these spectra are **uncorrected**, documented as such rather than silently glossed over). Returns the same `scan` struct with `spectra.f` (shared frequency vector) and `spectra.(channel)_f` added (e.g. `spectra.t1_volt_f`, `spectra.a2_g_f` - matching `MOD_fish_lib`'s `Pt_volt_f`/`Pa_g_f` naming, see [FP07 calibration and chi](L2_calc_chi.md)).

### `MODprocess_single_L1_to_L2.m`

```matlab
L2data = MODprocess_single_L1_to_L2(data, metadata, PressureTimeseries)
```

Pure transformation function - `PressureTimeseries` (from `meta/PressureTimeseries.mat`) is a **required** argument, not self-loaded, matching `MODprocess_single_L0_to_L1.m`'s `external_ctd`-as-argument precedent. To process one L1 file by hand:

```matlab
PressureTimeseries = load(fullfile(metadata.paths.meta, 'PressureTimeseries.mat'));
data = load('L1/modsom_20.mat');
L2data = MODprocess_single_L1_to_L2(data, metadata, PressureTimeseries);
```

1. Tiles `data.epsi` **within this file only**, `N_epsi`-sample windows with 50% overlap (`scan_step = N_epsi/2`).
2. For each scan's center time, nearest-matches against `PressureTimeseries.dnum`/`.is_down`. Deliberately **no extrapolation** here: a scan center time outside `[min(PressureTimeseries.dnum), max(PressureTimeseries.dnum)]` has no real pressure information at all - e.g. epsi logging that started hours before DeepSolo's pressure record begins (real case: `epsi_deepsolo/26_0520_ljc`'s first 14 L1 files, ~18.5 h of epsi data recorded before the first fallrise pressure sample) - and gets excluded rather than nearest-matched to a potentially far-distant, meaningless sample. This was caught during testing: an earlier version used `interp1(...,'nearest','extrap')`, which would have nearest-matched all of those early scans to whatever the first `PressureTimeseries` sample happened to be classified as, regardless of how many hours away it was.
3. For kept (descending) scans, slices `data.epsi` and calls `mod_scan_get_spectra`.
4. Assembles output arrays over the scan dimension: `dnum`, `pressure`/`w` (interpolated from this file's own `data.ctd.P`/`.dzdt` at scan center), `spectra.f` (shared, `1 × nfreq`), per-channel `spectra.(channel)_f` matrices (`nbscan × nfreq`), plus provenance (`nfft`, `dof`, `Fs_epsi`, `N_epsi`, `scan_step`). **Update (branch `chi_processing`):** also `temperature`/`salinity` (from `data.ctd.T`/`.S` at scan center, only when this file's CTD has real T/S), `chi_obs.(channel)`/`chi_obs_kc.(channel)` for every fpo7 channel with a resolved `volts_to_C` calibration, and the deconvolved spectrum/cutoff those are computed from (`spectra.k`, `spectra.(channel)_Tg_k`, `spectra.(channel)_fc_index`) - see [FP07 calibration and chi](L2_calc_chi.md).

Returns an all-empty `L2data` (consistent field shapes, `nbscan = 0`) if this file has no epsi data, is too short for even one scan, or no scan lands on a descending part of the record - not an error, since that's expected for files recorded entirely during an upcast or before pressure logging started.

### `MODprocess_all_L1_to_L2.m`

```matlab
L2_files = MODprocess_all_L1_to_L2(L1_dir, metadata, L2_dir, reprocess_all)
```

Orchestrator, mirrors `MODprocess_all_L0_to_L1.m`'s shape exactly: skips a file if its L2 `.mat` already exists and is newer than the source L1 file, except the most recently modified L1 file (always redone), with a `reprocess_all` override. Loads `meta/PressureTimeseries.mat` **once** at the start, then passes it into every `MODprocess_single_L1_to_L2` call - so the per-file work stays a pure function while the file-I/O cost is paid once per batch run. Errors clearly if `meta/PressureTimeseries.mat` doesn't exist yet (it's built by `MODprocess_all_L0_to_L1.m` - that must run first).

## `setup.yml` additions

Two new optional blocks, both defaulted if absent (no existing `setup.yml` needs an edit to keep working):

```yaml
afe:
  sample_rate: 320       # Hz, nominal EFE board rate -> metadata.PROCESS.Fs_epsi

profile_detection:        # -> metadata.PROFILES.*
  lowpass_factor: 3        # cutoff period = lowpass_factor * median(dt); must be > 2
  gap_factor: 5             # gaps > gap_factor * median(dt) split the record, not interpolated across
  buffer_bins: 1             # pad each descending run by this many raw pressure samples on each side

spectral:                  # -> metadata.PROCESS.nfft / .dof
  nfft: 1024
  dof: 3
```

`nfft`/`dof` default to `1024`/`3` (same defaults the old `MOD_fish_lib` `Acquisition/setup.yml` templates used) if the `spectral:` block is absent. `Fs_epsi` defaults to `320` Hz (the standard EFE board rate) if `afe.sample_rate` is absent.

## How to run it

```matlab
addpath('/path/to/MOD_fish_processing/processing');
addpath('/path/to/MOD_fish_processing/setup');
addpath('/path/to/MOD_fish_processing/util');

metadata = MODsetup_read_yaml('/path/to/deployment/meta/setup.yml');

% L0->L1 must already have run - builds meta/PressureTimeseries.mat as a side effect
L1_files = MODprocess_all_L0_to_L1(metadata.paths.L0, metadata, metadata.paths.L1);

L2_files = MODprocess_all_L1_to_L2(metadata.paths.L1, metadata, metadata.paths.L2);
```

## Known limitations

- **File-boundary coverage gaps** - a partial window at the end of an L1 file that doesn't reach a full `N_epsi` samples is dropped, not padded from the next file. Accepted cost of "realtime" per-file mode - see "What this step does" above.
- **No epsilon or SOM transfer-function correction yet** - `mod_scan_get_spectra.m`'s spectra are still raw and uncorrected. See PLAN.md Section 6.2/6.4 for what's still open. `chi_obs`/`chi_mle` are now implemented downstream for deployments with a real onboard CTD - see [FP07 calibration and chi](L2_calc_chi.md); DeepSolo itself still can't get chi (no CTD T).
- **Direction classification quality depends entirely on how sparse/gappy the pressure record is for a given deployment** - `lowpass_factor`/`gap_factor`/`buffer_bins` are tunable per deployment in `setup.yml`'s `profile_detection:` block precisely because a different DeepSolo deployment (or a different vehicle's fallrise-style sparse pressure product) may need different values. Always worth a diagnostic plot (see "Diagnostic" above) after a new deployment's first run.

## History

Built on branch `l1_to_l2_conversion` (2026-07-26), following [L0 → L1](L0_to_L1_conversion.md). Prerequisite fixes to L0→L1 code (DeepSolo external CTD reader, `calibrate_ctd` → `process_ctd_fields` rename/guard, `PressureTimeseries.mat`) are logged in that doc's History section, not duplicated here. Tested end-to-end against a sandbox copy of `epsi_deepsolo/26_0520_ljc` (45 L1 files, `reprocess_all=true`) - see PLAN.md Session Log (2026-07-26) for full numbers, including the file-boundary NaN-extrapolation bug caught and fixed during this test run (see `MODprocess_single_L1_to_L2.m`'s notes above).
