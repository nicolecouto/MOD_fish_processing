# Zero-padding numbered raw filenames

**Status:** working, tested against real deployment files.

## What this does

Some deployments name raw files with a bare incrementing number instead of a
timestamp (`modsom_0.modraw`, `modsom_1.modraw`, ... `modsom_192.modraw`).
Alphabetical listings sort those lexically, not numerically, so
`modsom_10.modraw` sorts before `modsom_2.modraw` - every folder listing,
and anything downstream that relies on sorted order, comes out scrambled.

`MODsetup_pad_raw_filenames.m` fixes this by renaming the files in place to a
zero-padded width (`modsom_000.modraw`, `modsom_001.modraw`, ...,
`modsom_192.modraw`), so alphabetical order matches chronological order.

- **Rename only** - file contents are never read or written, only the
  directory entry changes (`movefile`).
- **Verified** - after each rename, the new file's byte count is checked
  against the original; a mismatch aborts with an error.
- **Logged** - every rename is appended to `meta/FilenamePadLog.csv`, a
  sibling of `raw_dir`.
- **Safe to call repeatedly** - a no-op on names that are already padded or
  aren't number-based (e.g. datetime-named files).
- If a sibling `L0/` folder already has converted `.mat` files under the old
  names, those are renamed to match and their `raw_file_info.filename` field
  is updated, so `MODprocess_all_modraw_to_L0`'s already-converted check
  still recognizes them.

## Function

```matlab
n_renamed = MODsetup_pad_raw_filenames(raw_dir, raw_file_suffix, L0_dir, force)
```

| Argument | Required | Description |
|---|---|---|
| `raw_dir` | yes | Full path to a folder of raw data files |
| `raw_file_suffix` | no | e.g. `.modraw`. Default: auto-detected by `MODsetup_detect_raw_suffix.m` |
| `L0_dir` | no | Folder of converted `.mat` files to rename in step with the raw files. Default: a sibling `L0/` folder next to `raw_dir`, if it exists |
| `force` | no | `true` to skip the confirmation prompt. Default: `false` |

Returns `n_renamed` - the number of raw files renamed (`0` if nothing needed
doing, the user declined, or MATLAB is running with `-batch` and `force`
wasn't set).

Pad width is `max(3, widest number already present)`, computed separately
per numeric filename prefix. If a deployment could grow past 999 files, run
this once up front so the width is settled before processing starts.

In non-interactive MATLAB (`-batch`), the confirmation prompt can't be
answered, so without `force=true` the function warns and does nothing rather
than renaming files unprompted.

**Called by:** `MODprocess_all_modraw_to_L0.m` (runs it after suffix
detection, so padding happens at the modraw → L0 step and everything
downstream sees sortable names).

**Calls:** `MODsetup_detect_raw_suffix.m`

## Example

```matlab
raw_dir = '/Users/ncouto/Library/CloudStorage/Dropbox/SIO/projects/mod_fish_lib/data_for_reorg/epsi_on_wirewalker/25_0408_tlc_ww1_navo2/raw';
n_renamed = MODsetup_pad_raw_filenames(raw_dir)
```

```
MODsetup_pad_raw_filenames: 100 of 193 .modraw files in /Users/ncouto/Library/CloudStorage/Dropbox/SIO/projects/mod_fish_lib/data_for_reorg/epsi_on_wirewalker/25_0408_tlc_ww1_navo2/raw need zero-padding, e.g.
    modsom_0.modraw -> modsom_000.modraw
    modsom_1.modraw -> modsom_001.modraw
    modsom_10.modraw -> modsom_010.modraw
    ... and 97 more
Rename these files in place? (contents untouched, log written to meta/FilenamePadLog.csv) y/n: y
MODsetup_pad_raw_filenames: renamed 100 raw files - log: /Users/ncouto/Library/CloudStorage/Dropbox/SIO/projects/mod_fish_lib/data_for_reorg/epsi_on_wirewalker/25_0408_tlc_ww1_navo2/meta/FilenamePadLog.csv

n_renamed =

   100
```

Note only 100 of 193 files needed padding here: files `100`-`192` were
already 3 digits wide (equal to the pad width for this prefix) and so were
left untouched - only `modsom_0` through `modsom_99` (unpadded) were renamed.

## `meta/FilenamePadLog.csv`

Written next to `raw_dir` (i.e. `fileparts(raw_dir)/meta/FilenamePadLog.csv`),
appended to across runs. One header comment line, one CSV header, then one
row per rename:

```
# MODsetup_pad_raw_filenames rename log - files renamed in place, contents untouched
datetime_utc,folder,old_name,new_name
2026-07-08T22:14:03Z,raw,modsom_0.modraw,modsom_000.modraw
2026-07-08T22:14:03Z,raw,modsom_1.modraw,modsom_001.modraw
2026-07-08T22:14:03Z,raw,modsom_10.modraw,modsom_010.modraw
...
2026-07-08T22:14:04Z,L0,modsom_0.mat,modsom_000.mat
2026-07-08T22:14:04Z,L0,modsom_1.mat,modsom_001.mat
...
```

| Column | Meaning |
|---|---|
| `datetime_utc` | Timestamp of the run that performed the rename (one timestamp per call, shared by all rows from that call) |
| `folder` | `raw` or `L0`, depending on which file was renamed |
| `old_name` | Original filename (with extension) |
| `new_name` | Padded filename (with extension) |

## Safety checks

- **Duplicate targets:** errors before renaming anything if two old names
  would collapse onto the same padded name (e.g. `modsom_1` and `modsom_001`
  both existing already) - resolve by hand first.
- **Existing target:** errors if a padded name already exists as a separate
  file that isn't part of the rename set, rather than overwriting it.
- **Byte-count verification:** each rename is checked immediately after
  `movefile`; a mismatch aborts with an error (check the log to see how far
  it got).

## History

Added 2026-07-08 to fix sort order in deployments with numbered (not
datetime-named) raw files - see `PLAN.md` Session Log entry "Zero-pad
numbered raw filenames."
