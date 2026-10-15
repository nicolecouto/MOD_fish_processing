function s = MODsetup_format_yaml_value(value)
% MODsetup_format_yaml_value        Part of MOD_fish_processing
%
% s = MODsetup_format_yaml_value(value)
%
% DESCRIPTION
%   Clean, minimal-digit yaml scalar text for the value types the registry
%   uses (numeric, logical, char/string): numbers as sprintf('%.10g'),
%   logicals as true/false, Inf as .inf and NaN as .nan, text in single
%   quotes. YAMLMatlab's ReadYaml only reads Inf/NaN spelled with a leading
%   dot (YAML 1.1's .inf/-.inf/.nan); the bare words "Inf"/"NaN" come back
%   as char, not double (confirmed empirically - the chi/epsilon
%   contam_freq_hz and coherence_fmax_hz values default to Inf). Text is
%   quoted so a value like yes/no/on/off or 0537 can't read back as a
%   logical or a number.
%
% INPUTS
%   value - scalar numeric, logical, or char/string
%
% OUTPUTS
%   s     - char, the yaml text for value
%
% CALLED BY
%   MODsetup_write_yaml_value.m, MODsetup_write_cruise_meta_data_template.m,
%   MODsetup_build_yaml.m
%
% CALLS
%   (none)
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

if islogical(value)
    if value
        s = 'true';
    else
        s = 'false';
    end
elseif isnumeric(value)
    % .inf/.nan, not Inf/NaN - see DESCRIPTION
    if isnan(value)
        s = '.nan';
    elseif isinf(value)
        if value > 0
            s = '.inf';
        else
            s = '-.inf';
        end
    else
        s = sprintf('%.10g', value);
    end
elseif ischar(value) || isstring(value)
    s = ['''' strrep(char(value), '''', '''''') ''''];
else
    error('MODsetup_format_yaml_value:unsupportedType', ...
        'Cannot format a value of class %s for yaml.', class(value));
end
end
