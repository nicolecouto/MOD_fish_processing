function PressureTimeseries = MODprocess_L1_make_pressure_timeseries(cache)
% MODprocess_L1_make_pressure_timeseries        Part of MOD_fish_processing
%
% PressureTimeseries = MODprocess_L1_make_pressure_timeseries(cache)
%
% DESCRIPTION
%   Concatenates every L1 file's ctd.dnum/ctd.P (kept in the per-file L1
%   cache, MODprocess_L1_update_file_cache.m), sorted by file start time,
%   into one deployment-length pressure record. This is
%   the deployment-level pressure timeseries PLAN.md Section 6.3 sketched as
%   modProcess_make_pressure_timeseries.m - built now because
%   mod_L1_detect_profiling_direction.m needs a continuous,
%   whole-deployment record (a single L1 file's pressure data is too short
%   and too sparse, for vehicles like DeepSolo, to smooth/classify direction
%   on its own without edge artifacts at every file boundary).
%
%   Pure - no file reading, calibration or file writing. The caller
%   (MODprocess_all_L0_to_L1.m) saves the result to
%   meta/pressure_time_series.mat.
%
% INPUTS
%   cache - from MODprocess_L1_update_file_cache.m (one element per L1
%           file, with .ctd_dnum/.ctd_P). Files with no ctd data (empty
%           .ctd_P) are skipped, not an error - e.g. a deployment with no
%           CTD hardware at all, or a single file where CTD logging happened
%           to drop out.
%
% OUTPUTS
%   PressureTimeseries - struct with fields:
%       dnum - concatenated time vector [datenum], sorted, each time once
%              (a time that two L1 files both hold keeps the sample from
%              the file that starts first; samples with no time are left
%              out, with a printed count)
%       P    - concatenated pressure [dbar]
%     Empty (dnum = [], P = []) if no L1 file has usable ctd.P data.
%
% CALLED BY
%   MODprocess_all_L0_to_L1.m
%
% CALLS
%   (none - the cache comes from MODprocess_L1_update_file_cache.m)
%
% NOTES
%   Unlike MODprocess_L1_accumulate_twist_timeseries.m's count_gyro/
%   count_compass, pressure needs no cross-file offset - each file's ctd.P
%   is already an absolute physical value, so concatenating and sorting is
%   enough.
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

valid = ~cellfun(@isempty, {cache.ctd_P});
if ~any(valid)
    PressureTimeseries = struct('dnum', [], 'P', []);
    return
end
cache = cache(valid);
[~, sortIdx] = sort(cellfun(@min, {cache.ctd_dnum}));
cache = cache(sortIdx);
dnum = vertcat(cache.ctd_dnum);
P    = vertcat(cache.ctd_P);
% Every sample in time order, each time once: two L1 files can cover the
% same time (a raw file copied under another name, or a damaged file
% holding a copy of another's start), and everything downstream
% interpolates on dnum, which needs it sorted and unique
[dnum, first] = unique(dnum, 'first'); % sorted; NaN times kept once each, dropped below
P = P(first);
keep = ~isnan(dnum);
n_dropped = numel(vertcat(cache.ctd_dnum)) - nnz(keep);
if n_dropped > 0
    fprintf('MODprocess_L1_make_pressure_timeseries: %d sample(s) left out - a time already in another L1 file, or no time.\n', ...
        n_dropped);
end
PressureTimeseries.dnum = dnum(keep);
PressureTimeseries.P    = P(keep);

end %end function
