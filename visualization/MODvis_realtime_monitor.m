classdef MODvis_realtime_monitor < handle
    % MODvis_realtime_monitor        Part of MOD_fish_processing
    %
    % app = MODvis_realtime_monitor()
    % app = MODvis_realtime_monitor(processed_root)
    %
    % The live monitor for the realtime worker (MODprocess_deployment with
    % 'watch' true), laid out after the 2018 FastCTD GUI. It only reads
    % the worker's files - <processed_root>/realtime/status.json and
    % twist/twist_time_series.mat, each survey's
    % processed/realtime/gridded/gridded.mat, meta/ and meta/log/ - and
    % refreshes every few seconds. It writes only realtime/control.json
    % (Pause, Stop) and saved PNGs, and Start launches the worker as its
    % own matlab -batch process, so closing or crashing the monitor never
    % stops processing.
    %
    %   Top:    status - worker state, survey, vehicle, winch spool, file
    %           counts, casts, lag, problems, last update.
    %   Far left: the profile of each section's variable for one cast -
    %           the cast clicked on a section, or the newest one until a
    %           click - on that section's colour range, with a magenta line
    %           at the cast on the sections. Each plot box has its
    %           section's height and depths (no x label: the section's);
    %           depth zooms move them all.
    %   Left:   4 colour sections of the grid, one column per cast (depth
    %           vs time; one cast spans its own start to end), with sigma0 contours (2+ casts; on/off and the interval in
    %           the controls). All 4 share the depth and
    %           time limits; each has its own variable (from
    %           gridded.variables, e.g. epsilon.final; epsilon, chi and microconductivity as
    %           log10, not their figures of merit; kc and fluor linear), colormap and
    %           colour range.
    %   Middle, 3 rows x 2 columns of small plots beside sections 1-3,
    %           half a section's width: left, pressure vs time over the
    %           cruise twist count (<processed_root>/twist/, every survey on
    %           the spool, restarting at each winch spool change), on the
    %           same, linked time limits, over a map of the casts (v down,
    %           ^ up, at the grid's position of each) and the GPS track
    %           (meta/gps_time_series.mat) between the survey's first cast
    %           start and last cast end, in the sections' time window and
    %           casts choice, the latest fix bigger and red, equal distances in x
    %           and y (latitude or longitude added around a straight track
    %           so the map fills its box); right, the last 5
    %           casts' T profiles and C profiles offset like a waterfall,
    %           and their T-S. Beside the 4th section, the survey's
    %           processing log (or the cruise log), problem lines in red -
    %           click a line to see all of it.
    %   Right:  Start / Pause / Stop, the worker's last preflight for the
    %           survey, and every plot setting (shown on the plots).
    %
    % processed_root defaults to processed_root in acquisition/config.yml
    % (the folder Start Realtime Processing.command uses).
    %
    % See docs/workflow/processing_data.md, "Monitor app", and
    % docs/visualization/index.md.
    %
    % Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

    properties
        Root char = ''
        Fig matlab.ui.Figure
        Timer
        RefreshS double = 10
        FontSize double = 10.5       % axes text
        NSections double = 4
        NProfiles double = 5         % casts in the T-S and T profile plots

        StatusLbl
        SectionAx                    % 1 x NSections uiaxes
        ProfileAx                    % 1 x NSections uiaxes, the selected cast's profile of each section's variable
        ProfilePanel                 % holds ProfileAx, free of a grid so they can line up with the sections
        DepthLink                    % links YLim of the sections and the profiles
        SectionCLim cell = {}        % each section's colour limits as last drawn, [] = none
        PressureAx
        TSAx
        WaterfallAx
        TwistAx
        MapAx
        CondAx
        MidGrid                      % the middle uigridlayout (its column 2 is kept square)
        LogList
        DetailLbl

        SurveyDrop
        WorkerLbl
        StartBtn
        PauseBtn
        StopBtn
        PreflightBtn
        VarDrop                      % 1 x NSections, one per section
        CmapDrop
        CMinField
        CMaxField
        DirDrop
        ZMinField
        ZMaxField
        SpanField
        EndDrop
        EndField
        ContourBox                   % sigma0 contours on/off
        ContourField                 % sigma0 contour interval [kg/m^3], empty = 10 levels
        OffsetField
        CondOffsetField
        LogDrop
        OpenTSBtn
        OpenSpecBtn
        PngBtn

        Status struct = struct()
        Grid struct = struct()
        GridFile char = ''
        GridStamp double = NaN
        ChosenVars cell = {}         % each section's last pick from its menu, kept while the grid lacks it
        SelectedTime double = NaN
        SelectedCastStart double = NaN % the clicked cast's cast_start; NaN = the newest cast
        TimeLimits double = []       % the sections' time limits, shared with pressure and twist
        Twist struct = struct()      % <processed_root>/twist/twist_time_series.mat
        TwistStamp double = NaN
    end

    properties (Constant)
        ProfileColW = 105            % main grid, column 1 [px]: the profiles
        ControlColW = 235            % main grid, column 4 [px]: the controls
        GridPad = [2 10 10 10]       % main grid padding [left bottom right top]; the profiles need no room at the left
        GridSpacing = 4              % main grid column spacing [px]
        ColorbarPad = 25            % right of the sections [px]: the colorbar labels hang outside the axes
        DefaultVars = {'sigma0', 'temperature', 'salinity_practical', 'epsilon.final'}
        DefaultCmaps = {'dense', 'thermal', 'haline', 'turbo'}
        % parula and turbo are Matlab's; the rest are cmocean's (toolbox/cmocean)
        Colormaps = {'parula', 'turbo', 'thermal', 'haline', 'dense', 'deep', 'algae', 'matter', ...
            'amp', 'tempo', 'speed', 'turbid', 'solar', 'ice', 'oxy', 'gray', 'balance', 'delta', 'curl'}
    end

    methods
        function app = MODvis_realtime_monitor(processed_root)
            if nargin < 1 || isempty(processed_root)
                processed_root = MODvis_realtime_monitor.config_root();
            end
            if isempty(processed_root) || ~isfolder(processed_root)
                error('MODvis_realtime_monitor:noRoot', ['Processed folder not found: ''%s'' - give it ' ...
                    'as the argument, or set processed_root in acquisition/config.yml.'], processed_root);
            end
            app.Root = char(processed_root);
            app.buildUI();
            app.layoutMiddle();
            app.refresh();
            app.fitWindowToSurvey(); % a past survey opens with all its casts
            app.drawPlots();
            app.Timer = timer('ExecutionMode', 'fixedSpacing', 'Period', app.RefreshS, ...
                'BusyMode', 'drop', 'TimerFcn', @(~, ~) app.refresh());
            start(app.Timer);
        end

        function delete(app)
            if ~isempty(app.Timer) && isvalid(app.Timer)
                stop(app.Timer);
                delete(app.Timer);
            end
            if ~isempty(app.Fig) && isvalid(app.Fig)
                delete(app.Fig);
            end
        end

        %% Layout
        function buildUI(app)
            app.Fig = uifigure('Name', ['Realtime monitor - ' app.Root], 'Position', [40 40 1700 1000], ...
                'CloseRequestFcn', @(~, ~) delete(app), 'AutoResizeChildren', 'off', ...
                'SizeChangedFcn', @(~, ~) app.resized());
            g = uigridlayout(app.Fig, [2 4]);
            g.Padding = app.GridPad;
            g.ColumnSpacing = app.GridSpacing;
            g.RowHeight = {40, '1x'};
            g.ColumnWidth = {app.ProfileColW, '4x', '3.5x', app.ControlColW};

            app.StatusLbl = uilabel(g, 'Text', '', 'WordWrap', 'on', 'FontSize', 12, 'FontWeight', 'bold');
            app.StatusLbl.Layout.Row = 1;
            app.StatusLbl.Layout.Column = [1 4];

            % far left: the selected cast's profiles, one beside each section,
            % placed by alignProfiles to the sections' plot boxes
            prof = uipanel(g, 'BorderType', 'none');
            prof.Layout.Row = 2;
            prof.Layout.Column = 1;
            app.ProfilePanel = prof;
            app.ProfileAx = gobjects(1, app.NSections);
            for i = 1:app.NSections
                app.ProfileAx(i) = uiaxes(prof, 'FontSize', app.FontSize - 1);
                app.ProfileAx(i).YTickLabel = {}; % the depths read off the section beside it
            end

            % left: the sections, stacked
            left = uigridlayout(g, [app.NSections 1], 'Padding', [0 0 app.ColorbarPad 0], 'RowSpacing', 2);
            left.Layout.Row = 2;
            left.Layout.Column = 2;
            app.SectionAx = gobjects(1, app.NSections);
            for i = 1:app.NSections
                app.SectionAx(i) = uiaxes(left, 'FontSize', app.FontSize);
                app.SectionAx(i).ButtonDownFcn = @(~, ev) app.pickTime(ev);
            end

            % middle, one row per section: pressure and the cruise twist count
            % (same time limits, linked) over the map of the GPS track on the left; the
            % last casts' T and C profiles and their T-S on the right; the log
            % beside the 4th section
            mid = uigridlayout(g, [app.NSections 2], 'Padding', [0 0 0 0], 'RowSpacing', 2);
            mid.Layout.Row = 2;
            mid.Layout.Column = 3;
            mid.RowHeight = repmat({'1x'}, 1, app.NSections); % rows line up with the sections
            app.MidGrid = mid;
            app.PressureAx = app.smallAxes(mid, 1, 1);
            app.TwistAx = app.smallAxes(mid, 2, 1);
            app.MapAx = app.smallAxes(mid, 3, 1);
            app.WaterfallAx = app.smallAxes(mid, 1, 2);
            app.CondAx = app.smallAxes(mid, 2, 2);
            app.TSAx = app.smallAxes(mid, 3, 2);
            % the profile and T-S plots are square; pressure and twist take the rest of the width
            for ax = [app.WaterfallAx, app.CondAx, app.TSAx]
                ax.PlotBoxAspectRatio = [1 1 1];
            end
            logs = uigridlayout(mid, [2 1], 'Padding', [0 0 0 0], 'RowHeight', {'1x', 44});
            logs.Layout.Row = 4;
            logs.Layout.Column = [1 2];
            app.LogList = uilistbox(logs, 'Items', {}, 'FontName', 'Menlo', 'FontSize', 10, ...
                'ValueChangedFcn', @(src, ~) app.showLine(src.Value));
            app.DetailLbl = uilabel(logs, 'Text', '', 'WordWrap', 'on', 'FontName', 'Menlo', 'FontSize', 10);

            % right: control panel
            n_rows = 20 + 3 * app.NSections + 9;
            c = uigridlayout(g, [n_rows 2], 'RowSpacing', 3, 'Scrollable', 'on');
            c.Layout.Row = 2;
            c.Layout.Column = 4;
            c.RowHeight = repmat({20}, 1, n_rows);
            row = 1;
            app.SurveyDrop = app.labelled(c, row, 'Survey', 'drop', {}, @(~, ~) app.surveyChanged());
            row = row + 1;
            app.WorkerLbl = uilabel(c, 'Text', 'Worker: -', 'FontWeight', 'bold');
            app.WorkerLbl.Layout.Row = row;
            app.WorkerLbl.Layout.Column = [1 2];
            row = row + 1;
            app.StartBtn = app.button(c, row, 1, 'Start', @(~, ~) app.startWorker());
            app.PauseBtn = app.button(c, row, 2, 'Pause', @(~, ~) app.sendCommand('pause'));
            row = row + 1;
            app.StopBtn = app.button(c, row, 1, 'Stop', @(~, ~) app.sendCommand('stop'));
            app.PreflightBtn = app.button(c, row, 2, 'Preflight', @(~, ~) app.showPreflight());
            row = row + 2;
            app.heading(c, row, 'All sections');
            row = row + 1;
            app.DirDrop = app.labelled(c, row, 'Casts', 'drop', {'both', 'down', 'up'}, @(~, ~) app.drawPlots());
            row = row + 1;
            app.ZMinField = app.labelled(c, row, 'Depth min [m]', 'num', NaN, @(~, ~) app.drawPlots());
            row = row + 1;
            app.ZMaxField = app.labelled(c, row, 'Depth max [m]', 'num', NaN, @(~, ~) app.drawPlots());
            row = row + 1;
            app.SpanField = app.labelled(c, row, 'Span [hours]', 'num', 6, @(~, ~) app.drawPlots());
            row = row + 1;
            app.EndDrop = app.labelled(c, row, '  ending at', 'drop', {'current time (UTC)', 'this time (UTC):'}, ...
                @(~, ~) app.drawPlots());
            row = row + 1;
            lbl = uilabel(c, 'Text', '  yyyy-mm-dd HH:MM');
            lbl.Layout.Row = row; lbl.Layout.Column = 1;
            app.EndField = uieditfield(c, 'text', 'Value', '', 'Placeholder', 'yyyy-mm-dd HH:MM', ...
                'ValueChangedFcn', @(~, ~) app.endTimeTyped());
            app.EndField.Layout.Row = row; app.EndField.Layout.Column = 2;
            row = row + 2; % a gap: the section settings start here
            lbl = uilabel(c, 'Text', 'sigma0 contours');
            lbl.Layout.Row = row; lbl.Layout.Column = 1;
            app.ContourBox = uicheckbox(c, 'Text', 'show', 'Value', true, 'ValueChangedFcn', @(~, ~) app.drawSections());
            app.ContourBox.Layout.Row = row; app.ContourBox.Layout.Column = 2;
            row = row + 1;
            app.ContourField = app.labelled(c, row, '  every [kg/m^3]', 'num', NaN, @(~, ~) app.drawSections());
            app.ContourField.Limits = [0 Inf];
            app.ContourField.LowerLimitInclusive = 'off';
            app.VarDrop = gobjects(1, app.NSections);
            app.CmapDrop = gobjects(1, app.NSections);
            app.CMinField = gobjects(1, app.NSections);
            app.CMaxField = gobjects(1, app.NSections);
            for i = 1:app.NSections
                row = row + 1;
                app.VarDrop(i) = app.labelled(c, row, sprintf('Section %d', i), 'drop', app.DefaultVars(i), ...
                    @(src, ~) app.varChosen(i, src.Value));
                row = row + 1;
                app.CmapDrop(i) = app.labelled(c, row, '  colormap', 'drop', app.Colormaps, @(~, ~) app.drawSections());
                app.CmapDrop(i).Value = app.DefaultCmaps{i};
                row = row + 1;
                lims = uigridlayout(c, [1 2], 'Padding', [0 0 0 0], 'ColumnSpacing', 4);
                lims.Layout.Row = row;
                lims.Layout.Column = 2;
                lbl = uilabel(c, 'Text', '  colour min, max');
                lbl.Layout.Row = row;
                lbl.Layout.Column = 1;
                app.CMinField(i) = uieditfield(lims, 'numeric', 'AllowEmpty', 'on', 'Value', [], ...
                    'ValueChangedFcn', @(~, ~) app.drawSections());
                app.CMaxField(i) = uieditfield(lims, 'numeric', 'AllowEmpty', 'on', 'Value', [], ...
                    'ValueChangedFcn', @(~, ~) app.drawSections());
            end
            row = row + 2;
            app.heading(c, row, 'Small plots');
            row = row + 1;
            app.OffsetField = app.labelled(c, row, 'T profile offset [degC]', 'num', NaN, @(~, ~) app.drawWaterfall());
            row = row + 1;
            app.CondOffsetField = app.labelled(c, row, 'C profile offset [S/m]', 'num', NaN, @(~, ~) app.drawWaterfall());
            row = row + 1;
            app.LogDrop = app.labelled(c, row, 'Log', 'drop', {'survey processing.log', 'cruise_log.txt'}, @(~, ~) app.refreshLog());
            row = row + 1;
            note = uilabel(c, 'Text', 'Empty = auto. Span 0 = all casts.', 'FontSize', 10);
            note.Layout.Row = row;
            note.Layout.Column = [1 2];
            row = row + 1;
            app.OpenTSBtn = app.button(c, row, [1 2], 'Open L1 (MODvis_timeseries)', @(~, ~) app.openViewer('timeseries'));
            row = row + 1;
            app.OpenSpecBtn = app.button(c, row, [1 2], 'Open L2 (MODvis_spectra)', @(~, ~) app.openViewer('spectra'));
            row = row + 1;
            app.PngBtn = app.button(c, row, [1 2], 'Save PNG', @(~, ~) app.savePng());
            row = row + 1;
            root_lbl = uilabel(c, 'Text', app.Root, 'WordWrap', 'on', 'FontSize', 9);
            root_lbl.Layout.Row = [row min(row + 1, n_rows)];
            root_lbl.Layout.Column = [1 2];
            set(findall(c, '-property', 'FontSize'), 'FontSize', 10); % a little smaller, so the plots get the room
        end

        function resized(app)
            app.layoutMiddle();
            app.alignProfiles();
        end

        function alignProfiles(app)
            % each profile's plot box at its section's height and width
            % of depth, so the depths read across; the panel and the
            % sections' grid share the main grid's row, so their y agree
            if isempty(app.ProfilePanel) || ~isvalid(app.ProfilePanel)
                return
            end
            drawnow; % the sections' titles and labels have set their boxes
            w = app.ProfilePanel.Position(3);
            for i = 1:app.NSections
                p = app.SectionAx(i).InnerPosition;
                app.ProfileAx(i).InnerPosition = [6, p(2), max(w - 12, 20), p(4)]; % no y labels: edge to edge
            end
        end

        function layoutMiddle(app)
            % column 2 of the middle as wide as a row is tall, so its plots
            % are square; column 1 (pressure, twist) gets the rest
            if isempty(app.MidGrid) || ~isvalid(app.MidGrid)
                return
            end
            pos = app.Fig.Position;
            row_h = (pos(4) - 40 - 3 * 10 - (app.NSections - 1) * 2) / app.NSections;
            fixed_w = app.ProfileColW + app.ControlColW + app.GridPad(1) + app.GridPad(3) + 3 * app.GridSpacing;
            mid_w = (pos(3) - fixed_w) * 3.5 / 7.5; % the main grid's middle column, '3.5x' of '4x' '3.5x'
            app.MidGrid.ColumnWidth = {'1x', max(120, min(row_h, 0.6 * mid_w))};
        end

        function ax = smallAxes(app, parent, row, col)
            ax = uiaxes(parent, 'FontSize', app.FontSize);
            ax.Layout.Row = row;
            ax.Layout.Column = col;
        end

        function h = button(~, parent, row, col, text, callback)
            h = uibutton(parent, 'Text', text, 'ButtonPushedFcn', callback);
            h.Layout.Row = row;
            h.Layout.Column = col;
        end

        function heading(~, parent, row, text)
            h = uilabel(parent, 'Text', text, 'FontWeight', 'bold');
            h.Layout.Row = row;
            h.Layout.Column = [1 2];
        end

        function h = labelled(~, parent, row, text, kind, value, callback)
            lbl = uilabel(parent, 'Text', text);
            lbl.Layout.Row = row; lbl.Layout.Column = 1;
            if strcmp(kind, 'drop')
                h = uidropdown(parent, 'Items', value, 'ValueChangedFcn', callback);
                if isempty(value)
                    h.Items = {''};
                end
            else
                h = uieditfield(parent, 'numeric', 'AllowEmpty', 'on', 'ValueChangedFcn', callback);
                if isnan(value)
                    h.Value = [];
                else
                    h.Value = value;
                end
            end
            h.Layout.Row = row; h.Layout.Column = 2;
        end

        %% Every few seconds
        function refresh(app)
            if isempty(app.Fig) || ~isvalid(app.Fig)
                return
            end
            try
                app.readStatus();
                app.updateStatusLine();
                twist_changed = app.loadTwist();
                if app.loadGrid()
                    app.drawPlots();
                elseif twist_changed
                    app.drawTimeSeries();
                end
                app.refreshLog();
            catch ME
                app.StatusLbl.Text = sprintf('Monitor: could not refresh (%s) - trying again in %g s.', ME.message, app.RefreshS);
            end
        end

        function readStatus(app)
            f = fullfile(app.Root, 'realtime', 'status.json');
            app.Status = struct();
            if isfile(f)
                try
                    app.Status = jsondecode(fileread(f));
                catch
                    % being rewritten - next refresh
                end
            end
            names = app.surveyNames();
            current = app.SurveyDrop.Value;
            if ~isequal(app.SurveyDrop.Items, names) && ~isempty(names)
                app.SurveyDrop.Items = names;
            end
            if isempty(current) || ~any(strcmp(names, current))
                active = app.field(app.Status, 'active_survey', '');
                if any(strcmp(names, active))
                    app.SurveyDrop.Value = active;
                elseif ~isempty(names)
                    app.SurveyDrop.Value = names{end};
                end
            end
        end

        function names = surveyNames(app)
            d = dir(fullfile(app.Root, '*', 'meta', 'dev1_setup.yml'));
            names = cell(1, numel(d));
            for i = 1:numel(d)
                [~, names{i}] = fileparts(fileparts(d(i).folder));
            end
            names = sort(names);
        end

        function s = surveyStatus(app)
            s = struct();
            list = app.field(app.Status, 'surveys', {});
            if isstruct(list)
                list = num2cell(list);
            end
            for i = 1:numel(list)
                if strcmp(app.field(list{i}, 'survey', ''), app.SurveyDrop.Value)
                    s = list{i};
                end
            end
        end

        function updateStatusLine(app)
            st = app.Status;
            s = app.surveyStatus();
            worker = app.field(st, 'worker_state', 'no status.json yet');
            if ~app.workerRunning() && any(strcmp(worker, {'running', 'paused'}))
                worker = [worker ' (no worker.lock - not running?)'];
            end
            if ~app.workerRunning()
                app.WorkerLbl.Text = 'Worker: stopped';
                app.WorkerLbl.FontColor = [0.75 0 0];
            elseif strcmp(app.field(st, 'worker_state', ''), 'paused')
                app.WorkerLbl.Text = 'Worker: paused';
                app.WorkerLbl.FontColor = [0 0 0];
            else
                app.WorkerLbl.Text = 'Worker: running';
                app.WorkerLbl.FontColor = [0 0.5 0];
            end
            vehicle = '';
            spool = '';
            yml = fullfile(app.surveyFolder(), 'meta', 'dev1_setup.yml');
            if isfile(yml)
                txt = fileread(yml);
                vehicle = app.ymlValue(txt, 'vehicle_name');
                spool = app.ymlValue(txt, 'winch_spool');
                if strcmpi(app.ymlValue(txt, 'on_winch_spool'), 'false')
                    spool = 'none (lab test)';
                end
            end
            line1 = sprintf('Worker: %s   |   %s   %s   spool %s   |   state: %s', worker, app.SurveyDrop.Value, ...
                vehicle, spool, app.field(s, 'state', '-'));
            line2 = sprintf(['raw %d  L0 %d  L1 %d  L2 %d   casts %d   lag %s   problems %d   missing %d   ' ...
                '|   updated %s UTC'], app.field(s, 'n_raw', 0), app.field(s, 'n_L0', 0), app.field(s, 'n_L1', 0), ...
                app.field(s, 'n_L2', 0), app.field(s, 'n_casts', 0), app.lagText(app.field(s, 'lag_s', NaN)), ...
                app.field(s, 'n_problems', 0), numel(app.field(s, 'missing', {})), app.field(st, 'updated_utc', '-'));
            app.StatusLbl.Text = {line1; line2};
            bad = app.field(s, 'n_problems', 0) > 0 || ~isempty(app.field(s, 'missing', {}));
            app.StatusLbl.FontColor = [0 0 0] + bad * [0.75 0 0];
        end

        function changed = loadGrid(app)
            f = fullfile(app.surveyFolder(), 'processed', 'realtime', 'gridded', 'gridded.mat');
            changed = false;
            stamp = NaN;
            if isfile(f)
                d = dir(f);
                stamp = d.datenum;
            end
            if strcmp(f, app.GridFile) && isequaln(stamp, app.GridStamp)
                return
            end
            if isfile(f)
                try
                    g = load(f);
                catch
                    return % being written - next refresh (the last grid stays up)
                end
            else
                g = struct();
            end
            app.GridFile = f;
            app.GridStamp = stamp;
            app.Grid = g;
            names = {'temperature'};
            if isfield(app.Grid, 'variables') && ~isempty(app.Grid.variables)
                v = app.Grid.variables;
                keep = arrayfun(@(x) size(app.gridField(app.Grid, x.name), 1) == numel(app.Grid.z) ...
                    && size(app.gridField(app.Grid, x.name), 2) > 0, v);
                names = {v(keep).name};
                names = names(~ismember(names, {'z', 'time', 'latitude', 'longitude', 'cast_start', 'cast_end', 'cast_complete', 'profile_number'}));
            end
            if isempty(names)
                names = {'temperature'};
            end
            % a pick the grid lacks for now (e.g. microconductivity before
            % the first downcast with scans) comes back when it's there again
            for i = 1:app.NSections
                current = app.VarDrop(i).Value;
                if numel(app.ChosenVars) >= i && ~isempty(app.ChosenVars{i})
                    current = app.ChosenVars{i};
                end
                app.VarDrop(i).Items = names;
                if any(strcmp(names, current))
                    app.VarDrop(i).Value = current;
                elseif any(strcmp(names, app.DefaultVars{i}))
                    app.VarDrop(i).Value = app.DefaultVars{i};
                else
                    app.VarDrop(i).Value = names{min(i, numel(names))};
                end
            end
            changed = true;
        end

        function varChosen(app, i, name)
            app.ChosenVars{i} = name;
            app.drawSections();
        end

        %% Plots
        function drawPlots(app)
            app.drawSections();
            app.drawTS();
            app.drawWaterfall();
            app.drawTimeSeries();
        end

        function drawTimeSeries(app)
            % pressure, the cruise twist count and the GPS track, on the same time limits
            app.drawPressure();
            app.drawTwist();
            app.drawMap();
            try
                linkaxes([app.PressureAx, app.TwistAx], 'x');
            catch
                % one of them has nothing to plot yet (no time axis)
            end
        end

        function tl = smallPlotWindow(app, t)
            % [start end] datenum for pressure and twist: the sections'
            % window; when it ends now, now (newer samples than the last
            % grid redraw still show); with no window, the data's range
            w = app.timeWindow();
            tl = app.TimeLimits;
            if ~isempty(w) && strcmp(app.EndDrop.Value, app.EndDrop.Items{1})
                tl = w;
            elseif isempty(tl)
                tl = w;
            end
            if isempty(tl) && ~isempty(t)
                tl = [min(t) max(t)];
            end
        end

        function drawSections(app)
            app.TimeLimits = [];
            k = app.selectedCast();
            for i = 1:app.NSections
                app.drawSection(i, k);
                app.drawProfile(i, k);
            end
            ok = isgraphics(app.SectionAx);
            if ~isempty(app.TimeLimits)
                linkaxes(app.SectionAx(ok), 'x');
            end
            % a depth zoom on any section or profile moves them all
            app.DepthLink = linkprop([app.SectionAx(ok), app.ProfileAx(isgraphics(app.ProfileAx))], 'YLim');
            app.alignProfiles();
        end

        function k = selectedCast(app)
            % the grid column of the clicked cast, else the newest cast in
            % the window and direction(s); [] when there is none
            k = [];
            g = app.Grid;
            if ~isfield(g, 'cast_start') || isempty(g.cast_start)
                return
            end
            if isfinite(app.SelectedCastStart)
                k = find(abs(g.cast_start - app.SelectedCastStart) < 1e-8, 1);
            end
            if isempty(k)
                idx = find(app.pickColumns());
                [~, j] = max(g.time(idx));
                k = idx(j);
            end
        end

        function drawProfile(app, i, k)
            % section i's variable for cast k, on that section's colour range
            ax = app.ProfileAx(i);
            cla(ax);
            g = app.Grid;
            name = app.VarDrop(i).Value;
            G = app.gridField(g, name);
            if isfield(g, 'z') && ~isempty(g.z)
                ax.YDir = 'reverse';
                ylim(ax, app.depthLimits(g.z)); % the sections' depths, with or without a profile
            end
            if isempty(k) || isempty(G)
                if i == 1
                    title(ax, 'no cast', 'FontSize', app.FontSize, 'FontWeight', 'normal');
                end
                return
            end
            [~, v] = app.displayed(name, G(:, k));
            plot(ax, v, g.z, 'k', 'LineWidth', 1);
            ax.YDir = 'reverse'; % plot resets the axes
            ylim(ax, app.depthLimits(g.z));
            lims = app.SectionCLim{i};
            if ~isempty(lims)
                xlim(ax, lims);
            end
            % no x label: the variable and unit are the section's
            if i == 1
                how = 'newest';
                if isfinite(app.SelectedCastStart) && abs(g.cast_start(k) - app.SelectedCastStart) < 1e-8
                    how = 'clicked';
                end
                title(ax, {app.castText(k), sprintf('(%s; x = colour range)', how)}, 'Interpreter', 'none', ...
                    'FontSize', app.FontSize, 'FontWeight', 'normal');
            end
        end

        function txt = castText(app, k)
            txt = sprintf('%s %s', datestr(app.Grid.time(k), 'mm-dd HH:MM'), app.Grid.cast_direction{k}); %#ok<DATST>
        end

        function drawSection(app, i, k)
            ax = app.SectionAx(i);
            app.SectionCLim{i} = [];
            cla(ax);
            colorbar(ax, 'off');
            g = app.Grid;
            name = app.VarDrop(i).Value;
            if ~isfield(g, 'z') || isempty(app.gridField(g, name)) || isempty(g.time)
                if i == 1
                    title(ax, sprintf('%s: no grid yet (%s)', app.SurveyDrop.Value, app.shortPath(app.GridFile)), ...
                        'Interpreter', 'none', 'FontSize', app.FontSize + 1);
                end
                return
            end
            cols = app.pickColumns();
            if nnz(cols) == 0
                title(ax, sprintf('%s: no %s casts in %s', name, app.DirDrop.Value, app.windowText()), ...
                    'Interpreter', 'none', 'FontSize', app.FontSize + 1);
                return
            end
            [t, order] = sort(g.time(cols));
            idx = find(cols);
            idx = idx(order);
            G = app.gridField(g, name);
            [label, v] = app.displayed(name, G(:, idx));
            % one cell per cast and bin: edges halfway between cast times
            % and at the bin edges, so no cast or bin is dropped; a lone
            % cast spans its own start to end
            if isscalar(t)
                t_edges = [g.cast_start(idx), g.cast_end(idx)];
            else
                dt = diff(t);
                t_edges = [t(1) - dt(1) / 2, t(1:end-1) + dt / 2, t(end) + dt(end) / 2];
            end
            z_edges = [g.z - g.z_bin_m / 2; g.z(end) + g.z_bin_m / 2];
            h = pcolor(ax, t_edges, z_edges, [v, nan(size(v, 1), 1); nan(1, size(v, 2) + 1)]);
            h.EdgeColor = 'none';
            h.HitTest = 'off';
            hold(ax, 'on');
            if app.ContourBox.Value && isfield(g, 'sigma0') && ~strcmp(name, 'sigma0')
                s0 = g.sigma0(:, idx);
                levels = app.contourLevels(s0);
                if size(s0, 2) > 1 && ~isempty(levels)
                    [~, hc] = contour(ax, t, g.z, s0, levels, 'k', 'LineWidth', 0.5);
                    hc.HitTest = 'off';
                end
            end
            if ~isempty(k)
                xline(ax, g.time(k), 'm', 'LineWidth', 1.5, 'HitTest', 'off'); % the cast in the profiles
            end
            hold(ax, 'off');
            ax.YDir = 'reverse';
            colormap(ax, app.colormapNamed(app.CmapDrop(i).Value));
            cb = colorbar(ax, 'FontSize', app.FontSize);
            cb.Label.String = label;
            cb.Label.Interpreter = 'none';
            cb.Label.FontSize = app.FontSize;
            lims = app.colourLimits(i, v);
            if ~isempty(lims)
                ax.CLim = lims; % not clim(): a user clim.m can shadow it
            end
            app.SectionCLim{i} = lims;
            zl = app.depthLimits(g.z);
            ylim(ax, zl);
            tl = app.timeWindow();
            if isempty(tl)
                tl = t_edges([1 end]);
            end
            if ~(diff(tl) > 0)
                tl = tl(1) + [-1 1] / 1440; % a cast with no length: a minute each side
            end
            xlim(ax, tl);
            app.TimeLimits = tl;
            datetick(ax, 'x', 'HH:MM', 'keeplimits');
            ylabel(ax, 'depth [m]');
            lines = {label};
            if i == 1
                lines = [{sprintf('%s - %s, casts: %s (%d), depth %g-%g m, %g m bins, %s, white = no data', ...
                    app.SurveyDrop.Value, app.windowText(), app.DirDrop.Value, numel(idx), zl(1), zl(2), g.z_bin_m, ...
                    app.contourText())}, lines];
            end
            title(ax, lines, 'Interpreter', 'none', 'FontSize', app.FontSize + 1, 'FontWeight', 'normal');
            if i < app.NSections
                ax.XTickLabel = {};
            else
                xlabel(ax, sprintf('time UTC, %s to %s', datestr(tl(1), 'yyyy-mm-dd HH:MM'), ...
                    datestr(tl(2), 'yyyy-mm-dd HH:MM'))); %#ok<DATST>
            end
        end

        function cols = pickColumns(app)
            % the casts in the time window, in the chosen direction(s)
            g = app.Grid;
            cols = true(1, numel(g.time));
            if ~strcmp(app.DirDrop.Value, 'both')
                cols = strcmp(g.cast_direction, app.DirDrop.Value);
            end
            w = app.timeWindow();
            if ~isempty(w)
                cols = cols & g.time >= w(1) & g.time <= w(2);
            end
        end

        function w = timeWindow(app)
            % [start end] datenum (UTC): span hours ending now or at the
            % typed time; [] for span 0 or empty (all casts)
            w = [];
            span = app.SpanField.Value;
            if isempty(span) || span <= 0
                return
            end
            t_end = datenum(datetime('now', 'TimeZone', 'UTC')); %#ok<DATNM>
            if startsWith(app.EndDrop.Value, 'this time')
                t = app.typedTime();
                if ~isnan(t)
                    t_end = t;
                end
            end
            w = [t_end - span / 24, t_end];
        end

        function t = typedTime(app)
            t = NaN;
            try
                t = datenum(datetime(strtrim(app.EndField.Value), 'InputFormat', 'yyyy-MM-dd HH:mm')); %#ok<DATNM>
            catch
            end
        end

        function endTimeTyped(app)
            if isnan(app.typedTime())
                app.DetailLbl.Text = sprintf('"%s" isn''t a time - type it as yyyy-mm-dd HH:MM (UTC).', app.EndField.Value);
                return
            end
            app.EndDrop.Value = 'this time (UTC):';
            app.drawPlots();
        end

        function [label, v] = displayed(app, name, v)
            unit = '';
            if isfield(app.Grid, 'variables')
                k = find(strcmp({app.Grid.variables.name}, name), 1);
                if ~isempty(k)
                    unit = app.Grid.variables(k).unit;
                end
            end
            if startsWith(name, {'epsilon.', 'chi.', 'microconductivity.'}) ...
                    && ~contains(name, '_fom')
                v(v <= 0) = NaN;
                v = log10(v);
                label = sprintf('log10 %s [%s]', name, unit);
            else
                label = sprintf('%s [%s]', name, unit);
            end
        end

        function lims = colourLimits(app, i, v)
            lo = app.CMinField(i).Value;
            hi = app.CMaxField(i).Value;
            finite = v(isfinite(v));
            lims = [];
            if ~isempty(lo) && ~isempty(hi) && hi > lo
                lims = [lo hi];
            elseif ~isempty(finite)
                lims = prctile(finite, [2 98]);
                if lims(2) <= lims(1)
                    lims = lims(1) + [-1 1] * max(abs(lims(1)) * 0.01, eps);
                end
            end
        end

        function zl = depthLimits(app, z)
            zl = [0, max(z) + 0.5 * app.Grid.z_bin_m];
            if ~isempty(app.ZMinField.Value)
                zl(1) = app.ZMinField.Value;
            end
            if ~isempty(app.ZMaxField.Value)
                zl(2) = app.ZMaxField.Value;
            end
            if zl(2) <= zl(1)
                zl(2) = zl(1) + 1;
            end
        end

        function drawPressure(app)
            ax = app.PressureAx;
            cla(ax);
            f = fullfile(app.surveyFolder(), 'processed', 'realtime', 'meta', 'pressure_time_series.mat');
            pt = app.safeLoad(f);
            if ~isfield(pt, 'dnum') || isempty(pt.dnum)
                title(ax, 'pressure: none yet', 'FontSize', app.FontSize + 1);
                return
            end
            tl = app.smallPlotWindow(pt.dnum);
            keep = pt.dnum >= tl(1) & pt.dnum <= tl(2);
            plot(ax, datetime(pt.dnum(keep), 'ConvertFrom', 'datenum'), pt.P(keep), 'k');
            ax.YDir = 'reverse';
            xlim(ax, datetime(tl, 'ConvertFrom', 'datenum'));
            ylabel(ax, 'P [dbar]');
            title(ax, 'pressure (sections'' time window)', 'FontSize', app.FontSize + 1, 'FontWeight', 'normal');
        end

        function [idx, colors, labels] = lastCasts(app)
            % the last NProfiles casts in the sections' window and direction(s), oldest first
            g = app.Grid;
            idx = [];
            colors = [];
            labels = {};
            if ~isfield(g, 'time') || isempty(g.time)
                return
            end
            idx = find(app.pickColumns());
            [~, order] = sort(g.time(idx));
            idx = idx(order(max(1, end - app.NProfiles + 1):end));
            colors = parula(numel(idx) + 1);
            labels = arrayfun(@(k) sprintf('%s %s', datestr(g.time(k), 'HH:MM'), g.cast_direction{k}), ...
                idx, 'UniformOutput', false); %#ok<DATST>
        end

        function drawTS(app)
            ax = app.TSAx;
            cla(ax);
            g = app.Grid;
            [idx, colors, labels] = app.lastCasts();
            if ~isfield(g, 'salinity_practical') || ~isfield(g, 'temperature') || isempty(idx)
                title(ax, 'T-S: no grid yet', 'FontSize', app.FontSize + 1);
                return
            end
            hold(ax, 'on');
            for i = 1:numel(idx)
                plot(ax, g.salinity_practical(:, idx(i)), g.temperature(:, idx(i)), '.-', 'Color', colors(i, :), 'MarkerSize', 4);
            end
            hold(ax, 'off');
            xlabel(ax, 'salinity\_practical [psu]');
            ylabel(ax, 'temperature [degC]');
            legend(ax, labels, 'Location', 'best', 'FontSize', app.FontSize);
            title(ax, sprintf('T-S, last %d casts (oldest dark, newest yellow)', numel(idx)), ...
                'FontSize', app.FontSize + 1, 'FontWeight', 'normal');
        end

        function drawWaterfall(app)
            % the last casts' T and C profiles, each offset from the last
            app.drawProfiles(app.WaterfallAx, 'temperature', 'degC', app.OffsetField.Value, 0.01);
            app.drawProfiles(app.CondAx, 'conductivity', 'S/m', app.CondOffsetField.Value, 0.001);
        end

        function drawProfiles(app, ax, name, unit, offset, min_offset)
            cla(ax);
            g = app.Grid;
            [idx, colors, labels] = app.lastCasts();
            G = app.gridField(g, name);
            if isempty(G) || isempty(idx)
                title(ax, sprintf('%s profiles: none in the grid yet', name), 'FontSize', app.FontSize + 1);
                return
            end
            X = G(:, idx);
            how = sprintf('%g %s', offset, unit);
            if isempty(offset)
                % auto: a quarter of the profiles' range
                offset = max(diff(prctile(X(isfinite(X)), [2 98])) / 4, min_offset);
                how = sprintf('auto %.2g %s', offset, unit);
            end
            hold(ax, 'on');
            for i = 1:numel(idx)
                plot(ax, X(:, i) + (i - 1) * offset, g.z, 'Color', colors(i, :), 'LineWidth', 1);
            end
            hold(ax, 'off');
            ax.YDir = 'reverse';
            ylim(ax, app.depthLimits(g.z));
            xlabel(ax, sprintf('%s [%s], + %s per cast', name, unit, how));
            ylabel(ax, 'depth [m]');
            legend(ax, labels, 'Location', 'best', 'FontSize', app.FontSize);
            title(ax, sprintf('%s, last %d casts, offset', name, numel(idx)), 'FontSize', app.FontSize + 1, ...
                'FontWeight', 'normal');
        end

        function changed = loadTwist(app)
            % the cruise twist count (MODprocess_cruise_twist.m), reloaded only when it changes
            f = fullfile(app.Root, 'twist', 'twist_time_series.mat');
            stamp = NaN;
            if isfile(f)
                d = dir(f);
                stamp = d.datenum;
            end
            changed = ~isequaln(stamp, app.TwistStamp);
            if ~changed
                return
            end
            app.TwistStamp = stamp;
            s = app.safeLoad(f);
            if isfield(s, 'TwistTimeseries')
                app.Twist = s.TwistTimeseries;
            elseif isfile(f)
                app.TwistStamp = NaN; % being written - keep the last one, try next refresh
                changed = false;
            else
                app.Twist = struct();
            end
        end

        function levels = contourLevels(app, s0)
            % sigma0 contour levels: every ContourField kg/m^3 on round
            % values, or 10 levels when it's empty; [] = nothing to draw
            levels = [];
            lo = min(s0(:));
            hi = max(s0(:));
            if ~(hi > lo)
                return
            end
            d = app.ContourField.Value;
            if isempty(d)
                levels = 10;
            else
                levels = (ceil(lo / d):floor(hi / d)) * d;
                if isscalar(levels)
                    levels = [levels levels]; % contour reads a scalar as a number of levels
                end
            end
        end

        function txt = contourText(app)
            if ~app.ContourBox.Value
                txt = 'no sigma0 contours';
            elseif isempty(app.ContourField.Value)
                txt = 'sigma0 contours: 10 levels';
            else
                txt = sprintf('sigma0 contours every %g kg/m^3', app.ContourField.Value);
            end
        end

        function drawMap(app)
            % the casts (the grid's position of each: v down, ^ up) and the
            % GPS track (meta/gps_time_series.mat) between the survey's
            % first cast start and last cast end, in the sections' time
            % window; the last fix bigger and red; equal distances in x and
            % y (as n_axes_map.m), grid on
            ax = app.MapAx;
            cla(ax);
            f = fullfile(app.surveyFolder(), 'processed', 'realtime', 'meta', 'gps_time_series.mat');
            gp = app.safeLoad(f);
            if ~isfield(gp, 'dnum') || isempty(gp.dnum)
                title(ax, 'position: no GPS yet', 'FontSize', app.FontSize + 1);
                return
            end
            g = app.Grid;
            if ~isfield(g, 'cast_start') || isempty(g.cast_start) || ~isfield(g, 'latitude')
                title(ax, 'position: no casts in the grid yet', 'FontSize', app.FontSize + 1);
                return
            end
            tl = app.smallPlotWindow(gp.dnum);
            keep = gp.dnum >= tl(1) & gp.dnum <= tl(2) ...
                & gp.dnum >= min(g.cast_start) & gp.dnum <= max(g.cast_end);
            cols = app.pickColumns() & isfinite(g.latitude) & isfinite(g.longitude);
            if ~any(keep) && ~any(cols)
                title(ax, 'position: no casts or GPS fixes in the sections'' time window', 'FontSize', app.FontSize + 1);
                return
            end
            lat = gp.latitude(keep);
            lon = gp.longitude(keep);
            t = gp.dnum(keep);
            down = cols & strcmp(g.cast_direction, 'down');
            up = cols & strcmp(g.cast_direction, 'up');
            plot(ax, lon, lat, '.', 'Color', [0 0.4470 0.7410], 'MarkerSize', 4);
            hold(ax, 'on');
            plot(ax, g.longitude(down), g.latitude(down), 'v', 'MarkerSize', 7, 'MarkerFaceColor', 'k', 'MarkerEdgeColor', 'k');
            plot(ax, g.longitude(up), g.latitude(up), '^', 'MarkerSize', 7, 'MarkerFaceColor', 'w', 'MarkerEdgeColor', 'k');
            if ~isempty(t)
                plot(ax, lon(end), lat(end), 'o', 'MarkerSize', 8, 'MarkerFaceColor', [0.85 0.1 0.1], 'MarkerEdgeColor', 'k');
            end
            hold(ax, 'off');
            grid(ax, 'on');
            ax.XAxis.Exponent = 0;
            ax.YAxis.Exponent = 0;
            xlabel(ax, 'longitude [deg E]');
            ylabel(ax, 'latitude [deg N]');
            ns = 'NS';
            ew = 'EW';
            last = 'no GPS fixes between the casts';
            if ~isempty(t)
                last = sprintf('red: %s UTC, %.4f %s, %.4f %s', datestr(t(end), 'mm-dd HH:MM'), ...
                    abs(lat(end)), ns(1 + (lat(end) < 0)), abs(lon(end)), ew(1 + (lon(end) < 0))); %#ok<DATST>
            end
            title(ax, {sprintf('position (sections'' window, casts: %s): v down, ^ up', app.DirDrop.Value), last}, ...
                'FontSize', app.FontSize + 1, 'FontWeight', 'normal');
            % limits: the track and casts plus a margin, at least ~100 m each side
            lat = [lat(:); g.latitude(cols)'];
            lon = [lon(:); g.longitude(cols)'];
            pad = @(v) max(0.05 * (max(v) - min(v)), 0.001);
            ylim(ax, [min(lat) - pad(lat), max(lat) + pad(lat)]);
            xlim(ax, [min(lon) - pad(lon), max(lon) + pad(lon)]);
            % equal distances in x and y shrink a straight track's box to a
            % sliver: widen the narrow side (about its center) to the axes' shape
            coslat = cosd(mean(ax.YLim));
            % the drawing area: free of the last draw's aspect ratio, after the title and labels
            ax.DataAspectRatioMode = 'auto';
            ax.PlotBoxAspectRatioMode = 'auto';
            drawnow;
            p = ax.InnerPosition;
            r = p(3) / p(4); % width / height
            if ~(isfinite(r) && r > 0)
                r = 1; % not laid out yet
            end
            wx = diff(ax.XLim) * coslat; % both in degrees of latitude, i.e. distance
            wy = diff(ax.YLim);
            if wx / wy < r
                xlim(ax, mean(ax.XLim) + [-1 1] * r * wy / coslat / 2);
            else
                ylim(ax, mean(ax.YLim) + [-1 1] * wx / r / 2);
            end
            ax.DataAspectRatio = [1 coslat 1];
        end

        function drawTwist(app)
            ax = app.TwistAx;
            delete(allchild(ax)); % not cla: it leaves MODvis_twist_timeseries' hidden-handle xlines, which pile up
            cla(ax);
            legend(ax, 'off');
            tt = app.Twist;
            if ~isfield(tt, 'dnum') || isempty(tt.dnum)
                title(ax, 'cruise twist: none yet', 'FontSize', app.FontSize + 1);
                return
            end
            tl = app.smallPlotWindow(tt.dnum); % the same limits as pressure
            keep = tt.dnum >= tl(1) & tt.dnum <= tl(2);
            w = tt;
            if isfield(w, 'pressure')
                w = rmfield(w, 'pressure'); % no pressure = one line, no upcast highlighting
            end
            for name = {'dnum', 'count_gyro', 'count_compass', 'survey_index'}
                if isfield(w, name{1})
                    w.(name{1}) = tt.(name{1})(keep);
                end
            end
            inside = @(t) t >= tl(1) & t <= tl(2);
            w.spool_swaps = tt.spool_swaps(inside([tt.spool_swaps.dnum]));
            w.spool_swap_dnum = [w.spool_swaps.dnum]';
            w.surveys = tt.surveys(inside(tt.survey_start_dnum));
            w.survey_start_dnum = tt.survey_start_dnum(inside(tt.survey_start_dnum));
            if isempty(w.dnum)
                w.dnum = tl(:);
                w.count_gyro = nan(2, 1);
            end
            MODvis_twist_timeseries(w, ax);
            ax.FontSize = app.FontSize;
            xlim(ax, datetime(tl, 'ConvertFrom', 'datenum'));
            legend(ax, 'off');
            % now: the newest count, the spool and when it went on
            now_count = tt.count_gyro(find(isfinite(tt.count_gyro), 1, 'last'));
            if isempty(now_count)
                now_count = NaN;
            end
            since = '';
            if ~isempty(tt.spool_swaps)
                since = sprintf(' (on since %s)', datestr(tt.spool_swaps(end).dnum, 'mm-dd HH:MM')); %#ok<DATST>
            end
            spool = app.orNone(tt.spool);
            title(ax, {sprintf('cruise twist %+.1f turns, spool %s%s', now_count, spool, since), ...
                sprintf('latest %s UTC; dashed spool change, dotted survey start', ...
                datestr(tt.dnum(end), 'mm-dd HH:MM'))}, 'FontSize', app.FontSize + 1, 'FontWeight', 'normal', ...
                'Interpreter', 'none'); %#ok<DATST>
            ylabel(ax, 'turns (neutral is negative)');
            xlabel(ax, '');
        end

        %% Log
        function refreshLog(app)
            if strcmp(app.LogDrop.Value, 'cruise_log.txt')
                f = fullfile(app.Root, 'realtime', 'cruise_log.txt');
            else
                f = fullfile(app.surveyFolder(), 'processed', 'realtime', 'meta', 'log', 'processing.log');
            end
            lines = app.tail(f, 300);
            if isempty(lines)
                lines = {sprintf('(no %s yet)', app.shortPath(f))};
            end
            at_end = isempty(app.LogList.Items) || isempty(app.LogList.Value) ...
                || strcmp(app.LogList.Value, app.LogList.Items{end});
            app.LogList.Items = lines;
            removeStyle(app.LogList);
            bad = find(~cellfun(@isempty, regexpi(lines, 'error|problem|fail|could not', 'once')));
            if ~isempty(bad)
                addStyle(app.LogList, uistyle('FontColor', [0.8 0 0]), 'item', bad);
            end
            if at_end
                app.LogList.Value = lines{end};
                scroll(app.LogList, 'bottom');
            end
        end

        function showLine(app, line)
            app.DetailLbl.Text = line;
        end

        %% Controls
        function startWorker(app)
            if app.workerRunning()
                if strcmp(app.field(app.Status, 'worker_state', ''), 'paused')
                    app.sendCommand('run');
                else
                    app.DetailLbl.Text = 'The worker is already running (realtime/worker.lock).';
                end
                return
            end
            repo = fileparts(fileparts(mfilename('fullpath')));
            out = fullfile(app.Root, 'realtime', 'worker_console.txt');
            if ~isfolder(fileparts(out))
                mkdir(fileparts(out));
            end
            % An Intel MATLAB (no bin/maca64) on an Apple Silicon Mac only starts
            % under Rosetta (arch -x86_64). Asked of the hardware, since uname -m
            % from inside a Rosetta MATLAB says x86_64.
            prefix = '';
            [~, arm] = system('sysctl -n hw.optional.arm64 2>/dev/null');
            if strcmp(strtrim(arm), '1') && ~isfolder(fullfile(matlabroot, 'bin', 'maca64'))
                prefix = 'arch -x86_64 ';
            end
            cmd = sprintf(['MOD_FISH_PROCESSING_DIR=%s MOD_PROCESSED_ROOT=%s nohup %s%s -batch ' ...
                '"addpath(genpath(getenv(''MOD_FISH_PROCESSING_DIR''))); ' ...
                'MODprocess_deployment(getenv(''MOD_PROCESSED_ROOT''), ''watch'', true)" > %s 2>&1 &'], ...
                app.shellQuote(repo), app.shellQuote(app.Root), prefix, ...
                app.shellQuote(fullfile(matlabroot, 'bin', 'matlab')), app.shellQuote(out));
            [rc, msg] = system(cmd);
            if rc == 0
                app.DetailLbl.Text = sprintf('Worker started (output in %s). It shows as running after its first pass.', ...
                    app.shortPath(out));
            else
                app.DetailLbl.Text = sprintf('Could not start the worker: %s', msg);
            end
        end

        function sendCommand(app, command)
            f = fullfile(app.Root, 'realtime', 'control.json');
            if ~isfolder(fileparts(f))
                mkdir(fileparts(f));
            end
            tmp = [f '.tmp'];
            fid = fopen(tmp, 'w');
            if fid < 0
                app.DetailLbl.Text = sprintf('Could not write %s.', f);
                return
            end
            fprintf(fid, '%s', jsonencode(struct('command', command)));
            fclose(fid);
            movefile(tmp, f, 'f');
            app.DetailLbl.Text = sprintf('Sent "%s" (%s). The worker reads it within a second while waiting, or after the stage it is on.', ...
                command, app.shortPath(f));
        end

        function showPreflight(app)
            s = app.surveyStatus();
            p = app.field(s, 'preflight', []);
            if isempty(p)
                app.DetailLbl.Text = sprintf('No preflight for %s in status.json yet (the worker writes it each pass).', ...
                    app.SurveyDrop.Value);
                return
            end
            parts = [app.cellOf(app.field(p, 'plan', {})); ...
                strcat({'Missing: '}, app.cellOf(app.field(p, 'missing', {}))); ...
                strcat({'Problem: '}, app.cellOf(app.field(p, 'problems', {}))); ...
                strcat({'Note: '}, app.cellOf(app.field(p, 'notes', {})))];
            app.LogList.Items = parts;
            removeStyle(app.LogList);
            app.DetailLbl.Text = 'Preflight from the worker''s last pass (the log comes back on the next refresh).';
        end

        function pickTime(app, ev)
            % the click picks a time (its L1/L2 file) and the cast drawn
            % there (nearest cast time among those shown: the cell clicked)
            app.SelectedTime = ev.IntersectionPoint(1);
            g = app.Grid;
            cast = '';
            if isfield(g, 'time') && ~isempty(g.time)
                idx = find(app.pickColumns());
                if ~isempty(idx)
                    [~, j] = min(abs(g.time(idx) - app.SelectedTime));
                    app.SelectedCastStart = g.cast_start(idx(j));
                    cast = sprintf(', cast %s', app.castText(idx(j)));
                end
            end
            file = '';
            ti = app.safeLoad(fullfile(app.surveyFolder(), 'processed', 'realtime', 'meta', 'time_index.mat'));
            if isfield(ti, 'filename') && ~isempty(ti.filename)
                k = find(ti.dnum_start <= app.SelectedTime & ti.dnum_end >= app.SelectedTime, 1);
                if ~isempty(k)
                    file = ti.filename{k};
                end
            end
            app.DetailLbl.Text = sprintf('Selected %s UTC%s - L1/L2 file: %s', ...
                datestr(app.SelectedTime, 'yyyy-mm-dd HH:MM:SS'), cast, app.orNone(file)); %#ok<DATST>
            app.drawSections();
        end

        function openViewer(app, which)
            run_folder = fullfile(app.surveyFolder(), 'processed', 'realtime');
            if ~isfolder(run_folder)
                app.DetailLbl.Text = sprintf('No %s yet.', run_folder);
                return
            end
            if strcmp(which, 'timeseries')
                MODvis_timeseries(run_folder);
            else
                MODvis_spectra(run_folder);
            end
        end

        function savePng(app)
            folder = fullfile(app.Root, 'realtime', 'figures');
            if ~isfolder(folder)
                mkdir(folder);
            end
            f = fullfile(folder, sprintf('monitor_%s_%s.png', app.SurveyDrop.Value, ...
                char(datetime('now', 'TimeZone', 'UTC', 'Format', 'yyyyMMdd_HHmmss'))));
            drawnow;
            try
                exportapp(app.Fig, f);
                app.DetailLbl.Text = sprintf('Saved %s', f);
            catch ME
                app.DetailLbl.Text = sprintf('Could not save the PNG (%s).', ME.message);
            end
        end

        function surveyChanged(app)
            app.GridFile = '';
            app.SelectedTime = NaN;
            app.SelectedCastStart = NaN;
            app.loadGrid();
            app.fitWindowToSurvey();
            app.refresh();
            app.drawPlots();
        end

        function fitWindowToSurvey(app)
            % span and ending-at so the whole survey shows; the survey the
            % worker is on stays on a rolling window ending now
            g = app.Grid;
            if ~isfield(g, 'cast_start') || isempty(g.cast_start) || ~isfield(g, 'cast_end')
                return
            end
            live = app.workerRunning() && strcmp(app.SurveyDrop.Value, app.field(app.Status, 'active_survey', ''));
            if live
                app.SpanField.Value = 6;
                app.EndDrop.Value = app.EndDrop.Items{1};
                return
            end
            t_end = ceil(max(g.cast_end) * 1440) / 1440; % the typed time has minutes
            app.SpanField.Value = ceil((t_end - min(g.cast_start)) * 24 * 10) / 10; % hours, up to 0.1 h
            app.EndField.Value = datestr(t_end, 'yyyy-mm-dd HH:MM'); %#ok<DATST>
            app.EndDrop.Value = app.EndDrop.Items{2};
        end

        %% Helpers
        function folder = surveyFolder(app)
            folder = fullfile(app.Root, app.SurveyDrop.Value);
        end

        function tf = workerRunning(app)
            tf = isfile(fullfile(app.Root, 'realtime', 'worker.lock'));
        end

        function txt = windowText(app)
            w = app.timeWindow();
            if isempty(w)
                txt = 'all casts';
            elseif startsWith(app.EndDrop.Value, 'this time') && ~isnan(app.typedTime())
                txt = sprintf('%g h to %s UTC', app.SpanField.Value, datestr(w(2), 'yyyy-mm-dd HH:MM')); %#ok<DATST>
            else
                txt = sprintf('last %g h to now', app.SpanField.Value);
            end
        end

        function p = shortPath(app, f)
            p = strrep(f, [app.Root filesep], '');
        end
    end

    methods (Static)
        function cmap = colormapNamed(name)
            if any(strcmp(name, {'parula', 'turbo'}))
                cmap = feval(name, 256);
            else
                cmap = cmocean(name);
            end
        end

        function root = config_root()
            root = '';
            cfg = fullfile(fileparts(fileparts(mfilename('fullpath'))), 'acquisition', 'config.yml');
            if ~isfile(cfg)
                return
            end
            tok = regexp(fileread(cfg), '(?m)^processed_root:\s*([^#\r\n]*)', 'tokens', 'once');
            if ~isempty(tok)
                root = strtrim(strrep(strrep(tok{1}, '"', ''), '''', ''));
            end
        end

        %% A gridded field by its variables name: 'temperature' or a
        % grouped one, 'epsilon.final' (gridded.epsilon.final); [] if the grid
        % doesn't have it or it isn't numeric
        function x = gridField(g, name)
            x = [];
            parts = strsplit(name, '.');
            for i = 1:numel(parts)
                if ~isstruct(g) || ~isfield(g, parts{i})
                    return
                end
                g = g.(parts{i});
            end
            if isnumeric(g)
                x = g;
            end
        end

        function v = field(s, name, default)
            v = default;
            if isstruct(s) && isfield(s, name) && ~isempty(s.(name))
                v = s.(name);
            end
        end

        function v = ymlValue(txt, key)
            tok = regexp(txt, ['(?m)^' key ':\s*([^#\r\n]*)'], 'tokens', 'once');
            v = '';
            if ~isempty(tok)
                v = strtrim(strrep(strrep(tok{1}, '"', ''), '''', ''));
            end
        end

        function s = safeLoad(f)
            s = struct();
            if isfile(f)
                try
                    s = load(f);
                catch
                    % being written - next refresh
                end
            end
        end

        function lines = tail(f, n)
            lines = {};
            if ~isfile(f)
                return
            end
            try
                txt = fileread(f);
            catch
                return
            end
            lines = splitlines(strtrim(txt));
            lines = lines(~cellfun(@isempty, strtrim(lines)));
            lines = lines(max(1, end - n + 1):end);
        end

        function txt = lagText(lag_s)
            if isempty(lag_s) || ~isfinite(lag_s)
                txt = '-';
            elseif lag_s < 120
                txt = sprintf('%.0f s', lag_s);
            else
                txt = sprintf('%.1f min', lag_s / 60);
            end
        end

        function c = cellOf(x)
            if ischar(x) || isstring(x)
                c = cellstr(x);
            else
                c = x(:);
            end
        end

        function s = orNone(s)
            if isempty(s)
                s = '(none at that time)';
            end
        end

        function q = shellQuote(s)
            q = ['''' strrep(s, '''', '''\''''') ''''];
        end
    end
end
