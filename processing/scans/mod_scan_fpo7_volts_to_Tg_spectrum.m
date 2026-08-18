function scan = mod_scan_fpo7_volts_to_Tg_spectrum(scan, metadata, channel)
% mod_scan_fpo7_volts_to_Tg_spectrum        Part of MOD_fish_processing
%
% scan = mod_scan_fpo7_volts_to_Tg_spectrum(scan, metadata, channel)
%
% DESCRIPTION
%   Converts one scan's raw FP07 channel voltage power spectrum into a
%   deconvolved temperature-gradient wavenumber spectrum - the shared
%   first stage both mod_scan_calc_chi_obs.m (direct wavenumber
%   integration) and mod_scan_calc_chi_mle.m (Batchelor-spectrum MLE
%   fit) need before they diverge on what to do with it:
%
%     1. Pt_volt_f (raw volts^2/Hz) -> temperature frequency spectrum:
%          Pt_T_f = Pt_volt_f * volts_to_C(1)^2
%        (volts_to_C(1) is the linear calibration's slope, degC/volt -
%        see MODprocess_L1_apply_fpo7_calibration.m. Squaring the slope
%        and multiplying is equivalent to re-computing the spectrum from
%        the calibrated-to-degC timeseries directly, since pwelch detrends
%        its input and detrend(a*x+b) = a*detrend(x) - no second pwelch
%        call needed.)
%     2. Deconvolve the FP07 thermal rolloff AND the AFE's fixed
%        electronics/ADC response (sinc^4 anti-alias filter, resolved
%        once per deployment by MODsetup_define_filters.m -> see
%        metadata.AFE.(channel).electronics_filter below):
%          H_total = electronics_filter .* mod_scan_fpo7_transfer_function(f, w, tau0, exponent)
%          Pt_T_f = Pt_T_f ./ H_total
%     3. Convert to a temperature-gradient wavenumber spectrum:
%          k = f / abs(w)
%          Pt_Tg_k = (2*pi*k).^2 .* Pt_T_f .* abs(w)
%
%   Split out of what was originally one monolithic MODprocess_L2_calc_chi.m
%   (chi_obs's direct-integration steps) once mod_scan_calc_chi_mle.m
%   needed to start from the exact same deconvolved spectrum - keeping this
%   conversion in one place means a tau sensitivity comparison (tau0/
%   exponent overrides) automatically applies identically to both chi_obs
%   and chi_mle, rather than risking the two drifting out of sync.
%
% INPUTS
%   scan       - struct with:
%                  spectra.f         - frequency vector [Hz], nfreq x 1 or
%                        1 x nfreq (same shape as spectra.Pt_volt_f)
%                  spectra.Pt_volt_f - one scan's raw FP07 channel power
%                        spectrum [V^2/Hz], same shape as spectra.f (e.g.
%                        from mod_scan_get_spectra.m's
%                        scan.spectra.(channel)_volt_f, selected by the
%                        caller for this one channel)
%                  w                 - fall speed at this scan's center
%                        [m/s], scalar. Sign does not matter (abs'd
%                        internally) - see mod_scan_fpo7_transfer_function.m
%                        for why w=0 is not a meaningful input here.
%   metadata   - metadata struct (from MODsetup_read_yaml.m). Uses:
%                  metadata.AFE.(channel).volts_to_C - [slope, intercept],
%                    only slope used (see step 1 above)
%                  metadata.AFE.(channel).electronics_filter (optional) -
%                    AFE electronics/ADC transfer function, magnitude-
%                    squared, same shape as spectra.f, from
%                    MODsetup_define_filters.m. Defaults to 1 (no
%                    correction) if metadata.AFE.(channel) has no such
%                    field - so deployments processed before that step
%                    existed keep working unchanged.
%                  metadata.PROCESS.CHI.time_constant_s (optional) - FP07
%                    time-constant coefficient [s] (tau0), passed straight
%                    through to mod_scan_fpo7_transfer_function.m (default
%                    there: 0.005 if metadata.PROCESS.CHI or the field is
%                    missing). Exposed as a metadata field, not hardcoded,
%                    so a tau sensitivity comparison is a metadata edit,
%                    not a code edit.
%                  metadata.PROCESS.CHI.fall_speed_exponent (optional) -
%                    fall-speed exponent, passed straight through to
%                    mod_scan_fpo7_transfer_function.m (default there:
%                    -0.32).
%   channel    - channel name string (e.g. 't1'), selects which
%                metadata.AFE.(channel) to read.
%
% OUTPUTS
%   scan - same struct, with added:
%     spectra.k       - wavenumber vector [cpm], same shape as spectra.f,
%                        k = f / abs(w)
%     spectra.Pt_Tg_k - deconvolved temperature-gradient wavenumber
%                        spectrum, same shape as spectra.k
%
% CALLED BY
%   mod_scan_calc_chi_obs.m, mod_scan_calc_chi_mle.m
%
% CALLS
%   mod_scan_fpo7_transfer_function.m
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

volts_to_C = metadata.AFE.(channel).volts_to_C;

electronics_filter = 1;
if isfield(metadata.AFE.(channel), 'electronics_filter')
    electronics_filter = metadata.AFE.(channel).electronics_filter;
end

tau0 = [];
exponent = [];
if isfield(metadata, 'PROCESS') && isfield(metadata.PROCESS, 'CHI')
    chi_params = metadata.PROCESS.CHI;
    if isfield(chi_params, 'time_constant_s')
        tau0 = chi_params.time_constant_s;
    end
    if isfield(chi_params, 'fall_speed_exponent')
        exponent = chi_params.fall_speed_exponent;
    end
end

f = scan.spectra.f(:)';
Pt_volt_f = scan.spectra.Pt_volt_f(:)';
electronics_filter = electronics_filter(:)';

Pt_T_f = Pt_volt_f * volts_to_C(1)^2;
H_thermal = mod_scan_fpo7_transfer_function(f, scan.w, tau0, exponent);
H_total = electronics_filter .* H_thermal;
Pt_T_f = Pt_T_f ./ H_total;

k = f / abs(scan.w);
Pt_Tg_k = (2*pi*k).^2 .* Pt_T_f * abs(scan.w);

scan.spectra.k = k;
scan.spectra.Pt_Tg_k = Pt_Tg_k;

end %end function
