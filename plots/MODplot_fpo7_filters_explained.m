function fig = MODplot_fpo7_filters_explained(opts)
% MODplot_fpo7_filters_explained        Part of MOD_fish_processing
%
% fig = MODplot_fpo7_filters_explained(...)
%
% DESCRIPTION
%   Purely illustrative, no real data: three panels building up what the
%   two filters chi's deconvolution divides out (mod_scan_adc_filter.m,
%   mod_scan_fpo7_transfer_function.m) actually look like and why, as a
%   companion to docs/concepts/temperature_to_chi_walkthrough.md's
%   "What do the filters look like?" section.
%
%     1. sinc^n family (n=1,2,4) over a normalized frequency axis (first
%        crossing always at 1) - just MATLAB's own sinc(), the same math
%        mod_scan_adc_filter.m calls internally, to build intuition for
%        "steeper rolloff at higher n" before looking at the real filter.
%     2. The actual AFE electronics/ADC filter this repo uses:
%        mod_scan_adc_filter.m's amplitude response (sinc^4, denominator
%        stretched to 2*f(end) so the first crossing lands past Nyquist)
%        against its squared (power) form - the form
%        mod_scan_fpo7_volts_to_Tg_spectrum.m actually divides out -
%        showing why squaring steepens the rolloff again.
%     3. mod_scan_fpo7_transfer_function.m (the FP07 thermal-lag filter)
%        at every combination of two tau0 values and two fall speeds -
%        both a longer time constant AND a slower fall speed steepen the
%        rolloff (see that function's own DESCRIPTION for why: tau =
%        tau0*|w|^exponent, exponent<0, so smaller |w| means larger tau).
%
% OPTIONS (all optional name-value)
%   f_max     - frequency axis max [Hz] for panels 2-3. Default: 160 (a
%               320 Hz sample rate's Nyquist frequency, this repo's most
%               common epsi_mako fast-channel rate).
%   n_list    - sinc exponents for panel 1. Default: [1 2 4].
%   tau_list  - FP07 time constants [s] for panel 3. Default: [0.005
%               0.0083] (the historical MOD_fish_lib default and this
%               repo's typical calibrated ASTRAL value - see
%               docs/workflow/L2_calc_chi.md).
%   w_list    - fall speeds [m/s] for panel 3. Default: [0.7 0.2].
%
% OUTPUTS
%   fig - the figure handle.
%
% CALLED BY
%   (interactive/diagnostic use only, and
%   docs/concepts/temperature_to_chi_walkthrough.md's generating script
%   for its own committed image)
%
% CALLS
%   mod_scan_adc_filter.m, mod_scan_fpo7_transfer_function.m (reused
%   directly, not reimplemented; aguFigure, subtightplot assumed already
%   on the MATLAB path, matching this repo's other MODplot scripts)
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

arguments
    opts.f_max (1,1) double {mustBePositive} = 160
    opts.n_list (1,:) double {mustBePositive} = [1 2 4]
    opts.tau_list (1,2) double {mustBePositive} = [0.005 0.0083]
    opts.w_list (1,2) double {mustBePositive} = [0.7 0.2]
end

fig = aguFigure(13, 4.4, 11);
g = [0.05 0.06]; v = [0.16 0.14]; h = [0.07 0.02];
colorsN = lines(numel(opts.n_list));

%% Panel 1: sinc^n family, normalized frequency
ax1 = subtightplot(1,3,1,g,v,h);
hold on
fn = linspace(0, 3, 600);
for i = 1:numel(opts.n_list)
    plot(fn, sinc(fn).^opts.n_list(i), 'Color', colorsN(i,:), 'LineWidth', 1.5, ...
        'DisplayName', sprintf('sinc(f)^{%d}', opts.n_list(i)));
end
yline(0, 'Color', [0.6 0.6 0.6], 'HandleVisibility', 'off');
grid on
xlabel('f (normalized - first crossing at 1)'); ylabel('sinc(f)^n');
title('1. sinc^n family');
legend('location','northeast');

%% Panel 2: the real electronics filter, amplitude vs. power (squared)
ax2 = subtightplot(1,3,2,g,v,h);
f = linspace(0, opts.f_max, 1000);
H_adc = mod_scan_adc_filter(f, 'sinc4');
electronics_filter = H_adc.^2;
hold on
plot(f, H_adc, 'Color', [0.2 0.4 0.8], 'LineWidth', 1.5, 'DisplayName', 'H_{adc} (amplitude, sinc^4)');
plot(f, electronics_filter, 'Color', [0.8 0.2 0.2], 'LineWidth', 1.5, 'DisplayName', 'H_{adc}^2 (power - what gets divided out)');
grid on
xlabel('f [Hz]'); ylabel('response');
title(sprintf('2. Electronics/ADC filter (f_{max}=%.0f Hz)', opts.f_max));
legend('location','northeast');

%% Panel 3: thermal-lag filter across tau/speed combinations
ax3 = subtightplot(1,3,3,g,v,h);
hold on
lineStyles = {'-', '--'};
for iTau = 1:2
    for iW = 1:2
        H_thermal = mod_scan_fpo7_transfer_function(f, opts.w_list(iW), opts.tau_list(iTau), -0.32);
        plot(f, H_thermal, 'Color', colorsN(min(iTau,size(colorsN,1)),:), 'LineStyle', lineStyles{iW}, ...
            'LineWidth', 1.5, 'DisplayName', sprintf('\\tau_0=%.4g s, w=%.1f m/s', opts.tau_list(iTau), opts.w_list(iW)));
    end
end
grid on
xlabel('f [Hz]'); ylabel('H_{thermal}');
title('3. FP07 thermal-lag filter');
legend('location','northeast','FontSize',7);

end %end function
