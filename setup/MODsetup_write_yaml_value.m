function MODsetup_write_yaml_value(yaml_file, section, key, value)
% MODsetup_write_yaml_value        Part of MOD_fish_processing
%
% MODsetup_write_yaml_value(yaml_file, section, key, value)
%
% DESCRIPTION
%   Inserts or updates one "key: value" line within a top-level block of
%   a deployment's setup.yml (e.g. section='chi', key='kmin_obs'), in
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
%   Only handles this repo's actual setup.yml shape (flat top-level
%   blocks, simple scalar "key: value" children) - not a general YAML
%   editor. Called by MODsetup_validate_metadata.m when an operator
%   accepts saving a prompted value.
%
% INPUTS
%   yaml_file - full path to a deployment's setup.yml
%   section   - top-level block name, e.g. 'chi' (MODsetup_metadata_field_registry.m's
%               yaml_section)
%   key       - key within that block, e.g. 'kmin_obs' (yaml_key)
%   value     - scalar numeric, logical, or char/string to write. Numeric
%               values are formatted with sprintf('%.10g', value) (clean,
%               minimal-digit, matches how these files are hand-written
%               today, e.g. 1e-3 not 0.0010000000).
%
% OUTPUTS
%   (none - edits yaml_file in place)
%
% CALLED BY
%   MODsetup_validate_metadata.m
%
% CALLS
%   (none)
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

value_str = format_yaml_value(value);
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
        existing = lines{key_line};
        comment_start = regexp(existing, '\s+#', 'once');
        if ~isempty(comment_start)
            lines{key_line} = sprintf('  %s: %s %s', key, value_str, strtrim(existing(comment_start:end)));
        else
            lines{key_line} = sprintf('  %s: %s', key, value_str);
        end
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

%% Clean, minimal-digit yaml scalar formatting for the value types this
% repo's registry actually uses (numeric, logical, char/string).
function s = format_yaml_value(value)
if islogical(value)
    if value
        s = 'true';
    else
        s = 'false';
    end
elseif isnumeric(value)
    % YAMLMatlab's ReadYaml only recognizes Inf/-Inf spelled with a
    % leading dot (YAML 1.1's .inf/-.inf) - the bare word "Inf" sprintf
    % would otherwise produce round-trips back as a char, not a double
    % (confirmed empirically - see MODsetup_read_yaml.m's chi/epsilon
    % contam_freq_hz/coherence_fmax_hz fields, which default to Inf).
    if isinf(value)
        if value > 0
            s = '.inf';
        else
            s = '-.inf';
        end
    else
        s = sprintf('%.10g', value);
    end
elseif ischar(value) || isstring(value)
    s = char(value);
else
    error('MODsetup_write_yaml_value:unsupportedType', ...
        'Cannot format a value of class %s for yaml.', class(value));
end
end
