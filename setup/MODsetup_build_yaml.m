function [run_yml, info] = MODsetup_build_yaml(survey_meta_dir, cruise_meta_data_yml, varargin)
% MODsetup_build_yaml        Part of MOD_fish_processing
%
% run_yml = MODsetup_build_yaml(survey_meta_dir)
% [run_yml, info] = MODsetup_build_yaml(survey_meta_dir, cruise_meta_data_yml, 'run', name, ...)
%
% DESCRIPTION
%   Builds a processing run's yml, <survey>/meta/meta_data_<run>.yml - the
%   file processing reads (MODsetup_read_yaml.m). A run is one yml plus
%   one output folder, <survey>/processed/<run>/; the realtime worker's
%   run is 'realtime'. See docs/workflow/processing_data.md.
%
%   From two sources:
%     - meta/dev1_setup.yml, written on DEV1 by Start New Deployment
%       (acquisition/start_new_deployment.py): what's on the vehicle.
%     - cruise_meta_data.yml: the cruise's processing parameters per
%       sensor type (template: setup/cruise_meta_data_template.yml).
%   The merge is done on the text, so both files' comments are kept:
%     1. dev1_setup.yml, unchanged.
%     2. Each section of cruise_meta_data.yml that dev1_setup.yml doesn't
%        have, copied with its comments. For a section both have (afe:),
%        only the keys dev1_setup.yml lacks are added
%        (MODsetup_write_yaml_value.m). dev1_setup.yml wins on any key
%        both set.
%     3. dev1_setup.yml's top-level profiling_direction (what Start New
%        Deployment writes) is copied to profile_detection.profile_dir,
%        which is what processing reads.
%     4. A run: block - name, L1_from, created_utc, sources.
%
%   The 'realtime' run is rebuilt from the sources on every call, so a
%   change to dev1_setup.yml or cruise_meta_data.yml reaches it:
%     - a registry parameter the old file had and the sources don't (a
%       value saved from a prompt) is carried over; one the sources set
%       differently is reported in info.changed - the sources win;
%     - calibrations_root: the old file's is kept when it exists on this
%       computer and dev1_setup.yml's doesn't (e.g. a copy of the survey
%       on a laptop, after preflight asked for it);
%     - an old-layout meta/depl_meta_data.yml is used as the old file the
%       first time.
%   The old file is kept as .replaced_<UTC stamp> when its content
%   changes; nothing is written when nothing would change, so this is safe
%   to call on every pass of the realtime worker.
%
%   Any other run's yml is made once - from the sources, or from another
%   run's yml ('base') - with 'L1_from' and 'overrides' applied. After that
%   it's that run's own file: it is not rebuilt, so edits by hand stay.
%   Called again with different overrides, it says so and changes nothing
%   (edit the yml, or use a new run name). 'calibrations_root' is applied
%   to any run.
%
%   Whenever a yml is built and its calibrations_root isn't a folder on
%   this computer (and none was given), it takes a reachable one from
%   another run yml of the same survey (realtime first), so the folder
%   only has to be asked for once per copy of a survey.
%
% INPUTS
%   survey_meta_dir      - the survey's meta/ folder (holds dev1_setup.yml)
%   cruise_meta_data_yml - (optional, [] for the default)
%                          <processed_root>/cruise_meta_data.yml, i.e. two
%                          levels above survey_meta_dir. If it doesn't
%                          exist, the yml gets only dev1_setup.yml (+ step
%                          3), with a warning; MODsetup_preflight.m then
%                          lists what's missing.
%   Name-value options:
%     'run'               - run name, default 'realtime'. Letters, digits,
%                           _ and - only (it names the folder).
%     'base'              - another run whose yml this one starts from
%                           (instead of the sources). Not for 'realtime'.
%     'L1_from'           - run whose L1 this run uses instead of making
%                           its own ('' = its own). Not for 'realtime'.
%     'overrides'         - {'section.key', value, ...} (or a registry
%                           name instead of 'section.key', e.g.
%                           'fft_length'), written into a new run's yml.
%                           Not for 'realtime'.
%     'calibrations_root' - folder to use as calibrations_root (written
%                           into the yml); '' = from the sources
%
% OUTPUTS
%   run_yml - full path to meta/meta_data_<run>.yml
%   info    - struct:
%               .run       - the run name
%               .created   - true if the yml didn't exist before
%               .written   - true if the yml was (re)written
%               .backup    - path of the .replaced_* copy, or ''
%               .added     - cellstr 'section.key' added from the cruise file
%               .carried   - cellstr 'section.key' carried over from the old file
%               .changed   - cellstr 'section.key: old -> new'
%               .ignored   - cellstr overrides not applied (existing run yml)
%               .cruise_yml - the cruise file used ('' if none)
%
% CALLED BY
%   MODprocess_deployment.m (each survey pass); by hand
%
% CALLS
%   MODsetup_write_yaml_value.m, MODsetup_format_yaml_value.m,
%   MODsetup_metadata_field_registry.m, ReadYaml (toolbox/YAMLMatlab_0.4.3)
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

