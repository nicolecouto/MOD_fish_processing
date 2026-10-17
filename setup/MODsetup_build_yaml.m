function [run_yml, info] = MODsetup_build_yaml(survey_meta_dir, cruise_meta_data_yml, run, varargin)
% MODsetup_build_yaml        Part of MOD_fish_processing
%
% run_yml = MODsetup_build_yaml(survey_meta_dir)
% [run_yml, info] = MODsetup_build_yaml(survey_meta_dir, cruise_meta_data_yml, run, 'L1_from', other_run)
%
% DESCRIPTION
%   Builds a processing run's yml, <survey>/meta/meta_data_<run>.yml - the
%   file processing reads (MODsetup_read_yaml.m) - by combining two files:
%     - meta/dev1_setup.yml, written on DEV1 by Start New Deployment
%       (acquisition/start_new_deployment.py): what's on the vehicle.
%     - a cruise yml: processing parameters per sensor type (template:
%       setup/cruise_meta_data_template.yml). To try other settings, copy
%       it, change the copy, and build another run from that.
%   A run is one yml plus one output folder, <survey>/processed/<run>/; the
%   realtime worker's run is 'realtime'. See docs/workflow/processing_data.md.
%
%   The merge is done on the text, so both files' comments are kept:
%     1. dev1_setup.yml, unchanged.
%     2. Each section of the cruise yml that dev1_setup.yml doesn't have,
%        copied with its comments. For a section both have (afe:), only
%        the keys dev1_setup.yml lacks are added
%        (MODsetup_write_yaml_value.m). dev1_setup.yml wins on any key
%        both set.
%     3. dev1_setup.yml's top-level profiling_direction (what Start New
%        Deployment writes) is copied to profile_detection.profile_dir,
%        which is what processing reads.
%     4. A run: block - name, L1_from, cruise_yml, created_utc.
%
%   Every run is rebuilt this way on every call, so an edit to
%   dev1_setup.yml or to the run's cruise yml reaches it - edit those, not
%   the run yml. From the run yml there already:
%     - a registry parameter it had and the sources don't (a value saved
%       from a prompt) is carried over; one the sources set differently is
%       reported in info.changed - the sources win;
%     - its calibrations_root is kept when it's a folder on this computer
%       and dev1_setup.yml's isn't (e.g. a copy of the survey on a laptop,
%       after preflight asked for it). Otherwise a reachable one is taken
%       from another run yml of the same survey (realtime first), so it
%       only has to be asked for once per copy of a survey;
%     - for 'realtime', an old-layout meta/depl_meta_data.yml stands in the
%       first time.
%   The old file is kept as .replaced_<UTC stamp> when its content
%   changes; nothing is written when nothing would change, so this is safe
%   to call on every pass of the realtime worker.
%
% INPUTS
%   survey_meta_dir      - the survey's meta/ folder (holds dev1_setup.yml)
%   cruise_meta_data_yml - (optional) the cruise yml. [] = the one this run
%                          was built with (run.cruise_yml in its yml), or,
%                          for a new run, <processed_root>/cruise_meta_data.yml
%                          (two levels above survey_meta_dir). If it doesn't
%                          exist, the yml gets only dev1_setup.yml (+ step
%                          3), with a warning; MODsetup_preflight.m then
%                          lists what's missing.
%   run                  - (optional) run name, default 'realtime'. Letters,
%                          digits, _ and - only (it names the folder).
%   Name-value option:
%     'L1_from' - run whose L1 this run uses instead of making its own.
%                 [] (default) = as this run already had it (none for a new
%                 run); '' = its own L1. Not for 'realtime'.
%
% OUTPUTS
%   run_yml - full path to meta/meta_data_<run>.yml
%   info    - struct:
%               .run        - the run name
%               .created    - true if the yml didn't exist before
%               .written    - true if the yml was (re)written
%               .backup     - path of the .replaced_* copy, or ''
%               .added      - cellstr 'section.key' added from the cruise yml
%               .carried    - cellstr 'section.key' carried over from the old file
%               .changed    - cellstr 'section.key: old -> new'
%               .cruise_yml - the cruise yml used ('' if none was found)
%
% CALLED BY
%   MODprocess_deployment.m (each survey pass); templates/; by hand
%
% CALLS
%   MODsetup_write_yaml_value.m, MODsetup_format_yaml_value.m,
%   MODsetup_metadata_field_registry.m, ReadYaml (toolbox/YAMLMatlab_0.4.3)
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

