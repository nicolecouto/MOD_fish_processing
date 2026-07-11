# L0 → L1: Converting raw counts to physical units

**Status:** working, tested against real deployment files. Second step of the `MOD_fish_lib` → `MOD_fish_processing` reorganization (see `PLAN.md` at the repo root). Built on branch `l0_to_l1_conversion`.

## What this step does

Takes an L0 `.mat` file (raw counts/hex, no calibrations - see [L0: converting .modraw to .mat](L0_modraw_conversion.md)) and converts it to physical units:

- **epsi** - AFE channel counts → volts (thermistor/shear channels) or g (accelerometer channels)
- **ctd** - raw hex → pressure [dbar], temperature [°C], conductivity [mS/cm], salinity [psu], plus derived potential temperature, potential density, `dP/dt`, depth, `dz/dt`
- **alt**, **isap** - raw distance → height above bottom (`hab`)

Every other field (`gps`, `vnav`, `seg`, `spec`, `avgspec`, `dissrate`, `apf`, `fluor`, `ttv`) passes through unchanged.

Doing this requires a deployment configuration - which physical sensor is on which AFE channel, what its full-scale voltage range is, which CTD calibration coefficients apply - so this is also where a `setup.yml` file first enters the pipeline (see PLAN.md Section 2 for the metadata design).

