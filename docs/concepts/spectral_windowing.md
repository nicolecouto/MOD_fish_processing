# Choosing fft_length, fft_segments_per_scan, and scan_overlap

Three `setup.yml` `spectral:` values control every spectrum this pipeline computes: `fft_length`, `fft_segments_per_scan`, `scan_overlap` (`MODsetup_metadata_field_registry.m`). They control two genuinely independent things, and mixing them up is the easiest way to get a design wrong:

- **`fft_length` and `fft_segments_per_scan`** decide how many Welch segments get averaged into *one* scan's spectrum - this is what sets the spectrum's statistical reliability (its degrees of freedom, `dof`), and, through `fft_length` alone, its frequency/wavenumber resolution.
- **`scan_overlap`** decides how many scans you get per profile and how much they overlap each other - this is a vertical-resolution/smoothing choice. It has no effect on any individual scan's `dof` or resolution.

See `mod_scan_get_spectra.m` (the first pair) and `mod_L2_tile_scans.m` (`scan_overlap`, and where `scan_length` actually gets used). `scan_length` and `dof` are never set directly - both are derived: `scan_length` from `fft_length`/`fft_segments_per_scan` (`processing/scans/mod_scan_length_from_segments.m`), `dof` from `fft_segments_per_scan` alone (`processing/scans/mod_scan_dof.m`) - the same way Rockland ODAS's `get_diss_odas.m` reports `dof_spec` as an output, never an input.

The Welch-segment overlap itself is hardcoded at 50% in code (`mod_scan_fft_seg_starts.m`) - not yaml-configurable at all. It used to be a tunable `fft_overlap` fraction, but the only value its `dof` formula is actually valid for is 0.5 (see below), so exposing it as "tunable" was misleading more than useful.

## The formulas

```
scan_length = fft_length * (fft_segments_per_scan + 1) / 2   (processing/scans/mod_scan_length_from_segments.m)
dof         = 1.9 * fft_segments_per_scan                     (Nuttall 1971, processing/scans/mod_scan_dof.m)

scan_step   = (1 - scan_overlap) * scan_length                (mod_L2_tile_scans.m)
```

`scan_length` comes out to an exact integer sample count whenever `fft_length` is even - true for any power of 2, which is also the recommended (not enforced) convention for `fft_length` itself, for FFT efficiency. Rockland ODAS doesn't hard-enforce power-of-2 either - their own `get_diss_odas.m` parameter validator only checks `isnumeric && isscalar && x>=2`.

ATOMIX's guidance (quoted in the design discussion that led to this page): *"the ratio of dissipation length to fft length... should never be less than 2, and a ratio of 5 or larger is highly desirable."* In today's terms that's `fft_segments_per_scan >= 3` (never less than) and `>= 9` (highly desirable) - `ratio = (fft_segments_per_scan+1)/2` if you want to translate back. Rockland ODAS enforces the floor in code (`get_diss_odas.m`: errors below `2*fft_length`) and recommends `>=3*fft_length` in comments (`fft_segments_per_scan >= 5`, `dof >= 9.5`).

**Important: `fft_segments_per_scan` does not affect frequency or wavenumber resolution.** That's set by `fft_length` alone (`df = Fs_epsi/fft_length` - more segments doesn't change the length of any individual segment). `fft_segments_per_scan` affects `dof`, and - because it also grows `scan_length` - the scan's physical footprint. Pick `fft_length` for the resolution you need; pick `fft_segments_per_scan` for the statistical reliability you need, then check the resulting `scan_length`'s footprint (next section) before shipping a config.

**Caveat:** the `1.9` factor is Nuttall's value specifically for 50%-overlapped Hamming segments - it's why the overlap is hardcoded rather than exposed as a tunable fraction, rather than the other way around.

## The other constraint: a scan shouldn't outgrow the instrument

`scan_length` in samples turns into a physical footprint via the platform's own fall speed:

```
scan_duration [s] = scan_length / Fs_epsi
scan_footprint [m] = scan_duration * fall_speed
```

A scan that spans more water column than the vehicle itself (roughly 2 m) is no longer safely assumed to be sampling one coherent patch of turbulence - it starts averaging over however much real structure the vehicle passed through in that time. Since raising `fft_segments_per_scan` raises `scan_length` (at fixed `fft_length`), the dof-vs-footprint tradeoff is direct: more `dof` costs more footprint, and that cost is worse at higher fall speed. This isn't enforced in code (no `instrument_length` field or runtime warning) - check it at design time against the reference table below when writing `setup.yml`.

