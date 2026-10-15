function [surveys, warnings_out] = MODutil_list_surveys(processed_root)
% MODutil_list_surveys        Part of MOD_fish_processing
%
% [surveys, warnings_out] = MODutil_list_surveys(processed_root)
%
% DESCRIPTION
%   Lists the surveys under processed_root that have a meta/dev1_setup.yml
%   (written by Start New Deployment), in the order they were set up: the
%   UTC time on the file's first line ("written on DEV1 by
%   start_new_deployment.py <yyyy-mm-dd HH:MM> UTC"), or the file's
%   modification time, with a warning, if that line is missing. The last
%   one is the deployment going on now.
%
% INPUTS
%   processed_root - folder holding the survey folders
%
% OUTPUTS
%   surveys      - struct array in set-up order:
%                    .survey   - survey_name from the yml (folder name if absent)
%                    .folder   - <processed_root>/<survey folder>
%                    .dev1_yml - path of its dev1_setup.yml
%                    .dnum     - when it was set up [datenum, UTC]
%                    .spool    - winch_spool ('' if not set)
%   warnings_out - cellstr: files that couldn't be read (skipped) or had
%                  no written-at line
%
% CALLED BY
%   MODprocess_find_spool_swaps.m, MODprocess_deployment.m
%
% CALLS
%   ReadYaml (toolbox/YAMLMatlab_0.4.3)
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

addpath(fullfile(fileparts(fileparts(mfilename('fullpath'))), 'toolbox', 'YAMLMatlab_0.4.3'));
surveys = struct('survey', {}, 'folder', {}, 'dev1_yml', {}, 'dnum', {}, 'spool', {});
warnings_out = {};
files = dir(fullfile(processed_root, '*', 'meta', 'dev1_setup.yml'));
for iF = 1:numel(files)
    f = fullfile(files(iF).folder, files(iF).name);
    folder = fileparts(files(iF).folder); % <survey>/meta -> <survey>
    [~, survey] = fileparts(folder);
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
        warnings_out{end+1} = sprintf('Could not read %s (%s) - skipped.', f, ME.message); %#ok<AGROW>
        continue
    end
    tok = regexp(first_line(f), '(\d{4}-\d\d-\d\d \d\d:\d\d) UTC', 'tokens', 'once');
    if ~isempty(tok)
        dnum = datenum(datetime(tok{1}, 'InputFormat', 'yyyy-MM-dd HH:mm'));
    else
        dnum = files(iF).datenum; % local file time - only a fallback
        warnings_out{end+1} = sprintf(['%s has no "written ... UTC" first line - using the file''s ' ...
            'modification time.'], f); %#ok<AGROW>
    end
    surveys(end+1) = struct('survey', survey, 'folder', folder, 'dev1_yml', f, 'dnum', dnum, 'spool', spool); %#ok<AGROW>
end
if ~isempty(surveys)
    [~, order] = sort([surveys.dnum]);
    surveys = surveys(order);
end
end %end function

function line = first_line(file)
fid = fopen(file, 'r');
line = fgetl(fid);
fclose(fid);
if ~ischar(line)
    line = '';
end
end
