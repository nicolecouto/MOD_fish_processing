function best_val = mod_scan_mle_grid_search(Pobs, dof, model_fn, seed, start_mult, end_mult)
% mod_scan_mle_grid_search        Part of MOD_fish_processing
%
% best_val = mod_scan_mle_grid_search(Pobs, dof, model_fn, seed, start_mult, end_mult)
%
% DESCRIPTION
%   Generic 1-D log-spaced MLE grid search for the single parameter value
%   that best explains an observed spectrum Pobs against a family of
%   candidate model spectra, via spectral_loglikelihood.m (Ruddick,
%   Ozsoy & Vagle 2000 / Ruddick, Anis & Thompson 2000). Not specific to
%   chi or epsilon - model_fn is a 1-argument closure that, given a vector
%   of candidate parameter values, returns the corresponding model
%   spectra [numel(Pobs) x numel(candidates)] on the same axis as Pobs -
%   the caller supplies everything else the model shape needs (fixed
%   parameters, wavenumber axis) already bound into that closure. Shared
%   by mod_scan_calc_chi_mle.m (searching chi, model =
%   batchelor_spectrum.m with epsilon/nu/ktemp/k fixed) and
%   mod_scan_calc_epsilon_mle.m (searching epsilon, model =
%   nasmyth_spectrum.m with nu/k fixed) - split out of what was
%   originally chi_mle's own local mle_search_chi function once epsilon
%   needed the identical search machinery, so the two searches can't
%   silently drift apart.
%
%   A fixed 4-pass, 200-point log-spaced grid zoom, replacing MOD_fish_lib's
%   original open-ended while-loops that widen the search range when the
%   best fit lands on an edge - but the same idea survives in bounded
%   form: hitting an edge here still widens (10x on the side that was
%   hit) rather than narrows, and that widening step does NOT consume one
%   of the 4 narrowing passes. Widening is capped at max_widen=10,
%   matching MOD_fish_lib's mle_any_model.m own cc<10 guard - the legacy
%   code budgets that cap separately per edge (low, high), but since a
%   single search here only ever climbs in one direction at a time (never
%   needs both budgets on the same call), one shared cc<10-sized budget
%   mirrors it directly rather than doubling it.
%
%   Seeding defaults to a caller-chosen number of decades wide on each
%   side of `seed` (start_mult/end_mult), despite widening being free of
%   the pass budget now: spectral_loglikelihood computes
%   log(chi2pdf(z,dof)), and chi2pdf underflows to exactly 0 in double
%   precision once a candidate is many decades from the truth - so a too-
%   narrow starting grid can end up with EVERY candidate underflowed
%   (all(~isfinite(logL)) true) before the widen logic ever runs,
%   returning NaN having never gotten to widen at all. A wide starting net
%   keeps at least one edge candidate close enough to stay numerically
%   finite, giving widening something to act on - a caller that narrows
%   start_mult/end_mult trades away some of that safety margin.
%
% INPUTS
%   Pobs       - observed spectrum, 1-D vector [M]
%   dof        - degrees of freedom of the spectral estimate, scalar
%                (processing/scans/mod_scan_dof.m)
%   model_fn   - function handle, model_fn(candidate_grid) -> [M x N]
%                model spectra, one column per candidate value in
%                candidate_grid [1 x N]
%   seed       - order-of-magnitude starting value for the parameter being
%                searched (e.g. a cheap direct-integration estimate)
%   start_mult - low-bound multiplier on seed (e.g. 1e-3 for chi, 1e-1 for
%                epsilon - see each caller's own registered defaults)
%   end_mult   - high-bound multiplier on seed
%
% OUTPUTS
%   best_val - the grid-search MLE estimate of the parameter, or NaN if
%              every candidate in the search range underflowed (see
%              DESCRIPTION)
%
% CALLED BY
%   mod_scan_calc_chi_mle.m, mod_scan_calc_epsilon_mle.m
%
% CALLS
%   spectral_loglikelihood.m
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

n_grid = 200;
n_pass = 4;
max_widen = 10; % mirrors mle_any_model.m's per-edge cc<10 guard - one shared

search_lo = seed * start_mult;
search_hi = seed * end_mult;

pass = 0;
n_widen = 0;
while pass < n_pass
    grid = logspace(log10(search_lo), log10(search_hi), n_grid);
    Pt = model_fn(grid);
    logL = spectral_loglikelihood(Pobs, Pt, dof);

    if all(~isfinite(logL))
        best_val = NaN;
        return
    end

    [~, best] = max(logL);
    if best == 1 || best == n_grid
        if n_widen >= max_widen
            best_val = grid(best);
            return
        end
        if best == 1
            search_lo = search_lo / 10;
            search_hi = grid(2);
        else
            search_hi = search_hi * 10;
            search_lo = grid(n_grid - 1);
        end
        n_widen = n_widen + 1;
        continue % do not advance pass - retry with this new search range
    end

    search_lo = grid(best - 1);
    search_hi = grid(best + 1);
    pass = pass + 1;
end

best_val = grid(best);

end %end function
