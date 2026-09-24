function fig = MODplot_scans_and_segments(fft_length, scan_length, fall_speed, opts)
% MODplot_scans_and_segments        Part of MOD_fish_processing
%
% fig = MODplot_scans_and_segments(fft_length, scan_length, fall_speed, ...)
%
% DESCRIPTION
%   Purely theoretical/illustrative companion to MODplot_scan_context.m:
%   takes no real data, just the windowing parameters themselves, and
%   draws the Gantt-chart-style bar layout (like MODplot_scan_context.m's
%   between-scan panel, generalized to the time domain) that shows how
%   scans tile a record, how each scan subdivides into Welch segments,
%   and what physical footprint that produces at a given fall speed. Use
%   this to explore "what would fft_length/scan_length look like" without
%   loading any L1 file - see MODplot_scan_context.m for the real-data
%   version of the same ideas.
%
%   Three stacked panels:
%     1. Several scans (opts.n_scans of them), tiled at opts.scan_overlap,
%        each drawn as one Gantt bar. Each scan gets its own hue.
%     2. The same scans, each subdivided into its own Welch segments (at
%        the hardcoded 50%% within-scan overlap, matching
%        mod_scan_get_spectra.m - see NOTES). Every segment is drawn in a
%        shade of its parent scan's hue, so which segments belong to
%        which scan is visually obvious even where different scans'
%        segments interleave in time.
%     3. The same scans as panel 1, x-axis converted to meters via
%        fall_speed. The center scan is highlighted and its physical
%        footprint is printed, alongside the minimum wavenumber the
%        chosen fft_length/fall_speed combination can resolve.
%
% INPUTS (required)
%   fft_length  - Welch segment length [samples]
%   scan_length - scan length [samples] (in real use this is derived from
%                 fft_length/fft_segments_per_scan - see
%                 processing/scans/mod_scan_length_from_segments.m - but is taken
%                 directly here so this function can explore combinations
%                 that aren't necessarily an exact fft_segments_per_scan
%                 tiling; segment/scan counts are computed by the same
%                 floor-based tiling used everywhere else, so a
%                 non-exact scan_length just quietly drops its last
%                 partial segment/scan, same as real code would)
%   fall_speed  - platform fall speed [m/s], for the meters conversion in
%                 panel 3 and the kmin annotation
%
% OPTIONS (name-value)
%   Fs_epsi      - sample rate [Hz], for the sample<->time axis conversion
%                  and the meters/kmin conversion. Default: 320 (the
%                  registry default - MODsetup_metadata_field_registry.m)
%   n_scans      - how many scans to draw (odd, so there's a true center
%                  scan to highlight in panel 3). Default: 5
%   scan_overlap - fraction, 0-1; between-scan overlap used only to lay
%                  out the illustrative scans in panels 1/3 (mirrors
%                  mod_L2_tile_scans.m's scan_step = (1-scan_overlap)*
%                  scan_length). Default: 0.5
%
% OUTPUTS
%   fig - the figure handle
%
% EXAMPLE
%   MODplot_scans_and_segments(512, 1024, 0.65);
%   MODplot_scans_and_segments(1024, 2048, 0.65, 'n_scans', 7);
%
% CALLED BY
%   (interactive/diagnostic use only)
%
% CALLS
%   (aguFigure, subtightplot)
%
% NOTES
%   The within-scan segment overlap is hardcoded at 50%% (SEGMENT_OVERLAP
%   below), matching mod_scan_get_spectra.m's FFT_OVERLAP constant - not
%   an option here either, for the same reason (see
%   docs/concepts/spectral_windowing.md). opts.scan_overlap is a
%   different, independent knob (between-scan, not within-scan) - see
%   that same doc page for the distinction.
%
%   kmin printed in panel 3 is the wavenumber-domain frequency resolution
%   df = Fs_epsi/fft_length converted via Taylor's frozen-turbulence
%   hypothesis (k = f/fall_speed) - i.e. the smallest non-zero wavenumber
%   any spectrum computed at this fft_length/fall_speed can represent.
%   This is a property of fft_length (segment length), not scan_length -
%   see docs/concepts/spectral_windowing.md's "fft_segments_per_scan does
%   not affect resolution" point. The highlighted scan's physical
%   footprint, by contrast, is a property of scan_length.
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

