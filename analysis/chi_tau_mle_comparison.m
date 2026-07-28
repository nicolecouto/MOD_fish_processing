% chi_tau_mle_comparison.m        Part of MOD_fish_processing
%
% One-off analysis script (not a MODprocess_ pipeline function - it does
% file I/O and produces a printed report, which PLAN.md Section 2's "pure
% transformation functions" rule deliberately keeps out of processing/).
% Built on branch `chi_processing` to answer the two questions raised in
% mod_fish_lib/data_for_reorg/epsi_mako/astral/astral_chi.md:
%
%   1. How much does correcting the FP07 time constant (tau0 = 0.005,
%      silently wrong for decades - see mod_scan_fpo7_transfer_function.m's
%      NOTES - versus ~0.0086 s, the middle of astral_chi.md's documented
%      0.0083-0.0089 s range) change chi?
%   2. How much does chi_mle (Batchelor-spectrum MLE fit,
%      mod_scan_calc_chi_mle.m) differ from chi_obs (direct
%      wavenumber integration, mod_scan_calc_chi_obs.m) on the same
%      scans?
%
% Runs against a real ASTRAL profile (Profile100.mat) - an old-format
% MOD_fish_lib Profile struct, not this repo's own L2 output. Its
% Pt_volt_f.(ch) field is exactly the raw FP07 voltage power spectrum
% mod_scan_calc_chi_obs.m/mod_scan_calc_chi_mle.m expect as
% their `Pxx` input, so both functions run directly against it with no
% need to go back to the deployment's raw .modraw files - see
% docs/workflow/L2_calc_chi.md.
%
% ASSUMPTIONS specific to reading this old-format file (would not apply to
% this repo's own L1->L2 output, which already carries a single
% deployment-wide metadata.AFE.(ch).volts_to_C from
% MODprocess_L1_apply_fpo7_calibration.m):
%   - volts_to_C's slope is taken from this file's own
%     Meta_Data.AFE.(ch).cal_profile, linearly interpolated at each scan's
%     pressure against Meta_Data.AFE.t1.pr (the 9-bin pressure-local
%     in-situ calibration segments - only t1 carries the shared `pr` bin
%     vector in this file; t2's cal_profile is the same length and uses
%     the same bins, just without repeating `pr` in its own struct) - not
%     re-fit here. The intercept is set to 0 since neither
%     chi_obs nor chi_mle use it (only volts_to_C(1), the slope - see
%     mod_scan_fpo7_volts_to_Tg_spectrum.m).
%   - epsilon for chi_mle is this file's own Profile.epsilon_final(scan) -
%     already a single QC-picked shear-based value per scan (confirmed
%     317x1, not the raw per-shear-channel 317x2 Profile.epsilon). Not
%     computed by this repo - modProcess_L2_calc_epsilon.m is not started
%     yet, so this comparison is only possible because this old-format
%     file already carries an epsilon estimate.
%   - Thermal diffusivity is recomputed fresh via this repo's
%     mod_scan_thermal_diffusivity.m from Profile.s/.t/.pr; kinematic
%     viscosity is toolbox/seawater/sw_visc.m called directly (no wrapper
%     - see docs/workflow/L2_calc_chi.md). Neither is read from this
%     file's own Profile.kvis (kept independent of the old pipeline's own
%     values, since validating those isn't this script's job).
%
% Read-only against real data (Profile100.mat, FPO7_benchnoise.mat) -
% nothing in mod_fish_lib/data_for_reorg or MOD_fish_calibrations is
% written to.
%
% CALLS
%   mod_scan_calc_chi_obs.m, mod_scan_calc_chi_mle.m,
%   mod_scan_thermal_diffusivity.m, sw_visc.m (toolbox/seawater)
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

clear;

%% Config - edit paths for your machine
profile_path = '/Users/ncouto/Library/CloudStorage/Dropbox/SIO/projects/mod_fish_lib/data_for_reorg/epsi_mako/astral/profiles/Profile100.mat';
noise_file   = '/Users/ncouto/GitHub/modscripps/MOD_fish_calibrations/FPO7/FPO7_benchnoise.mat';
channels     = {'t1', 't2'};

