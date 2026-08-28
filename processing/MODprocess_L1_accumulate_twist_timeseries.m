function TwistTimeseries = MODprocess_L1_accumulate_twist_timeseries(L1_dir, meta_dir)
% MODprocess_L1_accumulate_twist_timeseries        Part of MOD_fish_processing
%
% TwistTimeseries = MODprocess_L1_accumulate_twist_timeseries(L1_dir, meta_dir)
%
% DESCRIPTION
%   Chains every L1 file's twist field (added by mod_L1_add_twist.m)
%   into one continuous, non-resetting rotation count for the whole
%   deployment. Each L1 file's count_gyro/count_compass restarts from 0
%   (it comes from a per-file cumsum) - this function offsets each file's
%   counts by the running cumulative total from all prior files, sorted by
%   file start time. Also applies spool-swap resets from
%   meta/spool_swap_log.csv (falling back to the legacy meta/SpoolSwapLog.csv
%   name if the new one isn't found - this file is operator-edited by hand
%   during a cruise, not pipeline-regenerated, so an in-progress deployment's
%   hand-created file must not be silently ignored after this rename).
%
% INPUTS
%   L1_dir   - directory containing L1 .mat files, each with top-level
%              'vnav' and 'twist' variables (as saved by
%              MODprocess_all_L0_to_L1.m's save(L1_file, '-struct', 'data'))
%   meta_dir - directory to read spool_swap_log.csv from and save
%              twist_time_series.mat into (deployment's meta/ folder)
%
% OUTPUTS
%   TwistTimeseries - struct with fields:
%       time_s            - concatenated time vector [s]
%       dnum              - concatenated time vector [datenum]
%       pressure          - concatenated CTD pressure [dbar]
%       count_gyro        - continuous cumulative rotation [full rotations], gyro method
%       count_compass     - continuous cumulative rotation [radians], compass method
%       spool_swap_dnum   - datenum of each spool swap event applied, if any
%
% CALLED BY
%   MODprocess_all_L0_to_L1.m
%
% CALLS
%   (none)
%
% NOTES
%   Also saves twist_time_series.mat into meta_dir. The twist field in each
%   L1 file is self-contained (count starts from ~0 for each file), so
%   reprocessing one file never corrupts the accumulated timeseries - this
%   function just re-chains whatever's currently in L1_dir.
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

% files = struct that contains all the mat files in L1_dir
files = dir(fullfile(L1_dir, '*.mat'));
nFiles = numel(files);

% checking that files loaded in
if nFiles == 0
    disp('Error: No Files');
    return
end

% initiating variables
sortKey = nan(nFiles, 1);
twistData = cell(nFiles,1);
validFile = false(nFiles,1);

% checking that each file contains the needed data. L1 .mat files are
% saved with save(L1_file, '-struct', 'data') (MODprocess_all_L0_to_L1.m),
% so vnav/twist are top-level variables in the file, not nested under a
% 'data' struct.
%
% Not every L1 file necessarily has vnav data - a raw file can legitimately
% contain zero VNAV blocks (comms dropout, logging started mid-file, ...),
% in which case L0 parsing sets vnav = [] and MODprocess_single_L0_to_L1
% never calls mod_L1_add_twist, so 'twist' is simply absent from
% that file. That's expected, not a processing failure - skip the file and
% move on, rather than treat it as an error.
for i = 1:nFiles
    fpath = fullfile(L1_dir,files(i).name);
    % S = current data file. 'twist'/'vnav' may legitimately not exist in
    % this file (see above) - suppress load's "variable not found"
    % warning for that expected case rather than let it print for every
    % vnav-less file.
    warnState = warning('off', 'MATLAB:load:variableNotFound');
    S = load(fpath, 'vnav', 'twist');
    warning(warnState);

    if ~isfield(S, 'vnav') || isempty(S.vnav) ...
        || ~isfield(S.vnav, 'dnum') || isempty(S.vnav.dnum) || ...
         ~isfield(S, 'twist') || isempty(S.twist)
        fprintf('MODprocess_L1_accumulate_twist_timeseries: skipping %s - no vnav/twist data in this file.\n', files(i).name);
        continue
    end

    sortKey(i) = min(S.vnav.dnum);
    twistData{i} = S.twist;
    validFile(i) = true;
end

% Drop any files that were skipped
sortKey   = sortKey(validFile);
twistData = twistData(validFile);

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
    offset_gyro    = this_gyro(end);
    offset_compass = this_compass(end);
end

TwistTimeseries.time_s        = vertcat(time_s_all{:});
TwistTimeseries.dnum          = vertcat(dnum_all{:});
TwistTimeseries.pressure      = vertcat(pressure_all{:});
TwistTimeseries.count_gyro    = vertcat(count_gyro_all{:});
TwistTimeseries.count_compass = vertcat(count_compass_all{:});


% checking for spoolswap. spool_swap_log.csv is operator-edited by hand
% during a cruise, not pipeline-regenerated, so an in-progress deployment
% may still only have the legacy SpoolSwapLog.csv name on disk - fall back
% to it (with a warning) rather than silently ignore a real, hand-created
% file just because this rename landed mid-cruise.
spoolLogPath = fullfile(meta_dir, 'spool_swap_log.csv');
if ~isfile(spoolLogPath)
    legacy_spoolLogPath = fullfile(meta_dir, 'SpoolSwapLog.csv');
    if isfile(legacy_spoolLogPath)
        warning('MODprocess_L1_accumulate_twist_timeseries:legacySpoolSwapLogName', ...
            ['%s not found - falling back to the legacy name %s. Rename it to ' ...
             'spool_swap_log.csv to clear this warning.'], spoolLogPath, legacy_spoolLogPath);
        spoolLogPath = legacy_spoolLogPath;
    end
end
swap_dnum = [];

if isfile(spoolLogPath)
    try
        opts = detectImportOptions(spoolLogPath, 'CommentStyle', '#', 'Delimiter', ',');
        opts.VariableNamesLine = 2;
        opts.DataLines = 3;
        T = readtable(spoolLogPath, opts);

    catch ME
        warning('Could not parse %s (%s). Proceeding without spool swap resets.', ...
        spoolLogPath, ME.message);
        T = table();
    end

    if ~isempty(T) && ismember('datetime_utc', T.Properties.VariableNames)
        raw = T.datetime_utc;

        if isdatetime(raw)
            dt = raw;
        else
            try
                dt = datetime(raw, 'InputFormat', 'yyyy-MM-dd''T''HH:mm:ss''Z''', 'TimeZone', 'UTC');
            catch
                dt = datetime(raw, 'TimeZone', 'UTC');
            end
        end
        dt = dt(~isnat(dt));      % drop any rows that failed to parse
        swap_dnum = sort(datenum(dt));
    elseif ~isempty(T)
        warning('%s has no datetime_utc column. Detected columns: %s', ...
        spoolLogPath, strjoin(T.Properties.VariableNames, ', '));
    end
end

for k = 1:numel(swap_dnum)
    idx = find(TwistTimeseries.dnum >= swap_dnum(k), 1, 'first');

    if isempty(idx)
      continue   % swap happened after the last sample - nothing to reset
    end

    reset_gyro    = TwistTimeseries.count_gyro(idx);
    reset_compass = TwistTimeseries.count_compass(idx);

    TwistTimeseries.count_gyro(idx:end)    = TwistTimeseries.count_gyro(idx:end)    - reset_gyro;
    TwistTimeseries.count_compass(idx:end) = TwistTimeseries.count_compass(idx:end) - reset_compass;
end


TwistTimeseries.spool_swap_dnum = swap_dnum;

save(fullfile(meta_dir, 'twist_time_series.mat'), 'TwistTimeseries');

end
