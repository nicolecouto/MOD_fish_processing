function scan = mod_scan_shear_accel_coherence(scan, metadata, channel)
% mod_scan_shear_accel_coherence        Part of MOD_fish_processing
%
% scan = mod_scan_shear_accel_coherence(scan, metadata, channel)
%
% DESCRIPTION
%   Magnitude-squared coherence between one shear channel and each
%   accelerometer channel the scan has (every epsi.a<n>_g: a1, a2, a3),
%   over this scan's raw time series - vibration-contamination
%   diagnostics. The 'a3' coherence also cleans the shear spectrum before
%   it is integrated for epsilon (mod_scan_calc_epsilon.m subtracts the
%   coherent fraction of shear variance: Ps_velocity_co_f =
%   Ps_velocity_f .* (1 - Cxy), see that function); a3 is the channel the
%   correction uses, as in MOD_fish_lib's mod_efe_scan_coherence.m (its
%   own comment: "should be a3"), since the vertical axis is the one most
%   mechanically coupled to a shear probe's own vibration. a1 and a2 are
%   diagnostics only.
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
%                  epsi.a<n>_g         - accelerometer channels (a1_g,
%                        a2_g, a3_g) raw time series, same length; each
%                        one present gets a coherence
%   metadata   - metadata struct (from MODsetup_read_yaml.m). Uses:
%                  metadata.PROCESS.fft_length, .fs_afe
%                  metadata.PROCESS.EPSILON.coherence_fmin_hz,
%                    .coherence_fmax_hz - band the diagnostic sum
%                    integrates over (see OUTPUTS)
%                Validated at the top of this function via
%                MODsetup_validate_metadata.m.
%   channel    - shear channel name string (e.g. 's1').
%
% OUTPUTS
%   scan - same struct, with added:
%     spectra.(channel)_coh_<a>    - for each accelerometer <a> (a1, a2,
%                              a3): magnitude-squared coherence vs. f,
%                              same shape as spectra.f (assumed identical
%                              frequency grid to mscohere's own output at
%                              the same fft_length/fs_afe - same trust
%                              MODsetup_define_filters.m's NOTES already
%                              document for a dummy pwelch call).
%                              spectra.(channel)_coh_a3 is always set:
%                              empty if the shear channel or a3_g is
%                              missing from scan.epsi (e.g. this
%                              deployment has no epsi at all for the
%                              requested channel).
%     spectra.(channel)_coh_<a>_sum - band-integrated coherence [Hz] over
%                              [coherence_fmin_hz, coherence_fmax_hz] - a
%                              standalone vibration-contamination
%                              diagnostic, not itself consumed by the
%                              epsilon calculation. NaN alongside an empty
%                              coherence vector.
%
% CALLED BY
%   mod_scan_calc_epsilon.m
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
    {'fft_length', 'fs_afe', 'coherence_fmin_hz', 'coherence_fmax_hz'});

fft_length = metadata.PROCESS.fft_length;
fs_afe = metadata.PROCESS.fs_afe;
fmin = metadata.PROCESS.EPSILON.coherence_fmin_hz;
fmax = metadata.PROCESS.EPSILON.coherence_fmax_hz;

shear_field = [channel '_volt'];
names = {};
if isstruct(scan.epsi)
    names = fieldnames(scan.epsi);
end
accel_fields = names(~cellfun(@isempty, regexp(names, '^a\d+_g$', 'once')))';
accel_fields = union(accel_fields, {'a3_g'}); % a3's fields are always set: the epsilon correction reads them
noverlap = round(0.5 * fft_length); % matches mod_scan_fft_seg_starts.m's hardcoded 50% overlap
for accel_field = accel_fields
    coh_field = [channel '_coh_' accel_field{1}(1:end - 2)];
    if ~isfield(scan.epsi, shear_field) || ~isfield(scan.epsi, accel_field{1})
        scan.spectra.(coh_field) = [];
        scan.spectra.([coh_field '_sum']) = NaN;
        continue
    end
    [Cxy, fe] = mscohere(detrend(scan.epsi.(shear_field)), detrend(scan.epsi.(accel_field{1})), ...
        fft_length, noverlap, fft_length, fs_afe);
    scan.spectra.(coh_field) = Cxy(:)';
    scan.spectra.([coh_field '_sum']) = sum(Cxy(fe > fmin & fe < fmax)) * mean(diff(fe), 'omitnan');
end

end %end function
