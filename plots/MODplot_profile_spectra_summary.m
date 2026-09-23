function fig = MODplot_profile_spectra_summary(data, pressure_range, opts)
% MODplot_profile_spectra_summary        Part of MOD_fish_processing
%
% fig = MODplot_profile_spectra_summary(data, pressure_range, ...)
%
% DESCRIPTION
%   Profile-summary diagnostic: fall speed, epsilon and chi profiles
%   (restricted to pressure_range), with 4 representative scans picked
%   out - shallow-quarter max epsilon (red), deep-quarter min epsilon
%   (dark blue), and two intermediate picks (orange/light blue) evenly
%   spaced by pressure between them - plus each of those 4 scans' own
%   epsilon (shear) and chi (temperature-gradient) spectra, each overlaid
%   with a theoretical Panchev/Batchelor curve built from that scan's own
%   fitted epsilon/chi rather than a fixed nominal value (the rolloff
%   wavenumber of both curves depends on epsilon, so a mismatched nominal
%   epsilon would shift the whole reference curve).
%
%   Call it twice - once per processing version (e.g. onboard-w vs
%   smoothed-w) - to compare them side by side; this function always
%   produces exactly one figure per call.
%
% INPUTS (required)
%   data            - per-scan turbulence struct with fields pr, w,
%                      epsilon, chi, epsi_fom, chi_fom, nu, kappa (all
%                      n_scans x 1), and k, Ps_shear_k, Pt_Tg_k (each an
%                      n_scans x 1 cell array of per-scan vectors) - the
%                      shape produced by apex_epsi's
%                      calculate_dissrate_like_apf_obp.m. See NOTES.
%   pressure_range  - [pmin pmax], dbar. Both the displayed pressure
%                      window and the window the 4 representative scans
%                      are picked from.
%
% OPTIONS (name-value)
%   label - appended to the figure's title, e.g. 'onboard w' or
%           'smoothed w', to tell apart figures from repeated calls.
%           Default: '' (no title)
%
% OUTPUTS
%   fig - the figure handle. Each of the 8 spectra axes carries its own
%         scan's pr/epsilon-or-chi/fom/kc in UserData (a struct), and the
%         4 chi-spectra axes are identifiable within fig by
%         YAxisLocation=='right' (the only column that uses it) - so a
%         caller can pull individual spectra/values back out of fig
%         without recomputing anything, e.g. to overlay a subset of them
%         in a new figure. See EXAMPLE.
%
% EXAMPLE
%   data = calculate_dissrate_like_apf_obp(data_from_float, apf_obp, 0);
%   data_smooth = calculate_dissrate_like_apf_obp(data_from_float, apf_obp, 1);
%   MODplot_profile_spectra_summary(data, [0 420], 'label', 'onboard w');
%   MODplot_profile_spectra_summary(data_smooth, [0 420], 'label', 'smoothed w');
%   MODplot_profile_spectra_summary(data, [150 250], 'label', 'onboard w, zoomed');
%
% CALLED BY
%   apex_epsi's explore_apex_epsi_profile.ipynb (a different repo;
%   interactive/diagnostic use only)
%
% CALLS
%   panchev.m, batchelor.m - from apex_epsi/code/EPSILOMETER_alb/EPSILON/process/
%   (aguFigure, subtightplot, xlog, ylog)
%
% NOTES
%   data is apex_epsi's ad hoc per-scan turbulence struct, not this
%   repo's own L1/L2 profile struct - the latter carries spectra/tiling
%   but no precomputed epsilon/chi/Panchev-Batchelor fits, so it can't be
%   passed in directly.
%
%   panchev.m/batchelor.m are not vendored in this repo and must already
%   be on the MATLAB path (apex_epsi's own notebook adds them via
%   addpath(genpath(AE.paths.epsi_library)) before calling this) - the
%   same assumed-already-on-path convention this repo's other MODplot
%   scripts already use for aguFigure/subtightplot.
%
%   Exactly 4 representative scans are chosen; the shallow/deep-quarter +
%   two-intermediate-picks selection logic is not generalized to an
%   arbitrary count.
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

