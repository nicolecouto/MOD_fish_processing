function fig = MODplot_vnav_attitude_explained(opts)
% MODplot_vnav_attitude_explained        Part of MOD_fish_processing
%
% fig = MODplot_vnav_attitude_explained(...)
%
% DESCRIPTION
%   Purely illustrative, no real data: the two ways
%   mod_L1_add_vnav_attitude.m describes which way the fish is pointing,
%   for docs/concepts/vehicle_attitude.md.
%     1. tilt and spin: a fish hanging from the cable, long axis (sensor
%        z) tilted from straight up, spinning about that long axis. Spin
%        is the angle from magnetic north to the sensor x axis once the
%        tilt is taken out (drawn on the horizontal plane below).
%     2. yaw, pitch, roll: VectorNav's angles for a level sensor (z
%        pointing down), each right-handed about its axis.
%
% OPTIONS (all optional name-value)
%   tilt - tilt drawn in panel 1 [deg]. Default: 30.
%   spin - spin drawn in panel 1 [deg]. Default: 60.
%
% OUTPUTS
%   fig - the figure handle.
%
% CALLED BY
%   (by hand, for docs/concepts/images/vnav_attitude_explained.png)
%
% CALLS
%   (none - aguFigure, subtightplot assumed already on the MATLAB path,
%   matching this repo's other MODplot scripts)
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

arguments
    opts.tilt (1,1) double {mustBeInRange(opts.tilt, 5, 80)} = 30
    opts.spin (1,1) double = 60
end

% plotting frame: X = magnetic north, Y = west, Z = up
red = [0.85 0.2 0.15]; green = [0.2 0.6 0.25]; blue = [0.15 0.35 0.8]; grey = [0.5 0.5 0.5];

fig = aguFigure(13, 6.5, 11);
g = [0.02 0.02]; v = [0.04 0.08]; h = [0.01 0.01];

%% Panel 1: tilt and spin
ax1 = subtightplot(1, 2, 1, g, v, h);
hold(ax1, 'on')
up = [0 0 1];
view_az = 30;                                    % screen-right is this far from north
tilt_toward = -[cosd(view_az) sind(view_az) 0];  % leans left, across the view
k = cross(up, tilt_toward);
R = rot(k, opts.tilt) * rot(up, opts.spin);      % sensor -> plotting frame
xb = (R * [1 0 0]')'; zb = (R * [0 0 1]')';

draw_fish(ax1, R)
plot3(ax1, [0 0], [0 0], [-1.9 2.8], '--', 'Color', 'k', 'LineWidth', 1)
text(ax1, 0.1, 0, 2.95, 'up', 'HorizontalAlignment', 'left')
plot3(ax1, [zb(1) zb(1)], [zb(2) zb(2)], [zb(3) 3.2], '-', 'Color', grey, 'LineWidth', 2.5)
text(ax1, zb(1)-0.1, zb(2), 3.3, 'cable', 'Color', grey, 'HorizontalAlignment', 'right')
arrow(ax1, [0 0 0], 2.5*zb, blue, 'z (long axis)')
arrow(ax1, [0 0 0], 1.3*xb, red, 'x')
arc(ax1, [0 0 0], k, up, opts.tilt, 2.0, 'k', 'tilt')
arc(ax1, 1.5*zb, zb, xb, 300, 0.5, blue, 'spin')

% horizontal plane below: north, and x with the tilt taken out
z0 = -1.9;
x_untilted = (rot(up, opts.spin) * [1 0 0]')';
th = linspace(0, 2*pi, 100);
patch(ax1, 1.6*cos(th), 1.6*sin(th), z0*ones(size(th)), [0.93 0.93 0.93], 'EdgeColor', 'none', 'FaceAlpha', 0.7)
arrow(ax1, [0 0 z0], 1.4*[1 0 0], 'k', 'magnetic N')
arrow(ax1, [0 0 z0], 1.3*x_untilted, red, 'x, tilt taken out')
arc(ax1, [0 0 z0], up, [1 0 0], opts.spin, 0.8, red, 'spin')
finish(ax1, {'1. tilt and spin: the fish''s own frame', 'z up the cable, as on an upcast'}, view_az)

%% Panel 2: yaw, pitch, roll for a level sensor (VectorNav: x forward, z down)
ax2 = subtightplot(1, 2, 2, g, v, h);
hold(ax2, 'on')
N = [1 0 0]; E = [0 -1 0]; D = [0 0 -1];
draw_box(ax2)
arrow(ax2, [0 0 0], 1.8*N, red, 'x (forward)')
arrow(ax2, [0 0 0], 1.7*E, green, 'y (starboard)')
arrow(ax2, [0 0 0], 1.5*D, blue, 'z (down)')
arc(ax2, 1.45*N, N, E, 270, 0.25, red, 'roll', 1.45*N + [0 0 0.38])
arc(ax2, 1.2*E, E, D, 270, 0.25, green, 'pitch', 1.2*E + [0 0 -0.45])
arc(ax2, 1.1*D, D, N, 270, 0.25, blue, 'yaw')
finish(ax2, {'2. yaw, pitch, roll: VectorNav''s angles', 'level sensor, z down, yaw 0 (x to magnetic north)'}, -30)

end %end function

%% rotation matrix about unit axis a by angle t [deg] (right-handed)
function M = rot(a, t)
a = a(:) / norm(a);
K = [0 -a(3) a(2); a(3) 0 -a(1); -a(2) a(1) 0];
M = eye(3) + sind(t)*K + (1 - cosd(t))*K^2;
end

function arrow(ax, p0, v, c, label)
quiver3(ax, p0(1), p0(2), p0(3), v(1), v(2), v(3), 0, 'Color', c, 'LineWidth', 1.8, 'MaxHeadSize', 0.4)
p = p0 + 1.12*v;
text(ax, p(1), p(2), p(3), label, 'Color', c, 'HorizontalAlignment', 'center')
end

% arc right-handed about unit axis a, centred at c, from unit vector u
% (perpendicular to a), sweeping t_deg at radius r, arrowhead at the end;
% label at label_at if given, else just outside the arc's middle
function arc(ax, c, a, u, t_deg, r, col, label, label_at)
a = a / norm(a); u = u - dot(u, a)*a; u = u / norm(u); w = cross(a, u);
t = linspace(0, deg2rad(t_deg), 60)';
p = c + r*(u.*cos(t) + w.*sin(t));
plot3(ax, p(:,1), p(:,2), p(:,3), '-', 'Color', col, 'LineWidth', 1.5)
d = -u*sin(t(end)) + w*cos(t(end));              % tangent at the end
nr = u*cos(t(end)) + w*sin(t(end));              % radial at the end
L = 0.15;
head = [p(end,:) + L*d; p(end,:) + 0.45*L*nr; p(end,:) - 0.45*L*nr];
patch(ax, head(:,1), head(:,2), head(:,3), col, 'EdgeColor', col, 'FaceLighting', 'none')
m = c + (r + 0.25)*(u*cos(t(round(end/2))) + w*sin(t(round(end/2))));
if nargin > 8
    m = label_at;
end
text(ax, m(1), m(2), m(3), label, 'Color', col, 'FontWeight', 'bold', 'HorizontalAlignment', 'center')
end

% cylinder along sensor z with a fin on the +x side, rotated by R
function draw_fish(ax, R)
[X, Y, Z] = cylinder(0.25, 40);
Z = 2*Z - 1;
P = R * [X(:) Y(:) Z(:)]';
surf(ax, reshape(P(1,:), size(X)), reshape(P(2,:), size(X)), reshape(P(3,:), size(X)), ...
    'FaceColor', [0.8 0.8 0.85], 'EdgeColor', 'none', 'FaceAlpha', 0.6)
fin = R * [0.25 0.65 0.65 0.25; 0 0 0 0; -0.9 -0.7 -0.2 -0.2];
patch(ax, fin(1,:), fin(2,:), fin(3,:), [0.85 0.2 0.15], 'FaceAlpha', 0.5, 'EdgeColor', 'none')
end

% flat sensor box, x forward
function draw_box(ax)
[x, y, z] = ndgrid([-0.5 0.5], [-0.3 0.3], [-0.1 0.1]);
V = [x(:) y(:) z(:)];
F = [1 2 4 3; 5 6 8 7; 1 2 6 5; 3 4 8 7; 1 3 7 5; 2 4 8 6];
patch(ax, 'Vertices', V, 'Faces', F, 'FaceColor', [0.8 0.8 0.85], 'FaceAlpha', 0.6, 'EdgeColor', [0.4 0.4 0.4])
end

function finish(ax, ttl, az)
axis(ax, 'equal'); axis(ax, 'off')
view(ax, az, 25)
ax.SortMethod = 'childorder'; % drawn in order, so labels on the plane sit on top of it
camlight(ax); lighting(ax, 'gouraud')
title(ax, ttl)
end
