# MOD Fish Processing Refactor — Project Plan

**Deadline: August 1st (burn-in for MURI and DECADES)**
**Primary repo for new work: MOD_fish_processing**

*Previously tracked on the `claude` branch of `MOD_fish_lib` during early planning; moved here 2026-07-08 now that MOD_fish_processing is where active work happens. See `MOD_fish_lib` `claude` branch history for the pre-move log.*

---

## 1. Vision and Repo Structure

We are splitting the monolithic `MOD_fish_lib` into three purpose-built repos:

| Repo | Purpose | Status |
|------|---------|--------|
| `MOD_fish_processing` | Processing algorithms and pipeline scripts | Active — has MODvis_timeseries, SpectraExplorerApp |
| `MOD_fish_acquisition` | Data acquisition software | Active — has fctd_epsi_acq |
| `MOD_fish_calibrations` | SBE `.cal` files, probe Sv values (git-tagged by date) | Active — tags: `sbe/2023-03`, `sbe/2023-12`, `sbe/2024-09`, `sbe/2025-03`, `shear/2025-12` |
| `MOD_fish_lib` | Legacy monolith — gradually deprecated | Staying alive during transition |

The goal is that `MOD_fish_processing` becomes a clean, instrument-agnostic pipeline that anyone can run without digging through decades of accumulated code. Standalone functions with excellent documentation replace the class-based approach.

---

## 2. Guiding Principles

### Move away from epsi_class_yaml
The class was a good idea but was never executed cleanly. The new approach is **standalone functions** that can be called independently, tested individually, and understood without loading a class object. The class methods in `epsi_class_yaml.m` can eventually become thin wrappers around the new functions.

### Pure transformation functions — no file I/O inside processing steps
Every L1 (and L2, L3) processing function takes a data struct and returns a modified data struct. No function loads or saves files except the top-level orchestrators (`modProcess_L0_to_L1.m`, `modProcess_L1_to_L2.m`, etc.). The orchestrator loads once, passes through the chain, saves once:

```matlab
% modProcess_L0_to_L1.m (pseudocode)
for each L0 file:
    data = load(L0_file)
    data = modProcess_L1_apply_ctd_calibration(data, metadata)  % needs metadata.CTD.cal
    data = modProcess_L1_apply_shear_calibration(data, metadata) % needs metadata.AFE, metadata.manifest
    data = modProcess_L1_despike(data, metadata)                 % needs metadata.PROCESS.Fs_epsi
    data = modProcess_L1_apply_filters(data, metadata)           % needs metadata.AFE.FS
    data = modProcess_L1_add_twist(data)                         % no metadata needed
    save(L1_file, data)
end
```

This makes every processing function trivially testable: load a file in a test script, pass the struct, inspect the output. No temp files, no side effects.

### metadata (lowercase, no paths saved)
`Meta_Data` → `metadata`. Two key rules:

1. **Paths are never saved in `metadata.mat`.** Paths are machine-specific; everything else in metadata (calibration coefficients, processing parameters, instrument manifest) is stable across machines. Paths are always derived fresh from a single `data_root` field in the YAML. This eliminates the "wrong paths on a new computer" problem without adding any new files.

2. **Every session starts with one line:**
   ```matlab
   metadata = modSetup_read_yaml('path/to/meta/setup.yml');
   ```
   This reads the YAML, derives all paths for the current machine, and returns the full struct in memory. `metadata.mat` (saved in `meta/`) is a portable deployment record — calibrations, manifest, processing parameters — that a collaborator could load on any machine.

3. `metadata` is assembled once and passed through the pipeline. It should never need to be modified mid-pipeline.

4. **Only pass `metadata` when the function actually uses it.** Many functions (like `modProcess_L1_add_twist`) need only the data struct. Adding `metadata` as a reflex argument when it isn't used makes function signatures misleading. When `metadata` is used, the header must name the specific fields — not just "metadata struct".

### Metadata provenance and archiving
`metadata.mat` is not always built in one shot — it can be assembled in stages (yaml read now, calibration values merged in later once probe serial numbers resolve to a cal file — see `calibrate_ctd`/shear-cal in Section 6.2), and it can be regenerated from an edited yaml, whether that's a routine re-run or a deliberate parameter experiment. Two rules keep all of that traceable without hand-maintained logs:

