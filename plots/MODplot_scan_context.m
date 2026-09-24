function fig = MODplot_scan_context(data, metadata, target_pressure, channel, opts)
% MODplot_scan_context        Part of MOD_fish_processing
%
% fig = MODplot_scan_context(data, metadata, target_pressure, channel, ...)
%
% DESCRIPTION
%   Diagnostic figure for one scan of one L1 file: how that scan's window
%   relates to its neighbors (between-scan overlap, tied to fft_length/
%   fft_segments_per_scan/scan_overlap via MODprocess_single_L1_to_L2.m's
%   scan_step = (1-scan_overlap)*N_epsi, unlike the old mod_fish_lib
%   pipeline where scan spacing was a fixed, independent dz), and what
%   mod_scan_get_spectra.m does inside that one scan (within-scan
%   segmenting/per-segment-detrend/windowing/averaging, at a hardcoded
%   50% overlap - see NOTES). A hand-rolled re-implementation of that
%   Welch average is included and checked against MATLAB's own
%   periodogram (on the same per-segment-detrended segments) as a sanity
%   check that the segment bookkeeping shown is actually what gets
%   computed.
%
%   Does not depend on any precomputed L2 scan table - scan windows are
%   computed here the same way MODprocess_single_L1_to_L2.m computes them
%   internally, so this can be run on a raw L1 file directly.
%
% INPUTS (required)
%   data            - L1 struct. Uses data.epsi.dnum, data.epsi.(channel);
%                      data.ctd.dnum, data.ctd.P
%   metadata         - metadata struct (MODsetup_read_yaml.m). Uses
%                      metadata.PROCESS.fft_length, .fft_segments_per_scan,
%                      .scan_overlap, .Fs_epsi as defaults (overridable -
%                      see OPTIONS)
%   target_pressure - db; the scan whose center pressure is closest to
%                      this is the one plotted
%   channel         - e.g. 't1_volt', 's1_volt' - which data.epsi field
%                      to plot
%
% OPTIONS (name-value)
%   fft_length            - override metadata.PROCESS.fft_length, to
%                            explore "what would this look like with a
%                            different fft_length" without editing
%                            metadata. Default: metadata.PROCESS.fft_length
%   fft_segments_per_scan - override metadata.PROCESS.fft_segments_per_scan,
%                            same idea. Default:
%                            metadata.PROCESS.fft_segments_per_scan
%   scan_overlap          - override metadata.PROCESS.scan_overlap
%                            (fraction, 0-1), same idea. Default:
%                            metadata.PROCESS.scan_overlap
%   n_neighbors           - scans shown on each side in the context
%                            panels. Default: 8
%   window_type           - 'hamming' | 'hann' | 'rectwin' | 'flattop'.
%                            Default: 'hamming'
%
%   No fft_overlap option - the Welch-segment overlap is hardcoded at
%   50% everywhere in this repo (matching mod_scan_get_spectra.m), so
%   this diagnostic tool doesn't re-open it as a variable either.
%
% OUTPUTS
%   fig - the figure handle
%
% EXAMPLE
%   data = load('L1/modsom_07.mat');
%   metadata = MODsetup_read_yaml('meta/metadata.yml');
%   MODplot_scan_context(data, metadata, 50, 't1_volt');
%   MODplot_scan_context(data, metadata, 50, 't1_volt', 'fft_length', 2048);
%
% CALLED BY
%   (interactive/diagnostic use only)
%
% CALLS
%   processing/scans/mod_scan_length_from_segments.m
%   (MATLAB's Signal Processing Toolbox periodogram, detrend, hamming;
%   aguFigure, subtightplot)
%
% NOTES
%   Segments are each individually detrended before their own Hamming
%   window/FFT (matching mod_scan_get_spectra.m's welch_psd_detrend_
%   per_segment, not a single whole-scan detrend) - see
%   docs/concepts/spectral_windowing.md for why that distinction matters.
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

arguments
    data
    metadata
    target_pressure (1,1) double
    channel (1,:) char
    opts.fft_length (1,1) double = metadata.PROCESS.fft_length
    opts.fft_segments_per_scan (1,1) double = metadata.PROCESS.fft_segments_per_scan
    opts.scan_overlap (1,1) double = metadata.PROCESS.scan_overlap
    opts.n_neighbors (1,1) double = 8
    opts.window_type (1,:) char {mustBeMember(opts.window_type,{'hamming','hann','rectwin','flattop'})} = 'hamming'
end

