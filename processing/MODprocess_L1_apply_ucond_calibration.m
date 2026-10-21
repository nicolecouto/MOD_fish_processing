function metadata = MODprocess_L1_apply_ucond_calibration(L1_dir, metadata, PressureTimeseries)
% MODprocess_L1_apply_ucond_calibration        Part of MOD_fish_processing
%
% metadata = MODprocess_L1_apply_ucond_calibration(L1_dir, metadata, PressureTimeseries)
%
% DESCRIPTION
%   Fits the gain [S/m per V] of every microconductivity channel
%   (metadata.AFE.(ch).type == 'microcond') by matching its low-frequency
%   spectral level to the CTD conductivity's, and stores it as
%   metadata.AFE.(ch).volts_to_S_per_m. Like the FP07 volts_to_C
%   (MODprocess_L1_apply_fpo7_calibration.m), it's fit in situ for each
%   deployment, not looked up.
%
%   Windows of ucond.gain_fit_window_s are placed in each stretch where
%   the fish moves the whole time (abs(dPdt) above
%   profile_detection.speedLim_scan_m_s) one way that
%   profile_detection.profile_dir trusts, as many as fit, centered in the
%   stretch. A window with a gap in either record (ctd_gap_factor /
%   epsi_gap_factor times the median sample interval), or with the
%   microconductivity railed (a sample at ucond.rail_fraction of the
%   channel's full_range or beyond), isn't used.
%   In each window:
%     gain = sqrt(mean P_C / mean(P_c1 / H2)), from 0 to ucond.gain_fit_fmax_hz
%   where P_C is the CTD conductivity spectrum, P_c1 the c1_volt spectrum
%   and H2 the channel's electronics response
%   (mod_scan_ucond_electronics_filter.m: the pre-emphasis, mostly, at
%   these frequencies). Windows above ucond.gain_fit_max are left out and
%   the rest averaged.
%
%   Legacy picked one window per profile (the middle) and used 10 s
%   Welch segments; here every usable window counts, and each gets one
%   Hann-windowed periodogram, so there's no segment length to choose.
%
%   No fit is not an error: a channel without enough usable data is left
%   without volts_to_S_per_m (a warning says so), and L2 skips its chi.
%
% INPUTS
%   L1_dir             - folder of L1 .mat files (top-level epsi and ctd)
%   metadata           - from MODsetup_read_yaml.m. Uses PROCESS.channels,
%                        PROCESS.f_sample_epsi, AFE.(ch).type/.ADCfilter/.full_range,
%                        PROCESS.UCOND, PROFILES.profile_dir/
%                        .speedLim_scan_m_s/.ctd_gap_factor,
%                        PROCESS.epsi_gap_factor
%   PressureTimeseries - dnum, dPdt_smoothed, is_down
%                        (meta/pressure_time_series.mat)
%
% OUTPUTS
%   metadata - with metadata.AFE.(ch).volts_to_S_per_m for each
%              microcond channel that could be fit
%
% CALLED BY
%   MODprocess_all_L0_to_L1.m
%
% CALLS
%   MODsetup_validate_metadata.m, mod_scan_ucond_electronics_filter.m
%
% PROVENANCE
%   MOD_fish_lib FastCTD_MATLAB/Dehysteresis_and_microconductivity/
%   microconductivity/FCTD_ucon_cal.m (Bethan Wynne-Cattanach, 2020): the
%   gain = sqrt(P_C / P_ucon) idea, the rejection above 100 and the mean.
%   Its dT/dC fit isn't ported (MHA's v3 computes dT/dC from T instead,
%   as mod_scan_calc_chi_ucond.m does).
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

ucond_channels = {};
for iC = 1:numel(metadata.PROCESS.channels)
    ch = metadata.PROCESS.channels{iC};
    if isfield(metadata.AFE, ch) && strcmpi(metadata.AFE.(ch).type, 'microcond')
        ucond_channels{end+1} = ch; %#ok<AGROW>
    end
end
if isempty(ucond_channels)
    return
end

yaml_file = '';
if isfield(metadata, 'paths') && isfield(metadata.paths, 'setup_yml')
    yaml_file = metadata.paths.setup_yml;
