function ax = MODvis_twist_timeseries(TwistTimeseries, ax)
% MODvis_twist_timeseries        Part of MOD_fish_processing
%
% ax = MODvis_twist_timeseries(TwistTimeseries, ax)
%
% DESCRIPTION
%   Plots cable twist count (gyro method) vs. time, highlighting upcast
%   samples. For the cruise twist count it also marks each spool change
%   (dashed, with the spool put on) and each survey start (dotted, with
%   its name).
%
% INPUTS
%   TwistTimeseries - struct from MODprocess_cruise_twist.m (the cruise
%                     count, <processed_root>/twist/twist_time_series.mat)
%                     or MODprocess_L1_accumulate_twist_timeseries.m (one
%                     survey, from 0 at its start): dnum, count_gyro,
%                     pressure; optionally spool_swaps, surveys and
%                     survey_start_dnum
%   ax               - (optional) axes to plot into (also uiaxes, e.g.
%                       the monitor's). Creates a new figure and axes if
%                       omitted.
%
% OUTPUTS
%   ax - the axes plotted into
%
% CALLED BY
%   MODvis_realtime_monitor.m; by hand (operator, during a cruise)
%
% CALLS
%   (none)
%
% NOTES
%   Upcast samples (diff(pressure) < 0) are highlighted since that's when
%   the fin is normally adjusted. "Neutral is Negative" - setting the fin
%   to neutral makes the count go down. The line's legend entry says
%   which way the fins turn the count (two lines, legend AutoUpdate off
%   so the marks drawn after it stay out).
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

if nargin < 2 || isempty(ax)
    figure;
    ax = axes;
end

gyro  = TwistTimeseries.count_gyro(:);
dtime = datetime(TwistTimeseries.dnum(:), 'ConvertFrom', 'datenum');

% the line is broken at gaps (between surveys, no vnav), so a spool reset
% across a gap isn't drawn as a slope
line_t = dtime;
line_gyro = gyro;
gap = find(diff(TwistTimeseries.dnum(:)) * 86400 > 10 * median(diff(TwistTimeseries.dnum(:)) * 86400, 'omitnan'));
for k = flipud(gap(:))'
    line_t = [line_t(1:k); NaT; line_t(k+1:end)];
    line_gyro = [line_gyro(1:k); NaN; line_gyro(k+1:end)];
end
h_line = plot(ax, line_t, line_gyro, '-', 'Color', [0 0.4470 0.7410], 'LineWidth', 1.5);
fins = sprintf('\\uparrow Fins to starboard - twists increase\n\\downarrow Fins to port - twists decrease');
h_leg = h_line;
leg_text = {fins};
hold(ax, 'on');

has_pressure = isfield(TwistTimeseries, 'pressure') && ~isempty(TwistTimeseries.pressure) ...
    && any(~isnan(TwistTimeseries.pressure));
if has_pressure
    pressure = TwistTimeseries.pressure(:);
    is_upcast = [false; diff(pressure) < 0];
    % MarkerSize kept small - at cruise-length sample counts (~1e6 points),
    % a normal-size marker fully occludes the underlying line.
    if any(is_upcast)
        h_leg(2) = plot(ax, dtime(is_upcast), gyro(is_upcast), '.', 'Color', [0.8500 0.3250 0.0980], 'MarkerSize', 2);
        leg_text{2} = 'upcast';
    end
end

currentcount = gyro(find(isfinite(gyro), 1, 'last'));
title(ax, {sprintf('Twist Count vs. Time (Final count: %.2f)', currentcount), ...
    'Neutral is Negative - set fin to neutral to reduce count'}, 'FontWeight', 'normal')
xlabel(ax, 'Time [UTC]')
ylabel(ax, 'Twist counts')
% legend text a size up from the axes' (its default is 0.9 of it); line
% sample a quarter of the default 30-point length (ItemTokenSize is
% hidden: set on the legend, not as a legend() option)
lgd = legend(ax, h_leg, leg_text, 'Location', 'best', 'AutoUpdate', 'off', 'FontSize', ax.FontSize + 1);
lgd.ItemTokenSize(1) = lgd.ItemTokenSize(1) / 4;

% spool changes (count restarts from 0) and survey starts
grey = [0.5 0.5 0.5];
if isfield(TwistTimeseries, 'spool_swaps') && ~isempty(TwistTimeseries.spool_swaps)
    for sw = TwistTimeseries.spool_swaps(:)'
        xline(ax, datetime(sw.dnum, 'ConvertFrom', 'datenum'), '--', sw.spool_id, ...
            'Color', grey, 'LabelVerticalAlignment', 'bottom', 'Interpreter', 'none', 'HandleVisibility', 'off');
    end
elseif isfield(TwistTimeseries, 'spool_swap_dnum') && ~isempty(TwistTimeseries.spool_swap_dnum)
    xline(ax, datetime(TwistTimeseries.spool_swap_dnum, 'ConvertFrom', 'datenum'), '--', ...
        'Color', grey, 'HandleVisibility', 'off');
end
if isfield(TwistTimeseries, 'survey_start_dnum') && isfield(TwistTimeseries, 'surveys')
    for k = 1:numel(TwistTimeseries.survey_start_dnum)
        xline(ax, datetime(TwistTimeseries.survey_start_dnum(k), 'ConvertFrom', 'datenum'), ':', ...
            TwistTimeseries.surveys{k}, 'Color', grey, 'Interpreter', 'none', 'HandleVisibility', 'off');
    end
end
hold(ax, 'off');

end

