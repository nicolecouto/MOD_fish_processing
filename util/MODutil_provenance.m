function p = MODutil_provenance(source_files, metadata, survey_dir)
% MODutil_provenance        Part of MOD_fish_processing
%
% p = MODutil_provenance(source_files, metadata)
% p = MODutil_provenance(source_files, metadata, survey_dir)
%
% DESCRIPTION
%   The provenance field saved in every L0, L1, L2, profiles_L1 and
%   profiles_L2 file: which data file(s) it was made from and which yml.
%   Paths are relative to the survey folder (e.g. 'L0/x.mat',
%   'processed/realtime/L1/x.mat', 'meta/meta_data_realtime.yml'), so they
%   are still right after the survey folder is copied somewhere else; a
%   path outside the survey folder is kept whole. yml_sha256 says which
%   version of the yml it was: compare it with the yml's current hash
%   (metadata.header.yaml_hash) to see whether the yml has changed since.
%   Nothing is redone because of a changed yml - this is a record.
%
% INPUTS
%   source_files - char or cellstr: full path(s) of the file(s) read to
%                  make this one
%   metadata     - from MODsetup_read_yaml.m, or [] (e.g. L0 made with no
%                  yml)
%   survey_dir   - (optional) the survey folder. Default
%                  metadata.paths.data_root.
%
% OUTPUTS
%   p - struct:
%         survey     - the survey folder's name
%         files      - cellstr, the source file(s), relative to the survey
%         yml        - the yml used, relative to the survey ('' if none)
%         yml_sha256 - SHA-256 of the yml's contents when it was read ('' if none)
%         run        - the processing run ('' if not a run yml)
%         made_utc   - when this file was made, 'yyyy-MM-dd HH:mm:ss'
%         code       - MODutil_code_version.m, e.g. 'commit e286ebf'
%
% CALLED BY
%   MODprocess_all_modraw_to_L0.m, MODprocess_all_L0_to_L1.m,
%   MODprocess_all_L1_to_L2.m, MODprocess_all_extract_profiles.m
%
% CALLS
%   MODutil_code_version.m
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

if nargin < 3 || isempty(survey_dir)
    survey_dir = '';
    if isstruct(metadata) && isfield(metadata, 'paths') && isfield(metadata.paths, 'data_root')
        survey_dir = metadata.paths.data_root;
    end
end
survey_dir = char(survey_dir);
[~, survey] = fileparts(survey_dir);
yml = '';
yml_sha256 = '';
run = '';
if isstruct(metadata)
    if isfield(metadata, 'paths') && isfield(metadata.paths, 'setup_yml')
        yml = relative(metadata.paths.setup_yml, survey_dir);
    end
    if isfield(metadata, 'header') && isfield(metadata.header, 'yaml_hash')
        yml_sha256 = metadata.header.yaml_hash;
    end
    if isfield(metadata, 'run') && isfield(metadata.run, 'name')
        run = metadata.run.name;
    end
end
files = cellfun(@(f) relative(f, survey_dir), cellstr(source_files), 'UniformOutput', false);
p = struct('survey', survey, 'files', {files(:)'}, 'yml', yml, 'yml_sha256', yml_sha256, ...
    'run', run, 'made_utc', char(datetime('now', 'TimeZone', 'UTC', 'Format', 'yyyy-MM-dd HH:mm:ss')), ...
    'code', MODutil_code_version());
end %end function

%% f relative to folder (with / separators), or f unchanged if it isn't inside it
function r = relative(f, folder)
f = char(f);
r = f;
if ~isempty(folder) && startsWith(f, [folder filesep])
    r = strrep(f(numel(folder) + 2:end), filesep, '/');
end
end
