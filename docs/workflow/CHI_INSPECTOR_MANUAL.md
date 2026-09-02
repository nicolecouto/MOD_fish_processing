# SpectraExplorerApp — Chi Inspector User Manual

`SpectraExplorerApp.m` browses `Profile*.mat` files and lets you click through profiles and depths
to inspect the temperature-gradient spectra behind each chi value. It was extended to surface the
diagnostics discussed in `MOD_fish_lib/CHI_PROCESSING_REVIEW.md` (Jim Moum's question about whether
some equatorial chi values are too high) so that reviewing spectra by eye is a normal part of using
this tool, not a separate one-off script per cast.

If a term below is unfamiliar, `CHI_PROCESSING_REVIEW.md` has the full derivation and code citations.
This manual just says what each panel/number *is* and what to look for.

---

## Starting it

```matlab
app = SpectraExplorerApp();                  % opens a folder chooser
app = SpectraExplorerApp('/path/to/profiles'); % or point it at a folder directly
```

Point it at a folder containing `Profile*.mat` files (i.e. `L2`/profiles output, not raw L0). Pick a
file from the list on the left; the app loads it, finds every scan with a valid data window, and
opens near the middle of the profile.

---

## Layout

```
+--------------------+---------------------------------------------------------+
| Choose Folder...    |  t1 profile | t1_volt(scan) | t1 Tg spectrum | chi1 profile |
| file list            |                                                          |
| ─ Depth Navigation ─ |  t2 profile | t2_volt(scan) | t2 Tg spectrum | chi2 profile |
| Prev / Next          |                                                          |
| Depth (m): [field]   |  ─────────────── kc vs depth ──── | ── noise match vs depth ──|
| Scan k / N            |                                                          |
| ─ Profile Diagnostics─|                                                          |
| [Scan Full Profile]   |                                                          |
| status                |                                                          |
| ┌─ info box ─────────┐|                                                          |
| │ chi/fom/kc numbers │|                                                          |
| └─────────────────────┘|                                                        |
+--------------------+---------------------------------------------------------+
```

- **Left column** ("t1/t2 profile"): the full voltage timeseries for this cast vs. depth, with the
  current scan's depth window shaded and marked with a dashed line.
- **Second column** ("t1/t2_volt (scan)"): the raw voltage timeseries *inside* the current scan
  window only, plotted vs. time.
- **Third column** ("t1/t2 Tg spectrum"): the main spectrum panel — see below.
- **Fourth column** ("chi1/chi2 profile"): `Profile.chi` (the raw, saved chi — the same value the
  processing pipeline writes) vs. depth for the whole cast, with the current depth marked.
- **Bottom strip**: whole-profile diagnostics, populated by the "Scan Full Profile" button (see
  below) — not computed automatically because it's expensive.

Use **Prev / Next**, type a depth into the **Depth (m)** field, or click a file in the list to
navigate. Every navigation action recomputes the spectrum for that depth (a few tenths of a second
per scan) and updates every panel.

---

## The spectrum panel (main thing you came here for)

Each spectrum panel (t1 or t2) shows, on a log-log frequency (Hz) vs. power axis:

| Line/marker | What it is |
|---|---|
| Dotted colored line | Raw observed temperature-gradient wavenumber spectrum, `Pt_Tg_k` |
| Solid colored line | Same spectrum, 15-point moving-average smoothed |
| Colored solid curves ("Batch s1t1", "Batch s2t1", ...) | Theoretical Batchelor spectrum shape using the **raw, saved chi** and each shear probe's epsilon (`epsilon_co.s1`/`.s2`) |
| Black dashed curve ("Batch (chi_mle)") | Same Batchelor shape, but using **chi_mle** (the maximum-likelihood fit) instead of raw chi, at `epsilon_final` |
| Black dash-dot curve ("Batch (chi_noise-sub)") | Same shape again, using chi computed with the **modeled noise spectrum subtracted first** (Ruddick et al. 2000, Eq. 9), at `epsilon_final` |
| Black dotted line ("noise") | The **modeled** electronic noise floor for this channel, converted into the same wavenumber-spectrum units as the observed spectrum |
| Gray dotted line ("3x adj. noise") | The rescaled noise model x 3 — this is literally the line the cutoff wavenumber is defined against (signal must clear 3x this to count as "signal") |
| Yellow pentagon | The cutoff wavenumber `kc` — where the pipeline stops integrating |
| Gray dotted vertical line labeled "kmin" | The lower integration bound, hardcoded at 3 cpm in `mod_efe_scan_chi.m` — nothing below this line is ever included in chi |

