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
%   MODprocess_L1_detect_profiling_direction.m for why and how that
%   classification is made. This is a pure transformation function: no
%   file I/O, and PressureTimeseries is a required argument rather than
%   self-loaded from meta/PressureTimeseries.mat, matching
%   MODprocess_single_L0_to_L1.m's external_ctd-as-argument precedent. To
%   process a single L1 file by hand:
%       PressureTimeseries = load(fullfile(metadata.paths.meta, 'PressureTimeseries.mat'));
%       data = load('L1/modsom_07.mat');
%       L2data = MODprocess_single_L1_to_L2(data, metadata, PressureTimeseries);
%
% INPUTS
%   data      - struct from an L1 .mat file (has epsi, ctd, ...)
%   metadata  - metadata struct (from MODsetup_read_yaml.m). Uses:
%               metadata.PROCESS.nfft, .dof, .Fs_epsi, .channels,
%               metadata.AFE.(channel).type (passed through to
%               MODprocess_L2_get_scan_spectra.m)
%   PressureTimeseries - struct with dnum, is_down (from
%               MODprocess_L1_detect_profiling_direction.m via
%               meta/PressureTimeseries.mat) - the whole-deployment record,
%               not sliced to this file. Each scan's center time is
%               nearest-matched against it.
%
% OUTPUTS
%   L2data - struct with, for each kept (descending) scan:
%     dnum        - scan center time [datenum], nbscan x 1
%     pressure    - CTD pressure at scan center [dbar], interpolated from
%                   this file's own data.ctd.P, nbscan x 1
%     f           - frequency vector [Hz], shared across all scans, 1 x nfreq
%     P.(channel) - power spectrum matrix, nbscan x nfreq, one field per
%                   shear/fpo7/acc channel (see MODprocess_L2_get_scan_spectra.m)
%     nfft, dof, Fs_epsi, N_epsi, scan_step - provenance
%   nbscan is 0 (all fields empty) if this file has no epsi data or no
%   scans land on a descending part of the record.
%
% CALLED BY
%   MODprocess_all_L1_to_L2.m
%
% CALLS
%   MODprocess_L2_get_scan_spectra.m
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
    && numel(data.ctd.dnum) > 1;

dnum_all = nan(nbscan_candidate, 1);
pressure_all = nan(nbscan_candidate, 1);
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

    epsi_chunk = slice_epsi(data.epsi, idx0, idx1);
    scan_results{iScan} = MODprocess_L2_get_scan_spectra(epsi_chunk, metadata);

    dnum_all(iScan) = center_dnum;
    if have_ctd
        pressure_all(iScan) = interp1(data.ctd.dnum, data.ctd.P, center_dnum, 'linear', 'extrap');
    end
    keep(iScan) = true;
end

if ~any(keep)
    return
end

scan_results = scan_results(keep);
L2data.dnum = dnum_all(keep);
L2data.pressure = pressure_all(keep);
L2data.f = scan_results{1}.f;

channels = fieldnames(scan_results{1}.P);
nbscan = numel(scan_results);
nfreq = numel(L2data.f);
for iC = 1:numel(channels)
    ch = channels{iC};
    Pmat = nan(nbscan, nfreq);
    for iScan = 1:nbscan
        Pmat(iScan, :) = scan_results{iScan}.P.(ch);
    end
    L2data.P.(ch) = Pmat;
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
L2data.f = [];
L2data.P = struct();
L2data.nfft = nfft;
L2data.dof = dof;
L2data.Fs_epsi = Fs_epsi;
L2data.N_epsi = N_epsi;
L2data.scan_step = scan_step;
end
