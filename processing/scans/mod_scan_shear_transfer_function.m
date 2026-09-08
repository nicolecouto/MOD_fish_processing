function H = mod_scan_shear_transfer_function(f, w, lc)
% mod_scan_shear_transfer_function        Part of MOD_fish_processing
%
% H = mod_scan_shear_transfer_function(f, w, lc)
%
% DESCRIPTION
%   Returns the magnitude-squared of the airfoil shear probe's dynamic
%   (single-pole low-pass) frequency response, per Oakey (1982):
%
%       H = 1 ./ (1 + (lc * f / abs(w)).^2)
%
%   Same functional shape as mod_scan_fpo7_transfer_function.m's thermal
%   rolloff (a single-pole low-pass in f/w), but with a fixed spatial
%   cutoff wavelength lc rather than a fall-speed-dependent time constant
%   - the shear probe's dynamic response scales with distance traveled
%   through water, not elapsed time, unlike an FP07 bead's thermal
%   inertia.
%
%   THIS FUNCTION IS ONLY THE PROBE'S OWN DYNAMIC RESPONSE. It does not
%   bundle the AFE electronics/ADC response (metadata.AFE.(channel).
%   electronics_filter, from MODsetup_define_filters.m, which already
%   folds in the shear channel's charge-amp filter) - same separation of
%   concerns as mod_scan_fpo7_transfer_function.m.
%
% INPUTS
%   f  - frequency vector [Hz] (any shape; H comes out the same shape as f)
%   w  - fall speed [m/s], scalar. abs(w) is used internally, so callers
%        do not need to pre-abs it - same convention as
%        mod_scan_fpo7_transfer_function.m.
%   lc - (optional) spatial cutoff wavelength [m], default 0.02 (Oakey
%        1982's original value, ported from MOD_fish_lib's haf_oakey.m -
%        unchanged there since at least the earliest commit in that
%        repo's history).
%
% OUTPUTS
%   H - magnitude-squared transfer function, same size as f.
%
% CALLED BY
%   mod_scan_shear_volts_to_shear_spectrum.m
%
% CALLS
%   (none)
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

if nargin < 3 || isempty(lc)
    lc = 0.02;
end

H = 1 ./ (1 + (lc .* f / abs(w)).^2);

end %end function
