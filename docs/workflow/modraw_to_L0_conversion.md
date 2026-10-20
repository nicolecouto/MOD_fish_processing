#  .modraw → L0: Converting .modraw to .mat

**Status:** working, tested against real deployment files. First step of the `MOD_fish_lib` → `MOD_fish_processing` reorganization (see `PLAN.md` at the repo root).

## What this step does

Reads a raw `.modraw` file and parses it into a MATLAB struct - **no calibrations applied, and no setup.yml needed** (except for a raw file without `$DCAL`, which needs `calibrations_root` - see "SBE calibration" below). The output is raw counts/volts, exactly as recorded, with a time axis, so it can be plotted immediately to sanity-check a deployment.

**The one exception is EFE (epsi) data**, which is converted from ADC counts to volts (`t1_volt`, `s1_volt`, ...) or g (`a1_g`, ...) and given channel names here. EFE boards are standard - the slot order, which slots are accelerometers, and each slot's full range and unipolar/bipolar config never change - so this uses the standard board config (`MODsetup_default_efe.m`) and needs no metadata. That's what lets EFE spectra be checked against ADC bit noise straight from L0 (`MODvis_spectra_L0.m`, see [Visualization](../visualization/index.md)). A metadata struct can optionally override names/config (e.g. a microconductivity probe in slot 4 named `c1`), but is never required. The conversion used is saved alongside as `epsi_conversion`, including plain-text instructions for recovering the exact counts (see "EFE channels: volts/g at L0" below).

Explicitly **not** done at this step:
- No Seabird CTD calibration coefficients applied (P/T/C stay as raw counts). The calibration itself is read and kept (`ctd_cal`, see "SBE calibration" below); L1 applies it.
- No shear probe Sv calibration applied (shear channels stay in volts)
- No FPO7 calibration (thermistor channels stay in volts)
- No filtering, despiking, or QC

Those all happen in the L1 step (not yet built — see PLAN.md).

## Functions

### `MODprocess_single_modraw_to_L0.m`

```matlab
L0_data = MODprocess_single_modraw_to_L0(modraw_file)
L0_data = MODprocess_single_modraw_to_L0(modraw_file, metadata)   % optional: EFE names/config from setup.yml
```

Parses one `.modraw` file. Reads the whole file into memory, finds each `$TAG...*checksum\r\n` block by type (`$EFE` for epsi, `$SB49`/`$SB41` for CTD, `$VNMAR`/`$VNYPR` for vnav, `$GPGGA`/`$INGGA` for GPS, `$ALT`, `$ISAP`, `$ACTU`, `$SEGM`, `$SPEC`, `$AVGS`, `$RATE`, `$APF0`/`$APF1`/`$APF2`, `$ECOP` for fluorometer, `$TTV1`), and decodes each block type's binary/hex payload into arrays.

Returns `L0_data` with whichever of these fields are present in the file (missing types come back as `[]`):

