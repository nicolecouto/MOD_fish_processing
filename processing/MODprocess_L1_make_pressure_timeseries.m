function PressureTimeseries = MODprocess_L1_make_pressure_timeseries(L1_dir)
% MODprocess_L1_make_pressure_timeseries        Part of MOD_fish_processing
%
% PressureTimeseries = MODprocess_L1_make_pressure_timeseries(L1_dir)
%
% DESCRIPTION
%   Concatenates ctd.dnum/ctd.P out of every L1 .mat file in L1_dir, sorted
%   by file start time, into one deployment-length pressure record. This is
%   the deployment-level pressure timeseries PLAN.md Section 6.3 sketched as
%   modProcess_make_pressure_timeseries.m - built now because
%   mod_L1_detect_profiling_direction.m needs a continuous,
%   whole-deployment record (a single L1 file's pressure data is too short
%   and too sparse, for vehicles like DeepSolo, to smooth/classify direction
%   on its own without edge artifacts at every file boundary).
%
%   Pure - reads files, does no calibration or file writing itself. The
%   caller (MODprocess_all_L0_to_L1.m) saves the result to
%   meta/pressure_time_series.mat.
%
% INPUTS
%   L1_dir - directory containing L1 .mat files, each with a top-level
%            'ctd' variable (as saved by MODprocess_all_L0_to_L1.m's
%            save(L1_file, '-struct', 'data')). Files with no ctd data
%            (ctd empty, or ctd.P missing/empty) are skipped, not an error -
%            e.g. a deployment with no CTD hardware at all, or a single file
%            where CTD logging happened to drop out.
%
% OUTPUTS
%   PressureTimeseries - struct with fields:
%       dnum - concatenated, sorted time vector [datenum]
%       P    - concatenated pressure [dbar]
%     Empty (dnum = [], P = []) if no L1 file has usable ctd.P data.
%
% CALLED BY
%   MODprocess_all_L0_to_L1.m
%
% CALLS
%   (none)
%
% NOTES
%   Unlike MODprocess_L1_accumulate_twist_timeseries.m's count_gyro/
%   count_compass, pressure needs no cross-file offset - each file's ctd.P
%   is already an absolute physical value, so concatenating and sorting is
%   enough.
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

files = dir(fullfile(L1_dir, '*.mat'));
nFiles = numel(files);

sortKey = nan(nFiles, 1);
ctdData = cell(nFiles, 1);
validFile = false(nFiles, 1);

for i = 1:nFiles
    fpath = fullfile(L1_dir, files(i).name);
    warnState = warning('off', 'MATLAB:load:variableNotFound');
    S = load(fpath, 'ctd');
    warning(warnState);

    if ~isfield(S, 'ctd') || isempty(S.ctd) || ...
            ~isfield(S.ctd, 'P') || isempty(S.ctd.P) || ...
            ~isfield(S.ctd, 'dnum') || isempty(S.ctd.dnum)
        continue
    end

    sortKey(i) = min(S.ctd.dnum);
    ctdData{i} = S.ctd;
    validFile(i) = true;
end

sortKey = sortKey(validFile);
ctdData = ctdData(validFile);

if isempty(ctdData)
    PressureTimeseries = struct('dnum', [], 'P', []);
    return
end

[~, sortIdx] = sort(sortKey);
ctdData = ctdData(sortIdx);

dnum_all = cell(numel(ctdData), 1);
P_all    = cell(numel(ctdData), 1);
for i = 1:numel(ctdData)
    dnum_all{i} = ctdData{i}.dnum(:);
    P_all{i}    = ctdData{i}.P(:);
end

PressureTimeseries.dnum = vertcat(dnum_all{:});
PressureTimeseries.P    = vertcat(P_all{:});

end %end function
