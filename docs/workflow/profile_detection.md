# Profile detection and extraction: the final science-quality L2 path

**Status:** built and tested end-to-end on branch `chi_processing` against a sandbox copy of `epsi_mako/blt2021_0715` - see "Known limitations" and "History" below. Follows [L1 → L2: downcast-gated spectra](L1_to_L2_conversion.md), which documents the per-file "realtime" path this one runs alongside, not in place of.

## What this step does, and why it's different from the realtime path

`MODprocess_single_L1_to_L2.m` (realtime mode) computes spectra per L1 file independently, so it can process each file as it lands - useful for live QC, but it drops the trailing partial FFT window at every file boundary rather than padding it from the next file, an accepted, documented cost of that mode.

This step - `modProcess_detect_profiles.m` → `modProcess_extract_profile.m` → `mod_L2_tile_scans.m` (shared with the realtime path) → `MODprocess_single_L1_to_L2_profile.m` → `MODprocess_all_L1_to_L2_profiles.m` - is the final, science-quality counterpart: it cuts the deployment into discrete profiles (as the legacy `MOD_fish_lib` always did), and for each profile stitches its raw epsi/ctd record across however many L1 files it spans **before** windowing. A profile spanning two L1 files gets no coverage gap at the seam, as long as the underlying sampling really was continuous there - which it normally is, since an L1 file boundary is a storage artifact, not a break in the instrument's sample clock.

Both modes are kept side by side deliberately (not one replacing the other): realtime mode stays cheap and streaming-friendly for a future per-file spectra QC viewer (a `MODvis_spectra`-style tool, not built yet); this mode is what a final gridded product (L3, not built yet) should be built from. The two compute their spectra fully independently - no result is shared or reused between them, a deliberate simplicity-over-storage-optimization choice (see PLAN.md Section 6.3's design discussion) that can be revisited later if data volume becomes a real problem.

## Profile detection

### `modProcess_detect_profiles.m` (`processing/L1/`)

```matlab
profiles = modProcess_detect_profiles(PressureTimeseries, metadata)
```

Full profile-picker, re-derived (not literally ported) from `MOD_fish_lib/EPSILOMETER/epsilib/epsiProcess_get_profiles_from_PressureTimeseries.m`, built directly on top of `mod_L1_detect_profiling_direction.m`'s already-computed `dPdt_smoothed` rather than re-filtering pressure from scratch:

1. Per-direction speed-limit hysteresis: a downcast run starts where `dPdt_smoothed > speedLim_down_start_m_s` and continues through any dip as long as it stays above the lower `speedLim_down_end_m_s`; upcasts are the mirror image on `-dPdt_smoothed`.
2. A `minLength_m` filter drops any run that doesn't span enough pressure.
3. Up to 10 passes fuse consecutive same-direction runs that aren't separated by a real opposite-direction run - handles a brief hiccup in the middle of an otherwise-continuous cast.
4. **Gap-boundary safety** (new relative to legacy, which has no gaps to worry about): a real timestamp gap in the pressure record (same `ctd_gap_factor` threshold `mod_L1_detect_profiling_direction.m` uses) is a hard boundary neither a run nor a merge can ever cross - two runs on opposite sides of a real gap are never treated as one profile, even when nothing else separates them.

Output is a `profiles(i)` struct array (`.profile_number`, `.direction`, `.index_start`/`.index_end`, `.dnum_start`/`.dnum_end`, `.P_start`/`.P_end`), sequentially numbered across both directions. **Every detected cast is returned, in both directions - this function does not filter by `metadata.PROFILES.profile_dir`.** CTD/pressure data is collected on every cast a vehicle makes regardless of direction, so every cast gets a `Profile####.mat` with its CTD record; `profile_dir` instead gates, downstream, which direction(s) are trusted enough to compute epsi spectra for (see "Direction: CTD vs. epsi" below).

### `MODprocess_L1_make_time_index.m` (`processing/`)

```matlab
TimeIndex = MODprocess_L1_make_time_index(L1_dir)
```

Loads only `epsi.dnum` (min/max) per L1 file - not full file contents - sorted by start time. Built inside `MODprocess_all_L0_to_L1.m`, saved as `meta/time_index.mat`, so `modProcess_extract_profile.m` can find which L1 file(s) overlap a profile's time range without loading every file's full contents.

## Profile extraction: stitching across a file boundary, with real gap detection

### `modProcess_extract_profile.m` (`processing/L1/`)

```matlab
profile_data = modProcess_extract_profile(profile, TimeIndex, metadata)
```

Given one detected profile, finds every L1 file overlapping its `[dnum_start, dnum_end]` (via `TimeIndex`), loads and concatenates their `epsi`/`ctd` fields in time order, and crops to the exact range. This is the piece that actually removes the realtime path's file-boundary coverage gap - the raw record is one continuous array before any windowing happens, not tiled per file.

**Exact gap-detection mechanism:** across the *whole* stitched epsi record (not just at file seams - a real discontinuity can occur mid-file too, e.g. the known regex block-drop artifact, PLAN.md Section 9), the sample-to-sample interval `dt` is compared against the deployment's *nominal* epsi sample interval, `1/Fs_epsi` - epsi is uniformly clocked hardware, so unlike the sparse/irregular ctd record there is one fixed expected spacing, not a local median. A gap is flagged where `dt > epsi_gap_factor * (1/Fs_epsi)`: with the suggested default `epsi_gap_factor = 3`, any gap wider than 3 sample periods (missing more than ~2 samples' worth of time) counts as real, not just ordinary clock jitter. Every sample gets a running `segment_id`, incrementing at each flagged gap.