if nargin < 3 || isempty(run)
    run = 'realtime';
end
ip = inputParser;
addParameter(ip, 'L1_from', []);
parse(ip, varargin{:});
L1_from = ip.Results.L1_from;
run = char(run);
check_name(run);
toolbox_dir = fullfile(fileparts(fileparts(mfilename('fullpath'))), 'toolbox', 'YAMLMatlab_0.4.3');
addpath(toolbox_dir);

dev1_yml = fullfile(survey_meta_dir, 'dev1_setup.yml');
run_yml = fullfile(survey_meta_dir, ['meta_data_' run '.yml']);
if ~isfile(dev1_yml)
    error('MODsetup_build_yaml:noDev1Setup', 'No dev1_setup.yml in %s - run Start New Deployment first.', survey_meta_dir);
end
info = struct('run', run, 'created', ~isfile(run_yml), 'written', false, 'backup', '', ...
    'added', {{}}, 'carried', {{}}, 'changed', {{}}, 'cruise_yml', '');

% The old file: this run's yml, or (realtime, the first time) the old layout's
old_yml = run_yml;
if strcmp(run, 'realtime') && ~isfile(old_yml)
    old_yml = fullfile(survey_meta_dir, 'depl_meta_data.yml');
end
old = struct();
if isfile(old_yml)
    old = read_source(old_yml);
end

% Which cruise yml, and which L1
default_cruise_yml = fullfile(fileparts(fileparts(survey_meta_dir)), 'cruise_meta_data.yml');
if nargin < 2 || isempty(cruise_meta_data_yml)
    cruise_meta_data_yml = default_cruise_yml;
    [has, recorded] = get_value(old, 'run', 'cruise_yml');
    if has && ~isempty(recorded)
        recorded = char(string(recorded));
        if isfile(recorded)
            cruise_meta_data_yml = recorded;
        elseif isfile(fullfile(fileparts(default_cruise_yml), file_name(recorded)))
            % a copy of the survey: the same file name next to the survey folder
            cruise_meta_data_yml = fullfile(fileparts(default_cruise_yml), file_name(recorded));
        end
    end
end
cruise_meta_data_yml = char(cruise_meta_data_yml);
if isnumeric(L1_from) % not given: keep the run's
    [~, L1_from] = get_value(old, 'run', 'L1_from');
end
if isempty(L1_from)
    L1_from = '';
end
L1_from = char(L1_from);
if ~isempty(L1_from)
    check_name(L1_from);
    if strcmp(run, 'realtime') || strcmp(L1_from, run)
        error('MODsetup_build_yaml:badL1From', ['L1_from ''%s'' isn''t allowed for run ''%s'' (realtime ' ...
            'makes its own L1, and a run can''t take its L1 from itself).'], L1_from, run);
    end
end

%% 1-3. dev1_setup.yml, then the cruise yml's processing parameters
tmp_yml = [run_yml '.building'];
% (rewritten from scratch each time; left behind if a build fails, to look at)
if isfile(cruise_meta_data_yml)
    sources = sprintf('dev1_setup.yml (below) and %s (after it)', cruise_meta_data_yml);
else
    sources = sprintf('dev1_setup.yml (below) only - no %s', cruise_meta_data_yml);
end
header = {sprintf('## meta_data_%s.yml - processing run "%s", made by MODsetup_build_yaml.m from %s.', run, run, sources)
    sprintf('## Output goes to ../processed/%s/. Every path comes from where this file is; data_root is the ship''s, kept as a record.', run)
    '## Rebuilt from those two files every time: edit them, not this file. Values saved here by a prompt are kept.'};
writelines([header; {''}; read_lines(dev1_yml)], tmp_yml);
dev1 = read_source(dev1_yml);
if isfile(cruise_meta_data_yml)
    info.cruise_yml = cruise_meta_data_yml;
    cruise = read_source(cruise_meta_data_yml);
    blocks = split_top_level_blocks(read_lines(cruise_meta_data_yml));
    for iB = 1:numel(blocks)
        sec = blocks(iB).key;
        if ~isfield(cruise, sec)
            continue
        end
        if ~isfield(dev1, sec)
            append_lines(tmp_yml, [{''}; blocks(iB).lines]);
            info.added = [info.added, strcat(sec, '.', keys_of(cruise.(sec)))];
        elseif isstruct(dev1.(sec)) && isstruct(cruise.(sec))
            for key = keys_of(cruise.(sec))
                val = cruise.(sec).(key{1});
                if ~isfield(dev1.(sec), key{1}) && is_scalar_value(val)
                    MODsetup_write_yaml_value(tmp_yml, sec, key{1}, val);
                    info.added{end+1} = [sec '.' key{1}];
                end
            end
        end
    end