arguments
    fft_length (1,1) double {mustBePositive}
    scan_length (1,1) double {mustBePositive}
    fall_speed (1,1) double {mustBePositive}
    opts.Fs_epsi (1,1) double {mustBePositive} = 320
    opts.n_scans (1,1) double {mustBePositive, mustBeInteger} = 5
    opts.scan_overlap (1,1) double {mustBeGreaterThanOrEqual(opts.scan_overlap,0), mustBeLessThan(opts.scan_overlap,1)} = 0.5
end

Fs_epsi = opts.Fs_epsi;
SEGMENT_OVERLAP = 0.5; % hardcoded - matches mod_scan_get_spectra.m's FFT_OVERLAP, see NOTES

%% tile scans across the illustrative record (mirrors mod_L2_tile_scans.m)
scan_noverlap = round(opts.scan_overlap * scan_length);
scan_step = scan_length - scan_noverlap;
n_scans = opts.n_scans;
scan_starts = (0:n_scans-1) * scan_step + 1;
scan_ends = scan_starts + scan_length - 1;
i_center = ceil(n_scans/2);

%% tile segments within one scan (mirrors mod_scan_get_spectra.m's
% welch_psd_detrend_per_segment local function)
seg_noverlap = round(SEGMENT_OVERLAP * fft_length);
seg_step = fft_length - seg_noverlap;
n_segs = floor((scan_length - seg_noverlap) / seg_step);
if n_segs < 1
    error('MODplot_scans_and_segments:scanTooShort', ...
        'scan_length=%d is shorter than fft_length=%d - no segments fit.', scan_length, fft_length);
end
seg_local_starts = (0:n_segs-1) * seg_step; % 0-indexed offset from the start of the scan

%% colors: one hue per scan, shades of that hue for its segments.
% Base palette is colorbrewer('Set1')'s first 5 rows (EPSILOMETER/
% EPSILON/generalplotting/colorbrewer.m) - a qualitative palette whose
% colors are already maximally distinct from each other, unlike an
% evenly-spaced HSV wheel where neighboring scan indices land on
% neighboring (similar-looking) hues by construction. The 5-color block
% is randomly shuffled (and re-shuffled per block if n_scans>5) so which
% scan gets which color isn't predictable either.
SET1_5 = [228 26 28; 55 126 184; 77 175 74; 152 78 163; 255 127 0] / 255;
n_base = size(SET1_5, 1);
scan_colors = zeros(n_scans, 3);
for block_start = 1:n_base:n_scans
    block_len = min(n_base, n_scans - block_start + 1);
    shuffled = SET1_5(randperm(n_base), :);
    scan_colors(block_start:block_start+block_len-1, :) = shuffled(1:block_len, :);
end
scan_hues = rgb2hsv(scan_colors);
scan_hues = scan_hues(:,1);

%% figure
n_rows = 3;
gap = [0.13 0.05]; marg_h = [0.06 0.05]; marg_w = [0.09 0.03];
fig = aguFigure(14, 15, 10);

x_max = scan_ends(end) + 0.02*scan_step;

%% Panel 1: scans
ax1 = subtightplot(n_rows,1,1,gap,marg_h,marg_w);
hold(ax1,'on');
for i = 1:n_scans
    lw = 10;
    if i == i_center
        plot(ax1, [scan_starts(i) scan_ends(i)], [i i], 'k-', 'linewidth', lw+3);
    end
    plot(ax1, [scan_starts(i) scan_ends(i)], [i i], '-', 'color', scan_colors(i,:), 'linewidth', lw);
end
ylim(ax1, [0.3, n_scans+0.7]);
xlim(ax1, [0, x_max]);
ylabel(ax1, 'scan index');
xlabel(ax1, 'sample #');
th1 = title(ax1, sprintf('%d scans, scan\\_length=%d, scan\\_step=%d ((1-scan\\_overlap)\\times scan\\_length, scan\\_overlap=%.0f%%) - center scan (black outline) highlighted in panel 3', ...
    n_scans, scan_length, scan_step, 100*opts.scan_overlap));
set(ax1, 'YTick', 1:n_scans);
apply_sample_ticks(ax1, fft_length, x_max);
add_time_axis(ax1, Fs_epsi);
raise_title(th1);

%% Panel 2: segments within each scan, shaded by parent scan's hue
ax2 = subtightplot(n_rows,1,2,gap,marg_h,marg_w);
hold(ax2,'on');
seg_band = 0.28; % fraction of the inter-scan spacing given to a scan's own segment rows -
                  % deliberately tight (vs. the full inter-scan spacing) so a scan's segments
                  % visibly cluster together, distinct from the neighboring scans' clusters
