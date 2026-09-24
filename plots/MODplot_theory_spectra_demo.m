function [figBatchelor, figPanchev] = MODplot_theory_spectra_demo(opts)
% MODplot_theory_spectra_demo        Part of MOD_fish_processing
%
% [figBatchelor, figPanchev] = MODplot_theory_spectra_demo(...)
%
% DESCRIPTION
%   Purely theoretical companion to
%   docs/concepts/spectral_filtering_and_noise_floors.md: takes no real
%   data, just decade sweeps of epsilon and chi plus one representative
%   fall speed, and draws the Batchelor (temperature) and Panchev (shear)
%   model spectra twice each - once on their native wavenumber axis (k,
%   cpm - batchelor_spectrum.m/panchev_spectrum.m's own convention), and
%   once relabeled onto a frequency axis (f, Hz) via Taylor's
%   frozen-turbulence hypothesis k = f/abs(w) and the same
%   wavenumber<->frequency PSD Jacobian
%   mod_scan_fpo7_volts_to_Tg_spectrum.m / mod_scan_shear_volts_to_shear_spectrum.m
%   use, run in reverse (see NOTES). This is the "ideal target shape"
%   half of that doc's question: what a fully-calibrated, fully-
%   deconvolved spectrum should look like before it reaches a noise
%   floor, in each domain.
%
%   The Batchelor figure specifically overlays TWO independent curve
%   families to make batchelor_spectrum.m's own amplitude-vs-shape
%   split visible rather than just asserted: an epsilon sweep at fixed
%   chi (warm colors) - epsilon moves the rolloff location; and a chi
%   sweep at fixed epsilon (cool colors) - chi only shifts the curve
%   vertically, never moving the rolloff, since kb depends on
%   epsilon/nu/ktemp alone (see batchelor_spectrum.m's own DESCRIPTION).
%   The Panchev figure has no such split - epsilon sets both the level
%   and the rolloff there, so there's no fixed-shape amplitude parameter
%   to sweep separately (see panchev_spectrum.m/nasmyth_spectrum.m).
%
% INPUTS (all optional name-value)
%   epsilon    - dissipation rate sweep [W/kg], one curve per value, at
%                fixed chi (see `chi` below). Default: logspace(-10,-6,5)
%                (1e-10:1e-6, a decade apart) - spans quiescent to
%                energetic ocean turbulence.
%   fall_speed - scalar [m/s]. Default: 0.65 (epsi_mako's ASTRAL median,
%                see docs/concepts/spectral_windowing.md) - only sets
%                where the frequency axis's rolloff lands (k=f/w), not
%                the wavenumber-domain curve shape itself.
%   chi        - scalar [degC^2/s], Batchelor curve's fixed amplitude
%                for the epsilon sweep (kb, and so the rolloff shape,
%                depends only on epsilon/nu/ktemp, not chi - see
%                batchelor_spectrum.m). Default: 1e-8.
%   chi_sweep  - chi sweep [degC^2/s], one curve per value, at fixed
%                epsilon (see `epsilon_for_chi_sweep` below). Default:
%                logspace(-10,-6,5) - same span/count as `epsilon`, for
%                visual symmetry between the two families.
%   epsilon_for_chi_sweep - scalar [W/kg], the fixed epsilon the chi
%                sweep is evaluated at. Default: 1e-8 (matches `chi`'s
%                default value, so both families default to the same
%                "1e-8" reference point from opposite directions).
%   nu         - kinematic viscosity [m^2/s] for the Batchelor curve.
%                Default: 1e-6 (toolbox/seawater/visc.m, representative
%                of ~10 degC seawater).
%   ktemp      - thermal diffusivity [m^2/s]. Default: 1.4e-7
%                (toolbox/seawater/ktemp.m, representative seawater
%                value).
%   kvis       - kinematic viscosity for the Panchev/shear curve
%                [m^2/s]. Default: 1e-6 (same physical quantity as nu,
%                just batchelor_spectrum.m and panchev_spectrum.m name
%                their own argument differently).
%   k          - wavenumber grid [cpm], shared by both figures. Default:
%                logspace(-1,3,400) - wide enough to show the full
%                rolloff at both ends of the default epsilon sweep for
%                both spectra (checked by hand for these defaults; a
%                very different epsilon/nu/ktemp/kvis choice may need a
%                wider grid).
%
% OUTPUTS
%   figBatchelor, figPanchev - the two figure handles.
%
% CALLED BY
%   (interactive/diagnostic use only, and
%   docs/concepts/spectral_filtering_and_noise_floors.md's generating
%   script for its own committed images)
%
% CALLS
%   batchelor_spectrum.m, panchev_spectrum.m (aguFigure, subtightplot,
%   xlog, ylog assumed already on the MATLAB path, matching this repo's
%   other MODplot scripts)
%
% NOTES
%   The frequency-domain panels are NOT the shape a raw t1_volt/s1_volt
%   spectrum actually has - they are what that spectrum should look like
%   AFTER calibration to physical units and AFTER deconvolving the
%   probe's dynamic response and the AFE's electronics/ADC filter (see
%   docs/concepts/spectral_filtering_and_noise_floors.md). The Jacobian
%   used to relabel each wavenumber curve onto a frequency axis here is
%   the exact inverse of mod_scan_fpo7_volts_to_Tg_spectrum.m's step 3 /
%   mod_scan_shear_volts_to_shear_spectrum.m's step 3
%   (X_k(k) = (2*pi*k).^2 .* X_f(f) .* abs(w), k=f/abs(w)) - solved here
%   for X_f given X_k, since batchelor_spectrum.m/panchev_spectrum.m only
%   ever produce the wavenumber-domain quantity directly.
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

arguments
    opts.epsilon (1,:) double {mustBePositive} = logspace(-10,-6,5)
    opts.fall_speed (1,1) double {mustBePositive} = 0.65
    opts.chi (1,1) double {mustBePositive} = 1e-8
    opts.chi_sweep (1,:) double {mustBePositive} = logspace(-10,-6,5)
    opts.epsilon_for_chi_sweep (1,1) double {mustBePositive} = 1e-8
    opts.nu (1,1) double {mustBePositive} = 1e-6
    opts.ktemp (1,1) double {mustBePositive} = 1.4e-7
    opts.kvis (1,1) double {mustBePositive} = 1e-6
    opts.k (1,:) double {mustBePositive} = logspace(-1,3,400)
end

epsilon = opts.epsilon;
chi_sweep = opts.chi_sweep;
w = opts.fall_speed;
k = opts.k;
f = k * abs(w); % Taylor's frozen-turbulence hypothesis - same convention as mod_scan_*_spectrum.m's own k = f/abs(w), solved for f

colorsEps = autumn(numel(epsilon)); % epsilon-sweep family (moves the rolloff) - warm
colorsChi = winter(numel(chi_sweep)); % chi-sweep family (pure amplitude shift) - cool, visually distinct from the epsilon family
% Clip each panel's y-axis to this many decades below its own GLOBAL peak (across every
% curve in the panel, not each curve's own peak) - both model spectra numerically underflow
% toward 0 well past their rolloff, and letting autoscale follow that tail down compresses
% the actual rolloff into an unreadable sliver at the top. Needs to be large enough for the
% Batchelor panels specifically: the chi sweep spans 4 decades of pure amplitude (chi's peak
% value scales linearly with chi, by construction - see batchelor_spectrum.m), and the dimmest
% of those curves still needs ~8 more decades below ITS OWN peak to show its full rolloff -
% too small a floor here would visually truncate the low-chi curves' rolloff and make it look
% like chi moves the rolloff location, which it does not (checked by hand: peak k is bit-
% identical, 30.243 cpm, across the whole default chi sweep at fixed epsilon).
FLOOR_DECADES = 13;

%% Figure 1: Batchelor (temperature-gradient)
figBatchelor = aguFigure(9,5.2,11);
g = [0.12 0.06]; v = [0.14 0.20]; h = [0.09 0.02]; % v(2)=0.20: top margin wide enough for both the per-panel titles and the sgtitle above them (see MODplot_chi_spectra_noise_floor.m's same note)

axK = subtightplot(1,2,1,g,v,h);
hold on
for i = 1:numel(epsilon)
    Psg_k = batchelor_spectrum(epsilon(i), opts.chi, opts.nu, opts.ktemp, k);
    Psg_k = reshape(Psg_k, size(k)); % batchelor_spectrum.m always returns a column (it forces k to a column internally), unlike panchev_spectrum.m which preserves the caller's orientation - reshape defensively so it matches this script's row-oriented k/f before any elementwise op against them
    plot(k, Psg_k, 'Color', colorsEps(i,:), 'DisplayName', sprintf('\\epsilon=%.0e (\\chi=%.0e)', epsilon(i), opts.chi));
end
for i = 1:numel(chi_sweep)
    Psg_k = batchelor_spectrum(opts.epsilon_for_chi_sweep, chi_sweep(i), opts.nu, opts.ktemp, k);
    Psg_k = reshape(Psg_k, size(k));
    plot(k, Psg_k, 'Color', colorsChi(i,:), 'DisplayName', sprintf('\\chi=%.0e (\\epsilon=%.0e)', chi_sweep(i), opts.epsilon_for_chi_sweep));
end
xlog; ylog; grid on
clipYToPeak(axK, FLOOR_DECADES);
xlabel('k [cpm]'); ylabel('\Phi_{T_z} [degC^2 m^{-1} cpm^{-1}]');
title('Wavenumber space');
legend('location','southwest','NumColumns',2,'FontSize',7);

axF = subtightplot(1,2,2,g,v,h);
hold on
for i = 1:numel(epsilon)
    Psg_k = batchelor_spectrum(epsilon(i), opts.chi, opts.nu, opts.ktemp, k);
    Psg_k = reshape(Psg_k, size(k)); % see note above
    Pt_T_f = Psg_k ./ ((2*pi*k).^2 * abs(w)); % inverse of mod_scan_fpo7_volts_to_Tg_spectrum.m step 3
    plot(f, Pt_T_f, 'Color', colorsEps(i,:), 'DisplayName', sprintf('\\epsilon=%.0e (\\chi=%.0e)', epsilon(i), opts.chi));
end
for i = 1:numel(chi_sweep)
    Psg_k = batchelor_spectrum(opts.epsilon_for_chi_sweep, chi_sweep(i), opts.nu, opts.ktemp, k);
    Psg_k = reshape(Psg_k, size(k));
    Pt_T_f = Psg_k ./ ((2*pi*k).^2 * abs(w));
    plot(f, Pt_T_f, 'Color', colorsChi(i,:), 'DisplayName', sprintf('\\chi=%.0e (\\epsilon=%.0e)', chi_sweep(i), opts.epsilon_for_chi_sweep));
end
xlog; ylog; grid on
clipYToPeak(axF, FLOOR_DECADES);
xlabel('f [Hz]'); ylabel('\Phi_T [degC^2 Hz^{-1}]');
title(sprintf('Frequency space (w=%.2f m/s)', abs(w)));
legend('location','southwest','NumColumns',2,'FontSize',7);
sgtitle(sprintf('Batchelor spectrum: warm=\\epsilon sweep at \\chi=%.0e, cool=\\chi sweep at \\epsilon=%.0e (\\nu=%.0e m^2/s, \\kappa_T=%.0e m^2/s)', opts.chi, opts.epsilon_for_chi_sweep, opts.nu, opts.ktemp));

%% Figure 2: Panchev (shear)
figPanchev = aguFigure(9,4.6,11);

axK2 = subtightplot(1,2,1,g,v,h);
hold on
for i = 1:numel(epsilon)
    Pxx_k = panchev_spectrum(epsilon(i), opts.kvis, k);
    plot(k, Pxx_k, 'Color', colorsEps(i,:), 'DisplayName', sprintf('\\epsilon=%.0e', epsilon(i)));
end
xlog; ylog; grid on
clipYToPeak(axK2, FLOOR_DECADES);
xlabel('k [cpm]'); ylabel('\Phi_{shear} [s^{-2} cpm^{-1}]');
title('Wavenumber space');
legend('location','southwest');

axF2 = subtightplot(1,2,2,g,v,h);
hold on
for i = 1:numel(epsilon)
    Pxx_k = panchev_spectrum(epsilon(i), opts.kvis, k);
    Ps_velocity_f = Pxx_k ./ ((2*pi*k).^2 * abs(w)); % inverse of mod_scan_shear_volts_to_shear_spectrum.m step 3
    plot(f, Ps_velocity_f, 'Color', colorsEps(i,:), 'DisplayName', sprintf('\\epsilon=%.0e', epsilon(i)));
end
xlog; ylog; grid on
clipYToPeak(axF2, FLOOR_DECADES);
xlabel('f [Hz]'); ylabel('\Phi_{velocity} [m^2 s^{-2} Hz^{-1}]');
title(sprintf('Frequency space (w=%.2f m/s)', abs(w)));
legend('location','southwest');
sgtitle(sprintf('Panchev spectrum: \\nu=%.0e m^2/s', opts.kvis));

end %end function

function clipYToPeak(ax, floorDecades)
% Restricts ax's y-limits to floorDecades below the tallest curve already
% plotted on it - both model spectra numerically underflow toward (but
% never exactly reach, until clamped) 0 well past their rolloff, and
% letting autoscale follow that tail down over hundreds of decades
% squashes the actual, visually meaningful rolloff into an unreadable
% sliver at the top of the axes.
yAll = [];
for ln = findobj(ax, 'Type', 'line')'
    yAll = [yAll; ln.YData(:)]; %#ok<AGROW>
end
yAll = yAll(isfinite(yAll) & yAll > 0);
if isempty(yAll)
    return
end
yTop = max(yAll);
yFloor = yTop * 10^(-floorDecades);
ax.YLim = [yFloor, yTop*2];
end
