function TwistTimeseries = MODprocess_cruise_twist(processed_root)
% MODprocess_cruise_twist        Part of MOD_fish_processing
%
% TwistTimeseries = MODprocess_cruise_twist(processed_root)
%
% DESCRIPTION
%   The cruise twist count: one series over every survey on the winch
%   spool, in time order, at 1 s. There is one winch with one spool on it at a time,
%   used by every vehicle, so the count carries on from one survey to the
%   next and restarts from 0 only when the spool is changed
%   (MODprocess_find_spool_swaps.m - the one place spool changes come from).
%
%   Made from each survey's own twist_time_series.mat (realtime run,
%   <survey>/processed/realtime/meta/, 40 Hz, counting from 0 at the
%   survey start, no spool resets): each is averaged into 1 s bins, offset
%   so it starts where the survey before it ended, and the spool resets are
%   applied to the joined series. A survey file is only reread when it has
%   changed (1 s copies kept in <processed_root>/twist/twist_by_survey.mat),
%   and twist_time_series.mat is only rewritten when a survey file or a
%   spool change has changed, so the monitor reloads it only then.
%
%   Only surveys on the winch spool count (on_winch_spool in
%   dev1_setup.yml, Start New Deployment's ON THE WINCH SPOOL / LAB TEST
%   switch; a yml from before the switch counts when winch_spool is filled
%   in). A lab test still has its own twist_time_series.mat.
%
%   The realtime worker (MODprocess_deployment.m, given processed_root)
%   calls this after every pass. Run it by hand on a copied Processed/
%   folder to rebuild it.
%
% INPUTS
%   processed_root - folder holding the survey folders and spool_swap_log.csv
%
% OUTPUTS
%   TwistTimeseries - also saved as <processed_root>/twist/twist_time_series.mat;
%                     an empty struct if no survey has twist yet. Fields:
%       dnum              - 1 s bin centres [datenum, UTC], ntime x 1
%       count_gyro        - cable twist since the current spool went on [full rotations]
%       count_compass     - same from the compass, cross-check [radians]
%       pressure          - mean CTD pressure in the bin [dbar] (NaN with no CTD)
%       survey_index      - which entry of .surveys each sample is from, ntime x 1
%       surveys           - survey names, in time order (only surveys with twist)
%       survey_start_dnum - first sample of each of .surveys [datenum]
%       spool_swaps       - the spool changes (MODprocess_find_spool_swaps.m)
%       spool_swap_dnum   - their times [datenum]
%       spool             - the spool on now ('' if none is named)
%       bin_s             - 1
%       sources           - per survey: .survey, .file (relative to
%                           processed_root) and .file_time (its modification
%                           time, this computer's local time)
%       warnings          - cellstr: disagreements between the spool sources
%                           (this call's), and join_warnings
%       join_warnings     - cellstr: surveys overlapping in time
%       made_utc, code    - when, and MODutil_code_version.m
%
% CALLED BY
%   MODprocess_deployment.m (after every pass over processed_root); by hand
%
% CALLS
%   MODutil_list_surveys.m, MODprocess_find_spool_swaps.m,
%   MODutil_save_atomic.m, MODutil_code_version.m
%
% NOTES
%   Neutral is negative: setting the fin to neutral makes the count go down.
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

BIN_S = 1;
out_dir = fullfile(processed_root, 'twist');
out_file = fullfile(out_dir, 'twist_time_series.mat');
cache_file = fullfile(out_dir, 'twist_by_survey.mat');

surveys = MODutil_list_surveys(processed_root);
w = warning('off', 'MODprocess_find_spool_swaps:mismatch'); % returned in .warnings instead
restore = onCleanup(@() warning(w));
[swaps, warnings_out] = MODprocess_find_spool_swaps(processed_root);

% 1 s copy of each survey's twist, reread only when its file changed
cache = struct('file', {}, 'stamp', {}, 'bytes', {}, 'piece', {});
if isfile(cache_file)
    try
        cache = getfield(load(cache_file, 'cache'), 'cache');
    catch
        % unreadable - rebuild it
    end
end
pieces = struct('survey', {}, 'file', {}, 'file_time', {}, 'dnum', {}, 'count_gyro', {}, ...
    'count_compass', {}, 'pressure', {}, 'last_gyro', {}, 'last_compass', {});
new_cache = cache([]);
changed = false;
for iS = 1:numel(surveys)
    if ~surveys(iS).on_spool
        continue % a lab test: its own twist is kept, but not summed here
    end
    f = fullfile(surveys(iS).folder, 'processed', 'realtime', 'meta', 'twist_time_series.mat');
    if ~isfile(f)
        continue
    end
    d = dir(f);
    hit = find(strcmp({cache.file}, f) & [cache.stamp] == d.datenum & [cache.bytes] == d.bytes, 1);
    if ~isempty(hit)
        entry = cache(hit);
    else
        try
            t = getfield(load(f, 'TwistTimeseries'), 'TwistTimeseries');
            piece = bin_survey(t, BIN_S);
        catch
            % unreadable (a partial copy or sync): keep its last good copy,
            % if any, and try again next pass (the old stamp doesn't match)
            previous = find(strcmp({cache.file}, f), 1);
            if isempty(previous)
                continue
            end
            piece = cache(previous).piece;
            d.datenum = cache(previous).stamp;
            d.bytes = cache(previous).bytes;
        end
        if isempty(piece.dnum)
            continue % no time yet
        end
        changed = changed || isempty(find(strcmp({cache.file}, f) & [cache.stamp] == d.datenum, 1));
        entry = struct('file', f, 'stamp', d.datenum, 'bytes', d.bytes, 'piece', piece);
    end
    entry.piece.survey = surveys(iS).survey;
    entry.piece.file = f;
    entry.piece.file_time = char(datetime(d.datenum, 'ConvertFrom', 'datenum', 'Format', 'yyyy-MM-dd HH:mm:ss'));
    new_cache(end+1) = entry; %#ok<AGROW>
    pieces(end+1) = entry.piece; %#ok<AGROW>
end
changed = changed || ~isequal(sort({new_cache.file}), sort({cache.file})); % a survey added or gone

if isempty(pieces)
    % no survey on the spool has twist (any more): no cruise file, so the
    % monitor doesn't keep showing one made from surveys now left out
    TwistTimeseries = struct();
    for f = {out_file, cache_file}
        if isfile(f{1})
            delete(f{1});
        end
    end
    return
end

% nothing new: keep the saved series (unless the spool changes differ)
if ~changed && isfile(out_file)
    try
        old = getfield(load(out_file, 'TwistTimeseries'), 'TwistTimeseries');
        if isequal(old.spool_swap_dnum, [swaps.dnum]') && isequal(sort(old.surveys), sort({pieces.survey})) ...
                && isequal({old.spool_swaps.spool_id}, {swaps.spool_id})
            TwistTimeseries = old;
            TwistTimeseries.warnings = [warnings_out, old.join_warnings]; % this pass's spool warnings
            return
        end
    catch
        % unreadable - rebuild it
    end
end

% join the surveys in time order, each starting where the one before ended
[~, order] = sort(arrayfun(@(p) p.dnum(1), pieces));
pieces = pieces(order);
n = arrayfun(@(p) numel(p.dnum), pieces);
dnum = vertcat(pieces.dnum);
gyro = cell(numel(pieces), 1);
compass = cell(numel(pieces), 1);
offset_gyro = 0;
offset_compass = 0;
join_warnings = {};
for iP = 1:numel(pieces)
    gyro{iP} = pieces(iP).count_gyro + offset_gyro;
    compass{iP} = pieces(iP).count_compass + offset_compass;
    offset_gyro = offset_gyro + pieces(iP).last_gyro;
    offset_compass = offset_compass + pieces(iP).last_compass;
    if iP > 1 && pieces(iP).dnum(1) < pieces(iP-1).dnum(end)
        join_warnings{end+1} = sprintf('Twist of %s starts before %s ends (%s UTC) - surveys overlap in time.', ...
            pieces(iP).survey, pieces(iP-1).survey, datestr(pieces(iP).dnum(1), 31)); %#ok<AGROW,DATST>
    end
end
gyro = vertcat(gyro{:});
compass = vertcat(compass{:});

% restart from 0 at each spool change (at the first finite value after it)
for k = 1:numel(swaps)
    gyro = restart_at(gyro, dnum, swaps(k).dnum);
    compass = restart_at(compass, dnum, swaps(k).dnum);
end

TwistTimeseries = struct();
TwistTimeseries.dnum = dnum;
TwistTimeseries.count_gyro = gyro;
TwistTimeseries.count_compass = compass;
TwistTimeseries.pressure = vertcat(pieces.pressure);
TwistTimeseries.survey_index = repelem((1:numel(pieces))', n(:));
TwistTimeseries.surveys = {pieces.survey};
TwistTimeseries.survey_start_dnum = arrayfun(@(p) p.dnum(1), pieces);
TwistTimeseries.spool_swaps = swaps;
TwistTimeseries.spool_swap_dnum = [swaps.dnum]';
TwistTimeseries.spool = '';
spools = {surveys([surveys.on_spool]).spool};
if ~isempty(swaps)
    TwistTimeseries.spool = swaps(end).spool_id;
elseif any(~cellfun(@isempty, spools))
    TwistTimeseries.spool = spools{find(~cellfun(@isempty, spools), 1, 'last')};
end
TwistTimeseries.bin_s = BIN_S;
TwistTimeseries.sources = struct('survey', {pieces.survey}, ...
    'file', cellfun(@(f) relative_to(f, processed_root), {pieces.file}, 'UniformOutput', false), ...
    'file_time', {pieces.file_time});
TwistTimeseries.join_warnings = join_warnings;
TwistTimeseries.warnings = [warnings_out, join_warnings];
TwistTimeseries.made_utc = char(datetime('now', 'TimeZone', 'UTC', 'Format', 'yyyy-MM-dd HH:mm:ss'));
TwistTimeseries.code = MODutil_code_version();

if ~isfolder(out_dir)
    mkdir(out_dir);
end
MODutil_save_atomic(out_file, struct('TwistTimeseries', TwistTimeseries));
cache = new_cache;
MODutil_save_atomic(cache_file, struct('cache', cache));
end %end function

%% One survey's 40 Hz twist -> means over bin_s bins (NaNs left out)
function p = bin_survey(t, bin_s)
dnum = t.dnum(:);
ok = isfinite(dnum);
if ~any(ok)
    p.dnum = []; % nothing to bin
    return
end
k = floor(dnum(ok) * 86400 / bin_s);
[bins, ~, g] = unique(k);
p.survey = '';
p.file = '';
p.file_time = '';
p.dnum = (bins + 0.5) * bin_s / 86400;
p.count_gyro = bin_mean(g, t.count_gyro(ok));
p.count_compass = bin_mean(g, t.count_compass(ok));
pressure = nan(size(dnum));
if isfield(t, 'pressure') && numel(t.pressure) == numel(dnum)
    pressure = t.pressure(:);
end
p.pressure = bin_mean(g, pressure(ok));
% the survey's own last value, so the next survey carries on from it
p.last_gyro = last_finite(t.count_gyro);
p.last_compass = last_finite(t.count_compass);
end

function m = bin_mean(g, x)
x = x(:);
good = isfinite(x);
m = accumarray(g(good), x(good), [max(g) 1]) ./ accumarray(g(good), 1, [max(g) 1]);
end

function x = restart_at(x, dnum, t)
j = find(dnum >= t & isfinite(x), 1);
if ~isempty(j)
    first = find(dnum >= t, 1);
    x(first:end) = x(first:end) - x(j);
end
end

function v = last_finite(x)
v = x(find(isfinite(x), 1, 'last'));
if isempty(v)
    v = 0;
end
end

function r = relative_to(f, root)
r = f;
if startsWith(f, [root filesep])
    r = f(numel(root)+2:end);
end
end
