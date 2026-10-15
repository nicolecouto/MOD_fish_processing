function [swaps, warnings_out] = MODprocess_find_spool_swaps(processed_root, spool_log_csv)
% MODprocess_find_spool_swaps        Part of MOD_fish_processing
%
% swaps = MODprocess_find_spool_swaps(processed_root)
% [swaps, warnings_out] = MODprocess_find_spool_swaps(processed_root, spool_log_csv)
%
% DESCRIPTION
%   Finds when the winch spool was changed over the cruise, for twist
%   counting: the cruise twist count restarts from 0 at each change. There
%   is one winch with one spool on it at a time, used by every vehicle, so
%   a change applies to every survey after it.
%
%   Two sources are checked against each other, so losing one doesn't lose
%   a change:
%     - every survey's meta/dev1_setup.yml (winch_spool, and the UTC time
%       Start New Deployment wrote it, from its first line): a survey whose
%       spool differs from the survey before it means a change between them.
%     - <processed_root>/spool_swap_log.csv: Start New Deployment adds a row
%       whenever the spool changes; a change made mid-deployment is added
%       by hand. Columns datetime_utc (yyyy-MM-ddTHH:mm:ssZ), spool_id,
%       spool_length_m, notes; '#' lines are comments.
%
%   Merging:
%     - A change seen in the dev1_setup.yml files is matched to a log row
%       with the same spool_id dated after the previous survey's
%       dev1_setup.yml and no later than 10 minutes after this survey's
%       (Start New Deployment writes both within seconds). Matched: source
%       'both', at the log's time. Not matched: source 'dev1_setup', at
%       the dev1_setup.yml time, with a warning that the log is missing it.
%     - A log row matching no dev1 change: source 'spool_swap_log' (a
%       mid-deployment change, or one whose dev1_setup.yml was deleted). A
%       warning is given if the next survey after it has a different spool.
%     - A log row for the spool already in use (e.g. the first spool of
%       the cruise) is kept as a change too; at the start of the cruise it
%       just starts the count at 0.
%   Spool names are compared ignoring case and surrounding spaces.
%
% INPUTS
%   processed_root - folder holding the survey folders (each with
%                    meta/dev1_setup.yml) and spool_swap_log.csv
%   spool_log_csv  - (optional) default <processed_root>/spool_swap_log.csv
%
% OUTPUTS
%   swaps        - struct array, in time order:
%                    .dnum      - when the count restarts [datenum, UTC]
%                    .time_utc  - same, as text
%                    .spool_id  - the spool put on
%                    .source    - 'both', 'dev1_setup' or 'spool_swap_log'
%                    .survey    - first survey on that spool ('' if none, e.g.
%                                 a mid-deployment change undone before the next survey)
%                    .notes     - notes from the log row ('' if none)
%   warnings_out - cellstr of disagreements between the two sources (also
%                  issued as warnings)
%   With no output argument, prints a table instead.
%
% CALLED BY
%   (the cruise twist count - not built yet; see
%   docs/workflow/realtime_processing.md stage 5)
%
% CALLS
%   ReadYaml (toolbox/YAMLMatlab_0.4.3)
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

if nargin < 2 || isempty(spool_log_csv)
    spool_log_csv = fullfile(processed_root, 'spool_swap_log.csv');
end
addpath(fullfile(fileparts(fileparts(mfilename('fullpath'))), 'toolbox', 'YAMLMatlab_0.4.3'));
MATCH_AFTER_DAYS = 10 / (24 * 60); % a log row up to 10 min after the survey's dev1_setup.yml still matches it
warnings_out = {};

surveys = read_dev1_setups(processed_root);
log_rows = read_spool_log(spool_log_csv);
warnings_out = [warnings_out, surveys.warnings, log_rows.warnings];
surveys = surveys.list;
log_rows = log_rows.list;
log_used = false(size(log_rows));

swaps = struct('dnum', {}, 'time_utc', {}, 'spool_id', {}, 'source', {}, 'survey', {}, 'notes', {});

