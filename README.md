# MOD_fish_processing
Data processing pipeline and field commands for MOD profiling fish


visualization
    MODvis_timeseries.m - plots time series from a directory of L0, L1, L2, or Profile .mat files (formerly L0ExplorerApp.m)
    MODvis_spectra.m - browses a folder of .mat files carrying per-scan spectra (this repo's own L2/profile output, or legacy MOD_fish_lib/EPSILOMETER Profile*.mat), with wavenumber/frequency spectrum plots and theoretical overlays
    MODvis_twist_timeseries.m - plots cable twist count (gyro method) vs. time for a deployment, highlighting upcast samples and spool swap events
    SpectraExplorerApp.m - plots timeseries from a directory of Profile.mat files;
        includes chi QC diagnostics (cutoff/kmin wavenumbers, modeled vs. observed noise,
        chi raw/noise-subtracted/MLE comparison) — see CHI_INSPECTOR_MANUAL.md