tau0_default = 0.005;    exponent_default   = -0.32; % MOD_fish_lib's long-standing (silently wrong) value
tau0_candidate = 0.0086; exponent_candidate = -0.32; % middle of astral_chi.md's 0.0083-0.0089 s range

%% Load
d = load(profile_path);
P = d.Profile;
noise_coefs = load(noise_file, 'n0', 'n1', 'n2', 'n3');
dof = P.Meta_Data.PROCESS.dof;
f = P.f;
nbscan = P.nbscan;
cal_pr = P.Meta_Data.AFE.t1.pr; % shared pressure-bin vector for all fpo7 channels' cal_profile

results = struct();

for iC = 1:numel(channels)
    ch = channels{iC};
    AFE = P.Meta_Data.AFE.(ch);

    chi_obs_default   = nan(nbscan, 1);
    chi_obs_candidate = nan(nbscan, 1);
    chi_mle_default   = nan(nbscan, 1);
    chi_mle_candidate = nan(nbscan, 1);

    for iScan = 1:nbscan
        w = P.w(iScan);
        if ~isfinite(w) || w == 0
            continue
        end

        Pxx = P.Pt_volt_f.(ch)(iScan, :);
        slope = interp1(cal_pr, AFE.cal_profile, P.pr(iScan), 'linear', 'extrap');
        volts_to_C = [slope, 0];

        ktemp = mod_scan_thermal_diffusivity(P.s(iScan), P.t(iScan), P.pr(iScan));
        nu = sw_visc(P.s(iScan), P.t(iScan), P.pr(iScan));
        epsilon = P.epsilon_final(iScan);

        chi_obs_default(iScan) = mod_scan_calc_chi_obs( ...
            f, Pxx, w, volts_to_C, ktemp, noise_coefs, tau0_default, exponent_default);
        chi_obs_candidate(iScan) = mod_scan_calc_chi_obs( ...
            f, Pxx, w, volts_to_C, ktemp, noise_coefs, tau0_candidate, exponent_candidate);

        if isfinite(epsilon) && epsilon > 0
            chi_mle_default(iScan) = mod_scan_calc_chi_mle( ...
                f, Pxx, w, volts_to_C, ktemp, nu, epsilon, dof, noise_coefs, tau0_default, exponent_default);
            chi_mle_candidate(iScan) = mod_scan_calc_chi_mle( ...
                f, Pxx, w, volts_to_C, ktemp, nu, epsilon, dof, noise_coefs, tau0_candidate, exponent_candidate);
        end
    end

    results.(ch).chi_obs_default   = chi_obs_default;
    results.(ch).chi_obs_candidate = chi_obs_candidate;
    results.(ch).chi_mle_default   = chi_mle_default;
    results.(ch).chi_mle_candidate = chi_mle_candidate;
end

%% Report
fprintf('\n%s, %d scans, tau0 %.4g -> %.4g s (exponent %.2f unchanged)\n\n', ...
    profile_path, nbscan, tau0_default, tau0_candidate, exponent_default);

for iC = 1:numel(channels)
    ch = channels{iC};
    r = results.(ch);

    n_obs = sum(isfinite(r.chi_obs_default));
    n_mle = sum(isfinite(r.chi_mle_default));

    med_obs_default   = median(r.chi_obs_default, 'omitnan');
    med_obs_candidate = median(r.chi_obs_candidate, 'omitnan');
    med_mle_default   = median(r.chi_mle_default, 'omitnan');
    med_mle_candidate = median(r.chi_mle_candidate, 'omitnan');

    fprintf('--- %s (chi_obs: %d/%d valid scans, chi_mle: %d/%d) ---\n', ch, n_obs, nbscan, n_mle, nbscan);
    fprintf('  chi_obs   median: %10.3e (default tau) -> %10.3e (candidate tau), %.2fx\n', ...
        med_obs_default, med_obs_candidate, med_obs_candidate / med_obs_default);
    fprintf('  chi_mle   median: %10.3e (default tau) -> %10.3e (candidate tau), %.2fx\n', ...
        med_mle_default, med_mle_candidate, med_mle_candidate / med_mle_default);
    fprintf('  chi_mle / chi_obs, default tau: %.2fx\n', med_mle_default / med_obs_default);
    fprintf('  chi_mle / chi_obs, candidate tau: %.2fx\n\n', med_mle_candidate / med_obs_candidate);
end
