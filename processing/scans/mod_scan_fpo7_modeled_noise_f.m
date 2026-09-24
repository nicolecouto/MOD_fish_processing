function noise_f_modeled = mod_scan_fpo7_modeled_noise_f(f, T, fs, electronics_filter, thermistor_coefs, amp_coefs)
% mod_scan_fpo7_modeled_noise_f        Part of MOD_fish_processing
%
% noise_f_modeled = mod_scan_fpo7_modeled_noise_f(f, T, fs, electronics_filter, thermistor_coefs, amp_coefs)
%
% DESCRIPTION
%   Theoretical FP07 electronic noise floor (Johnson/thermal noise +
%   amplifier noise, see the local subfunction fpo7_noise_f below),
%   converted into the same domain as a real recorded Pt_volt_f - i.e. what
%   that model predicts the noise floor would actually look like once
%   digitized, so it can be compared directly against an observed spectrum
%   the same way mod_scan_fpo7_bench_noise_f.m's measured curve already can
%   be (see that function's NOTES).
%
%   The subfunction's raw output is referred to the amplifier's input - the
%   point where the (already thermally-lagged) bridge signal and the
%   Johnson/amplifier noise combine, upstream of the AFE's downstream
%   electronics/ADC anti-alias filter. Both signal and noise pass through
%   that downstream filter on their way to being recorded, so:
%
%     noise_f_modeled = electronics_filter .* fpo7_noise_f(f, T, fs, ...)
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
%   The dominant temperature effect on the noise itself is not the explicit
%   T in the Johnson noise formula (vn^2 = 4*kB*T*R - only ~10% over a
%   0-30 degC range, since T there is in Kelvin) but R itself: an NTC
%   thermistor's resistance is exponentially sensitive to temperature, and
%   noise power scales with R (linearly for Johnson noise, quadratically
%   for the amplifier's current-noise term) - so the true noise floor can
%   vary substantially across the ocean's temperature range in a way a
%   fixed-R model (e.g. the old MOD_fish_lib
%   EPSILOMETER/CALIBRATION/FPO7/make_FPO7_notdiffnoise.m, which hardcoded
%   R = 150 kOhm and T = 293 K for every probe/scan) never captures. R(T)
%   is computed from the thermistor manufacturer's own published
%   resistance-temperature curve (see NOTES), not a fixed constant.
%
% INPUTS
%   f                  - frequency vector [Hz], passed through to the local
%                         noise model - must not contain 0 (the 1/f
%                         amplifier-noise shaping is undefined there).
%   T                  - local water temperature [degC], scalar. The real,
%                         in-situ value for this scan/segment (e.g. from
%                         CTD) - NOT a fixed placeholder.
%   fs                 - sample rate [Hz], scalar. Required, not defaulted -
%                         varies by electronics generation/deployment (e.g.
%                         MADRE-era 325 Hz vs. some SOM-era 320 Hz
%                         deployments). Not currently used by either noise
%                         term's math (Johnson noise no longer divides by
%                         it - see NOTES; amplifier noise never did) - kept
%                         required rather than silently dropped, in case a
%                         future noise term needs it, and to keep this
%                         function's call signature unchanged for existing
%                         callers.
%   electronics_filter - AFE electronics/ADC transfer function, magnitude-
%                         squared, same size as f (e.g. from
%                         MODsetup_define_filters.m /
%                         metadata.AFE.(channel).electronics_filter, or
%                         mod_scan_adc_filter.m for a legacy Profile file
%                         with no metadata.AFE.(ch) to resolve it from -
%                         see mod_scan_fpo7_volts_to_Tg_spectrum.m).
%                         Required, not defaulted to 1: silently defaulting
%                         it would silently reproduce exactly the bug this
%                         function exists to fix - comparing an unfiltered
%                         theoretical noise floor directly against a
%                         filtered real spectrum.
%   thermistor_coefs   - (optional) struct describing the thermistor's
%                        resistance-temperature curve. Fields, all defaulted
%                        to our actual FP07 probe's confirmed values (see
%                        NOTES - "Thermistor identification: Amphenol
%                        material type B9"):
%                          .A, .B, .C, .D - coefficients of
%                            Ln(Rt/R25) = A + B/T + C/T^2 + D/T^3
%                            (T in Kelvin), fitted to Amphenol's published
%                            Material Type B9 Rt/R25 table (see NOTES -
%                            Amphenol does not publish A/B/C/D for this
%                            curve directly, only the table these were
%                            fitted to). Default: our probes' confirmed
%                            curve (see NOTES).
%                          .R25 - nominal resistance [ohms] at the
%                            reference temperature, default 200e3 - the
%                            FP07DB204N part number's own published spec
%                            (200 kOhm +/-25% @ 25 degC), not an estimate
%                            (see NOTES).
%                          .T25_degC - reference temperature [degC] the
%                            curve/R25 are normalized to, default 25
%                            (standard thermistor convention; matches the
%                            FP07DB204N datasheet's "@ 25 C" spec point).
%                          .valid_range_degC - [Tmin Tmax], if given, T
%                            outside this range triggers a warning
%                            (extrapolating the curve) rather than an error.
%                            Default [-10 40] - the range the default
%                            A/B/C/D were fitted over (see NOTES).
%   amp_coefs          - (optional) struct of amplifier-circuit parameters,
%                        independent of the thermistor/temperature. Fields,
%                        all defaulted to the ADA4805 first-stage amp's
%                        published input-referred noise specs (see NOTES):
%                          .voltage_noise      - [V/sqrt(Hz)], default 100e-9
%                          .current_noise_20hz - [A/sqrt(Hz)], default 3e-12
%
% OUTPUTS
%   noise_f_modeled - FP07 electronic noise floor [V^2/Hz], in the same
%                     domain as a real recorded Pt_volt_f, same size as f.
%
% CALLED BY
%   Not yet called by anything within this repo's production pipeline -
%   mod_scan_fpo7_cutoff.m still uses the bench-measured curve
%   (mod_scan_fpo7_bench_noise_f.m), per PLAN.md's "bench noise stays for
%   now" decision. This function is exercised today only by
%   MODvis_spectra.m's "modeled" noise-floor/cutoff overlay.
%
% CALLS
%   (none other than its own local subfunction, fpo7_noise_f, below)
%
% NOTES
%   Two independent noise sources are combined by the local fpo7_noise_f
%   subfunction, both purely theoretical - no fudge factor (the old
%   model's amp_coefs.ff scale factor was dropped, not carried forward -
%   see below):
%     1. Johnson (thermal) noise: vn^2 = 4*kB*T*R - already the flat/white
%        power spectral density [V^2/Hz] by the standard Johnson-Nyquist
%        formula, used directly (fixed 2026-09-22: an earlier version of
%        this code divided by the Nyquist bandwidth fs/2 here, a units
%        error that made this term inversely, and unphysically, proportional
%        to sample rate).
%     2. Amplifier noise: the first-stage amp's own input voltage noise,
%        plus its input current noise converted to a voltage through the
%        bridge resistance R/2, shaped as 1/f (unity at 20 Hz).
%
%   Thermistor identification: Amphenol material type B9, confirmed via
%   the actual part number purchased, FP07DB204N (Mouser #527-FP07DB204N,
%   "Industrial Temperature Sensors Fast tip, 0.1sec still air response,
%   200K Ohm 25% @ 25 C"). Decoding Amphenol's FP-series ordering scheme
%   (AAS-920-267C-Thermometrics-NTC-TypeFP07-031814-web.pdf, "Ordering
%   Information"): FP-07-D-B-204-N =
%     FP07  - model number
%     D     - probe length code, 0.5 in (12.7 mm)
%     B     - material system code
%     204   - zero-power resistance @ 25 degC: first two digits are
%             significant figures, third digit is the power-of-ten
%             multiplier, i.e. 20 x 10^4 = 200,000 ohms
%     N     - tolerance code, +/-25%
%   The same datasheet's "Material System" table lists, for code letter B,
%   R-vs-T curve 9 as covering the 130 kOhm-240 kOhm nominal range at 25
%   degC - 200 kOhm falls inside it, and no other row for code letter B
%   does, so curve B9 is the unambiguous match. (This also directly
%   confirms R25 = 200 kOhm for this specific probe, not the 150 kOhm this
%   function's R25 default used previously, which was only a generic
%   estimate from Le Boyer et al. (in prep, JTECH) - see docs/references.md
%   - not tied to a specific part number.)
%
%   A/B/C/D coefficients: Amphenol's "Sensor Temperature Resistance
%   Curves Reference Guide" (AAS-913-318B-Temp-Resistance-Curves-091614-
%   web.pdf) does NOT publish A/B/C/D for material type B9 directly - the
%   "Glass Bead" curve family (material types A1-A7, B8-B15, D16-D17,
%   which is where B9 lives) is documented there only as a Ratio/Beta
%   table plus a Rt/R25-nominal-vs-temperature table (-60 to 95 degC,
%   5 degC steps), unlike the guide's other material families (2, 3, 4, 5,
%   F, G, H, C-, D-, S-, GC-, GE-series), which do get A/B/C/D tables
%   directly. The A/B/C/D below were therefore fitted here (ordinary
%   least squares, Ln(Rt/R25) = A + B/T + C/T^2 + D/T^3, T in Kelvin)
%   against that same published B9 Rt/R25 table, restricted to -10 to 40
%   degC (comfortable margin around real ocean water temperatures) to
%   keep the fit tight over the range this function is actually used in.
%   Max residual error of the fit against Amphenol's tabulated Rt/R25
%   values over that range: 0.028%, comparable to the fit quality Amphenol
%   itself reports for the material families it does publish A/B/C/D for.
%   Resulting default coefficients:
%     A =  -1.4080858228e+01
%     B =   4.2335348726e+03
%     C =   5.1757377172e+04
%     D =  -1.8570870261e+07
%   Outside [-10 40] degC (the default valid_range_degC) these coefficients
%   are an extrapolation of a fit that was only tuned to that window, not a
%   wider-range Amphenol-published fit - re-fit against a wider slice of
%   the same table (source PDF, page 29) if a deployment ever needs it.
%
%   amp_coefs.ff removed (not carried forward, not defaulted to 1). The
%   old code (make_FPO7_notdiffnoise.m, and the "Arnaud's paper" noise
%   model it was derived from - see
%   ~/Library/CloudStorage/Dropbox/SIO/projects/epsi/projects/21_06_redefine_fpo7_noise/,
%   which names the actual op-amp, ADA4805) multiplied the amplifier-noise
%   term by a fudge factor (default 200) that stood in for "the Tdiff
%   filter" - a *frequency-dependent* analog differentiator/pre-emphasis
%   circuit, not a temperature effect and not a real noise source of its
%   own. An earlier version of this function carried that factor forward
%   unchanged, flagged as a still-open question. It's now resolved: this
%   repo's own docs/workflow/L2_calc_chi.md and PLAN.md (Section 6.2/8,
%   mod_scan_fpo7_transfer_function.m's NOTES) independently confirm - by
%   checking MOD_fish_lib's actual blt2021_0715 process config - that
%   Meta_Data.MAP.temperature was never 'Tdiff' for any deployment this
%   repo processes; the bench noise calibration file itself is literally
%   named FPO7_notdiffnoise.mat for the same reason. Tdiff isn't a term in
%   our signal chain at all, so a Tdiff-derived correction factor was
%   never modeling anything physically real here - both Johnson and
%   amplifier noise are now purely theoretical, no fudge factor.
%
%   Why the underlying model matters beyond its shape: this repo's own
%   docs/workflow/L2_calc_chi.md "Known limitations" section already
%   flags, independently of this investigation, that the full-profile
%   chi_obs/Profile.chi match against a real ASTRAL profile has "kc itself
%   diverging from Profile.tg_kc for many scans despite identical bench
%   noise coefficients and algorithm" - not yet root-caused there. A
%   single generic noise curve with no probe-specific or temperature-
%   dependent behavior is exactly the kind of thing that would produce
%   scan-to-scan kc drift of that sort. This function is a step toward
%   testing that hypothesis, not yet a fix - not wired into
%   mod_scan_fpo7_cutoff.m (see CALLED BY).
%
%   fpo7_noise_f was originally its own top-level file,
%   mod_scan_fpo7_noise_f.m - folded in here as a private subfunction since
%   in practice it's never useful except through this wrapper (comparing
%   its raw, unfiltered output directly against a real recorded spectrum
%   is the exact mistake this wrapper exists to prevent - see DESCRIPTION).
%   Any caller that used to call mod_scan_fpo7_noise_f.m directly needs to
%   call this function instead, supplying electronics_filter (e.g. via
%   mod_scan_adc_filter.m).
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

noise_f = fpo7_noise_f(f, T, fs, thermistor_coefs, amp_coefs);
noise_f_modeled = electronics_filter .* noise_f;

end %end function

function noise_f = fpo7_noise_f(f, T, fs, thermistor_coefs, amp_coefs)
% Theoretical FP07 electronic noise (Johnson/thermal + amplifier noise),
% referred to the amplifier's input (upstream of the AFE electronics/ADC
% filter - see the parent function's DESCRIPTION for why that filter is
% applied one level up, not in here). Originally its own top-level file,
% mod_scan_fpo7_noise_f.m - see the parent function's NOTES for why it's a
% private subfunction here instead. Parameter/physics documentation lives
% in the parent function's INPUTS/NOTES, not duplicated here.