**What a gap actually does:** `mod_L2_tile_scans.m` is what acts on `segment_id` - it skips only the candidate FFT window(s) whose samples would span two different `segment_id` values, the direct generalization of realtime mode's "drop the trailing partial window" behavior to any real gap location inside a profile, not just its outer file boundaries. **A profile is never split into two output files, and never dropped outright, over an internal gap** - one profile in, one `Profile####.mat` out, with only the handful of windows actually touching the gap missing from the result. `MODprocess_single_L1_to_L2_profile.m` records how much of the profile's raw coverage this affected as a non-blocking QC diagnostic, `profile_gap_fraction` (0 when there was no internal gap - the common case for an ordinary file-rotation boundary).

`ctd` does not get its own `segment_id`: it's only ever used for scan-center interpolation (pressure/fall-speed/temperature/salinity), never windowed into an FFT directly, so a gap there just means `interp1` linearly bridges it - much lower stakes than letting an FFT window itself span a gap.

epsi and ctd are extracted independently, so a contributing L1 file that has one but not the other (e.g. no epsi record at all - see "CTD-only deployments" below) still contributes whichever it has - CTD coverage is never dropped just because epsi wasn't recorded, and vice versa.

## Direction: CTD vs. epsi, and CTD-only deployments

Every deployment collects CTD/pressure on every cast, but epsi (shear/fpo7) is usually trustworthy in only one direction - vehicle wake turbulence typically contaminates the untrusted direction. `modProcess_detect_profiles.m` reflects this by returning every detected cast, both directions; `MODprocess_single_L1_to_L2_profile.m` is the one place that decides, per profile, whether to actually compute epsi spectra:

```matlab
compute_epsi = metadata.manifest.has_epsi && ...
    (metadata.PROFILES.profile_dir is 'both', or matches profile.direction)
```