%% Changes seen in the dev1_setup.yml files, matched to log rows
previous_spool = '';
previous_dnum = -Inf;
for iS = 1:numel(surveys)
    s = surveys(iS);
    if isempty(s.spool)
        continue
    end
    if ~same_spool(s.spool, previous_spool)
        in_window = find(~log_used & arrayfun(@(r) same_spool(r.spool_id, s.spool), log_rows) ...
            & [log_rows.dnum] > previous_dnum & [log_rows.dnum] <= s.dnum + MATCH_AFTER_DAYS, 1);
        if ~isempty(in_window)
            log_used(in_window) = true;
            r = log_rows(in_window);
            swaps(end+1) = make_swap(r.dnum, s.spool, 'both', s.survey, r.notes); %#ok<AGROW>
        else
            swaps(end+1) = make_swap(s.dnum, s.spool, 'dev1_setup', s.survey, ''); %#ok<AGROW>
            if isempty(previous_spool)
                what = sprintf('the first spool, %s', s.spool);
            else
                what = sprintf('the change from %s to %s', previous_spool, s.spool);
            end
            warnings_out{end+1} = sprintf(['%s has no row for %s (survey %s, %s UTC) - using the ' ...
                'dev1_setup.yml time.'], spool_log_csv, what, s.survey, datestr(s.dnum, 31)); %#ok<AGROW,DATST>
        end
    end
    previous_spool = s.spool;
    previous_dnum = s.dnum;
end

%% Log rows no dev1_setup.yml accounts for
for iR = find(~log_used)
    r = log_rows(iR);
    next_survey = '';
    next_idx = find([surveys.dnum] >= r.dnum & ~cellfun(@isempty, {surveys.spool}), 1);
    if ~isempty(next_idx)
        if same_spool(surveys(next_idx).spool, r.spool_id)
            next_survey = surveys(next_idx).survey;
        end
        % a later log row before that survey would explain a difference
        later_row = any([log_rows.dnum] > r.dnum & [log_rows.dnum] <= surveys(next_idx).dnum + MATCH_AFTER_DAYS);
        if ~same_spool(surveys(next_idx).spool, r.spool_id) && ~later_row
            warnings_out{end+1} = sprintf(['%s says spool %s from %s UTC, but the next survey, %s, ' ...
                'says spool %s.'], spool_log_csv, r.spool_id, datestr(r.dnum, 31), next_survey, ...
                surveys(next_idx).spool); %#ok<AGROW,DATST>
        end
    end
    swaps(end+1) = make_swap(r.dnum, r.spool_id, 'spool_swap_log', next_survey, r.notes); %#ok<AGROW>
end

if ~isempty(swaps)
    [~, order] = sort([swaps.dnum]);
    swaps = swaps(order);
end
for iW = 1:numel(warnings_out)
    warning('MODprocess_find_spool_swaps:mismatch', '%s', warnings_out{iW});
end
if nargout == 0
    print_swaps(swaps);
    clear swaps
end
end %end function

%% Every survey's dev1_setup.yml: survey, winch_spool, time written
function out = read_dev1_setups(processed_root)
out.list = struct('survey', {}, 'spool', {}, 'dnum', {}, 'file', {});
out.warnings = {};
files = dir(fullfile(processed_root, '*', 'meta', 'dev1_setup.yml'));
for iF = 1:numel(files)
    f = fullfile(files(iF).folder, files(iF).name);
    [~, survey] = fileparts(fileparts(files(iF).folder)); % <survey>/meta -> <survey>
    spool = '';
    try
        y = ReadYaml(f);
        if isfield(y, 'winch_spool')
            spool = strtrim(char(string(y.winch_spool)));
        end
        if isfield(y, 'survey_name')
            survey = char(string(y.survey_name));
        end
    catch ME
        out.warnings{end+1} = sprintf('Could not read %s (%s) - skipped.', f, ME.message);
        continue
    end
    first_line = strtrim(fgetl_safe(f));
    tok = regexp(first_line, '(\d{4}-\d\d-\d\d \d\d:\d\d) UTC', 'tokens', 'once');
    if ~isempty(tok)
        dnum = datenum(datetime(tok{1}, 'InputFormat', 'yyyy-MM-dd HH:mm'));
    else
        dnum = files(iF).datenum; % local file time - only a fallback
        out.warnings{end+1} = sprintf(['%s has no "written ... UTC" first line - using the file''s ' ...
            'modification time.'], f);
    end
    out.list(end+1) = struct('survey', survey, 'spool', spool, 'dnum', dnum, 'file', f);
