classdef MODvis_realtime_monitor < handle
    % MODvis_realtime_monitor        Part of MOD_fish_processing
    %
    % app = MODvis_realtime_monitor()
    % app = MODvis_realtime_monitor(processed_root)
    %
    % The live monitor for the realtime worker (MODprocess_deployment with
    % 'watch' true), laid out after the 2018 FastCTD GUI. It only reads
    % the worker's files - <processed_root>/realtime/status.json, each
    % survey's processed/realtime/grid/grid.mat, meta/ and meta/log/ - and
    % refreshes every few seconds. It writes only realtime/control.json
    % (Pause, Stop) and saved PNGs, and Start launches the worker as its
    % own matlab -batch process, so closing or crashing the monitor never
    % stops processing.
    %
    %   Top:    status - worker state, survey, vehicle, winch spool, file
    %           counts, casts, lag, problems, last update.
    %   Left:   4 colour sections of the grid, one column per cast (depth
    %           vs time), with sigma0 contours. All 4 share the depth and
    %           time limits; each has its own variable (from
    %           grid.variables; epsilon and chi as log10), colormap and
    %           colour range.
    %   Middle, one row per section: small plots half a section's width -
    %           pressure vs time and T-S of the last 5 casts beside the
    %           1st section, the last 5 T profiles offset like a waterfall
    %           beside the 2nd (the 4th spot is free); the survey's twist
    %           count, as wide as a section, beside the 3rd; the survey's
    %           processing log (or the cruise log) beside the 4th, problem
    %           lines in red - click a line to see all of it.
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
        PressureAx
        TSAx
        WaterfallAx
        TwistAx
        LogList
        DetailLbl

        SurveyDrop
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
        OffsetField
        LogDrop
        OpenTSBtn
        OpenSpecBtn
        PngBtn

        Status struct = struct()
        Grid struct = struct()
        GridFile char = ''
        GridStamp double = NaN
        SelectedTime double = NaN
        TimeLimits double = []       % the sections' time limits, shared with pressure
    end

    properties (Constant)
        DefaultVars = {'sigma0', 'T', 'SP', 'epsilon_final'}
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
            app.refresh();
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
                'CloseRequestFcn', @(~, ~) delete(app));
            g = uigridlayout(app.Fig, [2 3]);
            g.RowHeight = {40, '1x'};
            g.ColumnWidth = {'2x', '2x', 270};

            app.StatusLbl = uilabel(g, 'Text', '', 'WordWrap', 'on', 'FontSize', 12, 'FontWeight', 'bold');
            app.StatusLbl.Layout.Row = 1;
            app.StatusLbl.Layout.Column = [1 3];

            % left: the sections, stacked
            left = uigridlayout(g, [app.NSections 1], 'Padding', [0 0 0 0], 'RowSpacing', 2);
            left.Layout.Row = 2;
            left.Layout.Column = 1;
            app.SectionAx = gobjects(1, app.NSections);
            for i = 1:app.NSections
                app.SectionAx(i) = uiaxes(left, 'FontSize', app.FontSize);
                app.SectionAx(i).ButtonDownFcn = @(~, ev) app.pickTime(ev);
            end

            % middle, one row per section: a 2x2 of small plots beside the
            % first 2 sections (the 4th spot is free), the twist count as
            % wide as a section beside the 3rd, the log beside the 4th
            mid = uigridlayout(g, [app.NSections 2], 'Padding', [0 0 0 0], 'RowSpacing', 2);
            mid.Layout.Row = 2;
            mid.Layout.Column = 2;
            app.PressureAx = app.smallAxes(mid, 1, 1);
            app.TSAx = app.smallAxes(mid, 1, 2);
            app.WaterfallAx = app.smallAxes(mid, 2, 1);
            app.TwistAx = app.smallAxes(mid, 3, [1 2]);
            logs = uigridlayout(mid, [2 1], 'Padding', [0 0 0 0], 'RowHeight', {'1x', 44});
            logs.Layout.Row = 4;
            logs.Layout.Column = [1 2];
            app.LogList = uilistbox(logs, 'Items', {}, 'FontName', 'Menlo', 'FontSize', 10, ...
                'ValueChangedFcn', @(src, ~) app.showLine(src.Value));
            app.DetailLbl = uilabel(logs, 'Text', '', 'WordWrap', 'on', 'FontName', 'Menlo', 'FontSize', 10);

            % right: control panel
            n_rows = 16 + 3 * app.NSections + 8;
            c = uigridlayout(g, [n_rows 2], 'RowSpacing', 3, 'Scrollable', 'on');
            c.Layout.Row = 2;
            c.Layout.Column = 3;
            c.RowHeight = repmat({22}, 1, n_rows);
            row = 1;
            app.SurveyDrop = app.labelled(c, row, 'Survey', 'drop', {}, @(~, ~) app.surveyChanged());
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
            app.VarDrop = gobjects(1, app.NSections);
            app.CmapDrop = gobjects(1, app.NSections);
            app.CMinField = gobjects(1, app.NSections);
            app.CMaxField = gobjects(1, app.NSections);
            for i = 1:app.NSections
                row = row + 1;
                app.VarDrop(i) = app.labelled(c, row, sprintf('Section %d', i), 'drop', app.DefaultVars(i), ...
                    @(~, ~) app.drawSections());
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
                if app.loadGrid()
                    app.drawPlots();
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
            vehicle = '';
            spool = '';
            yml = fullfile(app.surveyFolder(), 'meta', 'dev1_setup.yml');
            if isfile(yml)
                txt = fileread(yml);
                vehicle = app.ymlValue(txt, 'vehicle_name');
                spool = app.ymlValue(txt, 'winch_spool');
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
            f = fullfile(app.surveyFolder(), 'processed', 'realtime', 'grid', 'grid.mat');
            changed = false;
            stamp = NaN;
            if isfile(f)
                d = dir(f);
                stamp = d.datenum;
            end
            if strcmp(f, app.GridFile) && isequaln(stamp, app.GridStamp)
                return
            end
            app.GridFile = f;
            app.GridStamp = stamp;
            app.Grid = struct();
            if isfile(f)
                try
                    app.Grid = load(f);
                catch
                    app.GridStamp = NaN; % being written - next refresh
                end
            end
            names = {'T'};
            if isfield(app.Grid, 'variables') && ~isempty(app.Grid.variables)
                v = app.Grid.variables;
                keep = arrayfun(@(x) isfield(app.Grid, x.name) && isnumeric(app.Grid.(x.name)) ...
                    && size(app.Grid.(x.name), 1) == numel(app.Grid.z) && size(app.Grid.(x.name), 2) > 0, v);
                names = {v(keep).name};
                names = names(~ismember(names, {'z', 'time', 'cast_start', 'cast_end', 'cast_complete', 'profile_number'}));
            end
            if isempty(names)
                names = {'T'};
            end
            for i = 1:app.NSections
                current = app.VarDrop(i).Value;
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

        %% Plots
        function drawPlots(app)
            app.drawSections();
            app.drawPressure();
            app.drawTS();
            app.drawWaterfall();
            app.drawTwist();
        end

        function drawSections(app)
            app.TimeLimits = [];
            for i = 1:app.NSections
                app.drawSection(i);
            end
            ok = isgraphics(app.SectionAx);
            if ~isempty(app.TimeLimits)
                linkaxes(app.SectionAx(ok), 'xy');
            end
        end

        function drawSection(app, i)
            ax = app.SectionAx(i);
            cla(ax);
            colorbar(ax, 'off');
            g = app.Grid;
            name = app.VarDrop(i).Value;
            if ~isfield(g, 'z') || ~isfield(g, name) || isempty(g.time)
                if i == 1
                    title(ax, sprintf('%s: no grid yet (%s)', app.SurveyDrop.Value, app.shortPath(app.GridFile)), ...
                        'Interpreter', 'none', 'FontSize', app.FontSize + 1);
                end
                return
            end
            cols = app.pickColumns();
            if nnz(cols) < 2
                title(ax, sprintf('%s: %d cast(s) in %s - need 2 for a section', name, nnz(cols), app.windowText()), ...
                    'Interpreter', 'none', 'FontSize', app.FontSize + 1);
                return
            end
            [t, order] = sort(g.time(cols));
            idx = find(cols);
            idx = idx(order);
            [label, v] = app.displayed(name, g.(name)(:, idx));
            % one cell per cast and bin: edges halfway between cast times
            % and at the bin edges, so no cast or bin is dropped
            dt = diff(t);
            t_edges = [t(1) - dt(1) / 2, t(1:end-1) + dt / 2, t(end) + dt(end) / 2];
            z_edges = [g.z - g.z_bin_m / 2; g.z(end) + g.z_bin_m / 2];
            h = pcolor(ax, t_edges, z_edges, [v, nan(size(v, 1), 1); nan(1, size(v, 2) + 1)]);
            h.EdgeColor = 'none';
            h.HitTest = 'off';
            hold(ax, 'on');
            if isfield(g, 'sigma0') && ~strcmp(name, 'sigma0')
                s0 = g.sigma0(:, idx);
                if any(isfinite(s0(:)))
                    [~, hc] = contour(ax, t, g.z, s0, 10, 'k', 'LineWidth', 0.5);
                    hc.HitTest = 'off';
                end
            end
            if isfinite(app.SelectedTime)
                xline(ax, app.SelectedTime, 'm', 'LineWidth', 1.5, 'HitTest', 'off');
            end
            hold(ax, 'off');
            ax.YDir = 'reverse';
            colormap(ax, app.colormapNamed(app.CmapDrop(i).Value));
            cb = colorbar(ax, 'FontSize', app.FontSize);
            cb.Label.String = label;
            cb.Label.Interpreter = 'none';
            cb.Label.FontSize = app.FontSize;
            [lims, how] = app.colourLimits(i, v);
            if ~isempty(lims)
                ax.CLim = lims; % not clim(): a user clim.m can shadow it
            end
            zl = app.depthLimits(g.z);
            ylim(ax, zl);
            tl = app.timeWindow();
            if isempty(tl)
                tl = t_edges([1 end]);
            end
            xlim(ax, tl);
            app.TimeLimits = tl;
            datetick(ax, 'x', 'HH:MM', 'keeplimits');
            ylabel(ax, 'depth [m]');
            lines = {sprintf('%d. %s, %s, colour %s', i, label, app.CmapDrop(i).Value, how)};
            if i == 1
                lines = [{sprintf('%s - %s, casts: %s (%d), depth %g-%g m, %g m bins, white = no data', ...
                    app.SurveyDrop.Value, app.windowText(), app.DirDrop.Value, numel(idx), zl(1), zl(2), g.z_bin_m)}, lines];
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
            if startsWith(name, {'epsilon', 'chi'})
                v(v <= 0) = NaN;
                v = log10(v);
                label = sprintf('log10 %s [%s]', name, unit);
            else
                label = sprintf('%s [%s]', name, unit);
            end
        end

        function [lims, how] = colourLimits(app, i, v)
            lo = app.CMinField(i).Value;
            hi = app.CMaxField(i).Value;
            finite = v(isfinite(v));
            lims = [];
            if ~isempty(lo) && ~isempty(hi) && hi > lo
                lims = [lo hi];
                how = sprintf('%g to %g', lo, hi);
            elseif ~isempty(finite)
                lims = prctile(finite, [2 98]);
                if lims(2) <= lims(1)
                    lims = lims(1) + [-1 1] * max(abs(lims(1)) * 0.01, eps);
                end
                how = sprintf('auto %.4g to %.4g (2-98%%)', lims(1), lims(2));
            else
                how = 'auto (no data)';
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
            % the sections' time window when there is one, else the last hours
            tl = app.TimeLimits;
            if isempty(tl)
                tl = app.timeWindow();
            end
            if isempty(tl)
                tl = [min(pt.dnum) max(pt.dnum)];
            end
            keep = pt.dnum >= tl(1) & pt.dnum <= tl(2);
            plot(ax, pt.dnum(keep), pt.P(keep), 'k');
            ax.YDir = 'reverse';
            xlim(ax, tl);
            datetick(ax, 'x', 'HH:MM', 'keeplimits');
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
            if ~isfield(g, 'SP') || ~isfield(g, 'T') || isempty(idx)
                title(ax, 'T-S: no grid yet', 'FontSize', app.FontSize + 1);
                return
            end
            hold(ax, 'on');
            for i = 1:numel(idx)
                plot(ax, g.SP(:, idx(i)), g.T(:, idx(i)), '.-', 'Color', colors(i, :), 'MarkerSize', 4);
            end
            hold(ax, 'off');
            xlabel(ax, 'SP [psu]');
            ylabel(ax, 'T [degC]');
            legend(ax, labels, 'Location', 'best', 'FontSize', app.FontSize);
            title(ax, sprintf('T-S, last %d casts (oldest dark, newest yellow)', numel(idx)), ...
                'FontSize', app.FontSize + 1, 'FontWeight', 'normal');
        end

        function drawWaterfall(app)
            ax = app.WaterfallAx;
            cla(ax);
            g = app.Grid;
            [idx, colors, labels] = app.lastCasts();
            if ~isfield(g, 'T') || isempty(idx)
                title(ax, 'T profiles: no grid yet', 'FontSize', app.FontSize + 1);
                return
            end
            T = g.T(:, idx);
            offset = app.OffsetField.Value;
            how = sprintf('%g degC', offset);
            if isempty(offset)
                % auto: a quarter of the profiles' range
                offset = max(diff(prctile(T(isfinite(T)), [2 98])) / 4, 0.01);
                how = sprintf('auto %.2g degC', offset);
            end
            hold(ax, 'on');
            for i = 1:numel(idx)
                plot(ax, T(:, i) + (i - 1) * offset, g.z, 'Color', colors(i, :), 'LineWidth', 1);
            end
            hold(ax, 'off');
            ax.YDir = 'reverse';
            ylim(ax, app.depthLimits(g.z));
            xlabel(ax, sprintf('T [degC], each cast + %s from the last', how));
            ylabel(ax, 'depth [m]');
            legend(ax, labels, 'Location', 'best', 'FontSize', app.FontSize);
            title(ax, sprintf('T, last %d casts, offset', numel(idx)), 'FontSize', app.FontSize + 1, 'FontWeight', 'normal');
        end

        function drawTwist(app)
            ax = app.TwistAx;
            cla(ax);
            f = fullfile(app.surveyFolder(), 'processed', 'realtime', 'meta', 'twist_time_series.mat');
            tt = app.safeLoad(f);
            if ~isfield(tt, 'dnum') || isempty(tt.dnum)
                title(ax, 'twist: none yet', 'FontSize', app.FontSize + 1);
                return
            end
            MODvis_twist_timeseries(tt, ax);
            ax.FontSize = app.FontSize;
            title(ax, 'twist count, this survey (cruise-wide count not built yet)', ...
                'FontSize', app.FontSize + 1, 'FontWeight', 'normal');
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
            app.SelectedTime = ev.IntersectionPoint(1);
            file = '';
            ti = app.safeLoad(fullfile(app.surveyFolder(), 'processed', 'realtime', 'meta', 'time_index.mat'));
            if isfield(ti, 'filename') && ~isempty(ti.filename)
                k = find(ti.dnum_start <= app.SelectedTime & ti.dnum_end >= app.SelectedTime, 1);
                if ~isempty(k)
                    file = ti.filename{k};
                end
            end
            app.DetailLbl.Text = sprintf('Selected %s UTC - L1/L2 file: %s', ...
                datestr(app.SelectedTime, 'yyyy-mm-dd HH:MM:SS'), app.orNone(file)); %#ok<DATST>
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
            app.refresh();
            app.drawPlots();
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
