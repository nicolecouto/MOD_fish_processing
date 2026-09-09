function fom = mod_scan_calc_fom(k, Pobs, Pmodel, klim, dof)
% mod_scan_calc_fom        Part of MOD_fish_processing
%
% fom = mod_scan_calc_fom(k, Pobs, Pmodel, klim, dof)
%
% DESCRIPTION
%   Figure-of-merit: how well a model spectrum (e.g. a Nasmyth fit at some
%   epsilon estimate) matches an observed spectrum over a given wavenumber
%   range, as a single dimensionless number - values near 1 indicate a
%   good fit; large fom means the observed spectrum drifts systematically
%   away from the model shape (contamination, a bad estimate, or a
%   spectrum this model family simply doesn't describe well).
%
%     ratio = log10(Pobs(klim) ./ Pmodel(klim))
%     fom   = mad(ratio) / sig_lnS / Tm
%
%   where sig_lnS = sqrt(5/4*(dof-1)^(-7/9)) is the theoretical standard
%   deviation of log(spectral ratio) for a dof-degree-of-freedom spectral
%   estimate, and Tm = 0.8 + sqrt(1.56/Ns) (Ns = 2*numel(k), the full
%   two-sided bin count) is a small-sample correction factor - both ported
%   as-is from MOD_fish_lib's mod_efe_scan_epsilon.m, which computes this
%   exact quantity inline for epsilon/epsilon_co's fom/fom_mle rather than
%   as its own named function there (MOD_fish_lib's mod_efe_scan_chi.m has
%   its own separate compute_fom local subfunction for chi - not read
%   closely enough during this port to confirm it's the identical formula,
%   flagged as a follow-up if chi ever gets its own FOM wired in).
%
%   Not specific to epsilon or to a Nasmyth model - Pobs/Pmodel can be any
%   spectral observation/model pair on the same wavenumber axis (this
%   repo's own batchelor_spectrum.m for a future chi FOM
%   included), matching how spectral_loglikelihood.m is similarly kept
%   model-agnostic. That generality is why this lives alongside the
%   generic MLE/model machinery in processing/scans/ rather than being a
%   private local function inside modProcess_L2_calc_epsilon.m.
%
% INPUTS
%   k      - wavenumber vector [cpm], any shape, matching Pobs/Pmodel
%   Pobs   - observed spectrum, same shape as k
%   Pmodel - model spectrum evaluated at the same k, same shape as k
%   klim   - [kmin, kmax] wavenumber range [cpm] to compare over -
%            typically the same range the model was fit/integrated over
%            (e.g. mod_scan_calc_epsilon_obs.m's [kmin_obs, kc])
%   dof    - degrees of freedom of the spectral estimate, scalar
%            (processing/scans/mod_scan_dof.m)
%
% OUTPUTS
%   fom - figure of merit, scalar. NaN if fewer than 2 bins fall in klim
%         (mad of a single value, or of nothing, is not meaningful).
%
% CALLED BY
%   modProcess_L2_calc_epsilon.m
%
% CALLS
%   (none)
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

k = k(:);
Pobs = Pobs(:);
Pmodel = Pmodel(:);

krange = k >= klim(1) & k <= klim(2);
if nnz(krange) < 2
    fom = NaN;
    return
end

ratio = log10(Pobs(krange) ./ Pmodel(krange));

sig_lnS = sqrt(5/4 * (dof-1)^(-7/9));
Ns = 2 * numel(k);
Tm = 0.8 + sqrt(1.56/Ns);

fom = mad(ratio) / sig_lnS / Tm; % mad(x) with no 2nd arg = MEAN absolute deviation (MATLAB default), matching legacy's unflagged mad(fom) call - NOT mad(x,1), which would be the median variant

end %end function
