function MODsetup_write_yaml_value(yaml_file, section, key, value)
% MODsetup_write_yaml_value        Part of MOD_fish_processing
%
% MODsetup_write_yaml_value(yaml_file, section, key, value)
%
% DESCRIPTION
%   Inserts or updates one "key: value" line within a top-level block of
%   a processing run's yml or a setup.yml (e.g. section='chi', key='kmin_obs'), in
%   place - a targeted text-level edit, not a round-trip through the
%   vendored toolbox/YAMLMatlab_0.4.3/WriteYaml.m, which would reformat
%   the whole file and destroy setup.yml's hand-written comments (see
%   every real setup.yml in this repo - they're heavily commented).
%   Everything else in the file - every other line, comment, and blank -
%   is left byte-for-byte unchanged.
%
%   If the section block already exists (a line matching '^section:'),
%   the key is found among that block's direct 2-space-indented children
%   (the convention every setup.yml in this repo already uses) and its
%   value replaced in place, preserving any trailing inline comment; if
%   the key isn't there yet, a new "  key: value" line is inserted
%   immediately after the section header. If the section doesn't exist at
%   all (e.g. no chi: block yet), a new one is appended at the end of the
%   file.
%
%   section = '' sets a top-level "key: value" line instead (e.g.
%   calibrations_root), replaced in place, keeping any inline comment, or
%   appended at the end of the file if it isn't there yet.
%
%   Only handles this repo's actual setup.yml shape (flat top-level
%   blocks, simple scalar "key: value" children, 2-space indentation) -
%   not a general YAML editor. Called by MODsetup_validate_metadata.m when
%   an operator accepts saving a prompted value, and by
%   MODsetup_build_yaml.m (merging, the run: block and calibrations_root),
%   and by MODsetup_preflight.m (calibrations_root).
%
% INPUTS
%   yaml_file - full path to a run yml (meta_data_<run>.yml) or setup.yml
%   section   - top-level block name, e.g. 'chi' (MODsetup_metadata_field_registry.m's
%               yaml_section), or '' for a top-level key
%   key       - key within that block, e.g. 'kmin_obs' (yaml_key)
%   value     - scalar numeric, logical, or char/string to write,
%               formatted by MODsetup_format_yaml_value.m (numbers with
%               sprintf('%.10g'), e.g. 1e-3 not 0.0010000000; Inf/NaN as
%               .inf/.nan; text single-quoted).
%
% OUTPUTS
%   (none - edits yaml_file in place)
%
% CALLED BY
%   MODsetup_validate_metadata.m, MODsetup_build_yaml.m, MODsetup_preflight.m
%
% CALLS
%   MODsetup_format_yaml_value.m
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

lines = cellstr(readlines(yaml_file));
% readlines can leave one trailing '' entry for files that end with a
% newline (common/expected) - drop it so appends below don't leave a
% stray blank line before new content; writelines re-adds a final
% newline on save regardless.
if ~isempty(lines) && isempty(lines{end})
    lines(end) = [];
end

value_str = MODsetup_format_yaml_value(value);
section = char(section);
if isempty(section)
    key_line = find_top_level_key(lines, key);
    if ~isempty(key_line) && key_line < numel(lines) && ~isempty(regexp(lines{key_line + 1}, '^\s+\S', 'once'))
        error('MODsetup_write_yaml_value:topLevelBlock', ['%s: is a block in %s, not a single ' ...
            'value - give its section and key instead.'], key, yaml_file);
    end
    if isempty(key_line)
        lines{end+1} = sprintf('%s: %s', key, value_str);
    else
        lines{key_line} = with_inline_comment(sprintf('%s: %s', key, value_str), lines{key_line});
    end
    writelines(lines, yaml_file);
    return
end
section_line = find_top_level_key(lines, section);

if isempty(section_line)
    if ~isempty(lines) && ~isempty(strtrim(lines{end}))
        lines{end+1} = '';
    end
    lines{end+1} = sprintf('%s:', section);
    lines{end+1} = sprintf('  %s: %s', key, value_str);
else
    block_end = section_line;
    for i = (section_line + 1):numel(lines)
        line = lines{i};
        is_continuation = isempty(strtrim(line)) || startsWith(strtrim(line), '#') || ...
            (~isempty(line) && any(line(1) == [' ', char(9)]));
        if ~is_continuation
            break
        end
        block_end = i;
    end

    key_line = 0;
    key_pattern = sprintf('^  %s:', regexptranslate('escape', key));
    for i = (section_line + 1):block_end
        if ~isempty(regexp(lines{i}, key_pattern, 'once'))
            key_line = i;
            break
        end
    end

    if key_line > 0
        lines{key_line} = with_inline_comment(sprintf('  %s: %s', key, value_str), lines{key_line});
    else
        new_line = sprintf('  %s: %s', key, value_str);
        lines = [lines(1:section_line); {new_line}; lines(section_line + 1:end)];
    end
end

writelines(lines, yaml_file);

end %end function

%% First line index (1-based) matching a top-level 'key:' header, or []
function idx = find_top_level_key(lines, key)
idx = [];
pattern = sprintf('^%s:', regexptranslate('escape', key));
for i = 1:numel(lines)
    if ~isempty(regexp(lines{i}, pattern, 'once'))
        idx = i;
        return
    end
end
end

%% new_line plus whatever inline "# comment" the line it replaces had
function line = with_inline_comment(new_line, existing)
line = new_line;
comment_start = regexp(existing, '\s+#', 'once');
if ~isempty(comment_start)
    line = sprintf('%s %s', new_line, strtrim(existing(comment_start:end)));
end
end