For a concrete number: `epsi_mako`'s ASTRAL deployment (`Profile025.mat`) falls at a median 0.65 m/s (10th-90th percentile 0.62-0.67 m/s, occasional bursts to 1.26 m/s).

**Rockland's own default, for comparison:** their `quick_look.m` defaults to `fft_length=2 s`, `diss_length=4*fft_length=8 s` (`fft_segments_per_scan=7`, `dof=13.3`) - specified in time, converted to samples via each deployment's own fast sample rate at runtime (at a VMP/MicroRider `fs_fast` around 512 Hz, that's `fft_length~1024 samples`, `scan_length~4096 samples`). Their default footprint is *longer in time* (8 s) than any of this repo's previous defaults - a reminder that "the right answer" genuinely depends on the platform (VMP's own physical scale and typical fall speed aren't necessarily the same as the MOD fish's), not a single universal number.

## Reference table (Fs_epsi = 320 Hz)

| fft_length [samples] | df [Hz] | fft_segments_per_scan | scan_length [samples] | dof | scan duration [s] | max fall speed for a <=2 m scan [m/s] |
|---:|---:|---:|---:|---:|---:|---:|
| 256  | 1.250  | 3 | 512   | 5.7  | 1.60  | 1.250 |
| 256  | 1.250  | 5 | 768   | 9.5  | 2.40  | 0.833 |
| 256  | 1.250  | 7 | 1024  | 13.3 | 3.20  | 0.625 |
| 256  | 1.250  | 9 | 1280  | 17.1 | 4.00  | 0.500 |
| 512  | 0.625  | 3 | 1024  | 5.7  | 3.20  | 0.625 |
| 512  | 0.625  | 5 | 1536  | 9.5  | 4.80  | 0.417 |
| 512  | 0.625  | 7 | 2048  | 13.3 | 6.40  | 0.312 |
| 512  | 0.625  | 9 | 2560  | 17.1 | 8.00  | 0.250 |
| 1024 | 0.3125 | 3 | 2048  | 5.7  | 6.40  | 0.312 |
| 1024 | 0.3125 | 5 | 3072  | 9.5  | 9.60  | 0.208 |
| 1024 | 0.3125 | 7 | 4096  | 13.3 | 12.80 | 0.156 |
| 1024 | 0.3125 | 9 | 5120  | 17.1 | 16.00 | 0.125 |
| 2048 | 0.15625| 3 | 4096  | 5.7  | 12.80 | 0.156 |
| 2048 | 0.15625| 5 | 6144  | 9.5  | 19.20 | 0.104 |
| 2048 | 0.15625| 7 | 8192  | 13.3 | 25.60 | 0.078 |
| 2048 | 0.15625| 9 | 10240 | 17.1 | 32.00 | 0.062 |

(`df = Fs_epsi/fft_length`, the frequency-bin spacing - depends only on `fft_length`, same for every `fft_segments_per_scan` row at that `fft_length`. "max fall speed for a <=2 m scan" is `2/scan_duration` - above that speed, this row's footprint exceeds 2 m. Scale linearly for a different instrument length: multiply by `your_length_m/2`.)

For a ~0.65 m/s platform like the ASTRAL Mako above, `fft_length=1024` doesn't fit under 2 m at any `fft_segments_per_scan` in this table (best case, `fft_segments_per_scan=3`, is already 3.2 m). `fft_length=512` fits only at `fft_segments_per_scan=3` (2.08 m, right at the edge). `fft_length=256` has more headroom (1.56-2.08 m up to `fft_segments_per_scan=7`). This repo's current registry defaults are `fft_length=1024`/`fft_segments_per_scan=3` - a reasonable placeholder for now, but **check this table against your own platform's fall speed before relying on the defaults for a real deployment.**

`fft_length` also sets frequency resolution independently of all of this - pick the smallest `fft_length` that still resolves the wavenumbers `kmin_obs`/`kmin` (`MODsetup_metadata_field_registry.m`) actually need, then use the largest `fft_segments_per_scan` the footprint budget at your platform's fall speed allows.

## What this looks like

![Schematic: one scan split into Welch segments (fft_length chosen, fft_segments_per_scan chosen, scan_length computed) at the top, successive scans spaced along a profile by scan_overlap in the middle, and dof vs. fft_segments_per_scan at the fixed 50% overlap with ATOMIX's thresholds marked at the bottom](images/spectral_windowing_schematic.png)

Top and middle panels use an illustrative `fft_length=512`, `fft_segments_per_scan=3` (`scan_length=1024`, derived), `scan_overlap=50%` (not real data - generated for this page). Note the two panels' x-axes are unrelated in scale: the top panel's segments overlap *inside* one scan and set `dof`; the middle panel's scans overlap *across* the profile and set vertical resolution - moving one slider never moves the other.

`plots/MODplot_scans_and_segments.m` generates the same kind of figure on demand, from just `fft_length`/`scan_length`/`fall_speed` - no L1 file needed - to explore a candidate combination before committing it to `setup.yml`:

![Example MODplot_scans_and_segments.m output: five scans tiled at 50% overlap (top), each scan's Welch segments shown in shades of that scan's own color (middle), and the same scans converted to meters via fall_speed with the center scan's physical footprint and kmin printed (bottom)](images/scans_and_segments_example.png)

Same illustrative `fft_length=512`/`scan_length=1024`/`scan_overlap=50%` as above, plus `fall_speed=0.65 m/s` (median for `epsi_mako`'s ASTRAL deployment, see above) - the highlighted (3rd) scan spans 2.08 m, and `kmin = Fs_epsi/(fft_length*fall_speed) = 0.962 cpm`. See `MODplot_scan_context.m` for the equivalent diagnostic run against real data instead of just the parameters.

## CTD spectra: a different method, not just a different rate

Everything above is about `ctd.P`/`ctd.T`/`ctd.C`'s epsi neighbors (shear/fpo7/acc). CTD spectra (`mod_scan_get_spectra.m`) are computed by a genuinely different method, not the same Welch average scaled to a different `Fs`:

- **No interpolation onto the epsi grid, either direction.** Upsampling `ctd.P`/`.T`/`.C` to `Fs_epsi` before windowing would put fabricated spectral content above CTD's own Nyquist into the result - no interpolation method can recover real signal a slower sensor never sampled. Downsampling epsi to CTD's rate would defeat the entire purpose of epsi's high sample rate for the epsi channels. Instead, a scan's CTD spectrum comes from whichever native-rate CTD samples' timestamps actually fall inside that scan's time window - a time-based selection, not a value interpolation.
- **A single periodogram, not a Welch average.** At a typical `Fs_ctd` (16 Hz for SBE49, this registry's default), a several-second scan only contains on the order of 100 raw CTD samples - far too few to segment into `fft_segments_per_scan` overlapping pieces the way epsi does. So there is no `fft_segments_per_scan`/`dof` concept for CTD spectra at all: one periodogram per scan, no segments, no overlap. Don't assume a `ctd.P`/`.T`/`.C` spectrum carries the same statistical reliability (dof) as an epsi channel's spectrum at the same scan - it doesn't, by construction.
- **`Fs_ctd`** (`MODsetup_metadata_field_registry.m`) is the only CTD-specific spectral parameter - it sets the expected number of native samples per scan (`N_ctd`, derived from the scan's already-fixed duration), used as a fixed `periodogram` `nfft` so every scan's CTD frequency vector matches exactly, even though the actual raw sample count landing in any given scan's window can vary by a sample or two (CTD sampling doesn't line up with epsi scan boundaries).
- **`compute_spectra`** (`setup.yml`'s `ctd:` block, registered as `compute_ctd_spectra`) is an explicit, per-deployment boolean - not inferred from `vehicle_name`/`fish_flag`. Set `false` when a deployment's CTD telemetry has no fixed, scan-duration-relative sample rate, e.g. DeepSolo's ~60-120s irregular external pressure telemetry, where a scan window holds 0-1 native samples, not "a handful," so `Fs_ctd`/`N_ctd` would have no meaning. When `false`, this whole feature is skipped, `ctd.P` included, and `Fs_ctd` is never even asked for. A vehicle with a genuinely fixed-rate CTD (e.g. Wirewalker's onboard RBR Concerto) sets this `true` regardless of how its data arrives (onboard `$SB49`/`$SB41` stream vs. an independent CTD file, `MODprocess_read_external_ctd.m`) - the two are unrelated. On a deployment that DOES compute ctd spectra but only reports P (none exist yet, but nothing rules it out), `ctd.T`/`.C` being absent would still skip only those two channels, the same way an epsi channel absent from `scan.epsi` is skipped.
