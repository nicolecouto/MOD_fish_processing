# MOD Fish Processing Refactor — Project Plan

**Deadline: August 1st (burn-in for MURI and DECADES)**
**Primary repo for new work: MOD_fish_processing**

*Previously tracked on the `claude` branch of `MOD_fish_lib` during early planning; moved here 2026-07-08 now that MOD_fish_processing is where active work happens. See `MOD_fish_lib` `claude` branch history for the pre-move log.*

**Index** - read this first, then jump to the section you need. Code comments cite these section numbers, so keep them stable.

- [1. Vision and Repo Structure](#1-vision-and-repo-structure) - the three-repo split and what lives where
- [2. Guiding Principles](#2-guiding-principles) - design rules and their carve-outs (heavily cited from code)
- [3. Deployment Folder Structure](#3-deployment-folder-structure) - on-disk layout of a deployment
- [4. Data Levels](#4-data-levels) - L0/L1/L2/L3 definitions and current status of each
- [5. The Instrument Configuration Problem](#5-the-instrument-configuration-problem) - `setup.yml` and the instrument manifest
- [6. Processing Pipeline - Function List](#6-processing-pipeline--function-list) - per-level function tables and design notes
- [7. Twist Counting](#7-twist-counting--anas-first-project) - Ana's project, now shipped
- [8. Additional Tasks](#8-additional-tasks-after-ana-finishes-twist-counter)
- [9. Known Issues / Debt](#9-known-issues--debt) - open code-review findings and known bugs
- [10. Milestones](#10-milestones)
- [11. Wiki Update Checklist](#11-wiki-update-checklist) - `docs/` site status and the Standing rule for visualization docs
- [12. Session Log](#12-session-log) - moved to [`SESSION_LOG.md`](SESSION_LOG.md)

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
`mod_scan_fpo7_transfer_function.m` (still under `processing/scans/` - it takes probe-specific
arguments, not pure math). `mod_scan_thermal_diffusivity.m`, itself pure `(SP, SR, T, P)` math with
no `metadata`/probe argument, moved out of this carve-out entirely - renamed `ktemp.m` and relocated
to `toolbox/seawater/` alongside `visc.m` (branch `epsilon_processing`, 2026-09-08) - see
`SESSION_LOG.md`. The three theoretical-spectrum-shape functions this carve-out originally covered -
`batchelor_spectrum.m`, `panchev_spectrum.m`, `nasmyth_spectrum.m` -
were moved to `toolbox/theoretical_spectra/` (branch `epsilon_processing`, 2026-09-08) once there
were three of them, not one, making the carve-out's own "reusable outside the fish-scan pipeline
entirely" reasoning literal rather than just a documentation note, then renamed the same day to drop
their `mod_scan_` prefix now that they take no `scan`/`metadata` argument and live outside
`processing/scans/` entirely - see `SESSION_LOG.md`.
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
  `pad_raw_filenames`, 2026-07-23, `SESSION_LOG.md`, established) — and offers to save the answer into
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

**Done and merged to `main`:** L0 (raw → .mat, no calibrations, no metadata beyond what's in the file). Originally prototyped on the `nicole` branch of `MOD_fish_lib` as `MODprocess_modraw_to_L0.m` / `MODprocess_allnew_modraw_to_L0.m`; see `SESSION_LOG.md` for what changed on the port. Documented in `MOD_fish_processing/docs/workflow/L0_modraw_conversion.md`.

**In progress on branch `l0_to_l1_conversion`:** L0 → L1 (counts/hex → physical units: epsi volts/g, CTD P/T/C/S, altimeter hab, cable twist count). First cut ships `MODsetup_read_yaml.m` + `MODprocess_single_L0_to_L1.m` / `MODprocess_all_L0_to_L1.m`, tested end-to-end against `epsi_mako_w_fluor/25_0408_d03_mako1_canyonhead` (96/96 files, physically plausible T/P/S/C). Twist counting (`mod_L1_add_twist.m`/`MODprocess_L1_accumulate_twist_timeseries.m`) added 2026-07-24 and wired into both orchestrators - see Section 7. Despike, filters, and shear/FPO7 calibration are still not in this step - see Section 6.2. Documented in `MOD_fish_processing/docs/workflow/L0_to_L1_conversion.md`. See `SESSION_LOG.md` entries 2026-07-09 and 2026-07-24 for what changed.

**In progress on branch `l1_to_l2_conversion`:** L1 → L2 for `epsi_deepsolo` - per-scan spectra (shear/fpo7/accel, raw uncorrected pwelch), gated by profiling direction (downcast only, `dPdt > 0`) rather than split into `Profile####.mat` casts - a deliberate divergence from the old `mod_fish_lib` approach (see Section 4 note below and `docs/workflow/L1_to_L2_conversion.md`). No epsilon/chi yet. Prerequisite L0→L1 fixes shipped alongside: real DeepSolo external-CTD reader (`ctd/DeepSoloFallrise.mat`, P-only), `calibrate_ctd` renamed `process_ctd_fields` and made T/C-optional, and a new deployment-level `meta/pressure_time_series.mat` (profiling-direction classification - an L1-level product, consumed by L2). Tested end-to-end against a sandbox copy of `epsi_deepsolo/26_0520_ljc` - see `SESSION_LOG.md` entry 2026-07-26.

**Done** (chi: branch `chi_processing`, off `l1_to_l2_conversion`; epsilon: branch `epsilon_processing`): FP07 in-situ `volts_to_C` calibration, the tau-based FP07 time-constant deconvolution, the noise-floor cutoff, a direct-integration `chi_obs`, and a Batchelor-spectrum MLE `chi_mle` - prompted by finding that `MOD_fish_lib`'s live chi calculation computes this deconvolution's transfer function but has silently stopped applying it since 2025-10-06 (relevant to a 2025 BLT paper correction Nicole/Arnaud need to describe precisely). Built and tested one module at a time against real `epsi_mako/blt2021_0715` data (the only deployment here with a real onboard CTD). `chi_mle` needed an `epsilon` estimate this repo didn't compute yet - `mod_scan_calc_epsilon.m` (shear-channel Nasmyth fit) now supplies one, and `chi_mle` is wired into `mod_L2_tile_scans.m` as a result. See `docs/workflow/L2_calc_chi.md`, `docs/workflow/L2_calc_eps.md`, and `SESSION_LOG.md` entries 2026-07-27, 2026-07-28, and 2026-09-08.

**Next target:** fix the regex block-splitting artifact in `MODprocess_single_modraw_to_L0.m` (Section 9 — parse by declared hex block length instead of regex terminators)

### Two processing modes: realtime vs. postprocess

The pipeline above forks into two modes once L1 exists, matching two different jobs:

- **Realtime**: `modraw → L0 → L1 → L2` (per-file). Runs on each raw file as it lands during a deployment - never waits for a complete profile, so it works even mid-cast. This is what the on-deployment/at-sea visualization tools (`MODvis_timeseries.m`, `MODvis_twist_timeseries.m`) consume - L1 fields directly, plus L2's per-L1-file spectra (`MODprocess_single_L1_to_L2.m`/`MODprocess_all_L1_to_L2.m`, gated on `metadata.manifest.has_epsi` - see Section 6.4). No profile-cutting involved.
- **Postprocess**: `modraw → L1 → profiles → grid`. Run once a deployment (or a leg of one) is done, against a complete L1 dataset - produces the final science-quality output: one `Profile####.mat` per detected cast in `metadata.paths.profiles` (`modProcess_detect_profiles.m` + `modProcess_extract_profile.m` + `MODprocess_single_L1_to_L2_profile.m`/`MODprocess_all_L1_to_L2_profiles.m` - see Section 6.3), then interpolated onto a standard pressure grid (`modProcess_L3_grid_profiles.m`, Section 6.5 - not started). Every detected cast gets a CTD record regardless of direction; `profile_dir` only gates whether a given profile also gets epsi spectra (Section 6.3/6.4).

Both L2 paths share the same windowing core (`mod_L2_tile_scans.m`) but today compute spectra independently - realtime's per-file output and postprocess's per-profile output are not deduplicated against each other (the original simplicity-over-storage-optimization call, confirmed with Nicole - see `SESSION_LOG.md`, 2026-08-28). L0 and L1 are shared unmodified by both modes; the fork happens entirely at the L2 step.

**Revised direction, not yet implemented** (`SESSION_LOG.md`, 2026-08-28, "L1 disk duplication and realtime profile-assembly" follow-up): realtime should keep computing L2 exactly as today (per-L1-file, profile-detection-independent - this stays the fallback/QC view for when profile picking is unreliable, and for looking at raw spectra without the profile abstraction), but should also *assemble* profile-shaped output for realtime gridding by grouping L2's already-computed scans by which detected cast their center-time falls in, rather than recomputing scans from L1. Edge scans that straddle an L1 file boundary near a cast's start/end are expected to be approximate in this realtime-assembled view - understood and accepted, since postprocess's independent per-profile recompute (unchanged, still exact) is the authoritative science-quality product. This only applies to the realtime path; postprocess's `MODprocess_single_L1_to_L2_profile.m` keeps recomputing scans directly from each profile's own stitched L1 record, same as today.

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

**Deviation from the design as originally sketched (2026-07-28, same session `MODsetup_define_filters.m` shipped)**: rather than a generic `modProcess_L1_apply_filters.m` that "applies the combined filter to that channel's spectrum" for any channel, the combination is done directly inside the existing pure `mod_scan_fpo7_volts_to_Tg_spectrum.m` (new optional `electronics_filter` parameter, default 1/no-correction), threaded through `mod_scan_calc_chi_obs.m`/`mod_scan_calc_chi_mle.m` to `MODprocess_single_L1_to_L2.m`'s chi call site. Reason: fpo7/chi is the only channel type with a real consumer today - shear/accel channels have `electronics_filter` resolved (via `MODsetup_define_filters.m`, built as designed) but nothing downstream to apply it to yet, since `mod_scan_calc_epsilon.m` (§6.4) doesn't exist. A generic apply-wrapper right now would have exactly one indirect caller, the same "pass-through wrapper with no logic of its own" shape this repo removed once already (`MODprocess_L2_kinematic_viscosity.m`, see `SESSION_LOG.md`, 2026-07-28). Build `modProcess_L1_apply_filters.m` for real once shear/accel spectra have a second consumer to apply it to.

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
| `mod_scan_calc_epsilon.m` | Nasmyth fit → epsilon, called per shear channel from `mod_L2_tile_scans.m`'s per-scan loop (not a `metadata.manifest.shear_channels` list - channels are filtered inline the same way `chi_obs_channels` already is, for consistency) | `mod_efe_scan_epsilon.m` | Done (branch `epsilon_processing`, 2026-09-08; renamed/moved from `processing/L2/modProcess_L2_calc_epsilon.m` to `processing/scans/mod_scan_calc_epsilon.m` later the same day) - see `docs/workflow/L2_calc_eps.md` |
| `mod_scan_fpo7_volts_to_Tg_spectrum.m` | Shared first stage for both chi estimators: raw FP07 volts spectrum → tau-deconvolved temperature-gradient wavenumber spectrum | `mod_efe_scan_chi.m` (steps 1-3) | Done (branch `chi_processing`) — split out of `MODprocess_L2_calc_chi.m` once `chi_mle` needed the identical conversion |
| `mod_scan_calc_chi_obs.m` | Direct-integration chi_obs (FP07 calibration → tau deconvolution → noise-floor cutoff → wavenumber integration). No FOM yet (**old `mod_efe_scan_chi.m` currently broken — see Section 9**) | `mod_efe_scan_chi.m` | Done (branch `chi_processing`, renamed from `MODprocess_L2_calc_chi.m`) — needs real onboard CTD T (blocked for DeepSolo, works for `epsi_mako`); see `docs/workflow/L2_calc_chi.md`. FOM still not started |
| `toolbox/theoretical_spectra/batchelor_spectrum.m` | Theoretical Batchelor (1959) temperature-gradient spectrum evaluated at a given k - the model `chi_mle` fits | `batchelor.m` local subfunction inside `mod_efe_scan_chi.m` | Done (branch `chi_processing`; moved and renamed on branch `epsilon_processing`, 2026-09-08) |
| `mod_scan_calc_chi_mle.m` | chi_mle via Batchelor-spectrum MLE fit (Ruddick, Ozsoy & Vagle 2000) - grid-search over chi with epsilon/nu/ktemp fixing the spectrum's shape | `mod_efe_scan_chi.m` / `get_chi_mle.m` / `mle_any_model.m` / `logLikelihood.m` | Done (branch `chi_processing`); wired into `mod_L2_tile_scans.m` (branch `epsilon_processing`, 2026-09-08) now that `mod_scan_calc_epsilon.m` supplies epsilon; grid-search zoom split into shared `processing/scans/mod_scan_mle_grid_search.m` at the same time - see `docs/workflow/L2_calc_chi.md`, `docs/workflow/L2_calc_eps.md` |
| `mod_scan_fpo7_transfer_function.m` | FP07 thermal time-constant deconvolution filter, `tau0`/`exponent` exposed as overridable parameters for a tau sensitivity comparison | `get_filters_MADRE.m`/`h_fp07.m` (formula unchanged; the deconvolution step itself was silently dropped from `MOD_fish_lib`'s live `mod_efe_scan_chi.m` on 2025-10-06 — see Section 9) | Done (branch `chi_processing`) |
| `mod_scan_fpo7_cutoff.m` | Noise-floor cutoff (kc) for chi_obs/chi_mle's wavenumber range - fixes two indexing bugs found in the original | `FPO7_cutoff.m` | Done (branch `chi_processing`) |
| `toolbox/seawater/ktemp.m` | ktemp for chi_obs/chi_mle, via vendored `gsw_rho`/`gsw_cp_t_exact` (migrated from `sw_dens`/`sw_cp`, 2026-09-08) + a ported thermal-conductivity term | `kt.m`/`thermometric_cond.m` (units corrected - see `docs/workflow/L2_calc_chi.md`) | Done (branch `chi_processing`; migrated to GSW/TEOS-10 and renamed/moved from `processing/scans/mod_scan_thermal_diffusivity.m` to `toolbox/seawater/ktemp.m` on branch `epsilon_processing`, 2026-09-08) |
| `modProcess_L2_qc.m` | QC flags: fom, accel, speed, pitch/roll | `mod_epsilometer_calc_turbulence_v2.m` lines ~473–526 | Not started |

### 6.5 L2 → L3

| Function | Description | Source |
|----------|-------------|--------|
| `modProcess_L3_grid_profiles.m` | Interpolate profiles onto standard P axis | `epsiProcess_gridProfiles.m` |

---

## 7. Twist Counting — Ana's First Project

**Status: Done, tested, and wired into the pipeline (2026-07-24, branch `l0_to_l1_conversion`)** - see the 2026-07-24 entry in `SESSION_LOG.md` for what shipped and what changed from Ana's original draft. The step-by-step tasklist and function signatures below are Ana's original scoping and are left as-is as a record of the assignment; the actual 2026-07-24 shipped filenames followed the repo's `MODprocess_`/`MODvis_` capital-MOD convention (Section 6.1's naming note) rather than the `modProcess_`/`modPlot_` names used below - `MODprocess_L1_add_twist.m`, `MODprocess_L1_accumulate_twist_timeseries.m`, `MODvis_twist_timeseries.m` (plotting functions live in `visualization/matlab/`, matching `MODvis_timeseries.m`). The first of those was renamed again, to `mod_L1_add_twist.m` in `processing/L1/`, on 2026-07-28 - see Section 6.2's current table for today's actual name.

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
3. **`toolbox/theoretical_spectra/batchelor_spectrum.m:68`** (correctness; moved from `processing/scans/` and renamed from `mod_scan_batchelor_spectrum.m`, both 2026-09-08, line number unchanged) - `kb = (epsilon/nu/ktemp^2)^(1/4)` has no guard against `epsilon <= 0`; produces a complex-valued spectrum instead of erroring, which `mod_scan_calc_chi_mle.m` then feeds into `chi2pdf` as a complex `z` (undefined behavior) with no warning.
4. **`processing/scans/mod_scan_calc_chi_mle.m:149`** (correctness) - when the direct-integration seed (`chi_seed`) is non-positive/non-finite, returns `chi_mle=NaN` but leaves `kc` at its already-computed valid value instead of also `NaN`, contradicting the function's own documented contract (and the `kc<=kmin` branch just above it, which does reset both).
5. **`processing/scans/mod_scan_calc_chi_mle.m:131`** (duplication) - re-derives `mod_scan_calc_chi_obs.m`'s entire preprocessing (deconvolve, find `kc`, restrict range, integrate for a seed) inline instead of reusing it, and `kmin = 3` cpm is hardcoded independently in both files - a caller needing both estimates (e.g. `analysis/chi_tau_mle_comparison.m`) redoes the noise-floor search and deconvolution twice, and a future `kmin` retune could silently land in only one of the two files.
6. **`toolbox/theoretical_spectra/batchelor_spectrum.m:78`** (correctness, latent; moved from `processing/scans/` and renamed from `mod_scan_batchelor_spectrum.m`, both 2026-09-08, line number unchanged) - the scalar-chi `reshape(Psg, size(k))` is a no-op since `k` was already overwritten to a column vector earlier in the function; not exercised by the current caller (always passes a vector of candidate chi values), but a future scalar-chi/row-vector-k caller would silently get the wrong orientation back.
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

Wiki: `MOD_fish_processing/docs/` (MkDocs Material, deployed to GitHub Pages via `.github/workflows/docs.yml` — see `SESSION_LOG.md`, 2026-07-09). Superseded the Notion wiki as the source of truth; pages live in-repo under `docs/workflow/` (what scripts do, how to run them), `docs/concepts/` (physics/math background), and `docs/visualization/` (catalog of the `MODvis_*`/`*App` interactive apps and `MODplot_*` diagnostic plots — what each one shows and how to call it).

**Standing rule:** any time a `MODvis_*`/`*App` or `MODplot_*` script is added or changed, update its entry in `docs/visualization/index.md` in the same change — an example image (regenerated if the script's output changed) plus a short description of how to use it. Don't let this drift out of sync with the code the way the rest of the wiki periodically has.

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
- [x] Add visualization section: `docs/visualization/index.md` catalogs MODvis_timeseries, MODvis_spectra, MODvis_twist_timeseries, SpectraExplorerApp, and the MODplot_* diagnostic scripts — moved `CHI_INSPECTOR_MANUAL.md` here from `docs/workflow/` (2026-09-25)
- [x] Add "From t1_volt to chi: a worked walkthrough" — `docs/concepts/temperature_to_chi_walkthrough.md`, narrative companion to `spectral_filtering_and_noise_floors.md` (filter shapes, real-data deconvolution walkthrough, Taylor's-hypothesis/gradient-Jacobian derivation, chi_obs vs chi_mle), adapted from exploratory notebook work in `mod_fish_lib`'s `temp_to_chi.ipynb`; new `plots/MODplot_fpo7_filters_explained.m` + image. A follow-up page (going backward through the filters, comparing a reconstructed spectrum against real bench-noise measurements) is planned separately (2026-09-28)

---

## 12. Session Log

Moved to [`SESSION_LOG.md`](SESSION_LOG.md) (2026-09-28). Reverse-chronological, append-only.
