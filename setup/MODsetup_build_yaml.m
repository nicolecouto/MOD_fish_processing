function [depl_yml, info] = MODsetup_build_yaml(survey_meta_dir, cruise_meta_data_yml)
% MODsetup_build_yaml        Part of MOD_fish_processing
%
% depl_yml = MODsetup_build_yaml(survey_meta_dir)
% [depl_yml, info] = MODsetup_build_yaml(survey_meta_dir, cruise_meta_data_yml)
%
% DESCRIPTION
%   Builds meta/depl_meta_data.yml, the yml processing reads
%   (MODsetup_read_yaml.m), from two files:
%     - meta/dev1_setup.yml, written on DEV1 by Start New Deployment
%       (acquisition/start_new_deployment.py): what's on the vehicle.
%     - cruise_meta_data.yml: the cruise's processing parameters per
%       sensor type (template: setup/cruise_meta_data_template.yml).
%
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
%     4. If depl_meta_data.yml already existed, any registry parameter it
%        had that the new merge doesn't (e.g. a value saved from a
%        preflight prompt) is carried over. A registry parameter the two
%        sources set to a different value than the old file had is
%        reported in info.changed - the sources win.
%
%   An existing depl_meta_data.yml whose content would change is kept as
%   depl_meta_data.yml.replaced_<UTC stamp>. If nothing would change the
%   file isn't rewritten, so this is safe to call on every pass of the
%   realtime worker.
%
% INPUTS
%   survey_meta_dir      - the survey's meta/ folder (holds dev1_setup.yml)
%   cruise_meta_data_yml - (optional) default
%                          <processed_root>/cruise_meta_data.yml, i.e. two
%                          levels above survey_meta_dir. If it doesn't
%                          exist, depl_meta_data.yml gets only
%                          dev1_setup.yml (+ step 3), with a warning;
%                          MODsetup_preflight.m then lists what's missing.
%
% OUTPUTS
%   depl_yml - full path to meta/depl_meta_data.yml
%   info     - struct:
%                .written   - true if depl_meta_data.yml was (re)written
%                .backup    - path of the .replaced_* copy, or ''
%                .added     - cellstr 'section.key' added from the cruise file
%                .carried   - cellstr 'section.key' carried over from the old file
%                .changed   - cellstr 'section.key: old -> new'
%                .cruise_yml - the cruise file used ('' if none)
%
% CALLED BY
%   MODprocess_deployment.m (each survey pass); by hand
%
% CALLS
%   MODsetup_write_yaml_value.m, MODsetup_format_yaml_value.m,
%   MODsetup_metadata_field_registry.m, ReadYaml (toolbox/YAMLMatlab_0.4.3)
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

if nargin < 2 || isempty(cruise_meta_data_yml)
    cruise_meta_data_yml = fullfile(fileparts(fileparts(survey_meta_dir)), 'cruise_meta_data.yml');
end
toolbox_dir = fullfile(fileparts(fileparts(mfilename('fullpath'))), 'toolbox', 'YAMLMatlab_0.4.3');
addpath(toolbox_dir);

dev1_yml = fullfile(survey_meta_dir, 'dev1_setup.yml');
depl_yml = fullfile(survey_meta_dir, 'depl_meta_data.yml');
if ~isfile(dev1_yml)
    error('MODsetup_build_yaml:noDev1Setup', 'No dev1_setup.yml in %s - run Start New Deployment first.', survey_meta_dir);
end
info = struct('written', false, 'backup', '', 'added', {{}}, 'carried', {{}}, ...
    'changed', {{}}, 'cruise_yml', '');

% Work on a temp copy; depl_meta_data.yml is only replaced at the end
tmp_yml = [depl_yml '.building'];
% (rewritten from scratch each time; left behind if a build fails, to look at)
dev1_lines = read_lines(dev1_yml);
if isfile(cruise_meta_data_yml)
    sources = sprintf('dev1_setup.yml (below) and %s (after it)', cruise_meta_data_yml);
else
    sources = sprintf('dev1_setup.yml (below) only - no %s', cruise_meta_data_yml);
end
header = {['# depl_meta_data.yml - made by MODsetup_build_yaml.m from ' sources '.']
    '# Edit those and rebuild; values saved here by a preflight prompt are kept on rebuild.'
    ''};
writelines([header; dev1_lines], tmp_yml);
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
        'No %s - depl_meta_data.yml has only dev1_setup.yml; run MODsetup_preflight to see what''s missing.', ...
        cruise_meta_data_yml);
end

%% 3. Start New Deployment's profiling_direction -> profile_detection.profile_dir
if isfield(dev1, 'profiling_direction')
    MODsetup_write_yaml_value(tmp_yml, 'profile_detection', 'profile_dir', char(string(dev1.profiling_direction)));
end

%% 4. Carry over registry parameters from an existing depl_meta_data.yml
if isfile(depl_yml)
    old = read_source(depl_yml);
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
end

if ~isempty(info.changed)
    fprintf(['MODsetup_build_yaml: %s differed from its sources and now follows them:\n  %s\n' ...
        '  (edit dev1_setup.yml or cruise_meta_data.yml to change these for good)\n'], ...
        depl_yml, strjoin(info.changed, sprintf('\n  ')));
end

%% Check it reads, then replace depl_meta_data.yml only if it changed
read_merged(tmp_yml, dev1_yml, cruise_meta_data_yml);
new_text = fileread(tmp_yml);
if isfile(depl_yml) && strcmp(fileread(depl_yml), new_text)
    delete(tmp_yml);
    return
end
if isfile(depl_yml)
    info.backup = unused_path([depl_yml '.replaced_' char(datetime('now', 'TimeZone', 'UTC', 'Format', 'yyyyMMddHHmmss'))]);
    copyfile(depl_yml, info.backup);
end
movefile(tmp_yml, depl_yml, 'f');
info.written = true;
end %end function

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
        'depl_meta_data.yml is unchanged. Check that %s and %s use 2-space indentation and ' ...
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
has = isfield(y, section) && isstruct(y.(section)) && isfield(y.(section), key);
val = [];
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

