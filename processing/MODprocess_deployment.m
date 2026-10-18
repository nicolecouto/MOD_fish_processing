function summary = MODprocess_deployment(target, varargin)
% MODprocess_deployment        Part of MOD_fish_processing
%
% MODprocess_deployment(processed_root, 'watch', true)          - realtime worker
% summary = MODprocess_deployment(survey_folder)                 - one pass, run 'realtime'
% summary = MODprocess_deployment(survey_folder, 'run', 'nfft512', ...) - a postprocessing run
% summary = MODprocess_deployment('<survey>/meta/meta_data_<run>.yml', ...) - continue that run
%
% DESCRIPTION
%   The one driver for realtime processing and postprocessing: the same
%   stages, run by the same MODprocess_all_* functions, with switches. See
%   docs/workflow/processing_data.md.
%
%   A processing run is one yml, <survey>/meta/meta_data_<run>.yml, plus
%   one output folder, <survey>/processed/<run>/ (meta/, L1/, L2/,
%   profiles_L1/, profiles_L2/). raw/ and L0/ stay in the survey folder,
%   shared by every run. The realtime worker's run is 'realtime'; any other
%   name is a postprocessing run. Every run's yml is dev1_setup.yml + one
%   cruise yml ('cruise_yml'; default cruise_meta_data.yml), rebuilt each
%   pass (MODsetup_build_yaml.m) - to try other settings, give another
%   cruise yml and a new run name. A run is continued by giving its name
%   or its yml; it remembers its cruise yml and L1_from.
%
%   Each pass, for each survey it's looking after:
%     0. route new raw files from the cruise-wide raw folder into
%        <survey>/raw/ (MODutil_route_raw_by_survey.m) - when given
%        processed_root
%     1. build the run yml from dev1_setup.yml + cruise_meta_data.yml
%        (MODsetup_build_yaml.m) and check it (MODsetup_preflight.m), which
%        says what the run reads and writes. Missing parameters: the survey
%        waits ("waiting for parameters") until they're added. Nothing
%        prompts unless 'ask' is true.
%     2. modraw -> L0 -> L1 (MODprocess_all_modraw_to_L0.m,
%        MODprocess_all_L0_to_L1.m) - not for a run with L1_from. If the
%        CTD calibration changes within the survey (another SN or
%        calibration date, see MODprocess_all_modraw_to_L0.m), the whole
%        worker stops ("stopped: CTD calibration changed" in status.json,
%        "stop" in control.json): fix the .CAL file, reset the survey
%        (MODprocess_reset_survey.m) and restart the worker
%     3. the cast table, processed/<run>/meta/casts.mat
%        (MODprocess_L1_update_cast_table.m)
%     4. 'by' 'file' (realtime): L1 -> L2, whole L1 files tiled into scans.
%        'by' 'profile' (postprocessing): profiles_L1/ from the cast table
%        (MODprocess_all_extract_profiles.m), then -> profiles_L2/.
%     5. the grid: one column per cast, in depth bins (MODprocess_grid.m),
%        from L1/L2 by file or profiles_L1/profiles_L2 by profile
%     6. _README.txt in each level folder (MODutil_write_folder_readme.m)
%   Then, once per pass over processed_root (realtime run, with L1):
%     7. the cruise twist count, <processed_root>/twist/twist_time_series.mat
%        (MODprocess_cruise_twist.m): every survey on the winch spool joined, restarting at
%        each winch spool change
%   'from' and 'until' run only some of the stages (L0, L1, casts, L2,
%   grid); 'until', 'yml' only builds and checks the yml (for every stage
%   from 'from' on).
%
%   A file that fails doesn't stop anything: it's logged, listed in the
%   run's meta/log/problems.json, retried on later passes (it's only
%   logged again when the error changes), and cleared from the list once
%   it goes through. A stage that fails as a whole is listed the same way,
%   and the next stage still runs.
%
%   With 'watch' true (given processed_root), it repeats until stopped:
%   one pass over every survey that has something new, then a wait of
%   'poll_s' seconds. The wait starts after a pass ends, so passes never
%   overlap however long they take. The newest survey (the last one set up
%   by Start New Deployment) is the active one; older ones are still
%   finished off when files arrive for them. The newest raw file, which is
%   usually still growing, is redone at most every 'regrow_min_s' seconds.
%   Started with matlab -batch, it never prompts. Watching is for the
%   'realtime' run only.
%
%   Control and status - files in <processed_root>/realtime/ (not written
%   for a one-off pass on one survey):
%     control.json   - {"command": "run" | "pause" | "stop"}, written by the
%                      monitor app (or by hand); read every second during
%                      the wait and between stages. Stop finishes the
%                      current stage, then exits. The worker sets it to
%                      "run" when it starts.
%     worker.lock    - PID and host of the running worker; a second worker
%                      won't start while that PID is alive ('force' to
%                      override). Removed when the worker exits.
%     status.json    - rewritten after each survey and each pass: worker
%                      state, active survey, per-survey state and file
%                      counts, lag behind the newest raw file, problems,
%                      missing parameters, unrouted raw files
%     cruise_log.txt - one line per notable event, for the whole cruise
%   and per run, in <survey>/processed/<run>/meta/log/:
%     processing.log - everything printed while that run was processed
%                      (Matlab's diary), including warnings
%     problems.json  - files/stages currently failing
%
% INPUTS
%   target - one of:
%              processed_root (folder of survey folders): every survey in it
%              a survey folder (has meta/dev1_setup.yml)
%              a run's yml, <survey>/meta/meta_data_<run>.yml - that run
%                (the run name comes from the file name)
%              a survey's meta/dev1_setup.yml - that survey
%   Name-value options:
%     'run'                  - run name, default 'realtime' (or from a run
%                              yml target)
%     'cruise_yml'           - the cruise yml this run's settings come from.
%                              [] (default) = the one the run was built
%                              with, or cruise_meta_data.yml next to the
%                              survey folder for a new run
%     'L1_from'              - use this run's L1 instead of making one (L1
%                              settings must match). [] (default) = as the
%                              run already has it; '' = its own L1
%     'from', 'until'        - first and last stage: 'L0', 'L1', 'casts',
%                              'L2', 'grid' (default 'L0' to 'grid'); 'until' 'yml'
%                              only builds and checks the yml
%     'ask'                  - default true in an interactive Matlab when
%                              not watching: ask for missing parameters
%                              and an unreachable calibrations_root
%     'by'                   - 'file' (default) or 'profile'
%     'watch'                - default false (one pass). true: repeat until
%                              stopped (needs processed_root)
%     'poll_s'               - default 30: wait after each pass [s]
%     'regrow_min_s'         - default 120 when watching, else 0: the newest
%                              file is redone at most this often [s]
%                              (0 = always, as a one-off run does)
%     'fpo7_refit_new_files' - default 10 when watching, else 0: refit the
%                              FP07 calibration after this many more L1 files
%     'raw_dir'              - cruise-wide raw folder to route from. Default
%                              <processed_root>/RAW_full_cruise if it
%                              exists; '' = don't route (use raw/ as is)
%     'force'                - default false. true: start even if worker.lock
%                              says another worker is running
%
% OUTPUTS
%   summary - struct array, one per survey processed in the last pass (see
%             status.json's "surveys" for the fields; .preflight is the
%             MODsetup_preflight.m report, with .plan)
%
% CALLED BY
%   Start Realtime Processing.command (watch); templates/MODtemplate_postprocess.m
%   and templates/MODtemplate_postprocess_by_stage.m; by hand
%
% CALLS
%   MODutil_route_raw_by_survey.m, MODutil_list_surveys.m,
%   MODsetup_build_yaml.m, MODsetup_preflight.m,
%   MODprocess_all_modraw_to_L0.m, MODprocess_all_L0_to_L1.m,
%   MODprocess_L1_update_cast_table.m, MODprocess_all_L1_to_L2.m,
%   MODprocess_all_extract_profiles.m, MODutil_write_folder_readme.m,
%   MODprocess_cruise_twist.m
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

