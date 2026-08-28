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
- **Logged** - every rename is appended to `meta/filename_pad_log.csv`, a
  sibling of `raw_dir`.
- **Safe to call repeatedly** - a no-op on names that are already padded or
  aren't number-based (e.g. datetime-named files).
- **Console messages show a shortened path** (`MODutil_short_path.m`) -
  everything above the deployment directory's parent is dropped, e.g.
  `/Users/.../data_for_reorg/epsi_deepsolo/26_0520_ljc/raw` prints as
  `epsi_deepsolo/26_0520_ljc/raw`. Errors still show the full path.
- If a sibling `L0/` folder already has converted `.mat` files under the old
  names, those are renamed to match and their `raw_file_info.filename` field
  is updated, so `MODprocess_all_modraw_to_L0`'s already-converted check
  still recognizes them.

## Function

```matlab
n_renamed = MODsetup_pad_raw_filenames(raw_dir, Name, Value, ...)
```

| Argument | Required | Description |
|---|---|---|
| `raw_dir` | yes | Full path to a folder of raw data files |

Everything else is an optional Name-Value pair, in any order:

| Name | Default | Description |
|---|---|---|
| `raw_file_suffix` | auto-detected by `MODsetup_detect_raw_suffix.m` | e.g. `.modraw` |
| `L0_dir` | a sibling `L0` folder next to `raw_dir`, if it exists | Folder of converted `.mat` files to rename in step with the raw files |
| `force` | `false` | `true` to skip confirmation (dialog or prompt) entirely |
| `pad_width` | `0` (auto - see below) | Zero-pad to this many digits instead of the default. `0` also means "let me choose in the dialog/prompt" when running interactively |

Returns `n_renamed` - the number of raw files renamed (`0` if nothing needed
doing, the user declined, or MATLAB is running with `-batch` and `force`
wasn't set).

**Auto width (`pad_width=0`), per numeric prefix: if every file's trailing
number already has the same digit width, nothing is renamed.** Equal widths
already sort correctly regardless of how many digits that is - `modsom_00`
through `modsom_45` needs no padding, even though 2 digits is less than the
usual 3-digit floor. Only *actually mixed* widths (`modsom_1`, `modsom_2`,
..., `modsom_45`) get padded, to `max(3, widest number present)` so there's
room to grow before the next re-pad is needed. `pad_width` overrides this and
forces every file to the given width regardless of whether it was already
uniform.

If a deployment could grow past 999 files, run this once up front so the
width is settled before processing starts. Real-time acquisition always names
files by timestamp rather than a running number, so a fixed `pad_width` is
really only useful when post-processing a finished, unpadded numbered run.

### Confirmation: dialog, text prompt, or skipped

Unless `force` is set, confirmation happens one of three ways, picked
automatically:

1. **GUI dialog** (when a display is available, i.e. not `-batch` and
   `feature('ShowFigureWindows')` is true) - a small centered `uifigure`
   window. This is what you get if you'd otherwise be stuck at a terminal
   `y/n` prompt with no way to answer it (e.g. running MATLAB through an
   editor/IDE integration). Shows up to 3 example renames plus a count of
   the rest, and - if `pad_width` wasn't already fixed by the caller - a
   spinner to change the zero-padding digit count, with the preview updating
   live. **Rename**/**Cancel** buttons.
2. **Text prompt** (no display available, not `-batch`) - asks for the
   digit count first (if not fixed), then a plain `y/n` confirmation.
3. **Skipped, with a warning** (`-batch`) - neither kind of prompt can be
   answered non-interactively, so without `force=true` the function warns
   and renames nothing.

## Example

```matlab
raw_dir = '/Users/ncouto/Library/CloudStorage/Dropbox/SIO/projects/mod_fish_lib/data_for_reorg/epsi_on_wirewalker/25_0408_tlc_ww1_navo2/raw';
n_renamed = MODsetup_pad_raw_filenames(raw_dir, 'force', true)
```

```
MODsetup_pad_raw_filenames: 100 of 193 .modraw files in epsi_on_wirewalker/25_0408_tlc_ww1_navo2/raw need zero-padding, e.g.
    modsom_0.modraw -> modsom_000.modraw
    modsom_1.modraw -> modsom_001.modraw
    modsom_10.modraw -> modsom_010.modraw
    ... and 97 more
MODsetup_pad_raw_filenames: renamed 100 raw files - log: epsi_on_wirewalker/25_0408_tlc_ww1_navo2/meta/filename_pad_log.csv

n_renamed =

   100
```

Note only 100 of 193 files needed padding here: files `100`-`192` were
already 3 digits wide (equal to the pad width for this prefix) and so were
left untouched - only `modsom_0` through `modsom_99` (unpadded) were renamed.

Running the same call interactively (no `force`), with a display available,
pops the GUI dialog described above instead of renaming immediately.

**Called by:** `MODprocess_all_modraw_to_L0.m` (runs it after suffix
detection, so padding happens at the modraw → L0 step and everything
downstream sees sortable names), passing `raw_file_suffix` and `L0_dir`
through as Name-Value pairs.

**Calls:** `MODsetup_detect_raw_suffix.m`

## `meta/filename_pad_log.csv`

Written next to `raw_dir` (i.e. `fileparts(raw_dir)/meta/filename_pad_log.csv`),
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

Updated 2026-07-23: replaced the plain terminal `y/n` confirmation with a
GUI dialog (falling back to a text prompt when no display is available, or
skipping with a warning under `-batch`), and switched from positional
arguments to Name-Value pairs, adding `pad_width` as an explicit override for
the auto-computed digit count. See `PLAN.md` Session Log.

Updated 2026-07-24: fixed a bug where auto width always padded to at least 3
digits, even when a deployment's files already had a uniform (but smaller)
digit width - e.g. a 45-file deployment already named `modsom_00`..`modsom_45`
got needlessly renamed to `modsom_000`..`modsom_045`. Auto width now only
acts on genuinely mixed widths (`modsom_1`, `modsom_2`, ..., `modsom_45`) -
uniform widths are left alone, since they already sort correctly as-is. Also
fixed the GUI dialog/text prompt popping up even when nothing needed
renaming - the "would this actually change anything" check now runs before
any prompt, not after. And switched informational console messages to a
shortened path via the new `util/MODutil_short_path.m`. See `PLAN.md`
Session Log.