end
if ~isempty(out.list)
    [~, order] = sort([out.list.dnum]);
    out.list = out.list(order);
end
end

%% spool_swap_log.csv rows (comment lines skipped; unparseable rows reported)
function out = read_spool_log(file)
out.list = struct('dnum', {}, 'spool_id', {}, 'notes', {});
out.warnings = {};
if ~isfile(file)
    return
end
lines = cellstr(readlines(file));
lines = lines(~startsWith(strtrim(lines), '#') & strlength(strtrim(lines)) > 0);
if isempty(lines)
    return
end
header = strtrim(split(lines{1}, ','))';
i_time = find(strcmp(header, 'datetime_utc'), 1);
i_spool = find(strcmp(header, 'spool_id'), 1);
i_notes = find(strcmp(header, 'notes'), 1);
if isempty(i_time) || isempty(i_spool)
    out.warnings{end+1} = sprintf('%s has no datetime_utc/spool_id header - not used.', file);
    return
end
for iL = 2:numel(lines)
    cols = strtrim(split_csv_line(lines{iL}));
    if numel(cols) < max(i_time, i_spool)
        out.warnings{end+1} = sprintf('%s line "%s": too few columns - skipped.', file, lines{iL});
        continue
    end
    dt = parse_utc(cols{i_time});
    if isnat(dt)
        out.warnings{end+1} = sprintf('%s: can''t read the time "%s" - row skipped.', file, cols{i_time});
        continue
    end
    notes = '';
    if ~isempty(i_notes) && numel(cols) >= i_notes
        notes = strjoin(cols(i_notes:end), ',');
    end
    out.list(end+1) = struct('dnum', datenum(dt), 'spool_id', cols{i_spool}, 'notes', notes);
end
if ~isempty(out.list)
    [~, order] = sort([out.list.dnum]);
    out.list = out.list(order);
end
end

function dt = parse_utc(text)
dt = NaT;
for fmt = {'yyyy-MM-dd''T''HH:mm:ss''Z''', 'yyyy-MM-dd''T''HH:mm:ss', 'yyyy-MM-dd HH:mm:ss', 'yyyy-MM-dd HH:mm'}
    try
        dt = datetime(text, 'InputFormat', fmt{1});
        return
    catch
    end
end
end

%% Split one CSV line, honouring double quotes
function cols = split_csv_line(line)
cols = regexp(char(line), '(?:^|,)("(?:[^"]|"")*"|[^,]*)', 'tokens');
cols = cellfun(@(c) regexprep(regexprep(c{1}, '^"|"$', ''), '""', '"'), cols, 'UniformOutput', false);
end

function tf = same_spool(a, b)
tf = strcmpi(strtrim(char(string(a))), strtrim(char(string(b))));
end

function s = make_swap(dnum, spool, source, survey, notes)
s = struct('dnum', dnum, 'time_utc', char(datetime(dnum, 'ConvertFrom', 'datenum', 'Format', 'yyyy-MM-dd HH:mm:ss')), ...
    'spool_id', spool, 'source', source, 'survey', survey, 'notes', notes);
end

function line = fgetl_safe(file)
fid = fopen(file, 'r');
line = fgetl(fid);
fclose(fid);
if ~ischar(line)
    line = '';
end
end

function print_swaps(swaps)
if isempty(swaps)
    fprintf('No winch spool changes found.\n');
    return
end
fprintf('%-19s  %-14s  %-14s  %s\n', 'UTC', 'spool', 'source', 'first survey on it');
for s = swaps
    fprintf('%-19s  %-14s  %-14s  %s\n', s.time_utc, s.spool_id, s.source, s.survey);
end
end