ip = inputParser;
addParameter(ip, 'by', 'file', @(s) any(strcmp(s, {'file', 'profile'})));
addParameter(ip, 'watch', false);
addParameter(ip, 'poll_s', 30);
addParameter(ip, 'regrow_min_s', []);
addParameter(ip, 'fpo7_refit_new_files', []);
addParameter(ip, 'raw_dir', []);
addParameter(ip, 'force', false);
addParameter(ip, 'run', '');
addParameter(ip, 'cruise_yml', []);
addParameter(ip, 'L1_from', []);
addParameter(ip, 'from', 'L0');
addParameter(ip, 'until', 'grid');
addParameter(ip, 'ask', []);
parse(ip, varargin{:});
opts = ip.Results;
STAGES = {'L0', 'L1', 'casts', 'L2', 'grid'};
i_from = find(strcmp(STAGES, opts.from));
i_until = find(strcmp([{'yml'}, STAGES], opts.until)) - 1;
if isempty(i_from) || isempty(i_until)
    error('MODprocess_deployment:badStage', ['from must be one of %s, and until one of yml, %s ' ...
        '(got from ''%s'', until ''%s'').'], strjoin(STAGES, ', '), strjoin(STAGES, ', '), opts.from, opts.until);
end
if i_until >= 1 && i_until < i_from
    error('MODprocess_deployment:badStage', 'until (''%s'') comes before from (''%s'').', opts.until, opts.from);
end
opts.stages = STAGES(i_from:i_until);
% what preflight checks: the stages that run - or, for 'until' 'yml' (a
% check before running), every stage from 'from' on
opts.check_stages = opts.stages;
if i_until < i_from
    opts.check_stages = STAGES(i_from:end);