- `metadata.ctd` (the raw, stitched, cropped profile-length CTD record - dnum/P/T/S/dzdt/... at native CTD sample rate, **not** interpolated onto scan centers) is attached to **every** `Profile####.mat`, unconditionally - direction, `profile_dir`, and `has_epsi` never affect it.
- `metadata.PROFILES.profile_dir` (default `'down'`) governs only whether spectra get computed for a given profile's direction.
- `metadata.manifest.has_epsi` (`MODsetup_read_yaml.m`, true only when `setup.yml`'s `instrument_manifest.afe` block is present) covers a genuinely CTD-only vehicle (no AFE/epsi board at all - e.g. a bare FastCTD or Wirewalker cast): `MODprocess_all_L1_to_L2.m` (the realtime path, which exists purely to compute spectra) skips entirely and cleanly rather than writing near-empty `.mat` files or crashing; `MODprocess_all_L1_to_L2_profiles.m` keeps running, since CTD-only profile output is still meaningful.
- The raw `epsi` struct itself (with `segment_id`) is never saved into `L2data`/`Profile####.mat` - only derived per-scan products (`spectra.*`, `chi_obs.*`, etc.) when `compute_epsi` is true. `ctd` is the one raw record that IS saved, deliberately - see above.

A caller can always expect the same field set from `Profile####.mat`, whether or not that particular profile has spectra - when `compute_epsi` is false, `mod_L2_tile_scans.m`'s per-scan fields are still present, just empty (`dnum = []`, etc.), and `profile_gap_fraction` is `0`.

## Shared windowing: `mod_L2_tile_scans.m` (`processing/L2/`)

```matlab
L2data = mod_L2_tile_scans(epsi, ctd, metadata, PressureTimeseries)
```

The `N_epsi`/`scan_step`/pwelch tiling loop originally inline in `MODprocess_single_L1_to_L2.m`, factored out so both paths share one implementation (not one result - see above). `PressureTimeseries` (direction gating) is optional: the realtime path passes it, the profile-cut path omits it since a detected profile is already direction-pure by construction. Absent `epsi.segment_id` (the realtime path never sets it), the gap-boundary check is a no-op - realtime behavior is unchanged.

## `setup.yml` additions

```yaml
profile_detection:              # -> metadata.PROFILES.* (profile-picking only)
  ctd_gap_factor: 5              # renamed from gap_factor - pressure/ctd record gap threshold
  speedLim_down_start_m_s: 0.3
  speedLim_down_end_m_s: 0.1
  speedLim_up_start_m_s: 0.1
  speedLim_up_end_m_s: 0.05
  minLength_m: 10
  profile_dir: down               # 'down' | 'up' | 'both'

spectral:                        # -> metadata.PROCESS.* (existing block, extended)
  fft_length: 1024
  fft_segments_per_scan: 3
  scan_overlap: 0.5
  epsi_gap_factor: 3              # scan-window gap threshold - governs which FFT windows are
                                   # valid, not which samples are part of a profile, so it lives
                                   # here (PROCESS), not under profile_detection: (PROFILES)
```

All of these are validated via `MODsetup_validate_metadata.m` at point of use (prompted for, and offered to be saved into `setup.yml`, if missing) rather than silently defaulted - see `MODsetup_metadata_field_registry.m` for the authoritative list. The defaults above are that registry's `suggested_default` values, shown here for a reader who wants the numbers without opening the registry source:

- `ctd_gap_factor: 5` - same field `mod_L1_detect_profiling_direction.m` already used under the name `gap_factor` before this branch; renamed to pair with `epsi_gap_factor` below.
- `speedLim_down_start_m_s: 0.3` / `speedLim_down_end_m_s: 0.1` / `speedLim_up_start_m_s: 0.1` / `speedLim_up_end_m_s: 0.05` - the legacy `fctd`/`epsi` vehicle defaults. Legacy also hardcoded different defaults for `wirewalker` (0.5/0.5/0.5/0.05); this repo does not guess from vehicle type (PLAN.md Section 2's "no hardcoded values without a documented reason") - a wirewalker deployment sets its own values in `setup.yml`.
- `minLength_m: 10` - same as legacy.
- `profile_dir: down` - only downcasts get epsi spectra computed by default, consistent with this repo's descent-only trustworthiness convention elsewhere (e.g. DeepSolo's shear/high-res temperature). Every cast, either direction, still gets a `Profile####.mat` with its CTD record - see "Direction: CTD vs. epsi" above.
- `epsi_gap_factor: 3` - a starting point only, **not yet verified against real data** - see "Known limitations."

## `Profile####.mat` output

`MODprocess_all_L1_to_L2_profiles.m` saves one `Profile%04d.mat` per detected profile - **every** detected profile, both directions, regardless of `profile_dir`/`has_epsi` - into `metadata.paths.profiles` (a new field, `data_root/profiles`, deliberately a *sibling* of `metadata.paths.L2`, not inside it - the realtime path's per-file output and this path's per-cast output are never in the same directory). Every file has the same field shape as the realtime path's per-file output (empty when `compute_epsi` was false for that profile) plus provenance (`profile_number`, `direction`, `filenames`, `dnum_start`/`dnum_end`, `profile_gap_fraction`) and `ctd` (the profile's own raw CTD record, always populated - see above). Skip-if-up-to-date is decided per profile from `time_index.mat` alone (cheap - no epsi/ctd data loaded just to check), mirroring `MODprocess_all_L1_to_L2.m`'s per-file rule: a profile is reprocessed if any L1 file it touches is newer than its existing `Profile####.mat`, or if it touches the single most-recently-modified L1 file in the deployment.

