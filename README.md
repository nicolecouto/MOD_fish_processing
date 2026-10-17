# MOD_fish_processing
Data processing pipeline and field commands for MOD profiling fish


acquisition
    start_new_deployment.py - Start New Deployment window (Python/tkinter) for the acquisition Mac: writes the Setup file fctd_epsi reads, the deployment's meta/dev1_setup.yml, and a row in the cruise deployment log - see docs/workflow/start_new_deployment.md
    check_software/check_ship_setup.sh - read-only check of a ship computer (DEV1/DEV3): branch and remotes, up to date with GitHub, config.yml folders, MOD_fish_calibrations files, cruise_meta_data.yml, python3/tkinter and matlab

setup
    MODsetup_build_yaml.m - merges a survey's meta/dev1_setup.yml (Start New Deployment) with the cruise's cruise_meta_data.yml into a processing run's yml, meta/meta_data_<run>.yml (rebuilt every time; another set of values = another cruise yml), the yml processing reads
    MODsetup_preflight.m - prints a run's plan (which yml, inputs, outputs) and checks its yml has every processing parameter the stages about to run need (asks for missing ones with prompt = true), before an unattended run
    MODsetup_L1_settings.m - the part of metadata L0 -> L1 reads, so preflight can check that a run reusing another run's L1 (L1_from) has the same L1 settings
    cruise_meta_data_template.yml - every processing parameter with its description and suggested starting value (made by MODsetup_write_cruise_meta_data_template.m); copy to <processed_root>/cruise_meta_data.yml and review

templates
    MODtemplate_postprocess.m - postprocessing one survey: edit the settings block (survey, run name, cruise yml, L1_from, by, last stage), run it; same code as the realtime worker
    MODtemplate_postprocess_by_stage.m - the same, one section per stage (L0, L1, casts, L2, grid) to look at each stage's output before the next
    MODtemplate_postprocess_steps.m - postprocessing one line per level (metadata = ..., L0_files = ..., L1_files = ..., ...): the processing functions called directly, no driver

launchers (repo folder, double-click on DEV3)
    Start Realtime Processing.command - starts the realtime worker (matlab -batch) on processed_root from acquisition/config.yml
    Start Realtime Monitor.command - opens MODvis_realtime_monitor in a second MATLAB next to the worker
    util/launch_common.sh - what both share: the processed folder and the MATLAB to use (arch -x86_64 for an Intel MATLAB on Apple Silicon)

processing
    MODprocess_deployment.m - the one driver: realtime worker (MODprocess_deployment(processed_root, 'watch', true), or double-click "Start Realtime Processing.command") and one-pass/postprocessing runs (MODprocess_deployment(survey_folder, 'run', name, ...)): one yml per run (survey/meta/meta_data_<run>.yml) and one output folder (survey/processed/<run>/); see docs/workflow/processing_data.md
    MODprocess_grid.m - the grid: one column per cast (down and up) in depth bins of grid.z_bin_m - CTD = mean of the L1 samples in each bin, epsilon/chi = mean of the scans whose center is in it (processed/<run>/grid/grid.mat)
    MODprocess_find_spool_swaps.m - winch spool changes for the cruise twist count, from the dev1_setup.yml files and spool_swap_log.csv together
    MODprocess_cruise_twist.m - the cruise twist count: every survey on the winch spool joined at 1 s, restarting at each spool change (Processed/twist/), run by the worker

util
    MODutil_simulate_acquisition.m - replays a real deployment's raw files into a test folder, growing each file the way fctd_epsi does, to test realtime processing
    MODutil_read_som3.m - prints (or returns) what's in a .modraw file's $SOM3 block: mission, vehicle, firmware, and each SOM module (EFE channels with probe SNs, SBE, SD card, ...)
    MODutil_level_folders.m - for the viewers: the L1 and L2 folders that go together for a processing run (its own L1, or the L1_from run's)
    MODutil_provenance.m - the provenance field in every L0/L1/L2/profiles file: the file(s) and run yml it was made from (relative to the survey), the yml's SHA-256, run, time and code commit

visualization
    MODvis_realtime_monitor.m - the live monitor for the realtime worker: status, grid sections (depth vs time, any gridded variable), pressure, T-S of the last casts, cruise twist, the processing log, Start/Pause/Stop
    MODvis_timeseries.m - plots time series from a directory of L0, L1, L2, or Profile .mat files, or a processing run's folder (opens its L1) (formerly L0ExplorerApp.m)
    MODvis_spectra.m - browses a folder of .mat files carrying per-scan spectra (this repo's own L2/profile output, or legacy MOD_fish_lib/EPSILOMETER Profile*.mat), with wavenumber/frequency spectrum plots, theoretical overlays, FPO7 noise floors, and ADC bit-noise (24/20/16-bit) and accelerometer noise reference lines
    MODvis_spectra_L0.m - quick-look EFE spectra straight from L0 files vs ADC bit noise, no setup.yml needed: timeseries rows on top, click to pick the spectrum window; nfft/window/overlap/taper/detrend editable in the viewer; export one scan or the whole file's scans (spectra, f, noise floors, indices, settings) to .mat
    MODvis_twist_timeseries.m - plots cable twist count (gyro method) vs. time, highlighting upcast samples, spool changes and survey starts
    SpectraExplorerApp.m - plots timeseries from a directory of Profile.mat files;
        includes chi QC diagnostics (cutoff/kmin wavenumbers, modeled vs. observed noise,
        chi raw/noise-subtracted/MLE comparison) — see CHI_INSPECTOR_MANUAL.md