for i = 1:n_scans
    seg_colors = segment_shades(scan_hues(i), n_segs);
    if n_segs == 1
        seg_y = 0;
    else
        seg_y = linspace(-seg_band/2, seg_band/2, n_segs);
    end
    for j = 1:n_segs
        x0 = scan_starts(i) + seg_local_starts(j);
        x1 = x0 + fft_length - 1;
        y = i + seg_y(j);
        plot(ax2, [x0 x1], [y y], '-', 'color', seg_colors(j,:), 'linewidth', 4);
    end
end
ylim(ax2, [0.3, n_scans+0.7]);
xlim(ax2, [0, x_max]);
ylabel(ax2, 'scan index');
xlabel(ax2, 'sample #');
th2 = title(ax2, sprintf('each scan''s %d segment(s), fft\\_length=%d, 50%% within-scan overlap (hardcoded) - shades = same scan', ...
    n_segs, fft_length));
set(ax2, 'YTick', 1:n_scans);
apply_sample_ticks(ax2, fft_length, x_max);
add_time_axis(ax2, Fs_epsi);
raise_title(th2);

%% Panel 3: scans converted to meters via fall_speed, center scan highlighted
ax3 = subtightplot(n_rows,1,3,gap,marg_h,marg_w);
hold(ax3,'on');
to_m = @(samp) (samp-1)/Fs_epsi*fall_speed;
for i = 1:n_scans
    lw = 10;
    if i == i_center
        plot(ax3, [to_m(scan_starts(i)) to_m(scan_ends(i))], [i i], 'k-', 'linewidth', lw+3);
    end
    plot(ax3, [to_m(scan_starts(i)) to_m(scan_ends(i))], [i i], '-', 'color', scan_colors(i,:), 'linewidth', lw);
end
footprint_m = scan_length/Fs_epsi*fall_speed;
kmin = Fs_epsi/(fft_length*fall_speed);
text(ax3, to_m(scan_starts(i_center)), i_center+0.55, sprintf('scan length = %.2f m', footprint_m), ...
    'FontWeight','bold', 'HorizontalAlignment','left', 'FontSize', 9);
ylim(ax3, [0.3, n_scans+0.7]);
xlim(ax3, [0, to_m(x_max)]);
ylabel(ax3, 'scan index');
xlabel(ax3, 'distance fallen [m] (sample #/Fs\_epsi \times fall\_speed)');
title(ax3, sprintf('fall\\_speed=%.2f m/s -> highlighted scan spans %.2f m; kmin = Fs\\_epsi/(fft\\_length\\times fall\\_speed) = %.3f cpm', ...
    fall_speed, footprint_m, kmin));
set(ax3, 'YTick', 1:n_scans);

end

%% helper: nudge a title clear of the top time-axis's own tick labels/xlabel,
% which occupy the same space above the axes box that the title would
% otherwise default into
function raise_title(th)
th.Units = 'normalized';
th.Position(2) = th.Position(2) + 0.16;
end

%% helper: bottom x-axis ticked at multiples of fft_length
function apply_sample_ticks(ax, fft_length, x_max)
ax.XTick = 0:fft_length:x_max;
end

%% helper: top x-axis in integer seconds, aligned to the bottom (sample #) axis
function ax_top = add_time_axis(ax_bottom, Fs_epsi)
drawnow % settle ax_bottom's Position before copying it
pos = ax_bottom.Position;
ax_top = axes('Position', pos, 'Color', 'none', ...
    'XAxisLocation', 'top', 'YAxisLocation', 'right', ...
    'YTick', [], 'YColor', 'none', 'Box', 'off');
ax_top.XLim = ax_bottom.XLim / Fs_epsi;
t_max = ax_top.XLim(2);
ax_top.XTick = 0:1:floor(t_max);
xlabel(ax_top, 'time [s]');
end

%% helper: nseg shades of one hue (varying saturation/value), for one scan's segments
function rgb = segment_shades(hue, n)
if n == 1
    sat = 0.75; val = 0.80;
else
    sat = linspace(0.40, 1.00, n);
    val = linspace(0.95, 0.65, n);
end
rgb = hsv2rgb([repmat(hue,n,1), sat(:), val(:)]);
end