end
if isempty(opts.ask)
    opts.ask = ~opts.watch && ~batchStartupOptionUsed && feature('ShowFigureWindows');
end
if isempty(opts.regrow_min_s)
    opts.regrow_min_s = 120 * opts.watch;
end
if isempty(opts.fpo7_refit_new_files)
    opts.fpo7_refit_new_files = 10 * opts.watch;
end

[processed_root, only_survey_folder, yml_run] = resolve_target(target);
if ~isempty(yml_run)
    if ~isempty(opts.run) && ~strcmp(opts.run, yml_run)
        error('MODprocess_deployment:runMismatch', 'The yml is run ''%s'' but ''run'' says ''%s''.', yml_run, opts.run);
    end
    opts.run = yml_run;
end
if isempty(opts.run)
    opts.run = 'realtime';
end
% checked here as well as in MODsetup_build_yaml.m: the run's log folder is
% made before the yml is built
for name = {opts.run, char(string(opts.L1_from))}
    if ~isempty(name{1}) && isempty(regexp(char(name{1}), '^[A-Za-z0-9_-]+$', 'once'))
        error('MODprocess_deployment:badRunName', ['Run name "%s" can only have letters, digits, _ and - ' ...
            '(it names a folder in processed/).'], char(name{1}));
    end
end
if opts.watch && ~isempty(only_survey_folder)
    error('MODprocess_deployment:watchNeedsRoot', ...
        'watch needs the processed root (the folder of survey folders), not one survey.');
end
if opts.watch && (~strcmp(opts.run, 'realtime') || opts.ask || ~isequal(opts.stages, STAGES))
    error('MODprocess_deployment:watchIsRealtime', ['watch is for the realtime run only, all stages, ' ...
        'never asking - run postprocessing without watch.']);
end
% default raw folder: looked for every pass, since the rsync may create it
% after the worker starts
default_raw_dir = isempty(opts.raw_dir) && isempty(only_survey_folder);
if isempty(opts.raw_dir)
    opts.raw_dir = '';
end

% Worker files (status, control, lock, cruise log) - not for a one-off pass
% on one survey, so a copied survey folder gets nothing written beside it
rt_dir = '';
if isempty(only_survey_folder)
    rt_dir = fullfile(processed_root, 'realtime');
    if ~isfolder(rt_dir)
        mkdir(rt_dir);
    end
end
if opts.watch
    take_worker_lock(rt_dir, opts.force);
    release_lock = onCleanup(@() delete_if_file(fullfile(rt_dir, 'worker.lock')));
    write_json(fullfile(rt_dir, 'control.json'), struct('command', 'run'));
    cruise_log(rt_dir, sprintf('Worker started (by %s, poll %g s, regrow %g s) on %s', ...
        opts.by, opts.poll_s, opts.regrow_min_s, processed_root));
end

last_signature = containers.Map(); % survey folder -> raw/ signature when caught up
sig_seen = containers.Map();       % survey folder -> {signature, first time seen}
status = struct('updated_utc', '', 'worker_state', 'running', 'by', opts.by, 'run', opts.run, ...
    'processed_root', processed_root, 'active_survey', '', 'pass_s', NaN, 'poll_s', opts.poll_s, ...
    'surveys', {{}}, 'unrouted', {{}}, 'broken_links', {{}}, 'warnings', {{}});
summary = [];