Fs_epsi = metadata.PROCESS.Fs_epsi;
fft_length = opts.fft_length;
N_epsi = mod_scan_length_from_segments(fft_length, opts.fft_segments_per_scan);
if fft_length ~= metadata.PROCESS.fft_length || opts.fft_segments_per_scan ~= metadata.PROCESS.fft_segments_per_scan ...
        || opts.scan_overlap ~= metadata.PROCESS.scan_overlap
    fprintf(['using fft_length=%d, fft_segments_per_scan=%d, scan_overlap=%.2f ' ...
        '(overridden from metadata.PROCESS) -> scan_length=%d\n'], ...
        fft_length, opts.fft_segments_per_scan, opts.scan_overlap, N_epsi);
end

%% locate scans the same way MODprocess_single_L1_to_L2.m does: windows of
% N_epsi = scan_length samples, step = (1-scan_overlap)*N_epsi
scan_step = round((1-opts.scan_overlap)*N_epsi);
n_samples = numel(data.epsi.dnum);
if n_samples < N_epsi
    error('MODplot_scan_context:tooShort','this file has only %d epsi samples, needs at least scan_length=%d for one scan at fft_length=%d', ...
        n_samples, N_epsi, fft_length);
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

%% window + segment bookkeeping for the chosen scan (mirrors
% mod_scan_get_spectra.m's welch_psd_detrend_per_segment)
idx0 = scan_starts(iScan);
idx1 = idx0 + N_epsi - 1;
x_raw = double(data.epsi.(channel)(idx0:idx1));   % NOT detrended - each segment gets its own detrend below
t = (0:N_epsi-1)'/Fs_epsi;

switch opts.window_type
    case 'hamming', win = hamming(fft_length);
    case 'hann',    win = hann(fft_length);
    case 'rectwin', win = rectwin(fft_length);
    case 'flattop', win = flattopwin(fft_length);
end

FFT_OVERLAP = 0.5; % hardcoded - matches mod_scan_fft_seg_starts.m's hardcoded overlap
noverlap = round(FFT_OVERLAP*fft_length);
step = fft_length - noverlap;
seg_starts = 1:step:(N_epsi - fft_length + 1);
n_segs = numel(seg_starts);

fprintf('window length = %d samples (%.2fs); overlap = %d samples (%.0f%% of window); -> %d segment(s)\n', ...
    fft_length, fft_length/Fs_epsi, noverlap, 100*noverlap/fft_length, n_segs);

%% replicate mod_scan_get_spectra.m's welch_psd_detrend_per_segment by hand
nfreq = fft_length/2 + 1;
Pxx_segs = zeros(nfreq, n_segs);
seg_raw  = zeros(fft_length, n_segs);   % raw, undetrended
seg_det  = zeros(fft_length, n_segs);   % individually detrended
seg_win  = zeros(fft_length, n_segs);   % windowed after individual detrend

for i = 1:n_segs
    idx = seg_starts(i):seg_starts(i) + fft_length - 1;
    xi_raw = x_raw(idx);
    xi_det = detrend(xi_raw);   % per-segment detrend - the whole point of this diagnostic
    xiw = xi_det .* win;
    seg_raw(:,i) = xi_raw;
    seg_det(:,i) = xi_det;
    seg_win(:,i) = xiw;

    [Pseg, f_manual] = periodogram(xiw, [], fft_length, Fs_epsi, 'psd');
    Pxx_segs(:,i) = Pseg;
end
Pxx_manual = mean(Pxx_segs, 2);

% sanity check: same math via MATLAB's own periodogram/pwelch, called
% per-segment the same way welch_psd_detrend_per_segment does, since
% pwelch itself has no per-segment-detrend option to check against directly.
Pxx_check = zeros(nfreq, n_segs);
for i = 1:n_segs
    Pxx_check(:,i) = periodogram(seg_win(:,i), [], fft_length, Fs_epsi, 'psd');
end
fprintf('max |manual - periodogram-per-segment| = %.3e (should be ~0)\n', ...
    max(abs(Pxx_manual - mean(Pxx_check,2))));

%% figure
n_rows = 6;
gap = [0.05 0.06]; marg_h = [0.05 0.05]; marg_w = [0.07 0.03];
fig = aguFigure(16, (17/5)*n_rows, 10);
cmap = lines(max(n_segs,1));   % segment i's color (cmap(i,:)) is reused in every later panel that shows that segment

% 0a. between-scan overlap, epsi domain: this scan (black) and its
% neighbors (colored), each drawn over its own window, offset by a
% steady per-scan-index climb so "which scan is which" stays unambiguous.
subtightplot(n_rows,2,[1 2],gap,marg_h,marg_w);
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
% stacked by scan index. Overlap here is scan_overlap by construction -
% shown, not measured, unlike the old mod_fish_lib pipeline where it was
% an incidental side effect of a fixed, independent dz.
subtightplot(n_rows,2,[3 4],gap,marg_h,marg_w);
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
title(sprintf('scan\\_step = (1-scan\\_overlap)\\times N\\_epsi -> %.0f%% overlap by construction (median window width = %.2f db)', ...
    100*opts.scan_overlap, median(width_db_nb)))

% 1. full record (black, undetrended) with every Welch segment overlaid
% in its own color (cmap(i,:), reused in the panels below, shown AFTER
% its own individual detrend), nudged just enough alternately below/above
% the black line to stay visible.
subtightplot(n_rows,2,[5 6],gap,marg_h,marg_w);
tiny_off = 0.02*range(x_raw - mean(x_raw));
hold on
plot(t, x_raw-mean(x_raw), 'k-', 'linewidth', 1.3)
for i = 1:n_segs
    idx = seg_starts(i):seg_starts(i)+fft_length-1;
    sign_i = 1 - 2*mod(i,2);   % i=1 (odd) -> below, i=2 (even) -> above, i=3 -> below, ...
    off = sign_i*tiny_off;
    plot(t(idx), seg_det(:,i)+off, 'color', cmap(i,:), 'linewidth',1.4)
end
xlabel('time [s]'); ylabel(strrep(channel,'_','\_'))
title(sprintf('scan %d: raw record (black, mean-removed for display), %d segment(s) shown after their own individual detrend, step %d samples (%.0f%% overlap)', ...
    iScan, n_segs, step, 100*noverlap/fft_length))

% 2. the window shape itself
subtightplot(n_rows,2,7,gap,marg_h,marg_w);
plot((0:fft_length-1)/Fs_epsi, win, 'k-','linewidth',1.5)
xlabel('time within segment [s]'); ylabel('window amplitude')
title(sprintf('%s window, length %d', opts.window_type, fft_length))
ylim([0 1.05*max(win)])

% 3. segment 1: raw -> per-segment detrend -> windowed.
subtightplot(n_rows,2,8,gap,marg_h,marg_w);
hold on
plot((0:fft_length-1)/Fs_epsi, seg_raw(:,1)-mean(seg_raw(:,1)),'-','color',[0.6 0.6 0.6],'linewidth',1.2)
plot((0:fft_length-1)/Fs_epsi, seg_det(:,1),'-','color',cmap(1,:),'linewidth',1.5)
plot((0:fft_length-1)/Fs_epsi, seg_win(:,1),'k-','linewidth',1)
legend('raw (mean-removed)','individually detrended','windowed','location','best')
xlabel('time within segment [s]'); ylabel('amplitude')
title('segment 1: raw -> per-segment detrend -> window')

% 4. every segment's own periodogram (in its own segment color) + their
% average (black). Positioned left, 2 row-heights x 1 column so it reads
% as roughly square.
subtightplot(n_rows,2,[9 11],gap,marg_h,marg_w);
semilogy(f_manual, Pxx_segs(:,1), 'color', cmap(1,:)); hold on
for i = 2:n_segs
    semilogy(f_manual, Pxx_segs(:,i), 'color', cmap(i,:))
end
semilogy(f_manual, Pxx_manual, 'k-','linewidth',2)
xlabel('frequency [Hz]'); ylabel('PSD')
title(sprintf('%d individual periodogram(s) (per-segment detrend) -> Welch average', n_segs))
xlim([0 Fs_epsi/2])

% 5. hand-rolled Welch vs. the same math via MATLAB's periodogram, sanity
% check. Same 2x1 footprint as panel 4.
subtightplot(n_rows,2,[10 12],gap,marg_h,marg_w);
semilogy(f_manual, Pxx_manual,'b-','linewidth',2); hold on
semilogy(f_manual, mean(Pxx_check,2),'r--','linewidth',1.5)
legend('manual (by hand)','MATLAB periodogram, per segment','location','best')
xlabel('frequency [Hz]'); ylabel('PSD [units^2/Hz]')
title('sanity check: hand-rolled per-segment-detrend Welch matches periodogram exactly')
xlim([0 Fs_epsi/2])

end