end
metadata = MODsetup_validate_metadata(metadata, yaml_file, ...
    {'ucond_gain_fit_window_s', 'ucond_gain_fit_fmax_hz', 'ucond_gain_fit_max', 'ucond_rail_fraction', ...
     'ucond_preemphasis_R22_ohm', 'ucond_preemphasis_R24_ohm', 'ucond_preemphasis_R25_ohm', ...
     'ucond_preemphasis_C19_F', 'ucond_antialias_sinc_power', 'f_sample_epsi', ...
     'profile_dir', 'speedLim_scan_m_s', 'ctd_gap_factor', 'epsi_gap_factor'});
U = metadata.PROCESS.UCOND;
f_sample_epsi = metadata.PROCESS.f_sample_epsi;

[epsi, ctd] = concat_L1(L1_dir, cellfun(@(ch) [ch '_volt'], ucond_channels, 'UniformOutput', false));
if isempty(epsi.dnum) || isempty(ctd.dnum)
    warning('MODprocess_L1_apply_ucond_calibration:noData', ...
        'No L1 file in %s had both epsi and ctd.C data - microconductivity gain not fit.', L1_dir);
    return
end

[rc, re] = usable_windows(ctd.dnum, epsi.dnum, PressureTimeseries, metadata);

for iC = 1:numel(ucond_channels)
    ch = ucond_channels{iC};
    gain = nan(size(rc, 1), 1);
    for iW = 1:size(rc, 1)
        C = ctd.C(rc(iW, 1):rc(iW, 2));
        V = epsi.([ch '_volt'])(re(iW, 1):re(iW, 2));
        if any(isnan(C)) || any(isnan(V)) || any(abs(V) >= U.rail_fraction * metadata.AFE.(ch).full_range)
            continue
        end
        f_sample_ctd = 1 / (86400 * median(diff(ctd.dnum(rc(iW, 1):rc(iW, 2)))));
        [P_C, f_C] = periodogram(detrend(C), hann(numel(C)), numel(C), f_sample_ctd);
        [P_V, f_V] = periodogram(detrend(V), hann(numel(V)), numel(V), f_sample_epsi);
        H2 = mod_scan_ucond_electronics_filter(f_V, U, f_sample_epsi, adc_filter(metadata.AFE.(ch)));
        band_C = f_C > 0 & f_C <= U.gain_fit_fmax_hz;
        band_V = f_V > 0 & f_V <= U.gain_fit_fmax_hz;
        gain(iW) = sqrt(mean(P_C(band_C)) / mean(P_V(band_V) ./ H2(band_V)));
    end
    used = isfinite(gain) & gain <= U.gain_fit_max;
    if ~any(used)
        warning('MODprocess_L1_apply_ucond_calibration:noFit', ...
            ['%s: no usable %g s window (%d tried) - volts_to_S_per_m not set, ' ...
             'so no chi_ucond for this channel yet.'], ch, U.gain_fit_window_s, size(rc, 1));
        continue
    end
    metadata.AFE.(ch).volts_to_S_per_m = mean(gain(used));
    fprintf('%s: microconductivity gain %.4g S/m per V (mean of %d windows, std %.2g; %d left out above %g)\n', ...
        ch, mean(gain(used)), nnz(used), std(gain(used)), nnz(gain > U.gain_fit_max), U.gain_fit_max);
end

end %end function

%% Index ranges [first, last] into the ctd (rc) and epsi (re) records of
% each usable window - see DESCRIPTION. The CTD record is split into runs
% where the fish moves steadily one trusted way with no CTD gap; each run
% holds as many whole windows as fit, centered in it (legacy took the
% middle of each profile). Both records are sorted, so a window's samples
% are one contiguous run of indices.
function [rc, re] = usable_windows(ctd_dnum, epsi_dnum, PT, metadata)
P = metadata.PROFILES;
win_d = metadata.PROCESS.UCOND.gain_fit_window_s / 86400;

speed = interp1(PT.dnum, abs(PT.dPdt_smoothed), ctd_dnum, 'nearest');
is_down = interp1(PT.dnum, double(PT.is_down), ctd_dnum, 'nearest') > 0;
switch lower(P.profile_dir)
    case 'down'
        trusted = is_down;
    case 'up'
        trusted = ~is_down;
    otherwise % 'both'
        trusted = true(size(is_down));
end
ok = speed > P.speedLim_scan_m_s & trusted;

