function MODsetup_write_cruise_meta_data_template(out_file)
% MODsetup_write_cruise_meta_data_template        Part of MOD_fish_processing
%
% MODsetup_write_cruise_meta_data_template(out_file)
%
% DESCRIPTION
%   Writes a cruise_meta_data.yml template: every processing parameter in
%   MODsetup_metadata_field_registry.m, grouped by yaml section, with its
%   suggested_default as the starting value. The top of the file is just
%   the sections and "key: value" lines (one heading comment per section);
%   each field's description is in a block at the bottom, under a
%   "# ==== Field descriptions ====" line. MODsetup_build_yaml.m looks for
%   that line to copy the block to the bottom of each run yml, and
%   MODsetup_write_yaml_value.m to add new lines above it. Generated from
%   the registry so the template can't drift from it;
%   setup/cruise_meta_data_template.yml in the repo is this function's
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
section_order = {'afe', 'spectral', 'profile_detection', 'chi', 'ucond', 'epsilon', 'grid'};
section_notes = struct( ...
    'afe', 'EFE board (every vehicle - L0->L1 needs afe.sample_rate)', ...
    'spectral', 'Scan and spectrum settings (every vehicle)', ...
    'profile_detection', 'Profiling direction and cast detection from the pressure time series (every vehicle)', ...
    'chi', 'FP07 chi (only used when an AFE slot is fpo7)', ...
    'ucond', 'Microconductivity chi (only used when an AFE slot is microcond)', ...
    'epsilon', 'Shear epsilon (only used when an AFE slot is shear)', ...
    'grid', 'Gridding (every vehicle)');
sections = unique({registry.yaml_section}, 'stable');
sections = [section_order(ismember(section_order, sections)), setdiff(sections, section_order, 'stable')];

L = {
    '# cruise_meta_data.yml - processing parameters for one cruise.'
    '# Values are suggested defaults - REVIEW EVERY VALUE before the cruise.'
    '# What each field is for, and how this file is used, is at the bottom.'
    };
for iS = 1:numel(sections)
    sec = sections{iS};
    L{end+1, 1} = ''; %#ok<AGROW>
    if isfield(section_notes, sec)
        L{end+1, 1} = ['# ' section_notes.(sec)]; %#ok<AGROW>
    end
    L{end+1, 1} = [sec ':']; %#ok<AGROW>
    for spec = registry(strcmp({registry.yaml_section}, sec))
        L{end+1, 1} = sprintf('  %s: %s', spec.yaml_key, MODsetup_format_yaml_value(spec.suggested_default)); %#ok<AGROW>
    end
end

%% Field descriptions, at the bottom
L = [L; {''
    '# ========================= Field descriptions ========================='
    '#'
    '# About this file'
    }];
about = ['Made by MODsetup_write_cruise_meta_data_template.m from MODsetup_metadata_field_registry.m. ' ...
    'Values are the registry''s suggested defaults - historical starting points. ' ...
    'Put the reviewed copy at <processed_root>/cruise_meta_data.yml. ' ...
    'MODsetup_build_yaml.m merges it with each survey''s meta/dev1_setup.yml (from Start New Deployment) ' ...
    'into each processing run''s yml, meta/meta_data_<run>.yml, which processing reads. ' ...
    'Values in dev1_setup.yml win over this file. ' ...
    'A section may be left out if no vehicle on the cruise needs it. ' ...
    'Keep the 2-space indentation and plain "key: value" lines when editing.'];
L = [L; wrap_comment(about, '#   ', '#   ', 92)'];
for iS = 1:numel(sections)
    sec = sections{iS};
    L{end+1, 1} = '#'; %#ok<AGROW>
    if isfield(section_notes, sec)
        L{end+1, 1} = ['# ' sec ' - ' section_notes.(sec)]; %#ok<AGROW>
    else
        L{end+1, 1} = ['# ' sec]; %#ok<AGROW>
    end
    for spec = registry(strcmp({registry.yaml_section}, sec))
        L = [L; wrap_comment([spec.yaml_key ': ' char(spec.description)], '#   - ', '#       ', 92)']; %#ok<AGROW>
    end
end

writelines(L, out_file);
fprintf('Wrote %s (%d parameters)\n', out_file, numel(registry));
end %end function

%% Word-wrap text into comment lines no wider than width: the first line
% starts with first_prefix, the rest with next_prefix
function lines = wrap_comment(text, first_prefix, next_prefix, width)
words = strsplit(strtrim(regexprep(char(text), '\s+', ' ')), ' ');
lines = {};
prefix = first_prefix;
current = prefix;
for iW = 1:numel(words)
    if strlength(current) > strlength(prefix) && strlength(current) + 1 + strlength(words{iW}) > width
        lines{end+1} = current; %#ok<AGROW>
        prefix = next_prefix;
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
