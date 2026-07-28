function fc_index = mod_scan_fpo7_cutoff(f, Pxx, noise_coefs)
% mod_scan_fpo7_cutoff        Part of MOD_fish_processing
%
% fc_index = mod_scan_fpo7_cutoff(f, Pxx, noise_coefs)
%
% DESCRIPTION
%   Finds where an observed FP07 voltage spectrum (Pxx) drops down into
%   the instrument's own bench-measured noise floor, and returns the index
%   (into f/Pxx, unchanged) of the last frequency bin still trustworthy
%   above that floor. This is the upper integration bound (kc, once
%   divided by fall speed) mod_scan_calc_chi_obs.m and
%   mod_scan_calc_chi_mle.m both need - chi is only computed over
%   wavenumbers where the FP07 channel is actually measuring turbulence,
%   not its own electronic noise.
%
%   The noise floor itself is a cubic fit in log10(f) vs. log10(noise
%   power), pre-measured on a bench with no probe attached
%   (noise_coefs.n0..n3 - see MOD_fish_calibrations/FPO7/README.md for
%   where this file comes from). The observed spectrum is smoothed
%   (movmean, 15-point window) and compared, bin by bin, against
%   SN_min (=3) times the noise floor - skipping the lowest 2 remaining
%   (f > 0) bins entirely, since those are dominated by low-frequency
%   structure rather than sensor noise and would otherwise trip the
%   threshold spuriously; the first (higher-frequency) bin where the
%   smoothed spectrum drops below that threshold is where "signal" gives
%   way to "noise". Before comparing, the observed spectrum's overall
%   noise-floor level is normalized to match the bench measurement's
%   units/scale (see adjust_spec below) - the two were not necessarily
%   measured under identical gain/conditions, so a direct level-for-level
%   comparison without this step would be comparing two different
%   absolute scales.
%
% INPUTS
%   f          - frequency vector [Hz], any shape, must include more than
%                n_skip (2, hardcoded below) bins with f > 0 - the DC/f=0
%                bin, if present, is excluded from the noise-floor search
%                since log10(0) is undefined, and the first n_skip
%                remaining bins are excluded too (see DESCRIPTION) - see
%                NOTES for how the f=0 exclusion differs from the old
%                FPO7_cutoff.m
%   Pxx        - FP07 channel's raw volts^2/Hz power spectrum, same
%                size/order as f
%   noise_coefs - struct with fields n0, n1, n2, n3 (bench noise floor
%                polynomial coefficients, e.g. loaded from
%                MOD_fish_calibrations/FPO7/FPO7_benchnoise.mat)
%
% OUTPUTS
%   fc_index - index into the ORIGINAL f/Pxx arrays (as passed in - no
%              truncation) of the last bin still above the noise floor.
%              Caller converts to a cutoff wavenumber via
%              kc = f(fc_index) / abs(w). If the spectrum never crosses
%              the noise floor at all, fc_index is the last f > 0 bin
%              (i.e. "trust the whole spectrum").
%
% CALLED BY
%   mod_scan_calc_chi_obs.m, mod_scan_calc_chi_mle.m
%
% CALLS
%   (none)
%
% NOTES
%   Ports the old MOD_fish_lib FPO7_cutoff.m's approach (bench noise
%   floor, movmean smoothing, SN_min=3 threshold, skip the first 2
%   Fourier coefficients), but fixes two indexing issues found while
%   tracing it, both silent (no error, just a wrong answer by a
%   few bins):
%     1. The old function internally dropped the f=0 bin
%        (spec=spec(f>0); f=f(f>0);) before searching, then returned an
%        index into that SHORTER, locally-reassigned array. Its caller
%        (mod_efe_scan_chi.m) then indexed its own, still-full-length f
%        array with that same number (f(fc_index)) - off by however many
%        bins were dropped (1, for a standard one-sided pwelch f that
%        starts at 0). This function instead tracks original-array
%        indices throughout, so the index it returns is always valid
%        against the f/Pxx exactly as passed in - no reindexing required
%        by the caller.
%     2. The old function's "don't compare the first 2 Fourier
%        coefficients" step searched within medspec(3:end), then returned
%        that sub-array's index directly as fc_index without adding the
%        2-bin offset back - so its fc_index actually pointed 2 bins
%        earlier (lower frequency) than where the noise floor was really
%        crossed. Fixed here by converting back to an original-array index
%        before returning.
%   Both would have made the old code's chi integration cut off a little
%   early (excluding a few valid high-wavenumber bins) - a small, one-
%   directional bias, not the kind of factor-of-2 issue the FP07 time
%   constant itself is (see mod_scan_fpo7_transfer_function.m), but
%   worth having fixed given how much this whole exercise is about
%   auditing exactly this kind of thing.
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

SN_min = 3;
n_skip = 2; % don't trust the first 2 (lowest-frequency) Fourier coefficients

f = f(:);
Pxx = Pxx(:);

valid = find(f > 0);
if numel(valid) <= n_skip
    error('mod_scan_fpo7_cutoff:tooFewBins', ...
        'Need more than %d frequency bins with f > 0 to find a noise-floor cutoff.', n_skip);
end

logf = log10(f(valid));
noise = noise_coefs.n0 + noise_coefs.n1.*logf + noise_coefs.n2.*logf.^2 + noise_coefs.n3.*logf.^3;
medspec = smoothdata(Pxx(valid), 'movmean', 15);

% Normalize the observed spectrum's noise floor onto the bench
% measurement's scale, using only the top 30% of the frequency range
% (0.7*f(end) to f(end)) - close to Nyquist, where real turbulent signal
% has long since rolled off and what remains should be almost pure
% instrument noise on both sides of the comparison.
high_freq = f(valid) > 0.7 * f(valid(end));
adjust_spec = median(medspec(high_freq) ./ 10.^noise(high_freq), 'omitmissing');
if adjust_spec > 10
    warning('mod_scan_fpo7_cutoff:highNoiseFloor', ...
        ['Observed noise floor is >10x the bench measurement - either a ' ...
        'noisy scan or a probe/electronics issue worth checking.']);
end

search_idx = (n_skip + 1):numel(valid); % positions within `valid`/`medspec`, skipping the first n_skip
below_floor = medspec(search_idx) ./ adjust_spec < SN_min * 10.^noise(search_idx);
first_noisy = find(below_floor, 1, 'first');

if isempty(first_noisy)
    fc_index = valid(end); % never drops into noise - trust the whole spectrum
else
    % Convert back from a `search_idx`-relative position to the original
    % f/Pxx index space (see NOTES point 2), then step back one bin so
    % fc_index lands on the last bin still above the floor, not the first
    % one below it (matches the old code's final `fc_index - 1` step).
    first_noisy_orig = valid(search_idx(first_noisy));
    fc_index = first_noisy_orig - 1;
    fc_index = max(fc_index, valid(1));
end

end %end function