%% Validate required, non-defaultable inputs (see parent NOTES - do not silently default these)
if nargin < 3 || isempty(fs)
    error('mod_scan_fpo7_modeled_noise_f:missingFs', ...
        'fs (sample rate [Hz]) is required and is not defaulted - it varies by electronics generation/deployment.');
end

if any(f(:) == 0)
    error('mod_scan_fpo7_modeled_noise_f:zeroFrequency', ...
        'f must not contain 0 - the 1/f amplifier-noise shaping is undefined there.');
end

%% Defaults - our confirmed FP07DB204N (Amphenol material type B9) probe (see parent NOTES)
if isempty(thermistor_coefs)
    thermistor_coefs = struct();
end
if ~all(isfield(thermistor_coefs, {'A', 'B', 'C', 'D'}))
    thermistor_coefs.A = -1.4080858228e+01;
    thermistor_coefs.B =  4.2335348726e+03;
    thermistor_coefs.C =  5.1757377172e+04;
    thermistor_coefs.D = -1.8570870261e+07;
end

if isempty(amp_coefs)
    amp_coefs = struct();
end
if ~isfield(amp_coefs, 'voltage_noise') || isempty(amp_coefs.voltage_noise)
    amp_coefs.voltage_noise = 100e-9; % V/sqrt(Hz), ADA4805 first-stage amp - see parent NOTES