ip = inputParser;
addParameter(ip, 'run', 'realtime');
addParameter(ip, 'base', '');
addParameter(ip, 'L1_from', '');
addParameter(ip, 'overrides', {});
addParameter(ip, 'calibrations_root', '');
parse(ip, varargin{:});
opts = ip.Results;
run = char(opts.run);
if isempty(regexp(run, '^[A-Za-z0-9_-]+$', 'once'))
    error('MODsetup_build_yaml:badRunName', ['Run name "%s" can only have letters, digits, _ and - ' ...
        '(it becomes the folder processed/%s/).'], run, run);
end
is_realtime = strcmp(run, 'realtime');
if is_realtime && (~isempty(opts.base) || ~isempty(opts.L1_from) || ~isempty(opts.overrides))
    error('MODsetup_build_yaml:realtimeFromSources', ['The realtime run is built from dev1_setup.yml and ' ...
        'cruise_meta_data.yml only - put parameters there, or use another run name for base/L1_from/overrides.']);
end
for name = {opts.L1_from, opts.base}
    if ~isempty(name{1}) && isempty(regexp(char(name{1}), '^[A-Za-z0-9_-]+$', 'once'))
        error('MODsetup_build_yaml:badRunName', 'Run name "%s" can only have letters, digits, _ and -.', char(name{1}));
    end
end
if strcmp(char(opts.L1_from), run)
    error('MODsetup_build_yaml:L1FromSelf', 'L1_from can''t be the run itself (%s).', run);
end
overrides = parse_overrides(opts.overrides);

if nargin < 2 || isempty(cruise_meta_data_yml)
    cruise_meta_data_yml = fullfile(fileparts(fileparts(survey_meta_dir)), 'cruise_meta_data.yml');
end
toolbox_dir = fullfile(fileparts(fileparts(mfilename('fullpath'))), 'toolbox', 'YAMLMatlab_0.4.3');
addpath(toolbox_dir);

dev1_yml = fullfile(survey_meta_dir, 'dev1_setup.yml');
run_yml = fullfile(survey_meta_dir, ['meta_data_' run '.yml']);
if ~isfile(dev1_yml)
    error('MODsetup_build_yaml:noDev1Setup', 'No dev1_setup.yml in %s - run Start New Deployment first.', survey_meta_dir);
end
info = struct('run', run, 'created', ~isfile(run_yml), 'written', false, 'backup', '', ...
    'added', {{}}, 'carried', {{}}, 'changed', {{}}, 'ignored', {{}}, 'cruise_yml', '');