## How to run it

```matlab
addpath('/path/to/MOD_fish_processing/processing');
addpath('/path/to/MOD_fish_processing/processing/L1');
addpath('/path/to/MOD_fish_processing/processing/L2');
addpath('/path/to/MOD_fish_processing/setup');
addpath('/path/to/MOD_fish_processing/util');

metadata = MODsetup_read_yaml('/path/to/deployment/meta/setup.yml');

% L0->L1 must already have run - builds meta/pressure_time_series.mat and
% meta/time_index.mat as a side effect
L1_files = MODprocess_all_L0_to_L1(metadata.paths.L0, metadata, metadata.paths.L1);

L2_files = MODprocess_all_L1_to_L2_profiles(metadata);
```

## Known limitations

- **File-lookup is not robust to a single corrupted timestamp sample - currently breaks extraction for most profiles in the one real deployment tested.** `MODprocess_L1_make_time_index.m` assigns each L1 file's `dnum_start`/`dnum_end` from a plain `min`/`max` of its `epsi.dnum` (or `ctd.dnum`), with no outlier rejection. In `blt2021_0715`, one real file (`EPSI_B_PC2_21_07_17_203041.mat`) has a single garbage leading sample (`epsi.dnum(1) ≈ datenum(1970,1,1)`, ~19,000 days before every other sample in the file) - this single bad sample corrupts that file's `dnum_start`, which sorts it to position 1 in `time_index.mat`, which then breaks `modProcess_extract_profile.m`'s `find(profile.dnum_end <= TimeIndex.dnum_end, 1, 'first')` lookup for every profile whose real `dnum_end` is earlier than that file's (otherwise legitimate) `dnum_end` - **55 of 57 detected profiles in this deployment currently return empty `epsi`/`ctd`** as a result (confirmed 2026-08-28; only the two profiles nearest the true end of the deployment escape it). This is a pre-existing gap in the file-lookup design (not introduced by today's direction/CTD-attachment work, but discovered while testing it, and it directly undermines "every profile gets its CTD record" until fixed) - not yet fixed; needs a design decision on how to make a file's assigned time range robust to a single bad clock sample (e.g. trimming leading/trailing outlier gaps via a threshold relative to the nominal sample interval, the same style of fix already used elsewhere in this codebase for real mid-record gaps) before this path can be trusted on real data.
- **`epsi_gap_factor`'s suggested default (3) is still not confirmed against real gap/jitter cases.** The one real cross-file profile tested (`blt2021_0715` profile #31, spanning 8 L1 files) happened to have no genuine timestamp gap anywhere in it - real max `dt` was 0.004003 s against a 0.003125 s nominal (320 Hz), comfortably under the 3x threshold, but that only confirms the default doesn't produce *false positives* on ordinary hardware jitter for this one deployment. The gap-splitting mechanism itself was verified with a synthetic 5 s gap (not real data) - still worth watching the first time this runs against a deployment that actually has a real dropout.
- **No diagnostic plot has been run yet** against a real detected profile set - the "Diagnostic" pattern `L1_to_L2_conversion.md` uses (`plot(PressureTimeseries.dnum, PressureTimeseries.P)` with profile boundaries overlaid) is recommended before trusting `modProcess_detect_profiles.m`'s output on a new deployment, but hasn't been exercised here yet.
- **No epsilon or SOM transfer-function correction** - same as the realtime path; see [L1 → L2: downcast-gated spectra](L1_to_L2_conversion.md)'s own "Known limitations."
- **`epsi`/`ctd` only** - `modProcess_extract_profile.m` does not stitch `alt`/`isap`/`vnav`/`gps`/`ttv` across a file boundary; add a field the same way once a real consumer needs it.
- **No storage/dedup optimization** - realtime and profile-cut spectra are fully independent computations, even for the interior of a profile that a per-file pass already covered. Acceptable for now (see PLAN.md Section 6.3); revisit if data volume becomes a real problem.

## History

Built on branch `chi_processing`, following [L1 → L2: downcast-gated spectra](L1_to_L2_conversion.md) and [FP07 calibration and chi](L2_calc_chi.md). Prompted by a design discussion about what happens when a profile spans two raw files - investigation found `MOD_fish_lib`'s legacy `epsiProcess_crop_timeseries.m`/`epsiProcess_merge_mat_files.m` solves this by concatenating raw arrays across the boundary with no gap detection at all, while Rockland's ODAS library sidesteps the problem by assuming one profile always lives in one raw file. This step's real gap detection (rather than either extreme) was a deliberate choice, confirmed with Nicole.

Tested end-to-end (2026-08-28) against a sandbox copy of `epsi_mako/blt2021_0715` (151 L1 files, ~932 MB): 31 real profiles detected; profile #31 spanned 8 L1 files (970,950 stitched epsi samples, no real gap found at any of the 7 internal file boundaries), and the scan window nearest that seam matched a hand-built `mod_scan_get_spectra.m` call on the same stitched sample range exactly - confirming no edge effect at an ordinary file boundary. The `mod_L2_tile_scans.m` refactor of the realtime path was regression-tested `isequaln`-identical against the pre-refactor code on a real L1 file. A synthetic 5 s gap separately verified the gap-splitting mechanism itself (this real deployment had no genuine gap to test it against). See PLAN.md Section 12 session log (2026-08-28) for full numbers.

**2026-08-28, same day, design review:** a follow-up review caught that this initial version filtered `modProcess_detect_profiles.m`'s output by `profile_dir` (only downcasts were ever returned/saved), had no gate at all for a CTD-only deployment (`MODsetup_read_yaml.m` would have crashed reading `instrument_manifest.afe` unconditionally), and saved `Profile####.mat` into the same directory as the realtime path's per-file output. Fixed: `modProcess_detect_profiles.m` now returns every cast in both directions; `MODprocess_single_L1_to_L2_profile.m` decides per-profile whether to compute epsi spectra (`metadata.manifest.has_epsi` && direction matches `profile_dir`) and always attaches the profile's own CTD record regardless; `metadata.manifest.has_epsi` (new) makes `instrument_manifest.afe` genuinely optional in `MODsetup_read_yaml.m`, and gates `MODprocess_all_L1_to_L2.m`'s realtime path (skips cleanly, rather than crashing or writing empty `.mat` files, for a CTD-only vehicle); `metadata.paths.profiles` (new, `data_root/profiles`) is now `MODprocess_all_L1_to_L2_profiles.m`'s default output directory, a sibling of `metadata.paths.L2`. `MODprocess_L1_make_time_index.m` and `modProcess_extract_profile.m` were also extended to fall back to `ctd.dnum` when a file has no epsi record, so CTD-only deployments' files are indexed and extracted at all. Verified end-to-end against the same `blt2021_0715` sandbox: both directions detected (31 down / 26 up), CTD populated for both a down and an up profile, spectra computed only for the down profile under the default `profile_dir: down` (and for both under `profile_dir: both`), no raw `epsi` struct in either output, `MODsetup_read_yaml.m` no longer crashes on a synthetic CTD-only `setup.yml`, and `MODprocess_all_L1_to_L2.m` skips cleanly (no directory created, `{}` returned) for a CTD-only `metadata.manifest.has_epsi=false`. This same testing pass is what surfaced the file-lookup bug in "Known limitations" above.
