function fc_index = mod_scan_fpo7_cutoff_search(f, medspec, noise_f, SN_min, n_skip, contam_freq_hz)
% mod_scan_fpo7_cutoff_search        Part of MOD_fish_processing
%
% fc_index = mod_scan_fpo7_cutoff_search(f, medspec, noise_f, SN_min, n_skip, contam_freq_hz)
%
% DESCRIPTION
%   The noise-floor-crossing search at the core of mod_scan_fpo7_cutoff.m,
%   extracted so a second caller can run the identical search against a
%   different noise-floor curve without re-deriving the same logic - same
%   reasoning mod_scan_fpo7_noise_adjust.m was extracted for
%   (MODvis_spectra.m's shifted-noise-floor overlay). Here the second
%   caller is MODvis_spectra.m's live "cutoff (modeled)" checkbox, which
%   runs this same search against the theoretical noise floor
%   (mod_scan_fpo7_modeled_noise_f.m) instead of the bench-measured one -
%   so the two noise-floor choices can be compared on an otherwise
%   identical algorithm.
%
%   Smooths nothing itself - medspec must already be the smoothed
%   observed spectrum (movmean, mod_scan_fpo7_cutoff.m's
%   n_smooth_f_spectrum), and noise_f must already be on the correct
%   absolute scale for direct comparison (a bench caller must pre-multiply
%   by its own adjust_spec - see mod_scan_fpo7_noise_adjust.m; the modeled
%   noise floor needs no such scaling, since mod_scan_fpo7_modeled_noise_f.m
%   already returns it in the same "as recorded" units as a real spectrum).
%   Compares medspec against SN_min*noise_f bin by bin, skipping the first
%   n_skip (lowest-frequency) bins, and returns the index of the last bin
%   still above that threshold before the first drop below it - "never
%   drops below" returns the last index (trust the whole spectrum), same
%   as mod_scan_fpo7_cutoff.m's original behavior. Then caps that index
%   against contam_freq_hz (Inf = no cap) - see mod_scan_fpo7_cutoff.m's
%   NOTES for why this cap exists.
%
% INPUTS
%   f               - frequency vector [Hz], f>0 only (caller has already
%                      excluded any f=0 bin), any shape
%   medspec         - smoothed observed spectrum at those frequencies,
%                      same size as f
%   noise_f         - comparison noise-floor curve at those frequencies,
%                      already on the correct absolute scale (see
%                      DESCRIPTION), same size as f
%   SN_min          - signal-to-noise threshold multiplier
%   n_skip          - number of lowest-frequency bins excluded from the
%                      search
%   contam_freq_hz  - known contamination frequency [Hz], or Inf for no cap
%
% OUTPUTS
%   fc_index - index into f/medspec/noise_f (as passed in) of the last bin
%              still trustworthy
%
% CALLED BY
%   mod_scan_fpo7_cutoff.m, MODvis_spectra.m
%
% CALLS
%   (none)
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

f = f(:); medspec = medspec(:); noise_f = noise_f(:);
n = numel(f);
if numel(medspec) ~= n || numel(noise_f) ~= n
    error('mod_scan_fpo7_cutoff_search:sizeMismatch', ...
        'f, medspec, and noise_f must all be the same size.');
end
if n <= n_skip
    error('mod_scan_fpo7_cutoff_search:tooFewBins', ...
        'Need more than %d frequency bins to find a noise-floor cutoff.', n_skip);
end

search_idx = (n_skip + 1):n;
below_floor = medspec(search_idx) < SN_min * noise_f(search_idx);
first_noisy = find(below_floor, 1, 'first');

if isempty(first_noisy)
    fc_index = n; % never drops into noise - trust the whole spectrum
else
    fc_index = search_idx(first_noisy) - 1;
    fc_index = max(fc_index, 1);
end

% Cap against a known contamination line - a fixed spectral line can hold
% the smoothed spectrum above the noise floor and pull the search out past
% it. Inf (no known line) is a no-op.
if isfinite(contam_freq_hz)
    below_contam = find(f < contam_freq_hz);
    if ~isempty(below_contam)
        fc_index = min(fc_index, below_contam(end));
    end
end

end %end function
