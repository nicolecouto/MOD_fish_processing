# MOD_fish_processing
Data processing pipeline and field commands for MOD profiling fish


acquisition
    start_new_deployment.py - Start New Deployment window (Python/tkinter) for the acquisition Mac: writes the Setup file fctd_epsi reads, the deployment's meta/dev1_setup.yml, and a row in the cruise deployment log - see docs/workflow/start_new_deployment.md

setup
    MODsetup_build_yaml.m - merges a survey's meta/dev1_setup.yml (Start New Deployment) with the cruise's cruise_meta_data.yml into meta/depl_meta_data.yml, the yml processing reads
    MODsetup_preflight.m - checks a deployment's yml has every processing parameter its instruments need (asks for missing ones with prompt = true), before an unattended run
    cruise_meta_data_template.yml - every processing parameter with its description and suggested starting value (made by MODsetup_write_cruise_meta_data_template.m); copy to <processed_root>/cruise_meta_data.yml and review

processing
    MODprocess_deployment.m - the one driver: realtime worker (MODprocess_deployment(processed_root, 'watch', true), or double-click "Start Realtime Processing.command") and one-pass/postprocessing runs (MODprocess_deployment(survey_folder, 'by', 'profile')); see docs/workflow/realtime_processing.md
    MODprocess_find_spool_swaps.m - winch spool changes for the cruise twist count, from the dev1_setup.yml files and spool_swap_log.csv together

util
    MODutil_simulate_acquisition.m - replays a real deployment's raw files into a test folder, growing each file the way fctd_epsi does, to test realtime processing
    MODutil_read_som3.m - prints (or returns) what's in a .modraw file's $SOM3 block: mission, vehicle, firmware, and each SOM module (EFE channels with probe SNs, SBE, SD card, ...)

visualization
    MODvis_timeseries.m - plots time series from a directory of L0, L1, L2, or Profile .mat files (formerly L0ExplorerApp.m)
    MODvis_spectra.m - browses a folder of .mat files carrying per-scan spectra (this repo's own L2/profile output, or legacy MOD_fish_lib/EPSILOMETER Profile*.mat), with wavenumber/frequency spectrum plots, theoretical overlays, FPO7 noise floors, and ADC bit-noise (24/20/16-bit) and accelerometer noise reference lines
    MODvis_spectra_L0.m - quick-look EFE spectra straight from L0 files vs ADC bit noise, no setup.yml needed: timeseries rows on top, click to pick the spectrum window; nfft/window/overlap/taper/detrend editable in the viewer; export one scan or the whole file's scans (spectra, f, noise floors, indices, settings) to .mat
    MODvis_twist_timeseries.m - plots cable twist count (gyro method) vs. time for a deployment, highlighting upcast samples and spool swap events
    SpectraExplorerApp.m - plots timeseries from a directory of Profile.mat files;
        includes chi QC diagnostics (cutoff/kmin wavenumbers, modeled vs. observed noise,
        chi raw/noise-subtracted/MLE comparison) — see CHI_INSPECTOR_MANUAL.md
