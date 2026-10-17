function fig = MODvis_vnav_attitude(source, time_range)
% MODvis_vnav_attitude        Part of MOD_fish_processing
%
% fig = MODvis_vnav_attitude(source)
% fig = MODvis_vnav_attitude(source, time_range)
%
% DESCRIPTION
%   Plots which way the fish was pointing, from the L1 VectorNav data
%   (and ctd.P for pressure): pressure, tilt, spin (in turns, next to the
%   gyro twist count, as a cross-check), pitch and roll, and yaw, on one linked time axis. See
%   docs/concepts/vehicle_attitude.md for what each angle means.
%
%   L1 files made before mod_L1_add_vnav_attitude.m existed have no
%   tilt/spin; those are computed here from their vnav (nothing is
%   written).
%
% INPUTS
%   source     - an L1 folder, or a survey folder (its
%                processed/realtime/L1 is used)
%   time_range - (optional) [start end] as datetime or datenum; default:
%                everything
%
% OUTPUTS
%   fig - the figure handle
%
% CALLED BY
%   (by hand)
%
% CALLS
%   mod_L1_add_vnav_attitude.m (for older L1 files); aguFigure,
%   subtightplot assumed already on the MATLAB path
%
% NOTES
%   Spin is unwrapped across files here, so it runs on continuously; in
%   each L1 file it starts within +-180 deg. The twist count is joined
%   across files the way MODprocess_L1_accumulate_twist_timeseries.m
%   does; both are drawn from 0 at the start of the time range.
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

if nargin < 2
    time_range = [];
end
if isdatetime(time_range)
    time_range = datenum(time_range); %#ok<DATNM>
end
L1_dir = source;
if isfolder(fullfile(source, 'processed', 'realtime', 'L1'))
    L1_dir = fullfile(source, 'processed', 'realtime', 'L1');
end
files = dir(fullfile(L1_dir, '*.mat'));
if isempty(files)
    error('MODvis_vnav_attitude:noFiles', 'No L1 files in %s.', L1_dir);
end
addpath(fullfile(fileparts(fileparts(mfilename('fullpath'))), 'processing', 'L1'));

names = {'dnum', 'tilt', 'spin', 'pitch', 'roll', 'yaw'};
V = cell2struct(repmat({[]}, numel(names), 1), names);
C.dnum = []; C.P = [];
T.dnum = []; T.count = [];
last_count = 0;
for iF = 1:numel(files)
    S = load(fullfile(files(iF).folder, files(iF).name), 'vnav', 'ctd', 'twist');
    if ~isfield(S, 'vnav') || isempty(S.vnav) || ~isstruct(S.vnav) || isempty(S.vnav.dnum)
        continue
    end
    v = S.vnav;
    if ~isempty(time_range) && (max(v.dnum) < time_range(1) || min(v.dnum) > time_range(2))
        continue
    end
    if ~isfield(v, 'tilt')
        v = mod_L1_add_vnav_attitude(v);
    end
    for k = 1:numel(names)
        V.(names{k}) = [V.(names{k}); v.(names{k})(:)];
    end
    if isfield(S, 'ctd') && ~isempty(S.ctd) && isfield(S.ctd, 'P')
        C.dnum = [C.dnum; S.ctd.dnum(:)];
        C.P = [C.P; S.ctd.P(:)];
    end
    if isfield(S, 'twist') && ~isempty(S.twist)
        n = S.twist.count_gyro(:);
        T.dnum = [T.dnum; S.twist.dnum(:)];
        T.count = [T.count; n + last_count];
        last_n = n(find(isfinite(n), 1, 'last'));
        if ~isempty(last_n)
            last_count = last_count + last_n;
        end
    end
end
if isempty(V.dnum)
    error('MODvis_vnav_attitude:noVnav', 'No vnav data in %s in that time range.', L1_dir);
end

% one continuous spin: unwrap across the file joins
ok = isfinite(V.spin);
V.spin(ok) = rad2deg(unwrap(deg2rad(V.spin(ok))));

% keep the time range, so spin and twist count from its start
if isempty(time_range)
    time_range = [min(V.dnum) max(V.dnum)];
