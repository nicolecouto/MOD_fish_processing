function fig = MODplot_scan_context(data, metadata, target_pressure, channel, opts)
% MODplot_scan_context        Part of MOD_fish_processing
%
% fig = MODplot_scan_context(data, metadata, target_pressure, channel, ...)
%
% DESCRIPTION
%   Diagnostic figure for one scan of one L1 file: how that scan's window
%   relates to its neighbors (between-scan overlap, tied to nfft/dof via
%   MODprocess_single_L1_to_L2.m's scan_step = N_epsi/2 - always ~50% by
%   construction here, unlike the old mod_fish_lib pipeline where scan
%   spacing was a fixed, independent dz), and what pwelch does inside
%   that one scan (within-scan segmenting/windowing/averaging). A
%   hand-rolled re-implementation of pwelch is included and checked
%   against MATLAB's own pwelch as a sanity check that the segment
%   bookkeeping shown is actually what gets computed.
%
%   Does not depend on any precomputed L2 scan table - scan windows are
%   computed here the same way MODprocess_single_L1_to_L2.m computes them
%   internally, so this can be run on a raw L1 file directly.
%
% INPUTS (required)
%   data            - L1 struct. Uses data.epsi.dnum, data.epsi.(channel);
%                      data.ctd.dnum, data.ctd.P
%   metadata         - metadata struct (MODsetup_read_yaml.m). Uses
%                      metadata.PROCESS.nfft, .dof, .Fs_epsi as defaults
%                      (overridable - see OPTIONS)
%   target_pressure - db; the scan whose center pressure is closest to
%                      this is the one plotted
%   channel         - e.g. 't1_volt', 's1_volt' - which data.epsi field
%                      to plot
%
% OPTIONS (name-value)
%   nfft         - override metadata.PROCESS.nfft, to explore "what would
%                  this look like with a different nfft" without editing
%                  metadata. Default: metadata.PROCESS.nfft
%   dof          - override metadata.PROCESS.dof, same idea. Default:
%                  metadata.PROCESS.dof
%   n_neighbors  - scans shown on each side in the context panels.
%                  Default: 8
%   window_type  - 'hamming' | 'hann' | 'rectwin' | 'flattop'. Default:
%                  'hamming'
%   noverlap     - pwelch sub-window overlap, in samples. Default: []
%                  (pwelch's own default, nfft/2)
%
% OUTPUTS
%   fig - the figure handle
%
% EXAMPLE
%   data = load('L1/modsom_07.mat');
%   metadata = MODsetup_read_yaml('meta/metadata.yml');
%   MODplot_scan_context(data, metadata, 50, 't1_volt');
%   MODplot_scan_context(data, metadata, 50, 't1_volt', 'nfft', 2048);

arguments
    data
    metadata
    target_pressure (1,1) double
    channel (1,:) char
    opts.nfft (1,1) double = metadata.PROCESS.nfft
    opts.dof (1,1) double = metadata.PROCESS.dof
    opts.n_neighbors (1,1) double = 8
    opts.window_type (1,:) char {mustBeMember(opts.window_type,{'hamming','hann','rectwin','flattop'})} = 'hamming'
    opts.noverlap = []
end

Fs_epsi = metadata.PROCESS.Fs_epsi;
nfft    = opts.nfft;
dof     = opts.dof;
if nfft ~= metadata.PROCESS.nfft || dof ~= metadata.PROCESS.dof
    fprintf('using nfft=%d, dof=%d (overridden from metadata.PROCESS: nfft=%d, dof=%d)\n', ...
        nfft, dof, metadata.PROCESS.nfft, metadata.PROCESS.dof);
end

%% locate scans the same way MODprocess_single_L1_to_L2.m does: 50%-overlapping
% windows of N_epsi = (dof-1)*nfft samples, step = N_epsi/2
N_epsi    = (dof-1)*nfft;
scan_step = N_epsi/2;
n_samples = numel(data.epsi.dnum);
if n_samples < N_epsi
    error('MODplot_scan_context:tooShort','this file has only %d epsi samples, needs at least N_epsi=%d for one scan at nfft=%d, dof=%d', ...
        n_samples, N_epsi, nfft, dof);
end
scan_starts = 1:scan_step:(n_samples - N_epsi + 1);
n_scans_total = numel(scan_starts);

center_idx  = scan_starts + floor(N_epsi/2) - 1;
center_dnum = data.epsi.dnum(center_idx);
center_P    = interp1(data.ctd.dnum, data.ctd.P, center_dnum, 'linear', 'extrap');

[~, iScan] = min(abs(center_P - target_pressure));
fprintf('scan %d of %d: center pressure = %.2f db (target was %.2f db), N_epsi = %d samples (%.2fs)\n', ...
    iScan, n_scans_total, center_P(iScan), target_pressure, N_epsi, N_epsi/Fs_epsi);

%% context: how this scan's window sits among its neighbors (between-scan view)
nb_idx  = max(1,iScan-opts.n_neighbors):min(n_scans_total,iScan+opts.n_neighbors);
n_nb    = numel(nb_idx);
cmap_nb = turbo(n_nb);

idxE_all = [scan_starts(nb_idx)', scan_starts(nb_idx)'+N_epsi-1];
e_lo = min(idxE_all(:,1)); e_hi = max(idxE_all(:,2));
t_epsi_ctx = ((e_lo:e_hi) - e_lo)'/Fs_epsi;
x_epsi_ctx = detrend(double(data.epsi.(channel)(e_lo:e_hi)));

P0_nb = interp1(data.ctd.dnum, data.ctd.P, data.epsi.dnum(idxE_all(:,1)), 'linear', 'extrap');
P1_nb = interp1(data.ctd.dnum, data.ctd.P, data.epsi.dnum(idxE_all(:,2)), 'linear', 'extrap');
width_db_nb = P1_nb - P0_nb;

%% window + segment bookkeeping for the chosen scan (mirrors what pwelch does internally)
idx0 = scan_starts(iScan);
idx1 = idx0 + N_epsi - 1;
x = detrend(double(data.epsi.(channel)(idx0:idx1)));
t = (0:N_epsi-1)'/Fs_epsi;

switch opts.window_type
    case 'hamming', win = hamming(nfft);
    case 'hann',    win = hann(nfft);
    case 'rectwin', win = rectwin(nfft);
    case 'flattop', win = flattopwin(nfft);
end

noverlap = opts.noverlap;
if isempty(noverlap)
    noverlap = floor(nfft/2);   % pwelch's own default when noverlap = []
end
step = nfft - noverlap;
seg_starts = 1:step:(N_epsi - nfft + 1);
n_segs = numel(seg_starts);

fprintf('window length = %d samples (%.2fs); overlap = %d samples (%.0f%% of window); -> %d segment(s)\n', ...
    nfft, nfft/Fs_epsi, noverlap, 100*noverlap/nfft, n_segs);

%% replicate pwelch by hand, segment by segment
U = sum(win.^2);
nfreq = nfft/2 + 1;
Pxx_segs = zeros(nfreq, n_segs);
seg_raw  = zeros(nfft, n_segs);
seg_win  = zeros(nfft, n_segs);

for i = 1:n_segs
    idx = seg_starts(i):seg_starts(i) + nfft - 1;
    xi  = x(idx);
    xiw = xi .* win;
    seg_raw(:,i) = xi;
    seg_win(:,i) = xiw;

    Xi = fft(xiw, nfft);
    Xi = Xi(1:nfreq);
    Pxx_i = (abs(Xi).^2) / (Fs_epsi*U);
    Pxx_i(2:end-1) = 2*Pxx_i(2:end-1);
    Pxx_segs(:,i) = Pxx_i;
end
Pxx_manual = mean(Pxx_segs, 2);
f_manual = (0:nfreq-1)'*Fs_epsi/nfft;

[Pxx_pwelch, f_pwelch] = pwelch(x, win, noverlap, nfft, Fs_epsi, 'psd');
fprintf('max |manual - pwelch| = %.3e (should be ~0)\n', max(abs(Pxx_manual - Pxx_pwelch)));

%% figure
n_rows = 6;
fig = aguFigure(16, (17/5)*n_rows, 10);
tiledlayout(n_rows,2,'TileSpacing','compact');
cmap = lines(max(n_segs,1));   % segment i's color (cmap(i,:)) is reused in every later panel that shows that segment

% 0a. between-scan overlap, epsi domain: this scan (black) and its
% neighbors (colored), each drawn over its own window, offset by a
% steady per-scan-index climb so "which scan is which" stays unambiguous.
nexttile([1 2]);
off_step_e = 2*range(x_epsi_ctx) / max(2*opts.n_neighbors,1);
hold on
plot(t_epsi_ctx, x_epsi_ctx, 'color',[0.8 0.8 0.8])
for k = 1:n_nb
    ii  = nb_idx(k);
    idx = idxE_all(k,1):idxE_all(k,2);
    tt  = (idx - e_lo)'/Fs_epsi;
    xx  = detrend(double(data.epsi.(channel)(idx)));
    off = (ii - iScan) * off_step_e;
    if ii==iScan
        plot(tt, xx+off, 'k-', 'linewidth', 2.2)
    else
        plot(tt, xx+off, '-', 'color', cmap_nb(k,:), 'linewidth', 1.0)
    end
end
xlabel('time [s], relative to first neighbor start'); ylabel(sprintf('%s (detrended) + offset', strrep(channel,'_','\_')))
title(sprintf('scan %d (black) and %d neighbors on each side - epsi-sample windows', iScan, opts.n_neighbors))

% 0b. same neighborhood in pressure/depth space, Gantt-style: one
% horizontal bar per scan (length = that scan's pressure window width),
% stacked by scan index. Overlap here is ~50% by construction
% (scan_step = N_epsi/2) - shown, not measured, unlike the old
% mod_fish_lib pipeline where it was an incidental side effect of a
% fixed, independent dz.
nexttile([1 2]);
hold on
yline(0, ':', 'color',[0.75 0.75 0.75])
for k = 1:n_nb
    ii = nb_idx(k);
    y  = ii - iScan;
    if ii==iScan
        plot([P0_nb(k) P1_nb(k)],[y y],'k-','linewidth',4)
    else
        plot([P0_nb(k) P1_nb(k)],[y y],'-','color',cmap_nb(k,:),'linewidth',2.2)
    end
end
ylim([-opts.n_neighbors-1, opts.n_neighbors+1])
xlabel('pressure [db]'); ylabel(sprintf('scan index relative to scan %d',iScan))
title(sprintf('scan\\_step = N\\_epsi/2 -> 50%% overlap by construction (median window width = %.2f db)', ...
    median(width_db_nb)))

% 1. full record (black) with every pwelch segment overlaid in its own
% color (cmap(i,:), reused in the panels below), nudged just enough
% alternately below/above the black line to stay visible.
nexttile([1 2]);
tiny_off = 0.02*range(x);
hold on
plot(t, x, 'k-', 'linewidth', 1.3)
for i = 1:n_segs
    idx = seg_starts(i):seg_starts(i)+nfft-1;
    sign_i = 1 - 2*mod(i,2);   % i=1 (odd) -> below, i=2 (even) -> above, i=3 -> below, ...
    off = sign_i*tiny_off;
    plot(t(idx), x(idx)+off, 'color', cmap(i,:), 'linewidth',1.4)
end
xlabel('time [s]'); ylabel(strrep(channel,'_','\_'))
title(sprintf('scan %d: full record (black) with %d segment(s) overlaid, step %d samples (%.0f%% overlap)', ...
    iScan, n_segs, step, 100*noverlap/nfft))

% 2. the window shape itself
nexttile
plot((0:nfft-1)/Fs_epsi, win, 'k-','linewidth',1.5)
xlabel('time within segment [s]'); ylabel('window amplitude')
title(sprintf('%s window, length %d', opts.window_type, nfft))
ylim([0 1.05*max(win)])

% 3. segment 1, raw vs windowed - this is "where the window lives".
% Segment 1's color (cmap(1,:)), solid for raw and dashed for windowed.
nexttile
plot((0:nfft-1)/Fs_epsi, seg_raw(:,1),'-','color',cmap(1,:),'linewidth',1.1); hold on
plot((0:nfft-1)/Fs_epsi, seg_win(:,1),'--','color',cmap(1,:),'linewidth',1.6)
legend('raw segment','windowed segment','location','best')
xlabel('time within segment [s]'); ylabel('amplitude')
title('segment 1: before vs after windowing')

% 4. every segment's own periodogram (in its own segment color) + their
% average (black). Positioned left, 2 row-heights x 1 column so it reads
% as roughly square.
nexttile([2 1])
semilogy(f_manual, Pxx_segs(:,1), 'color', cmap(1,:)); hold on
for i = 2:n_segs
    semilogy(f_manual, Pxx_segs(:,i), 'color', cmap(i,:))
end
semilogy(f_manual, Pxx_manual, 'k-','linewidth',2)
xlabel('frequency [Hz]'); ylabel('PSD')
title(sprintf('%d individual periodogram(s) -> Welch average', n_segs))
xlim([0 Fs_epsi/2])

% 5. hand-rolled Welch vs pwelch, sanity check. Same 2x1 footprint as panel 4.
nexttile([2 1])
semilogy(f_manual, Pxx_manual,'b-','linewidth',2); hold on
semilogy(f_pwelch, Pxx_pwelch,'r--','linewidth',1.5)
legend('manual (by hand)','pwelch','location','best')
xlabel('frequency [Hz]'); ylabel('PSD [units^2/Hz]')
title('sanity check: hand-rolled Welch matches pwelch exactly')
xlim([0 Fs_epsi/2])

end