end
if ~isfield(amp_coefs, 'current_noise_20hz') || isempty(amp_coefs.current_noise_20hz)
    amp_coefs.current_noise_20hz = 3e-12; % A/sqrt(Hz) at 20 Hz, ADA4805 - see parent NOTES
end

if ~isfield(thermistor_coefs, 'R25') || isempty(thermistor_coefs.R25)
    thermistor_coefs.R25 = 200e3; % ohms - FP07DB204N datasheet spec, see parent NOTES
end
if ~isfield(thermistor_coefs, 'T25_degC') || isempty(thermistor_coefs.T25_degC)
    thermistor_coefs.T25_degC = 25; % standard convention, matches FP07DB204N spec point - see parent NOTES
end
if ~isfield(thermistor_coefs, 'valid_range_degC') || isempty(thermistor_coefs.valid_range_degC)
    thermistor_coefs.valid_range_degC = [-10 40]; % default A/B/C/D fit range - see parent NOTES
end

valid_range = thermistor_coefs.valid_range_degC;
if T < valid_range(1) || T > valid_range(2)
    warning('mod_scan_fpo7_modeled_noise_f:outsideValidRange', ...
        'T = %.2f degC is outside the coefficients'' stated valid range [%.1f %.1f] degC - Rt/R25 extrapolated.', ...
        T, valid_range(1), valid_range(2));
