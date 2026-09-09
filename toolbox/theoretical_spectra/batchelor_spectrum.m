function Psg = batchelor_spectrum(epsilon, chi, nu, ktemp, k)
% batchelor_spectrum        Part of MOD_fish_processing
%
% Psg = batchelor_spectrum(epsilon, chi, nu, ktemp, k)
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
% PROVENANCE - why this is a distinct function from MOD_fish_lib's batchelor.m
%   MOD_fish_lib actually has *two* Batchelor-spectrum implementations, and
%   this function ports the one the legacy chi_mle fit actually used, not
%   the more commonly-referenced one:
%     1. EPSILOMETER/EPSILON/process/batchelor.m - [k,Psg]=batchelor(epsilon,
%        chi,nu,D,q) - self-generates its own k grid from eta (k is only
%        ever an OUTPUT, never an input); used elsewhere purely for
%        plotting a model curve over a wide range, e.g. SpectraExplorerApp.m.
%     2. A local `batchelor` subfunction defined inside
%        EPSILOMETER/EPSILON/mod_efe_scan_chi.m (which shadows #1 for every
%        call inside that file) - Psg=batchelor(epsilon,chi,nu,D,k) - takes
%        k as an INPUT and evaluates the spectrum only at those points.
%        This is the one mle_any_model.m's grid search actually calls (via
%        a closure, tmpModel = @(chi) batchelor(...,k) with k =
%        SpecObs.k, the observed scan's own wavenumber array), and it's
%        why no interpolation between model and observed spectra was ever
%        needed in the legacy MLE fit - both were computed on the identical
%        k array by construction, not resampled onto a common grid
%        afterward. logLikelihood.m simply does elementwise/matrix
%        arithmetic between Pk (observed) and Pt (model), which only works
%        because they already share a wavenumber axis.
%   This function is a direct, unchanged-math port of variant #2 (Ren-Chieh
%   Lien 1992, after Oakey 1981) - not variant #1. See the 2026-09-08
%   session log entry in PLAN.md (Section 12) for how this was confirmed
%   by reading both source files side by side.
%
% INPUTS
%   epsilon - turbulent kinetic energy dissipation rate [W/kg], scalar.
%             Computed by modProcess_L2_calc_epsilon.m (epsilon_obs/
%             epsilon_obs_co/epsilon_mle) or supplied by the caller from
%             elsewhere (e.g. an existing epsilon_final field from an
%             old-format MOD_fish_lib Profile####.mat, as used for the
%             chi_obs vs. chi_mle comparison in docs/workflow/L2_calc_chi.md).
%   chi     - scalar (thermal) variance dissipation rate [degC^2/s]. May
%             be a vector (e.g. a grid of candidate chi values to
%             evaluate during an MLE search) - Psg comes out with chi's
%             shape outer-producted against k (see OUTPUTS).
%   nu      - kinematic viscosity [m^2/s] (toolbox/seawater/visc.m)
%   ktemp   - thermal diffusivity [m^2/s] (toolbox/seawater/ktemp.m)
%   k       - wavenumber [cpm], any shape - the observed scan's own
%             wavenumber bins; not resampled or interpolated anywhere in
%             this function or by its caller.
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