Explicitly **not** done at this step (still open - see PLAN.md Section 6.2 and Section 7):
- No shear probe Sv calibration (shear channels stay as volts, not `1/s`)
- No FPO7 dT/dV calibration
- No despiking
- No SOM instrument transfer function filters
- No `twist` field (cable twist counting - Ana's project)

## Functions

### `MODsetup_read_yaml.m`

```matlab
metadata = MODsetup_read_yaml(setup_yml)
```

Reads a deployment's `setup.yml` and returns a `metadata` struct:

| Field | Contents |
|---|---|
| `paths.data_root`, `.raw`, `.L0`, `.L1`, `.meta`, `.calibrations_root` | Derived fresh from `setup.yml`'s `data_root` field - **never saved to disk**, since paths are machine-specific |
| `fish_flag` | `'FCTD'` or `'EPSI'` - selects which `altimeter` geometry block in the yaml applies |
| `PROCESS.latitude` | Used for `ctd.z` (depth from pressure) when a file has no GPS fix |
| `PROCESS.channels` | AFE channel names in ADC slot order, e.g. `{'t1','t2','s1','s2','a1','a2','a3'}` |
| `AFE.(channel).full_range`, `.ADCconf`, `.type` | Per channel, from `setup.yml`'s `afe.channels` block |
| `CTD.name`, `.SN`, `.sample_per_record` | From `setup.yml`'s `ctd` and `sn.ctd` |
| `CTD.cal` | SBE calibration coefficients, read from `calibrations_root/SBECAL/<SN>.CAL` (the `MOD_fish_calibrations` repo) |
| `GEOMETRY.alt_angle_deg`, `.alt_dist_from_crashguard_ft`, `.alt_probe_dist_from_crashguard_in` | Altimeter mount geometry, from `setup.yml`'s `altimeter.fctd` or `altimeter.epsi` block (picked by `fish_flag`) |

Also saves `metadata.mat` into `meta/` alongside `setup.yml` - a portable deployment record with `paths` stripped out, so it means the same thing on any machine. Re-derive `metadata.paths` by calling `MODsetup_read_yaml` again rather than trusting a stale `metadata.mat`.

Deliberately minimal: it only resolves the fields this L0→L1 step actually uses. It does not yet build the full `metadata.manifest` (`shear_channels`, `fpo7_channels`, etc. from PLAN.md Section 5) or read `optional_sensors` - nothing downstream needs those yet. Add fields as later steps need them, not preemptively.

**`setup.yml` only needs to declare what this step uses** - see `data_for_reorg/epsi_mako_w_fluor/25_0408_d03_mako1_canyonhead/meta/setup.yml` for a real minimal example:

```yaml
data_root: /path/to/deployment          # only path in the file - everything else derives from it
calibrations_root: /path/to/MOD_fish_calibrations

fish_flag: FCTD
latitude: 32.8

sn:
  ctd: '0674'

ctd:
  type: S49
  sample_per_record: 2

afe:
  channels:                              # in ADC slot order
    t1: {type: fpo7,  full_range: 2.5, ADCconf: Unipolar}
    t2: {type: fpo7,  full_range: 2.5, ADCconf: Unipolar}
    s1: {type: shear, full_range: 2.5, ADCconf: Bipolar}
    s2: {type: shear, full_range: 2.5, ADCconf: Bipolar}
    a1: {type: acc,   full_range: 1.8, ADCconf: Unipolar}
    a2: {type: acc,   full_range: 1.8, ADCconf: Unipolar}
    a3: {type: acc,   full_range: 1.8, ADCconf: Unipolar}

altimeter:
  fctd:
    angle_deg: 45
    dist_from_crashguard_ft: 4
    probe_dist_from_crashguard_in: 0
```

MATLAB has no built-in YAML reader (checked in R2024b: no `yaml.*` namespace, `readstruct` only accepts `'json'`/`'xml'`/`'auto'` as `FileType`), so `MODsetup_read_yaml.m` uses the vendored third-party `toolbox/YAMLMatlab_0.4.3/` (MIT licensed).

### `MODprocess_single_L0_to_L1.m`

```matlab
data = MODprocess_single_L0_to_L1(L0_data, metadata)
```

Pure transformation - takes an L0 struct and a `metadata` struct, returns the same fields with `epsi`/`ctd`/`alt`/`isap` converted to physical units. No file I/O.

The three conversion steps (`convert_efe_channels`, `calibrate_ctd`, `calibrate_altimeter_hab`) live as **local subfunctions inside this file**, not as separate `modProcess_L1_apply_*.m` files - nothing calls them standalone today. Split one out the moment something else needs to call it directly.

Notes on the CTD conversion specifically:
- SBE49 "eng" format (raw hex counts) goes through the full SBE calibration polynomials (temperature, pressure, conductivity), then salinity via `sw_salt`.
- SBE41 "PTS" format arrives from L0 already as ASCII-parsed P/T/S (conductivity left `NaN`) - no calibration equations needed, only the derived fields below.
- `th` (potential temperature), `sgth` (potential density), `dPdt`, `z` (depth), `dzdt` are computed for both formats, using the CSIRO `seawater` toolbox (vendored at `toolbox/seawater/`).
- Depth (`z`) needs a latitude: interpolated from `data.gps.latitude` if the file has GPS fixes, otherwise falls back to `metadata.PROCESS.latitude` from `setup.yml`.

`calibrate_altimeter_hab` uses the same `GEOMETRY` fields for both `alt` (the MOD altimeter) and `isap` (ISA500) - inherited as-is from the source function, which assumed the same mount geometry for both. Verified against real `isap` data; no `data_for_reorg` deployment has `alt` data yet, so that path is untested.

### `MODprocess_all_L0_to_L1.m`

```matlab
L1_files = MODprocess_all_L0_to_L1(L0_dir, metadata, L1_dir, reprocess_all)
```

Orchestrator: loops over every `.mat` file in `L0_dir`, calls `MODprocess_single_L0_to_L1` on each, saves one `.mat` per L0 file into `L1_dir`. `L1_dir` is optional - defaults to a sibling `L1/` folder next to `L0_dir` (created if it doesn't exist). `metadata` should be read once per session with `MODsetup_read_yaml` and passed in, not re-read per file.

Skips a file if its L1 `.mat` already exists and is newer than the L0 file it came from - except the most recently modified L0 file, which is always reprocessed (mirrors `MODprocess_all_modraw_to_L0.m`'s same rule one level up, in case the raw file behind it was still being written when L0 last ran). Pass `reprocess_all = true` to force every file to redo regardless.

## How to run it

```matlab
addpath('/path/to/MOD_fish_processing/processing');
addpath('/path/to/MOD_fish_processing/setup');
addpath('/path/to/MOD_fish_processing/toolbox');   % YAMLMatlab_0.4.3, seawater

metadata = MODsetup_read_yaml('/path/to/deployment/meta/setup.yml');

% L0 must already exist - see L0_modraw_conversion.md
L1_files = MODprocess_all_L0_to_L1(metadata.paths.L0, metadata, metadata.paths.L1);
```

To process a single file directly:

```matlab
L0_data = load('/path/to/deployment/L0/EPSI25_04_08_150323.mat');
data = MODprocess_single_L0_to_L1(L0_data, metadata);
figure; plot(data.ctd.dnum, data.ctd.T);      % calibrated temperature
figure; plot(data.epsi.time_s, data.epsi.s1_volt);  % shear channel, volts
```

## Known limitations / things to check

- **The `alt.hab` path is untested against real data.** Every `data_for_reorg` deployment tested so far uses `isap` (ISA500) rather than the MOD altimeter (`alt`), so `calibrate_altimeter_hab` has only been exercised on `isap`. The math is the same for both, but confirm against a real `alt` deployment before trusting it.
- **`isap.dst` pegs at a flat maximum value (120, in the one deployment tested) when the target is out of range** - not a bug, but don't mistake a flatlined `isap.hab` for a real constant range to bottom.
- **Depth/salinity near zero at the start of a deployment is expected, not a bug.** The first raw file of a cast is often recorded on deck with the CTD in air - conductivity ≈ 0 gives salinity ≈ 0 via `sw_salt`, and pressure ≈ 0 gives depth ≈ 0. This resolves once the instrument is in the water.

## History

Ported from `mod_som_read_epsi_files_v4.m` in the old `MOD_fish_lib` monolith - specifically the physical-conversion half of that function (the raw-parsing half became `MODprocess_single_modraw_to_L0.m` in the L0 step). Built on branch `l0_to_l1_conversion`:

- Added `MODsetup_read_yaml.m` as the first piece of yaml-driven `metadata`, per PLAN.md Section 2 - deliberately scoped to only what this step needs, growing incrementally rather than building the full metadata schema up front.
- Vendored `YAMLMatlab_0.4.3` (no built-in MATLAB YAML reader) and the CSIRO `seawater` toolbox (for `sw_salt`/`sw_ptmp`/`sw_pden`/`sw_dpth`) into `toolbox/`.
- Fixed a latent bug found in `MODprocess_single_modraw_to_L0.m` while porting the altimeter logic: it called `orderfields(alt, {..., 'hab'})` but never set `alt.hab` - `hab` needs instrument geometry that L0 deliberately doesn't have. Would have thrown a hard error on any deployment with `alt` data; none of the four `data_for_reorg` deployments tested so far have any, so it was never hit until now. `hab` is now correctly computed here instead, for both `alt` and `isap`.
- Renamed `MODprocess_new_modraw_to_L0.m` → `MODprocess_all_modraw_to_L0.m` so the L0 and L1 batch orchestrators share the same `MODprocess_all_*` naming pattern.
- Tested against all 96 files of `epsi_mako_w_fluor/25_0408_d03_mako1_canyonhead` - see PLAN.md Session Log (2026-07-09) for full results.