**What to look for:** if the dashed/dash-dot comparison curves sit noticeably below the solid
raw-chi curves, the raw (saved) chi is inflated relative to the noise-aware estimates — this is
the failure mode described in `CHI_PROCESSING_REVIEW.md` §1 and §5 (Fine et al. 2018 saw up to
1000x inflation from this exact effect). If the observed spectrum (dotted/solid colored line) sits
noticeably above or below the black "noise" line in the region approaching the yellow cutoff
marker, or the gray "3x adj. noise" line looks like a poor match to where the spectrum actually
flattens out, the noise model itself may not describe this scan — that's Matthew's question about
observed vs. modeled noise.

---

## The info box (numbers behind the plot)

For the currently-viewed scan, per channel:

```
--- chi1 (t1) ---
chi (raw, saved):  1.23e-08      <- what's actually in Profile.chi today
chi (noise-sub):   4.50e-09      <- same integral, noise subtracted first (Ruddick Eq. 9)
chi (MLE):         3.80e-09      <- maximum-likelihood Batchelor fit
fom / fom_mle:     0.90 / 0.85   <- figure of merit for each fit; flagged if > 1.15
kmin / kc (cpm):   3.0 / 42.3    <- integration bounds actually used
adjust_spec:       1.40          <- observed / modeled noise ratio; flagged if outside [0.1, 10]
```

- If `chi (raw, saved)` is much larger than `chi (noise-sub)` and `chi (MLE)`, that's a strong signal
  this particular scan's saved chi is noise-inflated.
- `fom`/`fom_mle`: lower is a better fit. The `<==` flag threshold (1.15) is not an official
  criterion — it's the one informal threshold already present (but unused) in
  `mod_efe_scan_chi.m`'s disabled debug figure. Treat it as "worth a second look," not "reject."
- `adjust_spec`: this is the number `FPO7_cutoff.m` uses to rescale the theoretical noise model to
  this scan's actual noise level before applying the cutoff. Close to 1 means the modeled noise
  floor (from `FPO7_notdiffnoise.mat`/`FPO7_noise.mat`) tracks this scan well. The `<==` flag range
  ([0.1, 10]) mirrors a check that exists in `FPO7_cutoff.m` but is commented out
  (`if adjust_spec>10 % warning(...)`) — again, a starting point, not a validated rule.

---

## "Scan Full Profile" — the whole-cast QC view

Clicking **Scan Full Profile** re-runs the spectrum computation at every valid depth in the loaded
cast (this is the expensive part — it can take from several seconds to a couple minutes depending
on profile length, hence it's not automatic) and populates the two bottom-strip axes:

- **Cutoff wavenumber vs. depth** (`kc1`, `kc2`): look for `kc` collapsing to unusually low values
  at particular depths (means very little of the spectrum was judged to be signal there — often
  because the modeled noise floor was too high for that scan) or pegging at the top of the range
  (fine, but check that's real signal and not the "no crossing found -> use highest frequency"
  fallback in `FPO7_cutoff.m`).
- **Noise-model match vs. depth** (`adjust_spec1`, `adjust_spec2`): the green shaded band is
  `adjust_spec` within `[0.1, 10]` (same informal band as the info box). Depths where the trace
  leaves the band are exactly the depths where "does the observed noise match the modeled noise"
  (Matthew's question) has a "no" answer, and are the depths worth pulling up individually and
  looking at the spectrum panel for.

Once this has run, the **chi1/chi2 profile** panels (top-right) also gain a dotted `chi_mle` line
so you can compare the raw/saved chi profile against the MLE profile depth-by-depth for the whole
cast, not just the current scan.

The result is cached per file — switching depth within the same file doesn't recompute it, but
loading a different file clears the cache and you'll need to click the button again.

---

## Known caveats of the app itself

- `patchCalibrationPaths()` injects hardcoded fallback FPO7 noise coefficients and forces
  `Meta_Data.PROCESS.adjustTemp = true` so the app doesn't need machine-specific calibration paths.
  This means the app may not be using the *exact* noise model a given deployment's real processing
  run used — if you need to confirm against a specific deployment's actual `FPO7_noise.mat`, check
  `Meta_Data.paths.calibrations.fpo7` on that machine separately.
- The three chi estimates (raw, noise-subtracted, MLE) let you compare methodologies but this app
  does **not** change what gets saved to `Profile.chi` — it's read-only / diagnostic. Any fix based
  on what you see here still needs to happen in `mod_efe_scan_chi.m` / the processing pipeline.
- "Scan Full Profile" calls `get_scan_spectra` once per depth, i.e. it repeats the full per-scan
  computation (spectra, epsilon, chi, MLE fit) for every valid scan in the cast. On long profiles
  this is slow by design — it's meant for occasional QC passes, not routine navigation.

## See also

- `MOD_fish_lib/CHI_PROCESSING_REVIEW.md` — the full pipeline trace, the comparison against Oakey
  (1982) / Ruddick et al. (2000) / Fine et al. (2018), and the reasoning behind every diagnostic in
  this app.