%% An existing run other than realtime is its own file - not rebuilt
if ~is_realtime && isfile(run_yml)
    existing = read_source(run_yml);
    for iO = 1:numel(overrides)
        [has, val] = get_value(existing, overrides(iO).section, overrides(iO).key);
        if ~has || ~isequal(val, overrides(iO).value)
            info.ignored{end+1} = overrides(iO).name;
        end
    end
    [~, old_L1_from] = get_value(existing, 'run', 'L1_from');
    if ~isempty(opts.L1_from) && ~strcmp(char(string(old_L1_from)), char(opts.L1_from)) % '' = not given
        info.ignored{end+1} = 'run.L1_from';
    end
    [~, old_sources] = get_value(existing, 'run', 'sources');
    if ~isempty(opts.base) && ~contains(char(string(old_sources)), ['meta_data_' char(opts.base) '.yml'])
        info.ignored{end+1} = 'base';
    end
    if ~isempty(info.ignored)
        fprintf(['MODsetup_build_yaml: %s already exists, so these were not applied: %s.\n' ...
            '  Edit that file, or give a new run name to start a new run.\n'], run_yml, strjoin(info.ignored, ', '));
    end
    [~, old_cal] = get_value(existing, '', 'calibrations_root');
    new_cal = char(opts.calibrations_root);
    if isempty(new_cal) && ~isfolder(char(string(old_cal)))
        [new_cal, from_yml] = reachable_calibrations_root(survey_meta_dir, run_yml);
        if ~isempty(new_cal)
            info.carried{end+1} = ['calibrations_root (from ' from_yml ')'];
        end
    end
    if ~isempty(new_cal) && ~strcmp(char(string(old_cal)), new_cal)
        MODsetup_write_yaml_value(run_yml, '', 'calibrations_root', new_cal);
        info.written = true;
    end
    return
end

%% Start the new text: the sources, or the base run's yml
tmp_yml = [run_yml '.building'];
% (rewritten from scratch each time; left behind if a build fails, to look at)
if ~isempty(opts.base)
    base_yml = fullfile(survey_meta_dir, ['meta_data_' char(opts.base) '.yml']);
    if ~isfile(base_yml)
        error('MODsetup_build_yaml:noBase', 'No %s to start run %s from.', base_yml, run);
    end
    sources = sprintf('a copy of meta_data_%s.yml', char(opts.base));
    body = drop_header(read_lines(base_yml));
else
    if isfile(cruise_meta_data_yml)
        sources = sprintf('dev1_setup.yml (below) and %s (after it)', cruise_meta_data_yml);
    else
        sources = sprintf('dev1_setup.yml (below) only - no %s', cruise_meta_data_yml);
    end
    body = read_lines(dev1_yml);
end
header = {sprintf('## meta_data_%s.yml - processing run "%s", made by MODsetup_build_yaml.m from %s.', run, run, sources)
    sprintf('## Output goes to ../processed/%s/. Every path comes from where this file is; data_root is the ship''s, kept as a record.', run)};
if is_realtime
    header{end+1} = '## Rebuilt from its sources on every realtime pass: edit those. Values saved here by a prompt are kept.';
else
    header{end+1} = '## Made once; this is now this run''s own file - edit it here (it is not rebuilt).';
end
writelines([header; {''}; body], tmp_yml);

if isempty(opts.base)
    dev1 = read_source(dev1_yml);
    %% 2. Cruise processing parameters
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

    %% 3. Start New Deployment's profiling_direction -> profile_detection.profile_dir
    if isfield(dev1, 'profiling_direction')
        MODsetup_write_yaml_value(tmp_yml, 'profile_detection', 'profile_dir', char(string(dev1.profiling_direction)));
    end
end

%% realtime: carry over from the old file (or the old-layout depl_meta_data.yml)
old_yml = run_yml;
if is_realtime && ~isfile(old_yml)
    old_yml = fullfile(survey_meta_dir, 'depl_meta_data.yml');
