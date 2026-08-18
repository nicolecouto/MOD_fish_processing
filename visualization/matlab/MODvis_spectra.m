classdef MODvis_spectra < handle
    % MODvis_spectra        Part of MOD_fish_processing
    % Browse a folder of L2 *.mat files (MODprocess_single/all_L1_to_L2.m
    % output: dnum, pressure, f, P.(channel) [nbscan x nfreq], nfft, dof,
    % Fs_epsi, N_epsi, scan_step). Pick a file, and:
    %   - Row 1 always shows L2 pressure (per-scan) for context.
    %   - Rows 2-3 each show up to 2 raw L1 channels (t1/t2/s1/s2/a1/a2/a3
    %     volt/g, restricted to whichever channels this file actually has
    %     spectra for) on their own left/right y-axes (yyaxis), pulled
    %     from the matching file in the sibling L1 folder. Y-limits are
    %     settable/lockable per axis - same two-axis setup as
    %     MODvis_timeseries (branch modvis_timeseries): real yyaxis,
    %     native tick labels blanked and redrawn as colored text() in
    %     reserved margins so every row stays the same width no matter
    %     which fields/units are plotted.
    %   - Click a point in any of the 3 rows to shade that scan's time
    %     window across all three and plot its raw spectrum (all 7
    %     channels, toggle on/off via checkboxes) in the bottom axes.

    properties
        Fig matlab.ui.Figure
        GL matlab.ui.container.GridLayout

        FolderBtn matlab.ui.control.Button
        FolderLbl matlab.ui.control.Label
        FileList matlab.ui.control.ListBox
        RefreshBtn matlab.ui.control.Button

        Folder string = ""
        Files string = strings(0,1)
        CurrentData struct = struct()      % loaded L2 file
        CurrentFile string = ""

        L1Dir string = ""
        CurrentL1Data struct = struct()    % matching L1 file (epsi.dnum, epsi.(channel), ...)

        NRows double = 3   % 1 = pressure (fixed, left axis only), 2-3 = selectable L1 channels
        HasAxis2 logical = [false; true; true]

        AxesTickFontSize double = 10

        TopAxes
        TopLine        % axis-1 (left) line handle per row
        TopLine2       % axis-2 (right) line handle per row (rows 2-3 only)
        ShadePatch     % shaded-scan patch handle per row

        FieldADrop     % axis 1 (left, required)
        FieldBDrop     % axis 2 (right, optional - rows 2-3 only)

        YMinField, YMaxField, YResetBtn      % axis 1 (left)
        YMinField2, YMaxField2, YResetBtn2   % axis 2 (right, rows 2-3 only)

        LastFieldA string = ["pressure", "s1_volt", "t1_volt"]
        LastFieldB string = ["", "s2_volt", "a2_g"]

        YTickTextHandles cell    % left-margin custom tick text handles, per row
        YTickTextHandles2 cell   % right-margin custom tick text handles, per row
        Axis1Color cell          % 1x3 RGB per row, left axis
        Axis2Color cell          % 1x3 RGB per row, right axis

        PlotStyleCheck   % uicheckbox: dots (default) vs lines
        UseLine logical = false

        SelectedScanIdx double = []

        SpecAxes
        SpecLines struct = struct()     % channel name -> line handle
        ChannelOn struct = struct()     % channel name -> logical, persists across files
        ChannelCheckPanel
        ChannelCheck struct = struct()  % channel name -> uicheckbox handle
        ChannelOrder cell = {'t1_volt_f','t2_volt_f','s1_volt_f','s2_volt_f','a1_g_f','a2_g_f','a3_g_f'}
        SpecTitle matlab.ui.control.Label

        GlobalDnum double = []   % L2 scan-center dnum (drives x-window + scan picking)
        ProfileTmin double = 0
        ProfileTmax double = 0
        HasUserZoomed logical = false

        % X-window controls (same pattern as MODvis_timeseries)
        XWinSlider
        XWinLenField
        XWinResetBtn
        UseXWindow logical = false
        XWindowLen double = 0
        XWinFraction double = 0

        % Spectra y-limit lock (so consecutive scans can be compared on
        % the same scale instead of each auto-scaling to its own data)
        SpecYMinField
        SpecYMaxField
        SpecYLockCheck
        SpecYResetBtn
        SpecYLock logical = false

        SignalColors struct
    end

    properties (Constant)
        NoneItem = '(none)'   % axis-2 sentinel meaning "don't plot a second field"
    end

    methods
        function app = MODvis_spectra(folder)
            if nargin >= 1 && ~isempty(folder)
                app.Folder = string(folder);
            else
                app.Folder = string(pwd);
            end

            app.SignalColors = app.defineSignalColors();
            for i = 1:numel(app.ChannelOrder)
                app.ChannelOn.(app.ChannelOrder{i}) = true;
            end
            app.YTickTextHandles = cell(app.NRows,1);
            app.YTickTextHandles2 = cell(app.NRows,1);
            app.Axis1Color = repmat({[0.15 0.15 0.15]}, app.NRows, 1);
            app.Axis2Color = repmat({[0.15 0.15 0.15]}, app.NRows, 1);

            app.buildUI();
            app.loadFolder(app.Folder);
        end

        function buildUI(app)
            app.Fig = uifigure('Name','L2 Spectra Explorer','Position',[100 100 1350 950]);

            app.GL = uigridlayout(app.Fig,[1 2]);
            app.GL.ColumnWidth = {240,'1x'};
            app.GL.RowHeight = {'1x'};
            app.GL.Padding = [10 10 10 10];
            app.GL.ColumnSpacing = 10;

            %% LEFT: folder + file list + x-window/style controls
            left = uigridlayout(app.GL,[6 1]);
            left.Layout.Row = 1;
            left.Layout.Column = 1;
            left.RowHeight = {44, 22, 34, '1x', 28, 36};
            left.ColumnWidth = {'1x'};
            left.RowSpacing = 6;

            topRow = uigridlayout(left,[2 2]);
            topRow.Layout.Row = 1; topRow.Layout.Column = 1;
            topRow.RowHeight = {'1x', 34};
            topRow.ColumnWidth = {'1x', 140};
            topRow.RowSpacing = 6;
            topRow.Padding = [0 0 0 0];

            app.FolderLbl = uilabel(topRow,'Text',"");
            app.FolderLbl.Layout.Row = 1; app.FolderLbl.Layout.Column = [1 2];
            app.FolderLbl.FontSize = 12;
            app.FolderLbl.WordWrap = 'on';
            app.FolderLbl.VerticalAlignment = 'top';

            app.FolderBtn = uibutton(topRow,'push','Text','Choose folder…', ...
                'ButtonPushedFcn', @(~,~)app.chooseFolder());
            app.FolderBtn.Layout.Row = 2; app.FolderBtn.Layout.Column = 2;
            app.FolderBtn.FontSize = 12;

            mini = uilabel(topRow,'Text','');
            mini.Layout.Row = 2; mini.Layout.Column = 1;

            lbl = uilabel(left,'Text','L2 files (*.mat):');
            lbl.Layout.Row = 2; lbl.Layout.Column = 1;

            app.RefreshBtn = uibutton(left,'push','Text','Refresh list', ...
                'ButtonPushedFcn', @(~,~)app.loadFolder(app.Folder));
            app.RefreshBtn.Layout.Row = 3; app.RefreshBtn.Layout.Column = 1;

            app.FileList = uilistbox(left, 'Items',{}, ...
                'ValueChangedFcn', @(~,~)app.onFileSelected());
            app.FileList.Layout.Row = 4; app.FileList.Layout.Column = 1;
            app.FileList.FontName = 'Sans';
            app.FileList.FontSize = 12;

            xwinRow = uigridlayout(left, [1 3]);
            xwinRow.Layout.Row = 5; xwinRow.Layout.Column = 1;
            xwinRow.RowHeight = {'1x'};
            xwinRow.ColumnWidth = {76, '1x', 64};
            xwinRow.ColumnSpacing = 4;
            xwinRow.Padding = [0 2 0 2];

            xwinLbl = uilabel(xwinRow, 'Text', 'X win (s):');
            xwinLbl.Layout.Row = 1; xwinLbl.Layout.Column = 1;
            xwinLbl.VerticalAlignment = 'center';
            xwinLbl.FontSize = 12;

            app.XWinLenField = uieditfield(xwinRow, 'numeric', ...
                'Placeholder', 'sec', 'Value', 0, 'Limits', [0 Inf], ...
                'ValueChangedFcn', @(~,~)app.onXWinLenChanged());
            app.XWinLenField.Layout.Row = 1; app.XWinLenField.Layout.Column = 2;
            app.XWinLenField.FontSize = 12;

            app.XWinResetBtn = uibutton(xwinRow, 'push', 'Text', 'Full view', ...
                'ButtonPushedFcn', @(~,~)app.onXWinReset());
            app.XWinResetBtn.Layout.Row = 1; app.XWinResetBtn.Layout.Column = 3;
            app.XWinResetBtn.FontSize = 11;

            sliderRow = uigridlayout(left, [1 2]);
            sliderRow.Layout.Row = 6; sliderRow.Layout.Column = 1;
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
                'Limits', [0 100], 'Value', 0, 'MajorTicks', [], 'MinorTicks', [], ...
                'Enable', 'off', ...
                'ValueChangedFcn',  @(~,~)app.onXWinSliderMoved(), ...
                'ValueChangingFcn', @(~,evt)app.onXWinSliderChanging(evt));
            app.XWinSlider.Layout.Row = 1; app.XWinSlider.Layout.Column = 2;

            %% RIGHT: 3 timeseries rows + spectra section
            right = uigridlayout(app.GL,[app.NRows+1 1]);
            right.Layout.Row = 1; right.Layout.Column = 2;
            rh = repmat({'1x'}, 1, app.NRows);
            rh{end+1} = '2.2x';
            right.RowHeight = rh;
            right.ColumnWidth = {'1x'};
            right.RowSpacing = 8;

            app.TopAxes = gobjects(app.NRows,1);
            app.TopLine = gobjects(app.NRows,1);
            app.TopLine2 = gobjects(app.NRows,1);
            app.ShadePatch = gobjects(app.NRows,1);
            app.FieldADrop = gobjects(app.NRows,1);
            app.FieldBDrop = gobjects(app.NRows,1);
            app.YMinField = gobjects(app.NRows,1);
            app.YMaxField = gobjects(app.NRows,1);
            app.YResetBtn = gobjects(app.NRows,1);
            app.YMinField2 = gobjects(app.NRows,1);
            app.YMaxField2 = gobjects(app.NRows,1);
            app.YResetBtn2 = gobjects(app.NRows,1);

            for i = 1:app.NRows
                % axes | reserved right-margin spacer (axis-2 tick text) | axis-1 ctrl | axis-2 ctrl
                row = uigridlayout(right,[1 4]);
                row.Layout.Row = i; row.Layout.Column = 1;
                row.RowHeight = {'1x'};
                row.ColumnWidth = {'1x', 55, 168, 168};
                row.ColumnSpacing = 6;
                row.Padding = [68 0 0 0];  % left margin reserved for axis-1 tick text

                app.TopAxes(i) = uiaxes(row);
                app.TopAxes(i).FontSize = app.AxesTickFontSize;
                app.TopAxes(i).Layout.Row = 1; app.TopAxes(i).Layout.Column = 1;
                grid(app.TopAxes(i),'on');
                app.TopAxes(i).PositionConstraint = 'innerposition';
                app.TopAxes(i).ButtonDownFcn = @(src,evt) app.onTimeseriesClicked(src,evt);

                ii = i;
                addlistener(app.TopAxes(i), 'YLim', 'PostSet', ...
                    @(~,~)app.onAxesYLimChanged(ii));

                app.buildFieldControls(row, 3, i, 1);
                if app.HasAxis2(i)
                    app.buildFieldControls(row, 4, i, 2);
                end
            end

            % Row 1 is always pressure - fixed, non-interactive dropdown
            app.FieldADrop(1).Items = {'pressure'};
            app.FieldADrop(1).Value = 'pressure';
            app.FieldADrop(1).Enable = 'off';

            linkaxes(app.TopAxes, 'x');

            z = zoom(app.Fig);
            z.ActionPostCallback = @(~,~)app.onUserZoomPan();
            p = pan(app.Fig);
            p.ActionPostCallback = @(~,~)app.onUserZoomPan();

            %% Spectra section: title on top, axes + checkbox column below,
            %% y-limit lock controls at the bottom
            specSection = uigridlayout(right,[3 1]);
            specSection.Layout.Row = app.NRows+1; specSection.Layout.Column = 1;
            specSection.RowHeight = {26, '1x', 30};
            specSection.ColumnWidth = {'1x'};
            specSection.RowSpacing = 4;
            specSection.Padding = [0 0 0 0];

            app.SpecTitle = uilabel(specSection, 'Text', 'Click a point above to show its spectrum');
            app.SpecTitle.Layout.Row = 1; app.SpecTitle.Layout.Column = 1;
            app.SpecTitle.FontSize = 13;

            mainRow = uigridlayout(specSection, [1 2]);
            mainRow.Layout.Row = 2; mainRow.Layout.Column = 1;
            mainRow.RowHeight = {'1x'};
            mainRow.ColumnWidth = {'1x', 90};
            mainRow.ColumnSpacing = 6;
            mainRow.Padding = [0 0 0 0];

            app.SpecAxes = uiaxes(mainRow);
            app.SpecAxes.Layout.Row = 1; app.SpecAxes.Layout.Column = 1;
            grid(app.SpecAxes,'on');
            xlabel(app.SpecAxes,'Frequency [Hz]');
            ylabel(app.SpecAxes,'Power spectral density');

            app.ChannelCheckPanel = uigridlayout(mainRow, [numel(app.ChannelOrder) 1]);
            app.ChannelCheckPanel.Layout.Row = 1; app.ChannelCheckPanel.Layout.Column = 2;
            app.ChannelCheckPanel.RowHeight = repmat({'fit'},1,numel(app.ChannelOrder));
            app.ChannelCheckPanel.ColumnWidth = {'1x'};
            app.ChannelCheckPanel.RowSpacing = 6;
            app.ChannelCheckPanel.Padding = [4 20 0 0];

            for i = 1:numel(app.ChannelOrder)
                ch = app.ChannelOrder{i};
                cb = uicheckbox(app.ChannelCheckPanel, 'Text', ch, 'Value', true, ...
                    'FontColor', app.getSignalColor(ch), ...
                    'ValueChangedFcn', @(src,~)app.onChannelCheckChanged(ch, src.Value));
                cb.Layout.Row = i; cb.Layout.Column = 1;
                cb.FontSize = 11;
                app.ChannelCheck.(ch) = cb;
            end

            ylimRow = uigridlayout(specSection, [1 6]);
            ylimRow.Layout.Row = 3; ylimRow.Layout.Column = 1;
            ylimRow.RowHeight = {'1x'};
            ylimRow.ColumnWidth = {70, 100, 100, 110, 70, '1x'};
            ylimRow.ColumnSpacing = 6;
            ylimRow.Padding = [0 0 0 0];

            ylimLbl = uilabel(ylimRow, 'Text', 'Y-limits:');
            ylimLbl.Layout.Row = 1; ylimLbl.Layout.Column = 1;
            ylimLbl.VerticalAlignment = 'center';

            app.SpecYMinField = uieditfield(ylimRow, 'numeric', ...
                'Placeholder', 'min', 'Limits', [0 Inf], ...
                'ValueChangedFcn', @(~,~)app.onSpecYLimChanged());
            app.SpecYMinField.Layout.Row = 1; app.SpecYMinField.Layout.Column = 2;

            app.SpecYMaxField = uieditfield(ylimRow, 'numeric', ...
                'Placeholder', 'max', 'Limits', [0 Inf], ...
                'ValueChangedFcn', @(~,~)app.onSpecYLimChanged());
            app.SpecYMaxField.Layout.Row = 1; app.SpecYMaxField.Layout.Column = 3;

            app.SpecYLockCheck = uicheckbox(ylimRow, 'Text', 'Lock across scans', ...
                'Value', false, ...
                'ValueChangedFcn', @(src,~)app.onSpecYLockChanged(src.Value));
            app.SpecYLockCheck.Layout.Row = 1; app.SpecYLockCheck.Layout.Column = 4;

            app.SpecYResetBtn = uibutton(ylimRow, 'push', 'Text', 'Reset', ...
                'ButtonPushedFcn', @(~,~)app.onSpecYReset());
            app.SpecYResetBtn.Layout.Row = 1; app.SpecYResetBtn.Layout.Column = 5;
        end

        function buildFieldControls(app, parent, colIdx, rowIdx, axisNum)
            % One "Field / Y-limits / Reset" control panel for either axis 1
            % (left, required) or axis 2 (right, optional - its Items
            % include NoneItem as the first, default entry).
            ctrl = uigridlayout(parent,[4 3]);
            ctrl.Layout.Row = 1;
            ctrl.Layout.Column = colIdx;
            ctrl.RowHeight = {16, 28, 26, 22};
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

            fieldDrop = uidropdown(ctrl,'Items',{}, ...
                'ValueChangedFcn', @(~,~)app.onFieldChanged(rowIdx));
            fieldDrop.Layout.Row = 2; fieldDrop.Layout.Column = [1 3];

            ylbl = uilabel(ctrl,'Text','Y-limits');
            ylbl.Layout.Row = 3; ylbl.Layout.Column = 1;
            ylbl.VerticalAlignment = 'center';

            yMinField = uieditfield(ctrl,'numeric', 'Placeholder','min', ...
                'ValueChangedFcn', @(~,~)app.onYLimitChanged(rowIdx, axisNum));
            yMinField.Layout.Row = 3; yMinField.Layout.Column = 2;

            yMaxField = uieditfield(ctrl,'numeric', 'Placeholder','max', ...
                'ValueChangedFcn', @(~,~)app.onYLimitChanged(rowIdx, axisNum));
            yMaxField.Layout.Row = 3; yMaxField.Layout.Column = 3;

            yResetBtn = uibutton(ctrl,'Text','Reset y-limits', ...
                'ButtonPushedFcn', @(~,~)app.onYLimitReset(rowIdx, axisNum));
            yResetBtn.Layout.Row = 4; yResetBtn.Layout.Column = [2 3];

            if axisNum == 1
                app.FieldADrop(rowIdx) = fieldDrop;
                app.YMinField(rowIdx)  = yMinField;
                app.YMaxField(rowIdx)  = yMaxField;
                app.YResetBtn(rowIdx)  = yResetBtn;
            else
                app.FieldBDrop(rowIdx) = fieldDrop;
                app.YMinField2(rowIdx) = yMinField;
                app.YMaxField2(rowIdx) = yMaxField;
                app.YResetBtn2(rowIdx) = yResetBtn;
            end
        end

        %% ---------------- Folder / file list ----------------

        function chooseFolder(app)
            p = uigetdir(char(app.Folder), 'Select L2 folder');
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

            % L1 files live in the sibling 'L1' folder next to this L2
            % folder (MODprocess_all_L1_to_L2.m's default L2_dir layout).
            candidate_L1 = fullfile(fileparts(char(folder)), 'L1');
            if isfolder(candidate_L1)
                app.L1Dir = string(candidate_L1);
            else
                app.L1Dir = "";
            end

            d = dir(fullfile(folder,"*.mat"));
            names = sort(string({d.name})');
            app.Files = names;

            if isempty(names)
                app.FileList.Items = {};
                app.CurrentData = struct();
                app.CurrentFile = "";
                app.Fig.Name = "L2 Spectra Explorer (no files)";
                app.clearAll();
                return;
            end

            app.FileList.Items = cellstr(names);
            app.FileList.Value = app.FileList.Items{1};
            app.onFileSelected();
        end

        function clearAll(app)
            for i = 1:app.NRows
                cla(app.TopAxes(i));
                if i > 1
                    app.FieldADrop(i).Items = {};
                    app.FieldBDrop(i).Items = {};
                end
            end
            cla(app.SpecAxes);
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
            app.CurrentData = S;
            app.SelectedScanIdx = [];
            app.Fig.Name = "L2 Spectra Explorer — " + app.CurrentFile;

            % Matching L1 file (same filename, sibling L1 folder) - source
            % of the raw per-channel timeseries for rows 2-3.
            app.CurrentL1Data = struct();
            if app.L1Dir ~= ""
                L1_file = fullfile(app.L1Dir, app.CurrentFile);
                if exist(L1_file, 'file')
                    try
                        app.CurrentL1Data = load(L1_file);
                    catch
                        app.CurrentL1Data = struct();
                    end
                end
            end

            if ~isfield(S,'dnum') || isempty(S.dnum)
                app.GlobalDnum = [];
                app.clearAll();
                app.SpecTitle.Text = 'No scans in this file (no descending data, or file too short)';
                return;
            end

            app.GlobalDnum = S.dnum(:);
            app.ProfileTmin = min(app.GlobalDnum);
            app.ProfileTmax = max(app.GlobalDnum);

            if app.ProfileTmax > app.ProfileTmin
                app.TopAxes(1).XLim = [app.ProfileTmin, app.ProfileTmax]; % propagates via linkaxes
            end
            app.HasUserZoomed = false;

            % Channels available for rows 2-3: whichever channels this file
            % has spectra for (L2's P struct) AND have raw data in the
            % matching L1 file's epsi struct.
            l2_channels = app.getChannelList();
            has_l1_epsi = isfield(app.CurrentL1Data,'epsi') && isstruct(app.CurrentL1Data.epsi) ...
                && isfield(app.CurrentL1Data.epsi,'dnum') && ~isempty(app.CurrentL1Data.epsi.dnum);
            if has_l1_epsi
                l1_fields = string(fieldnames(app.CurrentL1Data.epsi));
                channels = l2_channels(ismember(l2_channels, l1_fields));
            else
                channels = strings(0,1);
            end

            for i = 2:app.NRows
                app.FieldADrop(i).Items = cellstr(channels);
                app.FieldBDrop(i).Items = [{app.NoneItem}; cellstr(channels)];
                app.FieldADrop(i).Enable = has_l1_epsi;
                app.FieldBDrop(i).Enable = has_l1_epsi;

                app.LastFieldA(i) = app.restoreOrDefault(app.FieldADrop(i), app.LastFieldA(i));
                app.LastFieldB(i) = app.restoreOrDefault(app.FieldBDrop(i), app.LastFieldB(i));
            end

            for i = 1:app.NRows
                app.plotRow(i);
            end

            % Sync spectra checkbox visibility to what this file actually has
            for i = 1:numel(app.ChannelOrder)
                ch = app.ChannelOrder{i};
                app.ChannelCheck.(ch).Visible = any(strcmp(l2_channels, ch));
            end

            cla(app.SpecAxes);
            app.SpecTitle.Text = 'Click a point above to show its spectrum';

            if app.UseXWindow
                app.applyXWindow();
            end
        end

        function value = restoreOrDefault(app, dropdown, lastVal) %#ok<INUSL>
            if isempty(dropdown.Items)
                value = "";
                return
            end
            if strlength(lastVal) > 0 && any(strcmp(dropdown.Items, char(lastVal)))
                dropdown.Value = char(lastVal);
            else
                dropdown.Value = dropdown.Items{1};
            end
            value = string(dropdown.Value);
        end

        function channels = getChannelList(app)
            channels = strings(0,1);
            if ~isfield(app.CurrentData,'spectra') || ~isstruct(app.CurrentData.spectra)
                return
            end
            present = fieldnames(app.CurrentData.spectra);
            % 'f'/'k' are shared axes, not channels; '_Tg_k'/'_fc_index'
            % are per-channel chi diagnostics, not independently
            % plottable raw spectra - exclude all from the channel list.
            present = present(~ismember(present, {'f','k'}));
            present = present(~endsWith(present, {'_Tg_k','_fc_index'}));
            ordered = app.ChannelOrder(ismember(app.ChannelOrder, present));
            rest = setdiff(present, ordered, 'stable');
            channels = string([ordered(:); rest(:)]);
        end

        %% ---------------- Top timeseries rows (yyaxis left/right) ----------------

        function onFieldChanged(app, rowIdx)
            if isgraphics(app.FieldADrop(rowIdx))
                app.LastFieldA(rowIdx) = string(app.FieldADrop(rowIdx).Value);
            end
            if app.HasAxis2(rowIdx) && isgraphics(app.FieldBDrop(rowIdx))
                app.LastFieldB(rowIdx) = string(app.FieldBDrop(rowIdx).Value);
            end
            app.plotRow(rowIdx);
        end

        function onPlotStyleChanged(app)
            app.UseLine = app.PlotStyleCheck.Value;
            for i = 1:app.NRows
                app.plotRow(i);
            end
        end

        function plotRow(app, rowIdx)
            if isempty(fieldnames(app.CurrentData)) || isempty(app.GlobalDnum)
                return
            end

            ax = app.TopAxes(rowIdx);
            dual = numel(ax.YAxis) > 1;

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
            keyA = string(app.FieldADrop(rowIdx).Value);
            [ok, clr1] = app.plotOneSignal(ax, rowIdx, true, keyA, app.YMinField(rowIdx), app.YMaxField(rowIdx));
            if ~ok
                return;
            end

            % ----- Axis 2 (right, optional) -----
            axis2Active = app.HasAxis2(rowIdx) && ~isempty(app.FieldBDrop(rowIdx).Items) ...
                && ~strcmp(app.FieldBDrop(rowIdx).Value, app.NoneItem);

            if axis2Active
                yyaxis(ax, 'right');
                ax.YAxis(2).Visible = 'on';
                keyB = string(app.FieldBDrop(rowIdx).Value);
                app.plotOneSignal(ax, rowIdx, false, keyB, app.YMinField2(rowIdx), app.YMaxField2(rowIdx), clr1);
                yyaxis(ax, 'left');
            elseif dual
                % Right axis exists but is set to "(none)" - hide the ruler
                % rather than trying to fully undo yyaxis mode.
                yyaxis(ax, 'right');
                ax.YAxis(2).Visible = 'off';
                yyaxis(ax, 'left');
                app.updateYTickText2(rowIdx);
            end

            grid(ax,'on');
            try
                datetick(ax,'x','keeplimits'); %#ok<DATETICK>
            catch
            end

            if keepX
                ax.XLim = xlim0;
            end
            if app.UseXWindow && isfinite(app.ProfileTmin) && app.ProfileTmax > app.ProfileTmin
                app.applyXWindow();
            end

            app.redrawShade(rowIdx);
        end

        function [ok, clr] = plotOneSignal(app, ax, rowIdx, isPrimary, key, yMinField, yMaxField, primaryClr)
            % Plots one field on whichever y-axis side is currently active
            % (caller must have already called yyaxis as needed). Both axis
            % 1 (left) and axis 2 (right) get the blanked-tick-label
            % treatment so a huge-magnitude field on either side never
            % grows that side's native tick labels and shifts the axes box
            % out of alignment with the other rows.
            if nargin < 8
                primaryClr = [];
            end
            ok = false;
            clr = [];

            if key == "" || key == string(app.NoneItem)
                return
            end

            [dnum, y] = app.getSeries(key);
            if isempty(dnum) || isempty(y)
                return
            end
            dnum = dnum(:); y = y(:);
            n = min(numel(dnum), numel(y));
            dnum = dnum(1:n); y = y(1:n);

            keepY = strcmp(ax.YLimMode, 'manual');
            if keepY
                ylim0 = ax.YLim;
            end

            clr = app.getSignalColor(key);
            if ~isPrimary && ~isempty(primaryClr)
                clr = app.resolveAxis2Color(clr, primaryClr);
            end

            if app.UseLine
                h = plot(ax, dnum, y, '-', 'Color', clr, 'LineWidth', 1);
            else
                h = plot(ax, dnum, y, '.', 'Color', clr, 'MarkerSize', 6);
            end
            h.ButtonDownFcn = @(src,evt) app.onTimeseriesClicked(src,evt);
            if isPrimary
                app.TopLine(rowIdx) = h;
            else
                app.TopLine2(rowIdx) = h;
            end

            if isPrimary
                app.Axis1Color{rowIdx} = clr;
                ax.YAxis(1).Color = clr;
            elseif numel(ax.YAxis) >= 2
                app.Axis2Color{rowIdx} = clr;
                ax.YAxis(2).Color = clr;
            end

            if app.isReversed(key)
                ax.YDir = 'reverse';
            else
                ax.YDir = 'normal';
            end

            nt = numel(ax.YTick);
            if nt > 0
                ax.YTickLabel = repmat({''}, 1, nt);
            end

            if keepY
                ax.YLim = ylim0;
            else
                ax.YLimMode = 'auto';
                autoYLim = ax.YLim;
                yMinField.Value = autoYLim(1);
                yMaxField.Value = autoYLim(2);
            end

            if isPrimary
                app.updateYTickText(rowIdx);
            else
                app.updateYTickText2(rowIdx);
            end

            ok = true;
        end

        function [dnum, y] = getSeries(app, key)
            dnum = []; y = [];
            if key == "" || key == string(app.NoneItem)
                return
            end
            if key == "pressure"
                if isfield(app.CurrentData,'pressure') && isfield(app.CurrentData,'dnum')
                    dnum = app.CurrentData.dnum(:);
                    y = app.CurrentData.pressure(:);
                end
                return
            end
            % L1 raw epsi channel
            if isfield(app.CurrentL1Data,'epsi') && isfield(app.CurrentL1Data.epsi, key)
                dnum = app.CurrentL1Data.epsi.dnum(:);
                y = app.CurrentL1Data.epsi.(key)(:);
            end
        end

        function tf = isReversed(app, key) %#ok<INUSL>
            tf = ismember(lower(key), {'pressure','p','z'});
        end

        function clr = getSignalColor(app, key)
            if key == "pressure"
                clr = [0 0 0];
                return
            end
            clr = [0.3 0.3 0.3];
            if isfield(app.SignalColors, key)
                clr = app.SignalColors.(key);
            end
        end

        function clr = resolveAxis2Color(app, clr, primaryClr) %#ok<INUSL>
            % If the axis-2 field's natural color is too close to axis 1's,
            % swap it for the next distinct entry from a fixed fallback
            % palette (MATLAB's standard default axes color order).
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

        %% ---------------- Y-limits (per axis) ----------------

        function onYLimitChanged(app, rowIdx, axisNum)
            ax = app.TopAxes(rowIdx);
            dual = numel(ax.YAxis) > 1;

            if axisNum == 2
                if ~dual; return; end
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
            ax = app.TopAxes(rowIdx);
            dual = numel(ax.YAxis) > 1;

            if axisNum == 2
                if ~dual; return; end
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

        %% ---------------- Custom margin tick text (keeps row widths uniform) ----------------

        function onAxesYLimChanged(app, rowIdx)
            if isempty(app.YTickTextHandles) || rowIdx > numel(app.TopAxes)
                return;
            end
            ax = app.TopAxes(rowIdx);
            if ~isvalid(ax); return; end
            dual = numel(ax.YAxis) > 1;

            if dual
                yyaxis(ax, 'left');
            end
            n = numel(ax.YTick);
            if n > 0
                try; ax.YTickLabel = repmat({''}, 1, n); catch; end
            end
            app.updateYTickText(rowIdx);

            if dual
                yyaxis(ax, 'right');
                if strcmp(ax.YAxis(2).Visible, 'on')
                    n2 = numel(ax.YTick);
                    if n2 > 0
                        try; ax.YTickLabel = repmat({''}, 1, n2); catch; end
                    end
                end
                yyaxis(ax, 'left');
                app.updateYTickText2(rowIdx);
            end
        end

        function updateYTickText(app, rowIdx)
            if isempty(app.YTickTextHandles) || rowIdx > numel(app.YTickTextHandles)
                return;
            end
            ax = app.TopAxes(rowIdx);
            if ~isvalid(ax); return; end
            if numel(ax.YAxis) > 1
                yyaxis(ax, 'left');
            end

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
                if reversed
                    norm_y = (ylim(2) - val) / span;
                else
                    norm_y = (val - ylim(1)) / span;
                end
                if norm_y < -0.05 || norm_y > 1.05; continue; end

                label = app.smartFormatTick(val, ticks);

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

        function updateYTickText2(app, rowIdx)
            if isempty(app.YTickTextHandles2) || rowIdx > numel(app.YTickTextHandles2)
                return;
            end
            ax = app.TopAxes(rowIdx);
            if ~isvalid(ax) || numel(ax.YAxis) < 2
                return;
            end
            yyaxis(ax, 'right');

            old = app.YTickTextHandles2{rowIdx};
            if ~isempty(old)
                try; delete(old(isvalid(old))); catch; end
            end
            app.YTickTextHandles2{rowIdx} = gobjects(0);

            if strcmp(ax.YAxis(2).Visible, 'off')
                yyaxis(ax, 'left');
                return;
            end

            ticks = ax.YTick;
            if isempty(ticks)
                yyaxis(ax, 'left');
                return;
            end

            ylim = ax.YLim;
            span = ylim(2) - ylim(1);
            if ~isfinite(span) || span == 0
                yyaxis(ax, 'left');
                return;
            end

            reversed = strcmp(ax.YDir, 'reverse');
            handles  = gobjects(0);

            txtColor = [0.15 0.15 0.15];
            if rowIdx <= numel(app.Axis2Color) && ~isempty(app.Axis2Color{rowIdx})
                txtColor = app.Axis2Color{rowIdx};
            end

            for k = 1:numel(ticks)
                val = ticks(k);
                if reversed
                    norm_y = (ylim(2) - val) / span;
                else
                    norm_y = (val - ylim(1)) / span;
                end
                if norm_y < -0.05 || norm_y > 1.05; continue; end

                label = app.smartFormatTick(val, ticks);

                t = text(ax, 1, norm_y, [' ' label], ...
                    'Units',               'normalized', ...
                    'HorizontalAlignment', 'left', ...
                    'VerticalAlignment',   'middle', ...
                    'Clipping',            'off', ...
                    'FontSize',            app.AxesTickFontSize, ...
                    'Color',               txtColor);
                handles(end+1) = t; %#ok<AGROW>
            end

            app.YTickTextHandles2{rowIdx} = handles;
            yyaxis(ax, 'left');
        end

        function s = smartFormatTick(app, val, allVals) %#ok<INUSL>
            if ~isfinite(val); s = ''; return; end
            if val == 0;       s = '0'; return; end

            finVals = allVals(isfinite(allVals) & allVals ~= 0);
            if isempty(finVals)
                maxAbs = abs(val);
            else
                maxAbs = max(abs(finVals));
            end

            if maxAbs >= 10000 || maxAbs < 0.01
                s = sprintf('%.3e', val);
                return;
            end

            sorted = sort(allVals(isfinite(allVals)));
            if numel(sorted) >= 2
                steps = abs(diff(sorted));
                steps = steps(steps > 0);
                if isempty(steps)
                    step = maxAbs;
                else
                    step = min(steps);
                end
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

        %% ---------------- Click-to-select-scan ----------------

        function onTimeseriesClicked(app, src, evt) %#ok<INUSD>
            if isempty(app.GlobalDnum); return; end

            xClick = [];
            try
                xClick = evt.IntersectionPoint(1);
            catch
            end
            if isempty(xClick)
                ax = ancestor(src, 'matlab.ui.control.UIAxes');
                if isempty(ax); ax = src; end
                try
                    cp = ax.CurrentPoint;
                    xClick = cp(1,1);
                catch
                    return
                end
            end

            [~, idx] = min(abs(app.GlobalDnum - xClick));
            app.SelectedScanIdx = idx;

            for i = 1:app.NRows
                app.redrawShade(i);
            end
            app.plotSpectrum(idx);
        end

        function redrawShade(app, rowIdx)
            ax = app.TopAxes(rowIdx);
            if isgraphics(app.ShadePatch(rowIdx))
                delete(app.ShadePatch(rowIdx));
            end
            if isempty(app.SelectedScanIdx); return; end

            [t0, t1] = app.scanWindow(app.SelectedScanIdx);
            if isempty(t0); return; end

            if numel(ax.YAxis) > 1
                yyaxis(ax, 'left');
            end
            yl = ax.YLim;

            hold(ax,'on');
            app.ShadePatch(rowIdx) = patch(ax, [t0 t1 t1 t0], [yl(1) yl(1) yl(2) yl(2)], ...
                [1 0.85 0.2], 'FaceAlpha', 0.3, 'EdgeColor', 'none', ...
                'HitTest', 'off', 'PickableParts', 'none');
            % uistack can fail on a yyaxis-enabled uiaxes ("Children may
            % only be set to a permutation of itself") - purely a z-order
            % nicety, so don't let it break scan selection if it does.
            try; uistack(app.ShadePatch(rowIdx), 'bottom'); catch; end
            hold(ax,'off');
        end

        function [t0, t1] = scanWindow(app, idx)
            t0 = []; t1 = [];
            if ~isfield(app.CurrentData,'N_epsi') || ~isfield(app.CurrentData,'Fs_epsi')
                return
            end
            half_days = (app.CurrentData.N_epsi / 2) / app.CurrentData.Fs_epsi / 86400;
            center = app.GlobalDnum(idx);
            t0 = center - half_days;
            t1 = center + half_days;
        end

        function plotSpectrum(app, idx)
            if ~isfield(app.CurrentData,'spectra') || ~isfield(app.CurrentData.spectra,'f') || isempty(app.CurrentData.spectra.f)
                return
            end
            f = app.CurrentData.spectra.f(:)';
            keep = f > 0; % f=0 can't be shown on a log axis

            cla(app.SpecAxes);
            hold(app.SpecAxes,'on');
            app.SpecLines = struct();

            channels = app.getChannelList();
            for i = 1:numel(channels)
                ch = char(channels(i));
                Pxx = app.CurrentData.spectra.(ch)(idx,:);
                clr = app.getSignalColor(ch);
                h = loglog(app.SpecAxes, f(keep), Pxx(keep), '-', 'Color', clr, 'LineWidth', 1.2);
                if isfield(app.ChannelOn, ch)
                    h.Visible = app.ChannelOn.(ch);
                else
                    app.ChannelOn.(ch) = true;
                end
                app.SpecLines.(ch) = h;
            end
            hold(app.SpecAxes,'off');
            grid(app.SpecAxes,'on');
            set(app.SpecAxes,'XScale','log','YScale','log');
            xlabel(app.SpecAxes,'Frequency [Hz]');
            ylabel(app.SpecAxes,'Power spectral density');

            if app.SpecYLock && isfinite(app.SpecYMinField.Value) && isfinite(app.SpecYMaxField.Value) ...
                    && app.SpecYMaxField.Value > app.SpecYMinField.Value
                app.SpecAxes.YLim = [app.SpecYMinField.Value, app.SpecYMaxField.Value];
            else
                app.SpecAxes.YLimMode = 'auto';
                yl = app.SpecAxes.YLim;
                app.SpecYMinField.Value = yl(1);
                app.SpecYMaxField.Value = yl(2);
            end

            dnum_str = datestr(app.GlobalDnum(idx), 'yyyy-mm-dd HH:MM:SS'); %#ok<DATST>

            scanlen_s = NaN;
            if isfield(app.CurrentData,'N_epsi') && isfield(app.CurrentData,'Fs_epsi')
                scanlen_s = app.CurrentData.N_epsi / app.CurrentData.Fs_epsi;
            end
            nfft = app.getFieldOr(app.CurrentData, 'nfft', NaN);
            dof  = app.getFieldOr(app.CurrentData, 'dof', NaN);

            p_str = '';
            if isfield(app.CurrentData,'pressure') && numel(app.CurrentData.pressure) >= idx
                p_str = sprintf(', P=%.1f dbar', app.CurrentData.pressure(idx));
            end

            app.SpecTitle.Text = sprintf('Scan %d/%d @ %s | length %.2f s (nfft=%d, dof=%d)%s', ...
                idx, numel(app.GlobalDnum), dnum_str, scanlen_s, nfft, dof, p_str);
        end

        function v = getFieldOr(app, S, field, default) %#ok<INUSL>
            if isfield(S, field)
                v = S.(field);
            else
                v = default;
            end
        end

        function onChannelCheckChanged(app, ch, tf)
            app.ChannelOn.(ch) = tf;
            if isfield(app.SpecLines, ch) && isvalid(app.SpecLines.(ch))
                app.SpecLines.(ch).Visible = tf;
            end
        end

        %% ---------------- Spectra y-limit lock ----------------

        function onSpecYLimChanged(app)
            ymin = app.SpecYMinField.Value;
            ymax = app.SpecYMaxField.Value;
            if isfinite(ymin) && isfinite(ymax) && ymax > ymin && ymin > 0
                app.SpecAxes.YLim = [ymin ymax];
            end
        end

        function onSpecYLockChanged(app, tf)
            app.SpecYLock = tf;
            if tf
                app.onSpecYLimChanged();
            else
                app.SpecAxes.YLimMode = 'auto';
                yl = app.SpecAxes.YLim;
                app.SpecYMinField.Value = yl(1);
                app.SpecYMaxField.Value = yl(2);
            end
        end

        function onSpecYReset(app)
            app.SpecYLock = false;
            app.SpecYLockCheck.Value = false;
            app.SpecAxes.YLimMode = 'auto';
            yl = app.SpecAxes.YLim;
            app.SpecYMinField.Value = yl(1);
            app.SpecYMaxField.Value = yl(2);
        end

        %% ---------------- X-window controls (mirrors MODvis_timeseries) ----------------

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
                app.TopAxes(1).XLim = [app.ProfileTmin, app.ProfileTmax];
                for i = 1:app.NRows
                    try; datetick(app.TopAxes(i),'x','keeplimits'); catch; end
                end
            end
        end

        function applyXWindow(app)
            if ~app.UseXWindow; return; end
            if ~isfinite(app.ProfileTmin) || app.ProfileTmax <= app.ProfileTmin; return; end

            winDays    = app.XWindowLen / 86400;
            profileDur = app.ProfileTmax - app.ProfileTmin;

            if winDays >= profileDur
                app.TopAxes(1).XLim = [app.ProfileTmin, app.ProfileTmax];
                app.XWinSlider.Value = 0;
                for i = 1:app.NRows
                    try; datetick(app.TopAxes(i),'x','keeplimits'); catch; end
                end
                return;
            end

            maxFrac  = 1 - winDays / profileDur;
            frac     = min(max(app.XWinFraction, 0), maxFrac);
            winStart = app.ProfileTmin + frac * profileDur;

            app.TopAxes(1).XLim  = [winStart, winStart + winDays];
            app.XWinSlider.Value = frac * 100;

            for i = 1:app.NRows
                try; datetick(app.TopAxes(i),'x','keeplimits'); catch; end
            end
        end

        function onUserZoomPan(app)
            app.HasUserZoomed = true;
        end

        %% ---------------- Colors ----------------

        function C = defineSignalColors(app) %#ok<INUSD>
            C = struct();
            C.a1_g = [129 27 112]./255;
            C.a2_g = [235 64 61]./255;
            C.a3_g = [245 199 118]./255;
            C.s1_volt = [60 134 76]./255;
            C.s2_volt = [173 215 136]./255;
            C.t1_volt = [29 78 140]./255;
            C.t2_volt = [78 173 173]./255;
        end
    end
end
