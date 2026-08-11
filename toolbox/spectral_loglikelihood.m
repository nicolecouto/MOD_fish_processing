function logL = spectral_loglikelihood(Pobs, Pth, dof)
% spectral_loglikelihood        Part of MOD_fish_processing
%
% logL = spectral_loglikelihood(Pobs, Pth, dof)
%
% DESCRIPTION
%   Log-likelihood of an observed spectral estimate Pobs against one or
%   more candidate model spectra Pth, following the Maximum Likelihood
%   Spectral Fitting method of Ruddick, Anis & Thompson (2000, J. Atmos.
%   Oceanic Technol. 17). Assumes each frequency/wavenumber bin of Pobs
%   is chi-squared distributed about its true (model) value with dof
%   degrees of freedom - i.e. Y = Pobs/Pth ~ chi2(dof)/dof, their eq.
%   (16) - rather than treating Pobs as exact, which lets bins with more
%   averaging (higher dof, lower variance) count more toward the fit
%   than noisy ones.
%
%   Implements their eq. (18) exactly:
%     logL = sum_i[ ln( chi2pdf(dof*Pobs_i/Pth_i, dof) / Pth_i ) ]
%            + length(Pobs)*log(dof)
%   The 1/Pth_i inside the log and the +log(dof) term both come from
%   their eq. (17) normalizing factor d/S_th, which is the Jacobian of
%   the change of variables from their chi-squared quantity Y = Pobs/Pth
%   back to Pobs itself. The +length(Pobs)*log(dof) term is a constant
%   added identically to every candidate in Pth, so it never changes
%   which candidate maximizes logL - callers doing a pure argmax search
%   (e.g. mod_scan_calc_chi_mle.m) can ignore it, but it's kept here so
%   logL matches eq. (18) exactly and is directly usable/comparable on
%   its own (e.g. against a different dof or number of fit points).
%
%   Not specific to chi or to scans - Pobs/Pth can be any spectral
%   observation and any candidate model spectrum on the same axis (e.g.
%   Batchelor spectra for chi, as used by mod_scan_calc_chi_mle.m, or, as
%   in MOD_fish_lib's mle_any_model.m, an inertial-subrange/Nasmyth fit
%   for epsilon from shear spectra). That generality is why this lives in
%   toolbox/ rather than processing/scans/, matching how MOD_fish_lib
%   kept its equivalent (logLikelihood.m) in toolboxes/fitting_tools/
%   rather than under EPSILOMETER/EPSILON/.
%
% INPUTS
%   Pobs - observed spectrum, 1-D vector [M]
%   Pth  - candidate model spectrum/spectra on the same axis as Pobs,
%          [M x N] (one column per candidate, e.g. one per chi in a grid
%          search)
%   dof  - degrees of freedom of the spectral estimate, scalar
%
% OUTPUTS
%   logL - log-likelihood of each candidate, [1 x N]
%
% REQUIRES
%   chi2pdf (Statistics and Machine Learning Toolbox)
%
% CALLED BY
%   mod_scan_calc_chi_mle.m
%
% CALLS
%   (none)
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

Pobs = Pobs(:);
z = dof * Pobs ./ Pth;
logL = sum(log(chi2pdf(z, dof) ./ Pth), 1, 'omitnan') + numel(Pobs)*log(dof);
end