end
created_utc = char(datetime('now', 'TimeZone', 'UTC', 'Format', 'yyyy-MM-dd HH:mm:ss'));
if is_realtime && isfile(old_yml)
    old = read_source(old_yml);
    merged = read_merged(tmp_yml, dev1_yml, cruise_meta_data_yml);
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
    % calibrations_root that works on this computer wins over one that doesn't
    [has_old_cal, old_cal] = get_value(old, '', 'calibrations_root');
    [~, new_cal] = get_value(merged, '', 'calibrations_root');
    if has_old_cal && isfolder(char(string(old_cal))) && ~isfolder(char(string(new_cal)))
        MODsetup_write_yaml_value(tmp_yml, '', 'calibrations_root', char(string(old_cal)));
        info.carried{end+1} = 'calibrations_root';
    end
    [has_created, old_created] = get_value(old, 'run', 'created_utc');
    if has_created
        created_utc = char(string(old_created)); % so an unchanged rebuild is byte-identical
    end
end

%% 4. run: block, overrides, calibrations_root
MODsetup_write_yaml_value(tmp_yml, 'run', 'sources', sources);
MODsetup_write_yaml_value(tmp_yml, 'run', 'created_utc', created_utc);
MODsetup_write_yaml_value(tmp_yml, 'run', 'L1_from', char(opts.L1_from));
MODsetup_write_yaml_value(tmp_yml, 'run', 'name', run);
for iO = 1:numel(overrides)
    MODsetup_write_yaml_value(tmp_yml, overrides(iO).section, overrides(iO).key, overrides(iO).value);
end
if ~isempty(opts.calibrations_root)
    MODsetup_write_yaml_value(tmp_yml, '', 'calibrations_root', char(opts.calibrations_root));
else
    % one that isn't a folder here: another run of this survey may already
    % have one that is (asked for once per copy of the survey, not per run)
    [~, cal] = get_value(read_merged(tmp_yml, dev1_yml, cruise_meta_data_yml), '', 'calibrations_root');
    if ~isfolder(char(string(cal)))
        [other_cal, from_yml] = reachable_calibrations_root(survey_meta_dir, run_yml);
        if ~isempty(other_cal)
            MODsetup_write_yaml_value(tmp_yml, '', 'calibrations_root', other_cal);
            info.carried{end+1} = ['calibrations_root (from ' from_yml ')'];
        end
    end
end

if ~isempty(info.changed)
    fprintf(['MODsetup_build_yaml: %s differed from its sources and now follows them:\n  %s\n' ...
        '  (edit dev1_setup.yml or cruise_meta_data.yml to change these for good)\n'], ...
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

%% {'section.key', value, ...} (or registry names) -> struct array
function out = parse_overrides(c)
out = struct('name', {}, 'section', {}, 'key', {}, 'value', {});
if isempty(c)
    return
end
if ~iscell(c) || mod(numel(c), 2) ~= 0
    error('MODsetup_build_yaml:badOverrides', 'overrides must be {''section.key'', value, ...}.');
end
registry = MODsetup_metadata_field_registry();
for k = 1:2:numel(c)
    name = char(c{k});
    parts = strsplit(name, '.');
    if numel(parts) == 2
        sec = parts{1}; key = parts{2};
    else
        r = registry(strcmp({registry.name}, name));
        if isempty(r)
            error('MODsetup_build_yaml:badOverrides', ['Override "%s" is neither ''section.key'' nor a ' ...
                'registry name (MODsetup_metadata_field_registry.m).'], name);
        end
        sec = r(1).yaml_section; key = r(1).yaml_key;
    end
    out(end+1) = struct('name', name, 'section', sec, 'key', key, 'value', c{k + 1}); %#ok<AGROW>
end
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

%% A run yml's lines without its "## " header (and the blank line after it)
function lines = drop_header(lines)
k = 1;
while k <= numel(lines) && startsWith(lines{k}, '##')
    k = k + 1;
end
if k <= numel(lines) && isempty(strtrim(lines{k}))
    k = k + 1;
end
lines = lines(k:end);
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

