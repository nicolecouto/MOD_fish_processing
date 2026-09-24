# Concepts

Background on the physics and math behind the pipeline, as opposed to the [workflow](../workflow/modraw_to_L0_conversion.md) pages, which document what the scripts do and how to run them.

- [Choosing fft_length, fft_segments_per_scan, and scan_overlap](spectral_windowing.md) - how `fft_length`/`fft_segments_per_scan`/`scan_overlap` combine to set a spectrum's degrees of freedom and resolution, and why a scan also can't physically outgrow the instrument
- [Units and the sw_->gsw_ migration](units_and_seawater.md) - why this repo moved from the legacy CSIRO SEAWATER (EOS-80) toolbox to GSW/TEOS-10, the one deliberate exception (`visc.m`), the Reference-Salinity shortcut and its measured accuracy, and the per-level `MODunits_L0/L1/L2.m` registries
- [From raw volts to a trustworthy wavenumber spectrum](spectral_filtering_and_noise_floors.md) - what the ideal Batchelor/Panchev shapes look like in wavenumber and frequency space, the calibration+deconvolution steps a raw volts spectrum needs before it can be compared to them, and how the noise floor sets a cutoff

Pages will be added here over time. Planned topics:

- Calculating epsilon from shear
- Calculating chi from temperature
- How profiles are detected from a pressure timeseries
- Figure of merit: what it means and when to trust it