else
    warning('MODsetup_build_yaml:noCruiseMetaData', ...
        'No %s - %s has only dev1_setup.yml; run MODsetup_preflight to see what''s missing.', ...
        cruise_meta_data_yml, run_yml);
end
if isfield(dev1, 'profiling_direction')
    MODsetup_write_yaml_value(tmp_yml, 'profile_detection', 'profile_dir', char(string(dev1.profiling_direction)));
end

%% Carry over from the old file
created_utc = char(datetime('now', 'TimeZone', 'UTC', 'Format', 'yyyy-MM-dd HH:mm:ss'));
merged = read_merged(tmp_yml, dev1_yml, cruise_meta_data_yml);
if ~isempty(fieldnames(old))
    for spec = MODsetup_metadata_field_registry()
        [has_old, old_val] = get_value(old, spec.yaml_section, spec.yaml_key);
        if ~has_old
            continue
        end
        [has_new, new_val] = get_value(merged, spec.yaml_section, spec.yaml_key);
        name = [spec.yaml_section '.' spec.yaml_key];
        if ~has_new
            MODsetup_write_yaml_value(tmp_yml, spec.yaml_section, spec.yaml_key, old_val);
            info.carried{end+1} = name;
        elseif ~isequal(old_val, new_val)
            info.changed{end+1} = sprintf('%s: %s -> %s', name, ...
                MODsetup_format_yaml_value(old_val), MODsetup_format_yaml_value(new_val));
        end
    end
    [has_created, old_created] = get_value(old, 'run', 'created_utc');
    if has_created
        created_utc = char(string(old_created)); % so an unchanged rebuild is byte-identical
    end
end
% calibrations_root that works on this computer wins over one that doesn't
[~, cal] = get_value(merged, '', 'calibrations_root');
if isempty(cal) || ~isfolder(char(string(cal))) % missing: preflight says so
    [has_old_cal, old_cal] = get_value(old, '', 'calibrations_root');
    if has_old_cal && isfolder(char(string(old_cal)))
        MODsetup_write_yaml_value(tmp_yml, '', 'calibrations_root', char(string(old_cal)));
        info.carried{end+1} = 'calibrations_root';
    else
        [other_cal, from_yml] = reachable_calibrations_root(survey_meta_dir, run_yml);
        if ~isempty(other_cal)
            MODsetup_write_yaml_value(tmp_yml, '', 'calibrations_root', other_cal);
            info.carried{end+1} = ['calibrations_root (from ' from_yml ')'];
        end
    end
end

%% 4. run: block
MODsetup_write_yaml_value(tmp_yml, 'run', 'created_utc', created_utc);
MODsetup_write_yaml_value(tmp_yml, 'run', 'cruise_yml', info.cruise_yml);
MODsetup_write_yaml_value(tmp_yml, 'run', 'L1_from', L1_from);
MODsetup_write_yaml_value(tmp_yml, 'run', 'name', run);

if ~isempty(info.changed)
    fprintf(['MODsetup_build_yaml: %s differed from its sources and now follows them:\n  %s\n' ...
        '  (edit dev1_setup.yml or the cruise yml to change these for good)\n'], ...
        run_yml, strjoin(info.changed, sprintf('\n  ')));
end

%% Check it reads, then replace the run yml only if it changed
read_merged(tmp_yml, dev1_yml, cruise_meta_data_yml);
new_text = fileread(tmp_yml);
if isfile(run_yml) && strcmp(fileread(run_yml), new_text)
    delete(tmp_yml);
    return
end
if isfile(run_yml)
    info.backup = unused_path([run_yml '.replaced_' char(datetime('now', 'TimeZone', 'UTC', 'Format', 'yyyyMMddHHmmss'))]);
    copyfile(run_yml, info.backup);
end
movefile(tmp_yml, run_yml, 'f');
info.written = true;
end %end function

