function Psg = nasmyth_spectrum(epsilon, nu, k)
% nasmyth_spectrum        Part of MOD_fish_processing
%
% Psg = nasmyth_spectrum(epsilon, nu, k)
%
% DESCRIPTION
%   Theoretical Nasmyth universal shear wavenumber spectrum (Oakey 1982,
%   Lueck's fit as documented in McMillan et al. 2016), evaluated at a
%   caller-supplied wavenumber vector k - the same "evaluate at given k"
%   shape batchelor_spectrum.m already uses for chi, so this is
%   directly usable as the model spectrum in an epsilon MLE grid search
%   (mod_scan_calc_epsilon_mle.m) the same way batchelor_spectrum.m
%   is for chi_mle.
%
%   Unlike the Batchelor spectrum, epsilon is not a pure multiplicative
%   amplitude here - it sets both the spectrum's overall level AND its
%   rolloff shape (via the Kolmogorov wavenumber ks = (epsilon/nu^3)^(1/4)),
%   so an MLE fit searches over epsilon directly, not a separate amplitude
%   parameter the way chi_mle searches over chi with epsilon/nu/ktemp held
%   fixed.
%
% PROVENANCE
%   Ported from the "form 2" branch of MOD_fish_lib's nasmyth.m (also
%   vendored in two places there - EPSILOMETER/EPSILON/process/nasmyth.m
%   and toolboxes/fitting_tools/nasmyth.m - byte-identical in both). That
%   original supports 4 calling forms via varargin (scaled vs.
%   non-dimensional, with or without a caller-supplied k); form 2
%   (`phi = nasmyth(e, nu, k)`) already took k as a genuine input and
%   evaluated the spectrum only at those points - unlike batchelor.m,
%   there was no separate self-generating-k variant standing in the way,
%   so this is a straightforward extraction of that one form, not a
%   fix for any shadowing/ambiguity the way batchelor_spectrum.m was.
%   This port only implements the scaled, evaluate-at-k form (that
%   repo's forms 1/2 combined, with a caller-supplied k always required)
%   - the non-dimensional and self-generated-k-grid forms (3/4, and 1
%   without a k argument) are not needed by anything in this repo and
%   are not ported. No numeric change to the spectrum formula itself.
%
% INPUTS
%   epsilon - turbulent kinetic energy dissipation rate [W/kg], scalar or
%             vector (e.g. a grid of candidate epsilon values to evaluate
%             during an MLE search) - Psg comes out with epsilon's shape
%             outer-producted against k (see OUTPUTS).
%   nu      - kinematic viscosity [m^2/s] (toolbox/seawater/sw_visc.m)
%   k       - wavenumber [cpm], any shape
%
% OUTPUTS
%   Psg - theoretical shear power spectrum [s^-2/cpm], size numel(k) x
%         numel(epsilon) if either epsilon or k is non-scalar (outer
%         product - matches what mod_scan_calc_epsilon_mle.m's
%         log-likelihood grid search needs: one model curve per candidate
%         epsilon, all evaluated at the same observed k).
%
% CALLED BY
%   mod_scan_calc_epsilon_obs.m, mod_scan_calc_epsilon_mle.m,
%   mod_scan_calc_fom.m (via modProcess_L2_calc_epsilon.m)
%
% CALLS
%   (none)
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

epsilon = epsilon(:)'; % row, so k (column) outer-products cleanly below

k = k(:); % column
ks = (epsilon ./ nu.^3).^(1/4); % Kolmogorov wavenumber(s), 1 x Ne

x = k * (1 ./ ks); % nk x Ne, x = k/ks per candidate epsilon
G2 = 8.05 * x.^(1/3) ./ (1 + (20.6*x).^(3.715)); % Lueck's improved fit

Psg = (ones(size(k)) * (epsilon.^(3/4) * nu^(-1/4))) .* G2;

if isscalar(epsilon)
    Psg = reshape(Psg, size(k));
end

end %end function
