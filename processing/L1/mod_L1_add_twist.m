function data = mod_L1_add_twist(data)
% mod_L1_add_twist        Part of MOD_fish_processing
%
% data = mod_L1_add_twist(data)
%
% DESCRIPTION
%   Computes cumulative twist count from VecNav gyro and compass data and
%   adds a twist struct to the data. Count starts from zero for this file;
%   cross-file accumulation is handled by MODprocess_L1_accumulate_twist_timeseries.
%
% INPUTS
%   data      - L0/L1 data struct with fields: vnav.gyro, vnav.compass,
%               vnav.acceleration, vnav.dnum, vnav.time_s, ctd.P, ctd.dnum
%               If data.vnav is empty, returns data unchanged with a warning.
%               If data.ctd is empty, twist.pressure is all-NaN.
%
% OUTPUTS
%   data      - same struct with data.twist added:
%                 twist.time_s        [s]
%                 twist.dnum          [datenum]
%                 twist.pressure      [dbar], interpolated from CTD
%                 twist.count_gyro    [full rotations], primary
%                 twist.count_compass [radians], cross-check
%
% CALLED BY
%   MODprocess_single_L0_to_L1.m
%
% CALLS
%   (none - SN_RotateToZAxis is a local subfunction below, not a separate
%   file, since nothing else in the repo calls it)
%
% NOTES
%   Gyro z-axis integral is the primary method. Negative = untwisting.
%   "Neutral is Negative" -- set fin to neutral to make the count go down.
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

% Check vnav exists and if so, load it
if ~isfield(data, 'vnav') || isempty(data.vnav) || isempty(data.vnav.time_s)
    warning('mod_L1_add_twist: data.vnav is missing or empty. Returning data unchanged.');
    return
end
vnav = data.vnav;

% Collecting all the vnav data that fits the time stamp requirements
% into the rot variables
diff_not_neg = [0; diff(vnav.dnum)] > 0;
keep = ~isnan(vnav.dnum) & ~isinf(vnav.dnum) & diff_not_neg;
rot.compass      = vnav.compass(keep,:);
rot.gyro         = vnav.gyro(keep,:);
rot.acceleration = vnav.acceleration(keep,:)./9.81;
rot.time_s       = vnav.time_s(keep);
rot.dnum         = vnav.dnum(keep);

% Pressure at each vnav sample, interpolated from CTD - used downstream to
% mark upcast/downcast on the twist plot. NaN if there's no CTD on this
% deployment or the interpolation fails (e.g. non-monotonic ctd.dnum).
if isfield(data, 'ctd') && ~isempty(data.ctd) && isfield(data.ctd, 'dnum') && isfield(data.ctd, 'P')
    try
        rot.pressure = interp1(data.ctd.dnum, data.ctd.P, rot.dnum);
    catch
        rot.pressure = nan(size(rot.dnum));
    end
else
    rot.pressure = nan(size(rot.dnum));
end

% Prepare empty arrays for rotated data
rotated_comp = nan(size(rot.compass));
gyro = nan(size(rot.gyro));

% Find the number of data points
time = rot.dnum;
pts = numel(time);

% For each point, rotate compass and gyro data into the gravity-aligned
% z-axis frame (SN_RotateToZAxis finds the rotation that takes the local
% acceleration vector to [0 0 |a|])
for k = 1:pts
    [~, ~, ~, Rot_mat] = SN_RotateToZAxis(rot.acceleration(k,:));
    rotated_comp(k,:) = Rot_mat*(rot.compass(k,:).');
    gyro(k,:) = Rot_mat*(rot.gyro(k,:).');
end

% Compass method (cross-check): normalize the horizontal compass
% components to a unit vector and take its phase - the instantaneous
% heading angle, unwrapped so multi-turn rotation isn't wrapped to
% [-pi, pi].
comp_mag = repmat(sqrt(sum(rotated_comp(:,1:2).*rotated_comp(:,1:2),2)),[1 3]);
compass_norm = rotated_comp./comp_mag;
compass = compass_norm(:,1)+1i*compass_norm(:,2);
tot_rot_comp = unwrap(angle(compass));

% Gyro method (primary): find time interval, dt
dt = diff(time)*24*3600;
dt = [dt; median(dt, 'omitnan')];

% The total rotation counts from the gyro is its cumulative sum
tot_rot_gyro(:,1) = cumsum(gyro(:,1).*dt);
tot_rot_gyro(:,2) = cumsum(gyro(:,2).*dt);
tot_rot_gyro(:,3) = cumsum(gyro(:,3).*dt);

% Save rotation data. Gyro count is z-axis (vertical/cable-twist axis),
% converted from radians to full rotations (divide by 2*pi) - the unit
% operators actually count fin/spool adjustments against.
data.twist.time_s        = rot.time_s;
data.twist.dnum          = rot.dnum;
data.twist.pressure      = rot.pressure;
data.twist.count_gyro    = tot_rot_gyro(:,3) / (2*pi);
data.twist.count_compass = tot_rot_comp;

end %end function

%% Find the Euler rotation that takes VECTOR to [0 0 |VECTOR|], i.e. the
% rotation that aligns a local acceleration reading with the vertical
% (z) axis. Only used here, so kept as a local subfunction rather than a
% separate file.
function [Phi,Theta,Psi,Rot_mat] = SN_RotateToZAxis(vector)
% [PHI, THETA, PSI] = SN_ROTATETOZAXIS(VECTOR) figures out PHI (x-Euler
% angle), THETA (y-Euler angle), Psi (z-Euler angle) that would take to
% transform the vector to [0 0 lengthof(vector)]
% The transform is to be used with the rotation matrix found at http://en.wikipedia.org/wiki/Rotation_matrix
%
% [..., ROT_MAT] = SN_ROTATETOZAXIS(VECTOR) provides a rotation matrix for
% use as well;
%
% written by San Nguyen 2012 10

% The orthogonal matrix (post-multiplying a column vector) corresponding to a clockwise/left-handed rotation
% http://en.wikipedia.org/wiki/Rotation_matrix
Rot_Mat = @(p,t,s)[ cos(t)*cos(s), -cos(p)*sin(s) + sin(p)*sin(t)*cos(s),  sin(p)*sin(s) + cos(p)*sin(t)*cos(s);
                    cos(t)*sin(s),  cos(p)*cos(s) + sin(p)*sin(t)*sin(s), -sin(p)*cos(s) + cos(p)*sin(t)*sin(s);
                   -sin(t),         sin(p)*cos(t),                         cos(p)*cos(t)];
Psi = 0;

if length(vector) ~= 3
    error('MATLAB:SN_RotateToZAxis:wrongInput','Vector must be length of 3');
end
if isrow(vector)
    vector = vector';
end

yz_vec = vector([2,3]);
r = sqrt(sum(yz_vec.^2));
Phi = acos(sum(yz_vec.*([0; 1;]))/r);

if vector(2) < 0
    Phi = pi-Phi;
end

if isnan(Phi)
    Phi = 0;
end

vector2 = Rot_Mat(Phi,0,0)*vector;

xz_vec = vector2([1,3]);

r = sqrt(sum(xz_vec.^2));
Theta = acos(sum(xz_vec.*([0; 1;]))/r);

if vector2(1) > 0
    Theta = -Theta;
end

if isnan(Theta)
    Theta = 0;
end

Rot_mat = Rot_Mat(Phi,Theta,Psi);

end
