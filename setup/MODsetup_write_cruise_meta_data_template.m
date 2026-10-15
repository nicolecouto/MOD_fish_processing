function MODsetup_write_cruise_meta_data_template(out_file)
% MODsetup_write_cruise_meta_data_template        Part of MOD_fish_processing
%
% MODsetup_write_cruise_meta_data_template(out_file)
%
% DESCRIPTION
%   Writes a cruise_meta_data.yml template: every processing parameter in
%   MODsetup_metadata_field_registry.m, grouped by yaml section, each with
%   its description as a comment and its suggested_default as the starting
%   value. Generated from the registry so the template can't drift from
%   it; setup/cruise_meta_data_template.yml in the repo is this function's
%   output.
%
%   For a cruise: copy the template to <processed_root>/cruise_meta_data.yml
%   and review every value. The suggested defaults are historical
%   starting points, not choices made for this cruise. MODsetup_build_yaml.m
%   then merges it with each survey's dev1_setup.yml.
%
% INPUTS
%   out_file - (optional) where to write it. Default:
%              setup/cruise_meta_data_template.yml in this repo.
%
% OUTPUTS
%   (none - writes out_file)
%
% CALLED BY
%   (by hand, after the registry changes)
%
% CALLS
%   MODsetup_metadata_field_registry.m, MODsetup_format_yaml_value.m
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

if nargin < 1 || isempty(out_file)
    out_file = fullfile(fileparts(mfilename('fullpath')), 'cruise_meta_data_template.yml');
end

registry = MODsetup_metadata_field_registry();

% Section order follows the pipeline; any section not listed here goes at the end
section_order = {'afe', 'ctd', 'spectral', 'profile_detection', 'chi', 'epsilon', 'grid'};
section_notes = struct( ...
    'afe', 'EFE board (every vehicle - L0->L1 needs afe.sample_rate)', ...
    'ctd', 'CTD (every vehicle)', ...
    'spectral', 'Scan and spectrum settings (every vehicle)', ...
    'profile_detection', 'Profiling direction and cast detection from the pressure time series (every vehicle)', ...
    'chi', 'FP07 chi (only used when an AFE slot is fpo7)', ...
    'epsilon', 'Shear epsilon (only used when an AFE slot is shear)', ...
    'grid', 'Gridding (every vehicle)');
sections = unique({registry.yaml_section}, 'stable');
sections = [section_order(ismember(section_order, sections)), setdiff(sections, section_order, 'stable')];

L = {
    '# cruise_meta_data.yml - processing parameters for one cruise.'
    '#'
    '# Made by MODsetup_write_cruise_meta_data_template.m from'
    '# MODsetup_metadata_field_registry.m. Values are the registry''s suggested'
    '# defaults - historical starting points. REVIEW EVERY VALUE before the cruise.'
    '#'
    '# Put the reviewed copy at <processed_root>/cruise_meta_data.yml.'
    '# MODsetup_build_yaml.m merges it with each survey''s meta/dev1_setup.yml'
    '# (from Start New Deployment) into meta/depl_meta_data.yml, which'
    '# processing reads. Values in dev1_setup.yml win over this file.'
    '# A section may be left out if no vehicle on the cruise needs it.'
    '# Keep the 2-space indentation and plain "key: value" lines when editing.'
    };
for iS = 1:numel(sections)
    sec = sections{iS};
    L{end+1, 1} = ''; %#ok<AGROW>
    if isfield(section_notes, sec)
        L{end+1, 1} = ['# ' section_notes.(sec)]; %#ok<AGROW>
    end
    L{end+1, 1} = [sec ':']; %#ok<AGROW>
    for spec = registry(strcmp({registry.yaml_section}, sec))
        for line = wrap_comment(spec.description, 4, 92)
            L{end+1, 1} = line{1}; %#ok<AGROW>
        end
        L{end+1, 1} = sprintf('  %s: %s', spec.yaml_key, MODsetup_format_yaml_value(spec.suggested_default)); %#ok<AGROW>
    end
end

writelines(L, out_file);
fprintf('Wrote %s (%d parameters)\n', out_file, numel(registry));
end %end function

%% Word-wrap text into '  # ...' comment lines no wider than width
function lines = wrap_comment(text, indent, width)
prefix = [repmat(' ', 1, indent - 2) '# '];
words = strsplit(strtrim(regexprep(char(text), '\s+', ' ')), ' ');
lines = {};
current = prefix;
for iW = 1:numel(words)
    if strlength(current) > strlength(prefix) && strlength(current) + 1 + strlength(words{iW}) > width
        lines{end+1} = current; %#ok<AGROW>
        current = prefix;
    end
    if strlength(current) == strlength(prefix)
        current = [current words{iW}]; %#ok<AGROW>
    else
        current = [current ' ' words{iW}]; %#ok<AGROW>
    end
end
lines{end+1} = current;
end
