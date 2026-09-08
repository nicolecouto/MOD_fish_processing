function scan = mod_scan_shear_accel_coherence(scan, metadata, channel)
% mod_scan_shear_accel_coherence        Part of MOD_fish_processing
%
% scan = mod_scan_shear_accel_coherence(scan, metadata, channel)
%
% DESCRIPTION
%   Magnitude-squared coherence between one shear channel and the
%   vertical-axis accelerometer channel 'a3', over this scan's raw time
%   series - a vibration-contamination diagnostic used to clean the shear
%   spectrum before integrating it for epsilon (modProcess_L2_calc_epsilon.m
%   subtracts the coherent fraction of shear variance: Ps_velocity_co_f =
%   Ps_velocity_f .* (1 - Cxy), see that function). 'a3' is hardcoded as
%   the reference channel, not looped over all three accelerometer axes -
%   matches MOD_fish_lib's mod_efe_scan_coherence.m, which hardcodes the
%   same choice (its own comment: "should be a3") since the vertical axis
%   is the one most mechanically coupled to a shear probe's own vibration.
%
%   Uses MATLAB's built-in mscohere on the raw (once, whole-scan) detrended
%   time series, rather than mod_scan_get_spectra.m's per-segment-detrend
%   Welch method - a deliberate simplification that matches
%   MOD_fish_lib's mod_efe_scan_coherence.m exactly (single whole-scan
%   detrend, mscohere's own internal Hamming windowing/50% overlap), since
%   no per-segment-detrend coherence estimator exists anywhere in this
%   repo to build on instead. Worth revisiting if the same detrend-per-
%   segment rationale mod_scan_get_spectra.m's NOTES give for spectra
%   turns out to matter for coherence too.
%
% INPUTS
%   scan       - struct with:
%                  epsi.(channel)_volt - shear channel raw voltage time
%                        series, one scan's worth of samples
%                  epsi.a3_g           - accelerometer channel 'a3' raw
%                        time series, same length
%   metadata   - metadata struct (from MODsetup_read_yaml.m). Uses:
%                  metadata.PROCESS.fft_length, .Fs_epsi
%                  metadata.PROCESS.EPSILON.coherence_fmin_hz,
%                    .coherence_fmax_hz - band the diagnostic sum
%                    integrates over (see OUTPUTS)
%                Validated at the top of this function via
%                MODsetup_validate_metadata.m.
%   channel    - shear channel name string (e.g. 's1').
%
% OUTPUTS
%   scan - same struct, with added:
%     spectra.(channel)_coh_a3     - magnitude-squared coherence vs. f,
%                              same shape as spectra.f (assumed identical
%                              frequency grid to mscohere's own output at
%                              the same fft_length/Fs_epsi - same trust
%                              MODsetup_define_filters.m's NOTES already
%                              document for a dummy pwelch call). Empty if
%                              either channel is missing from scan.epsi
%                              (e.g. this deployment has no epsi at all
%                              for the requested channel).
%     spectra.(channel)_coh_a3_sum - band-integrated coherence [Hz] over
%                              [coherence_fmin_hz, coherence_fmax_hz] - a
%                              standalone vibration-contamination
%                              diagnostic, not itself consumed by the
%                              epsilon calculation. NaN alongside an empty
%                              coherence vector.
%
% CALLED BY
%   modProcess_L2_calc_epsilon.m
%
% CALLS
%   MODsetup_validate_metadata.m
%   (MATLAB's Signal Processing Toolbox mscohere, detrend)
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

yaml_file = '';
if isfield(metadata, 'paths') && isfield(metadata.paths, 'setup_yml')
    yaml_file = metadata.paths.setup_yml;
end
metadata = MODsetup_validate_metadata(metadata, yaml_file, ...
    {'fft_length', 'Fs_epsi', 'coherence_fmin_hz', 'coherence_fmax_hz'});

fft_length = metadata.PROCESS.fft_length;
Fs_epsi = metadata.PROCESS.Fs_epsi;
fmin = metadata.PROCESS.EPSILON.coherence_fmin_hz;
fmax = metadata.PROCESS.EPSILON.coherence_fmax_hz;

shear_field = [channel '_volt'];
accel_field = 'a3_g';
coh_field = [channel '_coh_a3'];

if ~isfield(scan.epsi, shear_field) || ~isfield(scan.epsi, accel_field)
    scan.spectra.(coh_field) = [];
    scan.spectra.([coh_field '_sum']) = NaN;
    return
end

noverlap = round(0.5 * fft_length); % matches mod_scan_get_spectra.m's hardcoded 50% overlap
[Cxy, fe] = mscohere(detrend(scan.epsi.(shear_field)), detrend(scan.epsi.(accel_field)), ...
    fft_length, noverlap, fft_length, Fs_epsi);

scan.spectra.(coh_field) = Cxy(:)';
scan.spectra.([coh_field '_sum']) = sum(Cxy(fe > fmin & fe < fmax)) * mean(diff(fe), 'omitnan');

end %end function
