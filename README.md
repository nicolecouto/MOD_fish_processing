# MOD_fish_processing
Data processing pipeline and field commands for MOD profiling fish


visualization
    matlab
        MODvis_timeseries.m - plots time series from a directory of L0, L1, L2, or Profile .mat files (formerly L0ExplorerApp.m)
        SpectraExplorerApp.m - plots timeseries from a directory of Profile.mat files;
            includes chi QC diagnostics (cutoff/kmin wavenumbers, modeled vs. observed noise,
            chi raw/noise-subtracted/MLE comparison) — see CHI_INSPECTOR_MANUAL.md
    python
        MODvis_timeseries.py - plots time series from a directory of L0, L1, L2, or Profile .mat files (formerly L0ExplorerApp.py)