function Pxx = panchev_spectrum(epsilon, kvis, k)
% panchev_spectrum        Part of MOD_fish_processing
%
% Pxx = panchev_spectrum(epsilon, kvis, k)
%
% DESCRIPTION
%   Theoretical one-dimensional Panchev universal turbulent shear
%   wavenumber spectrum, evaluated at a caller-supplied wavenumber vector
%   k - the shear-probe analog of batchelor_spectrum.m, evaluated
%   at exactly an observed scan's own wavenumber bins rather than
%   generating its own range.
%
% PROVENANCE
%   Ported from MOD_fish_lib's EPSILOMETER/EPSILON/process/panchev.m
%   (originally in function form by kw 8/5/94, revised mg 1995). That
%   original's k input (its 3rd argument, `kin`) was already optional -
%   unlike batchelor.m, it was never mandatory-self-generating - so this
%   port just makes the caller-supplied-k path the only path: dropped (a)
%   the self-generated wavenumber grid spanning 1/(1000*eta) to 1/(5*eta)
%   used when kin was omitted, and (b) the first output k (redundant once
%   k is always supplied by the caller). This function's only caller
%   always supplies k explicitly (an observed scan's own wavenumber bins,
%   for direct overlay against Ps_shear_k), matching
%   batchelor_spectrum.m's same "evaluate at given k" pattern - no
%   numeric change to the spectrum itself.
%
% INPUTS
%   epsilon - turbulent kinetic energy dissipation rate [W/kg], scalar.
%   kvis    - kinematic viscosity [m^2/s] (toolbox/seawater/sw_visc.m, or
%             Profile.kvis for an already-computed legacy value).
%   k       - wavenumber [cpm], any shape.
%
% OUTPUTS
%   Pxx - theoretical shear power spectrum [s^-2 cpm^-1], same shape as k.
%
% CALLED BY
%   MODvis_spectra.m (wavenumber-domain panel, overlaid on observed
%   Ps_shear_k for visual QC).
%
% CALLS
%   (none)
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

a = 1.6;
delta = 0.1;
eta = (kvis^3 / epsilon)^(1/4); % Kolmogorov length scale [m]
conv = 1 / (eta * 2*pi);
c32 = 3/2; sc32 = sqrt(c32);
c23 = 2/3; ac32 = a^c32;
c43 = 4/3;

k = k(:)';
kn = k / conv;

scale = 2*pi * (epsilon * kvis^5)^0.25;
total = zeros(size(kn));
zeta = delta/2 : delta : 1;
for i = 1:numel(zeta)
    z = zeta(i);
    total = total ...
        + delta .* (1 + z.^2) ...
        .* (a.*z.^c23 + (sc32.*ac32) .* kn.^c23) ...
        .* exp(-c32.*a.*(kn/z).^c43 - (sc32.*ac32.*(kn/z).^2));
end
phi = 0.5 .* kn.^(-5/3) .* total;
Pxx = scale .* (kn/eta).^2 .* phi;

Pxx = reshape(Pxx, size(k));

end %end function
