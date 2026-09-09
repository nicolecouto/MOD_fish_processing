function L2data = mod_L2_tile_scans(epsi, ctd, metadata, PressureTimeseries)
% mod_L2_tile_scans        Part of MOD_fish_processing
%
% L2data = mod_L2_tile_scans(epsi, ctd, metadata, PressureTimeseries)
%
% DESCRIPTION
%   Tiles one continuous epsi record into N_epsi-sample scans overlapping
%   by scan_overlap (scan_step = (1-scan_overlap)*N_epsi) - N_epsi
%   (scan_length) is derived from fft_length/fft_segments_per_scan
%   (processing/scans/mod_scan_length_from_segments.m), not itself a yaml-
%   configurable field. Computes spectra
%   (mod_scan_get_spectra.m) and chi_obs (mod_scan_calc_chi_obs.m, when a
%   real onboard CTD/volts_to_C is available) per kept scan, and assembles
%   scan-dimension output arrays.
%
%   This is the shared windowing/spectra core factored out of
%   MODprocess_single_L1_to_L2.m (PLAN.md Section 6.3) so both the
%   per-L1-file "realtime" path and the new per-profile path
%   (MODprocess_single_L1_to_L2_profile.m) call one tiling implementation,
%   rather than duplicating this logic - each mode still computes its own
%   spectra independently end to end (no cross-mode data reuse/dedup, a
%   deliberate simplicity-over-storage-optimization choice), only the
%   *code* is shared. MODprocess_single_L1_to_L2.m is now a thin wrapper:
%   load data, call mod_L2_tile_scans(data.epsi, data.ctd, metadata,
%   PressureTimeseries).
%
%   Two ways this generalizes the original inline logic:
%     - Direction gating (PressureTimeseries) is OPTIONAL (4th arg).
%       Realtime mode passes it - a scan's center time is nearest-matched
%       against PressureTimeseries.is_down exactly as before. Profile-cut
%       mode omits it entirely - a profile from modProcess_detect_profiles.m
%       is already direction-pure by construction (it only ever returns
%       single-direction casts), so no per-scan gating is needed.
%     - Gap-boundary safety: if epsi.segment_id is present (set only by
%       modProcess_extract_profile.m - never by the realtime per-file
%       path), any candidate scan window whose samples span more than one
%       segment_id is skipped - the profile-cut generalization of "a
%       trailing partial window that doesn't reach a full N_epsi samples
%       is dropped, not padded" (see NOTES). Absent epsi.segment_id, this
%       check is a no-op, so realtime-mode behavior is unchanged.
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
%   chi_mle (mod_scan_calc_chi_mle.m) is now wired in too, using the
%   epsilon this same scan just computed - selected per
%   metadata.PROCESS.EPSILON.epsilon_final_source as the mean, omitting
%   NaN, of whichever epsilon variant across this deployment's shear
%   channels (see below). This per-scan mean is a deliberate
%   simplification, not the full profile-level ratio-based per-channel
%   selection MOD_fish_lib's legacy pipeline does (comparing s1 vs. s2
%   across a whole profile and picking whichever channel looks more
%   trustworthy) - that selection needs profile-level QC
%   (modProcess_L2_qc.m), not built yet. chi_mle is skipped for a scan
%   whose epsilon comes back NaN/non-finite (e.g. no shear channels
%   resolved, or every shear channel's own epsilon estimate failed).
%
% INPUTS
%   epsi     - data.epsi (from an L1 file) or profile_data.epsi (from
%              modProcess_extract_profile.m) - one continuous record.
%              Optional field: segment_id (Nx1 int, only ever set by
%              modProcess_extract_profile.m) - see DESCRIPTION.
%   ctd      - data.ctd or profile_data.ctd, same source as epsi
%   metadata - metadata struct (from MODsetup_read_yaml.m). Directly used
%              here: metadata.PROCESS.fft_length, .fft_segments_per_scan
%              (together derive N_epsi/scan_length and dof - see
%              DESCRIPTION/OUTPUTS), .scan_overlap, .Fs_epsi, .channels,
%              metadata.AFE.(channel).type, .volts_to_C (isfield-checked
%              to decide chi_obs_channels), metadata.paths.calibrations_root
%              (to load the FPO7 bench noise file). Passed straight
%              through, whole, to mod_scan_get_spectra.m and
%              mod_scan_calc_chi_obs.m - those functions (and
%              mod_scan_fpo7_volts_to_Tg_spectrum.m/mod_scan_fpo7_cutoff.m,
%              which they call in turn) read the specific
%              metadata.AFE.(channel).volts_to_C/.electronics_filter and
%              metadata.PROCESS.CHI.* fields they need - see their own
%              headers for the exact list.
%   PressureTimeseries - (optional) struct with dnum, is_down (from
%              mod_L1_detect_profiling_direction.m via
%              meta/pressure_time_series.mat) - the whole-deployment
%              record, not sliced to this epsi record. When provided,
%              each scan's center time is nearest-matched against it and
%              only descending scans are kept (realtime mode). When
%              omitted or empty, every candidate scan is direction-ungated
%              (profile-cut mode - see DESCRIPTION).
%
% OUTPUTS
%   L2data - struct with, for each kept scan:
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
%                   scans and channels, 1 x nfreq
%     spectra.(channel)_f    - power spectrum matrix, nbscan x nfreq, one
%                   field per shear/fpo7/acc channel (see
%                   mod_scan_get_spectra.m; key already includes the '_f'
%                   domain suffix, e.g. 't1_volt_f', 'a2_g_f')
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
%                   provenance. fft_segments_per_scan is the actual
%                   yaml-configurable input; N_epsi (scan_length) is
%                   derived from it and fft_length
%                   (processing/scans/mod_scan_length_from_segments.m), and dof
%                   from fft_segments_per_scan alone (processing/scans/mod_scan_dof.m)
%                   - see mod_scan_calc_chi_mle.m for the other consumer
%                   of that same dof derivation.
%   nbscan is 0 (all fields empty) if epsi has no data, is too short for
%   even one scan, or (realtime mode only) no scan lands on a descending
%   part of the record.
%
% CALLED BY
%   MODprocess_single_L1_to_L2.m, MODprocess_single_L1_to_L2_profile.m
%
% CALLS
%   mod_scan_get_spectra.m, toolbox/seawater/ktemp.m,
%   toolbox/seawater/visc.m, mod_scan_calc_chi_obs.m (only for fpo7
%   channels with a resolved volts_to_C calibration), mod_scan_calc_chi_mle.m
%   (only for scans with a finite epsilon estimate),
%   mod_scan_calc_epsilon.m (only for shear channels with a resolved
%   Sv calibration), processing/scans/mod_scan_dof.m,
%   processing/scans/mod_scan_length_from_segments.m
%
% NOTES
%   File-boundary/segment-boundary coverage gaps (a partial window at the
%   end of the record - or, when epsi.segment_id is present, at any
%   internal gap - that doesn't reach a full N_epsi samples) is dropped,
%   not padded from beyond the boundary. In realtime mode this is an
%   accepted, documented limitation (see MODprocess_single_L1_to_L2.m); in
%   profile-cut mode it only ever triggers at a genuine timestamp gap
%   (modProcess_extract_profile.m's epsi_gap_factor threshold) - an
%   ordinary L1 file-rotation boundary with continuous sampling stitches
%   seamlessly and loses nothing.
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

yaml_file = '';
if isfield(metadata, 'paths') && isfield(metadata.paths, 'setup_yml')
    yaml_file = metadata.paths.setup_yml;
end
metadata = MODsetup_validate_metadata(metadata, yaml_file, ...
    {'fft_length', 'fft_segments_per_scan', 'scan_overlap', 'Fs_epsi'});

if nargin < 4
    PressureTimeseries = [];
end
have_direction_gate = ~isempty(PressureTimeseries);
have_segment_id = isfield(epsi, 'segment_id') && ~isempty(epsi.segment_id);

fft_length = metadata.PROCESS.fft_length;
fft_segments_per_scan = metadata.PROCESS.fft_segments_per_scan;
Fs_epsi = metadata.PROCESS.Fs_epsi;
N_epsi = mod_scan_length_from_segments(fft_length, fft_segments_per_scan);
scan_step = round((1 - metadata.PROCESS.scan_overlap) * N_epsi);
dof = mod_scan_dof(fft_segments_per_scan);

L2data = empty_L2data(fft_length, fft_segments_per_scan, dof, Fs_epsi, N_epsi, scan_step);

if isempty(epsi) || ~isfield(epsi, 'dnum') || isempty(epsi.dnum)
    return
end

n_samples = numel(epsi.dnum);
if n_samples < N_epsi
    return % too short for even one scan
end

scan_starts = 1:scan_step:(n_samples - N_epsi + 1);
nbscan_candidate = numel(scan_starts);

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
            warning('mod_L2_tile_scans:noBenchNoiseFile', ...
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

dnum_all = nan(nbscan_candidate, 1);
pressure_all = nan(nbscan_candidate, 1);
w_all = nan(nbscan_candidate, 1);
temperature_all = nan(nbscan_candidate, 1);
SP_all = nan(nbscan_candidate, 1);
SR_all = nan(nbscan_candidate, 1);
nu_all = nan(nbscan_candidate, 1);
ktemp_all = nan(nbscan_candidate, 1);
epsilon_all = nan(nbscan_candidate, 1); % per-scan value actually fed to chi_mle - see below
chi_obs_all = struct();
chi_obs_kc_all = struct();
for iC = 1:numel(chi_obs_channels)
    chi_obs_all.(chi_obs_channels{iC}) = nan(nbscan_candidate, 1);
    chi_obs_kc_all.(chi_obs_channels{iC}) = nan(nbscan_candidate, 1);
end
chi_mle_all = struct();
for iC = 1:numel(chi_obs_channels)
    chi_mle_all.(chi_obs_channels{iC}) = nan(nbscan_candidate, 1);
end
epsilon_fields = {'epsilon_obs', 'epsilon_obs_kc', 'epsilon_obs_coh_corr', 'epsilon_obs_coh_corr_kc', ...
    'epsilon_mle', 'fom', 'fom_mle', 'coherence_sum'};
epsilon_all_by_field = struct();
for iF = 1:numel(epsilon_fields)
    epsilon_all_by_field.(epsilon_fields{iF}) = struct();
    for iC = 1:numel(epsilon_channels)
        epsilon_all_by_field.(epsilon_fields{iF}).(epsilon_channels{iC}) = nan(nbscan_candidate, 1);
    end
end
scan_results = cell(nbscan_candidate, 1);
keep = false(nbscan_candidate, 1);

for iScan = 1:nbscan_candidate
    idx0 = scan_starts(iScan);
    idx1 = idx0 + N_epsi - 1;

    if have_segment_id
        seg_window = epsi.segment_id(idx0:idx1);
        if any(seg_window ~= seg_window(1))
            continue % this window straddles a real gap - see GAP HANDLING
        end
    end

    center_idx = idx0 + floor(N_epsi / 2) - 1;
    center_dnum = epsi.dnum(center_idx);

    if have_direction_gate
        % Deliberately no 'extrap': a scan center time outside
        % [min(PressureTimeseries.dnum), max(PressureTimeseries.dnum)] has
        % no real pressure information at all (e.g. epsi logging that
        % started hours before DeepSolo's pressure record begins) -
        % interp1 returns NaN for it here, which the > 0 comparison below
        % correctly treats as "not down" rather than nearest-matching it
        % to a potentially far-distant, meaningless sample.
        is_down = interp1(PressureTimeseries.dnum, double(PressureTimeseries.is_down), ...
            center_dnum, 'nearest') > 0;
        if ~is_down
            continue
        end
    end

    scan = struct();
    scan.epsi = slice_epsi(epsi, idx0, idx1);
    scan_results{iScan} = mod_scan_get_spectra(scan, metadata);

    dnum_all(iScan) = center_dnum;
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
    keep(iScan) = true;
end

if ~any(keep)
    return
end

scan_results = scan_results(keep);
L2data.dnum = dnum_all(keep);
L2data.pressure = pressure_all(keep);
L2data.w = w_all(keep);
L2data.temperature = temperature_all(keep);
L2data.salinity = SP_all(keep);
L2data.SR = SR_all(keep);
L2data.nu = nu_all(keep);
L2data.ktemp = ktemp_all(keep);
L2data.epsilon_final = epsilon_all(keep); % per-scan value fed to chi_mle below - see DESCRIPTION
L2data.epsilon_final_source = epsilon_final_source_resolved; % which variant epsilon_final actually is - 'epsilon_mle', 'epsilon_co', or '' if epsilon was never computed at all
for iC = 1:numel(chi_obs_channels)
    ch = chi_obs_channels{iC};
    L2data.chi_obs.(ch) = chi_obs_all.(ch)(keep);
    L2data.chi_obs_kc.(ch) = chi_obs_kc_all.(ch)(keep);
    L2data.chi_mle.(ch) = chi_mle_all.(ch)(keep);
end
for iF = 1:numel(epsilon_fields)
    field = epsilon_fields{iF};
    for iC = 1:numel(epsilon_channels)
        ch = epsilon_channels{iC};
        L2data.(field).(ch) = epsilon_all_by_field.(field).(ch)(keep);
    end
end
L2data.spectra.f = scan_results{1}.spectra.f;

channels = setdiff(fieldnames(scan_results{1}.spectra), {'f'}, 'stable');
nbscan = numel(scan_results);
nfreq = numel(L2data.spectra.f);
for iC = 1:numel(channels)
    ch = channels{iC};
    Pmat = nan(nbscan, nfreq);
    for iScan = 1:nbscan
        Pmat(iScan, :) = scan_results{iScan}.spectra.(ch);
    end
    L2data.spectra.(ch) = Pmat;
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

%% Slice every field of epsi to samples idx0:idx1
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

%% Empty-scan-count output shape, so callers get consistent fields even
% when there are no kept scans.
function L2data = empty_L2data(fft_length, fft_segments_per_scan, dof, Fs_epsi, N_epsi, scan_step)
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
L2data.fft_length = fft_length;
L2data.fft_segments_per_scan = fft_segments_per_scan;
L2data.dof = dof;
L2data.Fs_epsi = Fs_epsi;
L2data.N_epsi = N_epsi;
L2data.scan_step = scan_step;
end
