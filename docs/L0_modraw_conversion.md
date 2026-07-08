# L0: Converting .modraw to .mat

**Status:** working, tested against real deployment files. First step of the `MOD_fish_lib` → `MOD_fish_processing` reorganization (see `MOD_fish_lib` `claude` branch `PLAN.md`).

## What this step does

Reads a raw `.modraw` file and parses it into a MATLAB struct — **no calibrations applied, no metadata beyond what's physically encoded in the file itself.** The output is raw counts/volts, exactly as recorded, with a time axis, so it can be plotted immediately to sanity-check a deployment.

Explicitly **not** done at this step:
- No Seabird CTD calibration coefficients applied (P/T/C stay as raw counts)
- No shear probe Sv calibration applied (shear channels stay as raw counts)
- No FPO7 calibration
- No filtering, despiking, or QC

Those all happen in the L1 step (not yet built — see PLAN.md).

## Functions

### `MODprocess_single_modraw_to_L0.m`

```matlab
L0_data = MODprocess_single_modraw_to_L0(modraw_file)
```

Parses one `.modraw` file. Reads the whole file into memory, finds each `$TAG...*checksum\r\n` block by type (`$EFE` for epsi, `$SB49`/`$SB41` for CTD, `$VNMAR`/`$VNYPR` for vnav, `$GPGGA`/`$INGGA` for GPS, `$ALT`, `$ISAP`, `$ACTU`, `$SEGM`, `$SPEC`, `$AVGS`, `$RATE`, `$APF0`/`$APF1`/`$APF2`, `$ECOP` for fluorometer, `$TTV1`), and decodes each block type's binary/hex payload into arrays.

Returns `L0_data` with whichever of these fields are present in the file (missing types come back as `[]`):

| Field | Contents |
|---|---|
| `epsi` | `channel1`...`channel7` (shear/FPO7/accel raw counts), `time_s`, `dnum` |
| `ctd` | `P_raw`, `T_raw`, `C_raw`, `PT_raw` (SBE49 'eng' format) or `P`, `T`, `S`, `C` (SBE41 'PTS' format), `time_s`, `dnum` |
| `vnav` | `compass`, `acceleration`, `gyro` (or `yaw`/`pitch`/`roll` depending on packet type), `time_s`, `dnum` |
| `gps` | `latitude`, `longitude`, `dnum` |
| `alt`, `isap` | altimeter distance (`dst`), `time_s`, `dnum` |
| `seg`, `spec`, `avgspec` | onboard-computed segment/spectra data (if enabled in firmware) |
| `dissrate`, `apf` | onboard-computed epsilon/chi (APEX float profile summaries) |
| `fluor` | Tridente `bb`, `chla`, `fDOM` |
| `ttv` | travel-time flow meter data |

CTD format is auto-detected per file: the function checks the length of the first `$SB49`/`$SB41` block against the known SBE49 (24-byte 'eng') and SBE41 (28-byte 'PTS') formats and picks whichever matches, so both CTD types parse correctly without needing a Meta_Data/calibration file to tell it which one is connected.

### `MODprocess_new_modraw_to_L0.m`

```matlab
obj = MODprocess_new_modraw_to_L0(modraw_path)
```

Orchestrator: loops over every `.modraw` file in a folder and calls `MODprocess_single_modraw_to_L0` on each, saving one `.mat` per raw file into a sibling `L0/` folder (created if it doesn't exist — assumes `raw/` and `L0/` are siblings under a common data root).

`modraw_path` can be:
- a folder path (string) — this is the typical way to call it for now
- a `mod_class` object with `Meta_Data.paths.data.raw` set — for later integration with the full metadata/YAML pipeline

Skips re-converting a file if its `.mat` already exists and the raw file hasn't grown since (checked by byte size) — except the most recent file, which is always reconverted in case it's still being written to (useful for real-time/at-sea processing).

## How to run it

```matlab
addpath('/path/to/MOD_fish_processing/processing/matlab');

data_root  = '/path/to/your/deployment';   % must contain a raw/ subfolder
modraw_dir = fullfile(data_root, 'raw');
L0_dir     = fullfile(data_root, 'L0');    % created automatically if missing

MODprocess_new_modraw_to_L0(modraw_dir);

% Visualize
app = L0ExplorerApp(L0_dir);  % from MOD_fish_processing/visualization/matlab
```

To process a single file directly (e.g. for debugging one file without the folder machinery):

```matlab
L0_data = MODprocess_single_modraw_to_L0('/path/to/EPSI25_04_09_151049.modraw');
figure; plot(L0_data.epsi.time_s, L0_data.epsi.channel3); % raw shear/FPO7 counts
figure; plot(L0_data.ctd.dnum, L0_data.ctd.T_raw);         % raw CTD temperature counts
```

## Known limitations / things to check visually

- **Flatlined channels are possible and not necessarily a bug.** In one bench-test file, `epsi.channel1` and `channel2` came back pegged at the ADC's max value (2^24) for the entire record — channels 3-7 varied normally. This turned out to be consistent with those probes being disconnected/unpowered during that particular bench test, not a parsing error. Always eyeball a new file in L0ExplorerApp before trusting it.
- This function has no error handling for corrupted/truncated `.modraw` files beyond per-block length checks (prints `"<TYPE> block N has incorrect length"` and skips that block). A file with many of these messages is worth a closer look.
- `L0_data.ctd.S_raw` is left as `NaN` for SBE49 'eng'-format CTDs — salinity isn't transmitted raw by that CTD mode, it's derived from P/T/C, which only happens at L1.

## History

Adapted from `mod_som_read_epsi_files_v4.m` in the old `MOD_fish_lib` monolith, with all calibration/metadata-dependent steps stripped out. Originally developed and tested on `nicole` branch of `MOD_fish_lib` (as `MODprocess_modraw_to_L0.m` / `MODprocess_allnew_modraw_to_L0.m`, later renamed). Ported to `MOD_fish_processing` on branch `l0_modraw_conversion`:
- Removed dependency on the legacy JLAB `make.m`/`use.m` toolbox functions (replaced with explicit struct field assignment) so the scripts are self-contained.
- Fixed CTD format detection: the SBE49→SBE41 fallback described in a code comment was never actually implemented, so any SBE41-format CTD (e.g. APEX float profiles) silently produced all-NaN `ctd` output. Now detected from the first block's length.
