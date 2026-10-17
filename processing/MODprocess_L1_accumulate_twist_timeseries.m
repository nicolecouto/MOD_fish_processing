function TwistTimeseries = MODprocess_L1_accumulate_twist_timeseries(cache, meta_dir)
% MODprocess_L1_accumulate_twist_timeseries        Part of MOD_fish_processing
%
% TwistTimeseries = MODprocess_L1_accumulate_twist_timeseries(cache, meta_dir)
%
% DESCRIPTION
%   Chains every L1 file's twist field (added by mod_L1_add_twist.m)
%   into one continuous, non-resetting rotation count for the whole
%   deployment. Each L1 file's count_gyro/count_compass restarts from 0
%   (it comes from a per-file cumsum) - this function offsets each file's
%   counts by the running cumulative total from all prior files, sorted by
%   file start time. The count starts from 0 at the survey start and is
%   never reset here: spool changes apply to the whole cruise, so they are
%   applied in the cruise twist count (MODprocess_cruise_twist.m), which
%   joins every survey's file.
%
% INPUTS
%   cache    - from MODprocess_L1_update_file_cache.m: each L1 file's twist
%              field and first vnav.dnum (so no L1 file is loaded here)
%   meta_dir - directory to save twist_time_series.mat into (the meta/ of
%              the processing run that made the L1, metadata.paths.L1_meta)
%
% OUTPUTS
%   TwistTimeseries - struct with fields:
%       time_s            - concatenated time vector [s]
%       dnum              - concatenated time vector [datenum]
%       pressure          - concatenated CTD pressure [dbar]
%       count_gyro        - continuous cumulative rotation [full rotations], gyro method
%       count_compass     - continuous cumulative rotation [radians], compass method
%
% CALLED BY
%   MODprocess_all_L0_to_L1.m
%
% CALLS
%   MODutil_save_atomic.m (the cache comes from MODprocess_L1_update_file_cache.m)
%
% NOTES
%   Also saves twist_time_series.mat into meta_dir. The twist field in each
%   L1 file is self-contained (count starts from ~0 for each file), so
%   reprocessing one file never corrupts the accumulated timeseries - this
%   function just re-chains whatever's currently in the cache (i.e. in L1/).
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

% Not every L1 file has twist data - a raw file can legitimately contain
% zero VNAV blocks (comms dropout, logging started mid-file, ...), in which
% case MODprocess_single_L0_to_L1 never calls mod_L1_add_twist and 'twist'
% is absent from that file. That's expected, not a processing failure -
% such files have an empty .twist in the cache and are skipped.
has_twist = ~cellfun(@isempty, {cache.twist});
sortKey   = [cache(has_twist).twist_sort_key];
twistData = {cache(has_twist).twist};

if isempty(twistData)
    disp('Error! No twist data.')
    % empty struct to make sure there is a return value
    TwistTimeseries = struct('time_s', [], 'dnum', [], 'pressure', [], 'count_gyro', [], 'count_compass', []);
    return
end

% sorting the L1 .mat files by time
[~, sortIdx] = sort(sortKey); % because sortKey contains starting time for each file
twistData = twistData(sortIdx);

% concatenating
nValid = numel(twistData); % nValid = number of original L1 .mat files that have proper data to use
% initializing all these fields with one cell per valid L1 .mat file
time_s_all        = cell(nValid, 1);
dnum_all           = cell(nValid, 1);
pressure_all       = cell(nValid, 1);
count_gyro_all     = cell(nValid, 1);
count_compass_all  = cell(nValid, 1);

offset_gyro    = 0;
offset_compass = 0;

% running through each valid L1 .mat file
for i = 1:nValid
    t = twistData{i};

    this_gyro    = t.count_gyro(:)    + offset_gyro;
    this_compass = t.count_compass(:) + offset_compass;

    time_s_all{i}       = t.time_s(:);
    dnum_all{i}          = t.dnum(:);
    pressure_all{i}       = t.pressure(:);
    count_gyro_all{i}    = this_gyro;
    count_compass_all{i} = this_compass;

    % Update offsets using the already-offset running totals, so the
    % next file continues from here rather than resetting to 0.
    offset_gyro    = last_finite(this_gyro, offset_gyro);
    offset_compass = last_finite(this_compass, offset_compass);
end

TwistTimeseries.time_s        = vertcat(time_s_all{:});
TwistTimeseries.dnum          = vertcat(dnum_all{:});
TwistTimeseries.pressure      = vertcat(pressure_all{:});
TwistTimeseries.count_gyro    = vertcat(count_gyro_all{:});
TwistTimeseries.count_compass = vertcat(count_compass_all{:});


MODutil_save_atomic(fullfile(meta_dir, 'twist_time_series.mat'), struct('TwistTimeseries', TwistTimeseries));

end

%% last finite value (a NaN at the end of one file mustn't turn every later file NaN)
function v = last_finite(x, previous)
v = x(find(isfinite(x), 1, 'last'));
if isempty(v)
    v = previous;
end
end
