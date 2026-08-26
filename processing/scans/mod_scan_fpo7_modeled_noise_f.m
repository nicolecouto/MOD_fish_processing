function noise_f_modeled = mod_scan_fpo7_modeled_noise_f(f, T, fs, electronics_filter, thermistor_coefs, amp_coefs)
% mod_scan_fpo7_modeled_noise_f        Part of MOD_fish_processing
%
% noise_f_modeled = mod_scan_fpo7_modeled_noise_f(f, T, fs, electronics_filter, thermistor_coefs, amp_coefs)
%
% DESCRIPTION
%   mod_scan_fpo7_noise_f.m's theoretical Johnson+amplifier noise model,
%   converted into the same domain as a real recorded Pt_volt_f - i.e. what
%   that model predicts the noise floor would actually look like once
%   digitized, so it can be compared directly against an observed spectrum
%   the same way mod_scan_fpo7_bench_noise_f.m's measured curve already can
%   be (see that function's NOTES).
%
%   mod_scan_fpo7_noise_f.m's output is referred to the amplifier's input -
%   the point where the (already thermally-lagged) bridge signal and the
%   Johnson/amplifier noise combine, upstream of the AFE's downstream
%   electronics/ADC anti-alias filter. Both signal and noise pass through
%   that downstream filter on their way to being recorded, so:
%
%     noise_f_modeled = electronics_filter .* mod_scan_fpo7_noise_f(f, T, fs, ...)
%
%   Deliberately NOT also multiplied by the FP07 thermal-rolloff filter
%   (mod_scan_fpo7_transfer_function.m), unlike how a real temperature
%   SIGNAL gets treated (e.g. in mod_scan_fpo7_volts_to_Tg_spectrum.m,
%   which deconvolves by electronics_filter .* H_thermal together). That
%   thermal filter models how EXTERNAL water temperature is converted into
%   bead resistance via the bead's own finite heat capacity - a physical
%   process real signal has to go through. Johnson noise (from the
%   thermistor's own resistance, thermal agitation of its electrons) and
%   amplifier input-referred noise are both generated electrically, at/
%   after that thermal conversion has already happened - they never pass
%   through the bead's thermal inertia at all, so multiplying them by that
%   filter here would be physically wrong, not just an unnecessary extra
%   step.
%
%   (The flip side of this same point: anywhere this "as recorded" noise
%   floor is later deconvolved back OUT of raw-voltage space - e.g. to
%   overlay against a deconvolved temperature-gradient wavenumber spectrum
%   like mod_scan_fpo7_volts_to_Tg_spectrum.m's Pt_Tg_k - dividing by the
%   FULL electronics_filter .* H_thermal (the same combination real signal
%   is deconvolved by) makes the electronics_filter cancel back out exactly,
%   leaving division by H_thermal alone. Not implemented here - this
%   function only handles the forward direction, into "as recorded" units;
%   any deconvolution back out of that is left to the caller.)
%
% INPUTS
%   f                  - frequency vector [Hz], passed through to
%                         mod_scan_fpo7_noise_f.m - must not contain 0.
%   T                  - local water temperature [degC], passed through.
%   fs                 - sample rate [Hz], passed through.
%   electronics_filter - AFE electronics/ADC transfer function, magnitude-
%                         squared, same size as f (e.g. from
%                         MODsetup_define_filters.m /
%                         metadata.AFE.(channel).electronics_filter - see
%                         mod_scan_fpo7_volts_to_Tg_spectrum.m). Required,
%                         not defaulted to 1: silently defaulting it would
%                         silently reproduce exactly the bug this function
%                         exists to fix - comparing an unfiltered
%                         theoretical noise floor directly against a
%                         filtered real spectrum (see mod_scan_fpo7_noise_f.m's
%                         "not yet called by anything" CALLED BY note for
%                         where that comparison was actually being made
%                         without this correction).
%   thermistor_coefs   - (optional) passed through to mod_scan_fpo7_noise_f.m.
%   amp_coefs          - (optional) passed through to mod_scan_fpo7_noise_f.m.
%
% OUTPUTS
%   noise_f_modeled - FP07 electronic noise floor [V^2/Hz], in the same
%                     domain as a real recorded Pt_volt_f, same size as f.
%
% CALLED BY
%   Not yet called by anything within this repo (see mod_scan_fpo7_noise_f.m's
%   own CALLED BY note - this is one step further down that same not-yet-
%   wired-in path).
%
% CALLS
%   mod_scan_fpo7_noise_f.m
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

if nargin < 4 || isempty(electronics_filter)
    error('mod_scan_fpo7_modeled_noise_f:missingElectronicsFilter', ...
        ['electronics_filter is required and is not defaulted to 1 - silently defaulting it would ' ...
        'reproduce the exact "compare unfiltered theoretical noise against a filtered real spectrum" ' ...
        'bug this function exists to fix. See NOTES.']);
end

if nargin < 5
    thermistor_coefs = [];
end
if nargin < 6
    amp_coefs = [];
end

if ~isequal(size(electronics_filter), size(f))
    error('mod_scan_fpo7_modeled_noise_f:sizeMismatch', ...
        'electronics_filter must be the same size as f (%s vs %s).', ...
        mat2str(size(electronics_filter)), mat2str(size(f)));
end

noise_f = mod_scan_fpo7_noise_f(f, T, fs, thermistor_coefs, amp_coefs);
noise_f_modeled = electronics_filter .* noise_f;

end %end function
