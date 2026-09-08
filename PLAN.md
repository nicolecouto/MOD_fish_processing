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

### mod_scan_* functions: (scan, metadata) in/out, with a carve-out for generic helpers

`processing/scans/` pipeline-step functions (fpo7 cutoff, chi_obs, chi_mle, volts-to-Tg-spectrum)
follow the same struct-in/struct-out shape as `mod_L1_*` — `metadata`, plus a `channel` argument
wherever the function needs a per-channel deployment constant (`metadata.AFE.(channel).*`), and a
`noise_coefs` argument for the one value not yet part of the persisted metadata schema (resolved
per file from a calibration file, not per deployment from `setup.yml`):

```matlab
scan = mod_scan_fpo7_cutoff(scan, metadata, noise_coefs);
scan = mod_scan_calc_chi_mle(scan, metadata, channel, noise_coefs);
```

Same two rules as `mod_L1_*` (Section 2, "metadata" below) apply: only pass `metadata` when the
function actually uses it, and the header must name the specific `scan.*`/`metadata.*` fields
read — not just "scan struct" / "metadata struct". `channel`/`noise_coefs` are the "extra things
if absolutely necessary" allowance — kept as explicit arguments rather than folded into `scan` or
`metadata`, so someone with just a hand-built `f`/spectrum can call any of these by constructing a
minimal `scan` (and, for the per-channel functions, a minimal `metadata.AFE.(channel)`) without
needing the rest of a real deployment's metadata.

