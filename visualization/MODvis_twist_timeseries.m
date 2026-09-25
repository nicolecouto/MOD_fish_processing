function ax = MODvis_twist_timeseries(TwistTimeseries, ax)
% MODvis_twist_timeseries        Part of MOD_fish_processing
%
% ax = MODvis_twist_timeseries(TwistTimeseries, ax)
%
% DESCRIPTION
%   Plots cable twist count (gyro method) vs. time for a deployment,
%   highlighting upcast samples and marking spool swap events.
%
% INPUTS
%   TwistTimeseries - struct from MODprocess_L1_accumulate_twist_timeseries.m:
%                      dnum, count_gyro, pressure, spool_swap_dnum (optional)
%   ax               - (optional) axes to plot into. Creates a new figure
%                       and axes if omitted.
%
% OUTPUTS
%   ax - the axes plotted into
%
% CALLED BY
%   (operator, during a cruise)
%
% CALLS
%   (none)
%
% NOTES
%   Upcast samples (diff(pressure) < 0) are highlighted since that's when
%   the fin is normally adjusted. "Neutral is Negative" - setting the fin
%   to neutral makes the count go down.
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

if nargin < 2 || isempty(ax)
    figure;
    ax = axes;
end

gyro  = TwistTimeseries.count_gyro;
dtime = datetime(TwistTimeseries.dnum, 'ConvertFrom', 'datenum');

plot(ax, dtime, gyro, '-', 'Color', [0 0.4470 0.7410], 'LineWidth', 1.5);
hold(ax, 'on');

has_pressure = isfield(TwistTimeseries, 'pressure') && ~isempty(TwistTimeseries.pressure) ...
    && any(~isnan(TwistTimeseries.pressure));
if has_pressure
    pressure = TwistTimeseries.pressure;
    is_upcast = [false; diff(pressure) < 0];
    % MarkerSize kept small - at cruise-length sample counts (~1e6 points),
    % a normal-size marker fully occludes the underlying line.
    plot(ax, dtime(is_upcast), gyro(is_upcast), '.', 'Color', [0.8500 0.3250 0.0980], 'MarkerSize', 2);
    legend(ax, {'twist count', 'upcast'}, 'Location', 'best');
end

currentcount = gyro(end);
title(ax, sprintf('Twist Count vs. Time (Final count: %.2f)', currentcount))
xlabel(ax, 'Time')
ylabel(ax, 'Twist Count [full rotations]')
hold(ax, 'off');

% Shrink the axes to leave room at the bottom for the annotation, so it
% doesn't collide with the x-axis label/tick labels.
ax.Position(2) = ax.Position(2) + 0.08;
ax.Position(4) = ax.Position(4) - 0.08;
annotation(ax.Parent, 'textbox', [0.15, 0.01, 0.7, 0.05], ...
    'String', 'Neutral is Negative — set fin to neutral to reduce count', ...
    'EdgeColor', 'none', 'HorizontalAlignment', 'center');

if isfield(TwistTimeseries, 'spool_swap_dnum') && ~isempty(TwistTimeseries.spool_swap_dnum)
    swapTimes = datetime(TwistTimeseries.spool_swap_dnum, 'ConvertFrom', 'datenum');
    for k = 1:numel(swapTimes)
        xline(ax, swapTimes(k), '--', 'Color', [0.5 0.5 0.5]);
    end
end

end
