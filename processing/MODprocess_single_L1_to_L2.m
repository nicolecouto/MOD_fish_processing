function L2data = MODprocess_single_L1_to_L2(data, metadata, PressureTimeseries)
% MODprocess_single_L1_to_L2        Part of MOD_fish_processing
%
% L2data = MODprocess_single_L1_to_L2(data, metadata, PressureTimeseries)
%
% DESCRIPTION
%   Converts one L1 file's epsi timeseries into per-scan spectra (L2),
%   keeping the whole file's scans in one output struct rather than
%   splitting into per-profile files (PLAN.md Section 4 - this is the
%   deliberate divergence from the old mod_fish_lib profile-based L2
%   approach). Scans tile data.epsi within this file only ("realtime"
%   mode - see PLAN.md's Context section) with 50% overlap:
%   N_epsi = (dof-1)*nfft samples per scan, step = N_epsi/2.
%
%   Only scans classified as descending (PressureTimeseries.is_down at the
%   scan's center time) get spectra computed - see
%   mod_L1_detect_profiling_direction.m for why and how that
%   classification is made. This is a pure transformation function: no
%   file I/O, and PressureTimeseries is a required argument rather than
%   self-loaded from meta/PressureTimeseries.mat, matching
%   MODprocess_single_L0_to_L1.m's external_ctd-as-argument precedent. To
%   process a single L1 file by hand:
%       PressureTimeseries = load(fullfile(metadata.paths.meta, 'PressureTimeseries.mat'));
%       data = load('L1/modsom_07.mat');
%       L2data = MODprocess_single_L1_to_L2(data, metadata, PressureTimeseries);
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
%   for that channel. See docs/workflow/L2_calc_chi.md for the full chain
%   (mod_scan_fpo7_transfer_function.m, mod_scan_fpo7_cutoff.m,
%   mod_scan_thermal_diffusivity.m, mod_scan_calc_chi_obs.m).
%   mod_scan_calc_chi_obs.m's intermediate deconvolved spectrum/cutoff
%   index (spectra.k/spectra.(ch)_Tg_k/spectra.(ch)_fc_index) are kept, not
%   discarded, alongside the chi_obs/chi_obs_kc summary scalars - see
%   OUTPUTS.
%   chi_mle (mod_scan_calc_chi_mle.m) is not computed here - it needs
%   an epsilon estimate this pipeline doesn't produce yet.
%
% INPUTS
%   data      - struct from an L1 .mat file (has epsi, ctd, ...)
%   metadata  - metadata struct (from MODsetup_read_yaml.m). Directly used
%               here: metadata.PROCESS.nfft, .dof, .Fs_epsi, .channels,
%               metadata.AFE.(channel).type, .volts_to_C (isfield-checked
%               to decide chi_obs_channels), metadata.paths.calibrations_root
%               (to load the FPO7 bench noise file). Passed straight
%               through, whole, to mod_scan_get_spectra.m and
%               mod_scan_calc_chi_obs.m - those functions (and
%               mod_scan_fpo7_volts_to_Tg_spectrum.m/mod_scan_fpo7_cutoff.m,
%               which they call in turn) read the specific
%               metadata.AFE.(channel).volts_to_C/.electronics_filter and
%               metadata.PROCESS.CHI.* fields they need - see their own
%               headers for the exact list.
%   PressureTimeseries - struct with dnum, is_down (from
%               mod_L1_detect_profiling_direction.m via
%               meta/PressureTimeseries.mat) - the whole-deployment record,
%               not sliced to this file. Each scan's center time is
%               nearest-matched against it.
%
% OUTPUTS
%   L2data - struct with, for each kept (descending) scan:
%     dnum        - scan center time [datenum], nbscan x 1
%     pressure    - CTD pressure at scan center [dbar], interpolated from
%                   this file's own data.ctd.P, nbscan x 1
%     w           - fall speed at scan center [m/s], interpolated from
%                   this file's own data.ctd.dzdt the same way pressure is
%                   interpolated from data.ctd.P, nbscan x 1. This is the
%                   fall-speed-dependent input mod_scan_calc_chi_obs.m
%                   (via mod_scan_fpo7_transfer_function.m) needs -
%                   see PLAN.md's chi_processing branch notes. Not abs'd
%                   here (mod_scan_fpo7_transfer_function.m does that
%                   itself) so the sign stays available for sanity checks
%                   (positive on a real descending scan, matching is_down).
%     temperature - CTD temperature at scan center [degC], interpolated
%                   from data.ctd.T the same way pressure is, nbscan x 1.
%                   Only populated if this L1 file's own data.ctd has both
%                   T and S (real onboard CTD, e.g. Mako - never true for
%                   DeepSolo's P-only external CTD) - stays NaN otherwise.
%     salinity    - CTD salinity at scan center [psu], same conditions as
%                   temperature, nbscan x 1.
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
%                   metadata.AFE.(channel).volts_to_C
%                   (MODprocess_L1_apply_fpo7_calibration.m) AND this file
%                   has real ctd.T/.S (see temperature/salinity above) -
%                   this struct simply has no fields at all for a file
%                   whose CTD T/S happened to drop out even if
%                   volts_to_C is resolved deployment-wide. Individual
%                   scans within a present field can still be NaN
%                   (mod_scan_calc_chi_obs.m - no valid noise-floor
%                   cutoff range for that scan).
%     chi_obs_kc.(channel) - the noise-floor cutoff wavenumber [cpm] used
%                   for each chi_obs.(channel) value - diagnostic, see
%                   mod_scan_calc_chi_obs.m's OUTPUTS. Same values as
%                   spectra.k(:, spectra.(channel)_fc_index), just
%                   pre-indexed for convenience.
%     nfft, dof, Fs_epsi, N_epsi, scan_step - provenance
%   nbscan is 0 (all fields empty) if this file has no epsi data or no
%   scans land on a descending part of the record.
%
% CALLED BY
%   MODprocess_all_L1_to_L2.m
%
% CALLS
%   mod_scan_get_spectra.m, mod_scan_thermal_diffusivity.m,
%   mod_scan_calc_chi_obs.m (only for fpo7 channels with a resolved
%   volts_to_C calibration)
%
% NOTES
%   File-boundary coverage gaps (a partial window at the end of this file
%   that doesn't reach a full N_epsi samples is dropped, not padded from
%   the next file) are an accepted, documented limitation of this
%   per-file "realtime" mode - see PLAN.md's Context section for why, and
%   the "post-processing" mode this is deliberately not attempting yet.
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

nfft = metadata.PROCESS.nfft;
dof = metadata.PROCESS.dof;
Fs_epsi = metadata.PROCESS.Fs_epsi;
N_epsi = (dof - 1) * nfft;
scan_step = N_epsi / 2; % 50% overlap

L2data = empty_L2data(nfft, dof, Fs_epsi, N_epsi, scan_step);

if isempty(data.epsi) || ~isfield(data.epsi, 'dnum') || isempty(data.epsi.dnum)
    return
end

n_samples = numel(data.epsi.dnum);
if n_samples < N_epsi
    return % file too short for even one scan
end

scan_starts = 1:scan_step:(n_samples - N_epsi + 1);
nbscan_candidate = numel(scan_starts);

have_ctd = ~isempty(data.ctd) && isfield(data.ctd, 'dnum') && isfield(data.ctd, 'P') ...
    && isfield(data.ctd, 'dzdt') && numel(data.ctd.dnum) > 1;

% Real CTD temperature/salinity - only true for deployments with an
% onboard CTD (e.g. Mako), never for DeepSolo's P-only external CTD.
% Needed for both chi's thermal diffusivity (ktemp) and, upstream, ever
% having a metadata.AFE.(ch).volts_to_C in the first place
% (MODprocess_L1_apply_fpo7_calibration.m).
have_ctd_ts = have_ctd && isfield(data.ctd, 'T') && isfield(data.ctd, 'S') ...
    && ~isempty(data.ctd.T) && ~isempty(data.ctd.S);

% Which fpo7 channels can get chi_obs computed: only those with a resolved
% in-situ calibration, and only if this deployment has the CTD T/S/P chi's
% thermal diffusivity needs. The bench noise floor file is loaded once
% here (not per scan) - if it's missing, chi_obs is skipped for this file
% entirely rather than erroring per scan.
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
                'for this file.'], noise_file);
            chi_obs_channels = {};
        end
    end
end

dnum_all = nan(nbscan_candidate, 1);
pressure_all = nan(nbscan_candidate, 1);
w_all = nan(nbscan_candidate, 1);
temperature_all = nan(nbscan_candidate, 1);
salinity_all = nan(nbscan_candidate, 1);
chi_obs_all = struct();
chi_obs_kc_all = struct();
for iC = 1:numel(chi_obs_channels)
    chi_obs_all.(chi_obs_channels{iC}) = nan(nbscan_candidate, 1);
    chi_obs_kc_all.(chi_obs_channels{iC}) = nan(nbscan_candidate, 1);
end
scan_results = cell(nbscan_candidate, 1);
keep = false(nbscan_candidate, 1);

for iScan = 1:nbscan_candidate
    idx0 = scan_starts(iScan);
    idx1 = idx0 + N_epsi - 1;
    center_idx = idx0 + floor(N_epsi / 2) - 1;
    center_dnum = data.epsi.dnum(center_idx);

    % Deliberately no 'extrap': a scan center time outside
    % [min(PressureTimeseries.dnum), max(PressureTimeseries.dnum)] has no
    % real pressure information at all (e.g. epsi logging that started
    % hours before DeepSolo's pressure record begins) - interp1 returns
    % NaN for it here, which the > 0 comparison below correctly treats as
    % "not down" rather than nearest-matching it to a potentially
    % far-distant, meaningless sample.
    is_down = interp1(PressureTimeseries.dnum, double(PressureTimeseries.is_down), ...
        center_dnum, 'nearest') > 0;
    if ~is_down
        continue
    end

    scan = struct();
    scan.epsi = slice_epsi(data.epsi, idx0, idx1);
    scan_results{iScan} = mod_scan_get_spectra(scan, metadata);

    dnum_all(iScan) = center_dnum;
    if have_ctd
        pressure_all(iScan) = interp1(data.ctd.dnum, data.ctd.P, center_dnum, 'linear', 'extrap');
        w_all(iScan) = interp1(data.ctd.dnum, data.ctd.dzdt, center_dnum, 'linear', 'extrap');
    end
    if have_ctd_ts
        temperature_all(iScan) = interp1(data.ctd.dnum, data.ctd.T, center_dnum, 'linear', 'extrap');
        salinity_all(iScan) = interp1(data.ctd.dnum, data.ctd.S, center_dnum, 'linear', 'extrap');

        if ~isempty(chi_obs_channels)
            ktemp = mod_scan_thermal_diffusivity( ...
                salinity_all(iScan), temperature_all(iScan), pressure_all(iScan));
            for iC = 1:numel(chi_obs_channels)
                ch = chi_obs_channels{iC};
                volt_field = [ch '_volt_f'];
                chan_scan = struct();
                chan_scan.spectra.f = scan_results{iScan}.spectra.f;
                chan_scan.spectra.Pt_volt_f = scan_results{iScan}.spectra.(volt_field);
                chan_scan.w = w_all(iScan);
                chan_scan.ktemp = ktemp;
                scan_results{iScan}.chi.(ch) = mod_scan_calc_chi_obs(chan_scan, metadata, ch, noise_coefs);
                chi_obs_all.(ch)(iScan) = scan_results{iScan}.chi.(ch).chi_obs;
                chi_obs_kc_all.(ch)(iScan) = scan_results{iScan}.chi.(ch).chi_obs_kc;
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
L2data.salinity = salinity_all(keep);
for iC = 1:numel(chi_obs_channels)
    ch = chi_obs_channels{iC};
    L2data.chi_obs.(ch) = chi_obs_all.(ch)(keep);
    L2data.chi_obs_kc.(ch) = chi_obs_kc_all.(ch)(keep);
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

end %end function

%% Slice every field of data.epsi to samples idx0:idx1
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
% when this file contributes nothing.
function L2data = empty_L2data(nfft, dof, Fs_epsi, N_epsi, scan_step)
L2data.dnum = [];
L2data.pressure = [];
L2data.w = [];
L2data.temperature = [];
L2data.salinity = [];
L2data.spectra = struct('f', []);
L2data.chi_obs = struct();
L2data.chi_obs_kc = struct();
L2data.nfft = nfft;
L2data.dof = dof;
L2data.Fs_epsi = Fs_epsi;
L2data.N_epsi = N_epsi;
L2data.scan_step = scan_step;
end
