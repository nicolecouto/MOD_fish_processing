function L2data = MODprocess_single_L1_to_L2(data, metadata, PressureTimeseries)
% MODprocess_single_L1_to_L2        Part of MOD_fish_processing
%
% L2data = MODprocess_single_L1_to_L2(data, metadata, PressureTimeseries)
%
% DESCRIPTION
%   Converts one blob of epsi+ctd data into its per-scan L2 spectra/chi/
%   epsilon. Generic over where that blob came from - a whole L1 file
%   (realtime mode) or one already-extracted, direction-pure profile
%   (post-processing mode, from MODprocess_all_extract_profiles.m via
%   Profile####.mat) - this function never branches on which. Both are
%   just "a struct with epsi/ctd, maybe some extra bookkeeping fields"; it
%   processes whatever epsi/ctd it's given and carries through whichever
%   of profile_number/direction/filenames/dnum_start/dnum_end happen to
%   already be present (see OUTPUTS). MODprocess_all_L1_to_L2.m is the one
%   driver for both modes - see that function's DESCRIPTION.
%
%   mod_L2_tile_scans.m decides where the scans and within-scan fft
%   segments are (pure index math - no data). This function does
%   everything else, per kept scan: slices epsi/ctd, computes raw spectra
%   (mod_scan_get_spectra.m, including ctd.P/T/C), CTD scalar
%   interpolation (pressure/fall speed/temperature/salinity/nu/ktemp), and
%   the full chi_obs/epsilon/chi_mle chain per channel - see
%   docs/workflow/L2_calc_chi.md and docs/workflow/L2_calc_eps.md for
%   those chains.
%
%   Whether epsi is even tiled at all: only if this deployment has epsi
%   hardware (metadata.manifest.has_epsi) AND, when data carries a
%   .direction (i.e. data came from a profile extraction - a raw L1 file
%   never has this field), this deployment trusts that direction for epsi
%   (metadata.PROFILES.profile_dir is 'both', or matches data.direction).
%   metadata.PROFILES.profile_dir (default 'down') reflects that, on an
%   epsi-equipped deployment, the CTD/pressure sensor is normally
%   trustworthy on every cast, but shear/fpo7 usually is not (vehicle wake
%   turbulence on the untrusted direction). A realtime L1 file (no
%   .direction) always attempts epsi tiling when has_epsi is true - it may
%   span both directions, so per-scan direction gating (below) is what
%   actually filters it, not this deployment-level check. When epsi isn't
%   tiled, mod_L2_tile_scans.m's empty-input path still runs (0 scans),
%   and this function still returns real ctd/profile-bookkeeping fields -
%   every call gets the same field set, whether or not it has spectra.
%
%   Only scans classified as descending (PressureTimeseries.is_down at the
%   scan's center time) get processed, when PressureTimeseries is given -
%   realtime mode always passes it; post-processing mode omits it, since a
%   profile from modProcess_detect_profiles.m is already direction-pure by
%   construction (per-scan gating would be redundant) - see
%   mod_L2_tile_scans.m's DESCRIPTION.
%
%   Also computes chi_obs (direct-integration thermal variance dissipation
%   rate) per scan for every fpo7 channel that has a resolved
%   metadata.AFE.(ch).volts_to_C (MODprocess_L1_apply_fpo7_calibration.m) -
%   i.e. deployments with a real onboard CTD, not DeepSolo's P-only
%   external CTD. Needs scan-center temperature/salinity (interpolated the
%   same way pressure already was) and the FP07 bench noise floor file
%   (MOD_fish_calibrations/FPO7/FPO7_benchnoise.mat, via
%   metadata.paths.calibrations_root), loaded once here and passed into
%   mod_scan_calc_chi_obs.m as noise_coefs. The AFE electronics/ADC
%   deconvolution (metadata.AFE.(ch).electronics_filter,
%   MODsetup_define_filters.m) happens inside
%   mod_scan_fpo7_volts_to_Tg_spectrum.m, not here; missing (older
%   metadata.mat) is not an error there, just no electronics correction
%   for that channel. See docs/workflow/L2_calc_chi.md for the full chain.
%
%   Computes epsilon (turbulent kinetic energy dissipation rate) per scan
%   for every shear channel with a resolved metadata.AFE.(ch).cal (a
%   bench-measured Sv, from MODsetup_read_yaml.m's shear-probe calibration
%   lookup) - gated on the same have_ctd_ts condition as chi_obs, since
%   kinematic viscosity (nu, needed by the epsilon calculation the same
%   way ktemp is needed by chi) also depends on real CTD T/S
%   (toolbox/seawater/visc.m). mod_scan_calc_epsilon.m does the
%   per-channel work (transfer function, coherence, direct-integration and
%   MLE epsilon estimates, figure of merit); see docs/workflow/L2_calc_eps.md
%   for the full chain.
%
%   chi_mle (mod_scan_calc_chi_mle.m) uses the epsilon this same scan just
%   computed - selected per metadata.PROCESS.EPSILON.epsilon_final_source
%   as the mean, omitting NaN, of whichever epsilon variant across this
%   deployment's shear channels (see below). This per-scan mean is a
%   deliberate simplification, not the full profile-level ratio-based
%   per-channel selection MOD_fish_lib's legacy pipeline does (comparing
%   s1 vs. s2 across a whole profile and picking whichever channel looks
%   more trustworthy) - that selection needs profile-level QC
%   (modProcess_L2_qc.m), not built yet. chi_mle is skipped for a scan
%   whose epsilon comes back NaN/non-finite (e.g. no shear channels
%   resolved, or every shear channel's own epsilon estimate failed).
%
% INPUTS
%   data      - struct with epsi, ctd (an L1 file's or a Profile####.mat's
%               shape), optionally profile_number, direction, filenames,
%               dnum_start, dnum_end (only ever present on an extracted
%               profile - see OUTPUTS and DESCRIPTION)
%   metadata  - metadata struct (from MODsetup_read_yaml.m). Directly used
%               here: metadata.manifest.has_epsi, metadata.PROFILES.profile_dir
%               (only validated/read when data.direction is present - see
%               DESCRIPTION), metadata.PROCESS.channels,
%               metadata.AFE.(channel).type/.volts_to_C/.cal,
%               metadata.paths.calibrations_root (FPO7 bench noise file),
%               metadata.PROCESS.EPSILON.epsilon_final_source. Passed
%               straight through, whole, to mod_L2_tile_scans.m,
%               mod_scan_get_spectra.m, mod_scan_calc_chi_obs.m,
%               mod_scan_calc_epsilon.m, mod_scan_calc_chi_mle.m - see each
%               one's own header for the specific fields it reads.
%   PressureTimeseries - (optional) struct with dnum, is_down (from
%               mod_L1_detect_profiling_direction.m via
%               meta/pressure_time_series.mat) - the whole-deployment
%               record, not sliced to this file/profile. Passed straight
%               through to mod_L2_tile_scans.m - see that function's
%               INPUTS for exact gating semantics.
%
% OUTPUTS
%   L2data - struct with:
%     ctd                  - data.ctd, unchanged: the raw, uninterpolated
%                             ctd record this call was given - present
%                             regardless of whether epsi was tiled.
%     profile_gap_fraction - fraction of data.epsi's sample count that
%                             falls in a segment_id run other than the
%                             largest one (see gap_fraction subfunction
%                             below) - a cheap proxy for "how much of this
%                             call's raw coverage was on the losing side
%                             of an internal gap." 0 when data.epsi has no
%                             segment_id (realtime mode, or no epsi data
%                             at all - segment_id is only ever set by
%                             modProcess_extract_profile.m).
%     profile_number, direction, filenames, dnum_start, dnum_end - present
%                             only if the corresponding field exists on
%                             `data` (i.e. data came from a profile
%                             extraction) - passthrough, untouched.
%   and, for each kept scan:
%     dnum        - scan center time [datenum], nbscan x 1
%     pressure    - CTD pressure at scan center [dbar], interpolated from
%                   ctd.P, nbscan x 1
%     w           - fall speed at scan center [m/s], interpolated from
%                   ctd.dzdt the same way pressure is interpolated from
%                   ctd.P, nbscan x 1. This is the fall-speed-dependent
%                   input mod_scan_calc_chi_obs.m (via
%                   mod_scan_fpo7_transfer_function.m) needs. Not abs'd
%                   here (mod_scan_fpo7_transfer_function.m does that
%                   itself) so the sign stays available for sanity checks
%                   (positive on a real descending scan).
%     temperature - CTD temperature at scan center [degC], interpolated
%                   from ctd.T the same way pressure is, nbscan x 1. Only
%                   populated if ctd has both T and S (real onboard CTD,
%                   e.g. Mako - never true for DeepSolo's P-only external
%                   CTD) - stays NaN otherwise.
%     salinity    - CTD Practical Salinity (ctd.SP) at scan center [psu],
%                   same conditions as temperature, nbscan x 1.
%     SR          - Reference Salinity at scan center [g/kg]
%                   (gsw_SR_from_SP(salinity), interpolated from ctd.SR the
%                   same way), same conditions as temperature, nbscan x 1 -
%                   see docs/concepts/units_and_seawater.md for why SR
%                   (not exact SA) is used throughout this repo's GSW calls.
%     nu          - kinematic viscosity at scan center [m^2/s]
%                   (toolbox/seawater/visc.m), same conditions as
%                   temperature, nbscan x 1. Feeds epsilon (via
%                   mod_scan_calc_epsilon.m) and chi_mle.
%     ktemp       - thermal diffusivity at scan center [m^2/s]
%                   (toolbox/seawater/ktemp.m), nbscan x 1. Only
%                   populated when chi_obs_channels is non-empty (see
%                   below) - stays NaN otherwise, same as spectra.k.
%     spectra.f              - frequency vector [Hz], shared across all
%                   scans and epsi channels, 1 x nfreq
%     spectra.(channel)_f    - power spectrum matrix, nbscan x nfreq, one
%                   field per shear/fpo7/acc channel (see
%                   mod_scan_get_spectra.m; key already includes the '_f'
%                   domain suffix, e.g. 't1_volt_f', 'a2_g_f')
%     spectra.f_ctd, spectra.P_f, spectra.T_f, spectra.C_f - ctd single-
%                   periodogram spectra (see mod_scan_get_spectra.m),
%                   nbscan x nfreq_ctd each - present only for whichever
%                   of P/T/C this deployment's ctd actually has.
%     spectra.k              - wavenumber matrix [cpm], nbscan x nfreq,
%                   k = f / abs(w) - depends on scan (via w) but not on
%                   channel, so one shared matrix rather than a copy per
%                   channel. Only populated when chi_obs_channels is
%                   non-empty (see below) - it's a byproduct of that
%                   computation, not computed independently.
%     spectra.(channel)_Tg_k - deconvolved temperature-gradient wavenumber
%                   spectrum, nbscan x nfreq, one field per fpo7 channel in
%                   chi_obs_channels (see chi_obs.(channel) below) -
%                   mod_scan_calc_chi_obs.m's intermediate Pt_Tg_k, kept
%                   rather than discarded after computing chi_obs from it.
%     spectra.(channel)_fc_index - noise-floor cutoff index into
%                   spectra.f/spectra.k/spectra.(channel)_f, nbscan x 1,
%                   one field per fpo7 channel in chi_obs_channels - see
%                   mod_scan_fpo7_cutoff.m's OUTPUTS.
%     chi_obs.(channel)    - direct-integration thermal variance
%                   dissipation rate [degC^2/s], nbscan x 1, one field per
%                   fpo7 channel that both has a resolved
%                   metadata.AFE.(channel).volts_to_C AND ctd has real
%                   T/S (see temperature/salinity above) - this struct
%                   simply has no fields at all otherwise. Individual
%                   scans within a present field can still be NaN
%                   (mod_scan_calc_chi_obs.m - no valid noise-floor
%                   cutoff range for that scan).
%     chi_obs_kc.(channel) - the noise-floor cutoff wavenumber [cpm] used
%                   for each chi_obs.(channel) value - diagnostic, see
%                   mod_scan_calc_chi_obs.m's OUTPUTS. Same values as
%                   spectra.k(:, spectra.(channel)_fc_index), just
%                   pre-indexed for convenience.
%     epsilon_final - the per-scan epsilon value actually fed to chi_mle
%                   below [W/kg], nbscan x 1 - mean, omitting NaN, across
%                   this deployment's epsilon_channels of whichever
%                   variant epsilon_final_source (below) selects. A
%                   per-scan simplification, not the full profile-level
%                   ratio-based per-channel selection MOD_fish_lib's
%                   legacy pipeline does - see docs/workflow/L2_calc_eps.md's
%                   "Known limitations."
%     epsilon_final_source - which variant epsilon_final actually is this
%                   run, resolved once from
%                   metadata.PROCESS.EPSILON.epsilon_final_source: the
%                   scalar string 'epsilon_mle' or 'epsilon_co' (an
%                   unrecognized/invalid metadata value falls back to
%                   'epsilon_co', same as it always has - this field makes
%                   that fallback visible in the output instead of
%                   silent), or '' if epsilon_channels was empty for this
%                   whole call (epsilon never computed at all).
%     chi_mle.(channel)    - Batchelor-spectrum MLE-fit thermal variance
%                   dissipation rate [degC^2/s], nbscan x 1, one field per
%                   fpo7 channel in chi_obs_channels (see chi_obs above) -
%                   computed only for scans where L2data.epsilon_final
%                   (above) is finite. NaN for every scan otherwise.
%     epsilon_obs.(channel), .epsilon_obs_kc.(channel),
%     epsilon_obs_coh_corr.(channel), .epsilon_obs_coh_corr_kc.(channel),
%     epsilon_mle.(channel), .fom.(channel), .fom_mle.(channel),
%     coherence_sum.(channel) - direct-integration, MLE, and figure-of-
%                   merit epsilon products, nbscan x 1 each, one field per
%                   shear channel that both has a resolved
%                   metadata.AFE.(channel).cal AND ctd has real T/S (same
%                   have_ctd_ts gate as chi_obs, since kinematic viscosity
%                   nu needs T/S the same way ktemp does) - these structs
%                   simply have no fields at all otherwise. See
%                   mod_scan_calc_epsilon.m's OUTPUTS for what each
%                   one means; coherence_sum is that function's
%                   spectra.(channel)_coh_a3_sum, pulled up to a top-level
%                   field for the same "kept rather than discarded"
%                   reason chi_obs_kc is.
%     spectra.(channel)_shear_k, .(channel)_shear_co_k - raw and
%                   coherence-cleaned shear wavenumber spectra, nbscan x
%                   nfreq, one pair per shear channel with epsilon
%                   computed - mod_scan_calc_epsilon_obs.m's integration
%                   inputs, kept the same way spectra.(channel)_Tg_k is
%                   for chi. _shear_co_k stays NaN for a scan with no
%                   usable coherence.
%     fft_length, fft_segments_per_scan, dof, Fs_epsi, N_epsi, scan_step -
%                   provenance, passed through from mod_L2_tile_scans.m.
%   nbscan is 0 (all per-scan fields empty) if epsi wasn't tiled at all
%   (see DESCRIPTION), is too short for even one scan, or (realtime mode
%   only) no scan lands on a descending part of the record. ctd/
%   profile_gap_fraction/profile_number/etc. are still populated in that
%   case.
%
% CALLED BY
%   MODprocess_all_L1_to_L2.m
%
% CALLS
%   mod_L2_tile_scans.m, mod_scan_get_spectra.m, toolbox/seawater/ktemp.m,
%   toolbox/seawater/visc.m, mod_scan_calc_chi_obs.m (only for fpo7
%   channels with a resolved volts_to_C calibration), mod_scan_calc_chi_mle.m
%   (only for scans with a finite epsilon estimate),
%   mod_scan_calc_epsilon.m (only for shear channels with a resolved
%   Sv calibration), MODsetup_validate_metadata.m
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

if nargin < 3
    PressureTimeseries = [];
end

yaml_file = '';
if isfield(metadata, 'paths') && isfield(metadata.paths, 'setup_yml')
    yaml_file = metadata.paths.setup_yml;
end

epsi = data.epsi;
ctd = data.ctd;

epsi_for_tiling = epsi;
if isfield(data, 'direction')
    metadata = MODsetup_validate_metadata(metadata, yaml_file, {'profile_dir'});
    trust_this_direction = strcmp(metadata.PROFILES.profile_dir, 'both') ...
        || strcmp(data.direction, metadata.PROFILES.profile_dir);
else
    trust_this_direction = true; % realtime mode: no direction label to distrust here - see DESCRIPTION
end
if ~metadata.manifest.has_epsi || ~trust_this_direction
    epsi_for_tiling = struct('dnum', []);
end

tiled_scans = mod_L2_tile_scans(epsi_for_tiling, metadata, PressureTimeseries);

L2data = empty_L2data(tiled_scans);
L2data.ctd = ctd;
L2data.profile_gap_fraction = gap_fraction(epsi);
passthrough_fields = {'profile_number', 'direction', 'filenames', 'dnum_start', 'dnum_end'};
for iF = 1:numel(passthrough_fields)
    field = passthrough_fields{iF};
    if isfield(data, field)
        L2data.(field) = data.(field);
    end
end

nbscan = numel(tiled_scans.idx0);
if nbscan == 0
    return
end

have_ctd = ~isempty(ctd) && isfield(ctd, 'dnum') && isfield(ctd, 'P') ...
    && isfield(ctd, 'dzdt') && numel(ctd.dnum) > 1;

% Real CTD temperature/salinity - only true for deployments with an
% onboard CTD (e.g. Mako), never for DeepSolo's P-only external CTD.
% Needed for both chi's thermal diffusivity (ktemp) and, upstream, ever
% having a metadata.AFE.(ch).volts_to_C in the first place
% (MODprocess_L1_apply_fpo7_calibration.m).
have_ctd_ts = have_ctd && isfield(ctd, 'T') && isfield(ctd, 'SP') ...
    && ~isempty(ctd.T) && ~isempty(ctd.SP);

% Which fpo7 channels can get chi_obs computed: only those with a resolved
% in-situ calibration, and only if this deployment has the CTD T/S/P chi's
% thermal diffusivity needs. The bench noise floor file is loaded once
% here (not per scan) - if it's missing, chi_obs is skipped entirely
% rather than erroring per scan.
chi_obs_channels = {};
noise_coefs = [];
if have_ctd_ts
    for iC = 1:numel(metadata.PROCESS.channels)
        ch = metadata.PROCESS.channels{iC};
        if isfield(metadata.AFE, ch) && strcmpi(metadata.AFE.(ch).type, 'fpo7') ...
                && isfield(metadata.AFE.(ch), 'volts_to_C')
            chi_obs_channels{end+1} = ch; %#ok<AGROW>
        end
    end
    if ~isempty(chi_obs_channels)
        noise_file = fullfile(metadata.paths.calibrations_root, 'FPO7', 'FPO7_benchnoise.mat');
        if isfile(noise_file)
            noise_coefs = load(noise_file, 'n0', 'n1', 'n2', 'n3');
        else
            warning('MODprocess_single_L1_to_L2:noBenchNoiseFile', ...
                ['FP07 bench noise file not found at %s - chi_obs not computed ' ...
                'for this record.'], noise_file);
            chi_obs_channels = {};
        end
    end
end

% Which shear channels can get epsilon computed: only those with a
% resolved bench Sv calibration, and only if this deployment has the CTD
% T/S/P kinematic viscosity (nu) needs - same have_ctd_ts gate chi_obs
% uses, for the same reason (nu depends on T/S the same way ktemp does).
epsilon_channels = {};
epsilon_final_source_resolved = ''; % stays empty if epsilon_channels never ends up non-empty
if have_ctd_ts
    for iC = 1:numel(metadata.PROCESS.channels)
        ch = metadata.PROCESS.channels{iC};
        if isfield(metadata.AFE, ch) && strcmpi(metadata.AFE.(ch).type, 'shear') ...
                && isfield(metadata.AFE.(ch), 'cal') && ~isempty(metadata.AFE.(ch).cal)
            epsilon_channels{end+1} = ch; %#ok<AGROW>
        end
    end
    if ~isempty(epsilon_channels)
        % epsilon_final_source is read directly (not by any epsilon
        % sub-function) in the per-scan loop below, to pick which epsilon
        % variant feeds chi_mle - validate it here, once, rather than at
        % point of use inside the loop.
        metadata = MODsetup_validate_metadata(metadata, yaml_file, {'epsilon_final_source'});

        % Resolved once here, not re-switched every scan: also what
        % L2data.epsilon_final_source records, so the output data itself
        % is traceable to which variant was actually used, independent of
        % whatever the yaml/metadata value literally was (e.g. a typo or
        % unrecognized string falls through to 'epsilon_co' below, same as
        % it always has - this just makes that fallback visible in the
        % output instead of silent).
        switch metadata.PROCESS.EPSILON.epsilon_final_source
            case 'epsilon_mle'
                epsilon_final_source_resolved = 'epsilon_mle';
            otherwise
                epsilon_final_source_resolved = 'epsilon_co';
        end
    end
end

dnum_all = tiled_scans.dnum;
pressure_all = nan(nbscan, 1);
w_all = nan(nbscan, 1);
temperature_all = nan(nbscan, 1);
SP_all = nan(nbscan, 1);
SR_all = nan(nbscan, 1);
nu_all = nan(nbscan, 1);
ktemp_all = nan(nbscan, 1);
epsilon_all = nan(nbscan, 1); % per-scan value actually fed to chi_mle - see below
chi_obs_all = struct();
chi_obs_kc_all = struct();
for iC = 1:numel(chi_obs_channels)
    chi_obs_all.(chi_obs_channels{iC}) = nan(nbscan, 1);
    chi_obs_kc_all.(chi_obs_channels{iC}) = nan(nbscan, 1);
end
chi_mle_all = struct();
for iC = 1:numel(chi_obs_channels)
    chi_mle_all.(chi_obs_channels{iC}) = nan(nbscan, 1);
end
epsilon_fields = {'epsilon_obs', 'epsilon_obs_kc', 'epsilon_obs_coh_corr', 'epsilon_obs_coh_corr_kc', ...
    'epsilon_mle', 'fom', 'fom_mle', 'coherence_sum'};
epsilon_all_by_field = struct();
for iF = 1:numel(epsilon_fields)
    epsilon_all_by_field.(epsilon_fields{iF}) = struct();
    for iC = 1:numel(epsilon_channels)
        epsilon_all_by_field.(epsilon_fields{iF}).(epsilon_channels{iC}) = nan(nbscan, 1);
    end
end
scan_results = cell(nbscan, 1);

for iScan = 1:nbscan
    idx0 = tiled_scans.idx0(iScan);
    idx1 = tiled_scans.idx1(iScan);
    center_dnum = dnum_all(iScan);

    scan = struct();
    scan.epsi = slice_epsi(epsi, idx0, idx1);
    scan.ctd = slice_ctd_by_time(ctd, epsi.dnum(idx0), epsi.dnum(idx1));
    scan_results{iScan} = mod_scan_get_spectra(scan, metadata);

    if have_ctd
        pressure_all(iScan) = interp1(ctd.dnum, ctd.P, center_dnum, 'linear', 'extrap');
        w_all(iScan) = interp1(ctd.dnum, ctd.dzdt, center_dnum, 'linear', 'extrap');
    end
    if have_ctd_ts
        temperature_all(iScan) = interp1(ctd.dnum, ctd.T, center_dnum, 'linear', 'extrap');
        SP_all(iScan) = interp1(ctd.dnum, ctd.SP, center_dnum, 'linear', 'extrap');
        SR_all(iScan) = interp1(ctd.dnum, ctd.SR, center_dnum, 'linear', 'extrap');

        % nu (kinematic viscosity) is needed by epsilon the same way ktemp
        % is needed by chi - computed once per scan, shared across every
        % shear channel and (via chi_mle) every fpo7 channel too. visc.m
        % (not a GSW function, but GSW-backed internally - see
        % toolbox/seawater/visc.m) takes Reference Salinity.
        nu = visc(SR_all(iScan), temperature_all(iScan), pressure_all(iScan));
        nu_all(iScan) = nu;

        if ~isempty(chi_obs_channels)
            % Local variable deliberately NOT named "ktemp" - it would
            % shadow the toolbox/seawater/ktemp.m function itself once
            % assigned, breaking the call on every scan after the first
            % (MATLAB treats a name as a variable, not a function, for the
            % rest of a function's scope once it's been assigned anywhere
            % in that scope).
            ktemp_scan = ktemp(SP_all(iScan), SR_all(iScan), temperature_all(iScan), pressure_all(iScan));
            ktemp_all(iScan) = ktemp_scan;
            for iC = 1:numel(chi_obs_channels)
                ch = chi_obs_channels{iC};
                volt_field = [ch '_volt_f'];
                chan_scan = struct();
                chan_scan.spectra.f = scan_results{iScan}.spectra.f;
                chan_scan.spectra.Pt_volt_f = scan_results{iScan}.spectra.(volt_field);
                chan_scan.w = w_all(iScan);
                chan_scan.ktemp = ktemp_scan;
                scan_results{iScan}.chi.(ch) = mod_scan_calc_chi_obs(chan_scan, metadata, ch, noise_coefs);
                chi_obs_all.(ch)(iScan) = scan_results{iScan}.chi.(ch).chi_obs;
                chi_obs_kc_all.(ch)(iScan) = scan_results{iScan}.chi.(ch).chi_obs_kc;
            end
        end

        if ~isempty(epsilon_channels)
            for iC = 1:numel(epsilon_channels)
                ch = epsilon_channels{iC};
                volt_field = [ch '_volt_f'];
                eps_scan = struct();
                eps_scan.spectra.f = scan_results{iScan}.spectra.f;
                eps_scan.spectra.Ps_volt_f = scan_results{iScan}.spectra.(volt_field);
                eps_scan.epsi = scan.epsi;
                eps_scan.w = w_all(iScan);
                eps_scan.nu = nu;
                scan_results{iScan}.epsilon.(ch) = mod_scan_calc_epsilon(eps_scan, metadata, ch);

                for iF = 1:numel(epsilon_fields)
                    field = epsilon_fields{iF};
                    if strcmp(field, 'coherence_sum')
                        continue % nested under spectra, handled separately below
                    end
                    epsilon_all_by_field.(field).(ch)(iScan) = scan_results{iScan}.epsilon.(ch).(field);
                end
                coh_sum_field = [ch '_coh_a3_sum'];
                if isfield(scan_results{iScan}.epsilon.(ch).spectra, coh_sum_field)
                    epsilon_all_by_field.coherence_sum.(ch)(iScan) = ...
                        scan_results{iScan}.epsilon.(ch).spectra.(coh_sum_field);
                end
            end

            % epsilon fed to chi_mle: mean across available shear channels
            % of whichever epsilon_final_source selects, omitting NaN -
            % see this file's DESCRIPTION for why this is a per-scan
            % simplification, not the full profile-level selection.
            % epsilon_final_source_resolved was resolved once, above.
            switch epsilon_final_source_resolved
                case 'epsilon_mle'
                    epsi_vals = cellfun(@(ch) epsilon_all_by_field.epsilon_mle.(ch)(iScan), epsilon_channels);
                otherwise % 'epsilon_co'
                    epsi_vals = cellfun(@(ch) epsilon_all_by_field.epsilon_obs_coh_corr.(ch)(iScan), epsilon_channels);
            end
            epsilon_all(iScan) = mean(epsi_vals, 'omitnan');

            if ~isempty(chi_obs_channels) && isfinite(epsilon_all(iScan))
                for iC = 1:numel(chi_obs_channels)
                    ch = chi_obs_channels{iC};
                    scan_results{iScan}.chi.(ch).epsilon = epsilon_all(iScan);
                    scan_results{iScan}.chi.(ch).nu = nu;
                    scan_results{iScan}.chi.(ch) = mod_scan_calc_chi_mle( ...
                        scan_results{iScan}.chi.(ch), metadata, ch, noise_coefs);
                    chi_mle_all.(ch)(iScan) = scan_results{iScan}.chi.(ch).chi_mle;
                end
            end
        end
    end
end

L2data.dnum = dnum_all;
L2data.pressure = pressure_all;
L2data.w = w_all;
L2data.temperature = temperature_all;
L2data.salinity = SP_all;
L2data.SR = SR_all;
L2data.nu = nu_all;
L2data.ktemp = ktemp_all;
L2data.epsilon_final = epsilon_all; % per-scan value fed to chi_mle below - see DESCRIPTION
L2data.epsilon_final_source = epsilon_final_source_resolved; % which variant epsilon_final actually is - 'epsilon_mle', 'epsilon_co', or '' if epsilon was never computed at all
for iC = 1:numel(chi_obs_channels)
    ch = chi_obs_channels{iC};
    L2data.chi_obs.(ch) = chi_obs_all.(ch);
    L2data.chi_obs_kc.(ch) = chi_obs_kc_all.(ch);
    L2data.chi_mle.(ch) = chi_mle_all.(ch);
end
for iF = 1:numel(epsilon_fields)
    field = epsilon_fields{iF};
    for iC = 1:numel(epsilon_channels)
        ch = epsilon_channels{iC};
        L2data.(field).(ch) = epsilon_all_by_field.(field).(ch);
    end
end
L2data.spectra.f = scan_results{1}.spectra.f;

channels = setdiff(fieldnames(scan_results{1}.spectra), {'f', 'f_ctd'}, 'stable');
nfreq = numel(L2data.spectra.f);
for iC = 1:numel(channels)
    ch = channels{iC};
    Pmat = nan(nbscan, numel(scan_results{1}.spectra.(ch)));
    for iScan = 1:nbscan
        Pmat(iScan, :) = scan_results{iScan}.spectra.(ch);
    end
    L2data.spectra.(ch) = Pmat;
end
if isfield(scan_results{1}.spectra, 'f_ctd')
    L2data.spectra.f_ctd = scan_results{1}.spectra.f_ctd;
end

% Deconvolved temperature-gradient spectrum + noise-floor cutoff index,
% per fpo7 channel with chi_obs computed above - kept rather than
% discarded, so a caller can see exactly what mod_scan_calc_chi_obs.m
% integrated, not just the resulting scalar.
for iC = 1:numel(chi_obs_channels)
    ch = chi_obs_channels{iC};
    Tg_k_mat = nan(nbscan, nfreq);
    fc_index_vec = nan(nbscan, 1);
    for iScan = 1:nbscan
        if isfield(scan_results{iScan}, 'chi') && isfield(scan_results{iScan}.chi, ch)
            Tg_k_mat(iScan, :) = scan_results{iScan}.chi.(ch).spectra.Pt_Tg_k;
            fc_index_vec(iScan) = scan_results{iScan}.chi.(ch).spectra.fc_index;
        end
    end
    L2data.spectra.([ch '_Tg_k']) = Tg_k_mat;
    L2data.spectra.([ch '_fc_index']) = fc_index_vec;
end

% k = f/abs(w) depends on scan (via w), not on which fpo7 channel computed
% it - one shared matrix, pulled from whichever chi_obs_channel happened
% to run (every chi_obs_channel gets the same k for a given scan, since
% they all share the same w).
if ~isempty(chi_obs_channels)
    k_mat = nan(nbscan, nfreq);
    first_ch = chi_obs_channels{1};
    for iScan = 1:nbscan
        if isfield(scan_results{iScan}, 'chi') && isfield(scan_results{iScan}.chi, first_ch)
            k_mat(iScan, :) = scan_results{iScan}.chi.(first_ch).spectra.k;
        end
    end
    L2data.spectra.k = k_mat;
end

% Raw and coherence-cleaned shear wavenumber spectra, per shear channel
% with epsilon computed above - kept rather than discarded, same
% rationale as the fpo7 Tg_k block above. spectra.(ch)_shear_co_k stays
% NaN for a scan/channel with no usable coherence (see
% mod_scan_shear_accel_coherence.m).
for iC = 1:numel(epsilon_channels)
    ch = epsilon_channels{iC};
    shear_k_mat = nan(nbscan, nfreq);
    shear_co_k_mat = nan(nbscan, nfreq);
    for iScan = 1:nbscan
        if isfield(scan_results{iScan}, 'epsilon') && isfield(scan_results{iScan}.epsilon, ch)
            shear_k_mat(iScan, :) = scan_results{iScan}.epsilon.(ch).spectra.Ps_shear_k;
            if isfield(scan_results{iScan}.epsilon.(ch).spectra, 'Ps_shear_co_k')
                shear_co_k_mat(iScan, :) = scan_results{iScan}.epsilon.(ch).spectra.Ps_shear_co_k;
            end
        end
    end
    L2data.spectra.([ch '_shear_k']) = shear_k_mat;
    L2data.spectra.([ch '_shear_co_k']) = shear_co_k_mat;
end

end %end function

%% Slice every numeric-vector field of epsi to samples idx0:idx1
function epsi_chunk = slice_epsi(epsi, idx0, idx1)
epsi_chunk = struct();
fn = fieldnames(epsi);
for iF = 1:numel(fn)
    field = fn{iF};
    v = epsi.(field);
    if isnumeric(v) && isvector(v) && numel(v) >= idx1
        epsi_chunk.(field) = v(idx0:idx1);
    end
end
end

%% Slice every numeric-vector field of ctd to samples whose dnum falls in
% [t0, t1] - a time-based selection, not an index range, since ctd's
% native sample rate/timing doesn't line up with epsi's (see
% mod_scan_get_spectra.m's NOTES for why this isn't interpolated instead).
function ctd_chunk = slice_ctd_by_time(ctd, t0, t1)
ctd_chunk = struct();
if isempty(ctd) || ~isfield(ctd, 'dnum') || isempty(ctd.dnum)
    return
end
mask = ctd.dnum >= t0 & ctd.dnum <= t1;
fn = fieldnames(ctd);
for iF = 1:numel(fn)
    field = fn{iF};
    v = ctd.(field);
    if isnumeric(v) && isvector(v) && numel(v) == numel(ctd.dnum)
        ctd_chunk.(field) = v(mask);
    end
end
end

%% Fraction of the epsi record's sample count that falls in a segment_id
% run other than the largest one - a cheap proxy for "how much of this
% call's raw coverage was on the losing side of an internal gap." 0 for an
% empty/absent segment_id (realtime mode, no gap detected, or no epsi data
% at all).
function frac = gap_fraction(epsi)
frac = 0;
if isempty(epsi) || ~isfield(epsi, 'segment_id') || isempty(epsi.segment_id)
    return
end
seg = epsi.segment_id;
n = numel(seg);
if n == 0
    return
end
counts = accumarray(seg, 1);
frac = 1 - max(counts) / n;
end

%% Empty-scan-count output shape, so callers get consistent fields even
% when there are no kept scans.
function L2data = empty_L2data(tiled_scans)
L2data.dnum = [];
L2data.pressure = [];
L2data.w = [];
L2data.temperature = [];
L2data.salinity = [];
L2data.SR = [];
L2data.nu = [];
L2data.ktemp = [];
L2data.epsilon_final = [];
L2data.epsilon_final_source = '';
L2data.spectra = struct('f', []);
L2data.chi_obs = struct();
L2data.chi_obs_kc = struct();
L2data.chi_mle = struct();
L2data.epsilon_obs = struct();
L2data.epsilon_obs_kc = struct();
L2data.epsilon_obs_coh_corr = struct();
L2data.epsilon_obs_coh_corr_kc = struct();
L2data.epsilon_mle = struct();
L2data.fom = struct();
L2data.fom_mle = struct();
L2data.coherence_sum = struct();
L2data.fft_length = tiled_scans.fft_length;
L2data.fft_segments_per_scan = tiled_scans.fft_segments_per_scan;
L2data.dof = tiled_scans.dof;
L2data.Fs_epsi = tiled_scans.Fs_epsi;
L2data.N_epsi = tiled_scans.N_epsi;
L2data.scan_step = tiled_scans.scan_step;
end