while true
    command = read_command(rt_dir, opts.watch);
    if strcmp(command, 'stop')
        break
    end
    if strcmp(command, 'pause')
        status.worker_state = 'paused';
        status.updated_utc = utc_now();
        write_status(rt_dir, status);
        if ~wait_or_stop(rt_dir, opts.poll_s)
            break
        end
        continue
    end
    status.worker_state = 'running';
    pass_start = tic;
    stopped = false;
    try % nothing in a pass stops the worker - it logs, waits and tries again

    % 0. route raw files into their survey folders
    if default_raw_dir && isfolder(fullfile(processed_root, 'RAW_full_cruise'))
        opts.raw_dir = fullfile(processed_root, 'RAW_full_cruise');
    end
    if ~isempty(opts.raw_dir)
        try
            routed = MODutil_route_raw_by_survey(opts.raw_dir, processed_root);
            if ~isempty(routed.linked)
                cruise_log(rt_dir, sprintf('Linked %d new raw file(s): %s', numel(routed.linked), ...
                    strjoin(routed.linked, ', ')));
            end
            status.unrouted = arrayfun(@(u) sprintf('%s (%s)', u.file, u.reason), routed.unrouted, ...
                'UniformOutput', false);
            status.broken_links = routed.broken;
        catch ME
            cruise_log_once(rt_dir, 'routing', sprintf('Routing raw files failed: %s', ME.message));
        end
    end

    % which surveys
    if ~isempty(only_survey_folder)
        [~, name] = fileparts(only_survey_folder);
        surveys = struct('survey', name, 'folder', only_survey_folder);
    else
        [surveys, status.warnings] = MODutil_list_surveys(processed_root);
    end
    if ~isempty(surveys)
        [~, status.active_survey] = fileparts(surveys(end).folder); % folder name, as in status.surveys
    end

    summary = [];
    for iS = 1:numel(surveys)
        if ~strcmp(read_command(rt_dir, opts.watch), 'run')
            stopped = true;
            break
        end
        folder = surveys(iS).folder;
        if ~isfolder(folder)
            continue % renamed or deleted since it was listed
        end
        sig = raw_signature(fullfile(folder, 'raw'));
        key = folder;
        if opts.watch && isKey(last_signature, key) && strcmp(last_signature(key), sig)
            continue % nothing new for this survey since a pass that finished its work
        end
        if ~isKey(sig_seen, key) || ~strcmp(sig_seen(key).sig, sig)
            sig_seen(key) = struct('sig', sig, 'since', now);
        end
        try
            s = run_survey_pass(folder, opts, rt_dir);
        catch ME
            cruise_log_once(rt_dir, ['pass:' folder], sprintf('%s: pass failed: %s', surveys(iS).survey, ME.message));
            continue
        end
        summary = [summary, s]; %#ok<AGROW>
        status.surveys = merge_survey_status(status.surveys, s);
        status.updated_utc = utc_now();
        if ~isempty(s.stop_message)
            % CTD calibration changed: ALL STOP - nothing more is processed
            % (any survey) until the .CAL is fixed, the survey reset and the
            % worker restarted
            status.worker_state = 'stopped: CTD calibration changed';
            status.warnings{end+1} = sprintf('%s: %s', s.survey, s.stop_message);
            cruise_log(rt_dir, sprintf('%s: %s\nThe worker has stopped.', s.survey, s.stop_message));
            if opts.watch
                write_json(fullfile(rt_dir, 'control.json'), struct('command', 'stop'));
            end
            write_status(rt_dir, status);
            stopped = true;
            break
        end
        write_status(rt_dir, status);
        % Caught up = nothing to do, and raw/ unchanged for long enough that
        % no newest-file redo can still be held back by regrow_min_s at any
        % level (L0, L1 and L2 each age separately); then skip this survey
        % until raw/ changes. (A yml or calibration edit alone doesn't wake
        % it - only a change in raw/ does.)
        unchanged_s = (now - sig_seen(key).since) * 86400;
        if strcmp(s.state, 'ok') && s.n_processed == 0 && unchanged_s > 2 * opts.regrow_min_s + s.pass_s
            last_signature(key) = sig;
        elseif isKey(last_signature, key)
            remove(last_signature, key);
        end
    end

    % 7. the cruise twist count, over every survey on the winch spool
    if isempty(only_survey_folder) && strcmp(opts.run, 'realtime') && ismember('L1', opts.stages) && ~stopped
        try
            tw = MODprocess_cruise_twist(processed_root);
            if isfield(tw, 'warnings')
                new = setdiff(tw.warnings, status.warnings, 'stable'); % survey-list warnings are there already
                for iW = 1:numel(new)
                    cruise_log_once(rt_dir, ['twist:' new{iW}], ['Twist: ' new{iW}]);
                end
                status.warnings = [status.warnings, new];
            end
        catch ME
            cruise_log_once(rt_dir, 'twist', sprintf('Cruise twist count failed: %s', ME.message));
        end
    end

    status.pass_s = toc(pass_start);
    status.updated_utc = utc_now();
    write_status(rt_dir, status);
    catch ME
        if ~opts.watch
            rethrow(ME)
        end
        cruise_log_once(rt_dir, 'pass', sprintf('Pass failed (will try again): %s', ME.message));
    end
    if ~opts.watch || stopped && strcmp(read_command(rt_dir, true), 'stop')
        break
    end
    if ~wait_or_stop(rt_dir, opts.poll_s)
        break
    end
end

if opts.watch
    if ~startsWith(status.worker_state, 'stopped:')
        status.worker_state = 'stopped';
    end
    status.updated_utc = utc_now();
    write_status(rt_dir, status);
    cruise_log(rt_dir, 'Worker stopped');
end
end %end function

%% ------------------------------------------------------------------ one survey
function s = run_survey_pass(folder, opts, rt_dir)
[~, survey] = fileparts(folder);
s = struct('survey', survey, 'run', opts.run, 'state', 'ok', 'last_pass_utc', utc_now(), 'pass_s', NaN, ...
    'n_raw', 0, 'n_L0', 0, 'n_L1', 0, 'n_L2', 0, 'n_casts', 0, 'newest_raw_utc', '', 'lag_s', NaN, ...
    'n_processed', 0, 'n_problems', 0, 'missing', {{}}, 'notes', {{}}, 'preflight', [], 'stop_message', '');
meta_dir = fullfile(folder, 'meta');
log_dir = fullfile(folder, 'processed', opts.run, 'meta', 'log');
if ~isfolder(log_dir)
    mkdir(log_dir);
