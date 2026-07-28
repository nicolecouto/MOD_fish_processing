# MOD Fish Processing

Documentation for `MOD_fish_processing` - the data processing pipeline for MOD profiling fish instruments (EPSI, FastCTD, wirewalker deployments).

This site has two kinds of pages:

- **[Workflow](workflow/L0_modraw_conversion.md)** - what each script does and how to run it, organized by data level (L0 -> L1 -> L2 -> L3) and by use case.
- **[Concepts](concepts/index.md)** - the physics and math behind the processing: calculating epsilon from shear, picking out profiles, figure of merit, noise spectra, and related background.

For the current state of the refactor, active tasks, and the session-by-session log of what's been built, see `PLAN.md` at the repo root.

## Requirements

- **MATLAB R2019b or newer** - Some scripts use an `arguments` block with validation functions, which R2019b introduced.
- **Signal Processing Toolbox** - `pwelch` is used for several spectral calculations.
- **Statistics and Machine Learning Toolbox** - `mod_scan_calc_chi_mle.m` uses `chi2pdf` for its Batchelor-spectrum MLE fit (see [FP07 calibration and chi](workflow/L2_calc_chi.md)).
- No other MathWorks toolboxes required. YAML reading (`YAMLMatlab_0.4.3`) and physical-unit conversions (CSIRO `seawater`) are vendored in `toolbox/` - just `addpath` it, no separate install (see [L0 -> L1 conversion](workflow/L0_to_L1_conversion.md)).