| Field | Contents |
|---|---|
| `epsi` | `time_s`, `dnum`, then `t1_volt`, `t2_volt`, `s1_volt`, `s2_volt` [V] and `a1_g`, `a2_g`, `a3_g` [g] (standard EFE names, or setup.yml's if metadata was passed) |
| `epsi_conversion` | counts <-> volts/g record for `epsi` - see below. `[]` if the file has no EFE data |
| `ctd` | `P_raw`, `T_raw`, `C_raw`, `PT_raw` (SBE49 'eng' format) or `P`, `T`, `S`, `C` (SBE41 'PTS' format), `time_s`, `dnum` |
| `vnav` | `compass`, `acceleration`, `gyro` (or `yaw`/`pitch`/`roll` depending on packet type; the others are NaN), `time_s`, `dnum` - angles for `$VNMAR` are added at L1, see [Which way the fish points](../concepts/vehicle_attitude.md) |
| `gps` | `latitude`, `longitude`, `dnum` |
| `alt`, `isap` | altimeter distance (`dst`), `time_s`, `dnum` |
| `seg`, `spec`, `avgspec` | onboard-computed segment/spectra data (if enabled in firmware) |
| `dissrate`, `apf` | onboard-computed epsilon/chi (APEX float profile summaries) |
| `fluor` | Tridente `bb`, `chla`, `fDOM` |
| `ttv` | travel-time flow meter data |
| `ctd_cal` | SBE calibration from the file's `$DCAL` (`mod_L0_ctd_calibration.m`: `SN`, three calibration dates, the coefficients, `source`, `text`), `[]` if the file has none |
| `ctd_header_sn` | the header's `CTD.SerialNum` (`''` if none) - only used to find a `.CAL` file for a file without `$DCAL` |
| `ctd_cal_error` | why the file's `$DCAL` couldn't be read (`''` if it could, or there was none) |

CTD format is auto-detected per file: the function checks the length of the first `$SB49`/`$SB41` block against the known SBE49 (24-byte 'eng') and SBE41 (28-byte 'PTS') formats and picks whichever matches, so both CTD types parse correctly without needing a Meta_Data/calibration file to tell it which one is connected.

### `MODprocess_all_modraw_to_L0.m`

```matlab
L0_files = MODprocess_all_modraw_to_L0(raw_dir, L0_dir, raw_file_suffix)
L0_files = MODprocess_all_modraw_to_L0(raw_dir, L0_dir, raw_file_suffix, metadata)   % optional: EFE names/config; calibrations_root/CTD.SN for a file without $DCAL
```

Orchestrator: loops over every raw file in `raw_dir` and calls `MODprocess_single_modraw_to_L0` on each, saving one `.mat` per raw file into `L0_dir`. `L0_dir` is optional — defaults to a sibling `L0/` folder next to `raw_dir` (created if it doesn't exist).

`raw_file_suffix` is optional too — if you don't pass it, it's auto-detected from `raw_dir` by `MODsetup_detect_raw_suffix.m` (see below). Pass it explicitly to skip detection or to force a specific type.

All required inputs are plain paths - no metadata object, no `mod_class`, nothing else required. `metadata` is optional: it's passed through for EFE names/config, and gives `paths.calibrations_root` and `CTD.SN` for a raw file without `$DCAL` (without it, such a file fails); files already converted aren't redone just because it changed (L1 re-applies setup.yml anyway). Each saved `.mat` file contains only the data-type fields from `MODprocess_single_modraw_to_L0` plus a small `raw_file_info` field (`bytes`, `filename`) used to detect whether the raw file has changed since it was last converted. Returns `L0_files`, a cell array of full paths to every `.mat` file in `L0_dir` after the call.

Skips re-converting a file if its `.mat` already exists and the raw file hasn't grown since (checked by byte size; an L0 file made before `ctd_cal` existed is redone once) - except the most recent file, which is always reconverted in case it's still being written to (useful for real-time/at-sea processing). With `'newest_min_redo_s', s` (the realtime worker passes it) the newest file is reconverted only when it has grown, at most once per `s` seconds; `'continue_on_error', true` returns failing files in a second output (`problems`) instead of stopping - same options as the L0 → L1 and L1 → L2 drivers (see [L0 → L1](L0_to_L1_conversion.md)).

### EFE channels: volts/g at L0

Four small functions share the work, so the numbers live in exactly one place:

| Function | Does |
|---|---|
| `setup/MODsetup_default_efe.m` | The standard EFE board: slot order, type, full range, ADC config, plus `Fs_epsi` (320 Hz), 24 bits, gain 1, and the accelerometer's 0.9 V zero-g offset and 0.4 V/g sensitivity |
| `processing/mod_efe_conversion.m` | Builds the per-channel record: name, config, and the exact linear map `value = counts * scale + offset`. Starts from the standard board and takes whatever metadata supplies; anything metadata leaves out falls back to that **slot's** default |
| `processing/mod_efe_counts_to_volts_g.m` | `channel1..N` counts → `<name>_volt` / `<name>_g`, returns the record |
| `processing/mod_efe_volts_g_to_counts.m` | Exact inverse - recovers the integer counts |

Standard EFE board:

| Slot | Name | Type | Full range | ADC config |
|---|---|---|---|---|
| 1-2 | `t1`, `t2` | fpo7 | 2.5 V | Unipolar: `V = counts * FR/2^24` |
| 3-4 | `s1`, `s2` | shear | 2.5 V | Bipolar: `V = counts * FR/2^23 - FR` |
| 5-7 | `a1`, `a2`, `a3` | acc | **1.8 V** | Unipolar, then `g = (V - 0.9)/0.4` |

`L0_data.epsi_conversion` holds:

- `README` - plain text: how to read the record and recover counts, with every channel's formula written out with its numbers, e.g. `s1 (slot 3, Bipolar, full_range 2.5 V): counts = (s1_volt + 2.5) * 2^23/2.5`. Type `disp(L0_data.epsi_conversion.README)`.
- `channel.(name)` - per channel: `slot`, `field`, `unit`, `type`, `full_range`, `ADCconf`, `scale` [unit/count], `offset` [unit], `how_to_recover_counts`, and where the name and config came from (`name_source`, `config_source`).
- `channels` (names in slot order), `source`, `Fs_epsi` (and its source), `bit_counts`, `gain`, `acc_offset_V`, `acc_factor_V_per_g`.

`scale` is also one ADC LSB in the channel's own units, which is what the bit-noise lines in `MODvis_spectra_L0.m` / `MODvis_spectra.m` use.

To get the counts back: `epsi_counts = mod_efe_volts_g_to_counts(L0_data.epsi, L0_data.epsi_conversion)`. Counts are integers, so this is exact (verified against the raw counts on real files - see History).

A repurposed slot (microconductivity or fluorometer in a shear slot) keeps its default name (`s1`/`s2`) at L0 unless metadata names it; L1 renames it from setup.yml's `instrument_manifest` either way - see [L0 → L1](L0_to_L1_conversion.md).

### `MODsetup_detect_raw_suffix.m`

```matlab
raw_file_suffix = MODsetup_detect_raw_suffix(raw_dir)
```

Guesses the raw file suffix for a folder instead of hardcoding `.modraw`, so a future acquisition format change (e.g. `.raw`) doesn't require a code edit. Lists every file in `raw_dir`, drops known non-raw extensions (`.mat`, `.json`, `.csv`, `.txt`, `.yml`, `.yaml`, `.log`, `.md`, `.m`, `.asv`, `.mlx`) and hidden/system files (`.DS_Store`, dotfiles), then picks whichever extension is most common among what's left.

This is extension-frequency based, not a binary-vs-text content sniff. That's deliberate: `.mat` files are binary too (it's MATLAB's own format), so checking "is this file binary" wouldn't actually distinguish raw data from L0 output sitting in the wrong folder — excluding known non-raw extensions and taking the dominant remainder is simpler and more reliable.

Errors instead of guessing wrong if `raw_dir` has no candidate files (e.g. you pointed it at an `L0/` folder full of `.mat` files), or if two extensions are equally common. In either case, pass `raw_file_suffix` explicitly to `MODprocess_all_modraw_to_L0`.

## How to run it

```matlab
addpath('/path/to/MOD_fish_processing/processing');
addpath('/path/to/MOD_fish_processing/processing/L0');  % mod_L0_ctd_calibration
addpath('/path/to/MOD_fish_processing/setup');    % for MODsetup_detect_raw_suffix
addpath('/path/to/MOD_fish_processing/util');     % for MODutil_short_path

data_root  = '/path/to/your/deployment';   % must contain a raw/ subfolder
modraw_dir = fullfile(data_root, 'raw');

L0_files = MODprocess_all_modraw_to_L0(modraw_dir);  % L0/ created automatically next to raw/
% pass metadata (MODsetup_read_yaml) as the 4th input if some raw files have no $DCAL

% Visualize
app = MODvis_timeseries(fileparts(L0_files{1}));  % from MOD_fish_processing/visualization
```

To process a single file directly (e.g. for debugging one file without the folder machinery):

```matlab
L0_data = MODprocess_single_modraw_to_L0('/path/to/EPSI25_04_09_151049.modraw');
figure; plot(L0_data.epsi.dnum, L0_data.epsi.s1_volt);   % shear channel, volts
figure; plot(L0_data.ctd.dnum, L0_data.ctd.T_raw);         % raw CTD temperature counts
disp(L0_data.epsi_conversion.README)                       % how to get the EFE counts back

% Quick-look EFE spectra vs ADC bit noise, no setup.yml needed
app = MODvis_spectra_L0(fileparts(L0_files{1}));           % newest file in the L0 folder
```

## SBE calibration: `$DCAL`, else the `.CAL` file

The SBE49 counts are converted at L1 with the calibration L0 keeps in each file's `ctd_cal`:

1. **The file's own `$DCAL`** - what the SBE itself reports (`ctd_cal.source = '.modraw $DCAL'`). Current firmware writes it in every file with a `$SOM3` header.
2. **No `$DCAL`, but SBE49 counts:** `calibrations_root/SBE/<SN>.CAL` (`source = 'calibrations folder: <path>'`), filled in by `MODprocess_all_modraw_to_L0.m`. SN: the one already recorded for this survey (it came from the fish), else the header's `CTD.SerialNum`, else the yml's `instrument_manifest.ctd.sn`. Needs `metadata` (for `calibrations_root`); a missing `.CAL` file stops that file with an error naming it. A `.CAL` file has no `TOFFSET`/`CSLOPE`/`POFFSET`, so those come from the survey's `$DCAL`. A `$DCAL` that can't be read (`ctd_cal_error` says why) counts as none.
3. Neither (no CTD data): `ctd_cal = []`.

The calibration block in the `.modraw` header ("as in Fish calibration file") is **never read**: it's a copy of the computer's `.CAL` file and is wrong whenever that file wasn't updated. See [the `$DCAL` tag](modraw_tag_format.md#dcal-sbe-calibration-coefficients).

**One calibration per survey.** The first one seen is recorded in `ctd_calibration.mat` in the `meta/` folder next to `L0/` (`<survey>/meta`), with `cal` and `file` (the raw file it came from). Every later file's is compared with it on serial number and the three calibration dates (coefficients aren't compared - a new calibration always has a new date). If one differs - e.g. the first file had no `$DCAL` and used an out-of-date `.CAL`, and the next file's `$DCAL` is newer - L0 stops for that survey with `MODprocess_all_modraw_to_L0:ctdCalibrationChanged` (even with `'continue_on_error'`). The message gives both calibrations and the fix:

1. Update `calibrations_root/SBE/<SN>.CAL` to match the fish (Start New Deployment's **Check CTD calibration** can write it - see [Start New Deployment](start_new_deployment.md)).
2. Reprocess that survey from raw: `MODprocess_reset_survey(survey_folder)` shows what it will delete (the survey's `L0/`, `processed/` - every run in it - and `meta/ctd_calibration.mat`; `raw/` and the ymls stay), asks, and deletes them. It refuses while the worker is running.
3. Restart the worker (Start Realtime Processing), or run `MODprocess_deployment(survey_folder)`.

**The realtime worker stops altogether** (ALL STOP, every survey): it writes `stop` to `control.json`, `status.json` says "stopped: CTD calibration changed" (the monitor's Worker line shows it) with the message in `warnings`, and the cruise log says what to do. It runs again only when it's restarted, and stops again straight away if the survey wasn't reset.

A header serial number that differs from the `$DCAL` one (the setup named the wrong CTD) is a warning; the `$DCAL` one is used.

## Known limitations / things to check visually

- **Flatlined channels are possible and not necessarily a bug.** In one bench-test file, `epsi.channel1` and `channel2` (now `t1_volt`/`t2_volt`) came back pegged at the ADC's max value (2^24 counts, 2.5 V) for the entire record - channels 3-7 varied normally. This turned out to be consistent with those probes being disconnected/unpowered during that particular bench test, not a parsing error. Always eyeball a new file in MODvis_timeseries before trusting it.
- This function has no error handling for corrupted/truncated `.modraw` files beyond per-block length checks (prints `"<TYPE> block N has incorrect length"` and skips that block). A file with many of these messages is worth a closer look.
- `L0_data.ctd.S_raw` is left as `NaN` for SBE49 'eng'-format CTDs — salinity isn't transmitted raw by that CTD mode, it's derived from P/T/C, which only happens at L1.

## History

Adapted from `mod_som_read_epsi_files_v4.m` in the old `MOD_fish_lib` monolith, with all calibration/metadata-dependent steps stripped out. Originally developed and tested on `nicole` branch of `MOD_fish_lib` (as `MODprocess_modraw_to_L0.m` / `MODprocess_allnew_modraw_to_L0.m`, later renamed). Ported to `MOD_fish_processing` on branch `l0_modraw_conversion`:
- Removed dependency on the legacy JLAB `make.m`/`use.m` toolbox functions (replaced with explicit struct field assignment) so the scripts are self-contained.
- Fixed CTD format detection: the SBE49→SBE41 fallback described in a code comment was never actually implemented, so any SBE41-format CTD (e.g. APEX float profiles) silently produced all-NaN `ctd` output. Now detected from the first block's length.
- Removed the `mod_class`/`Meta_Data` object branch from `MODprocess_all_modraw_to_L0.m` entirely. The original accepted either a folder path or a `mod_class` object, and even in the folder-path case it built a throwaway `Meta_Data` struct and saved it into every `.mat` file. Both functions now take only plain paths (a file for the single-file parser, a folder for the orchestrator) and save only raw data — this is a deliberate move away from the class-based `epsi_class_yaml` approach (see PLAN.md Section 2).
- Replaced the hardcoded `raw_file_suffix = '.modraw'` with auto-detection (`MODsetup_detect_raw_suffix.m`), still overridable via an optional argument, so a future acquisition file type doesn't require a code change.
- Tested against the full real dataset in `mod_fish_lib/data_for_reorg/` (epsi_mako_w_fluor, epsi_minnow, epsi_on_wirewalker, fctd_w_ucond_fluor — several hundred files total) — see `SESSION_LOG.md` for results.

**2026-09-29 (branch `main-fork`) - EFE counts → volts/g moved to L0, with the standard EFE board as the default.** Prompted by wanting to look at EFE spectra against ADC bit noise as quickly as possible (the MODSOM_liveplot use case) without first writing a setup.yml. Nicole's decision: EFE boards are standard, so L0 is the one exception to "don't move forward without metadata". `MODprocess_single_modraw_to_L0.m` now converts `channel1..7` to `t1_volt`...`a3_g` using `MODsetup_default_efe.m` (optionally overridden by a metadata argument), and saves the conversion as `epsi_conversion` with a plain-text `README` and a per-channel `how_to_recover_counts`. The counts ↔ volts/g math moved out of `MODprocess_single_L0_to_L1.m`'s `convert_efe_channels` into `mod_efe_conversion.m` / `mod_efe_counts_to_volts_g.m` / `mod_efe_volts_g_to_counts.m`, and the accelerometer offset/factor constants moved from here and from L1 into `MODsetup_default_efe.m`. Noted along the way: the accelerometers are 1.8 V full range, not 2.5 V. Tested in a scratchpad sandbox copy of `epsi_mako/blt2021_0715` (3 files) and `epsi_deepsolo/26_0720_ljc` (1 file): counts recovered from the new L0 equal the old L0's raw counts exactly on all 7 channels, and the new L1 epsi fields equal the existing L1 exactly for volts and to within 4e-16 g for accelerometers.

**2026-10-18 (branch `main-fork`) - SBE calibration from `$DCAL`.** Nicole: the calibration printed in the `.modraw` header comes from the computer's `.CAL` file and is wrong when that file isn't updated, so never read it; use `$DCAL`, which comes from the SBE, and the `.CAL` file only for a file without one; a calibration change within a survey pauses processing until the `.CAL` is fixed and the survey reprocessed from raw. New `mod_L0_ctd_calibration.m` (both layouts, by name, replacing `MODsetup_read_yaml.m`'s line-order `read_sbe_cal`); L0 gains `ctd_cal`/`ctd_header_sn`; `MODprocess_all_modraw_to_L0.m` adds the `.CAL` fallback, `meta/ctd_calibration.mat` and the pause. Found while testing (share copies, read-only): the Mako2 SBE 0237 reports a Dec 2025 calibration, but `SBE/0237.CAL` is from Dec 2023; the 2026-10-09 pier test's header says CTD 0537 but its `$DCAL` says 0674. Tested in a scratchpad sandbox: the 2026-10-17 ocean test's L1 T and C equal the old `.CAL`-based L1 (to 2e-10), P to 0.0006 dbar (last-digit rounding of PTCA0); the pier test's second file (no `$DCAL`) uses 0674.CAL with a serial-number warning; an older date in that `.CAL` pauses the survey with no L1; an L0 file without `ctd_cal` is redone.

**2026-10-20 (branch `main-fork`) - Raw files read one char per byte.** Nicole saw a 336-530 m gap in the RR2609 mako2_test2 grid. `EPSI26_10_19_175544.modraw` is a normal 5.0 MB file with 1254 good `$EFE40` blocks, but its L0 had 4880 epsi samples (out of about 100,000) with times from 11:50 to 16:35. `fopen` without an encoding lets Matlab guess one from the file's bytes. For this file it guessed ISO-2022-CN, which dropped 5448 bytes, and 1193 EFE blocks failed the length check. The file's time-index entry (from epsi) then missed the downcast, so the grid left out its 5 minutes. `MODprocess_single_modraw_to_L0.m` (both reads) and `MODutil_route_raw_by_survey.m` now open raw files as ISO-8859-1, one char per byte. Tested on copies in a scratchpad sandbox: 175544 parses all 100,320 samples, 17:55:44-18:00:52, and 175036 is unchanged (100,480 samples).