1. **`metadata.header` is an append-only event log.** Every function that creates or modifies `metadata` and resaves it appends one entry to `metadata.header.history`, a struct array with fields `.timestamp`, `.computer`, `.event`, `.filepath` — indexed directly as `metadata.header.history(1).timestamp`, no cell unwrapping. `MODsetup_read_yaml` appends a `created_from_yaml` event (yaml path in `.filepath`, plus a hash of the yaml's contents in `metadata.header.yaml_hash`, so two `metadata.mat` files can be checked for having come from identical or different yaml). `.filepath` is the only per-event detail today because `created_from_yaml` is the only caller — a later event type with different information to record (e.g. calibration merge, which is probe SN + cal file rather than a single path) gets the struct fields revisited then, not generalized now. Reading any single `metadata.mat` tells you its full lineage — no separate log file needed.
2. **Only touch disk when something actually changed.** A deployment script typically calls `MODsetup_read_yaml` at the start of every run, often many times an hour as new data comes in during a cruise — the same yaml, over and over. `MODsetup_save_metadata.m` compares the metadata it's about to save (yaml hash + resolved cal values) against what's already in `meta/metadata.mat` before deciding what to do:
   - **Unchanged** — same yaml, same cal values in effect. No-op: nothing written, nothing archived, no new history entry.
   - **Yaml differs** from what's on disk (routine edit or a deliberate parameter experiment) — the yaml is the source of truth and may now say something genuinely different. Archives the existing `meta/metadata.mat` to `meta/archive/metadata_<timestamp>.mat`, then writes the new one.
   - **Yaml unchanged, but a derived value is new or changed** — e.g. a probe serial number just resolved to a cal file for the first time, or a calibration tag moved. This isn't a configuration change, just a value getting filled in or corrected. Updates `meta/metadata.mat` **in place**, no archiving, and appends the corresponding event to `metadata.header.history`.

All three outcomes go through one function, `MODsetup_save_metadata.m` (Section 6.1), so the decision is made in one place instead of reimplemented by every caller. `meta/archive/` only grows from the yaml-differs case — fine to ignore for now; add a prune/keep-last-N policy later only if it becomes a real nuisance.

*Why keep a persisted `metadata.mat` at all, rather than always rebuilding in memory from yaml + calibration files?* Cal lookup could in principle be a pure function of deployment date vs. calibration tag dates, computed fresh every time with nothing saved. But a persisted file is the only durable record of exactly which cal values a given L1/L2 file was actually processed with — useful if a calibration tag is ever corrected after the fact, and necessary for processing without network access to `MOD_fish_calibrations`. Worth revisiting once metadata starts getting saved inside the L0/L1/L2 files themselves (see Section 6.1) — at that point a master `metadata.mat` may matter less, since each data file would carry its own record.

### Standard function header
Every function in `MOD_fish_processing` must start with this header block. Two examples: one that uses `metadata`, one that doesn't.

```matlab
% Function that uses metadata — list the specific fields it needs:
function data = modProcess_L1_apply_shear_calibration(data, metadata)
% modProcess_L1_apply_shear_calibration        Part of MOD_fish_processing
%
% data = modProcess_L1_apply_shear_calibration(data, metadata)
%
% DESCRIPTION
%   Converts shear probe voltage to velocity gradient [1/s] using the probe
%   sensitivity Sv and fall speed. Operates on all shear channels in the manifest.
%
% INPUTS
%   data      - L0 data struct with fields: epsi.s1_volt, epsi.s2_volt, ctd.dPdt
%   metadata  - metadata struct (from modSetup_read_yaml.m)
%               Uses: metadata.manifest.shear_channels
%                     metadata.AFE.s1.cal, metadata.AFE.s2.cal  (Sv [V/Pa])
%
% OUTPUTS
%   data      - same struct with epsi.s1_shear, epsi.s2_shear added [1/s]
%
% CALLED BY
%   modProcess_L1_run.m
%
% CALLS
%   (none)
%
% NOTES
%   Fall speed is taken from ctd.dPdt. Negative values (upcasts) are handled
%   by using abs(w) — Sv calibration applies regardless of direction.
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography
```

```matlab
% Function that does not need metadata — don't pass it:
function data = modProcess_L1_add_twist(data)
% modProcess_L1_add_twist                      Part of MOD_fish_processing
%
% data = modProcess_L1_add_twist(data)
%
% DESCRIPTION
%   Computes cumulative twist count from VecNav gyro and compass data and
%   adds a twist struct to the data. Count starts from zero for this file;
%   cross-file accumulation is handled by modProcess_L1_accumulate_twist_timeseries.
%
% INPUTS
%   data      - L0 data struct with fields: vnav.gyro, vnav.compass,
%               vnav.acceleration, vnav.dnum, vnav.time_s, ctd.P, ctd.dnum
%               If data.vnav is empty, returns data unchanged with a warning.
%
% OUTPUTS
%   data      - same struct with data.twist added:
%                 twist.time_s        [s]
%                 twist.dnum          [datenum]
%                 twist.pressure      [dbar], interpolated from CTD
%                 twist.count_gyro    [full rotations], primary
%                 twist.count_compass [radians], cross-check
%
% CALLED BY
%   modProcess_L1_run.m
%
% CALLS
%   SN_RotateToZAxis.m
%
% NOTES
%   Gyro z-axis integral is the primary method. Negative = untwisting.
%   "Neutral is Negative" -- set fin to neutral to make the count go down.
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography
```

The `CALLED BY` line is especially important — it tells a new user how to find context for why this function exists.

---

## 3. Deployment Folder Structure

A deployment needs exactly two things to start: raw files and a YAML config. Everything else is created by the pipeline.

```
deployment_root/
  raw/                         ← REQUIRED: raw binary files go here before processing
  ctd/                         ← DeepSolo/Wirewalker only: independent CTD file(s) - see
                                  MODprocess_read_external_ctd.m, Section 6.2. Not required
                                  for vehicles whose CTD arrives in the raw stream itself.
  meta/                        ← REQUIRED: must exist with setup.yml before processing
    setup.yml                  ← REQUIRED: deployment config (edit data_root: for each machine)
    metadata.mat               ← created by modSetup_read_yaml — portable, no paths, current state
    archive/                   ← prior metadata.mat versions, archived on every resave (see Section 2)
    TimeIndex.mat              ← created during L0 processing
    PressureTimeseries.mat     ← created during L1/profile processing
    TwistTimeseries.mat        ← created by modProcess_L1_accumulate_twist_timeseries
    SpoolSwapLog.csv           ← operator-edited any time during a cruise
  L0/                          ← created by pipeline
  L1/                          ← created by pipeline
  L2/                          ← created by pipeline
  grid/                        ← created by pipeline
  figures/                     ← created by pipeline
```

`SpoolSwapLog.csv` and `TwistTimeseries.mat` are created/updated during the cruise. All other files in `meta/` are regenerated deterministically from `setup.yml` and the data.

**Long-term goal:** A GUI for creating `setup.yml` with dropdowns (vehicle type, CTD SN pulled from `MOD_fish_calibrations`, per-channel sensor type + SN lookup, optional sensor toggles) and sensible defaults, so operators don't hand-edit YAML at sea.

---

## 4. Data Levels

| Level | Input | Output | Description |
|-------|-------|--------|-------------|
| **L0** | Raw binary files | Per-file `.mat` with raw counts/volts | Parse bytes, no calibrations, read headers |
| **L1** | L0 `.mat` files | Per-file `.mat` with calibrated, filtered, despiked data + `twist` field | CTD→P/T/C/S; shear→dshear/dz; FPO7→dT/dt; filters; twist timeseries for this file |
| **L2** | L1 `.mat` + profile indices | `Profile####.mat` per cast | Per-scan spectra, epsilon, chi, QC flags |
| **L3** | L2 profiles | Gridded sections | Interpolate onto standard pressure grid |

**Done and merged to `main`:** L0 (raw → .mat, no calibrations, no metadata beyond what's in the file). Originally prototyped on the `nicole` branch of `MOD_fish_lib` as `MODprocess_modraw_to_L0.m` / `MODprocess_allnew_modraw_to_L0.m`; see Section 12 for what changed on the port. Documented in `MOD_fish_processing/docs/workflow/L0_modraw_conversion.md`.

**In progress on branch `l0_to_l1_conversion`:** L0 → L1 (counts/hex → physical units: epsi volts/g, CTD P/T/C/S, altimeter hab). First cut ships `MODsetup_read_yaml.m` + `MODprocess_single_L0_to_L1.m` / `MODprocess_all_L0_to_L1.m`, tested end-to-end against `epsi_mako_w_fluor/25_0408_d03_mako1_canyonhead` (96/96 files, physically plausible T/P/S/C). Despike, filters, shear/FPO7 calibration, and the `twist` field are not yet in this step - see Section 6.2 and Section 7. Documented in `MOD_fish_processing/docs/workflow/L0_to_L1_conversion.md`. See Section 12 session log entry 2026-07-09 for what changed.

**Next target:** fix the regex block-splitting artifact in `MODprocess_single_modraw_to_L0.m` (Section 9 — parse by declared hex block length instead of regex terminators)

---

## 5. The Instrument Configuration Problem

### What's broken now
Old code hardcodes 8 channels as `s1, s2, t1, t2, a1, a2, a3, c_count`. In practice any of the `s`/`t` slots may hold a shear probe, FPO7, microconductivity probe, fluorometer, or nothing. The `$EFE` block may or may not be present.

### The fix: instrument_manifest block in setup.yml
**Implemented (branch `l0_to_l1_conversion`, 2026-07-24)** for the AFE-channel and presence-flag part described below; the grouped `shear_channels`/`fpo7_channels`-style lists at the bottom of this section are not built yet (nothing consumes them).

`setup.yml` has a single `instrument_manifest` block that says what's physically on the vehicle at a glance - electrical/sampling specifics (full_range, ADCconf, sample_per_record, ...) live in separate detail sections further down the file, keyed by the same names the manifest declares. An instrument entirely absent from `instrument_manifest` is treated as not on the deployment; nothing errors on a missing key, so old and minimal `setup.yml` files keep working as new instrument types are added to the schema.

AFE channels are keyed by physical ADC slot (`channel_1` = slot 1, ... `channel_7` = slot 7 - the order the SOM firmware samples in, matching L0's positional `channel1`..`channel7` fields), **not** by the logical sensor name - that distinction matters because raw parsing (`MODprocess_single_modraw_to_L0.m`) only ever sees ADC slot numbers, and it's `MODsetup_read_yaml.m`, reading this manifest, that resolves slot → logical name (`t1`, `s1`, `f1`, `c1`, ...) for everything downstream:

```yaml
# in setup.yml
instrument_manifest:
  ctd:
    sn: '0674'
  afe:
    channel_1: {name: t1, type: fpo7,  sn: 274}
    channel_2: {name: t2, type: fpo7,  sn: 311}
    channel_3: {name: s1, type: shear, sn: 261}
    channel_4: {name: s2, type: shear, sn: 421}
    channel_5: {name: a1, type: acc}
    channel_6: {name: a2, type: acc}
    channel_7: {name: a3, type: acc}
  vnav: true
  isap: true
  # alt, gps not on this deployment - keys simply omitted

afe:
  channels:                                  # electrical details, keyed by name
    t1: {full_range: 2.5, ADCconf: Unipolar}
    s1: {full_range: 2.5, ADCconf: Bipolar}
    # ...
```

```matlab
% metadata after MODsetup_read_yaml (what's actually resolved today)
metadata.PROCESS.channels     = {'t1','t2','s1','s2','a1','a2','a3'};  % ADC slot order, from channel_N sorted numerically
metadata.AFE.s1.type          = 'shear';
metadata.AFE.s1.SN            = '261';
metadata.AFE.s1.cal           = 33.49;        % Sv, looked up by SN
metadata.manifest.has_vnav    = true;
metadata.manifest.has_isap    = true;
metadata.manifest.has_alt     = false;        % key absent from setup.yml -> false, not an error
metadata.manifest.has_gps     = false;
metadata.manifest.has_fluor   = false;
```

Slot order is resolved by parsing and numerically sorting the `channel_N` keys - not by yaml field order. YAML libraries preserve declaration order but don't sort it, so `channel_10` would sort before `channel_2` under the old field-order approach the moment a deployment has more than 9 channels; explicit numeric sort avoids that trap.

`metadata.manifest.has_*` are presence-only flags today - nothing in L0→L1 reads them yet (`vnav`/`isap`/etc. just pass through from L0 unchanged). They exist so a later step (shear/FPO7 calibration application, twist counting, or the grouped `shear_channels`/`fpo7_channels` lists below) can start consuming them without every existing `setup.yml` needing a schema migration first.

**Not yet built** - grouped channel-list convenience fields, for when a processing function needs to loop over "all shear channels" rather than check `metadata.AFE.(ch).type` one channel at a time:

```matlab
% Not implemented yet - add when modProcess_L1_apply_shear_calibration.m
% (PLAN.md Section 6.2) actually needs to loop over shear channels
metadata.manifest.shear_channels     = {'s1', 's2'};
metadata.manifest.fpo7_channels      = {'t1', 't2'};
metadata.manifest.microcond_channels = {};
metadata.manifest.fluor_channels     = {};
```

Processing functions loop over manifest fields — no more hardcoded channel names.

---

## 6. Processing Pipeline — Function List

### 6.1 Setup

| Function | Description | Status |
|----------|-------------|--------|
| `MODsetup_read_yaml.m` | Read `setup.yml` → `metadata` struct with paths derived fresh, AFE/CTD/altimeter fields resolved from an explicit `instrument_manifest` block (Section 5), CTD calibration loaded from `MOD_fish_calibrations`. Saves `metadata.mat` (no paths). Deliberately minimal so far - only resolves what L0→L1 uses today; grows as later steps need more (grouped `metadata.manifest.shear_channels`/`fpo7_channels`/etc. from Section 5 not built yet, since nothing consumes them yet - presence flags `metadata.manifest.has_vnav`/`.has_isap`/etc. are). | Done (branch `l0_to_l1_conversion`) |
| `MODsetup_verify_paths.m` | Check required directories exist, create L0/L1/L2/grid/figures if not | Not started |
| `MODsetup_save_metadata.m` | Central save wrapper for `metadata.mat`. Compares the metadata to be saved against what's on disk and picks one of three outcomes: no-op (unchanged — nothing written), `'create'` (yaml differs — archives existing file to `meta/archive/metadata_<timestamp>.mat`, then writes the new one), or `'update'` (yaml unchanged but a derived value like a calibration lookup is new/changed — writes in place). Every non-no-op outcome appends an event to `metadata.header.history`. See Section 2, "Metadata provenance and archiving." | Done (branch `l0_to_l1_conversion`) |

*(Naming note: this table originally used a `modSetup_`/`modProcess_L1_apply_*` lowercase-prefix convention; the actual repo convention established during the L0 port and carried through here is `MODsetup_`/`MODprocess_` - capital MOD. Table updated to match what's actually on disk.)*

### 6.2 L0 → L1

Shipped as `MODprocess_single_L0_to_L1.m` (per-file, pure transformation) / `MODprocess_all_L0_to_L1.m` (batch orchestrator, mirrors `MODprocess_all_modraw_to_L0.m`'s skip-unless-new-or-newest logic one level up) - **not** as separate files per row below. The sub-steps below live as local subfunctions inside `MODprocess_single_L0_to_L1.m` for now, since nothing calls them standalone yet; split any of them into its own file the moment something other than this orchestrator needs to call it (per PLAN.md Section 2's "pure transformation function" principle - the principle is about testability and reuse, which local subfunctions don't get).

| Step | Description | Source in MOD_fish_lib | Status |
|------|-------------|-------------------------|--------|
| `convert_efe_channels` | AFE counts → volts (t*/s*) or g (a*), by manifest channel (`metadata.AFE.(ch).full_range/.ADCconf/.type`) | `mod_som_read_epsi_files_v4.m` counts→volts block | Done |
| `calibrate_ctd` | SBE cal equations → P [dbar], T [°C], C [S/m], S [psu], plus derived `th`/`sgth`/`dPdt`/`z`/`dzdt`. SBE41 "PTS" format and external CTD (DeepSolo/Wirewalker - see below) arrive from L0/caller already in physical units - only derived fields are computed for those. | `get_CalSBE.m`, `mod_som_read_epsi_files_v4.m` SBE block | Done |
| `calibrate_altimeter_hab` | Raw distance → height above bottom, using `metadata.GEOMETRY.*`. Applied to both `alt` (MOD altimeter) and `isap` (ISA500) - verified against real `isap` data and, as of the `blt2021_0715` test run (2026-07-24), real `alt` data too. | `mod_som_read_epsi_files_v4.m` ALTI/ISAP blocks | Done |
| `MODprocess_read_external_ctd.m` | For DeepSolo/Wirewalker (`metadata.vehicle_name`), reads and normalizes a deployment's independent CTD file (dnum/P/T/C/S), sliced per L0 file by `MODprocess_all_L0_to_L1.m` and passed into `MODprocess_single_L0_to_L1` as an optional 3rd argument. | NEW - no prior equivalent in `MOD_fish_lib` | Plumbing done, no real parser implemented for any instrument yet (no sample file available) |
| `modProcess_L1_apply_shear_calibration.m` | `Sv × volts / fall_speed` → shear, loops over `metadata.manifest.shear_channels` | `mod_som_get_shear_probe_calibration_v2.m` | `Sv` lookup itself now done in `MODsetup_read_yaml.m` (`metadata.AFE.(ch).cal`, per-channel, from `calibrations_root/SHEAR_PROBES/<SN>/Calibration_<SN>.txt`). This row - actually applying it to compute shear (needs fall speed, e.g. `ctd.dPdt`) - not started |
| `modProcess_L1_apply_fpo7_calibration.m` | Fit `dTdV` in-situ per deployment against real CTD temperature (not a lookup like shear's `Sv` - a prior version of this plan conflated the two) | `mod_epsi_linear_calibration_FP07.m` | Not started |
| `modProcess_L1_despike.m` | filloutliers movmedian per channel | `mod_epsilometer_calc_turbulence_v2.m` lines ~131–147 | Not started |
| `modProcess_L1_apply_filters.m` | Apply SOM instrument transfer function | `get_filters_SOM.m` | Not started |
| `modProcess_L1_add_twist.m` | Takes data struct, returns same struct with `twist` field added — see Section 7 | `GV_PlotUpAccumulation.m` | Not started (Ana's project) |

### 6.3 Profile detection

| Function | Description | Source |
|----------|-------------|--------|
| `modProcess_make_pressure_timeseries.m` | Concatenate pressure from all L1 files → `meta/PressureTimeseries.mat` | `epsiProcess_make_PressureTimeseries.m` |
| `modProcess_detect_profiles.m` | Find downcasts/upcasts from pressure timeseries | `epsiProcess_get_profiles_from_PressureTimeseries.m` |
| `modProcess_extract_profile.m` | Cut L1 data to a single profile | `epsiProcess_crop_timeseries.m` |

### 6.4 L1 → L2

| Function | Description | Source |
|----------|-------------|--------|
| `modProcess_L2_get_scan_spectra.m` | Per-scan: data window, pwelch, coherence subtract | `get_scan_spectra.m` |
| `modProcess_L2_calc_epsilon.m` | Nasmyth fit → epsilon, loops over `metadata.manifest.shear_channels` | `mod_efe_scan_epsilon.m` |
| `modProcess_L2_calc_chi.m` | Batchelor fit → chi (**currently broken — see Section 9**) | `mod_efe_scan_chi.m` |
| `modProcess_L2_qc.m` | QC flags: fom, accel, speed, pitch/roll | `mod_epsilometer_calc_turbulence_v2.m` lines ~473–526 |
| `modProcess_L2_run.m` | Top-level: profile list → Profile####.mat | NEW |

### 6.5 L2 → L3

| Function | Description | Source |
|----------|-------------|--------|
| `modProcess_L3_grid_profiles.m` | Interpolate profiles onto standard P axis | `epsiProcess_gridProfiles.m` |

---

## 7. Twist Counting — Ana's First Project

### Physical context
The instrument cable twists as it profiles. On the FastCTD, a fin can be adjusted to counteract this. The operator needs the current twist count **during** a deployment to know when and how much to adjust the fin. The twist count is included in the L1 data, computed as each file is processed and accumulated into a whole-deployment timeseries called TwistTimeseries.mat in `meta/`.

### How the algorithm works (from `GV_PlotUpAccumulation.m`)
1. Load `vnav` from L1 `.mat`: `compass` [N×3], `gyro` [N×3], `acceleration` [N×3], `dnum`, `time_s`
2. Remove bad timestamps (NaN, Inf, non-monotonic)
3. For each sample: rotate vectors to gravity-aligned z-axis frame using `SN_RotateToZAxis.m`
4. **Compass method (cross-check):** normalize horizontal compass components → complex unit vector → `phase()` → instantaneous heading angle
5. **Gyro method (primary):** cumulative sum of z-axis gyro × dt → total radians → ÷ 2π → full twist count
6. Negative = untwisting. "Neutral is Negative" — setting the fin to neutral makes the count go down.

### Data flow
```
For each L1 file:
  modProcess_L1_add_twist(data)
    reads vnav + ctd from file
    computes twist timeseries for this file (count starts from ~0)
    adds twist struct to file and saves
    twist.time_s, twist.dnum, twist.pressure,
    twist.count_gyro, twist.count_compass

When you want the full deployment picture:
  modProcess_L1_accumulate_twist_timeseries(L1_dir, metadata)
    reads twist field from all L1 files
    chains files with offset correction at boundaries
    applies spool swap resets from meta/SpoolSwapLog.csv
    saves meta/TwistTimeseries.mat
```

The `twist` field in each L1 file is self-contained (count starts from ~0 for each file). Reprocessing one file never corrupts the accumulated timeseries.

### SpoolSwapLog.csv
Human-readable, operator-edited, lives in `meta/`. Supports `#` comment lines — operators are encouraged to add notes.

```csv
# MODfish Spool Swap Log
# "Neutral is Negative" -- set fin to neutral to make the count go down
#
# Columns: datetime_utc, spool_id, spool_length_m, notes
#
2026-07-01T12:05:00Z, spool_D, 2000, "Start of cruise"
2026-07-15T14:30:00Z, spool_A, 2000, "Had to reterminate too many times. Need more length."
2026-07-17T08:15:00Z, spool_B, 1500, "Comms issues, swapping to shorter spool."
```

### Ana's step-by-step tasklist

#### Step 1 — Get familiar with the code and data
1. Load the example `.mat` files: `load('EPSI24_10_01_222113.mat')`. Familiarize yourself with the vnav fields.
2. Open `SN_RotateToZAxis.m`. Read it carefully. In your own words: what does it take as input, what does it return, and what is the physical meaning of the rotation?
3. Open `GV_PlotUpAccumulation.m`. Trace through the code section by section. Find the three lines that compute `tot_rot_gyro` and understand each one. What does `cumsum` do? Why do you multiply by `dt`? Why divide by `pi/2` at the end?
4. Run `GV_PlotUpAccumulation.m` on the example files (edit the hardcoded paths at the top). Does the plot look like what you expected?

#### Step 2 — Write `modProcess_L1_add_twist.m`
Write a function with this signature:
```matlab
function data = modProcess_L1_add_twist(data)
```
The function:
- Takes `data`, a struct already in memory (has `vnav`, `ctd`, and other fields from an L0 file)
- If `data.vnav` is empty or missing, prints a warning and returns `data` unchanged
- Computes twist using the gyro method (and compass as cross-check) — pull this logic from `GV_PlotUpAccumulation.m`
- Count starts from 0 for this file (no cross-file offset yet — that comes in Step 3)
- Creates `data.twist` with fields: `time_s`, `dnum`, `pressure`, `count_gyro`, `count_compass`
- Returns `data` with the new `twist` field added
- Use the standard function header (see the example in Section 2)

Test script (separate from the function itself):
```matlab
data = load('example_L0_file.mat');
data = modProcess_L1_add_twist(data, metadata);
figure; plot(data.twist.time_s, data.twist.count_gyro)
xlabel('time (s)'); ylabel('twist count (full rotations)')
```
Does the count grow steadily? Does it ever reverse? Does it match what `GV_PlotUpAccumulation` showed?

#### Step 3 — Write `modProcess_L1_accumulate_twist_timeseries.m` (no spool swap yet)
Write a function with this signature:
```matlab
function TwistTimeseries = modProcess_L1_accumulate_twist_timeseries(L1_dir, metadata)
```
The function:
- Lists all L1 `.mat` files in `L1_dir`, sorted by time
- Loops through files in order, loading the `twist` field from each
- Chains them: each file's `count_gyro` starts at 0, so you add the cumulative end value from the previous file as an offset
- Concatenates `time_s`, `dnum`, `pressure`, `count_gyro`, `count_compass` across all files
- Saves result to `fullfile(metadata.paths.meta, 'TwistTimeseries.mat')`
- Returns the `TwistTimeseries` struct

Test: does the accumulated count match the manual output from `GV_PlotUpAccumulation.m`?

#### Step 4 — Add SpoolSwapLog handling
Modify `modProcess_L1_accumulate_twist_timeseries.m`:
- Check if `meta/SpoolSwapLog.csv` exists; if not, proceed without it
- If it exists: read it, skipping `#` comment lines; parse `datetime_utc` column into dnum
- For each spool swap event: find the index in the accumulated timeseries where `dnum >= swap_dnum` and reset the cumulative offset at that point
- Add the spool swap timestamps as a field in `TwistTimeseries` for reference in plots

Test: create a fake `SpoolSwapLog.csv` with one entry partway through the example dataset. Verify the count resets at the right time.

#### Step 5 — Write `modPlot_twist_timeseries.m`
Write a function with this signature:
```matlab
function ax = modPlot_twist_timeseries(TwistTimeseries, ax)
```
The function:
- Plots `count_gyro` vs `datetime` (using datetime(dnum, 'ConvertFrom', 'datenum'))
- Marks upcast points in a different color (where `diff(pressure) < 0`)
- Shows current twist count in the title
- Adds annotation: *"Neutral is Negative — set fin to neutral to reduce count"*
- Marks spool swap events as vertical lines if `TwistTimeseries.spool_swap_dnum` exists
- `ax` input is optional (creates new figure if not provided)

#### Step 6 — Integration test
Run the full twist pipeline on the TLC WW minnow example files:
1. Run `modProcess_L1_add_twist` on every L1 file
2. Run `modProcess_L1_accumulate_twist_timeseries`
3. Run `modPlot_twist_timeseries`
4. Compare the plot to the existing manually-run output Nicole has from that cruise

---

## 8. Additional Tasks (after Ana finishes twist counter)

### Task 2: CTD Calibration — done
Shipped as the `calibrate_ctd` local subfunction inside `MODprocess_single_L0_to_L1.m` rather than a standalone `modProcess_L1_apply_ctd_calibration.m` (see Section 6.2). SBE cal equations, raw counts → P/T/C/S.

### Task 3: Sensor Manifest Reader — done
Shipped as `MODsetup_read_yaml.m` — YAML → `metadata`. Deliberately minimal so far: resolves only the AFE/CTD/altimeter fields the L0→L1 step uses today, not yet the full `metadata.manifest` (`shear_channels`/`fpo7_channels`/etc.) described in Section 5 — nothing consumes those fields yet, so they haven't been added. Extend it when the shear/FPO7 calibration steps (Section 6.2) need them.

### Task 4: L1 QC Overview Plot
`modPlot_L1_overview.m` — 4-panel figure: pressure, temperature, shear voltage, accelerometers.

### Task 5: Despike Function
`modProcess_L1_despike.m` — extract and generalize from `mod_epsilometer_calc_turbulence_v2.m` lines ~131–147.

---

## 9. Known Issues / Debt

| Issue | Location | Priority |
|-------|----------|----------|
| Chi processing broken | `mod_epsilometer_calc_turbulence_v2.m` lines 382–424 | **High — needed before cruise** |
| `volts_to_C` missing in `metadata.AFE.t1` | `mod_epsi_linear_calibration_FP07.m` ~line 70, silent try/catch | High — blocks chi |
| `Meta_Data.AFE` vs `Meta_Data.epsi` inconsistency | Scattered throughout codebase | Medium — fix in L1 refactor |
| Wrong calibration paths in `epsi_class_MetaData_doesnot_exist.m` | Lines 32–34 | Medium |
| Hard-coded `a3_g` as coherent acc channel | `mod_epsilometer_calc_turbulence_v2.m` line ~226 | Low — move to manifest |
| Regex block-splitting drops a block when binary payload starts with `\r\n` | `MODprocess_single_modraw_to_L0.m` (inherited from `mod_som_read_epsi_files_v4.m`): the lazy `\$EFE(...+?)\*hh\r\n` regex ends a block early whenever a record timestamp's low bytes are `0x0D 0x0A`, so that block fails the length check and is skipped (~0.25 s lost each time, recurs every 800 blocks while the ms counter lines up). Fix: parse by the declared hex block-length field instead of regex terminators. | Low — ~11 s lost per 16 h of data, but systematic |
| **To do:** cache calibration files locally in the deployment folder instead of requiring a manual copy. `MODsetup_read_yaml.m` should check `data_root/calibrations/` (mirroring `paths.raw`/`.L0`/`.L1`) first for each cal file (`SBE/<SN>.CAL`, `SHEAR_PROBES/<SN>/Calibration_<SN>.txt`); if missing there, read it from `calibrations_root` (the central `MOD_fish_calibrations` checkout) and copy it into `data_root/calibrations/` before use, so the deployment folder ends up as a self-contained record of exactly which cal files were used - same idea as `blt2021_0715`'s manually-populated `calibrations/` folder, done automatically. Deferred on 2026-07-24 (mid `l0_to_l1_conversion` testing) - not started. | Medium |

---

## 10. Milestones

| Date | Milestone |
|------|-----------|
| May 2026 | Plan written, Ana onboarded, example files sent, twist counter scoped |
| June 2026 | Ana: twist counter complete and tested; L0→L1 CTD + shear cal working on minnow data |
| July 2026 | Profile detection + L2 epsilon working, matching prior results |
| August 2026 | Chi (L2) fixed and working |
| September 2026 | Full pipeline end-to-end tested; L3 gridding working |
| Early October 2026 | Wiki updated, `MOD_fish_processing` README complete, pipeline cruise-ready |

---

## 11. Wiki Update Checklist

Wiki: `MOD_fish_processing/docs/` (MkDocs Material, deployed to GitHub Pages via `.github/workflows/docs.yml` — see Session Log 2026-07-09). Superseded the Notion wiki as the source of truth; pages live in-repo under `docs/workflow/` (what scripts do, how to run them) and `docs/concepts/` (physics/math background).

- [x] Draft "L0: converting .modraw to .mat" — `docs/workflow/L0_modraw_conversion.md`
- [x] Draft "Zero-padding numbered raw filenames" — `docs/workflow/pad_raw_filenames.md`
- [x] Draft "L0 to L1: converting raw counts to physical units" — `docs/workflow/L0_to_L1_conversion.md`
- [ ] Update "Setup during cruise" to reflect YAML-based config and new folder structure
- [ ] Add "Data levels" section (L0/L1/L2/L3)
- [ ] Update "How to process data" to use `MOD_fish_processing` workflow
- [ ] Add "Instrument configuration" section: YAML sensor manifest → `metadata.manifest`
- [ ] Add "Calibrations" section pointing to `MOD_fish_calibrations` and git tags
- [ ] Add "Twist counting" to field operations — how to run, what the plot means, spool swap procedure
- [ ] Update visualization section: MODvis_timeseries, SpectraExplorerApp, twist plot

---

## 12. Session Log

Reverse-chronological. Each step of the reorganization gets tested against real example files (kept in `mod_fish_lib/data_for_reorg/`, one subfolder per dataset type: `fctd`, `epsi_on_wirewalker`, `epsi_mako_w_fluor`, `epsi_minnow`, `epsi_mako`, `fctd_w_ucond`, `fctd_w_ucond_fluor`) before being ported into `MOD_fish_processing`.

### 2026-07-24 — First real end-to-end L0->L1 test run; `instrument_manifest` schema in setup.yml (branch `l0_to_l1_conversion`)

- **Ran `MODprocess_all_L0_to_L1` against `epsi_deepsolo/26_0520_ljc` for the first time** (previous session only got as far as building `setup.yml` and confirming the plan on paper - no MATLAB available that session). All 45 L0 files converted with no errors: `epsi.t1_volt`/`s1_volt`/`a1_g` all in physically sane ranges, shear `Sv` correctly resolved for SN261/SN421, `CTD.cal` correctly empty (no CTD hardware), external-CTD path correctly detected the absent `ctd/` folder and proceeded without it. Confirms L0->L1 needs nothing beyond what's already built for an epsi-only DeepSolo deployment - the remaining gap is downstream (shear/FPO7 calibration *application* still needs a real external-CTD parser for fall speed, per Section 6.2).
- **Redesigned `setup.yml`'s instrument declaration into an explicit `instrument_manifest` block**, per PLAN.md Section 5 - prompted by reviewing an older, richer pre-refactor yaml from `MOD_fish_lib` for ideas while deliberately keeping only what's needed today. Previously, "what's on the vehicle" was scattered: probe SN in a top-level `sn:` block, probe type buried in `afe.channels.<channel>.type`, and instrument presence (CTD, altimeter) only inferable from whether a yaml block existed at all. Now `instrument_manifest` is the single place that answers "what's physically here," with electrical/sampling specifics (full_range, ADCconf, sample_per_record) staying in separate detail sections below, keyed by the same names the manifest declares.
  - `instrument_manifest.afe` is keyed by **physical ADC slot** (`channel_1`..`channel_7`), not by sensor name - this matches how raw parsing actually sees the data (L0's `epsi.channel1`..`channel7` are positional, no sensor identity yet); each slot then declares `name` (the logical sensor name propagated everywhere downstream - `t1_volt`, `s1_volt`, `metadata.AFE.s1.cal`), `type`, and `sn`. `MODsetup_read_yaml.m` now sorts `channel_N` keys **numerically** to get ADC slot order, rather than trusting yaml field order like the old schema did - confirmed by testing that YAMLMatlab preserves declaration order but does not sort it, so a `channel_10` would have sorted before `channel_2` under the old approach the moment a deployment passed 9 channels. Real (if latent) correctness fix, not just reorganization.
  - `instrument_manifest.ctd.sn` replaces the old top-level `sn.ctd`. `instrument_manifest` also carries presence-only flags (`vnav`, `isap`, `alt`, `gps`, `fluor`) surfaced as `metadata.manifest.has_*` - nothing in L0->L1 reads them yet (those fields still just pass through from L0 unchanged), but a missing key and an explicit `false` now both resolve to `false`, per explicit design discussion - so existing minimal `setup.yml` files don't need edits as more instrument types get declared elsewhere.
  - Both real `setup.yml` files migrated to the new schema and re-tested end-to-end: `epsi_deepsolo/26_0520_ljc` (45 files, epsi + vnav only) and `epsi_mako_w_fluor/25_0408_d03_mako1_canyonhead` (96 files, epsi + ctd + isap + vnav + fluor) - both converted cleanly, output values unchanged from pre-refactor runs (confirms the schema change is a pure reorganization, not a behavior change): mako `ctd.T` 10.0-15.0°C, `ctd.S` 33.7-34.2 psu, `isap.hab` 0.2-83.6 m, matching the 2026-07-09 session's numbers.
  - `docs/workflow/L0_to_L1_conversion.md` and PLAN.md Section 5 updated to match - Section 5's original sketch (`sensors:`/`optional_sensors:` blocks, `channel_1`/`channel_2` generic keys) is now marked implemented for the manifest/presence-flag part; the grouped `shear_channels`/`fpo7_channels`-style convenience lists from that same sketch are explicitly called out as still not built, since nothing consumes them yet.

### 2026-07-23 — First real epsi-only deployment (`epsi_deepsolo/26_0520_ljc`): shear probe calibration lookup, optional CTD/altimeter, external-CTD plumbing (branch `l0_to_l1_conversion`)

Working through processing `data_for_reorg/epsi_deepsolo/26_0520_ljc` (DeepSolo, epsi-only, no CTD hardware) end-to-end surfaced several real gaps and one documentation bug:

- **`MODsetup_read_yaml.m`'s `ctd:`/`sn.ctd` and `altimeter.fctd`/`.epsi` blocks are now optional.** Both were read unconditionally before, so any deployment genuinely lacking that hardware (like this one) would hard-error at yaml-read time. Absent now means `metadata.CTD.cal = []` / no `metadata.GEOMETRY` at all, rather than requiring meaningless placeholder values in `setup.yml`.
- **Shear probe `Sv` lookup added**: `metadata.AFE.(channel).SN`/`.cal`, populated when `setup.yml`'s `sn.<channel>` is present and the channel's `afe.channels.<channel>.type` is `shear` - reads the most recent row of `calibrations_root/SHEAR_PROBES/<SN>/Calibration_<SN>.txt`, `[]` if that file doesn't exist yet (expected for newly-assigned probes). **FPO7 does NOT get the same treatment** - a first pass wrongly gave it an identical file-based lookup, but `dTdV` isn't a fixed, lookupable probe property like `Sv`; it's fit in-situ per deployment against real CTD temperature (`mod_epsi_linear_calibration_FP07.m`), so there's no calibration file to read. Caught and reverted before it shipped anywhere - FPO7 channels still get `.SN` tracked, just no `.cal`.
- **Conductivity units documentation bug found and fixed**: `docs/workflow/L0_to_L1_conversion.md` and this file's Section 6.2 table both said `ctd.C` is in mS/cm. Traced the actual math (`calibrate_ctd`'s `ctd.C*10./c3515` ratio, fed to `sw_salt`, which wants a dimensionless ratio to the `c3515 = 42.914` mS/cm standard) - `ctd.C` has always been in **S/m** (1 S/m = 10 mS/cm), never mS/cm. Also fixed the same mislabel in this file's 2026-07-09 session log entry (the *number* logged there, 3.7-4.2, was always correct for S/m - only the unit label was wrong).
- **External CTD plumbing (DeepSolo/Wirewalker) - wiring only, no real parser yet.** These vehicles' CTD data arrives as an independent file, never as `$SB49`/`$SB41` blocks in the `.modraw`/L0 stream - genuinely new functionality; no equivalent exists in `MOD_fish_lib` (only a never-implemented commented-out case in `epsi_class_yaml.m`). Added:
  - `metadata.vehicle_name` and `metadata.paths.ctd` (`data_root/ctd/`) to `MODsetup_read_yaml.m`, both optional (older `setup.yml` files, e.g. `epsi_mako_w_fluor`'s, predate `vehicle_name` entirely).
  - `MODprocess_read_external_ctd.m` (new file) - defines the field/unit contract (`dnum` as MATLAB datenum, `P` dbar, `T` °C, `C` S/m, `S` psu optional/derived) but is a stub that errors clearly if actually called - no sample file has been available from any DeepSolo/Wirewalker CTD instrument to build a real reader against.
  - `MODprocess_all_L0_to_L1.m` reads the whole deployment's external CTD once per session (only when `vehicle_name` matches AND `data_root/ctd/` exists on disk - absent folder is "no CTD yet," not an error), slices it per L0 file by `dnum` (via new local subfunction `slice_external_ctd`), and passes the chunk into `MODprocess_single_L0_to_L1` as a new optional 3rd argument.
  - `MODprocess_single_L0_to_L1.m`'s `calibrate_ctd` now derives `time_s` from `dnum` (`time_s = dnum*86400`, matching `MODprocess_single_modraw_to_L0.m`'s `convert_timestamp` convention exactly) and falls back to deriving `S` via `sw_salt` when not already present - both no-ops for the existing SBE41/SBE49 paths, both needed for external CTD chunks.
- Confirmed via testing plan (not yet run - no MATLAB available in the assisting environment this session) that for `26_0520_ljc` specifically, `data_root/ctd/` doesn't exist yet, so the external-CTD path is inert for this deployment; it'll process epsi-only once run.
- **`MOD_fish_calibrations` housekeeping** (separate repo, not `MOD_fish_processing`, but referenced by it): renamed the `SBECAL/` folder to `SBE/` (updated the one hardcoded reference in `MODsetup_read_yaml.m` to match), imported the full `SHEAR_PROBES/` archive from `MOD_fish_lib`, and renamed the existing `cal/2023-03`/`2023-12`/`2024-09`/`2025-03` tags to `sbe/*` (to make room for a `shear/*` namespace) - all four were unpushed local tags, so this was a same-commit rename, no shared-history impact. Added `shear/2025-12` tagging a new batch of shear probe calibrations (21 probes, including this deployment's `s1`/`s2` = 261/421).
- Did a full consistency pass across every `.md` file and every function header in the repo per user request. Found and fixed, beyond the above: `docs/workflow/pad_raw_filenames.md` still documented the old positional-argument signature and plain `y/n` prompt from before the 2026-07-23 GUI-dialog commit (below) - rewrote to match the current Name-Value signature and dialog/prompt/batch-skip fallback chain. Also found `MODsetup_save_metadata.m` had shipped as real, working code in the 2026-07-16 commit below, but that session log entry still said "design only, no code written yet," and Section 6.1's status table still said "Not started" - both corrected.

### 2026-07-23 — Replace pad_raw_filenames y/n prompt with a GUI dialog (branch `main`)

- `MODsetup_pad_raw_filenames.m`'s confirmation was a plain terminal `y/n` prompt, unanswerable when MATLAB is driven through an editor/IDE integration with no attached terminal. Switched to a small centered `uifigure` dialog (preview of up to 3 example renames + a count of the rest, a spinner to adjust the zero-padding digit count if not already fixed by the caller, Rename/Cancel buttons) whenever a display is available, falling back to the old text prompt when there's no display, and to a no-op warning under `-batch` - same three-tier fallback the function already had for `pad_width`, now covering the confirmation step too.
- Switched the function's argument style from positional (`raw_file_suffix`, `L0_dir`, `force`) to Name-Value pairs via an `arguments` block, adding `pad_width` as an explicit override for the auto-computed digit count. `MODprocess_all_modraw_to_L0.m`'s call site updated to match.
- `docs/workflow/pad_raw_filenames.md` was not updated at the time - caught and fixed in the 2026-07-23 consistency-pass entry above.

### 2026-07-16 — Metadata provenance and archiving (branch `l0_to_l1_conversion`)

- `metadata.mat` can be built in stages (yaml read now, calibration values merged in later — Section 6.2), can be regenerated from an edited yaml, and gets read at the start of nearly every script — often many times an hour during a cruise, same yaml each time. Added the design to Section 2 and shipped it the same session: `metadata.header.history`, an append-only struct array (`.timestamp`, `.computer`, `.event`, `.filepath`) that every writer of `metadata.mat` appends to, plus `MODsetup_save_metadata.m` (Section 6.1) as the one function all writers go through, which compares against what's on disk and picks one of three outcomes:
  - No-op — same yaml, same cal values in effect. Nothing written.
  - `'create'` — the yaml differs from what's on disk. Archives the existing `meta/metadata.mat` to `meta/archive/metadata_<timestamp>.mat`, then writes the new one.
  - `'update'` — yaml unchanged, but a derived value is new or changed, e.g. a probe serial number just resolved to a cal file. Writes `meta/metadata.mat` in place, no archiving.
- Updated the Section 3 folder diagram to show `meta/archive/`.
- Open question noted in Section 2: once metadata starts getting saved inside individual L0/L1/L2 files, a master `metadata.mat` may matter less.
- `MODsetup_read_yaml.m` now calls `MODsetup_save_metadata.m` at the end of every read, and returns `metadata.header` from whatever actually ended up on disk (so a no-op returns the existing history, not a fabricated new entry).

### 2026-07-11 — Fix `MODprocess_all_L0_to_L1` arg order; docstring/PLAN.md accuracy pass (branch `l0_to_l1_conversion`)

- **Real bug:** `metadata` (required) was sandwiched after the optional `L1_dir` in `MODprocess_all_L0_to_L1.m`'s signature, so calling it as `MODprocess_all_L0_to_L1(L0_dir, metadata)` silently mistook `metadata` for `L1_dir`. Moved `metadata` before the optional `L1_dir`/`reprocess_all` args; updated doc call examples to match. Re-tested against the 96-file `epsi_mako_w_fluor` deployment.
- Docstring/PLAN.md accuracy pass: removed `parse_epsi_channel_string`/`parse_single_epsi_channel` from `MODprocess_single_modraw_to_L0.m`'s documented subfunction list (dead code, never called from the parsing flow); fixed `MODsetup_read_yaml.m`'s docstring claiming it's "called by `MODprocess_all_L0_to_L1`" (it's called by the top-level caller, once per session, not by that function) and its "only resolves what L0→L1 uses" claim (`CTD.name`/`.SN`/`.sample_per_record` are resolved for the deployment record but not actually read anywhere in L0→L1); removed `metadata.CTD.name` from `MODprocess_single_L0_to_L1.m`'s documented inputs (never referenced in the function body).
- PLAN.md: Section 8 still listed CTD calibration and the yaml reader as open tasks; both had already shipped - marked done with pointers to the actual code. Fixed a dead doc path (`docs/L0_modraw_conversion.md` → `docs/workflow/L0_modraw_conversion.md`) and added the missing `L0_to_L1_conversion.md` pointer. Checked off `pad_raw_filenames.md` and `L0_to_L1_conversion.md` in the Section 11 wiki checklist.

### 2026-07-09 — L0 → L1: yaml metadata, physical-unit conversion, L0 rename (branch `l0_to_l1_conversion`)

- **Metadata now comes from yaml, read once per session.** Added `setup/MODsetup_read_yaml.m`: reads a deployment's `setup.yml`, derives `metadata.paths.*` fresh from a single `data_root` field (never saved), resolves the AFE channel manifest (`metadata.PROCESS.channels`, `metadata.AFE.(channel).full_range/.ADCconf/.type`), loads CTD calibration coefficients from `MOD_fish_calibrations/SBECAL/<SN>.CAL`, and picks the altimeter geometry block matching `fish_flag`. Saves `metadata.mat` into `meta/` with `paths` stripped out, per PLAN.md Section 2's "no paths in metadata.mat" rule. Deliberately minimal - only resolves the fields L0→L1 actually uses today (no `optional_sensors`, no full `metadata.manifest.shear_channels`-style lists from Section 5 yet, since nothing consumes them yet).
- **MATLAB (checked in R2024b) has no built-in YAML reader** - no `yaml.*` namespace, and `readstruct` only accepts `'json'`/`'xml'`/`'auto'` as `FileType`. Vendored the same third-party MIT-licensed `YAMLMatlab_0.4.3` toolbox the old codebase used (`MODsetup_make_metadata_from_yaml.m`) into `toolbox/YAMLMatlab_0.4.3/` (full toolbox incl. the bundled `snakeyaml-1.9.jar`, minus its `Tests/` folder).
- **Also vendored the CSIRO `seawater` toolbox** (`toolbox/seawater/`, 40 files, EOS-80) - needed for `sw_salt`/`sw_ptmp`/`sw_pden`/`sw_dpth`, used to derive `ctd.S`/`th`/`sgth`/`z` from calibrated P/T/C.
- **Built a minimal `setup.yml`** for `data_for_reorg/epsi_mako_w_fluor/25_0408_d03_mako1_canyonhead/meta/setup.yml`, trimmed to only the fields `MODsetup_read_yaml.m` reads (`data_root`, `calibrations_root`, `fish_flag`, `latitude`, `sn.ctd`, `afe.channels`, `ctd.type`/`.sample_per_record`, `altimeter.fctd`) - no comms/plot_properties/spectral/profiles blocks. Based on the real `MAKO1_25_0408_d03.yml` from the TLC cruise4 Dropbox project, which is the exact same deployment.
- **Added `processing/MODprocess_single_L0_to_L1.m`** (pure transformation: `data = MODprocess_single_L0_to_L1(L0_data, metadata)`) and **`processing/MODprocess_all_L0_to_L1.m`** (batch orchestrator, mirrors `MODprocess_all_modraw_to_L0.m`'s skip-unless-new-or-newest logic one level up, plus a `reprocess_all` switch to force everything). Ported from `mod_som_read_epsi_files_v4.m`'s physical-conversion logic (the L0 port only carried over the raw-parsing half): EFE counts → volts/g, CTD raw hex → P/T/C/S + derived `th`/`sgth`/`dPdt`/`z`/`dzdt`, altimeter/ISA500 distance → height above bottom (`hab`). **Design decision:** these three conversions live as local subfunctions inside `MODprocess_single_L0_to_L1.m` rather than as separate `modProcess_L1_apply_*.m` files (see Section 6.2) - nothing calls them standalone yet, so splitting them out now would be premature; do it when something else needs to call one directly.
- **Fixed a live bug found while doing this**: `MODprocess_single_modraw_to_L0.m`'s altimeter block called `orderfields(alt,{'dnum','time_s','dst','hab'})` but never set `alt.hab` - `hab` needs instrument geometry from metadata, which L0 deliberately doesn't have. This would have thrown a hard error on any deployment with MOD altimeter (`alt`) data; none of the four tested `data_for_reorg` deployments have any, so it was never hit. Removed `'hab'` from that `orderfields` call; `hab` is now correctly added downstream in `MODprocess_single_L0_to_L1.m` for both `alt` and `isap`.
- **Renamed `MODprocess_new_modraw_to_L0.m` → `MODprocess_all_modraw_to_L0.m`** (`git mv` + updated all internal references, docstrings, and current-facing docs in `docs/workflow/`) so the L0 and L1 batch orchestrators follow the same `MODprocess_all_*` naming pattern. Historical Session Log entries below that mention the old name are left as-is - they describe what was true when written.
- **Tested end-to-end** against `epsi_mako_w_fluor/25_0408_d03_mako1_canyonhead` (96 L0 files, already converted in an earlier session): all 96 converted to L1 with no errors. Spot-checked a mid-deployment file (file 30 of 96): T 9.9–15.2°C, P 1.2–112.1 dbar, S 33.7–34.2 psu, C 3.7–4.2 S/m - physically right for a San Diego canyon-head survey. (Originally logged here as "mS/cm" - a units-label mistake caught 2026-07-23; the number itself was always right, ctd.C has always been in S/m.) The first file (on-deck, pre-deployment) correctly comes out near-zero C/S with P≈0, consistent with the CTD being in air. `isap.hab` ranged 0.4–83.6 m (`isap.dst` maxes out at a flat 120 - likely the ISA500's max-range/no-detection value). Re-ran the batch orchestrator a second time: correctly skipped all but the newest file; `reprocess_all=true` correctly forced all 96 to redo.
- **Not yet in this step** (still open, tracked in Section 6.2/6.3/7): shear/FPO7 calibration, despike, SOM transfer-function filters, twist. This step only gets counts/hex to physical units - the granular calibration/QC functions PLAN.md originally scoped for L1 (Section 6.2 table) are still to be written on top of this.

### 2026-07-09 - Docs site scaffolded (MkDocs Material -> GitHub Pages)

- Moved documentation off the Notion wiki (ugly personal-account URL, and reluctance to keep piling pages onto the internal MOD wiki) and in-repo instead: `docs/` is now a MkDocs Material site, version-controlled and reviewable alongside code changes - matters once there are more GitHub contributors, since docs changes go through the same PR flow as everything else.
- Structure: `docs/workflow/` (what each script does, how to run it - existing `L0_modraw_conversion.md` moved here) and `docs/concepts/` (physics/math background: epsilon from shear, profile picking, figure of merit, noise spectrum - stub page only for now, filled in over time). `docs/index.md` is the landing page.
- `mkdocs.yml` at repo root: Material theme, search, MathJax via `pymdownx.arithmatex` for the concept pages' equations, `edit_uri` pointing at GitHub so any page has an "edit this page" link straight into a PR.
- `.github/workflows/docs.yml` builds and deploys to GitHub Pages (`mkdocs gh-deploy`) on every push to `main` that touches `docs/` or `mkdocs.yml`. Site will be live at `https://modscripps.github.io/MOD_fish_processing/` once GitHub Pages is enabled in repo settings (Settings -> Pages -> source: `gh-pages` branch) - not yet done; the first push to `main` after this merges creates the `gh-pages` branch for that setting to point at.
- Verified locally: `mkdocs build --strict` succeeds with no warnings.

### 2026-07-08 — Zero-pad numbered raw filenames

- Deployments whose raw files are numbered rather than datetime-named (`modsom_0`, `modsom_1`, ...) sorted wrong in every listing (`modsom_0, modsom_1, modsom_10, modsom_100, ...`). Added `MODsetup_pad_raw_filenames.m`: renames such files in place to zero-padded names (`modsom_000`, pad width = max(3, widest number present), per prefix). Contents untouched — rename only — with per-file byte-count verification and every rename logged to `meta/FilenamePadLog.csv`. Also renames matching L0 `.mat` files and updates their `raw_file_info.filename` so the already-converted skip logic in `MODprocess_new_modraw_to_L0` still matches. No-op on date-based or already-padded names; errors without touching anything if two files would collapse onto one padded name (e.g. `modsom_1` + `modsom_001`).
- `MODprocess_new_modraw_to_L0` now calls it after suffix detection, so padding happens at the modraw→L0 step and everything downstream sees sortable names. Prompts for confirmation before renaming; in non-interactive MATLAB (`-batch`) it skips with a warning instead (pass `force=true` to rename unprompted).
- Fixed a latent bug in `MODprocess_new_modraw_to_L0` while there: the "always reconvert the most recent file in case it's still being written" logic used the *alphabetically* last file — with unpadded names that was `modsom_99`, not the newest. Now picks the newest by modification time (`max([list_rawfile.datenum])`).
- Ran on the two affected `data_for_reorg` deployments with before/after md5 verification (hash sets identical): `epsi_minnow/23_1114_epsi01_minnow1` (7 raw + 7 L0 renamed) and `epsi_on_wirewalker/25_0408_tlc_ww1_navo2` (100 raw + 100 L0 renamed; files 100–192 already 3-digit). Re-ran `MODprocess_new_modraw_to_L0` on minnow afterward: 6 of 7 files correctly skipped, only the newest reconverted. Note: the damaged minnow files flagged in the earlier session-log entry are now named `modsom_001.modraw` and `modsom_006.modraw`.

### 2026-07-08 — Auto-detect raw file suffix

- `raw_file_suffix` was hardcoded to `.modraw` in `MODprocess_new_modraw_to_L0`. Added `MODprocess_detect_raw_suffix.m`: lists a folder, excludes known non-raw extensions (`.mat`, `.json`, etc.) and hidden/system files, and picks whichever extension is most common among what's left — errors instead of guessing wrong if there's no candidate or a tie. `MODprocess_new_modraw_to_L0` now takes `raw_file_suffix` as an optional third argument, auto-detected if omitted.
- Added `*.json` and `.claude/worktrees/` to `.gitignore` (editor/tooling noise, not project files) — currently only on branch `l0_modraw_conversion`, will land on `main` when that branch merges.

### 2026-07-08 — L0 conversion tested against full data_for_reorg dataset

- `data_for_reorg/` subfolders are populated now (4 of 7: `epsi_on_wirewalker`, `epsi_mako_w_fluor`, `epsi_minnow`, `fctd_w_ucond_fluor`; `fctd`, `epsi_mako`, `fctd_w_ucond` still empty). Ran `MODprocess_new_modraw_to_L0` on all four, converting straight into a sibling `L0/` folder next to each deployment's `raw/`. All 393 raw files across all four deployments converted successfully (0 failures):
  | Deployment | Files | Time | Fields present | Notes |
  |---|---|---|---|---|
  | `epsi_on_wirewalker/25_0408_tlc_ww1_navo2` | 193 | 524.5s | epsi only | 44 EFE blocks skipped — parser artifact, not corruption (see below) |
  | `epsi_mako_w_fluor/25_0408_d03_mako1_canyonhead` | 96 | 79.7s | epsi, ctd, isap, vnav | clean, 0 block errors |
  | `epsi_minnow/23_1114_epsi01_minnow1` | 7 | 35.0s | epsi, ctd | see below |
  | `fctd_w_ucond_fluor/25_0409_d05_fctd1_dye_survey` | 97 | 50.3s | epsi, ctd, isap, vnav | clean, 2 block errors total |
- **The `epsi_on_wirewalker` block errors are a parser artifact, not corruption.** Dissecting the raw bytes showed each "bad" block is one whose first record timestamp has low bytes `0x0D 0x0A` (= `\r\n`), which makes the lazy block-splitting regex end the match right at the header checksum; the length check then fails and the block is skipped (~0.25 s each). The exact 800-block spacing between errors is the ms-counter's low 16 bits cycling (800 blocks × 245.76 ms = 3 × 65,536 ms). Total loss: ~11 s across 16+ h. Logged in Section 9; proper fix is to parse by the declared hex block-length field.
- **`epsi_minnow` (NORSE 2023) has two genuinely damaged raw files** (distinct from the artifact above): `modsom_1.modraw` (14.5 MB vs ~37.9 MB siblings) and `modsom_6.modraw` (3.4 MB) show a broad smear of random payload lengths — bytes dropped mid-stream (likely comms dropouts), misaligning blocks. Both converted without crashing; `modsom_1` still yielded 1,120 intact blocks, `modsom_6` 291. Their `epsi` records will have gaps — check in MODvis_timeseries before using downstream. (`modsom_0` in the same deployment is pristine: 14,638/14,638 blocks clean.)

### 2026-07-08 — PLAN.md moved to MOD_fish_processing

- Moved this file from the `claude` branch of `MOD_fish_lib` to `MOD_fish_processing` (branch `main`), now that `MOD_fish_processing` is where active work happens. The `MOD_fish_lib` copy is now a stub pointing here.

### 2026-07-08 — Removed mod_class/Meta_Data dependency from MODprocess_new_modraw_to_L0

- `MODprocess_new_modraw_to_L0.m` still accepted a `mod_class` object and, even when called with a plain folder path, built a throwaway `Meta_Data` struct and saved it into every output `.mat` file. Removed entirely — both L0 functions (`MODprocess_single_modraw_to_L0.m`, `MODprocess_new_modraw_to_L0.m`) now take only plain file/folder paths, no metadata or config object of any kind. This is a deliberate move away from the class-based `epsi_class_yaml` approach (Section 2), which turned out to be more overhead than it was worth.
- `MODprocess_new_modraw_to_L0` now returns a cell array of the `.mat` file paths it produced, instead of a fake `mod_class`-like `obj`.
- Rewrote `l0_modraw_conversion` branch history into two clean commits (initial port, then the metadata-object removal) so each commit shows a real diff — an earlier commit that moved files from `processing/matlab/` to `processing/` had accidentally folded the metadata fix in as an unreadable "all new text" diff.

### 2026-07-07 — L0 modraw→mat ported to MOD_fish_processing

- Ported `MODprocess_single_modraw_to_L0.m` and `MODprocess_new_modraw_to_L0.m` from the `nicole` branch of `MOD_fish_lib` (where they'd been renamed from `MODprocess_modraw_to_L0.m` / `MODprocess_allnew_modraw_to_L0.m`) to `MOD_fish_processing`, branch `l0_modraw_conversion`, under `processing/matlab/`.
- Tested against two real `.modraw` files (an EPSI epsi+ctd+vnav file and an APEX profile file) using MATLAB in batch mode — confirmed raw counts come out plottable with correct time axes.
- Found and fixed two issues during porting:
  1. **CTD format bug:** code hardcoded `sbe_type = 'SBE49'` with a comment claiming an SBE41 fallback that didn't actually exist. Any SBE41-format CTD (e.g. APEX floats) silently produced all-NaN `ctd` output. Fixed by detecting format from the first `$SB49`/`$SB41` block's length.
  2. **Toolbox dependency:** both scripts used JLAB's `make`/`use` command-syntax helpers (from `EPSILOMETER/EPSILON/toolbox/misc/`), making them non-standalone. Replaced with explicit struct field assignment / removed the dead `use matData` line — scripts now run without needing anything from `MOD_fish_lib` on the path.
- `data_for_reorg/` subfolders are still empty — need example files copied in before the next step (L0→L1) can be tested against the full range of dataset types (fctd, epsi_mako, epsi_minnow, etc.), not just the two ad hoc files used this session (`data/sean_tests/raw/Profile32767_0.modraw`, `data/tlc2025_d05_chi_processing/raw_parking_lot/EPSI25_04_09_151049.modraw`).
- Wrote first wiki draft: `MOD_fish_processing/docs/L0_modraw_conversion.md`.
- **Git workflow established this session:** each processing step gets its own short-lived branch off `main` in `MOD_fish_processing` (e.g. `l0_modraw_conversion`), named after the step. Commit once the step is tested against real data, PR to `main` when ready to move to the next step. `PLAN.md` (this file) gets a dated Session Log entry each time a step lands, so the plan stays a running record, not just a forward-looking spec.