end
t0 = tic;
diary_file = fullfile(log_dir, 'processing.log');
diary(diary_file);
diary on
diary_off = onCleanup(@() diary('off'));
fprintf('\n==== %s UTC | %s | run %s | pass (by %s) ====\n', utc_now(), survey, opts.run, opts.by);

problems_file = fullfile(log_dir, 'problems.json');
known = read_problems(problems_file);
current = struct('file', {}, 'stage', {}, 'identifier', {}, 'message', {});
done = struct('stage', {}, 'files', {});

% 1. the run yml + preflight
try
    [run_yml, build_info] = MODsetup_build_yaml(meta_dir, opts.cruise_yml, opts.run, 'L1_from', opts.L1_from);
    [report, metadata] = MODsetup_preflight(run_yml, opts.ask, 'stages', opts.check_stages, 'ask_paths', opts.ask);
catch ME
    current(end+1) = stage_problem('build_yaml', ME);
    s = finish(s, 'error', current, known, done, problems_file, rt_dir, t0);
    return
end
s.preflight = report;
s.notes = [report.problems, report.notes];
show_plan(run_yml, report, ~opts.watch || build_info.written);
if isempty(metadata)
    % the yml (or a calibration file it names) can't be read
    current(end+1) = struct('file', run_yml, 'stage', 'read_yaml', 'identifier', '', ...
        'message', strjoin(report.problems, ' '));
    s = finish(s, 'error', current, known, done, problems_file, rt_dir, t0);
    return
end
done(end+1) = struct('stage', 'build_yaml', 'files', {{}}); % these went through
done(end+1) = struct('stage', 'read_yaml', 'files', {{run_yml}});
stages = opts.stages;
if ~isempty(metadata.run.L1_from)
    stages = setdiff(stages, {'L0', 'L1'}, 'stable'); % L1 is the other run's
end
if ~isempty(metadata.run.L1_from) && any(contains(report.problems, 'L1_from'))
    % the other run's L1 isn't this run's L1 - nothing to build on
    current(end+1) = struct('file', run_yml, 'stage', 'L1_from', 'identifier', '', ...
        'message', strjoin(report.problems(contains(report.problems, 'L1_from')), ' '));
    s = finish(s, 'error', current, known, done, problems_file, rt_dir, t0);
    return
end
if ~isempty(metadata.run.L1_from)
    done(end+1) = struct('stage', 'L1_from', 'files', {{run_yml}}); % clears an earlier L1_from problem
end
% Missing parameters are reported first - as soon as the survey is set up,
% before any data arrives, so there's time to add them
s.missing = report.missing;
if ~isempty(report.missing) && ~isempty(opts.stages)
    fprintf('Waiting for parameters: %s\n', strjoin(report.missing, ', '));
    s = finish(s, 'waiting for parameters', current, known, done, problems_file, rt_dir, t0);
    return
end
if isempty(stages)
    s = finish(s, 'ok', current, known, done, problems_file, rt_dir, t0); % 'until' 'yml'
    return
end
if any(ismember(stages, {'L0', 'L1'})) && isempty(list_raw(fullfile(folder, 'raw')))
    fprintf('No raw files in raw/ yet.\n');
    s = finish(s, 'waiting for raw files', current, known, done, problems_file, rt_dir, t0);
    return
end
redo = {'newest_min_redo_s', opts.regrow_min_s, 'continue_on_error', true};

% 2. modraw -> L0 -> L1
if ismember('L0', stages)
    try
        [~, p, d] = MODprocess_all_modraw_to_L0(metadata.paths.raw, metadata.paths.L0, [], metadata, redo{:});
        current = [current, p];
        done(end+1) = struct('stage', 'modraw_to_L0', 'files', {fullfile(metadata.paths.raw, d)});
        s.n_processed = s.n_processed + numel(d);
    catch ME
        current(end+1) = stage_problem('modraw_to_L0', ME);
        if strcmp(ME.identifier, 'MODprocess_all_modraw_to_L0:ctdCalibrationChanged')
            % not just a bad file: nothing after L0 is right until the .CAL
            % file is fixed and the survey reprocessed from raw - the worker
            % stops (see the survey loop)
            s.stop_message = ME.message;
            s = finish(s, 'stopped: CTD calibration changed', current, known, done, problems_file, rt_dir, t0);
            return
        end
    end
    if stop_requested(rt_dir, opts.watch)
        s = finish(s, 'stopped mid-pass', current, known, done, problems_file, rt_dir, t0);
        return
    end
end
if ismember('L1', stages)
    try
        [~, p, d] = MODprocess_all_L0_to_L1(metadata.paths.L0, metadata, metadata.paths.L1, false, redo{:}, ...
            'fpo7_refit_new_files', opts.fpo7_refit_new_files);
        current = [current, p];
        done(end+1) = struct('stage', 'L0_to_L1', 'files', {fullfile(metadata.paths.L0, d)});
        s.n_processed = s.n_processed + numel(d);
    catch ME
        current(end+1) = stage_problem('L0_to_L1', ME);
    end
    if stop_requested(rt_dir, opts.watch)
        s = finish(s, 'stopped mid-pass', current, known, done, problems_file, rt_dir, t0);
        return
    end
