classdef MODvis_timeseries < handle
    % MODvis_timeseries        Part of MOD_fish_processing
    % Browse a folder of *.mat files (L0, L1, L2, or Profile - any file
    % whose structures (epsi, ctd, vnav, gps, ...) carry a dnum field),
    % click a file, choose up to 6 rows, each with a required signal on
    % the left y-axis and an optional second signal (Struct = "(none)"
    % to skip it) on its own right y-axis (yyaxis), plotted vs dnum.
    % Supports nested fields like epsi.chan1, ctd.P_raw, gps.latitude, etc.
    %
    % Formerly named L0ExplorerApp.

    properties
        Fig matlab.ui.Figure
        GL matlab.ui.container.GridLayout

        FolderBtn matlab.ui.control.Button
        FolderLbl matlab.ui.control.Label
        FileList matlab.ui.control.ListBox
        RefreshBtn matlab.ui.control.Button

        Axes

        % Axis 1 (left, required) controls
        StructDrop
        SignalDrop
        YMinField
        YMaxField
        YResetBtn

        % Axis 2 (right, optional - Struct = NoneItem to disable) controls
        StructDrop2
        SignalDrop2
        YMinField2
        YMaxField2
        YResetBtn2

        AxesTickFontSize double = 10
        AxesLabelFontSize double = 11
        GlobalDnum double = []

        Folder string = ""
        Files string = strings(0,1)
        CurrentData struct = struct()
        CurrentFile string = ""
        NRows double = 6

        HasUserZoomed logical = false

        LastStruct string
        LastSignal string
        LastStruct2 string
        LastSignal2 string

        SignalColors struct

        % X-window slider handles
        XWinSlider
        XWinLenField
        XWinResetBtn

        % X-window state
        UseXWindow  logical = false
        XWindowLen  double  = 10    % window length in seconds
        XWinFraction double = 0     % fractional position in profile [0,1]
        ProfileTmin double  = 0     % profile start (dnum)
        ProfileTmax double  = 0     % profile end   (dnum)

        % Plot style
        PlotStyleCheck              % uicheckbox handle
        UseLine logical = false     % false = dots, true = lines

        % Custom y-tick label text handles (blank YTickLabel keeps TightInset
        % uniform; we draw our own labels as text() objects in the left margin).
        % Only used for the left (axis 1) y-axis - the optional right axis
        % (axis 2) shows MATLAB's native yyaxis tick labels.
        YTickTextHandles            % cell(NRows,1) of gobject arrays

        % Current axis-1 (left) data color per row, so the custom tick
        % text (drawn by updateYTickText, called from listeners as well
        % as plotRow) always matches the plotted line without needing it
        % passed in each time.
        Axis1Color                  % cell(NRows,1) of 1x3 RGB, default gray
    end

    properties (Constant)
        NoneItem = '(none)'   % axis-2 Struct sentinel meaning "don't plot a second signal"
    end


    methods
        function app = MODvis_timeseries(folder)
            if nargin >= 1 && ~isempty(folder)
                app.Folder = string(folder);
            else
                app.Folder = string(pwd);
            end

            app.buildUI();
            app.loadFolder(app.Folder);
        end

        function buildUI(app)
            app.Fig = uifigure('Name','L0 Explorer','Position',[100 100 1400 900]);

            app.GL = uigridlayout(app.Fig,[1 2]);
            app.GL.ColumnWidth = {240,'1x'};
            app.GL.RowHeight = {'1x'};
            app.GL.Padding = [10 10 10 10];
            app.GL.ColumnSpacing = 10;

            % LEFT: folder + list + x-window controls
            left = uigridlayout(app.GL,[6 1]);
            left.Layout.Row = 1;
            left.Layout.Column = 1;
            left.RowHeight = {44, 22, 34, '1x', 28, 36};
            left.ColumnWidth = {'1x'};
            left.RowSpacing = 6;

            topRow = uigridlayout(left,[2 2]);
            topRow.Layout.Row = 1;
            topRow.Layout.Column = 1;
            topRow.RowHeight = {'1x', 34};
            topRow.ColumnWidth = {'1x', 140};
            topRow.RowSpacing = 6;
            topRow.Padding = [0 0 0 0];

            % Folder label spans both columns
            app.FolderLbl = uilabel(topRow,'Text',"");
            app.FolderLbl.Layout.Row = 1;
            app.FolderLbl.Layout.Column = [1 2];
            app.trySetProp(app.FolderLbl,'Interpreter','none');
            app.FolderLbl.FontSize = 12;
            app.FolderLbl.WordWrap = 'on';
            app.FolderLbl.VerticalAlignment = 'top';

            % Button bottom-right
            app.FolderBtn = uibutton(topRow,'push','Text','Choose folder…', ...
                'ButtonPushedFcn', @(~,~)app.chooseFolder());
            app.FolderBtn.Layout.Row = 2;
            app.FolderBtn.Layout.Column = 2;
            app.FolderBtn.FontSize = 12;

            % Optional: show just the last folder name on bottom-left (nice touch)
            % (or you can put nothing there)
            mini = uilabel(topRow,'Text','');
            mini.Layout.Row = 2;
            mini.Layout.Column = 1;


            lbl = uilabel(left,'Text','L0 files (*.mat):');
            lbl.Layout.Row = 2;
            lbl.Layout.Column = 1;

            app.RefreshBtn = uibutton(left,'push','Text','Refresh list', ...
                'ButtonPushedFcn', @(~,~)app.loadFolder(app.Folder));
            app.RefreshBtn.Layout.Row = 3;
            app.RefreshBtn.Layout.Column = 1;

            % NOTE: uilistbox does NOT have 'Interpreter' property (even in R2024b)
            app.FileList = uilistbox(left, ...
                'Items',{}, ...
                'ValueChangedFcn', @(~,~)app.onFileSelected());
            app.FileList.Layout.Row = 4;
            app.FileList.Layout.Column = 1;
            app.FileList.FontName = 'Sans';  % or 'Consolas' on Windows
            app.FileList.FontSize = 12;

            % X-window: length field + Full-view button
            xwinRow = uigridlayout(left, [1 3]);
            xwinRow.Layout.Row = 5;
            xwinRow.Layout.Column = 1;
            xwinRow.RowHeight = {'1x'};
            xwinRow.ColumnWidth = {76, '1x', 64};
            xwinRow.ColumnSpacing = 4;
            xwinRow.Padding = [0 2 0 2];

            xwinLbl = uilabel(xwinRow, 'Text', 'X win (s):');
            xwinLbl.Layout.Row = 1; xwinLbl.Layout.Column = 1;
            xwinLbl.VerticalAlignment = 'center';
            xwinLbl.FontSize = 12;

            app.XWinLenField = uieditfield(xwinRow, 'numeric', ...
                'Placeholder', 'sec', ...
                'Value', 0, ...
                'Limits', [0 Inf], ...
                'ValueChangedFcn', @(~,~)app.onXWinLenChanged());
            app.XWinLenField.Layout.Row = 1; app.XWinLenField.Layout.Column = 2;
            app.XWinLenField.FontSize = 12;

            app.XWinResetBtn = uibutton(xwinRow, 'push', 'Text', 'Full view', ...
                'ButtonPushedFcn', @(~,~)app.onXWinReset());
            app.XWinResetBtn.Layout.Row = 1; app.XWinResetBtn.Layout.Column = 3;
            app.XWinResetBtn.FontSize = 11;

            % X-window: plot-style checkbox + position slider
            sliderRow = uigridlayout(left, [1 2]);
            sliderRow.Layout.Row = 6;
            sliderRow.Layout.Column = 1;
            sliderRow.RowHeight = {'1x'};
            sliderRow.ColumnWidth = {58, '1x'};
            sliderRow.ColumnSpacing = 6;
            sliderRow.Padding = [0 6 0 6];

            app.PlotStyleCheck = uicheckbox(sliderRow, 'Text', 'Lines', ...
                'Value', false, ...
                'ValueChangedFcn', @(~,~)app.onPlotStyleChanged());
            app.PlotStyleCheck.Layout.Row = 1; app.PlotStyleCheck.Layout.Column = 1;
            app.PlotStyleCheck.FontSize = 12;

            app.XWinSlider = uislider(sliderRow, ...
                'Limits', [0 100], ...
                'Value', 0, ...
                'MajorTicks', [], ...
                'MinorTicks', [], ...
                'Enable', 'off', ...
                'ValueChangedFcn',  @(~,~)app.onXWinSliderMoved(), ...
                'ValueChangingFcn', @(~,evt)app.onXWinSliderChanging(evt));
            app.XWinSlider.Layout.Row = 1; app.XWinSlider.Layout.Column = 2;


            % RIGHT: rows of controls + axes
            right = uigridlayout(app.GL,[app.NRows 1]);
            right.Layout.Row = 1;
            right.Layout.Column = 2;
            right.RowHeight = repmat({'1x'},1,app.NRows);
            right.ColumnWidth = {'1x'};
            right.RowSpacing = 10;

            app.Axes = gobjects(app.NRows,1);
            app.StructDrop  = gobjects(app.NRows,1);
            app.SignalDrop  = gobjects(app.NRows,1);
            app.YMinField   = gobjects(app.NRows,1);
            app.YMaxField   = gobjects(app.NRows,1);
            app.YResetBtn   = gobjects(app.NRows,1);
            app.StructDrop2 = gobjects(app.NRows,1);
            app.SignalDrop2 = gobjects(app.NRows,1);
            app.YMinField2  = gobjects(app.NRows,1);
            app.YMaxField2  = gobjects(app.NRows,1);
            app.YResetBtn2  = gobjects(app.NRows,1);
            app.LastStruct  = ["epsi"; "epsi"; "epsi"; "epsi"; "ctd"; "ctd"];
            app.LastSignal  = ["t1_volt"; "t2_volt"; "s1_volt"; "s2_volt"; "z"; "T"];
            app.LastStruct2 = strings(app.NRows,1);   % all "" => axis 2 starts as "(none)"
            app.LastSignal2 = strings(app.NRows,1);
            app.YTickTextHandles = cell(app.NRows, 1);
            app.Axis1Color = repmat({[0.15 0.15 0.15]}, app.NRows, 1);



            for i = 1:app.NRows
                % Row container: axes on left, two control panels on right
                % (axis 1 / left-axis controls, then axis 2 / right-axis controls)
                row = uigridlayout(right,[1 3]);
                row.Layout.Row = i;
                row.Layout.Column = 1;
                row.RowHeight = {'1x'};
                row.ColumnWidth = {'1x', 210, 210};
                row.ColumnSpacing = 10;
                row.Padding = [68 0 0 0];  % left margin reserved for custom y-tick labels

                % Axes (left)
                app.Axes(i) = uiaxes(row);
                app.Axes(i).FontSize = app.AxesTickFontSize;
                app.Axes(i).XLabel.FontSize = app.AxesLabelFontSize;
                app.Axes(i).YLabel.FontSize = app.AxesLabelFontSize;
                app.Axes(i).Layout.Row = 1;
                app.Axes(i).Layout.Column = 1;
                grid(app.Axes(i),'on');

                % Blank YTickLabel (set in plotRow) keeps TightInset uniform so
                % all axes share identical left/right edges.  Custom labels are
                % text() objects drawn in the 68-px left padding reserved above.
                app.Axes(i).PositionConstraint = 'innerposition';

                % Re-blank labels and refresh text objects whenever y-limits
                % change (covers user y-zoom as well as programmatic changes).
                ii = i;
                addlistener(app.Axes(i), 'YLim', 'PostSet', ...
                    @(~,~)app.onAxesYLimChanged(ii));

                % Controls panels (right): axis 1 (left y-axis) then axis 2
                % (right y-axis, optional - "(none)" disables it)
                app.buildAxisControls(row, 2, i, 1);
                app.buildAxisControls(row, 3, i, 2);
            end

            % Link x-axes so zoom/pan syncs across all panels
            linkaxes(app.Axes, 'x');

            % Mark HasUserZoomed only when the USER zooms/pans (toolbar/mouse)
            z = zoom(app.Fig);
            z.ActionPostCallback = @(~,~)app.onUserZoomPan();

            p = pan(app.Fig);
            p.ActionPostCallback = @(~,~)app.onUserZoomPan();

            % Initialize SignalColors
            app.SignalColors = app.defineSignalColors();

        end

        function buildAxisControls(app, parent, colIdx, rowIdx, axisNum)
            % Builds one "Struct / Signal / Y-limits / Reset" control panel
            % for either axis 1 (left, always active) or axis 2 (right,
            % optional - its Struct dropdown includes NoneItem as the first,
            % default entry so the row can be plotted with just one signal).
            ctrl = uigridlayout(parent,[5 3]);
            ctrl.Layout.Row = 1;
            ctrl.Layout.Column = colIdx;
            ctrl.RowHeight = {16, 28, 28, 26, 22};
            ctrl.ColumnWidth = {52, '1x', '1x'};
            ctrl.RowSpacing = 3;
            ctrl.Padding = [0 0 0 0];

            if axisNum == 1
                hdrText = 'Left axis';
            else
                hdrText = 'Right axis (optional)';
            end
            hdr = uilabel(ctrl,'Text',hdrText,'FontWeight','bold');
            hdr.Layout.Row = 1; hdr.Layout.Column = [1 3];
            hdr.FontSize = 11;

            lbl1 = uilabel(ctrl,'Text','Struct');
            lbl1.Layout.Row = 2; lbl1.Layout.Column = 1;
            lbl1.VerticalAlignment = 'center';

            if axisNum == 1
                structItems = {};
            else
                structItems = {app.NoneItem};
            end
            structDrop = uidropdown(ctrl,'Items',structItems, ...
                'ValueChangedFcn', @(~,~)app.onStructChanged(rowIdx, axisNum));
            structDrop.Layout.Row = 2; structDrop.Layout.Column = [2 3];

            lbl2 = uilabel(ctrl,'Text','Signal');
            lbl2.Layout.Row = 3; lbl2.Layout.Column = 1;
            lbl2.VerticalAlignment = 'center';

            signalDrop = uidropdown(ctrl,'Items',{}, ...
                'ValueChangedFcn', @(~,~)app.onSignalChanged(rowIdx, axisNum));
            signalDrop.Layout.Row = 3; signalDrop.Layout.Column = [2 3];
            app.trySetProp(signalDrop,'Tooltip','Signal (supports nested fields)');

            ylbl = uilabel(ctrl,'Text','Y-limits');
            ylbl.Layout.Row = 4; ylbl.Layout.Column = 1;
            ylbl.VerticalAlignment = 'center';

            yMinField = uieditfield(ctrl,'numeric', ...
                'Placeholder','min', ...
                'ValueChangedFcn', @(~,~)app.onYLimitChanged(rowIdx, axisNum));
            yMinField.Layout.Row = 4; yMinField.Layout.Column = 2;

            yMaxField = uieditfield(ctrl,'numeric', ...
                'Placeholder','max', ...
                'ValueChangedFcn', @(~,~)app.onYLimitChanged(rowIdx, axisNum));
            yMaxField.Layout.Row = 4; yMaxField.Layout.Column = 3;

            yResetBtn = uibutton(ctrl,'Text','Reset y-limits', ...
                'ButtonPushedFcn', @(~,~)app.onYLimitReset(rowIdx, axisNum));
            yResetBtn.Layout.Row = 5; yResetBtn.Layout.Column = [2 3];

            if axisNum == 1
                app.StructDrop(rowIdx) = structDrop;
                app.SignalDrop(rowIdx) = signalDrop;
                app.YMinField(rowIdx)  = yMinField;
                app.YMaxField(rowIdx)  = yMaxField;
                app.YResetBtn(rowIdx)  = yResetBtn;
            else
                app.StructDrop2(rowIdx) = structDrop;
                app.SignalDrop2(rowIdx) = signalDrop;
                app.YMinField2(rowIdx)  = yMinField;
                app.YMaxField2(rowIdx)  = yMaxField;
                app.YResetBtn2(rowIdx)  = yResetBtn;
            end
        end

        function chooseFolder(app)
            p = uigetdir(char(app.Folder), 'Select L0 folder');
            if isequal(p,0); return; end
            app.loadFolder(string(p));
        end

        function loadFolder(app, folder)
            folder = string(folder);
            if ~isfolder(folder)
                uialert(app.Fig, "Folder not found: " + folder, "Folder error");
                return;
            end

            app.Folder = folder;
            app.FolderLbl.Text = folder;

            d = dir(fullfile(folder,"*.mat"));
            names = string({d.name})';
            names = sort(names);
            app.Files = names;

            if isempty(names)
                app.FileList.Items = {};
                app.CurrentData = struct();
                app.CurrentFile = "";
                app.Fig.Name = "L0 Explorer (no files)";
                app.populateSelectorsEmpty();
                return;
            end

            app.FileList.Items = cellstr(names);
            app.FileList.Value = app.FileList.Items{1}; % always set valid selection
            app.onFileSelected();
        end

        function populateSelectorsEmpty(app)
            for i = 1:app.NRows
                app.StructDrop(i).Items = {};
                app.SignalDrop(i).Items = {};
                app.StructDrop2(i).Items = {};
                app.SignalDrop2(i).Items = {};
                cla(app.Axes(i));
            end
        end

        function onFileSelected(app)
            val = app.FileList.Value;
            if isempty(val); return; end

            app.CurrentFile = string(val);
            fp = fullfile(app.Folder, app.CurrentFile);

            try
                S = load(fp);
            catch ME
                uialert(app.Fig, "Failed to load: " + fp + newline + ME.message, "Load error");
                return;
            end

            % Unwrap Profile wrapper (profiles directory format)
            if isfield(S, 'Profile') && isstruct(S.Profile)
                S = S.Profile;
            end

            app.CurrentData = S;

            % Build a global dnum (used to initialize linked axes and as fallback)
            app.GlobalDnum = [];
            d = app.findFirstDnumInStruct(S);
            if ~isempty(d)
                app.GlobalDnum = d(:);
            end

            % Store profile time range for x-window
            if ~isempty(app.GlobalDnum)
                app.ProfileTmin = min(app.GlobalDnum);
                app.ProfileTmax = max(app.GlobalDnum);
            else
                app.ProfileTmin = 0;
                app.ProfileTmax = 0;
            end

            % IMPORTANT: linked axes start at [0 1]. Set XLim so data is visible.
            if ~isempty(app.GlobalDnum)
                tmin = min(app.GlobalDnum);
                tmax = max(app.GlobalDnum);
                if isfinite(tmin) && isfinite(tmax) && tmax > tmin
                    app.Axes(1).XLim = [tmin tmax];  % propagates to all due to linkaxes
                end
            end

            % New file => treat as not user-zoomed yet
            app.HasUserZoomed = false;

            % Title: prefer raw_file_info.filename if present
            ttl = app.CurrentFile;
            if isfield(S,'raw_file_info') && isstruct(S.raw_file_info) && isfield(S.raw_file_info,'filename')
                try
                    ttl = string(S.raw_file_info.filename);
                catch
                end
            end
            app.Fig.Name = "L0 Explorer — " + ttl;

            structs = app.getTopStructCandidates(S);

            for i = 1:app.NRows
                % Update struct list
                app.StructDrop(i).Items = cellstr(structs);

                if isempty(structs)
                    app.StructDrop(i).Items = {};
                    app.SignalDrop(i).Items = {};
                    app.StructDrop2(i).Items = {};
                    app.SignalDrop2(i).Items = {};
                    cla(app.Axes(i));
                    continue;
                end

                % --- Axis 1 (left, required): restore selection if possible ---
                app.LastStruct(i) = app.restoreOrDefault(app.StructDrop(i), app.LastStruct(i));

                topName = app.LastStruct(i);
                topStruct = app.CurrentData.(topName);
                signals = app.listNumericSignals(topStruct);
                signals = signals(signals ~= "dnum");

                if isempty(signals)
                    app.SignalDrop(i).Items = {};
                    cla(app.Axes(i));
                else
                    app.SignalDrop(i).Items = cellstr(signals);
                    app.LastSignal(i) = app.restoreOrDefault(app.SignalDrop(i), app.LastSignal(i));
                end

                % --- Axis 2 (right, optional): "(none)" always first ---
                app.StructDrop2(i).Items = [{app.NoneItem}; cellstr(structs)];
                app.LastStruct2(i) = app.restoreOrDefault(app.StructDrop2(i), app.LastStruct2(i));
                app.populateAxis2Signal(i);

                % Plot using the restored selections
                app.plotRow(i);
            end

            % Apply x-window at the same fractional position in the new profile
            if app.UseXWindow
                app.applyXWindow();
            end

        end

        function value = restoreOrDefault(app, dropdown, lastVal) %#ok<INUSD>
            % Pick lastVal if it's still a valid item on this dropdown, else
            % default to the dropdown's first item. Returns the value that
            % ends up selected (so the caller can store it back into
            % LastStruct/LastSignal/etc).
            if strlength(lastVal) > 0 && any(strcmp(dropdown.Items, char(lastVal)))
                dropdown.Value = char(lastVal);
            else
                dropdown.Value = dropdown.Items{1};
            end
            value = string(dropdown.Value);
        end

        function populateAxis2Signal(app, rowIdx)
            % Fills SignalDrop2 for whatever is currently selected in
            % StructDrop2(rowIdx), or clears it out when that's NoneItem
            % (or the chosen struct turns out to have no plottable signals).
            if strcmp(app.StructDrop2(rowIdx).Value, app.NoneItem)
                app.SignalDrop2(rowIdx).Items = {};
                app.LastStruct2(rowIdx) = "";
                app.LastSignal2(rowIdx) = "";
                return;
            end

            topName2 = string(app.StructDrop2(rowIdx).Value);
            app.LastStruct2(rowIdx) = topName2;
            topStruct2 = app.CurrentData.(topName2);
            signals2 = app.listNumericSignals(topStruct2);
            signals2 = signals2(signals2 ~= "dnum");

            if isempty(signals2)
                app.SignalDrop2(rowIdx).Items = {};
                app.StructDrop2(rowIdx).Value = app.NoneItem;
                app.LastStruct2(rowIdx) = "";
                app.LastSignal2(rowIdx) = "";
                return;
            end

            app.SignalDrop2(rowIdx).Items = cellstr(signals2);
            app.LastSignal2(rowIdx) = app.restoreOrDefault(app.SignalDrop2(rowIdx), app.LastSignal2(rowIdx));
        end

        function structs = getTopStructCandidates(app, S) %#ok<INUSD>
            f = fieldnames(S);
            keep = false(size(f));

            for k = 1:numel(f)
                name = f{k};
                if strcmp(name,'raw_file_info'); continue; end
                if isstruct(S.(name))
                    keep(k) = true;
                end
            end

            structs = string(f(keep));

            pref = ["epsi","ctd","gps","alt","act","seg","spec","fluor","ttv","vnav","isap","apf"];
            [isIn, loc] = ismember(pref, structs);     % loc indexes into 'structs'
            ordered = structs(loc(isIn));              % keep only those found, in pref order
            rest = setdiff(structs, ordered, 'stable');
            structs = [ordered(:); rest(:)];           % force columns; ordered is row-shaped when pref (a row) drives the indexing

        end

        function onStructChanged(app, rowIdx, axisNum)
            if isempty(app.CurrentFile) || isempty(fieldnames(app.CurrentData))
                return;
            end

            if axisNum == 2
                app.populateAxis2Signal(rowIdx);
                app.plotRow(rowIdx);
                return;
            end

            topName = string(app.StructDrop(rowIdx).Value);
            if topName == "" || ~isfield(app.CurrentData, topName)
                app.SignalDrop(rowIdx).Items = {};
                return;
            end

            % Save selections whenever user changes them
            app.LastStruct(rowIdx) = topName;

            topStruct = app.CurrentData.(topName);
            signals = app.listNumericSignals(topStruct);

            signals = signals(signals ~= "dnum"); % dnum is implicit

            if isempty(signals)
                app.SignalDrop(rowIdx).Items = {};
            else
                app.SignalDrop(rowIdx).Items = cellstr(signals);
                app.SignalDrop(rowIdx).Value = app.SignalDrop(rowIdx).Items{1};
                app.LastSignal(rowIdx) = string(app.SignalDrop(rowIdx).Value);
                app.plotRow(rowIdx);
            end

        end

        function onSignalChanged(app, rowIdx, axisNum)
            % Plot immediately when signal selection changes
            if axisNum == 2
                signalDrop = app.SignalDrop2(rowIdx);
            else
                signalDrop = app.SignalDrop(rowIdx);
            end

            if isempty(signalDrop.Items) || isempty(signalDrop.Value)
                return;
            end

            if axisNum == 2
                app.LastSignal2(rowIdx) = string(signalDrop.Value);
            else
                app.LastSignal(rowIdx) = string(signalDrop.Value);
            end
            app.plotRow(rowIdx);
        end

        function signals = listNumericSignals(app, S)
            signals = strings(0,1);
            if ~isstruct(S); return; end

            signals = app.recurseSignals(S, "");

            [~,idx] = unique(signals,'stable');
            signals = signals(idx);
        end

        function out = recurseSignals(app, S, prefix) %#ok<INUSD>
            out = strings(0,1);
            f = fieldnames(S);

            for k = 1:numel(f)
                name = f{k};
                val = S.(name);

                if prefix == ""
                    path = string(name);
                else
                    path = prefix + "." + string(name);
                end

                if isstruct(val)
                    out = [out; app.recurseSignals(val, path)]; %#ok<AGROW>
                else
                    if isnumeric(val) && ~isempty(val)
                        sz = size(val);
                        isVectorLike = isvector(val) || (numel(sz)==2 && (sz(1)==1 || sz(2)==1));
                        if isVectorLike
                            out = [out; path]; %#ok<AGROW>
                        end
                    end
                end
            end
        end

        function C = defineSignalColors(app) %#ok<INUSD>
            C = struct();

            C.a1_g = [129 27 112]./255;
            C.a2_g = [235 64 61]./255;
            C.a3_g = [245 199 118]./255;
            C.s1_volt = [60 134 76]./255;
            C.s2_volt = [173 215 136]./255;
            C.t1_volt = [29 78 140]./255;
            C.t2_volt = [78 173 173]./255;
            C.s1_count = [60 134 76]./255;
            C.s2_count = [173 215 136]./255;
            C.t1_count = [29 78 140]./255;
            C.t2_count = [78 173 173]./255;

            C.P = [0 0 0];
            C.P_raw = [0 0 0];
            C.dPdt = [0.4 0.4 0.4];

            C.T = [0.8941 0.1020 0.1098];
            C.T_raw = [0.8941 0.1020 0.1098];
            C.S = [0.2157 0.4941 0.7216];
            C.S_raw = [0.2157 0.4941 0.7216];

            C.alt = [0 0 1];

            C.gyro1 = [129 27 112]./255;
            C.gyro2 = [235 64 61]./255;
            C.gyro3 = [245 199 118]./255;

            C.compass1 = [0 0 0.543];
            C.compass2 = [185 38 26]./255;
            C.compass3 = [0 0 0];

            C.chla = [0.1059 0.6196 0.4667];
            C.bb   = [0.4000 0.6510 0.1176];
            C.fdom = [0.9020 0.6706 0.0078];
            C.ucond = [0.7373 0.5020 0.7412];

            C.channel1 = [0.3686 0.3098 0.6353];
            C.channel2 = [0.3127 0.6971 0.6726];
            C.channel3 = [0.7616 0.9058 0.6299];
            C.channel4 = [0.9500 0.9500 0.7116];
            C.channel5 = [0.9942 0.7583 0.4312];
            C.channel6 = [0.9288 0.3634 0.2749];
            C.channel7 = [0.6196 0.0039 0.2588];
        end


        function plotRow(app, rowIdx)
            if isempty(app.CurrentFile) || isempty(fieldnames(app.CurrentData))
                uialert(app.Fig, "Select a file first.", "No file");
                return;
            end

            ax = app.Axes(rowIdx);
            dual = numel(ax.YAxis) > 1;   % has this row ever used a right axis?

            % Preserve x-limits if the user has zoomed/panned or the x-window is active
            keepX = app.HasUserZoomed || app.UseXWindow;
            if keepX
                xlim0 = ax.XLim;
                keepX = all(isfinite(xlim0)) && xlim0(2) > xlim0(1) && xlim0(2) > 1000;
            end

            cla(ax);

            % ----- Axis 1 (left, required) -----
            if dual
                yyaxis(ax, 'left');
            end
            [ok, dnumSrc, clr1] = app.plotOneSignal(ax, rowIdx, true, ...
                app.StructDrop(rowIdx), app.SignalDrop(rowIdx), ...
                app.YMinField(rowIdx), app.YMaxField(rowIdx));
            if ~ok
                return;
            end

            % ----- Axis 2 (right, optional) -----
            axis2Active = ~strcmp(app.StructDrop2(rowIdx).Value, app.NoneItem) ...
                && ~isempty(app.SignalDrop2(rowIdx).Items) && ~isempty(app.SignalDrop2(rowIdx).Value);

            if axis2Active
                yyaxis(ax, 'right');
                ax.YAxis(2).Visible = 'on';
                app.plotOneSignal(ax, rowIdx, false, ...
                    app.StructDrop2(rowIdx), app.SignalDrop2(rowIdx), ...
                    app.YMinField2(rowIdx), app.YMaxField2(rowIdx), clr1);
                yyaxis(ax, 'left');
            elseif dual
                % Previously had a right-axis signal, now set back to
                % "(none)". MATLAB has no clean way to fully undo yyaxis
                % mode, so just hide the unused right ruler.
                yyaxis(ax, 'right');
                ax.YAxis(2).Visible = 'off';
                yyaxis(ax, 'left');
            end

            grid(ax,'on');
            try
                datetick(ax,'x','keeplimits'); %#ok<DATETICK>
            catch
            end

            app.trySetProp(ax.XLabel,'Interpreter','none');
            app.trySetProp(ax.YLabel,'Interpreter','none');
            xlabel(ax, sprintf('dnum (%s)', dnumSrc));

            if keepX
                ax.XLim = xlim0;
            end

            % Apply x-window (overrides zoom/pan-preserved limits)
            if app.UseXWindow && isfinite(app.ProfileTmin) && app.ProfileTmax > app.ProfileTmin
                winDays    = app.XWindowLen / 86400;
                profileDur = app.ProfileTmax - app.ProfileTmin;
                if winDays < profileDur
                    winStart = app.ProfileTmin + app.XWinFraction * profileDur;
                    winStart = max(winStart, app.ProfileTmin);
                    winStart = min(winStart, app.ProfileTmax - winDays);
                    ax.XLim  = [winStart, winStart + winDays];
                end
            end
        end

        function [ok, dnumSrc, clr] = plotOneSignal(app, ax, rowIdx, isPrimary, structDrop, signalDrop, yMinField, yMaxField, primaryClr)
            % Plots one signal on whichever y-axis side is currently active
            % (caller must have already called yyaxis(ax,'left'/'right') as
            % needed). isPrimary = axis 1 (left, required) - it gets the
            % custom blanked-tick-label treatment used for left-margin
            % alignment; axis 2 (right, optional) uses native yyaxis ticks.
            % primaryClr (axis 2 only) is the color already used on axis 1,
            % so a clashing axis-2 color can be swapped for a distinct one.
            if nargin < 9
                primaryClr = [];
            end
            ok = false;
            dnumSrc = "";
            clr = [];

            topName = string(structDrop.Value);
            sigPath = string(signalDrop.Value);

            if topName == "" || sigPath == "" || strcmp(topName, app.NoneItem)
                if isPrimary
                    uialert(app.Fig, "Pick a struct and signal.", "Missing selection");
                end
                return;
            end

            if ~isfield(app.CurrentData, topName)
                uialert(app.Fig, "Struct not found in file: " + topName, "Missing struct");
                return;
            end

            topStruct = app.CurrentData.(topName);

            [dnum, dnumSrc] = app.getDnum(topStruct, app.CurrentData);
            if isempty(dnum)
                uialert(app.Fig, "No dnum found (looked for " + topName + ".dnum then top-level dnum).", ...
                    "Missing time");
                return;
            end

            try
                y = app.getByDotPath(topStruct, sigPath);
            catch ME
                uialert(app.Fig, "Could not access " + topName + "." + sigPath + newline + ME.message, "Signal error");
                return;
            end

            if ~isnumeric(y) || isempty(y)
                uialert(app.Fig, "Selected signal is empty or not numeric.", "Signal error");
                return;
            end

            dnum = dnum(:);
            y = y(:);

            n = min(numel(dnum), numel(y));
            dnum = dnum(1:n);
            y = y(1:n);

            % Preserve y-limits if the user has manually set them (via the
            % fields), so they carry over across signal/file changes until
            % explicitly reset.
            keepY = strcmp(ax.YLimMode, 'manual');
            if keepY
                ylim0 = ax.YLim;
            end

            clr = app.getSignalColor(sigPath);
            if ~isPrimary && ~isempty(primaryClr)
                clr = app.resolveAxis2Color(clr, primaryClr);
            end
            try
                if app.UseLine
                    plot(ax, dnum, y, '-', 'Color', clr, 'LineWidth', 0.5);
                else
                    plot(ax, dnum, y, '.', 'Color', clr);
                end
            catch ME
                uialert(app.Fig, "Plot failed for " + topName + "." + sigPath + newline + ME.message, "Plot error");
                return;
            end

            % Tint the y-axis ruler to match the data it carries, so the
            % axis on each side is visually tied to its own signal.
            if isPrimary
                app.Axis1Color{rowIdx} = clr;
                ax.YAxis(1).Color = clr;
            elseif numel(ax.YAxis) >= 2
                ax.YAxis(2).Color = clr;
            end

            % Reverse y-axis for pressure/depth signals
            if app.shouldReverseY(topName, sigPath)
                ax.YDir = 'reverse';
            else
                ax.YDir = 'normal';
            end

            if isPrimary
                % Blank all y-tick labels so TightInset(1) is near-zero and
                % identical for every axes row -> perfect left AND right edge
                % alignment always. The actual values are shown by text()
                % objects in updateYTickText().
                nt = numel(ax.YTick);
                if nt > 0
                    ax.YTickLabel = repmat({''}, 1, nt);
                end
            end

            if keepY
                % Re-apply the user's manual y-limits over the new data.
                ax.YLim = ylim0;
            else
                % Auto-scale to the freshly plotted data and sync the
                % y-limit fields to show the current view.
                ax.YLimMode = 'auto';
                autoYLim = ax.YLim;
                yMinField.Value = autoYLim(1);
                yMaxField.Value = autoYLim(2);
            end

            if isPrimary
                % Draw custom y-tick labels in the reserved left margin.
                % Called last so YLim/YTick are fully settled.
                app.updateYTickText(rowIdx);
            end

            ok = true;
        end

        function onPlotStyleChanged(app)
            app.UseLine = app.PlotStyleCheck.Value;
            for i = 1:app.NRows
                if ~isempty(app.SignalDrop(i).Items) && ~isempty(app.SignalDrop(i).Value)
                    app.plotRow(i);
                end
            end
        end

        function onXWinLenChanged(app)
            val = app.XWinLenField.Value;
            if isnan(val) || val <= 0
                app.onXWinReset();
                return;
            end
            app.XWindowLen  = val;
            app.UseXWindow  = true;
            app.XWinSlider.Enable = 'on';
            app.applyXWindow();
        end

        function onXWinSliderMoved(app)
            if ~app.UseXWindow; return; end
            app.XWinFraction = app.XWinSlider.Value / 100;
            app.applyXWindow();
        end

        function onXWinSliderChanging(app, evt)
            if ~app.UseXWindow; return; end
            app.XWinFraction = evt.Value / 100;
            app.applyXWindow();
        end

        function onXWinReset(app)
            app.UseXWindow   = false;
            app.HasUserZoomed = false;
            app.XWinFraction = 0;
            app.XWinSlider.Value  = 0;
            app.XWinSlider.Enable = 'off';
            if isfinite(app.ProfileTmin) && app.ProfileTmax > app.ProfileTmin
                app.Axes(1).XLim = [app.ProfileTmin, app.ProfileTmax];
                for i = 1:app.NRows
                    try; datetick(app.Axes(i),'x','keeplimits'); catch; end
                end
            end
        end

        function applyXWindow(app)
            if ~app.UseXWindow; return; end
            if ~isfinite(app.ProfileTmin) || app.ProfileTmax <= app.ProfileTmin; return; end

            winDays    = app.XWindowLen / 86400;
            profileDur = app.ProfileTmax - app.ProfileTmin;

            if winDays >= profileDur
                app.Axes(1).XLim = [app.ProfileTmin, app.ProfileTmax];
                app.XWinSlider.Value = 0;
                for i = 1:app.NRows
                    try; datetick(app.Axes(i),'x','keeplimits'); catch; end
                end
                return;
            end

            maxFrac  = 1 - winDays / profileDur;
            frac     = min(max(app.XWinFraction, 0), maxFrac);
            winStart = app.ProfileTmin + frac * profileDur;

            app.Axes(1).XLim     = [winStart, winStart + winDays];
            app.XWinSlider.Value = frac * 100;

            for i = 1:app.NRows
                try; datetick(app.Axes(i),'x','keeplimits'); catch; end
            end
        end

        function onYLimitChanged(app, rowIdx, axisNum)
            ax = app.Axes(rowIdx);
            dual = numel(ax.YAxis) > 1;

            if axisNum == 2
                if ~dual; return; end  % no right axis active
                ymin = app.YMinField2(rowIdx).Value;
                ymax = app.YMaxField2(rowIdx).Value;
                if ~(isfinite(ymin) && isfinite(ymax) && ymax > ymin); return; end
                yyaxis(ax, 'right');
                ax.YLim = [ymin ymax];
                yyaxis(ax, 'left');
            else
                ymin = app.YMinField(rowIdx).Value;
                ymax = app.YMaxField(rowIdx).Value;
                if ~(isfinite(ymin) && isfinite(ymax) && ymax > ymin); return; end
                if dual; yyaxis(ax, 'left'); end
                ax.YLim = [ymin ymax];
            end
        end

        function onYLimitReset(app, rowIdx, axisNum)
            ax = app.Axes(rowIdx);
            dual = numel(ax.YAxis) > 1;

            if axisNum == 2
                if ~dual; return; end  % no right axis active
                yyaxis(ax, 'right');
                ax.YLimMode = 'auto';
                autoYLim = ax.YLim;
                app.YMinField2(rowIdx).Value = autoYLim(1);
                app.YMaxField2(rowIdx).Value = autoYLim(2);
                yyaxis(ax, 'left');
            else
                if dual; yyaxis(ax, 'left'); end
                ax.YLimMode = 'auto';
                autoYLim = ax.YLim;
                app.YMinField(rowIdx).Value = autoYLim(1);
                app.YMaxField(rowIdx).Value = autoYLim(2);
            end
        end

        function clr = getSignalColor(app, sigPath)
            % Default: dark gray RGB
            clr = [0.3 0.3 0.3];

            parts = split(sigPath,'.');
            key = char(parts(end));

            if isfield(app.SignalColors, key)
                c = app.SignalColors.(key);

                % If stored as short color char, convert to RGB
                if ischar(c) || (isstring(c) && isscalar(c))
                    clr = app.colorCharToRGB(char(c));
                elseif isnumeric(c) && numel(c)==3
                    clr = double(c(:)).';
                end
            end
        end

        function clr = resolveAxis2Color(app, clr, primaryClr)
            % If the axis-2 signal's natural color is too close to the
            % axis-1 color, swap it for the next distinct entry from a
            % fixed fallback palette (MATLAB's standard default axes
            % color order - none of those RGB triplets are used anywhere
            % in SignalColors, so they read as clearly "not axis 1").
            clashThresh = 0.25; % Euclidean distance in RGB, [0,1] scale
            if norm(clr(:) - primaryClr(:)) >= clashThresh
                return;
            end

            altColors = [ ...
                0.8500 0.3250 0.0980;  % orange
                0.9290 0.6940 0.1250;  % yellow
                0.4940 0.1840 0.5560;  % purple
                0.4660 0.6740 0.1880;  % green
                0.3010 0.7450 0.9330;  % cyan
                0.6350 0.0780 0.1840;  % dark red
                0      0.4470 0.7410]; % blue

            for k = 1:size(altColors,1)
                if norm(altColors(k,:) - primaryClr(:).') >= clashThresh
                    clr = altColors(k,:);
                    return;
                end
            end
        end

        function rgb = colorCharToRGB(app, c) %#ok<INUSD>
            switch lower(c)
                case 'k', rgb = [0 0 0];
                case 'w', rgb = [1 1 1];
                case 'r', rgb = [1 0 0];
                case 'g', rgb = [0 1 0];
                case 'b', rgb = [0 0 1];
                case 'c', rgb = [0 1 1];
                case 'm', rgb = [1 0 1];
                case 'y', rgb = [1 1 0];
                otherwise, rgb = [0.3 0.3 0.3];
            end
        end



        function onUserZoomPan(app)
            app.HasUserZoomed = true;
        end

        function tf = shouldReverseY(app, topName, sigPath) %#ok<INUSD>
            % Reverse for pressure/depth-like signals
            tf = false;

            parts = split(sigPath,'.');
            key = lower(parts(end));

            if ismember(key, {'p','p_raw','z'})
                tf = true;
            end
        end


        function [dnum, src] = getDnum(app, topStruct, S) %#ok<INUSD>
            dnum = [];
            src = "";

            % 1) Best: dnum in the selected struct
            if isstruct(topStruct) && isfield(topStruct,'dnum') && isnumeric(topStruct.dnum) && ~isempty(topStruct.dnum)
                d = topStruct.dnum(:);
                d = d(isfinite(d));
                if numel(d) >= 2
                    dnum = d;
                    src = "struct.dnum";
                    return;
                end
            end

            % 2) Next: top-level dnum
            if isfield(S,'dnum') && isnumeric(S.dnum) && ~isempty(S.dnum)
                d = S.dnum(:);
                d = d(isfinite(d));
                if numel(d) >= 2
                    dnum = d;
                    src = "top-level dnum";
                    return;
                end
            end

            % 3) Next: cached global dnum from file scan
            if ~isempty(app.GlobalDnum)
                d = app.GlobalDnum(:);
                d = d(isfinite(d));
                if numel(d) >= 2
                    dnum = d;
                    src = "cached global dnum";
                    return;
                end
            end

            % 4) Last resort: search anywhere in the file for a usable dnum
            d = app.findFirstDnumInStruct(S);
            if ~isempty(d)
                dnum = d(:);
                src = "auto-scanned dnum";
                return;
            end
        end

        function dnum = findFirstDnumInStruct(app, S) %#ok<INUSD>
            % Recursively search a struct for a numeric field named 'dnum'
            % Returns the first usable (>=2 finite values) vector found.

            dnum = [];

            if ~isstruct(S); return; end

            f = fieldnames(S);
            for k = 1:numel(f)
                nm = f{k};
                v = S.(nm);

                if strcmpi(nm,'dnum') && isnumeric(v) && ~isempty(v)
                    d = v(:);
                    d = d(isfinite(d));
                    if numel(d) >= 2
                        dnum = d;
                        return;
                    end
                end

                if isstruct(v)
                    d = app.findFirstDnumInStruct(v);
                    if ~isempty(d)
                        dnum = d;
                        return;
                    end
                end
            end
        end


        function val = getByDotPath(app, S, path) %#ok<INUSD>
            parts = split(string(path), ".");
            val = S;

            for i = 1:numel(parts)
                p = char(parts(i));
                if ~isstruct(val) || ~isfield(val, p)
                    error("Missing field '%s' in path '%s'.", p, path);
                end
                val = val.(p);
            end
        end

        function trySetProp(app, h, propName, propValue) %#ok<INUSD>
            % Safely set optional UI properties without crashing on releases/controls
            if isempty(h) || ~isvalid(h); return; end
            if isprop(h, propName)
                try
                    h.(propName) = propValue;
                catch
                end
            end
        end

        function onAxesYLimChanged(app, rowIdx)
            % Fires via PostSet listener whenever an axes' YLim changes
            % (signal change, y-lock, or user y-zoom).  Re-blank tick labels
            % (in case MATLAB auto-restored them) and refresh text objects.
            % Only the left (axis 1) y-axis uses the custom text-label
            % treatment, so force 'left' active first - the PostSet event
            % can fire while the right axis is the active side.
            if isempty(app.YTickTextHandles) || rowIdx > numel(app.Axes)
                return;
            end
            ax = app.Axes(rowIdx);
            if ~isvalid(ax); return; end
            if numel(ax.YAxis) > 1
                yyaxis(ax, 'left');
            end
            n = numel(ax.YTick);
            if n > 0
                try; ax.YTickLabel = repmat({''}, 1, n); catch; end
            end
            app.updateYTickText(rowIdx);
        end

        function updateYTickText(app, rowIdx)
            % Delete old custom tick-label text objects and draw fresh ones
            % in the 68-px left padding area, just outside the axes boundary.
            % Always operates on the left (axis 1) y-axis.
            if isempty(app.YTickTextHandles) || rowIdx > numel(app.YTickTextHandles)
                return;
            end
            ax = app.Axes(rowIdx);
            if ~isvalid(ax); return; end
            if numel(ax.YAxis) > 1
                yyaxis(ax, 'left');
            end

            % Remove stale handles (cla() or previous call may have deleted them)
            old = app.YTickTextHandles{rowIdx};
            if ~isempty(old)
                try; delete(old(isvalid(old))); catch; end
            end
            app.YTickTextHandles{rowIdx} = gobjects(0);

            ticks = ax.YTick;
            if isempty(ticks); return; end

            ylim = ax.YLim;
            span = ylim(2) - ylim(1);
            if ~isfinite(span) || span == 0; return; end

            reversed = strcmp(ax.YDir, 'reverse');
            handles  = gobjects(0);

            txtColor = [0.15 0.15 0.15];
            if rowIdx <= numel(app.Axis1Color) && ~isempty(app.Axis1Color{rowIdx})
                txtColor = app.Axis1Color{rowIdx};
            end

            for k = 1:numel(ticks)
                val = ticks(k);
                % Normalized display position (0=bottom, 1=top of axes)
                if reversed
                    norm_y = (ylim(2) - val) / span;
                else
                    norm_y = (val - ylim(1)) / span;
                end
                if norm_y < -0.05 || norm_y > 1.05; continue; end

                label = app.smartFormatTick(val, ticks);

                % x=0 is the axes left edge in axes-normalized units.
                % HorizontalAlignment='right' + Clipping='off' draws the
                % label to the LEFT of the axes, into the 68-px padding.
                t = text(ax, 0, norm_y, [label ' '], ...
                    'Units',               'normalized', ...
                    'HorizontalAlignment', 'right', ...
                    'VerticalAlignment',   'middle', ...
                    'Clipping',            'off', ...
                    'FontSize',            app.AxesTickFontSize, ...
                    'Color',               txtColor);
                handles(end+1) = t; %#ok<AGROW>
            end

            app.YTickTextHandles{rowIdx} = handles;
        end

        function s = smartFormatTick(app, val, allTicks) %#ok<INUSL>
            % Natural tick formatting:
            %   • Scientific (%.3e) for magnitudes >= 10000 or < 0.01
            %   • Fixed with just enough decimal places otherwise
            % Width is irrelevant — alignment comes from blank YTickLabel.
            if ~isfinite(val); s = ''; return; end
            if val == 0;       s = '0'; return; end

            finTicks = allTicks(isfinite(allTicks) & allTicks ~= 0);
            if isempty(finTicks)
                maxAbs = abs(val);
            else
                maxAbs = max(abs(finTicks));
            end

            if maxAbs >= 10000 || maxAbs < 0.01
                s = sprintf('%.3e', val);
                return;
            end

            % Fixed: pick decimal places from the tick spacing
            sorted = sort(allTicks(isfinite(allTicks)));
            if numel(sorted) >= 2
                steps = abs(diff(sorted));
                step  = min(steps(steps > 0));
            else
                step = maxAbs;
            end

            if     step >= 50,    s = sprintf('%.0f', val);
            elseif step >= 5,     s = sprintf('%.1f', val);
            elseif step >= 0.5,   s = sprintf('%.2f', val);
            elseif step >= 0.05,  s = sprintf('%.3f', val);
            else,                 s = sprintf('%.4f', val);
            end
        end

    end
end
