function deleted = MODprocess_reset_survey(survey_folder, varargin)
% MODprocess_reset_survey        Part of MOD_fish_processing
%
% deleted = MODprocess_reset_survey(survey_folder)
% deleted = MODprocess_reset_survey(survey_folder, 'yes', true)
%
% DESCRIPTION
%   Clears a survey so it's reprocessed from raw: deletes its L0/, its
%   processed/ (every run in it) and meta/ctd_calibration.mat. raw/ and
%   the ymls in meta/ are kept. For after the CTD calibration changed
%   within a survey and the worker stopped (MODprocess_all_modraw_to_L0.m):
%   fix calibrations_root/SBE/<SN>.CAL, run this, restart the worker.
%
%   Shows what it will delete and asks first. Refuses while the realtime
%   worker is running (<processed_root>/realtime/worker.lock), since it
%   would be writing into these folders.
%
% INPUTS
%   survey_folder - the survey (the folder holding raw/ and meta/)
%   'yes'         - (optional) true: don't ask (e.g. under matlab -batch,
%                   which can't). Default false.
%
% OUTPUTS
%   deleted - cellstr of what was deleted ({} if nothing, or not confirmed)
%
% CALLED BY
%   (by hand - the "CTD calibration changed" message says to)
%
% CALLS
%   (none)
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

p = inputParser;
addParameter(p, 'yes', false);
parse(p, varargin{:});
deleted = {};

survey_folder = regexprep(char(survey_folder), '[\\/]+$', '');
if ~isfolder(fullfile(survey_folder, 'raw'))
    error('MODprocess_reset_survey:notSurvey', '%s has no raw/ - not a survey folder.', survey_folder);
end
lock = fullfile(fileparts(survey_folder), 'realtime', 'worker.lock');
if isfile(lock)
    error('MODprocess_reset_survey:workerRunning', ['The realtime worker is running (%s). Stop it first ' ...
        '(Stop in the monitor, or {"command": "stop"} in control.json).'], lock);
end

targets = {fullfile(survey_folder, 'L0'), fullfile(survey_folder, 'processed'), ...
    fullfile(survey_folder, 'meta', 'ctd_calibration.mat')};
targets = targets(cellfun(@(t) isfolder(t) || isfile(t), targets));
if isempty(targets)
    fprintf('Nothing to delete in %s - it will be processed from raw.\n', survey_folder);
    return
end
fprintf('This deletes, so %s is reprocessed from raw (raw/ and the ymls are kept):\n', survey_folder);
for k = 1:numel(targets)
    fprintf('  %s\n', targets{k});
end
runs = dir(fullfile(survey_folder, 'processed'));
runs = {runs([runs.isdir] & ~startsWith({runs.name}, '.')).name};
if ~isempty(runs)
    fprintf('  (processed/ holds the runs: %s)\n', strjoin(runs, ', '));
end
if ~p.Results.yes
    if batchStartupOptionUsed
        error('MODprocess_reset_survey:noPrompt', 'Can''t ask here - run it with ''yes'', true to delete.');
    end
    if ~strcmpi(strtrim(input('Delete these? y/n: ', 's')), 'y')
        fprintf('Nothing deleted.\n');
        return
    end
end
for k = 1:numel(targets)
    if isfolder(targets{k})
        rmdir(targets{k}, 's');
    else
        delete(targets{k});
    end
end
deleted = targets;
fprintf('Deleted. Restart the worker (or run MODprocess_deployment(''%s'')) to reprocess from raw.\n', survey_folder);
end %end function