arguments
    data
    pressure_range (1,2) double
    opts.label (1,:) char = ''
end

darkGray = [0.3 0.3 0.3];
epsColors = [215 25 28; 253 174 97; 171 217 233; 44 123 182]/255; % warm (high eps) to cool (low eps)

%% Pick 4 representative scans within pressure_range: red is the actual
% maximum epsilon in the shallow quarter of the window, dark blue the
% actual minimum in the deep quarter (rather than the window-wide
% minimum, which can land in the middle), and orange/light blue are
% evenly spaced (by pressure) between the two, at the 1/3 and 2/3 points.
pr = data.pr(:);
epsilon = data.epsilon(:);
validIdx = find(isfinite(epsilon) & pr >= pressure_range(1) & pr <= pressure_range(2));
epsVals = epsilon(validIdx);
prVals = pr(validIdx);

prEdges = min(prVals) + [0 1 3 4]/4*range(prVals);
topRegion = find(prVals <= prEdges(2));
bottomRegion = find(prVals >= prEdges(3));

[~,iMax] = max(epsVals(topRegion));
[~,iMin] = min(epsVals(bottomRegion));
chosenScans = nan(1,4);
chosenScans(1) = validIdx(topRegion(iMax)); % red: peak epsilon, shallow quarter
chosenScans(4) = validIdx(bottomRegion(iMin)); % dark blue: minimum epsilon, deep quarter

prTopPick = prVals(topRegion(iMax));
prBottomPick = prVals(bottomRegion(iMin));
midTargets = prTopPick + [1 2]/3*(prBottomPick - prTopPick); % orange, light blue
for iP = 1:2
    [~,cand] = min(abs(prVals - midTargets(iP)));
    chosenScans(iP+1) = validIdx(cand);
end

targetPr = pr(chosenScans);
chosenColors = epsColors; % row order matches chosenScans order (1=red,2=orange,3=lightblue,4=darkblue)
[~,prOrder] = sort(targetPr);
chosenScans = chosenScans(prOrder);
chosenColors = chosenColors(prOrder,:);

%% figure
fig = aguFigure(18,10,14);
g = [0.02 0.015];
v = [0.08 0.18];
h = [0.08 0.03];

% Custom horizontal layout: columns 1-3 (fall speed, epsilon, chi)
% squeezed narrow with a small gap between them, then a wide gap before
% the two spectra columns so their pressure/value/fom annotations have
% room without crowding the chi axis.
marginL = 0.06;
marginR = 0.02;
gapSmall = 0.010;
gapBig = 0.05;
gapSpec = 0.012;
wCol = 0.12;
xCol = marginL + (0:2)*(wCol+gapSmall);
xSpec1 = xCol(3) + wCol + gapBig;
wSpec = (1 - marginR - xSpec1 - gapSpec)/2;
xSpec2 = xSpec1 + wSpec + gapSpec;

clear ax axEps axChi

ax(1) = subtightplot(4,5,[1 6 11 16],g,v,h);
ax(1).Position([1 3]) = [xCol(1) wCol];
plot(data.w,pr,'Color',darkGray);
xlabel('Fall speed [m s^{-1}]')
ylabel('Pressure [dbar]')

ax(2) = subtightplot(4,5,[2 7 12 17],g,v,h);
ax(2).Position([1 3]) = [xCol(2) wCol];
hold on
plot(epsilon,pr,'Color',darkGray);
for iS = 1:4
    plot(epsilon(chosenScans(iS)),pr(chosenScans(iS)),'o',...
        'MarkerFaceColor',chosenColors(iS,:),'MarkerEdgeColor','k');
end
xlog
xlabel('\epsilon [W kg^{-1}]')

ax(3) = subtightplot(4,5,[3 8 13 18],g,v,h);
ax(3).Position([1 3]) = [xCol(3) wCol];
hold on
plot(data.chi,pr,'Color',darkGray);
for iS = 1:4
    plot(data.chi(chosenScans(iS)),pr(chosenScans(iS)),'o',...
        'MarkerFaceColor',chosenColors(iS,:),'MarkerEdgeColor','k');
