function Psg = mod_scan_batchelor_spectrum(epsilon, chi, nu, ktemp, k)
% mod_scan_batchelor_spectrum        Part of MOD_fish_processing
%
% Psg = mod_scan_batchelor_spectrum(epsilon, chi, nu, ktemp, k)
%
% DESCRIPTION
%   Theoretical one-dimensional Batchelor (1959) temperature-gradient
%   wavenumber spectrum, evaluated at a caller-supplied wavenumber vector
%   k (rather than generating its own wavenumber grid from eta the way
%   MOD_fish_lib's EPSILOMETER/EPSILON/process/batchelor.m does) - this is
%   the shape mod_scan_calc_chi_mle.m fits against an observed
%   spectrum, so it needs to be evaluable at exactly the observed scan's
%   wavenumber bins.
%
%   Physically: turbulence at rate epsilon stirs the water past the FP07
%   down to the Kolmogorov scale, and molecular diffusion (ktemp) smooths
%   temperature structure below the Batchelor wavenumber
%   kb = (epsilon/nu/ktemp^2)^(1/4) - kb sets the spectrum's rolloff shape
%   and depends only on epsilon/nu/ktemp, not on chi. chi enters as a pure
%   multiplicative amplitude: Psg(k) = chi * shape(k; epsilon, nu, ktemp).
%   This linearity is what makes the MLE fit in
%   mod_scan_calc_chi_mle.m a 1-D search over a single amplitude
%   parameter rather than a nonlinear multi-parameter fit.
%
%   Ported from the local `batchelor` subfunction inside MOD_fish_lib's
%   mod_efe_scan_chi.m (itself Ren-Chieh Lien 1992, after Oakey 1981) -
%   the "evaluate at given k" variant, not the "generate a full-range k
%   grid" variant in EPSILOMETER/EPSILON/process/batchelor.m (that one is
%   used elsewhere, e.g. SpectraExplorerApp.m, purely for plotting a model
%   curve over a wide wavenumber range - not needed here since the fit
%   only ever evaluates the model at the observed scan's own k).
%
% INPUTS
%   epsilon - turbulent kinetic energy dissipation rate [W/kg], scalar.
%             Not yet computed anywhere in this repo (PLAN.md's
%             modProcess_L2_calc_epsilon.m is not started) - callers must
%             supply it from elsewhere (e.g. a shear-probe Nasmyth fit, or
%             an existing epsilon_final field from an old-format
%             MOD_fish_lib Profile####.mat, as used for the chi_obs vs.
%             chi_mle comparison in docs/workflow/L2_calc_chi.md).
%   chi     - scalar (thermal) variance dissipation rate [degC^2/s]. May
%             be a vector (e.g. a grid of candidate chi values to
%             evaluate during an MLE search) - Psg comes out with chi's
%             shape outer-producted against k (see OUTPUTS).
%   nu      - kinematic viscosity [m^2/s] (toolbox/seawater/sw_visc.m)
%   ktemp   - thermal diffusivity [m^2/s] (mod_scan_thermal_diffusivity.m)
%   k       - wavenumber [cpm], any shape
%
% OUTPUTS
%   Psg - theoretical temperature-gradient power spectrum [degC^2/m /cpm],
%         size numel(k) x numel(chi) if either chi or k is non-scalar
%         (outer product - matches what mod_scan_calc_chi_mle.m's
%         log-likelihood grid search needs: one model curve per candidate
%         chi, all evaluated at the same observed k). Negative values
%         (possible from the erfc numerics at very high k/kb) are clamped
%         to 0, matching the original.
%
% CALLED BY
%   mod_scan_calc_chi_mle.m
%
% CALLS
%   (none)
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

q = 3.7; % strain parameter, Batchelor (1959) / Oakey (1981) standard value

kb = (epsilon / nu / ktemp^2)^(1/4);

k = k(:); % column, so chi (row or scalar) outer-products cleanly below
a = sqrt(2*q) * 2*pi*k / kb;
uppera = erfc(a/sqrt(2)) * sqrt(pi/2);
g = 2*pi*a .* (exp(-a.^2/2) - a.*uppera);

Psg = (g * sqrt(q/2) / kb / ktemp) * chi(:)';
Psg(Psg <= 0) = 0;

if isscalar(chi)
    Psg = reshape(Psg, size(k));
end

end %end function
