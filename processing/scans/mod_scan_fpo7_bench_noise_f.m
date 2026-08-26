function noise_f = mod_scan_fpo7_bench_noise_f(f, noise_coefs)
% mod_scan_fpo7_bench_noise_f        Part of MOD_fish_processing
%
% noise_f = mod_scan_fpo7_bench_noise_f(f, noise_coefs)
%
% DESCRIPTION
%   FP07 electronic noise floor from a bench measurement - the MEASURED
%   counterpart to mod_scan_fpo7_noise_f.m's theoretical model. A real FP07
%   probe, on a real bench, read through the same electronics/ADC chain
%   used in the field, had its own noise floor recorded and fit as a cubic
%   polynomial in log10(f) vs. log10(noise power) (noise_coefs.n0..n3, e.g.
%   from MOD_fish_calibrations/FPO7/FPO7_benchnoise.mat):
%
%     log10(noise_f) = n0 + n1*log10(f) + n2*log10(f)^2 + n3*log10(f)^3
%
%   Because this is a real end-to-end measurement - not a from-scratch
%   circuit model - the value returned here is ALREADY in the same domain
%   as a real recorded Pt_volt_f: whatever thermal-lag and electronics/ADC
%   filtering happened during that original bench recording is already
%   baked into the fit. No further filter needs to be applied before
%   comparing this directly against an observed Pt_volt_f - see
%   mod_scan_fpo7_modeled_noise_f.m's NOTES for how that differs from
%   mod_scan_fpo7_noise_f.m's theoretical model, which needs the
%   electronics/ADC filter applied first for the same comparison to be
%   valid.
%
%   This function only evaluates the polynomial - it doesn't know or care
%   where noise_coefs came from. Pulled out into its own documented,
%   testable function rather than left as the inline formula duplicated
%   across mod_scan_fpo7_cutoff.m and several ad hoc analysis scripts
%   outside this repo (see NOTES).
%
% INPUTS
%   f           - frequency vector [Hz], any shape, must not contain 0
%                 (log10(0) is undefined).
%   noise_coefs - struct with fields n0, n1, n2, n3 (e.g. from
%                 MOD_fish_calibrations/FPO7/FPO7_benchnoise.mat).
%
% OUTPUTS
%   noise_f - FP07 bench-measured noise floor [V^2/Hz], same size as f.
%
% CALLED BY
%   Not yet called by anything - mod_scan_fpo7_cutoff.m still has its own
%   inline copy of this formula (see NOTES).
%
% CALLS
%   (none)
%
% NOTES
%   mod_scan_fpo7_cutoff.m (as of this writing) has its own inline copy of
%   this exact formula, predating this function. Not refactored to call
%   this one here, to keep this change scoped to adding the theoretical/
%   measured pair the way it was asked for (alongside
%   mod_scan_fpo7_modeled_noise_f.m) - worth doing as a follow-up so
%   there's only one copy of this formula in the repo.
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

if nargin < 2 || isempty(noise_coefs) || ~all(isfield(noise_coefs, {'n0', 'n1', 'n2', 'n3'}))
    error('mod_scan_fpo7_bench_noise_f:missingNoiseCoefs', ...
        'noise_coefs.n0/.n1/.n2/.n3 (bench noise polynomial coefficients, e.g. from FPO7_benchnoise.mat) are required.');
end

if any(f(:) == 0)
    error('mod_scan_fpo7_bench_noise_f:zeroFrequency', ...
        'f must not contain 0 - log10(0) is undefined.');
end

logf = log10(f);
log10_noise_f = noise_coefs.n0 + noise_coefs.n1.*logf + noise_coefs.n2.*logf.^2 + noise_coefs.n3.*logf.^3;
noise_f = 10.^log10_noise_f;

end %end function