end
xlog
xlabel('\chi [K^2 s^{-1}]')

for iS = 1:4
    iScan = chosenScans(iS);

    axEps(iS) = subtightplot(4,5,5*(iS-1)+4,g,v,h);
    plot(data.k{iScan},data.Ps_shear_k{iScan},'Color',chosenColors(iS,:));
    hold on
    [kPan,Pxx] = panchev(epsilon(iScan),data.nu(iScan),data.k{iScan});
    plot(kPan,Pxx,'--k');
    % chi/epsilon were fit to the observed spectrum only below this cutoff
    % (data.kcutoff_shear / data.fcutoff_temp) - above it, noise/contamination
    % dominate and the theoretical curve isn't expected to track the data.
    xline(data.kcutoff_shear(iScan),'-','Color',[0.85 0.33 0.1],'LineWidth',1.3,'HandleVisibility','off');
    xlog
    ylog
    text(0.03,0.05,sprintf('p = %.0f dbar\n\\epsilon = %.2e\nfom = %.2f',pr(iScan),epsilon(iScan),data.epsi_fom(iScan)),...
        'Units','normalized','HorizontalAlignment','left','VerticalAlignment','bottom','FontSize',11);
    axEps(iS).Position([1 3]) = [xSpec1 wSpec];
    axEps(iS).UserData = struct('pr',pr(iScan),'epsilon',epsilon(iScan),'fom',data.epsi_fom(iScan),'kc',data.kcutoff_shear(iScan));
    if iS < 4
        axEps(iS).XTickLabel = '';
    end
    grid on

    axChi(iS) = subtightplot(4,5,5*(iS-1)+5,g,v,h);
    plot(data.k{iScan},data.Pt_Tg_k{iScan},'Color',chosenColors(iS,:));
    hold on
    [kBatch,Psg] = batchelor(epsilon(iScan),data.chi(iScan),data.nu(iScan),data.kappa(iScan));
    plot(kBatch,Psg,'--k');
    kcTemp = data.fcutoff_temp(iScan)/abs(data.w(iScan));
    xline(kcTemp,'-','Color',[0.85 0.33 0.1],'LineWidth',1.3,'HandleVisibility','off');
    xlog
    ylog
    text(0.03,0.05,sprintf('p = %.0f dbar\n\\chi = %.2e\nfom = %.2f',pr(iScan),data.chi(iScan),data.chi_fom(iScan)),...
        'Units','normalized','HorizontalAlignment','left','VerticalAlignment','bottom','FontSize',11);
    axChi(iS).Position([1 3]) = [xSpec2 wSpec];
    axChi(iS).UserData = struct('pr',pr(iScan),'chi',data.chi(iScan),'fom',data.chi_fom(iScan),'kc',kcTemp);
    if iS < 4
        axChi(iS).XTickLabel = '';
    end
    axChi(iS).YAxisLocation = 'right';
    grid on
end

[ax(:).YDir] = deal('reverse');
[ax(:).YLim] = deal(pressure_range);
[ax(2:3).YTickLabel] = deal('');

[axEps(:).YLim] = deal([1e-9 1e0]);
[axEps(:).XLim] = deal([5e-1 5e2]);
axEps(4).XLabel.String = 'k [cpm]';
axEps(1).Title.String = 'Epsilon spectra';
axEps(2).YLabel.String = '\Phi_{shear} [s^{-2} cpm^{-1}]';

[axChi(:).YLim] = deal([1e-9 1e0]);
[axChi(:).XLim] = deal([5e-1 9e2]);
axChi(4).XLabel.String = 'k [cpm]';
axChi(1).Title.String = 'Chi spectra';
axChi(2).YLabel.String = '\Phi_{T_z} [K^2 s^{-1} cpm^{-1}]';

if ~isempty(opts.label)
    sgtitle(sprintf('Profile summary - %s',opts.label));
end


end