function check_name(name)
if isempty(regexp(name, '^[A-Za-z0-9_-]+$', 'once'))
    error('MODsetup_build_yaml:badRunName', ['Run name "%s" can only have letters, digits, _ and - ' ...
        '(it becomes a folder in processed/).'], name);
end
end

function n = file_name(f)
[~, n, e] = fileparts(f);
n = [n e];
end

%% A calibrations_root that is a folder here, from another run yml of this
% survey (realtime first), or ''
function [cal, from_yml] = reachable_calibrations_root(survey_meta_dir, this_yml)
cal = '';
from_yml = '';
d = dir(fullfile(survey_meta_dir, 'meta_data_*.yml'));
names = {d.name};
[~, order] = sort(~strcmp(names, 'meta_data_realtime.yml')); % realtime first
for k = order
    f = fullfile(survey_meta_dir, names{k});
    if strcmp(f, this_yml)
        continue
    end
    try
        [has, v] = get_value(ReadYaml(f), '', 'calibrations_root');
    catch
        continue
    end
    if has && isfolder(char(string(v)))
        cal = char(string(v));
        from_yml = names{k};
        return
    end
end
end

%% Read one of the source files, or stop with a message naming it
function y = read_source(file)
try
    y = ReadYaml(file);
catch ME
    error('MODsetup_build_yaml:badSource', ['%s does not read as yml (%s). Check its 2-space ' ...
        'indentation and "key: value" lines.'], file, ME.message);
end
end

%% Read the merged temp file, or stop with a message that says where to look
function y = read_merged(tmp_yml, dev1_yml, cruise_meta_data_yml)
try
    y = ReadYaml(tmp_yml);
catch ME
    error('MODsetup_build_yaml:badMerge', ['The merged yml does not read (%s). Left as %s to look at; ' ...
        'the run yml is unchanged. Check that %s and %s use 2-space indentation and ' ...
        'plain "key: value" lines.'], ME.message, tmp_yml, dev1_yml, cruise_meta_data_yml);
end
end

%% File lines as a column cellstr, without the trailing empty line readlines adds
function lines = read_lines(file)
lines = cellstr(readlines(file));
if ~isempty(lines) && isempty(lines{end})
    lines(end) = [];
end
end

function append_lines(file, lines)
writelines([read_lines(file); lines], file);
end

%% Split yml text into top-level blocks. Each block is its 'key:' line, the
% indented lines under it, and the comment lines directly above it (no blank
% line between), so a section's heading comment travels with it. A comment
% run that starts at line 1 is the file's own header and is dropped.
function blocks = split_top_level_blocks(lines)
blocks = struct('key', {}, 'lines', {});
is_top = ~cellfun(@isempty, regexp(lines, '^[A-Za-z_]\w*\s*:', 'once'));
is_comment = ~cellfun(@isempty, regexp(lines, '^\s*#', 'once'));
top_idx = find(is_top);
starts = top_idx;
for iT = 1:numel(top_idx)
    first = top_idx(iT);
    while first > 1 && is_comment(first - 1)
        first = first - 1;
    end
    if first == 1
        first = top_idx(iT);
    end
    starts(iT) = first;
end
for iT = 1:numel(top_idx)
    if iT < numel(top_idx)
        last = starts(iT + 1) - 1;
    else
        last = numel(lines);
    end
    while last > top_idx(iT) && isempty(strtrim(lines{last}))
        last = last - 1;
    end
    key = regexp(lines{top_idx(iT)}, '^([A-Za-z_]\w*)\s*:', 'tokens', 'once');
    blocks(end+1) = struct('key', key{1}, 'lines', {lines(starts(iT):last)}); %#ok<AGROW>
end
end

function k = keys_of(s)
k = {};
if isstruct(s)
    k = fieldnames(s)';
end
end

function tf = is_scalar_value(v)
tf = ((isnumeric(v) || islogical(v)) && isscalar(v)) || ischar(v) || (isstring(v) && isscalar(v));
end

function [has, val] = get_value(y, section, key)
val = [];
if isempty(section) % top-level key
    has = isfield(y, key);
    if has
        val = y.(key);
    end
    return
end
has = isfield(y, section) && isstruct(y.(section)) && isfield(y.(section), key);
if has
    val = y.(section).(key);
end
end

function out = unused_path(path)
out = path;
k = 2;
while isfile(out)
    out = sprintf('%s_%d', path, k);
    k = k + 1;
end
end

