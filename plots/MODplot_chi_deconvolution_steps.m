function fig = MODplot_chi_deconvolution_steps(scanA, scanB, metadata, channel, opts)
% MODplot_chi_deconvolution_steps        Part of MOD_fish_processing
%
% fig = MODplot_chi_deconvolution_steps(scanA, scanB, metadata, channel, ...)
%
% DESCRIPTION
%   Step-by-step, real-data companion to
%   docs/concepts/spectral_filtering_and_noise_floors.md and
%   MODplot_theory_spectra_demo.m: takes two real FP07 scans - meant to be
%   one low-chi and one high-chi example - and shows the actual pipeline
%   arithmetic that turns each one's raw voltage spectrum into a
%   deconvolved temperature-gradient wavenumber spectrum, one operation
%   at a time, rather than the single combined division
%   mod_scan_fpo7_volts_to_Tg_spectrum.m performs internally. Six stacked
%   panels, scanA in `scanA.color` throughout, scanB in `scanB.color`:
%
%     1. Raw Pt_volt_f [V^2/Hz] vs f, plus faint background curves - for
%        each scan, its own real epsilon/nu/ktemp/w held fixed and a
%        decade sweep of chi forward-transformed into raw-volt-equivalent
%        units (the exact inverse of steps 3+5 below): "what would raw
%        volts look like if the water were exactly Batchelor at this
%        scan's real epsilon and this chi." Each scan's real, fixed
%        epsilon is also printed as on-plot text.
%     2. Electronics/ADC filter - metadata.AFE.(channel).electronics_filter
%        vs f. One curve (deployment-constant, shared by both scans).
%     3. Spectrum after calibration + ADC-filter deconvolution:
%        Pt_T_f_step1 = Pt_volt_f .* volts_to_C(1)^2 ./ electronics_filter.
%     4. FP07 thermal-lag filter - mod_scan_fpo7_transfer_function.m,
%        reused directly (not reimplemented), one curve per scan (fall-
%        speed dependent). The equation and this call's tau0/exponent/w
%        are printed as on-plot text.
%     5. Fully deconvolved spectrum: Pt_T_f_step2 = Pt_T_f_step1 ./
%        H_thermal - algebraically identical to what
%        mod_scan_fpo7_volts_to_Tg_spectrum.m's own Pt_T_f would be for
%        the same inputs (same formula, split into two visible divisions
%        instead of one combined H_total division - a decomposition, not
%        a reimplementation).
%     6. Wavenumber spectrum: k=f/abs(w),
%        Pt_Tg_k = (2*pi*k).^2 .* Pt_T_f_step2 .* abs(w) (same Jacobian
%        as mod_scan_fpo7_volts_to_Tg_spectrum.m's step 3), with each
%        scan's own exact Batchelor curve overlaid (batchelor_spectrum.m,
%        using that scan's real fitted chi - the payoff panel). Each
%        scan's chi/epsilon/w are printed again here.
%
% INPUTS (required)
%   scanA, scanB - flat one-scan structs (mirrors
%                  MODplot_chi_spectra_noise_floor.m's convention - this
%                  function only ever plots fields it's handed, no data
%                  loading or legacy-format bridging inside it):
%                    f, Pt_volt_f - frequency [Hz], raw FP07 volts^2/Hz
%                                   spectrum, same shape
%                    w            - fall speed [m/s], scalar
%                    epsilon      - dissipation rate [W/kg], scalar
%                    nu           - kinematic viscosity [m^2/s], scalar
%                    ktemp        - thermal diffusivity [m^2/s], scalar
%                    chi          - thermal variance dissipation rate
%                                   [degC^2/s], scalar - this scan's
%                                   already-fitted/trusted value, used
%                                   only for the panel 6 overlay and the
%                                   panel 1 epsilon/chi annotation, not
%                                   recomputed by this function
%                    label        - char, legend/annotation label
%                    color        - 1x3 RGB, this scan's plot color
%   metadata     - struct with the deployment-constant pieces both scans
%                  share:
%                    metadata.AFE.(channel).volts_to_C - [slope,
%                      intercept] (only slope used, matches
%                      mod_scan_fpo7_volts_to_Tg_spectrum.m's convention)
%                    metadata.AFE.(channel).electronics_filter -
%                      magnitude-squared ADC(+charge-amp) response, same
%                      shape as f
%                    metadata.PROCESS.CHI.time_constant_s,
%                      .fall_speed_exponent - FP07 thermal-lag
%                      parameters (tau0, exponent)
%   channel      - channel name string (e.g. 't1'), for panel labels only
%                  (both scans' fields are already selected for this
%                  channel by the caller).
%
% OPTIONS (name-value)
%   chi_sweep_decades - number of decades each scan's panel-1 background
%                        chi sweep spans, centered on that scan's own
%                        real chi. Default: 2 (i.e. real_chi/10 to
%                        real_chi*10, 5 curves).
%
% OUTPUTS
%   fig - the figure handle.
%
% CALLED BY
%   (interactive/diagnostic use only, and
%   docs/concepts/spectral_filtering_and_noise_floors.md's generating
%   script for its own committed image)
%
% CALLS
%   mod_scan_fpo7_transfer_function.m, batchelor_spectrum.m (reused
%   directly, not reimplemented; aguFigure, subtightplot, xlog, ylog
%   assumed already on the MATLAB path, matching this repo's other
%   MODplot scripts)
%
% EXAMPLE
%   % Real ASTRAL data (external Dropbox path, not part of this repo) -
%   % legacy Profile struct, so field names differ from this repo's own
%   % native L2 output (see MODvis_spectra.m's normalizeLegacyProfile for
%   % the general bridge; this is the minimal version needed here):
%   d = load('.../mod_fish_lib/data_for_reorg/epsi_mako/astral/profiles/nfft512_from_ankitha/profiles_new_v2/Profile025.mat');
%   P = d.Profile; ch = 't1';
%   mkScan = @(idx,label,color) struct('f',P.f(:)','Pt_volt_f',P.Pt_volt_f.(ch)(idx,:), ...
%       'w',P.w(idx),'epsilon',P.epsilon_final(idx),'nu',P.kvis(idx),'ktemp',P.ktemp(idx), ...
%       'chi',P.chi(idx),'label',label,'color',color);
%   scanA = mkScan(37,'chi~1e-9 (scan 37)',[0.1 0.4 0.8]);
%   scanB = mkScan(50,'chi~1e-7 (scan 50)',[0.8 0.1 0.1]);
%   % No setup.yml accompanies this legacy deployment - reconstructed the
%   % minimal metadata this function needs directly from the legacy
%   % Profile.Meta_Data.AFE.(ch) struct and this repo's own filter
%   % functions, rather than guessing: AFE.(ch).cal is identified with
%   % volts_to_C(1) (no intercept term in the legacy struct); tau0=0.0083
%   % is this deployment's actual thermal-lag coefficient (confirmed from
%   % Profile.Meta_Data's own stored function handle, which differs from
%   % this repo's own 0.005 default - a real per-deployment calibration
%   % value, not a repo-wide constant, see mod_scan_fpo7_transfer_function.m).
%   metadata.AFE.(ch).volts_to_C = [P.Meta_Data.AFE.(ch).cal, 0];
%   metadata.AFE.(ch).electronics_filter = mod_scan_adc_filter(P.f(:)', 'sinc4').^2;
%   metadata.PROCESS.CHI.time_constant_s = 0.0083;
%   metadata.PROCESS.CHI.fall_speed_exponent = -0.32;
%   MODplot_chi_deconvolution_steps(scanA, scanB, metadata, ch);
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

arguments
    scanA (1,1) struct
    scanB (1,1) struct
    metadata (1,1) struct
    channel (1,:) char
    opts.chi_sweep_decades (1,1) double {mustBePositive} = 2
end

fig = aguFigure(7.5, 14, 9);
g = [0.045 0.05]; v = [0.04 0.045]; h = [0.13 0.03]; % g(1): row gap wide enough for one panel's x-tick labels + the next panel's title; panel 1's own title carries the channel name, so no separate sgtitle is needed (sgtitle's automatic vertical placement doesn't account for subtightplot's custom margins and rendered inside panel 1's axes instead of above it)
nPanels = 6;

electronics_filter = metadata.AFE.(channel).electronics_filter(:)';
volts_to_C1 = metadata.AFE.(channel).volts_to_C(1);
tau0 = metadata.PROCESS.CHI.time_constant_s;
exponent = metadata.PROCESS.CHI.fall_speed_exponent;

chainA = deconvolutionChain(scanA, electronics_filter, volts_to_C1, tau0, exponent);
chainB = deconvolutionChain(scanB, electronics_filter, volts_to_C1, tau0, exponent);

%% Panel 1: raw spectrum + chi-decade-sweep background curves
subtightplot(nPanels,1,1,g,v,h);
hold on
plotChiBackground(scanA, electronics_filter, volts_to_C1, tau0, exponent, opts.chi_sweep_decades, 0.35);
plotChiBackground(scanB, electronics_filter, volts_to_C1, tau0, exponent, opts.chi_sweep_decades, 0.35);
plot(scanA.f, scanA.Pt_volt_f, 'Color', scanA.color, 'LineWidth', 1.5, 'DisplayName', scanA.label);
plot(scanB.f, scanB.Pt_volt_f, 'Color', scanB.color, 'LineWidth', 1.5, 'DisplayName', scanB.label);
xlog; ylog; grid on
xlabel('f [Hz]'); ylabel('P_{volt} [V^2 Hz^{-1}]');
title(sprintf('1. Raw voltage spectrum (channel %s)', channel));
text(0.02,0.05,sprintf('\\epsilon_A=%.2e W/kg   \\epsilon_B=%.2e W/kg', scanA.epsilon, scanB.epsilon), ...
    'Units','normalized','FontSize',8);
legend('location','eastoutside');

%% Panel 2: electronics/ADC filter (shared, deployment-constant)
subtightplot(nPanels,1,2,g,v,h);
plot(scanA.f, electronics_filter, 'Color', [0.3 0.3 0.3], 'LineWidth', 1.5);
xlog; ylog; grid on
xlabel('f [Hz]'); ylabel('H_{elec}');
title('2. Electronics/ADC filter');

%% Panel 3: after calibration + ADC-filter deconvolution
subtightplot(nPanels,1,3,g,v,h);
hold on
plot(scanA.f, chainA.Pt_T_f_step1, 'Color', scanA.color, 'LineWidth', 1.5, 'DisplayName', scanA.label);
plot(scanB.f, chainB.Pt_T_f_step1, 'Color', scanB.color, 'LineWidth', 1.5, 'DisplayName', scanB.label);
xlog; ylog; grid on
xlabel('f [Hz]'); ylabel('\Phi_T [degC^2 Hz^{-1}]');
title('3. After calibration + ADC deconvolution');
legend('location','eastoutside');

%% Panel 4: FP07 thermal-lag filter
subtightplot(nPanels,1,4,g,v,h);
hold on
plot(scanA.f, chainA.H_thermal, 'Color', scanA.color, 'LineWidth', 1.5, 'DisplayName', scanA.label);
plot(scanB.f, chainB.H_thermal, 'Color', scanB.color, 'LineWidth', 1.5, 'DisplayName', scanB.label);
xlog; ylog; grid on
xlabel('f [Hz]'); ylabel('H_{thermal}');
title('4. FP07 thermal-lag filter');
text(0.02,0.15,'H = 1 / (1 + (2\pi\tau f)^2),   \tau = \tau_0 |w|^{exponent}', ...
    'Units','normalized','FontSize',8);
text(0.02,0.05,sprintf('\\tau_0=%.4g s   exponent=%.2f   w_A=%.3f m/s   w_B=%.3f m/s', ...
    tau0, exponent, scanA.w, scanB.w), 'Units','normalized','FontSize',8);
legend('location','eastoutside');

%% Panel 5: fully deconvolved spectrum
subtightplot(nPanels,1,5,g,v,h);
hold on
plot(scanA.f, chainA.Pt_T_f_step2, 'Color', scanA.color, 'LineWidth', 1.5, 'DisplayName', scanA.label);
plot(scanB.f, chainB.Pt_T_f_step2, 'Color', scanB.color, 'LineWidth', 1.5, 'DisplayName', scanB.label);
xlog; ylog; grid on
xlabel('f [Hz]'); ylabel('\Phi_T [degC^2 Hz^{-1}]');
title('5. Fully deconvolved spectrum');
legend('location','eastoutside');

%% Panel 6: wavenumber spectrum + exact Batchelor overlay
subtightplot(nPanels,1,6,g,v,h);
hold on
plot(chainA.k, chainA.Pt_Tg_k, 'Color', scanA.color, 'LineWidth', 1.5, 'DisplayName', [scanA.label ' (observed)']);
plot(chainB.k, chainB.Pt_Tg_k, 'Color', scanB.color, 'LineWidth', 1.5, 'DisplayName', [scanB.label ' (observed)']);
PsgA = batchelor_spectrum(scanA.epsilon, scanA.chi, scanA.nu, scanA.ktemp, chainA.k);
PsgB = batchelor_spectrum(scanB.epsilon, scanB.chi, scanB.nu, scanB.ktemp, chainB.k);
plot(chainA.k, reshape(PsgA,size(chainA.k)), '--', 'Color', scanA.color, 'LineWidth', 1, 'DisplayName', 'Batchelor fit A');
plot(chainB.k, reshape(PsgB,size(chainB.k)), '--', 'Color', scanB.color, 'LineWidth', 1, 'DisplayName', 'Batchelor fit B');
xlog; ylog; grid on
xlabel('k [cpm]'); ylabel('\Phi_{T_z} [degC^2 m^{-1} cpm^{-1}]');
title('6. Wavenumber spectrum + Batchelor fit');
text(0.02,0.15,sprintf('\\chi_A=%.2e   \\epsilon_A=%.2e   w_A=%.3f m/s', scanA.chi, scanA.epsilon, scanA.w), ...
    'Units','normalized','FontSize',8);
text(0.02,0.05,sprintf('\\chi_B=%.2e   \\epsilon_B=%.2e   w_B=%.3f m/s', scanB.chi, scanB.epsilon, scanB.w), ...
    'Units','normalized','FontSize',8);
legend('location','eastoutside');

end %end function

function chain = deconvolutionChain(scan, electronics_filter, volts_to_C1, tau0, exponent)
% Splits mod_scan_fpo7_volts_to_Tg_spectrum.m's single H_total division
% into the two visible steps this figure plots (see that function's own
% DESCRIPTION for the combined, one-step version of the same formula).
f = scan.f(:)';
Pt_volt_f = scan.Pt_volt_f(:)';
w = scan.w;

H_thermal = mod_scan_fpo7_transfer_function(f, w, tau0, exponent);

Pt_T_f_step1 = (Pt_volt_f * volts_to_C1^2) ./ electronics_filter;
Pt_T_f_step2 = Pt_T_f_step1 ./ H_thermal;

k = f / abs(w);
Pt_Tg_k = (2*pi*k).^2 .* Pt_T_f_step2 * abs(w);

chain = struct('H_thermal', H_thermal, 'Pt_T_f_step1', Pt_T_f_step1, ...
    'Pt_T_f_step2', Pt_T_f_step2, 'k', k, 'Pt_Tg_k', Pt_Tg_k);
end

function plotChiBackground(scan, electronics_filter, volts_to_C1, tau0, exponent, decades, alpha)
% Faint background curves for panel 1: "what would raw volts look like if
% the water were exactly Batchelor at this scan's real epsilon/nu/ktemp/w
% and this chi" - the exact forward (not inverse) chain, i.e. the inverse
% of deconvolutionChain above: ideal wavenumber spectrum -> ideal
% calibrated frequency spectrum (inverse Jacobian) -> ideal raw volts
% (forward-multiply by H_total, un-calibrate).
f = scan.f(:)';
w = scan.w;
k = f / abs(w);
H_thermal = mod_scan_fpo7_transfer_function(f, w, tau0, exponent);
H_total = electronics_filter .* H_thermal;

chi_grid = logspace(log10(scan.chi)-decades/2, log10(scan.chi)+decades/2, 5);
lightColor = 1 - alpha*(1 - scan.color); % blend toward white

for i = 1:numel(chi_grid)
    Psg_k = batchelor_spectrum(scan.epsilon, chi_grid(i), scan.nu, scan.ktemp, k);
    Psg_k = reshape(Psg_k, size(k)); % batchelor_spectrum.m forces a column internally - reshape to match this script's row-oriented f/k, see MODplot_theory_spectra_demo.m's same note
    Pt_T_f_ideal = Psg_k ./ ((2*pi*k).^2 * abs(w));
    Pt_volt_f_ideal = (Pt_T_f_ideal .* H_total) / volts_to_C1^2;
    plot(f, Pt_volt_f_ideal, 'Color', lightColor, 'HandleVisibility', 'off');
end
end
