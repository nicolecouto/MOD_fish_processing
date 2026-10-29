function x = MODutil_altimeter_hab_m(s, in_window)
% MODutil_altimeter_hab_m        Part of MOD_fish_processing
%
% x = MODutil_altimeter_hab_m(s, in_window)
%
% DESCRIPTION
%   The altimeter's height above bottom samples in a time window, from
%   one L1 file: the ISA500 (isap) if it has any there, else the MOD
%   altimeter (alt). Samples pegged at the altimeter's maximum range are
%   left out (no bottom in range: dst sits at one flat value, e.g. 120 m
%   for the ISA500 - MODunits_L1.m); a real range varies from sample to
%   sample, so a maximum seen more than once is a peg. NaN heights are
%   left out too.
%
% INPUTS
%   s         - an L1 file's variables (or some of them: isap, alt), as
%               load() gives them
%   in_window - function handle, logical of a datenum vector: true for
%               the samples to keep (e.g. @(t) t >= t0 & t <= t1)
%
% OUTPUTS
%   x - n x 2, [dnum, hab] with hab in m; zeros(0, 2) if neither
%       altimeter has a sample in the window
%
% CALLED BY
%   MODprocess_grid.m, MODvis_realtime_monitor.m
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

x = hab_in_window(s, 'isap', in_window);
if isempty(x)
    x = hab_in_window(s, 'alt', in_window);
end
end

function x = hab_in_window(s, rec, in_window)
x = zeros(0, 2);
if ~isfield(s, rec) || ~isstruct(s.(rec)) || ~all(isfield(s.(rec), {'dnum', 'hab'})) ...
        || numel(s.(rec).hab) ~= numel(s.(rec).dnum)
    return
end
t = s.(rec).dnum(:);
hab = s.(rec).hab(:);
keep = in_window(t) & isfinite(hab);
if isfield(s.(rec), 'dst') && numel(s.(rec).dst) == numel(t)
    dst = s.(rec).dst(:);
    peg = max(dst);
    if nnz(dst == peg) > 1
        keep = keep & dst ~= peg;
    end
end
x = [t(keep), hab(keep)];
end