end

%% Physical constants
kB = 1.380649e-23; % J/K, exact by SI definition (2019 redefinition)

%% Resistance at the actual local water temperature (Amphenol Ln(Rt/R25) curve)
T_K = T + 273.15;
Rt_R25 = exp(thermistor_coefs.A ...
    + thermistor_coefs.B ./ T_K ...
    + thermistor_coefs.C ./ T_K.^2 ...
    + thermistor_coefs.D ./ T_K.^3);
R = thermistor_coefs.R25 * Rt_R25;

%% Johnson (thermal) noise - flat across frequency
% 4*kB*T*R IS the noise power spectral density (V^2/Hz) by the standard
% Johnson-Nyquist formula - it's already a per-Hz quantity, not a total
% power over some bandwidth that needs dividing down. An earlier version of
% this code divided by the Nyquist bandwidth (fs/2) here, which was a units
% error: it made this term inversely proportional to sample rate, with no
% physical basis (Johnson noise from a resistor doesn't depend on how fast
% you sample it) - see parent function's NOTES.
vn2 = 4 * kB * T_K * R;
noise_johnson = vn2 * ones(size(f));

%% Amplifier noise - input voltage noise + input current noise (through R/2), 1/f-shaped, unity at 20 Hz
noise_current = amp_coefs.current_noise_20hz * R / 2;
noise_amp = noise_current.^2 + amp_coefs.voltage_noise.^2;
noise_amp = noise_amp .* (20 ./ f);

%% Combine
noise_f = noise_johnson + noise_amp;

end %end subfunction
