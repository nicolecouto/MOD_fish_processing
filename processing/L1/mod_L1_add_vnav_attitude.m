function vnav = mod_L1_add_vnav_attitude(vnav)
% mod_L1_add_vnav_attitude        Part of MOD_fish_processing
%
% vnav = mod_L1_add_vnav_attitude(vnav)
%
% DESCRIPTION
%   Adds the vehicle's attitude to the VectorNav struct, in two forms
%   (all in degrees, see docs/concepts/vehicle_attitude.md for diagrams):
%     tilt, spin       - the fish's own frame: tilt = angle of the sensor
%                        z axis (the fish's long axis) from straight up;
%                        spin = rotation about that long axis, so its
%                        change over time is the spin that twists the cable.
%     pitch, roll, yaw - VectorNav's own yaw-pitch-roll angles (z-y-x
%                        Euler angles of the sensor frame from North-East-
%                        Down, what the sensor's $VNYPR message reports).
%
%   $VNMAR files (magnetometer, accelerometer, gyro - what the FCTDs send)
%   have no yaw/pitch/roll, so they're computed here from the accelerometer
%   (which way is up) and the magnetometer (which way is magnetic north).
%   $VNYPR files already have yaw/pitch/roll from the sensor; those are kept
%   and tilt/spin come from them.
%
% INPUTS
%   vnav - L0 vnav struct (MODprocess_single_modraw_to_L0.m): .acceleration
%          [m/s^2] and .compass [gauss], n x 3 in the sensor frame, and
%          .yaw/.pitch/.roll [deg], n x 1 (NaN for $VNMAR)
%
% OUTPUTS
%   vnav - same struct with .tilt, .spin added and .pitch, .roll, .yaw
%          filled [deg] (from the accelerometer for pitch/roll, plus the
%          magnetometer for yaw and spin; the sensor's own angles are
%          kept only where there's no acceleration, i.e. $VNYPR):
%            tilt  - 0 = long axis pointing straight up, 90 = horizontal,
%                    180 = straight down
%            spin  - right-handed about the long axis (the sensor gyro
%                    z sign; twist.count_gyro, about the vertical, has
%                    the same sign while tilt < 90); 0 when the sensor
%                    x axis points to magnetic north with the tilt
%                    taken out. Unwrapped
%                    within the file (starts within +-180); NaN when tilt
%                    is within 1 deg of 180, where it isn't defined.
%            pitch - nose (x) up positive, -90 to 90
%            roll  - right-handed about x, -180 to 180; 0 = z pointing
%                    down. A fish hanging with z up the cable reads near
%                    +-180 and jumps between them
%            yaw   - magnetic heading of the x axis, clockwise from
%                    magnetic north seen from above, -180 to 180 (no
%                    declination)
%
% CALLED BY
%   MODprocess_single_L0_to_L1.m; MODvis_vnav_attitude.m (for L1 files
%   made before this step)
%
% CALLS
%   (none)
%
% NOTES
%   The accelerometer reads specific force: +9.81 m/s^2 on an axis
%   pointing up when the sensor is still (VectorNav's convention - checked
%   on the 2026-10-17 FCTD2 ocean test, where the magnetic field then dips
%   62 deg below horizontal at 35.5 N, as it should). So tilt, pitch and
%   roll are right only while the vehicle isn't accelerating much compared
%   to gravity, and spin/yaw are off near the ship's steel (on deck the
%   same test read a 77-79 deg dip).
%
%   PROVENANCE: replaces MOD_fish_lib EPSILOMETER/epsilib/
%   vnav_pitch_roll_heading.m, whose roll assumed the opposite
%   accelerometer sign (so its roll was off by 180 deg and its yaw wrong).
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

n = numel(vnav.dnum);
if ~isfield(vnav, 'yaw'),   vnav.yaw   = nan(n, 1); end
if ~isfield(vnav, 'pitch'), vnav.pitch = nan(n, 1); end
if ~isfield(vnav, 'roll'),  vnav.roll  = nan(n, 1); end

% Down (D) and magnetic north (N) as unit vectors in the sensor frame,
% n x 3: D from the accelerometer, N from the magnetometer too, where they
% exist, else both from the sensor's own yaw/pitch/roll ($VNYPR)
D = nan(n, 3);
N = nan(n, 3);
acc = all(isfinite(vnav.acceleration), 2);
mar = acc & all(isfinite(vnav.compass), 2);
D(acc,:) = -vnav.acceleration(acc,:) ./ vecnorm(vnav.acceleration(acc,:), 2, 2);
E = cross(D(mar,:), vnav.compass(mar,:), 2); % east = down x field
E = E ./ vecnorm(E, 2, 2);
N(mar,:) = cross(E, D(mar,:), 2);

ypr = ~acc & isfinite(vnav.yaw) & isfinite(vnav.pitch) & isfinite(vnav.roll);
[sy, cy] = deal(sind(vnav.yaw(ypr)),   cosd(vnav.yaw(ypr)));
[sp, cp] = deal(sind(vnav.pitch(ypr)), cosd(vnav.pitch(ypr)));
[sr, cr] = deal(sind(vnav.roll(ypr)),  cosd(vnav.roll(ypr)));
% rows 1 and 3 of the sensor-to-NED rotation Rz(yaw)*Ry(pitch)*Rx(roll)
N(ypr,:) = [cy.*cp, cy.*sp.*sr - sy.*cr, cy.*sp.*cr + sy.*sr];
D(ypr,:) = [-sp, cp.*sr, cp.*cr];

% yaw/pitch/roll from the sensor-to-NED rotation, whose rows are N, E, D
E = cross(D, N, 2);
vnav.pitch(acc) = asind(-D(acc,1));
vnav.roll(acc)  = atan2d(D(acc,2), D(acc,3));
vnav.yaw(mar)   = atan2d(E(mar,1), N(mar,1));

% tilt: angle between the sensor z axis and up (-D); NaN where there's no D
U = -D;
vnav.tilt = acosd(min(1, max(-1, U(:,3))));
vnav.tilt(~isfinite(U(:,3))) = NaN;

% spin: tip the sensor frame back upright with the smallest rotation (about
% the horizontal axis k = U x z), then take the angle of the x axis from
% north, counterclockwise seen from above (right-handed about z = up)
k = cross(U, repmat([0 0 1], n, 1), 2);
s = vecnorm(k, 2, 2);  % sin(tilt)
c = U(:,3);            % cos(tilt)
k = k ./ s;
k(s < 1e-9, :) = 0;    % already upright: no rotation
Nu = N.*c + cross(k, N, 2).*s + k.*sum(k.*N, 2).*(1 - c); % Rodrigues
spin = -atan2(Nu(:,2), Nu(:,1));
spin(vnav.tilt > 179) = NaN;
ok = isfinite(spin);
spin(ok) = unwrap(spin(ok));
vnav.spin = rad2deg(spin);

end %end function