end
in = V.dnum >= time_range(1) & V.dnum <= time_range(2);
for k = 1:numel(names)
    V.(names{k}) = V.(names{k})(in);
end
in = C.dnum >= time_range(1) & C.dnum <= time_range(2);
C.dnum = C.dnum(in); C.P = C.P(in);
in = T.dnum >= time_range(1) & T.dnum <= time_range(2);
T.dnum = T.dnum(in); T.count = T.count(in);
first = find(isfinite(T.count), 1);
if ~isempty(first)
    T.count = T.count - T.count(first);
end
ok = isfinite(V.spin);

t = datetime(V.dnum, 'ConvertFrom', 'datenum');
xl = datetime(time_range, 'ConvertFrom', 'datenum');

fig = aguFigure(7.5, 9, 9);
gap = [0.025 0.02]; mh = [0.06 0.03]; mw = [0.1 0.17];
ax = gobjects(5, 1);

ax(1) = subtightplot(5, 1, 1, gap, mh, mw);
plot(datetime(C.dnum, 'ConvertFrom', 'datenum'), C.P, 'k');
set(gca, 'YDir', 'reverse'); ylabel('P [dbar]');

ax(2) = subtightplot(5, 1, 2, gap, mh, mw);
plot(t, V.tilt, 'k');
ylim([0 180]); yticks(0:45:180); ylabel('tilt [deg]');
text(1.01, 0.9, '180 = long axis down', 'Units', 'normalized', 'FontSize', 8)
text(1.01, 0.5, '90 = horizontal', 'Units', 'normalized', 'FontSize', 8)
text(1.01, 0.1, '0 = long axis up', 'Units', 'normalized', 'FontSize', 8)

ax(3) = subtightplot(5, 1, 3, gap, mh, mw);
spin0 = V.spin(find(ok, 1));
if isempty(spin0)
    spin0 = NaN; % no spin in the range (no magnetometer, or pointing down)
end
plot(t, (V.spin - spin0) / 360, 'k', 'DisplayName', 'spin');
hold on
if ~isempty(T.dnum)
    plot(datetime(T.dnum, 'ConvertFrom', 'datenum'), T.count, '--', 'Color', [0 0.4470 0.7410], ...
        'DisplayName', 'gyro twist');
end
ylabel('[turns from start]'); legend('Location', 'eastoutside');

ax(4) = subtightplot(5, 1, 4, gap, mh, mw);
[tr, roll] = break_at_wraps(t, V.roll);
plot(t, V.pitch, tr, roll);
ylim([-180 180]); yticks(-180:90:180); ylabel('[deg]');
legend({'pitch', 'roll'}, 'Location', 'eastoutside');

ax(5) = subtightplot(5, 1, 5, gap, mh, mw);
[ty, yaw] = break_at_wraps(t, V.yaw);
plot(ty, yaw, 'k');
ylim([-180 180]); yticks(-180:90:180); ylabel('yaw [deg]');
text(1.01, 0.5, {'clockwise from', 'magnetic N'}, 'Units', 'normalized', 'FontSize', 8)

linkaxes(ax, 'x');
xlim(ax(1), xl);
set(ax(1:4), 'XTickLabel', []);
w = min(arrayfun(@(a) a.Position(3), ax));
for k = 1:numel(ax)
    ax(k).Position(3) = w; % legends shrink some axes; keep them lined up
end
[~, folder] = fileparts(strip(source, 'right', filesep));
title(ax(1), sprintf('VectorNav attitude - %s', folder), 'Interpreter', 'none');

end %end function

%% NaN between samples that jump across +-180, so a wrap isn't drawn as a
% vertical line
function [t_out, x_out] = break_at_wraps(t, x)
jump = [false; abs(diff(x)) > 180];
idx = (1:numel(x))' + cumsum(jump); % each sample shifts by the gaps before it
t_out = NaT(numel(x) + sum(jump), 1);
x_out = nan(numel(x) + sum(jump), 1);
t_out(idx) = t;
x_out(idx) = x;
end