end

% 3. cast table
casts = [];
if ismember('casts', stages) && ~isfile(fullfile(metadata.paths.L1_meta, 'pressure_time_series.mat'))
    fprintf('No %s yet (made with L1) - no cast table.\n', fullfile(metadata.paths.L1_meta, 'pressure_time_series.mat'));
end
if ismember('casts', stages) && isfile(fullfile(metadata.paths.L1_meta, 'pressure_time_series.mat'))
    try
        [casts, metadata] = MODprocess_L1_update_cast_table(metadata);
        done(end+1) = struct('stage', 'cast_table', 'files', {{}});
    catch ME
        current(end+1) = stage_problem('cast_table', ME);
    end
end
if isempty(casts) && isfile(fullfile(metadata.paths.meta, 'casts.mat'))
    saved = load(fullfile(metadata.paths.meta, 'casts.mat'), 'casts');
    casts = saved.casts;
end
s.n_casts = numel(casts);
if stop_requested(rt_dir, opts.watch)
    s = finish(s, 'stopped mid-pass', current, known, done, problems_file, rt_dir, t0);
    return
end

% 4. -> L2 by file, or profiles -> profiles_L2
if ismember('L2', stages)
    try
        if strcmp(opts.by, 'file')
            [~, p, d] = MODprocess_all_L1_to_L2(metadata.paths.L1, metadata, metadata.paths.L2, false, redo{:});
            done(end+1) = struct('stage', 'L1_to_L2', 'files', {fullfile(metadata.paths.L1, d)});
        else
            try
                MODprocess_all_extract_profiles(metadata);
                done(end+1) = struct('stage', 'extract_profiles', 'files', {{}});
            catch ME
                current(end+1) = stage_problem('extract_profiles', ME);
            end
            [~, p, d] = MODprocess_all_L1_to_L2(metadata.paths.profiles_L1, metadata, metadata.paths.profiles_L2, false, redo{:});
            done(end+1) = struct('stage', 'L1_to_L2', 'files', {fullfile(metadata.paths.profiles_L1, d)});
        end
        current = [current, p];
        s.n_processed = s.n_processed + numel(d);
    catch ME
        current(end+1) = stage_problem('L1_to_L2', ME);
    end
end

% 5. grid
if ismember('grid', stages) && ~isfile(fullfile(metadata.paths.meta, 'casts.mat'))
    fprintf('No %s yet - no grid.\n', fullfile(metadata.paths.meta, 'casts.mat'));
end
if ismember('grid', stages) && isfile(fullfile(metadata.paths.meta, 'casts.mat'))
    try
        MODprocess_grid(metadata, opts.by);
        done(end+1) = struct('stage', 'grid', 'files', {{}});
    catch ME
        current(end+1) = stage_problem('grid', ME);
    end
end

% 6. folder READMEs (the L1 one only when this run made the L1)
levels = {'raw', 'L0', 'L1', 'L2'};
if ~isempty(metadata.run.L1_from)
    levels = {'raw', 'L0', 'L2'};
end
if strcmp(opts.by, 'profile')
    levels = [levels, {'profiles_L1', 'profiles_L2'}];
end
levels{end+1} = 'grid';
readme_ok = true;
for lv = levels
    try
        if isfolder(metadata.paths.(lv{1}))
            MODutil_write_folder_readme(metadata.paths.(lv{1}), lv{1}, metadata);
        end
    catch ME
        if readme_ok % one readme problem per pass is enough
            current(end+1) = stage_problem('readme', ME); %#ok<AGROW>
        end
        readme_ok = false;
    end
end
if readme_ok
    done(end+1) = struct('stage', 'readme', 'files', {{}});
end

% counts and lag
s.n_raw = numel(list_raw(metadata.paths.raw));
s.n_L0 = count_files(metadata.paths.L0, {'*.mat'});
s.n_L1 = count_files(metadata.paths.L1, {'*.mat'});
s.n_L2 = count_files(metadata.paths.L2, {'*.mat'});
raw = list_raw(metadata.paths.raw);
if ~isempty(raw)
    newest = max([raw.datenum]);
    newest_utc = datetime(newest, 'ConvertFrom', 'datenum', 'TimeZone', 'local'); % file times are local
    newest_utc.TimeZone = 'UTC';
    s.newest_raw_utc = char(newest_utc, 'yyyy-MM-dd HH:mm:ss');
    products = dir(fullfile(metadata.paths.L2, '*.mat'));
    if strcmp(opts.by, 'profile')
        products = dir(fullfile(metadata.paths.profiles_L2, '*.mat'));
    end
    if ~isempty(products)
        % how far the newest product is behind the newest raw data
        s.lag_s = max(0, (newest - max([products.datenum])) * 86400);
    end
