function H = mod_scan_fpo7_transfer_function(f, w, tau0, exponent)
% mod_scan_fpo7_transfer_function        Part of MOD_fish_processing
%
% H = mod_scan_fpo7_transfer_function(f, w, tau0, exponent)
%
% DESCRIPTION
%   Returns the magnitude-squared of the FP07 thermistor's dynamic
%   (single-pole low-pass) frequency response:
%
%       tau = tau0 * abs(w)^exponent
%       H   = 1 ./ (1 + (2*pi*tau*f).^2)
%
%   The tau ~ w^exponent scaling (exponent = -0.32, the tow-tank-measured
%   flow-speed dependence of a glass-rod FP07 thermistor's time constant)
%   is from Gregg, M.C. and Meagher, T.B. (1980), "The dynamic response
%   of glass rod thermistors," J. Geophys. Res., 85(C5), 2779-2786,
%   doi:10.1029/JC085iC05p02779 - see docs/references.md.
%
%   A physical FP07 bead cannot instantaneously track the water
%   temperature around it - it responds like a first-order low-pass
%   filter with time constant tau, and tau itself shrinks as the fish
%   falls faster (more water flow past the bead -> faster thermal
%   equilibration). H(f) is how much of the *true* temperature-gradient
%   spectrum survives at each frequency once the sensor's own inertia has
%   rolled it off; dividing an observed temperature spectrum by H is the
%   deconvolution that recovers what the water was actually doing.
%
%   THIS FUNCTION IS ONLY THE THERMAL ROLLOFF. It deliberately does not
%   bundle the AFE electronics/ADC sinc^4 filter response that the old
%   MOD_fish_lib's get_filters_MADRE.m combined into a single H.FPO7(speed)
%   (H.electFPO7.^2 .* H.magsq(speed)) - that electronics term is a
%   separate, much smaller correction at typical epsi fft_length/Fs (its rolloff
%   sits near Nyquist; the thermal rolloff modeled here sits far below it,
%   around 1/(2*pi*tau) ~ tens of Hz for typical fall speeds) and belongs
%   to modProcess_L1_apply_filters.m (PLAN.md Section 6.2, not started
%   yet), not here. Keeping this function narrowly scoped to just tau
%   is deliberate: it's the one term whose value is in question (see NOTES),
%   and isolating it makes a tau sensitivity study a one-parameter change
%   instead of a multi-term one.
%
%   Also deliberately excludes the old code's "Tdiff" analog-differentiator
%   filter term (H.Tdiff, only relevant for MADRE-era electronics with a
%   physical dT/dt differentiator circuit ahead of the ADC). Confirmed via
%   MOD_fish_lib's actual BLT 2021 processing config
%   (EPSILOMETER/Meta_Data_Process/Meta_Data_Process_blt_2021.txt) that
%   Meta_Data.MAP.temperature was never set to 'Tdiff' for this deployment -
%   i.e. the FP07 channel there is raw (undifferentiated) thermistor
%   voltage, same as every SOM-era deployment this repo processes. This
%   repo has no MAP.temperature concept at all; that is fine as long as it
%   stays true that every deployment using this function has raw FP07
%   voltage, not an analog-differentiated signal.
%
% INPUTS
%   f        - frequency vector [Hz] (any shape; H comes out the same
%              shape as f - see OUTPUTS)
%   w        - fall speed [m/s], scalar. abs(w) is used internally (the
%              rolloff depends on flow speed past the probe, not on
%              descending vs. ascending), so callers do not need to
%              pre-abs it. w = 0 is not a meaningful input - tau/H are
%              only defined for a probe that is actually moving through
%              water; this is the same implicit precondition
%              mod_efe_scan_chi.m always had (it divides by w too, via
%              k = f./w), and is guaranteed upstream by only ever calling
%              this on scans PressureTimeseries.is_down already marked
%              descending.
%   tau0     - (optional) time constant coefficient [s], default 0.005.
%   exponent - (optional) fall-speed exponent (dimensionless), default
%              -0.32.
%
%   tau0/exponent default to the historical MOD_fish_lib values
%   (get_filters_MADRE.m / mod_efe_scan_chi.m / h_fp07.m - identical across
%   every copy in that repo's git history, confirmed unchanged since the
%   very first commit, and traceable to Gregg and Meagher (1980) above -
%   see docs/references.md). They are exposed here as arguments, not hardcoded,
%   specifically so a tau sensitivity comparison (the actual point of this
%   module - see PLAN.md, "how much does changing the time constant affect
%   chi/gamma") is just calling this function twice with different values
%   and comparing the resulting chi, not editing code.
%
% OUTPUTS
%   H - magnitude-squared transfer function, same size as f. Divide a raw
%       temperature-gradient-related spectrum by H to deconvolve (correct
%       for) the thermal rolloff - see mod_scan_fpo7_volts_to_Tg_spectrum.m.
%
% CALLED BY
%   mod_scan_fpo7_volts_to_Tg_spectrum.m
%
% CALLS
%   (none)
%
% NOTES
%   Why this correction matters enough to make tau an explicit,
%   overridable parameter: chi (thermal variance dissipation rate) is
%   computed by integrating the temperature-gradient wavenumber spectrum
%   up to a noise-floor cutoff kc (see mod_scan_fpo7_cutoff.m) - right
%   in the frequency range where H(f) has rolled off the most and this
%   deconvolution matters most. A wrong tau biases chi roughly by how much
%   1/H(f) is wrong right at that cutoff. Epsilon (turbulent kinetic energy
%   dissipation), by contrast, comes entirely from the shear channels and
%   never passes through this function at all - so a tau error does not
%   cancel between chi and epsilon, it goes straight into their ratio,
%   gamma = N^2*chi / (2*epsilon*Tz^2). A factor-of-2 tau error is
%   comparatively unremarkable for chi or epsilon individually, but is a
%   direct factor-of-~2 error in gamma. This is the exact concern that
%   prompted this whole module: MOD_fish_lib's live chi calculation
%   (mod_efe_scan_chi.m) computes this same H(f) (via h_freq.FPO7(w)) but,
%   as of a 2025-10-06 edit (commit 051d80f, "fix linear volts to C
%   conversion"), never actually divides by it anymore - H is computed and
%   silently unused. This module is this repo's from-scratch, documented
%   version of the correction, not a port of that broken call site.
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

if nargin < 3 || isempty(tau0)
    tau0 = 0.005;
end
if nargin < 4 || isempty(exponent)
    exponent = -0.32;
end

tau = tau0 * abs(w)^exponent;
H = 1 ./ (1 + (2*pi*tau*f).^2);

end %end function
