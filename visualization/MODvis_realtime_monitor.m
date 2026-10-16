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
    %   Left:   colour section of the grid, one column per cast (depth vs
    %           time), with sigma0 contours. Variables come from
    %           grid.variables; epsilon and chi are shown as log10.
    %   Middle: pressure vs time; T-S of the last 5 casts coloured by age;
    %           the survey's twist count (the cruise-wide count isn't
    %           built yet).
    %   Bottom: the survey's processing log (or the cruise log), problem
    %           lines in red; click a line to see all of it.
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

        StatusLbl
        SectionAx
        PressureAx
        TSAx
        TwistAx
        LogList
        DetailLbl

        SurveyDrop
        StartBtn
        PauseBtn
        StopBtn
        PreflightBtn
        VarDrop
        DirDrop
        CmapDrop
        CMinField
        CMaxField
        ZMinField
        ZMaxField
        SpanField
        LogDrop
        OpenTSBtn
        OpenSpecBtn
        PngBtn

        Status struct = struct()
        Grid struct = struct()
        GridFile char = ''
        GridStamp double = NaN
        SelectedTime double = NaN
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
            app.Fig = uifigure('Name', ['Realtime monitor - ' app.Root], 'Position', [60 60 1600 950], ...
                'CloseRequestFcn', @(~, ~) delete(app));
            g = uigridlayout(app.Fig, [3 3]);
            g.RowHeight = {48, '1x', 170};
            g.ColumnWidth = {'5x', '3x', 250};

            app.StatusLbl = uilabel(g, 'Text', '', 'WordWrap', 'on', 'FontSize', 13, 'FontWeight', 'bold');
            app.StatusLbl.Layout.Row = 1;
            app.StatusLbl.Layout.Column = [1 3];

            app.SectionAx = uiaxes(g);
            app.SectionAx.Layout.Row = 2;
            app.SectionAx.Layout.Column = 1;
            app.SectionAx.ButtonDownFcn = @(~, ev) app.pickTime(ev);

            mid = uigridlayout(g, [3 1], 'Padding', [0 0 0 0]);
            mid.Layout.Row = 2;
            mid.Layout.Column = 2;
            app.PressureAx = uiaxes(mid);
            app.TSAx = uiaxes(mid);
            app.TwistAx = uiaxes(mid);

            bottom = uigridlayout(g, [2 1], 'Padding', [0 0 0 0], 'RowHeight', {'1x', 36});
            bottom.Layout.Row = 3;
            bottom.Layout.Column = [1 2];
            app.LogList = uilistbox(bottom, 'Items', {}, 'FontName', 'Menlo', 'FontSize', 11, ...
                'ValueChangedFcn', @(src, ~) app.showLine(src.Value));
            app.DetailLbl = uilabel(bottom, 'Text', '', 'WordWrap', 'on', 'FontName', 'Menlo', 'FontSize', 11);

            c = uigridlayout(g, [22 2], 'RowSpacing', 4);
            c.Layout.Row = [2 3];
            c.Layout.Column = 3;
            c.RowHeight = repmat({24}, 1, 22);
            app.SurveyDrop = app.labelled(c, 1, 'Survey', 'drop', {}, @(~, ~) app.surveyChanged());
            app.StartBtn = uibutton(c, 'Text', 'Start', 'ButtonPushedFcn', @(~, ~) app.startWorker());
            app.StartBtn.Layout.Row = 2; app.StartBtn.Layout.Column = 1;
            app.PauseBtn = uibutton(c, 'Text', 'Pause', 'ButtonPushedFcn', @(~, ~) app.sendCommand('pause'));
            app.PauseBtn.Layout.Row = 2; app.PauseBtn.Layout.Column = 2;
            app.StopBtn = uibutton(c, 'Text', 'Stop', 'ButtonPushedFcn', @(~, ~) app.sendCommand('stop'));
            app.StopBtn.Layout.Row = 3; app.StopBtn.Layout.Column = 1;
            app.PreflightBtn = uibutton(c, 'Text', 'Preflight', 'ButtonPushedFcn', @(~, ~) app.showPreflight());
            app.PreflightBtn.Layout.Row = 3; app.PreflightBtn.Layout.Column = 2;
            app.VarDrop = app.labelled(c, 5, 'Section', 'drop', {'T'}, @(~, ~) app.drawPlots());
            app.DirDrop = app.labelled(c, 6, 'Casts', 'drop', {'both', 'down', 'up'}, @(~, ~) app.drawPlots());
            app.CmapDrop = app.labelled(c, 7, 'Colormap', 'drop', {'parula', 'turbo', 'jet', 'hot', 'gray'}, @(~, ~) app.drawPlots());
            app.CMinField = app.labelled(c, 8, 'Colour min', 'num', NaN, @(~, ~) app.drawPlots());
            app.CMaxField = app.labelled(c, 9, 'Colour max', 'num', NaN, @(~, ~) app.drawPlots());
            app.ZMinField = app.labelled(c, 10, 'Depth min [m]', 'num', NaN, @(~, ~) app.drawPlots());
            app.ZMaxField = app.labelled(c, 11, 'Depth max [m]', 'num', NaN, @(~, ~) app.drawPlots());
            app.SpanField = app.labelled(c, 12, 'Last hours', 'num', 6, @(~, ~) app.drawPlots());
            app.LogDrop = app.labelled(c, 13, 'Log', 'drop', {'survey processing.log', 'cruise_log.txt'}, @(~, ~) app.refreshLog());
            note = uilabel(c, 'Text', 'Colour/depth: empty = auto. Last hours: 0 = all.', 'WordWrap', 'on', 'FontSize', 10);
            note.Layout.Row = [14 15]; note.Layout.Column = [1 2];
            app.OpenTSBtn = uibutton(c, 'Text', 'Open L1 (MODvis_timeseries)', 'ButtonPushedFcn', @(~, ~) app.openViewer('timeseries'));
            app.OpenTSBtn.Layout.Row = 16; app.OpenTSBtn.Layout.Column = [1 2];
            app.OpenSpecBtn = uibutton(c, 'Text', 'Open L2 (MODvis_spectra)', 'ButtonPushedFcn', @(~, ~) app.openViewer('spectra'));
            app.OpenSpecBtn.Layout.Row = 17; app.OpenSpecBtn.Layout.Column = [1 2];
            app.PngBtn = uibutton(c, 'Text', 'Save PNG', 'ButtonPushedFcn', @(~, ~) app.savePng());
            app.PngBtn.Layout.Row = 18; app.PngBtn.Layout.Column = [1 2];
            root_lbl = uilabel(c, 'Text', app.Root, 'WordWrap', 'on', 'FontSize', 10);
            root_lbl.Layout.Row = [20 22]; root_lbl.Layout.Column = [1 2];
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
            current = app.VarDrop.Value;
            app.VarDrop.Items = names;
            if any(strcmp(names, current))
                app.VarDrop.Value = current;
            end
            changed = true;
        end

        %% Plots
        function drawPlots(app)
            app.drawSection();
            app.drawPressure();
            app.drawTS();
            app.drawTwist();
        end

        function drawSection(app)
            ax = app.SectionAx;
            cla(ax);
            g = app.Grid;
            name = app.VarDrop.Value;
            if ~isfield(g, 'z') || ~isfield(g, name) || isempty(g.time)
                title(ax, sprintf('%s: no grid yet (%s)', app.SurveyDrop.Value, app.shortPath(app.GridFile)), 'Interpreter', 'none');
                return
            end
            cols = app.pickColumns();
            if nnz(cols) < 2
                title(ax, sprintf('%s: %d cast(s) in this window - need 2 for a section', name, nnz(cols)), 'Interpreter', 'none');
                return
            end
            [t, order] = sort(g.time(cols));
            idx = find(cols);
            idx = idx(order);
            v = g.(name)(:, idx);
            [label, v] = app.displayed(name, v);
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
            colormap(ax, app.CmapDrop.Value);
            cb = colorbar(ax);
            cb.Label.String = label;
            cb.Label.Interpreter = 'none';
            [lims, how] = app.colourLimits(v);
            if ~isempty(lims)
                ax.CLim = lims; % not clim(): a user clim.m can shadow it
            end
            zl = app.depthLimits(g.z);
            ylim(ax, zl);
            xlim(ax, t_edges([1 end]));
            datetick(ax, 'x', 'keeplimits');
            ylabel(ax, 'depth [m]');
            title(ax, {sprintf('%s - %s', app.SurveyDrop.Value, label), ...
                sprintf('casts: %s (%d%s), colour %s, depth %g-%g m, %g m bins, white = no data', ...
                app.DirDrop.Value, numel(idx), app.spanText(), how, zl(1), zl(2), g.z_bin_m)}, ...
                'Interpreter', 'none', 'FontSize', 11);
        end

        function cols = pickColumns(app)
            g = app.Grid;
            cols = true(1, numel(g.time));
            if ~strcmp(app.DirDrop.Value, 'both')
                cols = strcmp(g.cast_direction, app.DirDrop.Value);
            end
            span = app.SpanField.Value;
            if ~isempty(span) && span > 0 && any(isfinite(g.time))
                cols = cols & g.time >= max(g.time) - span / 24;
            end
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

        function [lims, how] = colourLimits(app, v)
            lo = app.CMinField.Value;
            hi = app.CMaxField.Value;
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
                how = sprintf('auto %.3g to %.3g (2-98%%)', lims(1), lims(2));
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
                title(ax, 'pressure: none yet');
                return
            end
            keep = true(size(pt.dnum));
            span = app.SpanField.Value;
            if ~isempty(span) && span > 0
                keep = pt.dnum >= max(pt.dnum) - span / 24;
            end
            plot(ax, pt.dnum(keep), pt.P(keep), 'k');
            ax.YDir = 'reverse';
            datetick(ax, 'x', 'keeplimits');
            ylabel(ax, 'P [dbar]');
            title(ax, sprintf('pressure%s', app.spanText()));
        end

        function drawTS(app)
            ax = app.TSAx;
            cla(ax);
            g = app.Grid;
            if ~isfield(g, 'SP') || ~isfield(g, 'T') || isempty(g.time)
                title(ax, 'T-S: no grid yet');
                return
            end
            [~, order] = sort(g.time);
            last = order(max(1, end - 4):end);
            colors = parula(numel(last) + 1);
            hold(ax, 'on');
            labels = cell(1, numel(last));
            for i = 1:numel(last)
                k = last(i);
                plot(ax, g.SP(:, k), g.T(:, k), '.-', 'Color', colors(i, :), 'MarkerSize', 6);
                labels{i} = sprintf('%s %s', datestr(g.time(k), 'HH:MM'), g.cast_direction{k}); %#ok<DATST>
            end
            hold(ax, 'off');
            xlabel(ax, 'SP [psu]');
            ylabel(ax, 'T [degC]');
            legend(ax, labels, 'Location', 'best', 'FontSize', 8);
            title(ax, 'T-S, last 5 casts (oldest dark, newest yellow)');
        end

        function drawTwist(app)
            ax = app.TwistAx;
            cla(ax);
            f = fullfile(app.surveyFolder(), 'processed', 'realtime', 'meta', 'twist_time_series.mat');
            tt = app.safeLoad(f);
            if ~isfield(tt, 'dnum') || isempty(tt.dnum)
                title(ax, 'twist: none yet');
                return
            end
            MODvis_twist_timeseries(tt, ax);
            title(ax, 'twist count, this survey (cruise-wide count not built yet)');
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
            cmd = sprintf(['MOD_FISH_PROCESSING_DIR=%s MOD_PROCESSED_ROOT=%s nohup %s -batch ' ...
                '"addpath(genpath(getenv(''MOD_FISH_PROCESSING_DIR''))); ' ...
                'MODprocess_deployment(getenv(''MOD_PROCESSED_ROOT''), ''watch'', true)" > %s 2>&1 &'], ...
                app.shellQuote(repo), app.shellQuote(app.Root), ...
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
            app.drawSection();
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

        function txt = spanText(app)
            span = app.SpanField.Value;
            txt = '';
            if ~isempty(span) && span > 0
                txt = sprintf(', last %g h', span);
            end
        end

        function p = shortPath(app, f)
            p = strrep(f, [app.Root filesep], '');
        end
    end

    methods (Static)
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