**Naming inside `scan`: everything spectral lives under `scan.spectra`, named like
`MOD_fish_lib`'s old `P<type><units>_<domain>` convention** (`Ps_volt_f`, `Pt_volt_f`, `Pt_Tg_k`,
`Pa_g_f`, `domain` = `f` frequency or `k` wavenumber) — not a bare `Pxx`/`P` (meaningless name,
and `P` collides with pressure, `data.ctd.P`/`scan.pressure`). `mod_scan_get_spectra.m`'s
multi-channel output is `scan.spectra.f` (shared) plus one `scan.spectra.(ch)_volt_f`/`.(ch)_g_f`
per manifest channel (e.g. `spectra.t1_volt_f`, `spectra.a2_g_f`). The single-channel working
struct the four FP07/chi functions pass between each other is also `scan.spectra`, shaped
differently (one channel's worth): `.f`, `.Pt_volt_f` (type-level name, no channel number — these
functions are always FP07-generic), `.k`/`.Pt_Tg_k` (added by
`mod_scan_fpo7_volts_to_Tg_spectrum.m`), `.fc_index` (added by `mod_scan_fpo7_cutoff.m`) — `f`/`k`
are the axes, and the values/index they index live alongside them rather than as separate
top-level `scan` fields, so a caller handed just `scan.spectra` has everything self-contained.
`scan.w`/`.ktemp`/`.nu`/`.epsilon` stay top-level `scan` fields — scalar physical properties of
the scan, not spectra or axes. Forward-looking, no code yet: cross-spectra (e.g. shear/accel
coherence, `Ps_shear_co_k`'s analog) are meant to land in this same `spectra` struct too, e.g.
`spectra.s1a3_co_k` — the naming scheme shouldn't need another rename when that's built.
`mod_scan_calc_chi_obs.m`/`mod_scan_calc_chi_mle.m` thread `scan` straight through their two
sub-calls (not disposable local copies) specifically so `spectra.k`/`.Pt_Tg_k`/`.fc_index` survive
on the struct they return — `MODprocess_single_L1_to_L2.m` persists those into `L2data.spectra`
alongside `chi_obs`/`chi_obs_kc`, not just the summary scalars.

**Carve-out:** generic physics/math helpers with no natural home in a `scan` struct — reusable
outside the fish-scan pipeline entirely — stay scalar-in/scalar-out. Currently:
`mod_scan_thermal_diffusivity.m`, `mod_scan_fpo7_transfer_function.m` (both still under
`processing/scans/` - they take `metadata`/probe-specific arguments, not pure math). The three
theoretical-spectrum-shape functions this carve-out originally covered -
`mod_scan_batchelor_spectrum.m`, `mod_scan_panchev_spectrum.m`, `mod_scan_nasmyth_spectrum.m` -
were moved to `toolbox/theoretical_spectra/` (branch `epsilon_processing`, 2026-09-08) once there
were three of them, not one, making the carve-out's own "reusable outside the fish-scan pipeline
entirely" reasoning literal rather than just a documentation note - see Section 12 session log.
Everything else under `processing/scans/` should take
`(scan, metadata, ...)`.

*Status: this reconciles with the top-of-section principle above ("every L1/L2/L3 processing
function takes a data struct and returns a modified data struct") — `mod_scan_*` had drifted from
it toward scalar args (commit `6dfe18a`, design note in Section 6.2 below) based on the reasoning
that deployment-constant values should resolve once into `metadata`. That reasoning still holds,
it just means those values belong in `metadata` fields read by the function, not extra positional
args. Done (2026-08-18): all 5 pipeline-step functions
(`mod_scan_get_spectra.m`/`mod_scan_fpo7_cutoff.m`/`mod_scan_fpo7_volts_to_Tg_spectrum.m`/
`mod_scan_calc_chi_obs.m`/`mod_scan_calc_chi_mle.m`) converted to this shape, and
`MODprocess_single_L1_to_L2.m`'s call site updated to match; `docs/workflow/L1_to_L2_conversion.md`
and `docs/workflow/L2_calc_chi.md` updated to match, tested against synthetic data in a MATLAB
sandbox (`checkcode` clean, full chi_obs/chi_mle chain runs end to end). Same day, follow-up pass:
`scan.P`/`scan.Pxx` renamed to `scan.spectra.*` per the naming convention above, `f`/`k` moved
inside `spectra`, and `MODprocess_single_L1_to_L2.m` extended to persist `spectra.k`/
`.(ch)_Tg_k`/`.(ch)_fc_index` into `L2data` (previously computed per scan/channel then discarded -
a real gap, not just a naming issue). `visualization/matlab/MODvis_spectra.m` updated to match
(`ChannelOrder`, `.spectra` field access) - GUI, not exercised by the sandbox test; needs a manual
check against a real L2 file.*

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

### No hard-coded values without a documented reason

A hardcoded constant is an untested claim that one value is right for every deployment, vehicle, and probe forever. This repo has already been bitten by exactly that: `a3_g` hardcoded as *the* coherent acc channel (line ~507 below), `kmin = 3` cpm independently duplicated in two files (line ~519), `sbe_type = 'SBE49'` hardcoded with a claimed-but-nonexistent SBE41 fallback that silently produced all-NaN CTD output (line ~776), `raw_file_suffix` hardcoded to `.modraw` (line ~746).

Rule: if a different deployment, vehicle, or probe could plausibly need a different value, it is a `metadata` field — sourced from `setup.yml`, with a documented default in `defaults.yml` (below) — not a literal in the function body. If a value truly is universal (a physical constant, a unit conversion, a coefficient from a cited equation), it may stay in code, but the line must carry a one-line citation or explicit reasoning for why it holds 100% of the time — a source, a paper, a physical law. "It worked for the deployments I tested" is not that reasoning.

### Centralized field registry + validate-at-point-of-use (never silently default)

**Superseded design decision (2026-08-18):** the "Phase 1/Phase 2" plan originally sketched here — a
`setup/defaults.yml` file, `MODsetup_read_yaml.m` silently filling any missing key from it with a
warning, and (later) a multi-tab review GUI — was replaced before Phase 1 was built. The warn-and-
silently-substitute approach still means every deployment ends up with values for parameters it may
never use (a FastCTD deployment needs zero chi variables), and a warning printed to the console during
an unattended batch run is easy to never see. What actually shipped instead:

- **One central lookup table, not a separate yaml file:** `setup/MODsetup_metadata_field_registry.m`
  returns a struct array — one entry per configurable value, with its `setup.yml` section/key, its
  `metadata` field path, a description, and a historical default (shown only as a prompt's starting
  value, never applied silently). Currently covers the 10 `PROCESS.CHI.*` chi parameters plus
  `Fs_epsi`/`nfft`/`dof`/`PROFILES.lowpass_factor`/`.gap_factor`/`.buffer_bins` (data only for the
  latter 6 — see "Deferred" below).
- **`MODsetup_read_yaml.m` never silently defaults anything**, for any field, full stop — a metadata
  field simply doesn't exist if `setup.yml` doesn't declare it. No warning-and-substitute step.
- **Validation moved to point of use.** Each function that reads specific metadata fields — already
  documented in its own header — validates exactly that list as literally its first executable lines:
  `metadata = MODsetup_validate_metadata(metadata, yaml_file, {'kmin_obs', ...})`. A no-op if
  everything's already present (the common case, every run after the first). If something's missing,
  `MODsetup_prompt_value.m` asks for it — dialog with a display, text fallback without one, hard error
  under `-batch` (never fabricates a value; same dialog/prompt/batch-skip fallback chain
  `pad_raw_filenames`, 2026-07-23, Section 12, established) — and offers to save the answer into
  `setup.yml` via `MODsetup_write_yaml_value.m` (a targeted text-level insert/update, not a full
  `WriteYaml.m` round-trip, so hand-written comments survive). If saved,
  `MODsetup_validate_metadata.m` raises `MODsetup_validate_metadata:yamlUpdated` instead of returning;
  the caller's enclosing loop (`MODprocess_all_L1_to_L2.m`'s per-file retry wrapper is the reference
  implementation) catches that identifier, reloads metadata fresh, and retries from the start — never
  resumes mid-run with two different metadata structs in play.
- **Done (2026-08-18)** for the chi group: `MODsetup_metadata_field_registry.m`,
  `MODsetup_prompt_value.m`, `MODsetup_write_yaml_value.m`, `MODsetup_validate_metadata.m` (all new,
  `setup/`), wired into the 5 chi-consuming functions
  (`mod_scan_get_spectra.m`/`mod_scan_fpo7_cutoff.m`/`mod_scan_fpo7_volts_to_Tg_spectrum.m`/
  `mod_scan_calc_chi_obs.m`/`mod_scan_calc_chi_mle.m` — every local hardcoded-default fallback in
  those files deleted, they now read `metadata.PROCESS.CHI.*` directly, trusting the validate call
  above), with the retry wrapper in `MODprocess_all_L1_to_L2.m`. See
  `docs/workflow/L2_calc_chi.md`'s "Where these values live" section.
- **Deferred, not silently left half-fixed:** `mod_scan_get_spectra.m`'s own unconditional
  `metadata.PROCESS.nfft`/`.Fs_epsi` reads and `mod_L1_detect_profiling_direction.m`'s
  `metadata.PROFILES.*` reads are not yet wired to `MODsetup_validate_metadata.m` — a deployment
  whose `setup.yml` omits `spectral:`/`afe.sample_rate`/`profile_detection:` now hits a plain
  unhelpful "field not found" MATLAB error there instead of a prompt. The registry entries for those
  6 fields already exist; wiring their two consumers is the same small pattern as the 5 chi functions.
- **Long-term goal, still open:** a multi-tab review GUI listing every value about to be used across
  every domain at once (Section 3's existing long-term-goal line) remains a plausible later UX
  improvement once `MODsetup_validate_metadata.m` is wired into more consumers, but per-field prompting
  at point of use has turned out sufficient so far — no immediate need to build it.

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
    time_index.mat             ← created during L0→L1 processing (MODprocess_L1_make_time_index.m)
    pressure_time_series.mat   ← created during L1/profile processing
    twist_time_series.mat      ← created by MODprocess_L1_accumulate_twist_timeseries
    spool_swap_log.csv         ← operator-edited any time during a cruise
  L0/                          ← created by pipeline
  L1/                          ← created by pipeline
  L2/                          ← created by pipeline
  grid/                        ← created by pipeline
  figures/                     ← created by pipeline
```

`spool_swap_log.csv` and `twist_time_series.mat` are created/updated during the cruise. All other files in `meta/` are regenerated deterministically from `setup.yml` and the data. (`meta/` filenames were renamed to snake_case on branch `chi_processing`, alongside adding `time_index.mat` - see Section 6.3.)

**Long-term goal:** A GUI for creating `setup.yml` with dropdowns (vehicle type, CTD SN pulled from `MOD_fish_calibrations`, per-channel sensor type + SN lookup, optional sensor toggles) and sensible defaults, so operators don't hand-edit YAML at sea.

---

## 4. Data Levels

| Level | Input | Output | Description |
|-------|-------|--------|-------------|
| **L0** | Raw binary files | Per-file `.mat` with raw counts/volts | Parse bytes, no calibrations, read headers |
| **L1** | L0 `.mat` files | Per-file `.mat` with calibrated, filtered, despiked data + `twist` field | CTD→P/T/C/S; shear→dshear/dz; FPO7→dT/dt; filters; twist timeseries for this file |
| **L2** | L1 `.mat` (+ profile indices, for vehicles that use them) | `Profile####.mat` per cast, **or** one `.mat` per L1 file (`epsi_deepsolo` — see Section 4 note below) | Per-scan spectra, epsilon, chi, QC flags |
| **L3** | L2 profiles | Gridded sections | Interpolate onto standard pressure grid |

**Done and merged to `main`:** L0 (raw → .mat, no calibrations, no metadata beyond what's in the file). Originally prototyped on the `nicole` branch of `MOD_fish_lib` as `MODprocess_modraw_to_L0.m` / `MODprocess_allnew_modraw_to_L0.m`; see Section 12 for what changed on the port. Documented in `MOD_fish_processing/docs/workflow/L0_modraw_conversion.md`.

**In progress on branch `l0_to_l1_conversion`:** L0 → L1 (counts/hex → physical units: epsi volts/g, CTD P/T/C/S, altimeter hab, cable twist count). First cut ships `MODsetup_read_yaml.m` + `MODprocess_single_L0_to_L1.m` / `MODprocess_all_L0_to_L1.m`, tested end-to-end against `epsi_mako_w_fluor/25_0408_d03_mako1_canyonhead` (96/96 files, physically plausible T/P/S/C). Twist counting (`mod_L1_add_twist.m`/`MODprocess_L1_accumulate_twist_timeseries.m`) added 2026-07-24 and wired into both orchestrators - see Section 7. Despike, filters, and shear/FPO7 calibration are still not in this step - see Section 6.2. Documented in `MOD_fish_processing/docs/workflow/L0_to_L1_conversion.md`. See Section 12 session log entries 2026-07-09 and 2026-07-24 for what changed.

**In progress on branch `l1_to_l2_conversion`:** L1 → L2 for `epsi_deepsolo` - per-scan spectra (shear/fpo7/accel, raw uncorrected pwelch), gated by profiling direction (downcast only, `dPdt > 0`) rather than split into `Profile####.mat` casts - a deliberate divergence from the old `mod_fish_lib` approach (see Section 4 note below and `docs/workflow/L1_to_L2_conversion.md`). No epsilon/chi yet. Prerequisite L0→L1 fixes shipped alongside: real DeepSolo external-CTD reader (`ctd/DeepSoloFallrise.mat`, P-only), `calibrate_ctd` renamed `process_ctd_fields` and made T/C-optional, and a new deployment-level `meta/pressure_time_series.mat` (profiling-direction classification - an L1-level product, consumed by L2). Tested end-to-end against a sandbox copy of `epsi_deepsolo/26_0520_ljc` - see Section 12 session log entry 2026-07-26.

**Done** (chi: branch `chi_processing`, off `l1_to_l2_conversion`; epsilon: branch `epsilon_processing`): FP07 in-situ `volts_to_C` calibration, the tau-based FP07 time-constant deconvolution, the noise-floor cutoff, a direct-integration `chi_obs`, and a Batchelor-spectrum MLE `chi_mle` - prompted by finding that `MOD_fish_lib`'s live chi calculation computes this deconvolution's transfer function but has silently stopped applying it since 2025-10-06 (relevant to a 2025 BLT paper correction Nicole/Arnaud need to describe precisely). Built and tested one module at a time against real `epsi_mako/blt2021_0715` data (the only deployment here with a real onboard CTD). `chi_mle` needed an `epsilon` estimate this repo didn't compute yet - `modProcess_L2_calc_epsilon.m` (shear-channel Nasmyth fit) now supplies one, and `chi_mle` is wired into `mod_L2_tile_scans.m` as a result. See `docs/workflow/L2_calc_chi.md`, `docs/workflow/L2_calc_eps.md`, and Section 12 session log entries 2026-07-27, 2026-07-28, and 2026-09-08.

**Next target:** fix the regex block-splitting artifact in `MODprocess_single_modraw_to_L0.m` (Section 9 — parse by declared hex block length instead of regex terminators)

### Two processing modes: realtime vs. postprocess

The pipeline above forks into two modes once L1 exists, matching two different jobs:

- **Realtime**: `modraw → L0 → L1 → L2` (per-file). Runs on each raw file as it lands during a deployment - never waits for a complete profile, so it works even mid-cast. This is what the on-deployment/at-sea visualization tools (`MODvis_timeseries.m`, `MODvis_twist_timeseries.m`) consume - L1 fields directly, plus L2's per-L1-file spectra (`MODprocess_single_L1_to_L2.m`/`MODprocess_all_L1_to_L2.m`, gated on `metadata.manifest.has_epsi` - see Section 6.4). No profile-cutting involved.
- **Postprocess**: `modraw → L1 → profiles → grid`. Run once a deployment (or a leg of one) is done, against a complete L1 dataset - produces the final science-quality output: one `Profile####.mat` per detected cast in `metadata.paths.profiles` (`modProcess_detect_profiles.m` + `modProcess_extract_profile.m` + `MODprocess_single_L1_to_L2_profile.m`/`MODprocess_all_L1_to_L2_profiles.m` - see Section 6.3), then interpolated onto a standard pressure grid (`modProcess_L3_grid_profiles.m`, Section 6.5 - not started). Every detected cast gets a CTD record regardless of direction; `profile_dir` only gates whether a given profile also gets epsi spectra (Section 6.3/6.4).

Both L2 paths share the same windowing core (`mod_L2_tile_scans.m`) but today compute spectra independently - realtime's per-file output and postprocess's per-profile output are not deduplicated against each other (the original simplicity-over-storage-optimization call, confirmed with Nicole - see Section 12, 2026-08-28 session log). L0 and L1 are shared unmodified by both modes; the fork happens entirely at the L2 step.

**Revised direction, not yet implemented** (Section 12, 2026-08-28 session log, "L1 disk duplication and realtime profile-assembly" follow-up): realtime should keep computing L2 exactly as today (per-L1-file, profile-detection-independent - this stays the fallback/QC view for when profile picking is unreliable, and for looking at raw spectra without the profile abstraction), but should also *assemble* profile-shaped output for realtime gridding by grouping L2's already-computed scans by which detected cast their center-time falls in, rather than recomputing scans from L1. Edge scans that straddle an L1 file boundary near a cast's start/end are expected to be approximate in this realtime-assembled view - understood and accepted, since postprocess's independent per-profile recompute (unchanged, still exact) is the authoritative science-quality product. This only applies to the realtime path; postprocess's `MODprocess_single_L1_to_L2_profile.m` keeps recomputing scans directly from each profile's own stitched L1 record, same as today.

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
| `process_ctd_fields` (local subfunction, `MODprocess_single_L0_to_L1.m`; renamed from `calibrate_ctd`, branch `l1_to_l2_conversion`) | SBE cal equations → P [dbar], T [°C], C [S/m], S [psu] when raw counts are present, plus derived `dPdt`/`z`/`dzdt` (always) and `th`/`sgth`/`S` (only when `T`/`C` are both present - needed for DeepSolo's P-only external CTD, see `MODprocess_read_external_ctd.m` below). SBE41 "PTS" format and external CTD arrive from L0/caller already in physical units - only derived fields are computed for those. | `get_CalSBE.m`, `mod_som_read_epsi_files_v4.m` SBE block | Done |
| `calibrate_altimeter_hab` | Raw distance → height above bottom, using `metadata.GEOMETRY.*`. Applied to both `alt` (MOD altimeter) and `isap` (ISA500) - verified against real `isap` data and, as of the `blt2021_0715` test run (2026-07-24), real `alt` data too. | `mod_som_read_epsi_files_v4.m` ALTI/ISAP blocks | Done |
| `MODprocess_read_external_ctd.m` | For DeepSolo/Wirewalker (`metadata.vehicle_name`), reads and normalizes a deployment's independent CTD file (dnum/P, optionally T/C/S), sliced per L0 file by `MODprocess_all_L0_to_L1.m` and passed into `MODprocess_single_L0_to_L1` as an optional 3rd argument. | NEW - no prior equivalent in `MOD_fish_lib` | DeepSolo done (branch `l1_to_l2_conversion`, 2026-07-26) - `ctd/DeepSoloFallrise.mat`, P-only. Wirewalker still not implemented (no sample file available) |
| `modProcess_L1_apply_shear_calibration.m` | `Sv × volts / fall_speed` → shear, loops over `metadata.manifest.shear_channels` | `mod_som_get_shear_probe_calibration_v2.m` | `Sv` lookup itself now done in `MODsetup_read_yaml.m` (`metadata.AFE.(ch).cal`, per-channel, from `calibrations_root/SHEAR_PROBES/<SN>/Calibration_<SN>.txt`). This row - actually applying it to compute shear (needs fall speed, e.g. `ctd.dPdt`) - not started |
| `MODprocess_L1_apply_fpo7_calibration.m` | Fit `dTdV`/`volts_to_C` in-situ per deployment against real CTD temperature, gated on descending data only (not a lookup like shear's `Sv` - a prior version of this plan conflated the two) | `mod_epsi_linear_calibration_FP07.m` | Done (branch `chi_processing`) — see `docs/workflow/L2_calc_chi.md` |
| `modProcess_L1_despike.m` | filloutliers movmedian per channel | `mod_epsilometer_calc_turbulence_v2.m` lines ~131–147 | Not started |
| `modProcess_L1_apply_filters.m` | Apply SOM instrument transfer function - design below | `get_filters_SOM.m` | Partially done (branch `chi_processing`, 2026-07-28): `MODsetup_define_filters.m` resolves `metadata.AFE.(ch).electronics_filter` for fpo7/shear/acc, once per deployment. Applied directly inside `mod_scan_fpo7_volts_to_Tg_spectrum.m`/`mod_scan_calc_chi_obs.m`/`mod_scan_calc_chi_mle.m` (new optional `electronics_filter` param) for fpo7/chi - the one real consumer today. No generic `modProcess_L1_apply_filters.m` wrapper built - shear/acc have no consumer yet (no epsilon module), so it would have one indirect caller and no direct one; see design note below for the reasoning. Split a generic apply-function out once shear/accel needs one too. |
| `mod_L1_add_twist.m` | Takes data struct, returns same struct with `twist` field added — see Section 7 | `GV_PlotUpAccumulation.m` | Done (Ana's project, branch `l0_to_l1_conversion`) |
| `MODprocess_L1_make_pressure_timeseries.m` | Concatenates `ctd.dnum`/`.P` from all L1 files → deployment-length pressure record (no metadata needed); saved as `meta/pressure_time_series.mat` | NEW — see Section 6.3, this is `modProcess_make_pressure_timeseries.m` implemented under the `MODprocess_L1_*` naming | Done (branch `l1_to_l2_conversion`) |
| `mod_L1_detect_profiling_direction.m` | Classifies each pressure sample as descending (`dPdt_smoothed > 0`) or not — gap detection, cheby2 lowpass sized to the record's own sample spacing, buffered edges. Direction-only, not a full start/end profile-picker (see Section 6.3) | `epsiProcess_get_profiles_from_PressureTimeseries.m` (re-derived, not ported as-is — see `docs/workflow/L1_to_L2_conversion.md`) | Done (branch `l1_to_l2_conversion`) |

#### Design note: instrument filters (`MODsetup_define_filters.m` + `modProcess_L1_apply_filters.m`)

**`MODsetup_define_filters.m` built (2026-07-28, same day as this note, branch `chi_processing`)** - the resolve-once half below shipped as designed. **`modProcess_L1_apply_filters.m` deliberately not built as a generic wrapper** - see the deviation note at the end of this section for why, and the §6.2 table row above for what shipped instead.

`MOD_fish_lib`'s `get_filters_SOM.m` bundles every channel's instrument transfer function into one struct: per-channel ADC sinc⁴ response, shear's charge-amp electronics filter (loaded from a network-analysis `.mat`), the optional Tdiff analog-differentiator filter, gains, and the FPO7 thermal rolloff (`H.FPO7 = @(speed)(...)`, the one piece already re-implemented here as `mod_scan_fpo7_transfer_function.m` - see `docs/workflow/L2_calc_chi.md`). Naively porting the whole file as one function - or as a `MODsetup_define_filters.m` that resolves *all* of it at once - runs into the fact that `H.FPO7` needs fall speed, which is scan-specific, not deployment-specific. But that turns out to be the *only* term with that problem:

- **`f` is not actually scan-specific.** It comes from `metadata.PROCESS.nfft`/`.Fs_epsi`, both fixed for the whole deployment, so it's identical for every scan (`mod_scan_get_spectra.m` already returns the same `f` every time it's called within a file). Everything in `get_filters_SOM.m` that depends only on `f` and metadata - ADC sinc⁴ per channel type, shear's charge-amp filter, the Tdiff filter, gains - is therefore a genuine deployment-level constant, exactly like `metadata.AFE.(ch).cal`/`.volts_to_C`.
- **Only the FPO7 thermal rolloff depends on something that changes every scan** (fall speed `w`), which is why it has to stay a small per-scan pure function rather than something resolved once.

Proposed split, following the pattern `MODsetup_read_yaml.m`/`MODprocess_L1_apply_fpo7_calibration.m` already establish (resolve-once vs. apply-per-scan):

- **`MODsetup_define_filters.m`** (new, `setup/`): called once per deployment, like `MODsetup_read_yaml.m`. Resolves each channel's fixed electronics/ADC response (sinc⁴, charge-amp, Tdiff, gains) from `f` (derived from `metadata.PROCESS.nfft`/`.Fs_epsi`) and `metadata.AFE.(ch)`/`.Firmware`, and stores the result back onto `metadata.AFE.(ch).electronics_filter` (or similar - exact field name TBD when built). Persisted via `MODsetup_save_metadata.m` like every other resolved calibration value.
- **`mod_scan_fpo7_transfer_function.m`** (existing, `processing/scans/` after today's move) stays exactly as-is - the one term that can't be precomputed, since it needs per-scan `w`.
- **`modProcess_L1_apply_filters.m`** (still not started as a generic function - see deviation below): for each channel, multiplies its precomputed `metadata.AFE.(ch).electronics_filter` by `mod_scan_fpo7_transfer_function`'s output (for channels that have a speed-dependent term) and applies the combined filter to that channel's spectrum.

**Deviation from the design as originally sketched (2026-07-28, same session `MODsetup_define_filters.m` shipped)**: rather than a generic `modProcess_L1_apply_filters.m` that "applies the combined filter to that channel's spectrum" for any channel, the combination is done directly inside the existing pure `mod_scan_fpo7_volts_to_Tg_spectrum.m` (new optional `electronics_filter` parameter, default 1/no-correction), threaded through `mod_scan_calc_chi_obs.m`/`mod_scan_calc_chi_mle.m` to `MODprocess_single_L1_to_L2.m`'s chi call site. Reason: fpo7/chi is the only channel type with a real consumer today - shear/accel channels have `electronics_filter` resolved (via `MODsetup_define_filters.m`, built as designed) but nothing downstream to apply it to yet, since `modProcess_L2_calc_epsilon.m` (§6.4) doesn't exist. A generic apply-wrapper right now would have exactly one indirect caller, the same "pass-through wrapper with no logic of its own" shape this repo removed once already (`MODprocess_L2_kinematic_viscosity.m`, see 2026-07-28 session log below). Build `modProcess_L1_apply_filters.m` for real once shear/accel spectra have a second consumer to apply it to.

### 6.3 Profile detection

| Function | Description | Source | Status |
|----------|-------------|--------|--------|
| `MODprocess_L1_make_pressure_timeseries.m` | Concatenate pressure from all L1 files → `meta/pressure_time_series.mat` | `epsiProcess_make_PressureTimeseries.m` | Done (branch `l1_to_l2_conversion`) — see Section 6.2 |
| `mod_L1_detect_profiling_direction.m` | Classify each pressure sample as descending or not (direction only — not full profile start/end indices) | `epsiProcess_get_profiles_from_PressureTimeseries.m` (re-derived for sparse data) | Done (branch `l1_to_l2_conversion`) — see Section 6.2. Full profile-picker (start/end indices, merging, min-length filtering) below is still not started |
| `MODprocess_L1_make_time_index.m` | Per-L1-file `epsi.dnum` start/end → `meta/time_index.mat`, so a profile's overlapping L1 file(s) can be found without loading full file contents | NEW — no legacy equivalent (`TimeIndex.mat` was aspirational in this repo until now; the old `MOD_fish_lib` `TimeIndex.mat` carried more than this needs) | Done (branch `chi_processing`) |
| `modProcess_detect_profiles.m` | Find downcast/upcast start/end indices from pressure timeseries (full profile-picker, speed-limit hysteresis) | `epsiProcess_get_profiles_from_PressureTimeseries.m` | Done (branch `chi_processing`) |
| `modProcess_extract_profile.m` | Cut L1 data to a single profile, stitching across an L1 file boundary when a profile spans more than one file, with real gap detection (never lets an FFT window span a genuine timestamp gap) | `epsiProcess_crop_timeseries.m` + `epsiProcess_merge_mat_files.m` (re-derived, not ported — legacy merge has no gap detection at all) | Done (branch `chi_processing`) |
| `mod_L2_tile_scans.m` | Shared scan-tiling/spectra core, factored out of `MODprocess_single_L1_to_L2.m`, called by both the per-file "realtime" path and the new per-profile path | NEW — extracted from `MODprocess_single_L1_to_L2.m` | Done (branch `chi_processing`) |
| `MODprocess_single_L1_to_L2_profile.m` / `MODprocess_all_L1_to_L2_profiles.m` | Per-profile L1→L2 orchestration (final science-quality product), parallel to the existing per-file realtime pair | NEW | Done (branch `chi_processing`) |
| `MODprocess_all_extract_profiles.m` | Extraction-only phase, split out of `MODprocess_single_L1_to_L2_profile.m` so conversion no longer does its own file I/O - saves `profiles_raw/Profile####.mat` | NEW - split out of the function above | Done (branch `epsilon_processing`, 2026-09-08) |

### 6.4 L1 → L2

**For `epsi_deepsolo`, this step deliberately does not use profile indices from Section 6.3** — it computes per-scan spectra directly across each L1 file's continuous timeseries, gated by `mod_L1_detect_profiling_direction.m`'s per-sample `is_down` classification rather than discrete profile start/end indices. See `docs/workflow/L1_to_L2_conversion.md` for the full writeup of why and how.

| Function | Description | Source | Status |
|----------|-------------|--------|--------|
| `mod_scan_get_spectra.m` | Per-scan: pwelch on shear/fpo7/accel channels (raw, uncorrected — no `h_freq` transfer function yet). No coherence subtract | `get_scan_spectra.m` (stripped down — no epsilon/chi/coherence) | Done (branch `l1_to_l2_conversion`) — spectra only, see Section 4 |
| `MODprocess_single_L1_to_L2.m` | Per-L1-file: 50% overlap scan tiling, gate by `PressureTimeseries.is_down`, assemble scan-dimension arrays | NEW | Done (branch `l1_to_l2_conversion`) |
| `MODprocess_all_L1_to_L2.m` | Batch orchestrator, mirrors `MODprocess_all_L0_to_L1.m`'s shape | NEW | Done (branch `l1_to_l2_conversion`) |
| `modProcess_L2_calc_epsilon.m` | Nasmyth fit → epsilon, called per shear channel from `mod_L2_tile_scans.m`'s per-scan loop (not a `metadata.manifest.shear_channels` list - channels are filtered inline the same way `chi_obs_channels` already is, for consistency) | `mod_efe_scan_epsilon.m` | Done (branch `epsilon_processing`, 2026-09-08) - see `docs/workflow/L2_calc_eps.md` |
| `mod_scan_fpo7_volts_to_Tg_spectrum.m` | Shared first stage for both chi estimators: raw FP07 volts spectrum → tau-deconvolved temperature-gradient wavenumber spectrum | `mod_efe_scan_chi.m` (steps 1-3) | Done (branch `chi_processing`) — split out of `MODprocess_L2_calc_chi.m` once `chi_mle` needed the identical conversion |
| `mod_scan_calc_chi_obs.m` | Direct-integration chi_obs (FP07 calibration → tau deconvolution → noise-floor cutoff → wavenumber integration). No FOM yet (**old `mod_efe_scan_chi.m` currently broken — see Section 9**) | `mod_efe_scan_chi.m` | Done (branch `chi_processing`, renamed from `MODprocess_L2_calc_chi.m`) — needs real onboard CTD T (blocked for DeepSolo, works for `epsi_mako`); see `docs/workflow/L2_calc_chi.md`. FOM still not started |
| `mod_scan_batchelor_spectrum.m` | Theoretical Batchelor (1959) temperature-gradient spectrum evaluated at a given k - the model `chi_mle` fits | `batchelor.m` local subfunction inside `mod_efe_scan_chi.m` | Done (branch `chi_processing`) |
| `mod_scan_calc_chi_mle.m` | chi_mle via Batchelor-spectrum MLE fit (Ruddick, Ozsoy & Vagle 2000) - grid-search over chi with epsilon/nu/ktemp fixing the spectrum's shape | `mod_efe_scan_chi.m` / `get_chi_mle.m` / `mle_any_model.m` / `logLikelihood.m` | Done (branch `chi_processing`); wired into `mod_L2_tile_scans.m` (branch `epsilon_processing`, 2026-09-08) now that `modProcess_L2_calc_epsilon.m` supplies epsilon; grid-search zoom split into shared `toolbox/mod_scan_mle_grid_search.m` at the same time - see `docs/workflow/L2_calc_chi.md`, `docs/workflow/L2_calc_eps.md` |
| `mod_scan_fpo7_transfer_function.m` | FP07 thermal time-constant deconvolution filter, `tau0`/`exponent` exposed as overridable parameters for a tau sensitivity comparison | `get_filters_MADRE.m`/`h_fp07.m` (formula unchanged; the deconvolution step itself was silently dropped from `MOD_fish_lib`'s live `mod_efe_scan_chi.m` on 2025-10-06 — see Section 9) | Done (branch `chi_processing`) |
| `mod_scan_fpo7_cutoff.m` | Noise-floor cutoff (kc) for chi_obs/chi_mle's wavenumber range - fixes two indexing bugs found in the original | `FPO7_cutoff.m` | Done (branch `chi_processing`) |
| `mod_scan_thermal_diffusivity.m` | ktemp for chi_obs/chi_mle, via already-vendored `sw_dens`/`sw_cp` + a ported thermal-conductivity term | `kt.m`/`thermometric_cond.m` (units corrected - see `docs/workflow/L2_calc_chi.md`) | Done (branch `chi_processing`) |
| `modProcess_L2_qc.m` | QC flags: fom, accel, speed, pitch/roll | `mod_epsilometer_calc_turbulence_v2.m` lines ~473–526 | Not started |

### 6.5 L2 → L3

| Function | Description | Source |
|----------|-------------|--------|
| `modProcess_L3_grid_profiles.m` | Interpolate profiles onto standard P axis | `epsiProcess_gridProfiles.m` |

---

## 7. Twist Counting — Ana's First Project

**Status: Done, tested, and wired into the pipeline (2026-07-24, branch `l0_to_l1_conversion`)** - see Session Log entry below for what shipped and what changed from Ana's original draft. The step-by-step tasklist and function signatures below are Ana's original scoping and are left as-is as a record of the assignment; the actual 2026-07-24 shipped filenames followed the repo's `MODprocess_`/`MODvis_` capital-MOD convention (Section 6.1's naming note) rather than the `modProcess_`/`modPlot_` names used below - `MODprocess_L1_add_twist.m`, `MODprocess_L1_accumulate_twist_timeseries.m`, `MODvis_twist_timeseries.m` (plotting functions live in `visualization/matlab/`, matching `MODvis_timeseries.m`). The first of those was renamed again, to `mod_L1_add_twist.m` in `processing/L1/`, on 2026-07-28 - see Section 6.2's current table for today's actual name.

### Physical context
The instrument cable twists as it profiles. On the FastCTD, a fin can be adjusted to counteract this. The operator needs the current twist count **during** a deployment to know when and how much to adjust the fin. The twist count is included in the L1 data, computed as each file is processed and accumulated into a whole-deployment timeseries called twist_time_series.mat in `meta/`.

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
    applies spool swap resets from meta/spool_swap_log.csv
    saves meta/twist_time_series.mat
```

The `twist` field in each L1 file is self-contained (count starts from ~0 for each file). Reprocessing one file never corrupts the accumulated timeseries.

### spool_swap_log.csv
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
| Chi processing broken - `mod_efe_scan_chi.m` computes the FP07 time-constant transfer function (`filter_TF`) but, since commit `051d80f` (2025-10-06, "fix linear volts to C conversion"), never divides by it - the deconvolution is silently a no-op. Relevant to a 2025 BLT paper correction. Cannot fix `MOD_fish_lib` directly (off-limits) - re-implemented from scratch in `MOD_fish_processing` instead | `mod_epsilometer_calc_turbulence_v2.m` lines 382–424 / `mod_efe_scan_chi.m` | **High — needed before cruise.** Resolved in `MOD_fish_processing` (branch `chi_processing`): direct-integration `chi_obs` (`mod_scan_calc_chi_obs.m`, renamed from `MODprocess_L2_calc_chi.m` once `chi_mle` existed too) and a Batchelor-spectrum MLE `chi_mle` (`mod_scan_calc_chi_mle.m`) - see `docs/workflow/L2_calc_chi.md`. `MOD_fish_lib` itself unchanged |
| `volts_to_C` missing in `metadata.AFE.t1` | `mod_epsi_linear_calibration_FP07.m` ~line 70, silent try/catch | Resolved in `MOD_fish_processing` via `MODprocess_L1_apply_fpo7_calibration.m` (branch `chi_processing`). `MOD_fish_lib` itself unchanged |
| `Meta_Data.AFE` vs `Meta_Data.epsi` inconsistency | Scattered throughout codebase | Medium — fix in L1 refactor |
| Wrong calibration paths in `epsi_class_MetaData_doesnot_exist.m` | Lines 32–34 | Medium |
| Hard-coded `a3_g` as coherent acc channel | `mod_epsilometer_calc_turbulence_v2.m` line ~226 | Low — move to manifest |
| Regex block-splitting drops a block when binary payload starts with `\r\n` | `MODprocess_single_modraw_to_L0.m` (inherited from `mod_som_read_epsi_files_v4.m`): the lazy `\$EFE(...+?)\*hh\r\n` regex ends a block early whenever a record timestamp's low bytes are `0x0D 0x0A`, so that block fails the length check and is skipped (~0.25 s lost each time, recurs every 800 blocks while the ms counter lines up). Fix: parse by the declared hex block-length field instead of regex terminators. | Low — ~11 s lost per 16 h of data, but systematic |
| **To do:** cache calibration files locally in the deployment folder instead of requiring a manual copy. `MODsetup_read_yaml.m` should check `data_root/calibrations/` (mirroring `paths.raw`/`.L0`/`.L1`) first for each cal file (`SBE/<SN>.CAL`, `SHEAR_PROBES/<SN>/Calibration_<SN>.txt`); if missing there, read it from `calibrations_root` (the central `MOD_fish_calibrations` checkout) and copy it into `data_root/calibrations/` before use, so the deployment folder ends up as a self-contained record of exactly which cal files were used - same idea as `blt2021_0715`'s manually-populated `calibrations/` folder, done automatically. Deferred on 2026-07-24 (mid `l0_to_l1_conversion` testing) - not started. | Medium |

### `chi_processing` code review findings (2026-07-28) — recorded, not yet fixed

Ran `/code-review` against the branch after the `chi_obs`/`chi_mle`/reorg work above. Nicole's call: save the findings, don't act on them yet. Ranked most-severe first; none of these have been fixed.

1. **`MODprocess_single_L1_to_L2.m:227`** (correctness, confirmed) - `chi_obs` is computed from an interpolated fall speed (`w_all(iScan)`) with no check that it's finite/nonzero. `w=0` or non-finite makes `mod_scan_fpo7_transfer_function.m` compute `tau=Inf`, so `mod_scan_calc_chi_obs.m` returns `chi_obs=NaN` but `kc=Inf` instead of the documented `NaN` - silently corrupting `L2data.chi_obs_kc` for that scan.
2. **`docs/workflow/L1_to_L2_conversion.md:117` / `docs/workflow/L0_to_L1_conversion.md:273`** (documentation, confirmed) - the manual "run it by hand" `addpath` instructions were never updated for the `processing/scans/`/`processing/L1/` moves; `addpath` isn't recursive, so following either doc verbatim throws "Undefined function" on the first per-scan/per-file call.
3. **`toolbox/theoretical_spectra/mod_scan_batchelor_spectrum.m:68`** (correctness; moved from `processing/scans/` 2026-09-08, line number unchanged) - `kb = (epsilon/nu/ktemp^2)^(1/4)` has no guard against `epsilon <= 0`; produces a complex-valued spectrum instead of erroring, which `mod_scan_calc_chi_mle.m` then feeds into `chi2pdf` as a complex `z` (undefined behavior) with no warning.
4. **`processing/scans/mod_scan_calc_chi_mle.m:149`** (correctness) - when the direct-integration seed (`chi_seed`) is non-positive/non-finite, returns `chi_mle=NaN` but leaves `kc` at its already-computed valid value instead of also `NaN`, contradicting the function's own documented contract (and the `kc<=kmin` branch just above it, which does reset both).
5. **`processing/scans/mod_scan_calc_chi_mle.m:131`** (duplication) - re-derives `mod_scan_calc_chi_obs.m`'s entire preprocessing (deconvolve, find `kc`, restrict range, integrate for a seed) inline instead of reusing it, and `kmin = 3` cpm is hardcoded independently in both files - a caller needing both estimates (e.g. `analysis/chi_tau_mle_comparison.m`) redoes the noise-floor search and deconvolution twice, and a future `kmin` retune could silently land in only one of the two files.
6. **`toolbox/theoretical_spectra/mod_scan_batchelor_spectrum.m:78`** (correctness, latent; moved from `processing/scans/` 2026-09-08, line number unchanged) - the scalar-chi `reshape(Psg, size(k))` is a no-op since `k` was already overwritten to a column vector earlier in the function; not exercised by the current caller (always passes a vector of candidate chi values), but a future scalar-chi/row-vector-k caller would silently get the wrong orientation back.
7. **`processing/scans/mod_scan_calc_chi_mle.m:190`** (robustness) - the fixed 4-pass grid search returns `chi_grid(best)` with no flag for whether it actually converged vs. landed pinned to a search-range edge (e.g. a scan where `kc` barely exceeds `kmin`, so `chi_seed` is derived from very few bins).
8. **`analysis/chi_tau_mle_comparison.m:79`** (correctness, one-off script) - `cal_pr` is read only from `Meta_Data.AFE.t1.pr` and reused for `t2`'s `cal_profile` interpolation too, on an assumption stated in a comment but never checked at runtime; if t2's segments actually used different pressure bins, every t2 `chi_obs`/`chi_mle` number this script reports would be silently wrong.
9. **`processing/MODprocess_single_L1_to_L2.m:158`** (duplication, pre-existing) - the "which channels are of type X" filter loop is duplicated near-identically in `MODprocess_single_L1_to_L2.m`, `MODprocess_L1_apply_fpo7_calibration.m`, and `MODprocess_single_L0_to_L1.m`; a future AFE-type-taxonomy change would need to be applied to all three copies.

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
- [x] Draft "L1 to L2: downcast-gated spectra" — `docs/workflow/L1_to_L2_conversion.md`
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

### 2026-09-08 - Moved theoretical-spectrum functions into toolbox/theoretical_spectra/ (branch `epsilon_processing`)

`mod_scan_batchelor_spectrum.m` and `mod_scan_nasmyth_spectrum.m` (Phase B, same day) are both
already in the "Carve-out" category (Section 2) - generic physics/math helpers with no natural
home in a `scan` struct, reusable outside the fish-scan pipeline entirely - alongside
`mod_scan_panchev_spectrum.m` (added 2026-09-01, currently only consumed by `MODvis_spectra.m`'s
plotting). With three theoretical-spectrum-shape functions now living side by side in
`processing/scans/`, sharing that carve-out but not that directory's `(scan, metadata, ...)`
convention (all three are plain `(params..., k) -> spectrum` functions, no `scan`/`metadata`
argument at all), moved all three - unchanged, filenames kept exactly as-is (`git mv`, no rename) -
into a new `toolbox/theoretical_spectra/`. `mod_scan_thermal_diffusivity.m`/
`mod_scan_fpo7_transfer_function.m` stay in `processing/scans/`: both take `metadata`/probe-
specific arguments and aren't pure `(params, k)` spectrum shapes, so they don't fit this new
directory's narrower scope.

No call sites needed updating - every consumer (`mod_scan_calc_chi_mle.m`,
`mod_scan_calc_epsilon_obs.m`, `mod_scan_calc_epsilon_mle.m`, `modProcess_L2_calc_epsilon.m`,
`MODvis_spectra.m`) calls these by bare function name, resolved via the MATLAB path, not a literal
path string - confirmed by a repo-wide grep before moving. This repo has no recursive
`addpath(genpath(...))` anywhere (confirmed by grep) - path setup is either a one-off `addpath()`
inside a specific function (e.g. `MODsetup_read_yaml.m` adding `toolbox/YAMLMatlab_0.4.3`) or the
manual "How to run it" doc snippets. Nicole's own `startup_mod_fish_processing` (used by `deepsolo`
and other downstream repos, not itself part of this repo) already uses a recursive `addpath`, so no
in-code `addpath` was added here for `toolbox/theoretical_spectra/` - only
`docs/workflow/L2_calc_eps.md`'s "How to run it" snippet was updated, for a reader not using that
script. Updated the two still-open code-review findings (Section 9, items 3 and 6) that named
`processing/scans/mod_scan_batchelor_spectrum.m` by path to point at the new location (line numbers
unchanged - pure move, no content change).

### 2026-09-08 - Phase B: built the epsilon module, wired chi_mle in (branch `epsilon_processing`)

Followed directly from Phase A (below) on the same branch: with profile extraction decoupled from
L1→L2 conversion, the next blocker for the July 2026 DeepSolo deployment's L1→L2 step was that
nothing in this repo computes epsilon - `mod_scan_calc_chi_mle.m` has been fully implemented since
`chi_processing` but was never wired in for exactly that reason (Section 6.4's own table, and the
2026-09-02 session log entry below, both flagged this). Ported the full legacy chain from
`MOD_fish_lib`'s `EPSILOMETER/EPSILON/mod_efe_scan_epsilon.m`/`eps1_mmp.m`/`epsilon2_correct.m`/
`nasmyth.m`/`mod_efe_scan_coherence.m`, following the same 8-step pipeline order already
established for chi and confirmed with Nicole before implementation: scan tiling → per-channel
spectra (already built) → filters/cutoff → wavenumber conversion → coherence → direct-integration
chi/epsilon → MLE chi/epsilon → figure of merit.

**New files**: `mod_scan_shear_transfer_function.m` (Oakey 1982 probe response, mirrors
`mod_scan_fpo7_transfer_function.m`), `mod_scan_nasmyth_spectrum.m` (mirrors
`mod_scan_batchelor_spectrum.m`), `mod_scan_shear_volts_to_shear_spectrum.m` (mirrors
`mod_scan_fpo7_volts_to_Tg_spectrum.m` - no noise-floor-cutoff search exists for shear the way
FPO7 has one; contamination is instead capped directly as an integration bound, see below),
`mod_scan_shear_accel_coherence.m` (vs. accelerometer channel `a3`, hardcoded per legacy's own
choice), `mod_scan_calc_epsilon_obs.m` (the `eps1_mmp.m`/`epsilon2_correct.m` port, computing both
`epsilon_obs` and `epsilon_obs_co` from the raw and coherence-cleaned spectra), `mod_scan_calc_epsilon_mle.m`
(Nasmyth-fit MLE, always against the cleaned spectrum, seeded by `epsilon_obs_co`),
`mod_scan_calc_fom.m` (generic figure of merit, ported from the inline formula in
`mod_efe_scan_epsilon.m`), `processing/L2/modProcess_L2_calc_epsilon.m` (per-channel orchestrator,
the function this section's table already named as the target), and `toolbox/mod_scan_mle_grid_search.m`
(new - see refactor note below).

**Refactored `mod_scan_calc_chi_mle.m`**: its local `mle_search_chi` grid-search zoom (4-pass,
200-point log-spaced, widen-on-edge-hit) was extracted into the new shared
`toolbox/mod_scan_mle_grid_search.m`, parameterized by a model-function handle, once
`mod_scan_calc_epsilon_mle.m` needed the identical machinery fitting a different model
(`mod_scan_nasmyth_spectrum.m`, epsilon searched directly, vs. `mod_scan_batchelor_spectrum.m`,
chi searched as a pure amplitude) - so the two MLE searches can't silently drift apart. Verified
behavior-preserving: a synthetic-data regression check (known chi, noiseless Batchelor spectrum)
recovered the same chi to numerical precision after the refactor as the design intends before it.

**Wired into `mod_L2_tile_scans.m`**: epsilon is computed for every shear channel with a resolved
`metadata.AFE.(ch).cal`, gated on the same `have_ctd_ts` condition chi_obs uses (kinematic
viscosity `nu`, `toolbox/seawater/sw_visc.m`, needs real CTD T/S the same way thermal diffusivity
does - so DeepSolo's P-only external CTD still can't get epsilon *or* chi, a hardware limit no
amount of code can work around). `chi_mle` is then called per fpo7 channel for every scan with a
finite epsilon available - the mean, omitting NaN, across this deployment's shear channels of
whichever variant `metadata.PROCESS.EPSILON.epsilon_final_source` selects. **This is a deliberate
per-scan simplification**, not MOD_fish_lib's full profile-level ratio-based channel selection
(comparing s1 vs. s2 across a whole profile, gated by a figure-of-merit threshold) - that needs
`modProcess_L2_qc.m` (Section 6.4, still "Not started"), which is genuinely profile-level (RMS/STD
of accelerometer power aggregated across a whole profile's scans) and needs pitch/roll (vnav data,
outside `mod_L2_tile_scans.m`'s current epsi/ctd-only scope) for the fuller legacy QC array -
deliberately not half-built this round, flagged in `docs/workflow/L2_calc_eps.md`'s "Known
limitations" instead.

**Registry**: 7 new `MODsetup_metadata_field_registry.m` entries under a new `epsilon` yaml
section (`epsilon_kmin_obs`, `contam_freq_hz_shear`, `oakey_lc_m`, `coherence_fmin_hz`,
`coherence_fmax_hz`, `mle_start_search`, `mle_end_search` - registry `name`s deliberately distinct
from chi's identically-shaped `kmin_obs`/`contam_freq_hz` entries, since `MODsetup_validate_metadata.m`
looks entries up by that flat `name`, not by `yaml_key` - a real bug caught and fixed during this
session before it shipped: the scan-level functions' `validate_metadata` calls initially requested
the plain `'kmin_obs'`/`'contam_freq_hz'` names, which would have silently validated *chi's*
fields and left epsilon's own never validated). `epsilon_final_source`'s registered default
changed from the legacy `'epsilon_co'` to `'epsilon_mle'`, adopting Jen's 2026-09-02 ASTRAL finding
now that a real epsilon module exists to act on it.

**Verified** via a MATLAB sandbox (deleted when done): `mod_scan_nasmyth_spectrum.m`'s shape/
positivity; `toolbox/mod_scan_mle_grid_search.m` recovering a known epsilon exactly from a
noiseless synthetic Nasmyth spectrum and within a factor of ~2 from one chi-squared-noised
(dof≈5.7) realization, and recovering a known chi exactly from a noiseless synthetic Batchelor
spectrum (the chi_mle refactor regression check); `mod_scan_shear_transfer_function.m`'s monotonic
rolloff; `mod_scan_calc_epsilon_obs.m` recovering a known epsilon to ~4% on a noiseless synthetic
spectrum; `mod_scan_calc_epsilon_mle.m` recovering it near-exactly when seeded from that estimate;
`mod_scan_calc_fom.m` scoring a deliberately-wrong model worse than a correct one; and the full
`modProcess_L2_calc_epsilon.m`/`mod_L2_tile_scans.m` chain (chi_obs → epsilon → chi_mle wiring
included) running end to end on synthetic time-domain data with no errors and the documented
"bare empty struct when no channel qualifies" convention preserved. `checkcode` clean on every
new/touched file. **Not yet run against a real deployment's shear data** - see
`docs/workflow/L2_calc_eps.md`'s "Known limitations" for this and every other open item
(profile-level QC/selection not built, coherence-band values still placeholders, `calib_volt`/
`calib_vel` diagnostic not ported).

**Code review pass (same day)** caught two real bugs before this landed: `metadata.PROCESS.EPSILON.epsilon_final_source`
was read directly in `mod_L2_tile_scans.m` without ever being validated (no call site anywhere
requested it via `MODsetup_validate_metadata.m`), and `MODsetup_read_yaml.m` had no `epsilon:`
yaml-section reader at all (only `chi:`) - together these meant every one of the 8 new
`PROCESS.EPSILON.*` fields could never actually be supplied through `setup.yml`, and the very
first deployment with a real onboard CTD and a resolved shear calibration would have hit a raw
"Reference to non-existent field" crash instead of the intended validate-and-prompt flow. Both
fixed: `MODsetup_read_yaml.m` gained an `epsilon:` block mirroring `chi:` exactly, and
`mod_L2_tile_scans.m` now validates `epsilon_final_source` once, right after `epsilon_channels` is
determined non-empty, before the per-scan loop reads it. Also fixed: `MODprocess_all_L1_to_L2_profiles.m`'s
conversion-phase staleness check used `>=`, which could silently skip reconverting a profile whose
raw extraction and stale L2 output land on the same filesystem-mtime tick (a coarse-mtime-filesystem
edge case, more reachable now that extraction and conversion are two separate phases with their own
mtimes to compare) - changed to `>`, erring toward an extra reprocess rather than a silently stale
result. The chi_mle-recomputes-fpo7-deconvolution-twice finding (see `docs/workflow/L2_calc_eps.md`'s
"Known limitations") was deliberately left unfixed - a real efficiency cost, not a correctness bug,
and properly fixing it means changing `mod_scan_calc_chi_mle.m`'s own contract, which deserves a
dedicated pass rather than a rushed edit here.

### 2026-09-08 - Phase A: decoupled profile extraction from L1→L2 conversion (branch `epsilon_processing`)

Prompted by starting work on the July 2026 DeepSolo deployment's L1→L2 step (`deepsolo` repo): `MODprocess_single_L1_to_L2_profile.m` called `modProcess_extract_profile.m` itself, doing its own file I/O and requiring a `TimeIndex` argument - it couldn't accept "any type of L1 file, whether or not it's already broken into a profile" the way `MODprocess_single_L1_to_L2.m`'s realtime mode already could (that one is just `mod_L2_tile_scans(data.epsi, data.ctd, metadata, PressureTimeseries)`, no extraction). Needed to fix this before building the epsilon module (Section 6.4), which reuses the same conversion entry point regardless of how its input data was assembled.

**Extraction is now its own explicit, disk-persisted phase:**
- New `metadata.paths.profiles_raw` (`data_root/profiles_raw`, `MODsetup_read_yaml.m`) - a sibling of `metadata.paths.profiles`/`.L2`, so the two pipeline stages never collide on the same `Profile####.mat` filename.
- New `MODprocess_all_extract_profiles.m` (`processing/L1/`) - near-identical structure to the pre-refactor `MODprocess_all_L1_to_L2_profiles.m` (same skip-if-up-to-date logic keyed off `time_index.mat`, same retry-on-`yamlUpdated` loop), but calls `modProcess_extract_profile.m` only, saving the stitched-but-not-yet-converted raw record to `profiles_raw/Profile####.mat`.
- `MODprocess_single_L1_to_L2_profile.m`'s signature changed from `(profile, TimeIndex, metadata)` to `(profile_data, metadata)` - no file I/O left in this function at all, takes an already-extracted `profile_data` struct directly (whatever produced it).
- `MODprocess_all_L1_to_L2_profiles.m` rewritten to call `MODprocess_all_extract_profiles.m` first, then loop loading each `profiles_raw/Profile####.mat` and converting it - staleness for the conversion phase is now checked one link at a time (converted output's mtime vs. its own raw-extraction input's mtime) rather than reaching back to L1 file mtimes directly; a profile whose raw extraction was just redone (e.g. because it touched the newest L1 file) gets reconverted automatically as a result, with no separate "touches newest" case needed at this phase. Signature gained a `profiles_raw_dir` argument between `profiles_dir` and `reprocess_all`.

No other call site of `modProcess_extract_profile.m` existed anywhere in the repo (confirmed by grep) - this was a clean, single-call-site refactor. Updated `docs/workflow/profile_detection.md` (two-phase pipeline description, `Profile####.mat` output section split into `profiles_raw`/`profiles`) and `docs/workflow/pipeline_overview.md` (postprocess diagram/table). Section 6.3's table below still reads "Done" for the pre-refactor shape of these functions - status unchanged, since the functions still do the same job, just split across two files now.

### 2026-09-02 — Reviewed Jen's ASTRAL reprocess fork against `MOD_fish_lib` master; registered epsilon/QC/gridding parameters (branch `main`)

Jen sent a reprocessed ASTRAL microstructure dataset built on a fork of `MOD_fish_lib`'s legacy chain (`Epsi_reprocess_astral_new_jen.m`, building on Ankitha's earlier wrapper, plus her own edits to `get_scan_spectra.m`, `mod_efe_scan_epsilon.m`, and `mod_epsilometer_calc_turbulence_v2.m`), asking what should come into `MOD_fish_processing`. Her described changes: found the post-cruise calibration file for one of the shear probes used in deployments 2/3; switched `epsilon_final` from `epsilon_co` to `epsilon_mle` (both for chi's initial epsilon estimate and the profile-level final pick); fixed the ratio-based QC pick for that value (`get_scan_spectra.m` L239); moved `kmin` to 5 cpm for both the chi and epsilon MLE fits (`mod_efe_scan_chi.m` top-of-file for chi, `get_epsilon_mle` L261 for epsilon); replaced the rms+2*std acceleration QC in `mod_epsilometer_calc_turbulence_v2.m` L469 with a simpler fixed threshold after finding the rms_std version throwing out good ASTRAL data; hand-picked and NaN'd isolated bad epsilon peaks profile-by-profile (`Epsi_reprocess_astral_new_jen.m` from L88); switched gridding from 1 m to 0.5 m, enabled by the deployment's smaller nfft windows.

Diffed her four files against `origin/master` of `MOD_fish_lib` to isolate what actually changed (her wrapper has no `master` equivalent to diff against - it's her own script, not tracked upstream). Confirmed all of the above in the diff, plus two things she didn't mention that look like real bugs, flagged for follow-up with her rather than fixed here (there's no code in this repo yet to fix them in): her `eps1_mmp` call requests 4 outputs (`[epsilon,kmin(1),kc(1),method(1)]`) where `master`'s `eps1_mmp.m` returns 5 (`epsilon,epsilon_non_adjust,kmin,kc,method`) - safe only if her local `eps1_mmp.m` was also trimmed to 4 outputs, which she didn't send and we can't confirm; and in her new fixed-threshold QC, `qc.a2` and `qc.a3` both compare against `Profile.sumPa.a1` instead of `.a2`/`.a3` (copy-paste, `mod_epsilometer_calc_turbulence_v2.m` ~L486-488). A handful of other diffs looked like artifacts of her local setup rather than deliberate fixes (a `Meta_Data.paths.calibrations.fpo7`→`.calibration` path change matching her wrapper's flat calibration path, `Profile%04d`→`%03d` matching her 3-digit ASTRAL filenames, `omitmissing`→`omitnan` for older-MATLAB compatibility) - not proposed for adoption here.

Checked what exists in `MOD_fish_processing` to receive any of this: **nothing epsilon-related does yet.** `modProcess_L2_calc_epsilon.m`, `modProcess_L2_qc.m`, and `modProcess_L3_grid_profiles.m` are all still "Not started" (Section 6.4/6.5) - only chi is built (`mod_scan_calc_chi_obs.m`/`mod_scan_calc_chi_mle.m`, wired via `mod_L2_tile_scans.m`). Chi's own `kmin` is already a live, registered parameter (`PROCESS.CHI.kmin_obs`, default 3) - so Jen's chi-side `kmin=5` needs no code change at all, just a `setup.yml` value once ASTRAL is reprocessed here. Everything else (`epsilon_final_source`, epsilon's `kmin`, the QC method selector, gridding `dz`) would need real modules built first - Nicole's call: don't build those modules this round, just register the parameters they'll need in `setup/MODsetup_metadata_field_registry.m` now, so this review isn't lost before the modules exist to consume it.

**Registered 6 new entries** (all currently unconsumed - no `MODsetup_validate_metadata.m` call site anywhere yet, same situation the registry file's header already documents for `Fs_epsi`/`nfft`/`dof`): `epsilon` section - `epsilon_final_source` (`'epsilon_co'` | `'epsilon_mle'`, default `'epsilon_co'` - the legacy behavior, not Jen's finding, since nothing here has validated her choice yet), `kmin_mle` (default 5, Jen's value - legacy computed this dynamically as `SpecObs.kli(1)` rather than a fixed constant, so there's no real historical default to fall back to), `qc_accel_method` (`'rms_std'` | `'threshold'`, default `'rms_std'` matching legacy), `qc_accel_threshold` (default `1e-5`, Jen's ASTRAL value), `qc_accel_nstd` (default 2, the legacy hardcoded multiplier, now tunable). `grid` section - `dz_m` (default 1, legacy; Jen used 0.5 for ASTRAL).

**Two things not registered, left as open questions:** Jen's per-deployment manual bad-profile/depth-range exclusion table (`profbadz` in her wrapper - hand-picked spikes the automatic QC missed) has no equivalent or precedent anywhere in this repo; the registry only holds scalars, and no list/table-shaped `setup.yml` value has ever been used here, so this needs its own design decision once gridding/QC actually get built, not resolved now. Also noticed several unrelated hardcoded numeric literals while reading around this (`mod_L1_detect_profiling_direction.m`'s `cheby2(3,20,...)` filter order/ripple, `MODprocess_L1_apply_fpo7_calibration.m`'s `MIN_FIT_POINTS=30`, `MODprocess_single_L0_to_L1.m`'s accelerometer `acc_offset`/`acc_factor`, `mod_scan_batchelor_spectrum.m`'s Batchelor constant `q=3.7`, `mod_scan_panchev_spectrum.m`'s `a`/`delta`, `mod_scan_calc_chi_mle.m`'s MLE grid-search tuning `n_grid`/`n_pass`/`max_widen`) - not registered, since most are numerical-method/physical constants rather than genuinely deployment-tunable values. One is worth calling out as an actual bug, unrelated to Jen's changes: `SpectraExplorerApp.m:1041` hardcodes its own `SN_min = 3` instead of reading `metadata.PROCESS.CHI.sn_min` - a real divergence risk if a deployment ever overrides `sn_min`.

### 2026-09-02 — Audited metadata field access for missing validation; added a shared platform-instrument geometry lookup (branch `main`)

Nicole was reading `MODprocess_all_L0_to_L1.m` and noticed a guarded pattern (`if exist(metadata.paths.ctd, 'dir') ... else ... proceeding without CTD`) that's fine as-is - optional metadata gets an `if` and a graceful skip. Asked for an audit of the opposite case: code that reads a metadata field unconditionally, would error if it's missing, and has no `MODsetup_validate_metadata` call ensuring it's there first.

Three parallel research passes covered every file under `processing/` (top-level orchestration plus `L1/`/`L2/`/`scans/`), `setup/`, and `visualization/matlab/`. Most of what they flagged turned out to be false alarms once `MODsetup_read_yaml.m`'s own contract is accounted for: `metadata.paths.*`, `.vehicle_name`, `.PROCESS.channels`, `.PROCESS.latitude`, `.fish_flag`, and `.manifest.has_*` are unconditionally set by `MODsetup_read_yaml.m` itself, every time, for every deployment - none of them sit behind an `isfield(yml, ...)` guard, so they can never be absent from a metadata struct that actually came from that function. Likewise every `metadata.AFE.(ch).*` access in the repo is reached only by iterating `metadata.PROCESS.channels`, which is `{}` (loop body never runs) for a CTD-only vehicle, so `metadata.AFE` is never dereferenced when it wouldn't exist.

What was left: **five call sites** reading a field already in `MODsetup_metadata_field_registry.m` (`Fs_epsi`/`nfft`/`dof`/`PROFILES.lowpass_factor`/`.ctd_gap_factor`/`.buffer_bins` - the registry's header already documents these as "deferred") without validating it first at the point it's actually read - `mod_scan_get_spectra.m` (validated only `hamming_window_length_nfft`, read `nfft`/`Fs_epsi` unconditionally after), `mod_L2_tile_scans.m` (no validate call at all, read `nfft`/`dof`/`Fs_epsi`), `modProcess_extract_profile.m` (validated only `epsi_gap_factor`, read `Fs_epsi` unconditionally later), `MODsetup_define_filters.m` (no validate call at all, read `nfft`/`Fs_epsi`), and `mod_L1_detect_profiling_direction.m` (self-defaulted `lowpass_factor`/`ctd_gap_factor`/`buffer_bins` to hardcoded 3/5/1 via an `isfield` block instead of validating, unlike `modProcess_detect_profiles.m`'s real validate call for the same kind of fields). All five now call `MODsetup_validate_metadata` with the missing names added to the existing (or a new) call - no registry changes needed, since all five fields were already registered. `mod_L1_detect_profiling_direction.m`'s fix is a real behavior change: a deployment missing these fields used to get a silent hardcoded default, now it gets prompted (and can save a real value to setup.yml), same as everywhere else.

**One field family had no registry entry at all and no guard**: `metadata.GEOMETRY.alt_angle_deg`/`.alt_dist_from_crashguard_ft`/`.alt_probe_dist_from_crashguard_in`, read in `MODprocess_single_L0_to_L1.m`'s `calibrate_altimeter_hab`, called whenever raw altimeter/ISAP distance data is present - a data-presence check, not a metadata-presence check. `MODsetup_read_yaml.m` only ever set `metadata.GEOMETRY` when the deployment's own setup.yml had a matching `altimeter.fctd`/`altimeter.epsi` block, so a deployment logging alt/isap data without that block would hit a bare "reference to non-existent field" error. This one didn't fit the registry mechanically: `MODsetup_write_yaml_value.m` only writes a flat 2-level `section: \n  key: value` shape, but the real setup.yml altimeter block is 3-level (`altimeter: \n  fctd: \n    angle_deg: ...`), so registering it would let `MODsetup_validate_metadata` prompt correctly but silently write any saved answer to the wrong location on save.

Nicole's fix instead: altimeter geometry is a fixed mechanical fact about a *platform* (which vehicle, which fish_flag), not something to type into every deployment's setup.yml or prompt an operator for - same shape as the shear-probe SN calibration lookup (deployment declares an SN, the actual value is looked up from a shared file). Checked the three real setup.yml files already in production (`epsi_mako_w_fluor`, `epsi_mako/blt2021_0715`, `epsi_deepsolo`, all under `~/Dropbox/SIO/projects/mod_fish_lib/data_for_reorg/`) to ground the design - two of them already carry a hand-typed `altimeter:` block with real values (FCTD, no vehicle_name: 45°/4 ft/0 in; EPSI/Mako: 10°/5 ft/2.02 in), confirming `(fish_flag, vehicle_name)` is the right key, since the two known values differ by vehicle, not just fish_flag. Added a new repo-committed lookup table, `setup/platform_instrument_geometry.yml`, named broadly on purpose - Nicole wants it to grow beyond altimeter mounting to cover probe-to-CTD, fluorometer-to-CTD, and other fixed vertical offsets between instruments on a platform as those get measured. For now only its `altimeter:` block is populated: `FCTD` goes straight to the geometry fields (every FCTD unit shares one mount, no vehicle_name needed), `EPSI` nests by vehicle_name (`Mako` populated; DeepSolo/Wirewalker/etc. to be added as measured). `MODsetup_read_yaml.m` checks the deployment's own `altimeter:` block first (so one odd unit can still override), then falls back to this shared table via a new `lookup_altimeter_geometry` subfunction; neither source having an entry leaves `metadata.GEOMETRY` unset, same "never silently fill a value" rule as the rest of the function. `calibrate_altimeter_hab` got a fail-fast existence guard as the final safety net, naming both lookup paths in the error message.

**Open follow-up, logged but not built this round**: every instrument on the vehicle sits at a different fixed vertical offset (altimeter, fpo7/shear probes, CTD, fluorometer, ...), so each one's timestamp corresponds to a different actual depth than the CTD's timestamp for the "same" physical water parcel as the vehicle profiles past it. Correcting for this needs the vehicle's fall/rise speed at each moment (already computed as `ctd.dzdt`) combined with each sensor's fixed offset distance from the CTD (to be added to `platform_instrument_geometry.yml` under new blocks once those distances are measured) to shift every sensor's time axis onto a common one before combining records. Needs a new function, or logic folded into the relevant existing functions - not designed or built here.

### 2026-09-01 - FP07 modeled noise floor: removed the inherited `amp_coefs.ff` fudge factor (branch `modvis_spectra_batchelor_mle`)

Wiring the modeled noise floor into `MODvis_spectra.m`'s new noise-floor checkboxes prompted a closer look at `mod_scan_fpo7_noise_f.m`'s NOTES, which had flagged `amp_coefs.ff` (default 200, multiplied onto the amplifier-noise term only) as "unresolved... may not represent a real physical effect for our (non-differentiated) channel at all" when the function was first ported (2026-08-25/26 entry below). Nicole: since Johnson noise and amplifier noise are both theoretical (Amphenol B9 resistance curve, ADA4805 datasheet specs), there's no room for an unexplained scale factor - remove it.

The open question that entry raised is resolved, not new: `amp_coefs.ff` stood in for the old model's "Tdiff" analog differentiator/pre-emphasis circuit, and this repo's own `docs/workflow/L2_calc_chi.md`/this file's own NOTES already independently confirmed (via `MOD_fish_lib`'s actual `blt2021_0715` process config) that no deployment this repo processes has ever used Tdiff - the bench noise calibration file is literally named `FPO7_notdiffnoise.mat` for that reason. So the factor was never modeling anything physically real on our channel, regardless of whether 200 was the "right" value. Removed entirely (not defaulted to 1) - `noise_f = noise_johnson + noise_amp` now. Confirmed via repo-wide grep this field is referenced nowhere else (`mod_scan_fpo7_modeled_noise_f.m`/`MODvis_spectra.m` both just pass `amp_coefs` through or omit it). Not wired into `mod_scan_fpo7_cutoff.m`/production chi either way, so this only changes what the modeled-noise-floor checkbox draws, not any production chi output.

### 2026-09-01 - Nicole's notes

One problem that keeps coming up over and over is aligning the time series between different sensors. The shear, FPO7, and microconductivity probes sit out ahead of the Seabird CTD. We really need our first step to be perfectly aligning the data - t1 and T is a good way to compare.

### 2026-08-28 — Profile detection, cross-file profile extraction, shared L2 windowing; `meta/` filenames renamed to snake_case (branch `chi_processing`)

Prompted by a design question about what happens when a profile spans two raw files - does spectral windowing see an artificial edge effect at the seam? Investigated both reference implementations first: `MOD_fish_lib`'s `epsiProcess_crop_timeseries.m`/`epsiProcess_merge_mat_files.m` solves this by concatenating raw epsi/ctd arrays across the file boundary *before* windowing, with **no gap detection at all** - it just trusts the raw sample clock is continuous across a file split. Rockland's ODAS library (`~/Library/CloudStorage/Dropbox/SIO/_instrument_software/rockland/odas/`) sidesteps the problem entirely - the stock library assumes one profile always lives inside one raw `.p` file, ships no cross-file concatenation. Neither was directly reusable; built a third approach with explicit gap detection.

**Section 6.3 built out, PLAN.md Section 6.3 table updated to match:**
- `MODprocess_L1_make_time_index.m` (new, `processing/`) - per-L1-file `epsi.dnum` start/end, saved `meta/time_index.mat`, wired into `MODprocess_all_L0_to_L1.m` next to the existing pressure-timeseries build.
- `modProcess_detect_profiles.m` (new, `processing/L1/`) - full profile-picker (speed-limit hysteresis, min-length filter, up-to-10-pass same-direction merge), re-derived from `epsiProcess_get_profiles_from_PressureTimeseries.m` but built on `mod_L1_detect_profiling_direction.m`'s already-computed `dPdt_smoothed`, with a new gap-boundary safety pass (re-derives the same 3-line gap split that function's STEP 1 computes, so neither a run nor a merge can cross a real timestamp gap - legacy has no gaps to worry about, so this is genuinely new logic, not a port).
- `modProcess_extract_profile.m` (new, `processing/L1/`) - given one profile, finds and stitches its raw epsi/ctd record across however many L1 files it spans, with **real gap detection**: any `dt > epsi_gap_factor * (1/Fs_epsi)` across the *whole* stitched record (not just at file seams - also catches a real mid-file discontinuity, e.g. Section 9's known block-drop artifact) increments a running `segment_id`. A profile is never split or dropped over an internal gap - `mod_L2_tile_scans.m` is what actually acts on `segment_id`, skipping only the FFT window(s) that would straddle it.
- `mod_L2_tile_scans.m` (new, `processing/L2/`) - the `N_epsi`/`scan_step`/pwelch tiling loop factored out of `MODprocess_single_L1_to_L2.m` so both the realtime per-file path and the new profile-cut path share one windowing implementation (not one *result* - each still computes its own spectra independently, a deliberate simplicity-over-storage-optimization call, see below). `PressureTimeseries` direction-gating is now optional (profile-cut mode omits it, since a detected profile is already direction-pure); `epsi.segment_id`, when present, gates window validity the same way. `MODprocess_single_L1_to_L2.m` is now a thin wrapper around it.
- `MODprocess_single_L1_to_L2_profile.m` / `MODprocess_all_L1_to_L2_profiles.m` (new, `processing/`) - per-profile orchestration, parallel to the existing per-file realtime pair, saving `Profile####.mat` into `metadata.paths.L2` (new field, added to `MODsetup_read_yaml.m`).

**Design decisions, confirmed with Nicole before implementation:**
- Keep both modes side by side ("hybrid") rather than replacing realtime mode - it stays cheap/streaming-friendly for a future per-file spectra QC viewer (a `MODvis_spectra`-style tool, not built yet), while profile-cut mode is the final science-quality path.
- Accept full duplication of computed spectra between the two modes for now - no scan-reuse/dedup optimization (e.g. an absolute-time-anchored window grid was considered and rejected as unnecessary complexity for now).
- Two new, deliberately separate `setup.yml` gap-threshold fields rather than one shared value: `metadata.PROFILES.ctd_gap_factor` (renamed from `gap_factor`, for the sparse/irregular pressure record) and `metadata.PROCESS.epsi_gap_factor` (new, for the uniformly-clocked epsi record) - different timebases, different consequences (a misclassified direction sample vs. a dropped FFT window), so one number isn't right for both. `epsi_gap_factor`'s suggested default (3) is unverified against real data - flagged in `docs/workflow/profile_detection.md`.
- `meta/` filenames renamed to snake_case while touching these files anyway: `PressureTimeseries.mat`→`pressure_time_series.mat`, `TwistTimeseries.mat`→`twist_time_series.mat`, `FilenamePadLog.csv`→`filename_pad_log.csv`, `SpoolSwapLog.csv`→`spool_swap_log.csv` (new `time_index.mat` named this from creation). Every code/doc/PLAN.md reference updated except dated Session Log entries below this one, kept as an accurate record of what was true at the time. `spool_swap_log.csv` (the one operator-edited, not pipeline-regenerated, file in the list) falls back to the legacy name with a warning if the new one isn't found, so an in-progress cruise's hand-created file isn't silently ignored.

**Tested end-to-end** against a sandbox copy of `epsi_mako/blt2021_0715` (`meta/`, `calibrations/`, `L1/` - 151 files, ~932 MB - never touched in place, per standing practice): `modProcess_detect_profiles.m` found 31 real profiles; profile #31 happened to span **8 L1 files** (970,950 stitched epsi samples, `n_segments=1` - correctly found no real gap at any of the 7 file-rotation boundaries inside it, max real `dt` 0.004003 s vs. nominal 0.003125 s at `Fs_epsi=320`, well under the `epsi_gap_factor=3` threshold). Manually reconstructed the scan window nearest that profile's seam by hand-slicing `modProcess_extract_profile.m`'s stitched output and calling `mod_scan_get_spectra.m` directly - matched `mod_L2_tile_scans.m`'s own output for that scan exactly, confirming the original design question: no edge effect at an ordinary file boundary once windowing happens on the stitched record. Regression-tested the `mod_L2_tile_scans.m` refactor by running both the pre-refactor `MODprocess_single_L1_to_L2.m` (from `git show HEAD:...`) and the new thin-wrapper version on the same real L1 file (109 scans) - `isequaln`-identical. A separate synthetic test (in-memory, no real deployment needed) verified the gap mechanism itself, since this real deployment happened not to contain one: a 5 s synthetic gap correctly split `segment_id`, and every scan window that would have straddled it was excluded while unaffected windows on both sides were kept (exact count match against an independently-derived expected count). `checkcode` clean on every new file; pre-existing `datestr`/`now`/`datenum` deprecation notices in touched orchestrator files are pre-existing codebase style, not new.

**Not yet done**: no diagnostic plot run against this profile set (the "Diagnostic" pattern `docs/workflow/L1_to_L2_conversion.md` uses); `docs/workflow/profile_detection.md` written but its "Known limitations" section should be revisited now that real-data testing has actually happened.

**Same-day design review, three gaps found and fixed:** Nicole asked whether the setup/metadata truly gates behavior end to end - specifically, whether spectra processing only ever runs for epsi platforms, whether epsi structures leak into L2/profile output, where profiles are saved, and whether CTD (saved both directions) and epsi (usually one direction) are actually decoupled. Checked the code directly rather than assuming: raw epsi never leaks into L2/profile output (already correct), but three real gaps were found and fixed -
- `modProcess_detect_profiles.m` was filtering its own output by `profile_dir`, so only one direction's casts ever became `Profile####.mat` at all. Changed to always return every cast, both directions; `profile_dir` now only gates, downstream in `MODprocess_single_L1_to_L2_profile.m`, whether a given profile gets epsi spectra computed - every profile always gets its own CTD record (`L2data.ctd`) regardless.
- `MODsetup_read_yaml.m` read `instrument_manifest.afe` unconditionally - a CTD-only deployment (no AFE/epsi board) would crash there, contradicting its own docstring's "missing instrument = not on the vehicle, nothing errors" claim. Added `metadata.manifest.has_epsi` (true only when `instrument_manifest.afe` is present with ≥1 channel); the AFE-manifest block and `MODprocess_all_L1_to_L2.m` (the realtime spectra path) are now both gated on it - the latter skips cleanly with a message instead of crashing or writing empty `.mat` files. `MODprocess_L1_make_time_index.m` and `modProcess_extract_profile.m` were extended to fall back to `ctd.dnum` when a file has no epsi record, so a genuinely CTD-only deployment's files still get indexed/extracted (previously would have silently produced empty `time_index.mat`).
- `Profile####.mat` was saving into `metadata.paths.L2` - the same directory as the realtime path's per-file output. Added `metadata.paths.profiles` (`data_root/profiles`, sibling of `paths.L2`) and made it `MODprocess_all_L1_to_L2_profiles.m`'s default output directory.

Verified against the same `blt2021_0715` sandbox: both directions detected (31 down/26 up), CTD populated on both a down and an up profile, spectra computed only for the down profile (default `profile_dir: down`) and for both under `profile_dir: both`, no raw `epsi` struct in output, `MODsetup_read_yaml.m` no longer crashes on a synthetic CTD-only `setup.yml`, `MODprocess_all_L1_to_L2.m` skips cleanly for `has_epsi=false`. `checkcode` clean on all 8 touched/new files (only pre-existing `datestr`/`now` notices).

**Bug discovered during this same testing pass** (pre-existing, not introduced today - see `docs/workflow/profile_detection.md`'s "Known limitations"): `MODprocess_L1_make_time_index.m` assigns each L1 file's time range from a plain `min`/`max` of its dnum array, with no outlier rejection. One real file in `blt2021_0715` (`EPSI_B_PC2_21_07_17_203041.mat`) has a single corrupted leading `epsi.dnum` sample (≈`datenum(1970,1,1)`), which corrupts that file's sort position in `time_index.mat` and breaks `modProcess_extract_profile.m`'s file-range lookup for **55 of the 57 detected profiles** in this deployment (confirmed by direct test - only the two profiles nearest the true end of the deployment escape it). Not fixed yet - needs a design decision on how to make a file's assigned time range robust to a single bad clock sample before the profile-cut path can be trusted on real data; flagged for Nicole rather than silently patched with an arbitrary threshold.

**Same-day follow-up: legacy FastCTD despiking/microconductivity comparison, `mod_scan_get_spectra.m` generalized for non-standard AFE channels.** Nicole asked how legacy FastCTD's salinity despiking and microconductivity processing compared to this repo's `Profile.ctd`, and whether Epsi CTD data had ever been despiked. Research (via a subagent reading `MOD_fish_lib/FastCTD_MATLAB` and `MOD_fish_lib/EPSILOMETER` directly) found: legacy FastCTD despiking (`FastCTD_GridData.m:255-271`) is a post-gridding low-pass filter on depth-binned salinity, not point-outlier rejection, and has no home in this repo until L3 gridding exists (not started); Epsi CTD data was never despiked, in legacy or here - confirmed, not a regression; legacy Epsi profile numbering and gridding (`epsiProcess_makeNewProfiles.m`, `epsiProcess_gridProfiles.m`) already matched this session's earlier sequential `Profile####.mat`/`.direction`-field scheme, confirming no change was needed there. Nicole's decisions: defer despiking; scaffold microconductivity/fluorometer channel support now, clarifying these are just alternate sensors wired into an existing AFE channel slot (e.g. `c1`/`f1` in place of the usual `s1`/`s2`), not a new raw-ingestion path - the same `.modraw`/SOM/EFE stream every channel already goes through.

Tracing the channel-type handling found the pipeline was *almost* fully general already: `instrument_manifest.afe`'s `name`/`type` are free-form strings with no enum validation, `MODprocess_single_L0_to_L1.m`'s `convert_efe_channels` already defaults any non-`acc` channel to volts, and `probe_cal_subdir()`/`MODprocess_L1_apply_fpo7_calibration.m`/`mod_L2_tile_scans.m`'s chi_obs selection already only special-case `shear`/`fpo7` respectively - a microconductivity/fluorometer channel already correctly gets no automatic calibration or chi_obs. The one real gap: `mod_scan_get_spectra.m`'s channel-type switch only computed a spectrum for `case 'acc'` and `case {'shear','fpo7'}`, silently dropping any other type. Fixed to match `convert_efe_channels`'s convention (`case 'acc'` stays `_g`, `otherwise` defaults to `_volt`) - purely additive, every type in real use today (`acc`/`shear`/`fpo7`) unaffected. Verified in the `blt2021_0715` sandbox: relabeled a real shear channel (`s2`, SN 306) as `{name: c1, type: microconductivity}` via a real edited `setup.yml` read through `MODsetup_read_yaml.m` - no error, no calibration-file lookup attempted, `mod_scan_get_spectra.m` now produces `c1_volt_f` matching a hand-computed `pwelch` exactly; `chi_obs` channel selection correctly still excludes it; original shear/fpo7/acc channels regression-checked unaffected. `checkcode` clean. The microconductivity chi/turbulence algorithm itself remains undesigned and out of scope - Nicole: "processed similarly to chi, but a little different - I haven't dived into it yet."

**Same-day follow-up: formalized the two processing modes.** Nicole clarified the intended top-level shape: a realtime mode (`modraw → L0 → L1 → L2`, per-file, for at-sea visualization) and a postprocess mode (`modraw → L1 → profiles → grid`, for the final science-quality product). This was already implicit in what Section 6.2-6.5 describe (the per-file L2 path and the per-profile path built earlier today both already exist and share `mod_L2_tile_scans.m`) but had never been named or documented as the two intended entry points - added as a new subsection in Section 4.

**Same-day follow-up: L1 disk duplication (`_count` fields dropped) and realtime profile-assembly direction.** Debugging a `MODvis_spectra` report ("deepsolo L2 spectra not showing") led to a broader question about disk duplication across L0/L1/L2. Measured a real leg (`epsi_deepsolo/26_0720_ljc`): L0 1.1G, L1 2.1G, L2 310M. Traced the ~2x L0→L1 growth to `convert_efe_channels` (`processing/MODprocess_single_L0_to_L1.m`) copying raw ADC counts into L1 under a renamed field (`epsi.t1_count` etc.) *in addition to* the converted `_volt`/`_g` fields - confirmed nothing downstream ever read the `_count` copy (no calibration, no clipping/saturation diagnostic exists anywhere in the repo, twist/vnav processing is fully independent of `epsi`) and confirmed via `git log` this was itself a recent addition (`d29ec35`), so nothing else depended on the old shape being stable either. Nicole: drop `_count` from L1 - implemented on branch `l1_drop_counts`, verified with a synthetic sandbox test (converted values match a hand-computed affine transform exactly, zero `_count` fields remain, `data.twist` unaffected), `checkcode` clean. (Separately: the `MODvis_spectra` report itself was root-caused to stale L2 files predating the 2026-08-18 `spectra`-nesting refactor `70c2715` by three weeks - not a code bug; left for Nicole to reprocess when convenient. `MODvis_spectra.m`'s L2-only cosmetic labeling was also flagged as fixable/level-agnostic already, but held off per Nicole pending the discussion below.)

That measurement led into a longer discussion of whether L2's per-file spectra and postprocess's per-profile spectra should stop being computed independently, given profiles are needed for gridding and gridding matters for realtime too. Landed, after several rounds of back-and-forth, on: realtime keeps L2 exactly as today (per-L1-file, independent of profile detection - Nicole's reason: profile picking is sometimes unreliable, and raw/QC spectra viewing shouldn't depend on it working), but should gain a step that *assembles* profile-shaped output for realtime by grouping L2's already-computed scans by detected-cast membership rather than recomputing from L1. Edge scans near an L1 file boundary are expected to be approximate in this realtime view (Nicole: "understood that will be fixed in post-processing") - postprocess's independent, exact per-profile recompute is unaffected and remains authoritative. Recorded as the settled direction in Section 4's "Two processing modes" subsection; not implemented this session.

### 2026-08-25/26 — FP07 electronic noise floor: probe identification, bench/modeled split, production stays on bench noise (branch `chi_processing`)

**`mod_scan_fpo7_noise_f.m` created and the probe identified**: decoded the actual purchased part number, FP07DB204N, against the Amphenol FP07 datasheet's ordering scheme (model/length/material-code/resistance/tolerance) to confirm our thermistors are Amphenol material type B9, R25 = 200 kOhm - superseding the generic 150 kOhm estimate from Le Boyer et al. (in prep) that `docs/references.md` previously cited as the only source. Amphenol's resistance-curve reference guide doesn't publish A/B/C/D Ln(Rt/R25) coefficients for this curve family directly (only a Ratio/Beta table and a Rt/R25-vs-temperature table), so those were fitted here against that table. `docs/references.md` updated with the new sources (the FP07 datasheet, the Mouser order record). Renamed from `mod_scan_make_FPO7_noise_f.m` for naming-convention consistency with its `mod_scan_fpo7_*.m` siblings.

**Physics investigation - where Johnson/amplifier noise sits relative to the AFE's two filters**: `mod_scan_fpo7_noise_f.m`'s theoretical model needs to be compared against real recorded FP07 spectra, which have passed through both the FP07 thermal-rolloff filter (`mod_scan_fpo7_transfer_function.m`) and the AFE's downstream electronics/ADC anti-alias filter. Worked through where Johnson noise (generated by the thermistor's own resistance) and amplifier input-referred noise actually enter that chain: both are generated electrically, downstream of/parallel to the bead's thermal lag - so they should be shaped by the electronics/ADC filter only, never by the thermal-rolloff filter (which specifically describes how *external water temperature* becomes bead resistance, a process electronic noise never goes through). This caught a real bug: an earlier exploratory comparison (`astral_adjust_spec_by_scan_all_new_noise.m`, a Dropbox analysis script outside this repo) had compared the unfiltered theoretical noise model directly against real, already-electronics-filtered recorded spectra - overstating the model's noise floor near Nyquist. That specific 342-profile run was not rerun with the fix (out of scope for what was asked that session) - flagged here as a known-stale result if anyone returns to it.

**Two new repo functions**, splitting the noise floor into its measured/theoretical pair:
- `processing/scans/mod_scan_fpo7_bench_noise_f.m` - evaluates the old bench-measured noise curve (`noise_coefs.n0..n3`, a cubic-in-log10(f) polynomial); a real end-to-end measurement, so already "as recorded" - no filter needed before comparing against a real spectrum.
- `processing/scans/mod_scan_fpo7_modeled_noise_f.m` - wraps `mod_scan_fpo7_noise_f.m`, applying the electronics/ADC filter only (not thermal) to convert the theoretical model into that same "as recorded" domain. Named `_modeled`, not `_recorded` (an earlier name) - Nicole's feedback was that "recorded" wrongly implied an actual measurement, when this is a from-scratch circuit model.

**Production decision: bench noise stays for now.** After looking at exploratory comparison figures, Nicole didn't like the modeled noise floor's behavior (not yet root-caused). Decision: `mod_scan_fpo7_cutoff.m` (the actual production noise-floor cutoff feeding `mod_scan_calc_chi_obs.m`/`mod_scan_calc_chi_mle.m`) keeps using bench-measured noise + `adjust_spec` normalization, unchanged in behavior - the modeled path stays built but unwired into production. `mod_scan_fpo7_cutoff.m` was refactored to call the new `mod_scan_fpo7_bench_noise_f.m` instead of its own inline copy of the same formula (dedup only - verified byte-identical `fc_index` output against the old inline version on a synthetic spectrum before committing). This was the only production-code behavior touched this session, and it's behavior-preserving. Also recorded in Claude's persistent memory (`project_fpo7_noise_floor_decision.md`) so a future session doesn't silently wire the modeled path in without asking.

**Exploratory Dropbox scripts** (not part of this repo - live in `~/Library/CloudStorage/Dropbox/SIO/projects/mod_fish_lib/data_for_reorg/epsi_mako/astral/`, alongside their siblings like `astral_adjust_spec_by_scan_all.m`/`explore_prof100_noise_floor.m`): `astral_adjust_spec_by_scan_all_new_noise.m`, `explore_prof100_noise_floor_new_noise.m`, and the raw-frequency-space pair `explore_prof100_noise_floor_freq_old_noise.m`/`explore_prof100_noise_floor_freq_new_noise.m` (the last two use the corrected, electronics-filtered modeled-noise treatment).

### 2026-08-15 Nicole's notes

For the plan of having no hard-coded values and needing all of them to come from the yaml file. Instead of checking first if every single one of the values we need for all the processing are in the file, check whenever it comes up. Once you get to a processing step that requires a value that is not in meta_data, check again in the yaml file. If it's not there, have a pop-up that says that value has not been defined. Suggest what the default value is, and say that the .yml file will be updated with whatever value the user chooses. Update the yaml and re-read it and continue processing. 

### 2026-08-13 - Nicole's notes

There's strong, well-established consensus: use GSW (TEOS-10), not the old SEAWATER (sw_) toolbox.

Background

The sw_ scripts implement EOS-80 (the 1980 equation of state), built around practical salinity (PSS-78).
The gsw_ scripts implement TEOS-10 (Thermodynamic Equation of Seawater 2010), built around Absolute Salinity (SA) and Conservative Temperature (CT) rather than practical salinity and potential temperature.

We should get rid of sw_ dependence and move to gsw_. We should also keep very careful notes of what units all our variables are in.

### 2026-08-12 - Nicole's notes

ATOMIX best practices says "FFT length is the number of samples used to compute the fast Fourier Transform. **It is recommended that the displacement of the vehicle during fft-length (converted in second) should not exceed the length of the profiler**, unless the profiler is a rigidly fixed platform that is not swayed by the eddies in the flow. FFT length should be 2^N where N is the power of 2 the closest to time required for the vehicle to travel over a full body length. Consequently, the FFT-length and length of the vehicle sets a lower limit to the wavenumber of shear that can be resolved."

At approximately 0.7 m/s fall speed, nfft = 512 would be 2 m which is a bit longer than the fish, but not by much. Our default should be 512.


### 2026-07-28 — AFE electronics/ADC transfer function: `MODsetup_define_filters.m` (branch `chi_processing`)

Found while comparing this repo's `chi_obs` directly against a real `epsi_mako/astral/profiles/Profile100.mat`'s `Profile.chi(:,1)` (Ankitha's `MOD_fish_lib` run) - a direct comparison the `chi_mle`/tau-sensitivity validation earlier the same day hadn't done. `chi_obs` at tau0=0.005 came out systematically low. Confirmed `kc`, the FP07 calibration slope, and thermal diffusivity all already matched; back-solving `Profile100.mat`'s own stored `Pt_Tg_k` for the correction factor it was actually generated with matched `MOD_fish_lib`'s `H.FPO7 = H.electFPO7² .* H.magsq(speed)` (`get_filters_SOM.m`) to 4 significant figures - i.e. the AFE's sinc⁴ ADC anti-alias filter, which `mod_scan_fpo7_transfer_function.m`'s own docstring had already flagged as deliberately excluded and deferred to `modProcess_L1_apply_filters.m` (§6.2, "not started"). Not a small correction here: ~1.65x on top of the thermal rolloff by f≈62 Hz for a typical fall speed, right where chi's integration is most sensitive.

Built per §6.2's existing "Design note: instrument filters" (written earlier the same day): **`setup/MODsetup_define_filters.m`** (new) resolves `metadata.AFE.(ch).electronics_filter` (magnitude-squared, deployment-constant) for fpo7/shear/acc channels from `f` (derived via a dummy `pwelch` call matching `mod_scan_get_spectra.m`'s own) and `metadata.AFE.(ch).type`/`.ADCfilter` (new yaml field, `MODsetup_read_yaml.m`, defaults `'sinc4'`) - fpo7/acc get sinc⁴ squared; shear also folds in a charge-amp filter (`cap1nFres200Meg_5KohmInput.mat`, vendored from `MOD_fish_lib` into `MOD_fish_calibrations/SHEAR/` - not yet committed, same as `FPO7_benchnoise.mat`). Wired into `MODprocess_all_L0_to_L1.m` unconditionally (no CTD gate needed, unlike fpo7 calibration). Tdiff not ported - confirmed no deployment this repo processes has ever used it.

**Deliberately did not build a generic `modProcess_L1_apply_filters.m`** (see §6.2's design note for the reasoning) - shear/accel have `electronics_filter` resolved for future use but no consumer yet (no epsilon module). Instead threaded a new optional `electronics_filter` parameter directly through the existing pure chi chain: `mod_scan_fpo7_volts_to_Tg_spectrum.m` -> `mod_scan_calc_chi_obs.m`/`mod_scan_calc_chi_mle.m` -> `MODprocess_single_L1_to_L2.m`'s chi call site (default 1/no-correction, so pre-existing callers are unaffected).

**Validated**: `MODsetup_define_filters.m` resolves without error against a real sandboxed `blt2021_0715` deployment for all 7 AFE channels, including the "shear charge-amp file not vendored for this deployment's `calibrations_root` yet" warning path. Re-ran `analysis/chi_tau_mle_comparison.m` against `Profile100.mat` with the new `electronics_filter`: for scans where this repo's `kc` matches `Profile.tg_kc` (spot-checked, upper-middle depth range), `chi_obs` now lands at 85-100% of `Profile.chi` (previously 30-90%, often badly low) - closes the gap this investigation set out to close. **Surfaced, not resolved**: across the full 317-scan profile, the per-scan `chi_obs`/`Profile.chi` ratio still has a wide spread (median ~0.4) - ruled out calibration-source noise as the cause (flat vs. pressure-binned `cal_profile` made it worse, not better), traced instead to `kc` itself diverging from `Profile.tg_kc` for many scans despite identical bench noise coefficients and algorithm. Logged as a new "Known limitation" in `docs/workflow/L2_calc_chi.md` rather than chased down this session - a `kc`/noise-floor question, not an electronics-deconvolution one.

### 2026-07-28 — chi_obs rename + Batchelor-spectrum chi_mle (branch `chi_processing`)

Prompted by `mod_fish_lib/data_for_reorg/epsi_mako/astral/astral_chi.md` (Ankitha's ASTRAL profiles, written up while documenting the BLT paper correction): the doc names the two chi-affecting changes as (1) the tau fix (2026-07-27, below) and (2) `chi_obs` vs. `chi_mle` (Batchelor spectrum fit via MLE) - and proposes renaming plain "chi" to `chi_obs` "to be extra clear" now that a second estimator exists. Did both in one pass: the rename first (so `chi_mle` never had an ambiguous sibling to be confused with), then `chi_mle` itself.

**Rename**: `MODprocess_L2_calc_chi.m` → `mod_scan_calc_chi_obs.m` (`git mv`, output var `chi`→`chi_obs`). Every mention of the old filename across `processing/` (`mod_scan_fpo7_transfer_function.m`, `mod_scan_fpo7_cutoff.m`, `mod_scan_thermal_diffusivity.m`, `MODprocess_L1_apply_fpo7_calibration.m`, `MODprocess_all_L0_to_L1.m`) and `MODprocess_single_L1_to_L2.m`'s variables/fields (`chi_all`/`chi_kc_all`/`L2data.chi`/`L2data.chi_kc` → `chi_obs_*`/`L2data.chi_obs*`) updated to match. Left alone: `MODprocess_single_modraw_to_L0.m`'s `chi`/`chi_fom` fields - those decode an onboard APF telemetry wire format's own field names, an unrelated firmware-side "chi", not this pipeline's.

**Also split** `mod_scan_calc_chi_obs.m`'s first three steps (volts spectrum → tau-deconvolved temperature-gradient wavenumber spectrum) into a new shared `mod_scan_fpo7_volts_to_Tg_spectrum.m`, since `chi_mle` needed the exact same conversion - one shared function means a tau override can't apply to one estimator and not the other by accident. Both `mod_scan_calc_chi_obs.m` and the new `mod_scan_calc_chi_mle.m` gained explicit `tau0`/`exponent` passthrough arguments while at it (previously a tau sensitivity comparison meant editing source, contradicting `mod_scan_fpo7_transfer_function.m`'s own documented intent that it wouldn't).

**`chi_mle`** (new): `mod_scan_batchelor_spectrum.m` (theoretical Batchelor 1959 spectrum evaluated at a given k - linear in chi for fixed epsilon/nu/ktemp, which is what makes the fit a 1-D amplitude search; nu itself is just `sw_visc.m` called directly by the caller, no wrapper function - unlike `ktemp`, there's no extra logic to justify one), and `mod_scan_calc_chi_mle.m` itself (grid-search MLE, Ruddick/Ozsoy/Vagle 2000 - a from-scratch reimplementation of `MOD_fish_lib`'s `get_chi_mle.m`/`mle_any_model.m`/`logLikelihood.m`, not a port; 4-pass 200-point log-spaced zoom instead of the original's open-ended edge-widening loops). **Needs an externally-supplied `epsilon`** - `modProcess_L2_calc_epsilon.m` isn't built yet, so this is not wired into `MODprocess_single_L1_to_L2.m`; it's a standalone function for now, callable wherever an epsilon estimate already exists.

**Validated end-to-end** against a real ASTRAL profile (`epsi_mako/astral/profiles/Profile100.mat`, old-format `MOD_fish_lib` Profile struct - not this repo's own L2 output, but its `Pt_volt_f.(ch)` is exactly the raw spectrum both chi functions need, and it already carries a per-scan `epsilon_final` that made `chi_mle` runnable here despite the epsilon gap above) via new `analysis/chi_tau_mle_comparison.m` - the actual tau-sensitivity comparison `docs/workflow/L2_calc_chi.md` had flagged as "not yet run" since 2026-07-27. 317 scans, tau0 0.005 → 0.0086 (middle of `astral_chi.md`'s 0.0083-0.0089 s range): `chi_obs` median rose 1.24x (t1) / 1.27x (t2); `chi_mle` median rose 1.17x / 1.21x. `chi_mle` came out ~1.8-2.0x higher than `chi_obs` at either tau - both directions physically sensible (larger tau -> stronger high-wavenumber rolloff correction -> larger chi; `chi_mle`'s Batchelor fit recovers some of the variance past the noise-floor cutoff that direct integration simply truncates). Full numbers and interpretation in `docs/workflow/L2_calc_chi.md`.

**Still open**: FOM QC flag for either estimator (deferred, same as before); `t1`/`t2` chi discrepancy on `blt2021_0715` (unrelated, still not root-caused); `chi_mle` wiring into the automatic pipeline (blocked on shear-based epsilon).

**Later same day - naming/organization feedback**: "too many `MODprocess_` scripts" - `MODprocess_` should mean big, file-I/O/whole-deployment orchestrators (`all_L0_to_L1`, `add_twist`, `apply_fpo7_calibration`, etc.), not small per-scan pure-math helpers. Confirmed with Nicole (`mod_` prefix, level tag dropped from the name; a `processing/scans/` subfolder, since all 8 candidates operate on exactly one scan's spectrum - not "L2" per se, and an empty `processing/L1/` sibling would've been premature). Moved and renamed all 8: `mod_scan_get_spectra.m`, `mod_scan_fpo7_transfer_function.m`, `mod_scan_fpo7_cutoff.m`, `mod_scan_thermal_diffusivity.m`, `mod_scan_calc_chi_obs.m`, `mod_scan_calc_chi_mle.m`, `mod_scan_batchelor_spectrum.m`, `mod_scan_fpo7_volts_to_Tg_spectrum.m` → `processing/scans/`. Every call site and doc reference updated to match; re-validated against `Profile100.mat` afterward - identical numbers to the pre-move run above, so the move/rename touched nothing functional.

Also removed `MODprocess_L2_kinematic_viscosity.m` (added earlier the same day) - flagged as "totally redundant" since it was a single `nu = sw_visc(S,T,P);` pass-through with no logic of its own to justify a separate documented function, unlike `mod_scan_thermal_diffusivity.m` (which genuinely combines `sw_dens`/`sw_cp` with a ported thermal-conductivity term). Callers now call `sw_visc.m` directly.

**Filter organization design captured, not built** (prompted by "we used to have `get_filters_SOM.m` which put all the filters in one place"): see Section 6.2's new design note above `modProcess_L1_apply_filters.m`'s row - the key insight is that `f` is deployment-constant (from `nfft`/`Fs_epsi`), not scan-specific, so most of `get_filters_SOM.m`'s content (ADC sinc⁴, charge-amp, Tdiff, gains) can be resolved once via a new `MODsetup_define_filters.m`, exactly like `MODprocess_L1_apply_fpo7_calibration.m` resolves `volts_to_C` once; only the FPO7 thermal rolloff needs per-scan `w` and stays a `processing/scans/` function (`mod_scan_fpo7_transfer_function.m`, already built). Deliberately not implemented this session - real scope for a later pass.

**Same reorg, one more round**: `MODprocess_L1_add_twist.m` and `MODprocess_L1_detect_profiling_direction.m` also flagged as candidates for the same treatment. Checked each against the file-I/O criterion rather than assuming both qualified: both are genuinely pure (struct in, struct out, no `load`/`save` anywhere in either) - moved to `processing/L1/mod_L1_add_twist.m` and `processing/L1/mod_L1_detect_profiling_direction.m`. A third candidate, `MODprocess_L1_apply_fpo7_calibration.m`, does its own `dir()`/`load()` across every file in a deployment's `L1_dir` - the same thing `MODprocess_L1_accumulate_twist_timeseries.m` and `MODprocess_L1_make_pressure_timeseries.m` do, both left as `MODprocess_` in the first reorg round - so it stayed `MODprocess_L1_apply_fpo7_calibration.m` rather than moving too, for consistency with those two. All call sites and doc references updated; `checkcode` clean on every touched file (aside from pre-existing, unrelated `datestr`/`now`/`datenum` modernization suggestions this session didn't introduce).

Caught and fixed a side effect of the first reorg round's global find/replace: it had rewritten filenames inside the 2026-07-24 and 2026-07-26 session log entries below to their *current* (post-rename) names, even though those entries describe what was true - and what those functions were actually called - on the date each entry is dated. Restored the historical names in those entries (`MODprocess_L1_add_twist.m`, `MODprocess_L2_fpo7_transfer_function.m`, etc.) with a forward pointer to where each one lives now, rather than let a reverse-chronological log misstate its own history.

**One more naming round, same day**: reconsidered dropping the level tag from `processing/L1/`/`processing/scans/` names (the choice just above) after Nicole pushed for the repo to be "super super clear about what each function does." The reversal: MATLAB has a flat function namespace - a stack trace, `which`, tab-completion, or a grep hit all show the bare function name only, never the folder it lives in, so "the folder already says the level" turns out to be true only while browsing the file tree and false everywhere else a name actually gets read. Renamed both `processing/L1/` functions to `mod_L1_*` and all eight `processing/scans/` functions to `mod_scan_*`, dropping the resulting redundant "scan" from `mod_get_scan_spectra.m` -> `mod_scan_get_spectra.m` (kept literal elsewhere - a mechanical prefix add, not a base-name rewrite). Bonus alignment noticed, not designed for: `mod_L1_*` now lines up token-for-token against the big `MODprocess_L1_*` orchestrators (e.g. `mod_L1_add_twist` vs. `MODprocess_L1_apply_fpo7_calibration`) - same `_L1_` tag, prefix case alone signals pure-function vs. file-I/O-orchestrator. All call sites, docstrings, and error/warning identifiers updated; `checkcode` clean.

Also ran `/code-review` against the branch (see Section 9's new "`chi_processing` code review findings" subsection for the full list, 9 items) - explicitly saved for later, not fixed this session.

### 2026-07-27 — FP07 time-constant deconvolution and chi (branch `chi_processing`)

Traced where the FP07 time constant (`tau = 0.005 * w^-0.32`) enters `MOD_fish_lib`'s chi calculation, prompted by Nicole/Arnaud needing to describe this precisely for a 2025 BLT paper correction (a wrong tau biases chi, and chi/epsilon errors that are individually unremarkable become a direct factor in gamma). Found the formula itself has never changed across `MOD_fish_lib`'s git history, but the deconvolution that *uses* it (`Pt_T_f ./ filter_TF` in `mod_efe_scan_chi.m`) was silently dropped on 2025-10-06 (commit `051d80f`, "fix linear volts to C conversion") when a stale `dTdV` calibration was correctly replaced with `volts_to_C` - `filter_TF` is still computed today, just never applied. `MOD_fish_lib` is off-limits to edit directly, so built a from-scratch, documented version of the whole chain in `MOD_fish_processing` instead, one module at a time (explicit preference: "keep this as modular as possible so I can test things one at a time"), each tested standalone against real `epsi_mako/blt2021_0715` data (Mako, real onboard SBE CTD SN537 - the only deployment in `data_for_reorg` with real time-aligned CTD T; `epsi_deepsolo`'s external CTD is P-only and can't support any of this) in a scratchpad sandbox (`meta`/`calibrations`/`L1` only, ~930 MB - `L0`/`raw` left out, not needed).

**`MODprocess_L1_apply_fpo7_calibration.m`** (new): fits `volts_to_C = [slope, intercept]` per FP07 channel, in-situ, against real CTD T, gated on descending data only. Wired into `MODprocess_all_L0_to_L1.m` (gated on `~isempty(metadata.CTD.cal)`), persisted via `MODsetup_save_metadata.m`. Real result: `t1.volts_to_C = [-32.86, 51.70]`, `t2.volts_to_C = [-30.62, 45.53]` (n=725,673 descending samples each) - t1's (volts, T) scatter tight, t2's visibly noisier.

**`MODprocess_L2_fpo7_transfer_function.m`** (new; renamed `mod_scan_fpo7_transfer_function.m` in `processing/scans/` on 2026-07-28): the tau-based thermal-rolloff deconvolution filter itself, `tau0`/`exponent` exposed as real function arguments (not hardcoded) specifically so a tau sensitivity comparison is a one-line change. Deliberately excludes the AFE electronics/ADC filter and the old "Tdiff" analog-differentiator term (confirmed via `MOD_fish_lib`'s actual `blt2021_0715` process config that `MAP.temperature` was never `'Tdiff'` for this deployment). Verified: half-power frequency matches `1/(2*pi*tau)` analytically; doubling `tau0` correctly lowers the cutoff.

**`MODprocess_L2_fpo7_cutoff.m`** (new; renamed `mod_scan_fpo7_cutoff.m` in `processing/scans/` on 2026-07-28): noise-floor cutoff (kc) for chi's wavenumber integration, ported from `FPO7_cutoff.m` but fixing two indexing bugs found while tracing it (both silently returned an index a few bins earlier/lower-frequency than the actual noise-floor crossing - see `docs/workflow/L2_calc_chi.md` for the full detail). Verified visually against a real t1_volt scan's spectrum vs. scaled noise floor.

**`MODprocess_L2_thermal_diffusivity.m`** (new; renamed `mod_scan_thermal_diffusivity.m` in `processing/scans/` on 2026-07-28): ktemp via already-vendored `sw_dens`/`sw_cp` (not `MOD_fish_lib`'s differently-unit-scaled `density.m`/`cp.m`) plus a ported Caldwell (1974) thermal-conductivity term, with a units bug fixed (the original's caller passed dbar into a formula documented as wanting MPa). Verified: ~1.43e-7 m^2/s at S=35/T=10/P=1000, matching the expected seawater range.

**`MODprocess_L2_calc_chi.m`** (new) + `MODprocess_single_L1_to_L2.m` extended (scan-center `temperature`/`salinity`, `chi.(channel)`/`chi_kc.(channel)`): combines all of the above into a direct-integration chi (kmin=3 cpm to kc, no Batchelor MLE fit or FOM yet - deliberately deferred as a separate, later module). Already wired into the batch `MODprocess_all_L1_to_L2.m` with no changes needed there, since it flows through the per-file function.

**Calibration file**: `MOD_fish_lib/EPSILOMETER/CALIBRATION/FPO7/FPO7_notdiffnoise.mat` copied into `MOD_fish_calibrations/FPO7/FPO7_benchnoise.mat` (renamed, contents unchanged), plus a `README.md` documenting the rename/provenance. Not yet committed to `MOD_fish_calibrations` (that repo has an unrelated in-progress uncommitted README edit, left untouched).

**End-to-end test** (`blt2021_0715` sandbox, one clean descending profile, 1516→1782 dbar, 64 scans): t1 chi = 9.0e-11 to 5.5e-8 degC^2/s (median 3.1e-9) - an unremarkable, physically sane quiet-water value. t2 chi = 5.7e-9 to 2.3e-6 (median 6.0e-7) - **~200x higher**, with a correspondingly higher noise-floor cutoff (kc 59.7-217.8 cpm vs. t1's 18.0-108.4). Consistent with t2's noisier calibration scatter from Module 1 - read as a real t2 data-quality issue, not a bug (same code, same scan, clean t1 result). Not yet root-caused.

**Still open**: the actual tau sensitivity comparison (the point of this whole exercise) hasn't been run yet - the machinery is built and unit-tested, but no side-by-side "default tau vs. candidate wrong tau" chi diff has been done against real data yet. Also open: Batchelor MLE fit/FOM (deferred), t1/t2 discrepancy investigation, committing the `MOD_fish_calibrations` addition.

### 2026-07-26 — L1->L2 for epsi_deepsolo: downcast-gated per-scan spectra (branch `l1_to_l2_conversion`)

Started the L1->L2 step per the plan discussed with Nicole - deliberately diverging from `mod_fish_lib`'s profile-based approach for `epsi_deepsolo` (Section 4/6.4 note). Design decisions made along the way, confirmed with Nicole before implementation:
- **Scope: raw spectra only** (shear/fpo7/accel pwelch, uncorrected) - no epsilon/chi yet.
- **Scan stepping: 50% overlap** (`scan_step = N_epsi/2`).
- **Scan indexing: per-L1-file** ("realtime" mode - each file tiled independently, no cross-file I/O). Framed explicitly as the realtime-processing choice, with whole-deployment or profile-indexed "post-processing" mode as later work once `modProcess_detect_profiles.m` exists.
- **Profiling-direction detection moved to L1, not L2** - `ctd.P`/`dPdt` are already an L1 product, so classifying descent from them is naturally L1's job too, mirroring the twist-counting per-file/accumulate pattern. This also means a single L1 file can be processed to L2 standalone (`meta/PressureTimeseries.mat` is small and cheap to load), which was a real design requirement Nicole raised, not just a nice-to-have.

**A DeepSolo pressure file (`ctd/DeepSoloFallrise.mat`) appeared in the data folder this session** - dnum/P only (no T/C/S), 1032 points over 41.4 h, ~60 s spacing on the way up, ~120 s on the way down, at least one ~9982 s (2.77 h) gap. This is the "sparse fallrise data" Nicole described - the float's continuous pressure record, distinct from DeepSolo's separate pressure-binned up/down CTD profiles (P/T/S, not time-aligned, still unsolved). Confirmed `P` increasing = descending, matching the existing `dPdt` sign convention.

**Prerequisite L0->L1 fixes** (both needed before any of this could run - previously `ctd` was `[]` in every `epsi_deepsolo` L1 file):
- `MODprocess_read_external_ctd.m`: implemented a real DeepSolo branch (was an unconditional stub error). Wirewalker still unimplemented (no sample file).
- `MODprocess_single_L0_to_L1.m`'s CTD subfunction renamed `calibrate_ctd` -> `process_ctd_fields` (it does no calibration at all for SBE41/external-CTD sources, only derivation - "calibrate" undersold that) and its S/th/sgth derivation guarded behind `isfield(ctd,'T') && isfield(ctd,'C')`, since DeepSolo's fallrise file has neither. `dPdt`/`z`/`dzdt` still compute unconditionally.

**New L1-level functions** (called from the end of `MODprocess_all_L0_to_L1.m`, gated on the deployment having any CTD data): `MODprocess_L1_make_pressure_timeseries.m` (concatenates `ctd.dnum`/`.P` across all L1 files - this is Section 6.3's long-planned `modProcess_make_pressure_timeseries.m`, finally implemented) and `MODprocess_L1_detect_profiling_direction.m` (renamed `mod_L1_detect_profiling_direction.m` in `processing/L1/` on 2026-07-28 - see Section 6.2) (gap detection, cheby2 lowpass sized to the record's own sample spacing rather than a fixed seconds value, buffered edges - heavily commented per Nicole's request to understand the math, not just trust it). Both save to `meta/PressureTimeseries.mat`.

**New L2 functions**: `MODprocess_L2_get_scan_spectra.m` (renamed `mod_scan_get_spectra.m` in `processing/scans/` on 2026-07-28) (per-scan pwelch, stripped-down version of the old `get_scan_spectra.m`/`mod_efe_scan_acceleration.m`), `MODprocess_single_L1_to_L2.m` (per-file scan tiling + gating, pure - `PressureTimeseries` passed in as a required argument, not self-loaded), `MODprocess_all_L1_to_L2.m` (batch orchestrator mirroring `MODprocess_all_L0_to_L1.m`'s shape).

**`setup.yml` additions**: `afe.sample_rate` (-> `metadata.PROCESS.Fs_epsi`, default 320), `spectral.nfft`/`.dof` (-> `metadata.PROCESS.nfft`/`.dof`, defaults 1024/3), `profile_detection.lowpass_factor`/`.gap_factor`/`.buffer_bins` (-> `metadata.PROFILES.*`, defaults 3/5/1) - all optional, all added explicitly to `epsi_deepsolo/26_0520_ljc/meta/setup.yml` rather than relying on defaults.

**Real bug caught during testing**: `MODprocess_single_L1_to_L2.m`'s scan-to-direction matching originally used `interp1(...,'nearest','extrap')`. `epsi_deepsolo/26_0520_ljc`'s epsi logging starts ~18.5 h before the fallrise pressure record begins (files `modsom_00` through `modsom_13`) - with `'extrap'`, every scan in those files would have nearest-matched to whichever `PressureTimeseries` sample happened to be first, regardless of how many hours away, silently misclassifying them. Fixed by dropping `'extrap'` - out-of-range scans now correctly get excluded (`NaN` -> not-down) instead of guessed.

**Tested end-to-end** against a sandbox copy of `epsi_deepsolo/26_0520_ljc` (copied to scratchpad, not the real `data_for_reorg` folder, per Nicole's request to keep test runs out of directories she's also testing in manually) with `reprocess_all=true` on both steps:
- L0->L1 (45 files): `ctd.P`/`dPdt`/`z` now populated where previously empty; T/C/S/th/sgth correctly absent.
- `meta/PressureTimeseries.mat`: 757 samples (fewer than the raw file's 1032 - the rest fall outside any L1 file's epsi/vnav time range and get sliced out, same as external-CTD chunking always does), 30.1% classified `is_down`, `dPdt_smoothed` range -0.136 to +0.500 dbar/s, 0.8% NaN (short-segment fallback). Diagnostic plot (P / dPdt_smoothed / is_down vs. time) shows clean sawtooth pressure cycles with `is_down` landing exactly on each steep descending leg - visually confirms the classification.
- L1->L2 (45 files): scan counts ranged 0 (files entirely before pressure logging started, or entirely on an upcast) to 1066 per file. Spot-checked `modsom_20.mat`: 1066 scans, `f` 513 points (0-160 Hz, Nyquist for `Fs_epsi=320`), all 7 channels present (`t1_volt`/`t2_volt`/`s1_volt`/`s2_volt`/`a1_g`/`a2_g`/`a3_g`), `P.s1_volt` shaped `[1066 x 513]` as expected, kept scans' `pressure` monotonically increasing from 233.6 to 324.5 dbar in time order (100% of adjacent diffs non-negative) - confirms only real descent got through the gate.
- Confirmed standalone single-file usage: calling `MODprocess_single_L1_to_L2` directly on one loaded L1 file + a loaded `PressureTimeseries.mat` reproduces the same scan count (1066) as the batch run.

### 2026-07-24 — Cable twist counting: reviewed and fixed Ana's draft, wired into L0->L1 pipeline (branch `l0_to_l1_conversion`)

Ana had drafted `modProcess_L1_add_twist.m`, `modProcess_L1_accumulate_twist_timeseries.m`, and `modPlot_twist_timeseries.m` (Section 7) independently, untested against this repo's actual L1 file format. Reviewed against both PLAN.md Section 7's spec and the original source (`MOD_fish_lib/FastCTD_MATLAB/GV_PlotUpAccumulation.m`, `SN_RotateToZAxis.m`), fixed several real gaps, and shipped:

- **`SN_RotateToZAxis` added as a local subfunction inside `MODprocess_L1_add_twist.m`** (renamed `mod_L1_add_twist.m` on 2026-07-28 - see Section 6.2) - Ana's `add_twist` called it but it was never added to this repo (only existed in `MOD_fish_lib/FastCTD_MATLAB/SN_RotateToZAxis.m`, written by San Nguyen, MOD group). Not treated as vendored third-party code (it's MOD's own, unlike `YAMLMatlab_0.4.3`/`seawater`) and not split into its own file since nothing else in the repo calls it - folded in directly, content unchanged.
- **`twist.pressure` was missing entirely.** PLAN.md's spec and the original `GV_PlotUpAccumulation.m` both compute it (CTD pressure interpolated onto the vnav timebase, `NaN` fallback if no CTD or interpolation fails) - needed downstream to mark upcast/downcast on the plot. Added to `MODprocess_L1_add_twist.m`, called after CTD calibration inside `MODprocess_single_L0_to_L1.m` specifically so pressure is available.
- **`count_gyro` units were wrong.** Ana's version left the z-axis gyro integral in raw radians; the original divides by `2*pi` to get full rotations - the unit operators actually count fin/spool adjustments against (confirmed by the original's plot title "Rotation count" and PLAN.md's `[full rotations]` label). Fixed.
- **Real bug found via testing, not review: the accumulate function's file-loading was wrong for how this repo actually saves L1 files.** `MODprocess_all_L0_to_L1.m` saves each L1 `.mat` with `save(L1_file, '-struct', 'data')`, which flattens `data`'s fields to top-level variables (`vnav`, `twist`, ...) rather than nesting them under a `data` struct. Ana's `accumulate_twist_timeseries` (and PLAN.md Section 7's own pseudocode) assumed the nested form (`S.data.vnav`), so every file failed its validity check and the function always returned "no twist data" - caught immediately when actually run against `epsi_mako_w_fluor`'s real L1 files (96/96 "Error! Incorrect inputs"). Fixed to load `vnav`/`twist` directly.
- **Dead code removed:** Ana's `add_twist` defined a local `Rot_Mat` anonymous function that was never actually called (the loop uses the `Rot_mat` returned by `SN_RotateToZAxis` instead) - an unused duplicate of the matrix already inside `SN_RotateToZAxis.m`.
- **Renamed to match the repo's actual `MODprocess_`/`MODvis_` convention** (capital MOD - Section 6.1's naming note), not the `modProcess_`/`modPlot_` names PLAN.md's original Section 7 sketch used: `MODprocess_L1_add_twist.m`, `MODprocess_L1_accumulate_twist_timeseries.m` (both `processing/`), `MODvis_twist_timeseries.m` (moved to `visualization/matlab/`, matching `MODvis_timeseries.m`).
- **`MODvis_twist_timeseries.m`**: added the upcast-highlighting PLAN.md's spec called for (Ana's draft didn't use `pressure` at all) - `diff(pressure) < 0`, small marker size since a normal marker fully occludes the line at cruise-length sample counts (~1e6 points/deployment). Also fixed a missing closing paren in the title string, and a real layout bug where the "Neutral is Negative" annotation overlapped the x-axis label - shrunk the axes to leave room.
- **Wired into the pipeline** (this was previously a hand-run pair of functions with no orchestrator integration): `MODprocess_L1_add_twist` is now called inside `MODprocess_single_L0_to_L1.m` per file (after CTD calibration, gated on `data.vnav` being present - self-guards otherwise). `MODprocess_L1_accumulate_twist_timeseries` is now called once at the end of every `MODprocess_all_L0_to_L1.m` run, gated on `metadata.manifest.has_vnav` (not on vehicle/`fish_flag` - epsi deployments can carry a vnav too, and twist counting only makes sense where the hardware exists), so `meta/TwistTimeseries.mat` stays current automatically rather than needing a separate manual step.
- **Tested end-to-end** against `epsi_mako_w_fluor/25_0408_d03_mako1_canyonhead` (96 files, `vnav: true`) with `reprocess_all=true`: all 96 files got a populated `twist` field (`count_gyro` per-file range roughly -0.07 to 0.45 rotations, `pressure` 0% NaN). `meta/TwistTimeseries.mat` built successfully (~1.06M samples across the 8-hour deployment), final chained count 34.8 rotations, growing steadily and physically plausible for a repeatedly-profiled tow-yo survey (no `SpoolSwapLog.csv` present for this deployment, so the reset path wasn't exercised here). Plot renders cleanly with upcast highlighting and no layout collisions.
- Cruise-level tracking (twist carried across deployments/instruments sharing one winch cable, spool swaps and fin adjustments logged centrally) is explicitly out of scope for this session - `SpoolSwapLog.csv`/`TwistTimeseries.mat` today only operate within a single deployment folder. Noted as a later addition, not a gap in this step.

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
