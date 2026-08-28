function metadata = MODprocess_L1_apply_fpo7_calibration(L1_dir, metadata, PressureTimeseries)
% MODprocess_L1_apply_fpo7_calibration        Part of MOD_fish_processing
%
% metadata = MODprocess_L1_apply_fpo7_calibration(L1_dir, metadata, PressureTimeseries)
%
% DESCRIPTION
%   Fits a linear volts -> degrees-C calibration for every FP07 channel
%   (metadata.AFE.(ch).type == 'fpo7') by regressing that channel's raw
%   epsi voltage against real CTD temperature, and stores the result as
%   metadata.AFE.(ch).volts_to_C = [slope, intercept].
%
%   This is deliberately NOT a lookup like shear's Sv (metadata.AFE.(ch).cal,
%   read from a per-SN file in MODsetup_read_yaml.m) - an FP07 bead's
%   volts-to-temperature sensitivity isn't a fixed, bench-measured probe
%   property. It drifts with the specific electronics it's plugged into
%   and has to be fit in-situ, per deployment, against a real temperature
%   reference (mirrors mod_epsi_linear_calibration_FP07.m in the old
%   MOD_fish_lib, ALB/2019, most recently ALB/2024's linear-fit version).
%
%   Only descending (PressureTimeseries.is_down) data is used for the fit.
%   Two independent reasons for this, not one: (1) it matches how the
%   calibration will actually be used downstream - mod_scan_calc_chi_obs.m
%   only computes chi on descending scans in the first place (shear/FPO7
%   are only trustworthy on the way down for vehicles like DeepSolo/Mako -
%   see PLAN.md Section 4), so fitting on the same subset the correction
%   will be applied to is the more representative choice; (2) ascending
%   data on a vehicle that free-falls/tows down and is winched or driven
%   back up can have very different flow-noise/vibration characteristics
%   around the thermistor, which would bias a fit that mixed both.
%
%   No error, no calibration is not exceptional - a deployment with no CTD
%   temperature at all (DeepSolo's fallrise record is pressure-only) simply
%   never gets metadata.AFE.(ch).volts_to_C set, and every downstream
%   consumer (mod_scan_calc_chi_obs.m) is expected to check for that
%   field before trying to use it, the same way shear's .cal is only present when
%   a probe SN resolved to a real calibration file.
%
% INPUTS
%   L1_dir - directory containing L1 .mat files, each with top-level
%            'epsi' and 'ctd' variables (as saved by
%            MODprocess_all_L0_to_L1.m). Files missing either one, or
%            missing ctd.T specifically (e.g. DeepSolo's P-only external
%            CTD), are skipped when building the fit data, not an error.
%   metadata - metadata struct (from MODsetup_read_yaml.m). Uses:
%              metadata.PROCESS.channels, metadata.AFE.(ch).type (to find
%              which channels are 'fpo7')
%   PressureTimeseries - struct with dnum, is_down (from
%              mod_L1_detect_profiling_direction.m via
%              meta/pressure_time_series.mat) - the whole-deployment record.
%              Required argument, not self-loaded - same pure-function,
%              caller-supplies-it precedent as
%              MODprocess_single_L1_to_L2.m's PressureTimeseries argument.
%
% OUTPUTS
%   metadata - same struct, with metadata.AFE.(ch).volts_to_C = [slope,
%              intercept] added for every fpo7 channel that had enough
%              usable descending data to fit (see MIN_FIT_POINTS below).
%              Channels that couldn't be fit are left without the field -
%              a warning is printed, not an error.
%
% CALLED BY
%   MODprocess_all_L0_to_L1.m (only when metadata.CTD.cal is non-empty -
%   i.e. a real onboard CTD with temperature, not DeepSolo's P-only
%   external CTD)
%
% CALLS
%   (none)
%
% NOTES
%   The fit itself (polyfit(volts, T, 1), degree 1) is unchanged from the
%   old mod_epsi_linear_calibration_FP07.m. What's new here is fitting
%   across every L1 file in the deployment (sorted by file start time,
%   same pattern as MODprocess_L1_make_pressure_timeseries.m) rather than
%   against one hand-picked "longest profile" - this repo doesn't have
%   discrete profile objects yet (PLAN.md Section 6.3), and using the
%   whole is_down-gated deployment record is at least as much data as the
%   old "find the longest profile" heuristic was trying to approximate.
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

% Below this many descending (volts, T) pairs, a linear fit is judged too
% noisy to trust - arbitrary but generous threshold (a single scan window
% has on the order of hundreds of epsi samples; this is comparing against
% the coarser ctd sample count instead, so a deployment needs at least a
% couple dozen ctd samples' worth of descending data before this bothers).
MIN_FIT_POINTS = 30;

fpo7_channels = {};
for iC = 1:numel(metadata.PROCESS.channels)
    ch = metadata.PROCESS.channels{iC};
    if isfield(metadata.AFE, ch) && strcmpi(metadata.AFE.(ch).type, 'fpo7')
        fpo7_channels{end+1} = ch; %#ok<AGROW>
    end
end

if isempty(fpo7_channels)
    return
end

[epsi_dnum, epsi_volts, ctd_dnum, ctd_T] = concat_L1_epsi_ctd(L1_dir, fpo7_channels);

if isempty(epsi_dnum) || isempty(ctd_dnum)
    warning('MODprocess_L1_apply_fpo7_calibration:noData', ...
        ['No L1 file in %s had both epsi and ctd.T data - fpo7 calibration ' ...
        'not fit for any channel.'], L1_dir);
    return
end

% Same despike treatment mod_epsi_linear_calibration_FP07.m applied to
% CTD temperature before fitting - a movmean-based outlier filter, since
% CTD T is comparatively slow-varying and low-noise next to epsi volts.
T = filloutliers(ctd_T, 'linear', 'movmean', 100);

% Interpolate is_down (defined on PressureTimeseries.dnum, the
% concatenated pressure record - see MODprocess_L1_make_pressure_timeseries.m)
% onto this channel's ctd.dnum grid. 'nearest', not linear - is_down is a
% classification, not a continuous quantity. No 'extrap': a ctd sample
% outside PressureTimeseries' time range has no direction information at
% all, so interp1 returning NaN (and the > 0 comparison treating that as
% "not down") is correct here, same reasoning as
% MODprocess_single_L1_to_L2.m's scan-center is_down lookup.
is_down_at_ctd = interp1(PressureTimeseries.dnum, double(PressureTimeseries.is_down), ...
    ctd_dnum, 'nearest') > 0;

for iC = 1:numel(fpo7_channels)
    ch = fpo7_channels{iC};
    volt_field = [ch '_volt'];
    volts = epsi_volts.(volt_field);

    % Same despike treatment mod_epsi_linear_calibration_FP07.m applied to
    % the raw FP07 voltage - fillmissing then a movmedian outlier filter,
    % since epsi volts are much higher-rate and noisier than CTD T.
    volts = fillmissing(volts, 'linear');
    volts = filloutliers(volts, 'center', 'movmedian', 1000);

    valid_volts = ~isnan(volts);
    if nnz(valid_volts) < 2
        warning('MODprocess_L1_apply_fpo7_calibration:noValidVolts', ...
            'Channel %s has fewer than 2 valid epsi samples - skipping.', ch);
        continue
    end

    % Interpolate epsi volts (faster timebase) onto the ctd.dnum grid
    % (slower timebase) - matches mod_epsi_linear_calibration_FP07.m's
    % direction (it1_volt = interp1(epsi.dnum, epsi.t1_volt, ctd.dnum)),
    % not the other way around.
    interp_volts = interp1(epsi_dnum(valid_volts), volts(valid_volts), ctd_dnum);

    fit_mask = is_down_at_ctd & ~isnan(interp_volts) & ~isnan(T);
    if nnz(fit_mask) < MIN_FIT_POINTS
        warning('MODprocess_L1_apply_fpo7_calibration:notEnoughData', ...
            ['Channel %s has only %d descending (volts, T) pairs after ' ...
            'despiking (need >= %d) - volts_to_C not set for this channel.'], ...
            ch, nnz(fit_mask), MIN_FIT_POINTS);
        continue
    end

    Cal = polyfit(interp_volts(fit_mask), T(fit_mask), 1);
    metadata.AFE.(ch).volts_to_C = Cal; % [slope, intercept]
end

end %end function

%% Concatenate, across every L1 file in L1_dir sorted by file start time,
% the epsi voltage timeseries for the requested fpo7 channels plus the
% CTD dnum/T timeseries - both needed together (interpolated onto the
% same ctd.dnum grid) to fit each channel's volts_to_C. A file is only
% included if it has BOTH epsi data for every requested channel AND
% ctd.T - if either is missing, that file simply contributes nothing
% (not an error), same "missing data is not exceptional" spirit as
% MODprocess_L1_make_pressure_timeseries.m.
function [epsi_dnum, epsi_volts, ctd_dnum, ctd_T] = concat_L1_epsi_ctd(L1_dir, fpo7_channels)

files = dir(fullfile(L1_dir, '*.mat'));
nFiles = numel(files);
volt_fields = cellfun(@(ch) [ch '_volt'], fpo7_channels, 'UniformOutput', false);

sortKey = nan(nFiles, 1);
epsiData = cell(nFiles, 1);
ctdData = cell(nFiles, 1);
validFile = false(nFiles, 1);

for i = 1:nFiles
    fpath = fullfile(L1_dir, files(i).name);
    warnState = warning('off', 'MATLAB:load:variableNotFound');
    S = load(fpath, 'epsi', 'ctd');
    warning(warnState);

    has_epsi = isfield(S, 'epsi') && ~isempty(S.epsi) ...
        && isfield(S.epsi, 'dnum') && ~isempty(S.epsi.dnum) ...
        && all(cellfun(@(f) isfield(S.epsi, f), volt_fields));
    has_ctd = isfield(S, 'ctd') && ~isempty(S.ctd) ...
        && isfield(S.ctd, 'dnum') && ~isempty(S.ctd.dnum) ...
        && isfield(S.ctd, 'T') && ~isempty(S.ctd.T);

    if ~has_epsi || ~has_ctd
        continue
    end

    sortKey(i) = min(S.epsi.dnum);
    epsiData{i} = S.epsi;
    ctdData{i} = S.ctd;
    validFile(i) = true;
end

sortKey = sortKey(validFile);
epsiData = epsiData(validFile);
ctdData = ctdData(validFile);

if isempty(epsiData)
    epsi_dnum = [];
    epsi_volts = struct();
    ctd_dnum = [];
    ctd_T = [];
    return
end

[~, sortIdx] = sort(sortKey);
epsiData = epsiData(sortIdx);
ctdData = ctdData(sortIdx);

nValid = numel(epsiData);
epsi_dnum_all = cell(nValid, 1);
ctd_dnum_all = cell(nValid, 1);
ctd_T_all = cell(nValid, 1);
volt_all = struct();
for iCh = 1:numel(volt_fields)
    volt_all.(volt_fields{iCh}) = cell(nValid, 1);
end

for i = 1:nValid
    epsi_dnum_all{i} = epsiData{i}.dnum(:);
    ctd_dnum_all{i} = ctdData{i}.dnum(:);
    ctd_T_all{i} = ctdData{i}.T(:);
    for iCh = 1:numel(volt_fields)
        volt_all.(volt_fields{iCh}){i} = epsiData{i}.(volt_fields{iCh})(:);
    end
end

epsi_dnum = vertcat(epsi_dnum_all{:});
ctd_dnum = vertcat(ctd_dnum_all{:});
ctd_T = vertcat(ctd_T_all{:});

epsi_volts = struct();
for iCh = 1:numel(volt_fields)
    epsi_volts.(volt_fields{iCh}) = vertcat(volt_all.(volt_fields{iCh}){:});
end

end %end function
