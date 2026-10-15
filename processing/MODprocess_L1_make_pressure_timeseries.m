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
%       dnum - concatenated, sorted time vector [datenum]
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
PressureTimeseries.dnum = vertcat(cache.ctd_dnum);
PressureTimeseries.P    = vertcat(cache.ctd_P);

end %end function
