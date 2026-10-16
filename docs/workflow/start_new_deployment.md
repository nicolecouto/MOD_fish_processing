# Start New Deployment: Setup and dev1_setup.yml

**Status:** working, tested in a scratchpad sandbox (all vehicle presets; window driven end
to end; `dev1_setup.yml` read by `MODsetup_read_yaml.m` and run through modraw → L0 → L1).

`acquisition/start_new_deployment.py` opens a window for starting a
deployment: pick the vehicle (most fields fill in from its preset), set what
is on each AFE slot and its serial number, and build the survey name. **Create
Setup** shows the changes, then:

- backs up the current `Setup` as `Setup_replaced_YYYYMMDDHHMMSS` and writes
  the new one next to `fctd_epsi`, then reads it back the way `fctd_epsi`
  does to check every value,
- writes `<processed_root>/<survey>/meta/dev1_setup.yml` for MOD_fish_processing
  (see [dev1_setup.yml](#dev1_setupyml) below; all 7 AFE slots with names, types and serial numbers; an existing one is
  kept as `dev1_setup.yml.replaced_*`),
- appends a row to the cruise `deployment_log.csv`.

`fctd_epsi` only reads `Setup` when it starts, so restart it afterwards.

The window warns if the vehicle name and fish type disagree (MAKO or EPSI
in the name with FCTD selected, or FCTD in the name with EPSI selected).

**Winch spool** names the spool on the winch. There's one winch with one
spool on it at a time, and every vehicle uses it, so this isn't per vehicle:
the window fills in the spool used at the last Create Setup, whatever the
vehicle was. Change it only when the spool is changed - the window then warns
that the twist count restarts from 0 at this deployment. It's written to
`dev1_setup.yml` (`winch_spool:`) and the deployment log (not to `Setup` -
`fctd_epsi` doesn't use it), and the window warns if it's empty.

When the spool differs from the last row of the cruise
`<processed root>/spool_swap_log.csv` (or that file doesn't exist yet), Create
Setup appends a row to it: the UTC time, the spool, and a note. That log, not
the window's memory, is what the next Create Setup compares against. Add a row
by hand for a spool changed in the middle of a deployment (columns
`datetime_utc` as `yyyy-MM-ddTHH:mm:ssZ`, `spool_id`, `spool_length_m`,
`notes`). Processing checks the log against the `dev1_setup.yml` files
(`MODprocess_find_spool_swaps.m`), so losing either one doesn't lose a change.

If `deployment_log.csv` already exists with different columns (e.g. one
written before the winch_spool column), it's set aside as
`deployment_log_old_columns.csv` and a new log is started, so rows never end
up under the wrong headers. The Create Setup message says when this happens.

**Advanced settings** (ports, network, CTD data, raw files, calibration
paths, and where `dev1_setup.yml` and the deployment log go) default to
`config.yml`. Changes there apply to that window only - edit `config.yml`
to change them for good.

Raw file names start with the fish type - `EPSI...` for a Mako, `FCTD...`
for an FCTD - so the prefix can't be left on the wrong one.

**Create Setup** also saves what you entered for that vehicle, so picking
the vehicle next time fills in the same probes, CTD and pressure case. Every
serial number used is also added to that sensor type's dropdown.
The window opens filled in from the current `Setup` (or the first vehicle
preset if there isn't one), and warns if the survey date isn't today or the
survey name is the same as in the current `Setup`, so an old survey name
doesn't get reused by accident. Missing shear probe calibrations get a
warning; missing FP07 ones don't (they aren't normally used). **Load current Setup** fills
the window from the `Setup` again - it doesn't write or save anything.

## Setting it up on the acquisition Mac

1. Needs `python3` with tkinter (python.org or miniconda; nothing to pip
   install).
2. Edit `acquisition/config.yml` once per cruise: where `fctd_epsi`/`Setup`
   live, the calibrations folder, where processed data and the deployment log
   go, and the deck hardware shared by every vehicle (serial ports, baud
   rates, raw data folder). Use network paths (`/Volumes/DEV1_HD/...`,
   `/Volumes/DEV3_HD/...`) so they're the same from every computer.
3. Set up the **calibrations folder**: a clone of the MOD_fish_calibrations
   repo next to the software on DEV1,
   `/Volumes/DEV1_HD/Users/Shared/Software_current_cruise/MOD_fish_calibrations`
   (`calibrations_root` in `config.yml`). Cal files are kept up to date there
   with `git pull`, separately from the code. `fctd_epsi` (DEV1) and processing
   (DEV3, over the network at the same path) read the same files:
   - `SBE/<SN>.CAL` - CTD
   - `SHEAR_PROBES/<SN>/Calibration_<SN>.txt` - shear probes
   - `FPO7/<SN>/Calibration_<SN>.txt` - FP07 probes
   - `SHEAR/cap1nFres200Meg_5KohmInput.mat` - shear charge-amp response
     (processing only; without it epsilon has no electronics correction)

   `Setup` gets `<folder>/SBE`, `<folder>/SHEAR_PROBES` and `<folder>/FPO7`
   (`fctd_epsi` looks up slots 1-2 in FPO7 and 3-4 in SHEAR_PROBES, and
   records N/A for any probe file it can't find); `dev1_setup.yml` gets
   `calibrations_root: <folder>`. The same subfolders fill the serial number
   lists. The CTD path in `Setup` used to be `MOD_fish_lib/Acquisition/SBECAL`;
   MOD_fish_calibrations' `SBE/` has the same ten `.CAL` files with the same
   coefficients (checked 2026-10-15: only letter case, line endings and number
   formatting differ, plus one more digit on 0536's PTEMPA0), so moving to it
   changes no CTD calibration.
4. Check `acquisition/presets/*.yml` - one per vehicle (MAKO1-3, FCTD1-3:
   fish type, pressure case, CTD, default AFE slot layout). MAKO2 and MAKO3
   have no serial numbers yet - the window asks for them the first time. A
   vehicle can also be typed into the Vehicle box; it's remembered (and added
   to the list) after its first Create Setup. To give it defaults from the
   start, copy a preset file. The
   window remembers the last-used probes per vehicle in
   `acquisition/last_used.json`.
5. Make an alias of `acquisition/Start New Deployment.command` on the
   Desktop and double-click it.
6. Check each computer (DEV1 and DEV3) with
   `bash acquisition/check_software/check_ship_setup.sh`. It only reads (apart
   from a `git fetch`) and prints OK, FIX or note for: the clone's branch,
   remotes and whether it is up to date with GitHub; the `config.yml` folders;
   the MOD_fish_calibrations clone and the files processing needs; what is in
   the processed-data folder (`cruise_meta_data.yml`, `RAW_full_cruise`,
   `spool_swap_log.csv`, a leftover `realtime/worker.lock`); and python3 with
   tkinter and matlab. Give it the clone's path if it isn't run from the clone.

## AFE slots

Slots 1-4 each take FP07, shear, fluorometer, microconductivity or none;
slots 5-7 are always the accelerometers a1-a3. Names follow slot order (t1/t2,
s1/s2, f1, c1). An empty slot is written as serial number `000` in `Setup`
and keeps its standard name with `type: none` in dev1_setup.yml, so slot positions
never shift. `Setup` also records each slot's type (`CTD.chN_type`), which
`fctd_epsi` ignores but copies into every `.modraw` header.

## Rules `Setup` has to follow

From `fctd_epsi`'s source (`main.c` ReadSetupFile, `file_utils.c`,
`ctd.h`, `fctd_epsi.c`); the window enforces all of them:

- No empty value for any key `fctd_epsi` reads (`KEY=''` makes it segfault -
  why the earlier `convert_yaml_to_setup.py` output crashed it).
- Values can't contain spaces, `'`, `,`, `=`, `#` or `//`.
- Names (survey, vehicle, probe serial numbers, ports, ...) are at most 31
  characters - longer ones silently run into the next field.
- The whole file must stay under ~2000 bytes (it is copied into every
  `.modraw` header through a fixed-size buffer). So `Setup` has a single
  comment line - when and how it was written - and no section notes.
- Keys `fctd_epsi` never reads (`CTD.MicroCond`, `CTD.Compass`,
  `CTD.output_format`, `CTD.ch1-4_type`) are still written: they end up in
  every `.modraw` header, so a raw file says what was on each slot.

## dev1_setup.yml

`dev1_setup.yml` is written on DEV1 when the deployment starts, from the same values
`fctd_epsi` records into every `.modraw` header. It is the **first piece** of the processing
metadata, not all of it: it says what is on the vehicle (`data_root`, `calibrations_root`,
survey/cruise/vehicle, `fish_flag`, `instrument_manifest` with CTD and AFE slot SNs, and
`afe.channels` full range/ADC config). It has no processing parameters (`spectral:`, `chi:`,
`epsilon:` ...): those come from `cruise_meta_data.yml`, and `MODsetup_build_yaml.m` merges the
two into a processing run's yml, `meta/meta_data_<run>.yml`, the file processing reads (see
[Processing data](processing_data.md)). Its `data_root` is the ship's path, kept as a record:
processing takes every path from where the run yml is, so a copied survey folder works anywhere.

Processing reads the run yml built from it:

```matlab
metadata = MODsetup_read_yaml('/Volumes/DEV3_HD/.../Processed/<survey>/meta/meta_data_realtime.yml');
```

(`MODsetup_read_yaml` can read `dev1_setup.yml` itself too, but then it takes its paths from
`data_root`, the old layout.)

`vehicle_name` is the unit (`MAKO1`, `FCTD3`, ...). The shared altimeter geometry table
(`setup/platform_instrument_geometry.yml`) matches it ignoring case, falling back to the family
(`MAKO1` → `Mako`) - see [L0 → L1](L0_to_L1_conversion.md).

## History

**2026-10-15 - dev1_setup.yml feeds processing runs** (branch `main-fork`). Processing now builds one yml per processing run from `dev1_setup.yml` (`meta/meta_data_<run>.yml`, see [Processing data](processing_data.md)) and takes every path from where that yml is, so `data_root` here is kept as a record of the ship's path. No change to the window or the files it writes.

**2026-10-15 - Ship setup check** (branch `main-fork`). Added
`acquisition/check_software/check_ship_setup.sh` (setup step 6). Tested on the laptop clone
(git checks pass; ship paths reported as FIX since DEV1/DEV3 aren't mounted there), run from
inside and outside the clone.

**2026-10-14 (later) - Winch spool field; one comment line in Setup** (branch `main-fork`). Added
the Winch spool box (one spool for every vehicle: carried over from the last Create Setup, not
per vehicle; `winch_spool:` in `dev1_setup.yml`; a `winch_spool` column in the deployment log;
warning when empty, and when it changes, since the twist count restarts there). Setup's
section-note comment lines removed, leaving one provenance line. Tested in a scratchpad sandbox:
Setup round-trips through the fctd_epsi tokenizer (`check_roundtrip`), 1463 bytes for MAKO1.

**2026-10-14 - Brought onto `main-fork` from `modvis_export`** (commits 784b06d..6b04bc3,
copied as files - the two branches share no history). The processing yml the window writes was
renamed `setup.yml` → `dev1_setup.yml` (and its deployment-log column `processing_yml` →
`dev1_setup_yml`) so it's clear it was made on board at deployment start. Tested in a
scratchpad sandbox with a sandbox `config.yml` and a copy of `MOD_fish_calibrations`:
`write_all` for every preset (MAKO2/MAKO3 correctly refused - no pressure case or CTD SN
yet), Setup round-trips, backups and `.replaced_*` copies made on rewrite; the window opened
from the current Setup and Create Setup → Write Setup wrote all three outputs;
`MODsetup_read_yaml` on MAKO1/FCTD1/FCTD3 files gave channels in slot order, shear and CTD
cals loaded, altimeter geometry filled.