% A run ends where ok goes false, the direction changes or the CTD has a gap
ctd_gap = P.ctd_gap_factor * median(diff(ctd_dnum));
breaks = [true; ~ok(2:end) | ~ok(1:end-1) | is_down(2:end) ~= is_down(1:end-1) ...
    | diff(ctd_dnum) > ctd_gap];
run_id = cumsum(breaks);
run_id(~ok) = 0;

starts = zeros(0, 1);
for r = unique(run_id(run_id > 0))'
    t = ctd_dnum(run_id == r);
    n = floor((t(end) - t(1)) / win_d);
    if n < 1
        continue
    end
    t0 = t(1) + ((t(end) - t(1)) - n*win_d) / 2;
    starts = [starts; t0 + (0:n-1)'*win_d]; %#ok<AGROW>
end
edges = [starts, starts + win_d];
rc = index_ranges(ctd_dnum, edges);
re = index_ranges(epsi_dnum, edges);

epsi_gap = metadata.PROCESS.epsi_gap_factor * median(diff(epsi_dnum));
keep = false(size(edges, 1), 1);
for iW = 1:size(edges, 1)
    ie = re(iW, 1):re(iW, 2);
    if numel(ie) < 2 || rc(iW, 2) - rc(iW, 1) < 1
        continue
    end
    keep(iW) = max(diff([edges(iW, 1); epsi_dnum(ie); edges(iW, 2)])) <= epsi_gap;
end
rc = rc(keep, :);
re = re(keep, :);
end

%% [first, last] index of sorted, unique t in each window [edges(i,1), edges(i,2)]
function r = index_ranges(t, edges)
i = (1:numel(t))';
r = [interp1(t, i, edges(:, 1), 'next'), interp1(t, i, edges(:, 2), 'previous')];
r(any(isnan(r), 2), :) = repmat([1 0], nnz(any(isnan(r), 2)), 1); % none: an empty range
end

%% The channel's ADC filter type ('sinc4' when the yml doesn't say, as MODsetup_define_filters.m)
function name = adc_filter(afe_channel)
name = 'sinc4';
if isfield(afe_channel, 'ADCfilter')
    name = afe_channel.ADCfilter;
end
end

%% epsi (dnum + the volt fields) and ctd (dnum, C) from every L1 file that
% has both, in time order
function [epsi, ctd] = concat_L1(L1_dir, volt_fields)
files = dir(fullfile(L1_dir, '*.mat'));
parts = {};
t0 = [];
for i = 1:numel(files)
    warnState = warning('off', 'MATLAB:load:variableNotFound');
    S = load(fullfile(L1_dir, files(i).name), 'epsi', 'ctd');
    warning(warnState);
    if ~isfield(S, 'epsi') || ~isfield(S, 'ctd') || isempty(S.epsi) || isempty(S.ctd) ...
            || ~isfield(S.epsi, 'dnum') || isempty(S.epsi.dnum) ...
            || ~all(isfield(S.epsi, volt_fields)) ...
            || ~isfield(S.ctd, 'C') || isempty(S.ctd.C)
        continue
    end
    parts{end+1} = S; %#ok<AGROW>
    t0(end+1) = min(S.epsi.dnum); %#ok<AGROW>
end
[~, order] = sort(t0);
parts = parts(order);

epsi.dnum = cell2mat(cellfun(@(S) S.epsi.dnum(:), parts(:), 'UniformOutput', false));
for iF = 1:numel(volt_fields)
    epsi.(volt_fields{iF}) = cell2mat(cellfun(@(S) S.epsi.(volt_fields{iF})(:), parts(:), 'UniformOutput', false));
end
ctd.dnum = cell2mat(cellfun(@(S) S.ctd.dnum(:), parts(:), 'UniformOutput', false));
ctd.C = cell2mat(cellfun(@(S) S.ctd.C(:), parts(:), 'UniformOutput', false));
% Overlapping L1 files repeat samples: keep each time once
[epsi.dnum, ie] = unique(epsi.dnum);
for iF = 1:numel(volt_fields)
    epsi.(volt_fields{iF}) = epsi.(volt_fields{iF})(ie);
end
[ctd.dnum, ic] = unique(ctd.dnum);
ctd.C = ctd.C(ic);
end