end
state = 'ok';
if ~isempty(current)
    state = 'ok with problems';
end
s = finish(s, state, current, known, done, problems_file, rt_dir, t0);
end

%% Update problems.json, the counts and the log at the end of a survey pass
function s = finish(s, state, current, known, done, problems_file, rt_dir, t0)
now_utc = utc_now();
merged = struct('file', {}, 'stage', {}, 'identifier', {}, 'message', {}, 'first_seen_utc', {}, 'last_seen_utc', {});
% still failing, or new
for c = current
    k = find(strcmp({known.file}, c.file) & strcmp({known.stage}, c.stage), 1);
    first = now_utc;
    if ~isempty(k)
        first = known(k).first_seen_utc;
    end
    if isempty(k) || ~strcmp(known(k).message, c.message)
        cruise_log(rt_dir, sprintf('%s: %s problem%s: %s', s.survey, c.stage, ...
            file_suffix(c.file), c.message));
    end
    merged(end+1) = struct('file', c.file, 'stage', c.stage, 'identifier', c.identifier, ...
        'message', c.message, 'first_seen_utc', first, 'last_seen_utc', now_utc); %#ok<AGROW>
end
% earlier problems not seen this pass: dropped if that file (or stage) went
% through, kept otherwise (e.g. the stage didn't get to it)
for k = 1:numel(known)
    if any(strcmp({merged.file}, known(k).file) & strcmp({merged.stage}, known(k).stage))
        continue
    end
    i_done = find(strcmp({done.stage}, known(k).stage), 1);
    if isempty(known(k).file)
        resolved = ~isempty(i_done); % stage-level: the stage ran this pass
    else
        resolved = ~isempty(i_done) && any(strcmp(done(i_done).files, known(k).file));
    end
    if resolved
        cruise_log(rt_dir, sprintf('%s: %s%s now goes through', s.survey, known(k).stage, file_suffix(known(k).file)));
    else
        merged(end+1) = known(k); %#ok<AGROW>
    end
end
write_json(problems_file, merged);
s.n_problems = numel(merged);
s.state = state;
s.pass_s = toc(t0);
fprintf('==== %s | %s | %s, %d file(s) processed, %d problem(s), %.1f s ====\n', ...
    utc_now(), s.survey, state, s.n_processed, s.n_problems, s.pass_s);
end

%% ------------------------------------------------------------------ helpers
%% Print preflight's plan (which yml, inputs, outputs) and its problems and
% notes - every time for a one-off pass; while watching, only when the yml
% was (re)written or what's reported changed, so the log isn't flooded
function show_plan(run_yml, report, always)
persistent last
if isempty(last)
    last = containers.Map();
end
text = strjoin([report.plan(:)', strcat({'  Problem: '}, report.problems), strcat({'  Note: '}, report.notes)], newline);
if always || ~isKey(last, run_yml) || ~strcmp(last(run_yml), text)
    fprintf('%s\n', text);
end
last(run_yml) = text;
end

function [processed_root, survey_folder, yml_run] = resolve_target(target)
target = char(target);
survey_folder = '';
yml_run = '';
if isfile(target) && endsWith(target, '.yml')
    survey_folder = fileparts(fileparts(target)); % <survey>/meta/x.yml
    [~, name] = fileparts(target);
    tok = regexp(name, '^meta_data_(.+)$', 'tokens', 'once');
    if ~isempty(tok)
        yml_run = tok{1};
    end
elseif isfolder(target) && isfile(fullfile(target, 'meta', 'dev1_setup.yml'))
    survey_folder = target;
elseif ~isfolder(target)
    error('MODprocess_deployment:badTarget', '%s is not a folder or a yml file.', target);
end
if isempty(survey_folder)
    processed_root = target;
else
    processed_root = fileparts(survey_folder);
end
end

%% One worker per processed_root: realtime/worker.lock holds the PID of the
% Matlab running it. Another live PID on this computer -> refuse to start
% ('force' overrides). A lock left by a crashed worker (PID gone) is taken over.
function take_worker_lock(rt_dir, force)
lock_file = fullfile(rt_dir, 'worker.lock');
if isfile(lock_file) && ~force
    try
        lock = jsondecode(fileread(lock_file));
        [~, host] = system('hostname');
        same_host = strcmp(strtrim(host), lock.host);
        alive = system(sprintf('kill -0 %d 2>/dev/null', lock.pid)) == 0;
        if ~same_host || alive
            error('MODprocess_deployment:otherWorker', ['Another worker is running (%s: PID %d on %s, ' ...
                'started %s UTC). Stop it first ({"command": "stop"} in control.json), or start with ' ...
                '''force'', true if it is not really running.'], lock_file, lock.pid, lock.host, lock.started_utc);
        end
    catch ME
        if strcmp(ME.identifier, 'MODprocess_deployment:otherWorker')
            rethrow(ME)
        end
        % unreadable lock file - take it over
    end
end
[~, host] = system('hostname');
write_json(lock_file, struct('pid', feature('getpid'), 'host', strtrim(host), 'started_utc', utc_now()));
end

function delete_if_file(f)
if isfile(f)
    delete(f);
end
end

function tf = stop_requested(rt_dir, watching)
tf = strcmp(read_command(rt_dir, watching), 'stop');
end

%% Raw files in a folder, leaving out symlinks whose file has gone (dir
% still lists them, with the link's own size and time)
function d = list_raw(folder)
d = [dir(fullfile(folder, '*.modraw')); dir(fullfile(folder, '*.raw'))];
d = d(arrayfun(@(f) isfile(fullfile(folder, f.name)), d));
end

function command = read_command(rt_dir, watching)
command = 'run';
if ~watching
    return
end
f = fullfile(rt_dir, 'control.json');
if isfile(f)
    try
        c = jsondecode(fileread(f));
        if isfield(c, 'command') && any(strcmp(c.command, {'run', 'pause', 'stop'}))
            command = c.command;
        end
    catch
        % half-written by the app - treat as run, read again in a second
    end
end
end

%% Wait poll_s seconds, checking control.json every second; false = stop
function keep_going = wait_or_stop(rt_dir, poll_s)
keep_going = true;
t = tic;
while toc(t) < poll_s
    if strcmp(read_command(rt_dir, true), 'stop')
        keep_going = false;
        return
    end
    pause(min(1, max(0, poll_s - toc(t))));
end
end

function sig = raw_signature(raw_dir)
d = list_raw(raw_dir);
sig = strjoin(arrayfun(@(x) sprintf('%s:%d:%.8f', x.name, x.bytes, x.datenum), d, 'UniformOutput', false), '|');
end

function n = count_files(folder, patterns)
n = 0;
for p = patterns
    n = n + numel(dir(fullfile(folder, p{1})));
end
end

function list = merge_survey_status(list, s)
names = cellfun(@(x) x.survey, list, 'UniformOutput', false);
k = find(strcmp(names, s.survey), 1);
if isempty(k)
    list{end+1} = s;
else
    list{k} = s;
end
end

function p = stage_problem(stage, ME)
p = struct('file', '', 'stage', stage, 'identifier', ME.identifier, 'message', ME.message);
fprintf('%s FAILED: %s\n', stage, ME.message);
end

function p = read_problems(f)
p = struct('file', {}, 'stage', {}, 'identifier', {}, 'message', {}, 'first_seen_utc', {}, 'last_seen_utc', {});
if ~isfile(f)
    return
end
try
    raw = jsondecode(fileread(f));
catch
    return
end
for k = 1:numel(raw)
    r = raw(k);
    if iscell(raw)
        r = raw{k};
    end
    if ~isstruct(r)
        continue
    end
    p(end+1) = struct('file', text_field(r, 'file'), 'stage', text_field(r, 'stage'), ...
        'identifier', text_field(r, 'identifier'), 'message', text_field(r, 'message'), ...
        'first_seen_utc', text_field(r, 'first_seen_utc'), 'last_seen_utc', text_field(r, 'last_seen_utc')); %#ok<AGROW>
end
end

function t = text_field(r, f)
t = '';
if isfield(r, f) && ~isempty(r.(f))
    t = char(string(r.(f)));
end
end

function write_status(rt_dir, status)
if ~isempty(rt_dir)
    write_json(fullfile(rt_dir, 'status.json'), status);
end
end

function write_json(f, value)
tmp = [f '.tmp'];
fid = fopen(tmp, 'w');
fprintf(fid, '%s\n', jsonencode(value, 'PrettyPrint', true));
fclose(fid);
movefile(tmp, f, 'f');
end

%% cruise_log, but only when msg differs from the last one logged under key,
% so a failure that repeats every pass is logged once
function cruise_log_once(rt_dir, key, msg)
persistent last
if isempty(last)
    last = containers.Map();
end
if isKey(last, key) && strcmp(last(key), msg)
    return
end
last(key) = msg;
cruise_log(rt_dir, msg);
end

function cruise_log(rt_dir, msg)
line = sprintf('%s UTC | %s', utc_now(), msg);
fprintf('%s\n', line);
if isempty(rt_dir)
    return % one-off pass on one survey: the run's processing.log has it
end
fid = fopen(fullfile(rt_dir, 'cruise_log.txt'), 'a');
fprintf(fid, '%s\n', line);
fclose(fid);
end

function t = utc_now()
t = char(datetime('now', 'TimeZone', 'UTC', 'Format', 'yyyy-MM-dd HH:mm:ss'));
end

function s = file_suffix(file)
s = '';
if ~isempty(file)
    [~, n, e] = fileparts(file);
    s = [' (' n e ')'];
end
end

