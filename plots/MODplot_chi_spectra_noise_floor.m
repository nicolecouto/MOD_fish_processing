function fig = MODplot_chi_spectra_noise_floor(spec, opts)
% MODplot_chi_spectra_noise_floor        Part of MOD_fish_processing
%
% fig = MODplot_chi_spectra_noise_floor(spec, ...)
%
% DESCRIPTION
%   One-scan FPO7/chi noise-floor diagnostic: wavenumber-space temperature-
%   gradient spectrum on top, its frequency-space precursor spectrum below
%   (taller figure, two stacked panels). Each panel shows the raw spectrum
%   against 3x the noise floor - the actual SNR=3 threshold each cutoff is
%   found from (see NOTES) - for THREE noise models, each its own color:
%   green ("unadjusted"), orange ("adjusted" - the unadjusted curve
%   rescaled to this scan's own high-frequency level), and purple
%   ("theoretical" - a physics-based Johnson+amplifier noise model, as
%   opposed to the other two, which are typically bench-measured), plus
%   each one's own cutoff drawn in the same color, so the cutoff visibly
%   sits where its matching 3x-noise line crosses the spectrum. The
%   wavenumber panel additionally overlays three Batchelor curves - one fit
%   using each cutoff's chi, same color pairing - since chi (and so the
%   Batchelor curve) depends on which cutoff you accept; the frequency
%   panel has no Batchelor overlay (no direct frequency-domain equivalent).
%
%   `spec` is a flat one-scan struct rather than a whole profile struct, so
%   this function is reusable from any pipeline that can assemble one -
%   e.g. an astral exploratory script working from its own scan-level
%   workspace variables, or a thin apex_epsi adapter that plucks one scan's
%   fields out of the `data`/`data_smooth` struct produced by
%   calculate_dissrate_like_apf_obp.m. See EXAMPLE.
%
% INPUTS (required)
%   spec - struct with fields (all plain vectors unless noted):
%     f, Pt_volt_f                          - frequency [Hz], raw FPO7 volts^2/Hz spectrum
%     k, Pt_Tg_k                            - wavenumber [cpm], temperature-gradient spectrum
%     noise_volt_f_unadjusted, noise_volt_f_adjusted, noise_volt_f_theoretical   - frequency-space noise floor (V^2/Hz), same length as f
%     noise_Tg_k_unadjusted, noise_Tg_k_adjusted, noise_Tg_k_theoretical         - wavenumber-space noise floor (Tg units), same length as f (plotted at k=f/abs(w), not necessarily spec.k's own grid)
%     fc_unadjusted, fc_adjusted, fc_theoretical                - scalar cutoff frequency [Hz], one per noise model
%     w                                      - scalar fall speed [m/s], used to convert fc -> kc = fc/w for the wavenumber-panel cutoff lines
%     chi_unadjusted, chi_adjusted, chi_theoretical             - scalar chi [K^2/s], annotated as text
%     batchelor_k_unadjusted, batchelor_Psg_unadjusted         - theoretical Batchelor curve fit from the unadjusted cutoff's chi (caller-computed - see NOTES)
%     batchelor_k_adjusted, batchelor_Psg_adjusted             - theoretical Batchelor curve fit from the adjusted cutoff's chi
%     batchelor_k_theoretical, batchelor_Psg_theoretical       - theoretical Batchelor curve fit from the theoretical cutoff's chi
%   Optional: pr (scalar pressure, dbar) or scanID, used in the title/annotation if present.
%
% OPTIONS (name-value)
%   label - appended to the figure's title, e.g. a scan number or pressure
%           label. Default: '' (no title)
%
% OUTPUTS
%   fig - the figure handle.
%
% EXAMPLE
%   % apex_epsi: pick a scan near a target pressure out of data/data_smooth
%   [~,iScan] = min(abs(data.pr - targetPr));
%   spec.f = data.f{iScan};                      spec.Pt_volt_f = data.Pt_volt_f{iScan};
%   spec.k = data.k{iScan};                       spec.Pt_Tg_k = data.Pt_Tg_k{iScan};
%   spec.noise_volt_f_unadjusted = data.noise_volt_f_unadjusted{iScan};
%   spec.noise_volt_f_adjusted   = data.noise_volt_f_adjusted{iScan};
%   spec.noise_volt_f_theoretical = data.noise_volt_f_theoretical{iScan};
%   spec.noise_Tg_k_unadjusted   = data.noise_Tg_k_unadjusted{iScan};
%   spec.noise_Tg_k_adjusted     = data.noise_Tg_k_adjusted{iScan};
%   spec.noise_Tg_k_theoretical  = data.noise_Tg_k_theoretical{iScan};
%   spec.fc_unadjusted = data.fcutoff_temp_unadjusted(iScan);
%   spec.fc_adjusted   = data.fcutoff_temp(iScan);
%   spec.fc_theoretical = data.fcutoff_temp_theoretical(iScan);
%   spec.w = data.w(iScan);
%   spec.chi_unadjusted = data.chi_unadjusted(iScan);  spec.chi_adjusted = data.chi(iScan);
%   spec.chi_theoretical = data.chi_theoretical(iScan);
%   [spec.batchelor_k_unadjusted,spec.batchelor_Psg_unadjusted] = ...
%       batchelor(data.epsilon(iScan),data.chi_unadjusted(iScan),data.nu(iScan),data.kappa(iScan));
%   [spec.batchelor_k_adjusted,spec.batchelor_Psg_adjusted] = ...
%       batchelor(data.epsilon(iScan),data.chi(iScan),data.nu(iScan),data.kappa(iScan));
%   [spec.batchelor_k_theoretical,spec.batchelor_Psg_theoretical] = ...
%       batchelor(data.epsilon(iScan),data.chi_theoretical(iScan),data.nu(iScan),data.kappa(iScan));
%   spec.pr = data.pr(iScan);
%   MODplot_chi_spectra_noise_floor(spec, 'label', sprintf('Profile4, p=%.0f dbar',spec.pr));
%
% CALLED BY
%   apex_epsi's explore_apex_epsi_profile.ipynb (depth-picker cell); astral's
%   noise-floor exploratory scripts in mod_fish_lib/data_for_reorg
%   (different repos; interactive/diagnostic use only)
%
% CALLS
%   (aguFigure, subtightplot, xlog, ylog - assumed already on the MATLAB
%   path, matching this repo's other MODplot scripts)
%
% NOTES
%   Each cutoff (fc_unadjusted/fc_adjusted/fc_theoretical, set by the
%   caller) is found where the smoothed spectrum crosses 3x that SAME
%   noise model - never a different one - which is why only the 3x curves
%   are plotted here (the bare 1x noise curves aren't what the cutoff
%   search actually used, and including them made it unclear which line
%   the cutoff corresponded to).
%
%   The Batchelor curves are computed by the CALLER, not this function -
%   apex_epsi and astral each have their own `batchelor`-type function with
%   a different calling convention (apex_epsi's process/batchelor.m
%   generates its own wavenumber grid from epsilon; MOD_fish_processing's
%   own mod_scan_batchelor_spectrum.m evaluates at a caller-supplied k). To
%   keep this function usable from either without a path/naming collision,
%   it only ever plots a [k,Psg] curve pair it's handed, never computes one.
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

arguments
    spec
    opts.label (1,:) char = ''
end

darkGray = [0.3 0.3 0.3];
green  = [0.2 0.6 0.2];  % unadjusted
orange = [0.9 0.5 0.1];  % adjusted
purple = [0.5 0.2 0.6];  % theoretical

kc_unadjusted  = spec.fc_unadjusted/abs(spec.w);
kc_adjusted    = spec.fc_adjusted/abs(spec.w);
kc_theoretical = spec.fc_theoretical/abs(spec.w);

% The noise-floor curves are built on f (which excludes the f=0 bin), while
% Pt_Tg_k/k may include it - so the noise curves get their own, consistently
% sized wavenumber axis here rather than reusing spec.k.
k_noise = spec.f./abs(spec.w);

fig = aguFigure(8,8,12);
g = [0.14 0.02];
v = [0.07 0.18]; % top margin wide enough for sgtitle - too small and it renders inside the top axes instead of above them
h = [0.14 0.03];

%% Top: wavenumber-space temperature-gradient spectrum
axK = subtightplot(2,1,2,g,v,h);
hold on
plot(spec.k,spec.Pt_Tg_k,'Color',darkGray,'DisplayName','\Phi_{T_z}(k)');
plot(k_noise,3*spec.noise_Tg_k_unadjusted,'Color',green,'DisplayName','3x noise floor (unadjusted)');
plot(k_noise,3*spec.noise_Tg_k_adjusted,'Color',orange,'DisplayName','3x noise floor (adjusted)');
plot(k_noise,3*spec.noise_Tg_k_theoretical,'Color',purple,'DisplayName','3x noise floor (theoretical)');
plot(spec.batchelor_k_unadjusted,spec.batchelor_Psg_unadjusted,'Color',green,'DisplayName','Batchelor (unadjusted \chi)');
plot(spec.batchelor_k_adjusted,spec.batchelor_Psg_adjusted,'Color',orange,'DisplayName','Batchelor (adjusted \chi)');
plot(spec.batchelor_k_theoretical,spec.batchelor_Psg_theoretical,'Color',purple,'DisplayName','Batchelor (theoretical \chi)');
xline(kc_unadjusted,'Color',green,'LineWidth',1.3,'HandleVisibility','off');
xline(kc_adjusted,'Color',orange,'LineWidth',1.3,'HandleVisibility','off');
xline(kc_theoretical,'Color',purple,'LineWidth',1.3,'HandleVisibility','off');
xlog
ylog
% Batchelor curves fall off toward zero well past the Kolmogorov rolloff -
% that plunge is real, but letting it drive the y-axis autoscale makes the
% rest of the panel unreadable, so clip to the observed spectrum/noise range.
yDataK = [spec.Pt_Tg_k(:); 3*spec.noise_Tg_k_unadjusted(:); 3*spec.noise_Tg_k_adjusted(:); 3*spec.noise_Tg_k_theoretical(:)];
yDataK = yDataK(isfinite(yDataK) & yDataK>0);
if ~isempty(yDataK)
    axK.YLim = 10.^[floor(log10(min(yDataK))) ceil(log10(max(yDataK)))];
end
% Likewise, the Batchelor curves carry their own auto-generated k-grid
% (from process/batchelor.m's eta-based k0/kmax), which can run much wider
% than the actual spectrum - clip the x-axis to the observed data instead.
xDataK = [spec.k(:); k_noise(:)];
xDataK = xDataK(isfinite(xDataK) & xDataK>0);
if ~isempty(xDataK)
    axK.XLim = 10.^[floor(log10(min(xDataK))) ceil(log10(max(xDataK)))];
end
xlabel('k [cpm]')
ylabel('\Phi_{T_z} [K^2 m^{-1} cpm^{-1}]')
title('Wavenumber space')
text(0.03,0.05,sprintf('\\chi_{unadj} = %.2e\n\\chi_{adj} = %.2e\n\\chi_{theo} = %.2e',...
    spec.chi_unadjusted,spec.chi_adjusted,spec.chi_theoretical),...
    'Units','normalized','HorizontalAlignment','left','VerticalAlignment','bottom','FontSize',11);
legend('location','eastoutside');
grid on

%% Bottom: frequency-space raw spectrum - same noise-floor/cutoff treatment, no Batchelor
axF = subtightplot(2,1,1,g,v,h);
hold on
plot(spec.f,spec.Pt_volt_f,'Color',darkGray,'DisplayName','P_{volt}(f)');
plot(spec.f,3*spec.noise_volt_f_unadjusted,'Color',green,'DisplayName','3x noise floor (unadjusted)');
plot(spec.f,3*spec.noise_volt_f_adjusted,'Color',orange,'DisplayName','3x noise floor (adjusted)');
plot(spec.f,3*spec.noise_volt_f_theoretical,'Color',purple,'DisplayName','3x noise floor (theoretical)');
xline(spec.fc_unadjusted,'Color',green,'LineWidth',1.3,'HandleVisibility','off');
xline(spec.fc_adjusted,'Color',orange,'LineWidth',1.3,'HandleVisibility','off');
xline(spec.fc_theoretical,'Color',purple,'LineWidth',1.3,'HandleVisibility','off');
xlog
ylog
yDataF = [spec.Pt_volt_f(:); 3*spec.noise_volt_f_unadjusted(:); 3*spec.noise_volt_f_adjusted(:); 3*spec.noise_volt_f_theoretical(:)];
yDataF = yDataF(isfinite(yDataF) & yDataF>0);
if ~isempty(yDataF)
    axF.YLim = 10.^[floor(log10(min(yDataF))) ceil(log10(max(yDataF)))];
end
xlabel('f [Hz]')
ylabel('P_{volt} [V^2 Hz^{-1}]')
title('Frequency space')
legend('location','eastoutside');
grid on

if ~isempty(opts.label)
    sgtitle(opts.label);
end

end
