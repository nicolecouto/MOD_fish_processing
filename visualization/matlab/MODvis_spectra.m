classdef MODvis_spectra < handle
    % MODvis_spectra        Part of MOD_fish_processing
    % Browse a folder of *.mat files carrying per-scan spectra, in either
    % of two formats:
    %   - This repo's own L2/profile output (MODprocess_single/all_L1_to_L2.m,
    %     MODprocess_single/all_L1_to_L2_profiles.m): dnum, pressure,
    %     spectra.f, spectra.(channel)_f [nbscan x nfreq], nfft, dof,
    %     Fs_epsi, N_epsi. Raw per-channel context (rows 2-3) is pulled
    %     from the matching file in a sibling L1 folder.
    %   - Legacy MOD_fish_lib/EPSILOMETER Profile*.mat (e.g.
    %     data_for_reorg/epsi_mako/astral/profiles/*.mat): Profile.dnum/.pr/
    %     .f, Profile.Pt_volt_f/.Ps_volt_f/.Pa_g_f (each a struct keyed by
    %     channel name), Profile.Meta_Data.PROCESS/.AFE. Normalized into the
    %     same internal shape as above on load (normalizeLegacyProfile) -
    %     raw per-channel context (rows 2-3) comes straight from the same
    %     file's own Profile.epsi, no sibling file needed.
    % Pick a file, and:
    %   - Row 1 always shows pressure (per-scan) for context.
    %   - Rows 2-3 each show up to 2 raw channels (t1/t2/s1/s2/a1/a2/a3
    %     volt/g, restricted to whichever channels this file actually has
    %     spectra for) on their own left/right y-axes (yyaxis). Y-limits are
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

        NRows double = 3   % 1 = pressure/CTD temperature, 2-3 = selectable L1 channels
        HasAxis2 logical = [true; true; true]

        AxesTickFontSize double = 10

        TopAxes
        TopLine        % axis-1 (left) line handle per row
        TopLine2       % axis-2 (right) line handle per row (rows 2-3 only)
        ShadePatch     % shaded-scan patch handle per row

        FieldADrop     % axis 1 (left, required)
        FieldBDrop     % axis 2 (right, optional - rows 2-3 only)

        YMinField, YMaxField, YResetBtn      % axis 1 (left)
        YMinField2, YMaxField2, YResetBtn2   % axis 2 (right, rows 2-3 only)
        YLockCheck   % one per row - when on, switching to a new file keeps
                     % this row's current y-limits (both axes) instead of
                     % auto-rescaling to the new file's data

        LastFieldA string = ["pressure", "s1_volt", "t1_volt"]
        LastFieldB string = ["temperature", "s2_volt", "a2_g"]

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

        % Physical-units frequency-domain spectra + FPO7 noise floor
        % (legacy Profile files only - see normalizeLegacyProfile). Share
        % the same ChannelCheckPanel/ChannelOn/ChannelCheck maps as
        % ChannelOrder above (keyed by these same 5 strings), just a
        % second group of rows appended below a divider.
        PhysChannelOrder cell = {'t1_Tg_f','t2_Tg_f','s1_vel_f','s2_vel_f','fpo7_noise_f'}

        % Cutoff frequency/wavenumber - Profile.tg_fc/.sh_fc/.tg_kc/.sh_kc
        % are each [nbscan x 2], one column per channel (t1/t2 for tg_*,
        % s1/s2 for sh_*), not uncorrected/coherence-corrected - split into
        % 4 per-channel fields each (t1_fc/t2_fc/s1_fc/s2_fc,
        % t1_kc/t2_kc/s1_kc/s2_kc - see normalizeLegacyProfile) so each
        % channel gets its own checkbox/color/vertical line. Freq-domain
        % ones are a static group like PhysChannelOrder (SpecAxes);
        % wavenumber-domain ones are appended to the dynamic _k rebuild
        % (WavAxes), since their row position has to follow however many
        % _k channels this file has.
        FreqCutoffOrder cell = {'t1_fc','t2_fc','s1_fc','s2_fc'}
        WavCutoffOrder cell = {'t1_kc','t2_kc','s1_kc','s2_kc'}

        WavAxes                          % wavenumber-domain panel, below SpecAxes
        WavLines struct = struct()       % _k channel name -> observed line handle
        WavTheoryLines struct = struct() % same keys -> Batchelor/Panchev theory line handle
        WavDivLbl        % "Wavenumber" divider label, rebuilt per file
        DynamicWavKeys cell = {}  % currently-built _k/cutoff checkbox field
                                  % names, so they can be torn down before the
                                  % next file's rebuild (see rebuildWavCheckboxes)
        StaticCheckRows double = 0  % row count of the fixed checkbox groups
                                    % (raw/physical/freq-cutoff) built once in
                                    % buildUI - rebuildWavCheckboxes appends
                                    % the dynamic wavenumber group below this

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

        % Same, for the wavenumber panel (WavAxes)
        WavYMinField
        WavYMaxField
        WavYLockCheck
        WavYResetBtn
        WavYLock logical = false

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
            for i = 1:numel(app.PhysChannelOrder)
                app.ChannelOn.(app.PhysChannelOrder{i}) = true;
            end
            for i = 1:numel(app.FreqCutoffOrder)
                app.ChannelOn.(app.FreqCutoffOrder{i}) = true;
            end
            for i = 1:numel(app.WavCutoffOrder)
                app.ChannelOn.(app.WavCutoffOrder{i}) = true;
            end
            app.YTickTextHandles = cell(app.NRows,1);
            app.YTickTextHandles2 = cell(app.NRows,1);
            app.Axis1Color = repmat({[0.15 0.15 0.15]}, app.NRows, 1);
            app.Axis2Color = repmat({[0.15 0.15 0.15]}, app.NRows, 1);

            app.buildUI();
            app.loadFolder(app.Folder);
        end

        function buildUI(app)
            app.Fig = uifigure('Name','Spectra Explorer','Position',[100 100 1350 1300]);

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

            lbl = uilabel(left,'Text','Spectra files (*.mat):');
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
            rh{end+1} = '3.6x';  % specSection now hosts 2 stacked axes (freq + wavenumber)
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
            app.YLockCheck = gobjects(app.NRows,1);

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

            % Row 1's Items (pressure / CTD temperature / "(none)") are
            % populated per file in onFileSelected, same as rows 2-3.

            linkaxes(app.TopAxes, 'x');

            z = zoom(app.Fig);
            z.ActionPostCallback = @(~,~)app.onUserZoomPan();
            p = pan(app.Fig);
            p.ActionPostCallback = @(~,~)app.onUserZoomPan();

            %% Spectra section: title on top, axes + checkbox column below,
            %% y-limit lock controls for each axis at the bottom
            specSection = uigridlayout(right,[4 1]);
            specSection.Layout.Row = app.NRows+1; specSection.Layout.Column = 1;
            specSection.RowHeight = {26, '1x', 30, 30};
            specSection.ColumnWidth = {'1x'};
            specSection.RowSpacing = 4;
            specSection.Padding = [0 0 0 0];

            app.SpecTitle = uilabel(specSection, 'Text', 'Click a point above to show its spectrum');
            app.SpecTitle.Layout.Row = 1; app.SpecTitle.Layout.Column = 1;
            app.SpecTitle.FontSize = 13;

            % Freq-domain spectrum (row 1) + wavenumber-domain spectrum
            % (row 2, new) stacked in column 1, squished narrower than
            % before to leave room for a checkbox column (column 2) that
            % spans both rows - one checkbox list controls both panels.
            combinedRow = uigridlayout(specSection, [2 2]);
            combinedRow.Layout.Row = 2; combinedRow.Layout.Column = 1;
            combinedRow.RowHeight = {'1x','1x'};
            combinedRow.ColumnWidth = {'1x', 140};
            combinedRow.ColumnSpacing = 6;
            combinedRow.RowSpacing = 6;
            combinedRow.Padding = [0 0 0 0];

            app.SpecAxes = uiaxes(combinedRow);
            app.SpecAxes.Layout.Row = 1; app.SpecAxes.Layout.Column = 1;
            grid(app.SpecAxes,'on');
            xlabel(app.SpecAxes,'Frequency [Hz]');
            ylabel(app.SpecAxes,'Power spectral density');

            app.WavAxes = uiaxes(combinedRow);
            app.WavAxes.Layout.Row = 2; app.WavAxes.Layout.Column = 1;
            grid(app.WavAxes,'on');
            xlabel(app.WavAxes,'Wavenumber [cpm]');
            ylabel(app.WavAxes,'Power spectral density');

            % Static checkbox groups (raw / physical units / freq
            % cutoffs) - built once here, visibility toggled per file.
            % The dynamic wavenumber group (any _k spectra this file has,
            % plus the wavenumber cutoffs) is appended below these by
            % rebuildWavCheckboxes every time a file loads, since its row
            % count varies file to file.
            nRawCb = numel(app.ChannelOrder);
            nPhysCb = numel(app.PhysChannelOrder);
            nFreqCutoffCb = numel(app.FreqCutoffOrder);
            app.StaticCheckRows = nRawCb + 1 + nPhysCb + 1 + nFreqCutoffCb;

            app.ChannelCheckPanel = uigridlayout(combinedRow, [app.StaticCheckRows 1]);
            app.ChannelCheckPanel.Layout.Row = [1 2]; app.ChannelCheckPanel.Layout.Column = 2;
            app.ChannelCheckPanel.RowHeight = repmat({'fit'},1,app.StaticCheckRows);
            app.ChannelCheckPanel.ColumnWidth = {'1x'};
            app.ChannelCheckPanel.RowSpacing = 6;
            app.ChannelCheckPanel.Padding = [4 20 0 0];

            for i = 1:nRawCb
                ch = app.ChannelOrder{i};
                app.addChannelCheckbox(ch, ch, i);
            end

            divRow = nRawCb + 1;
            divLbl = uilabel(app.ChannelCheckPanel, 'Text', 'Physical units', 'FontWeight', 'bold');
            divLbl.Layout.Row = divRow; divLbl.Layout.Column = 1;
            divLbl.FontSize = 10;

            for i = 1:nPhysCb
                ch = app.PhysChannelOrder{i};
                lbl = ch;
                if strcmp(ch, 'fpo7_noise_f')
                    lbl = 'FPO7 noise floor';
                end
                app.addChannelCheckbox(ch, lbl, divRow + i);
            end

            divRow2 = divRow + nPhysCb + 1;
            divLbl2 = uilabel(app.ChannelCheckPanel, 'Text', 'Cutoffs (vertical lines)', 'FontWeight', 'bold');
            divLbl2.Layout.Row = divRow2; divLbl2.Layout.Column = 1;
            divLbl2.FontSize = 10;

            for i = 1:nFreqCutoffCb
                ch = app.FreqCutoffOrder{i};
                app.addChannelCheckbox(ch, ch, divRow2 + i);
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

            wavYlimRow = uigridlayout(specSection, [1 6]);
            wavYlimRow.Layout.Row = 4; wavYlimRow.Layout.Column = 1;
            wavYlimRow.RowHeight = {'1x'};
            wavYlimRow.ColumnWidth = {70, 100, 100, 110, 70, '1x'};
            wavYlimRow.ColumnSpacing = 6;
            wavYlimRow.Padding = [0 0 0 0];

            wavYlimLbl = uilabel(wavYlimRow, 'Text', 'Y-limits:');
            wavYlimLbl.Layout.Row = 1; wavYlimLbl.Layout.Column = 1;
            wavYlimLbl.VerticalAlignment = 'center';

            app.WavYMinField = uieditfield(wavYlimRow, 'numeric', ...
                'Placeholder', 'min', 'Limits', [0 Inf], ...
                'ValueChangedFcn', @(~,~)app.onWavYLimChanged());
            app.WavYMinField.Layout.Row = 1; app.WavYMinField.Layout.Column = 2;

            app.WavYMaxField = uieditfield(wavYlimRow, 'numeric', ...
                'Placeholder', 'max', 'Limits', [0 Inf], ...
                'ValueChangedFcn', @(~,~)app.onWavYLimChanged());
            app.WavYMaxField.Layout.Row = 1; app.WavYMaxField.Layout.Column = 3;

            app.WavYLockCheck = uicheckbox(wavYlimRow, 'Text', 'Lock across scans', ...
                'Value', false, ...
                'ValueChangedFcn', @(src,~)app.onWavYLockChanged(src.Value));
            app.WavYLockCheck.Layout.Row = 1; app.WavYLockCheck.Layout.Column = 4;

            app.WavYResetBtn = uibutton(wavYlimRow, 'push', 'Text', 'Reset', ...
                'ButtonPushedFcn', @(~,~)app.onWavYReset());
            app.WavYResetBtn.Layout.Row = 1; app.WavYResetBtn.Layout.Column = 5;
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
            hdr.Layout.Row = 1; hdr.Layout.Column = [1 2];
            hdr.FontSize = 11;

            if axisNum == 1
                lockCb = uicheckbox(ctrl, 'Text', 'Lock', 'Value', false);
                lockCb.Layout.Row = 1; lockCb.Layout.Column = 3;
                lockCb.FontSize = 10;
                app.YLockCheck(rowIdx) = lockCb;
            end

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
                app.Fig.Name = "Spectra Explorer (no files)";
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
            cla(app.WavAxes);
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
            app.SelectedScanIdx = [];
            app.Fig.Name = "Spectra Explorer — " + app.CurrentFile;
            app.CurrentL1Data = struct();

            if isfield(S, 'Profile')
                % Legacy MOD_fish_lib/EPSILOMETER Profile struct (e.g.
                % data_for_reorg/epsi_mako/astral/profiles/*.mat) -
                % normalize into the same shape used below, so nothing
                % past this point needs to know which format was loaded.
                % Profile.epsi already carries the raw per-channel
                % timeseries at full resolution, self-contained - no
                % sibling L1 file needed for rows 2-3.
                app.CurrentData = app.normalizeLegacyProfile(S.Profile);
                if isfield(S.Profile, 'epsi') && isstruct(S.Profile.epsi)
                    app.CurrentL1Data = struct('epsi', S.Profile.epsi);
                end
            else
                app.CurrentData = S;
                % Matching L1 file (same filename, sibling L1 folder) -
                % source of the raw per-channel timeseries for rows 2-3.
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
            end

            if ~isfield(app.CurrentData,'dnum') || isempty(app.CurrentData.dnum)
                app.GlobalDnum = [];
                app.clearAll();
                app.SpecTitle.Text = 'No scans in this file (no descending data, or file too short)';
                return;
            end

            app.GlobalDnum = app.CurrentData.dnum(:);
            app.ProfileTmin = min(app.GlobalDnum);
            app.ProfileTmax = max(app.GlobalDnum);

            if app.ProfileTmax > app.ProfileTmin
                app.TopAxes(1).XLim = [app.ProfileTmin, app.ProfileTmax]; % propagates via linkaxes
            end
            app.HasUserZoomed = false;

            % Row 1: pressure (left) / CTD temperature (right), both
            % selectable including "(none)" - always available directly
            % from CurrentData, no L1/sibling-file lookup needed.
            app.FieldADrop(1).Items = [{app.NoneItem}; {'pressure'}];
            app.FieldADrop(1).Enable = 'on';
            app.LastFieldA(1) = app.restoreOrDefault(app.FieldADrop(1), app.LastFieldA(1));

            hasTemp = isfield(app.CurrentData, 'temperature') && ~isempty(app.CurrentData.temperature);
            if hasTemp
                app.FieldBDrop(1).Items = [{app.NoneItem}; {'temperature'}];
            else
                app.FieldBDrop(1).Items = {app.NoneItem};
            end
            app.FieldBDrop(1).Enable = 'on';
            app.LastFieldB(1) = app.restoreOrDefault(app.FieldBDrop(1), app.LastFieldB(1));

            % Channels available for rows 2-3: whichever channels this file
            % has spectra for (L2's P struct) AND have raw data in the
            % matching L1 file's epsi struct.
            l2_channels = app.getChannelList();
            % l2_channels are spectra field names (t1_volt_f, a1_g_f, ...);
            % raw epsi fields drop the trailing '_f' (t1_volt, a1_g, ...) -
            % strip it before intersecting, or nothing ever matches.
            raw_channels = regexprep(l2_channels, '_f$', '');
            has_l1_epsi = isfield(app.CurrentL1Data,'epsi') && isstruct(app.CurrentL1Data.epsi) ...
                && isfield(app.CurrentL1Data.epsi,'dnum') && ~isempty(app.CurrentL1Data.epsi.dnum);
            if has_l1_epsi
                l1_fields = string(fieldnames(app.CurrentL1Data.epsi));
                channels = raw_channels(ismember(raw_channels, l1_fields));
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

            % Physical-units checkboxes - only legacy Profile files carry
            % this data (normalizeLegacyProfile); new-format L2/profile
            % files have no physUnits/wavenumber fields, so these stay
            % hidden for them.
            pu = struct('cal', struct(), 'vel_f', struct(), 'noise_coefs', []);
            if isfield(app.CurrentData, 'physUnits')
                pu = app.CurrentData.physUnits;
            end
            app.ChannelCheck.t1_Tg_f.Visible = isfield(pu.cal, 't1') && any(strcmp(l2_channels, 't1_volt_f'));
            app.ChannelCheck.t2_Tg_f.Visible = isfield(pu.cal, 't2') && any(strcmp(l2_channels, 't2_volt_f'));
            app.ChannelCheck.s1_vel_f.Visible = isfield(pu.vel_f, 's1');
            app.ChannelCheck.s2_vel_f.Visible = isfield(pu.vel_f, 's2');
            app.ChannelCheck.fpo7_noise_f.Visible = ~isempty(pu.noise_coefs);

            % Frequency-domain cutoff checkboxes (vertical lines on SpecAxes).
            for i = 1:numel(app.FreqCutoffOrder)
                ch = app.FreqCutoffOrder{i};
                app.ChannelCheck.(ch).Visible = isfield(app.CurrentData,ch) && ~isempty(app.CurrentData.(ch));
            end

            % Dynamic wavenumber group (any spectra.*_k channel this file
            % has, plus tg_kc/sh_kc if present) - rebuilt every file since
            % its row count varies (see rebuildWavCheckboxes).
            app.rebuildWavCheckboxes();

            cla(app.SpecAxes);
            cla(app.WavAxes);
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

        function tf = getChannelOnOr(app, ch, default)
            tf = default;
            if isfield(app.ChannelOn, ch)
                tf = app.ChannelOn.(ch);
            end
        end

        function cb = addChannelCheckbox(app, ch, lbl, row, clr)
            % Shared checkbox-creation helper for every group (raw,
            % physical units, cutoffs, dynamic wavenumber) - keeps the
            % checkbox's initial Value in sync with any persisted
            % ChannelOn preference (relevant for the dynamic wavenumber
            % group, whose checkboxes are torn down and rebuilt every file
            % load - see rebuildWavCheckboxes).
            if nargin < 5
                clr = app.getSignalColor(ch);
            end
            if ~isfield(app.ChannelOn, ch)
                app.ChannelOn.(ch) = true;
            end
            cb = uicheckbox(app.ChannelCheckPanel, 'Text', lbl, ...
                'Value', app.ChannelOn.(ch), ...
                'FontColor', clr, ...
                'ValueChangedFcn', @(src,~)app.onChannelCheckChanged(ch, src.Value));
            cb.Layout.Row = row; cb.Layout.Column = 1;
            cb.FontSize = 11;
            app.ChannelCheck.(ch) = cb;
        end

        function rebuildWavCheckboxes(app)
            % Rebuilds the dynamic wavenumber checkbox group - any
            % spectra.*_k channel this file has (getWavChannelList), plus
            % the wavenumber cutoffs (WavCutoffOrder) when this file
            % carries them - appended below the static groups built once
            % in buildUI. Unlike those static groups, this one's row count
            % varies file to file (legacy Profile files only; new-format
            % files have none), so it's torn down and rebuilt on every
            % onFileSelected rather than built once.
            for i = 1:numel(app.DynamicWavKeys)
                ch = app.DynamicWavKeys{i};
                if isfield(app.ChannelCheck, ch)
                    if isgraphics(app.ChannelCheck.(ch))
                        delete(app.ChannelCheck.(ch));
                    end
                    app.ChannelCheck = rmfield(app.ChannelCheck, ch);
                end
            end
            app.DynamicWavKeys = {};
            if isgraphics(app.WavDivLbl)
                delete(app.WavDivLbl);
            end

            wavChannels = app.getWavChannelList();
            availableWavCutoffs = {};
            for i = 1:numel(app.WavCutoffOrder)
                ch = app.WavCutoffOrder{i};
                if isfield(app.CurrentData, ch) && ~isempty(app.CurrentData.(ch))
                    availableWavCutoffs{end+1} = ch; %#ok<AGROW>
                end
            end

            nWavCb = numel(wavChannels) + numel(availableWavCutoffs);
            if nWavCb == 0
                app.ChannelCheckPanel.RowHeight = repmat({'fit'}, 1, app.StaticCheckRows);
                return
            end

            totalRows = app.StaticCheckRows + 1 + nWavCb; % +1 for the "Wavenumber" divider
            app.ChannelCheckPanel.RowHeight = repmat({'fit'}, 1, totalRows);

            divRow = app.StaticCheckRows + 1;
            app.WavDivLbl = uilabel(app.ChannelCheckPanel, 'Text', 'Wavenumber (_k)', 'FontWeight', 'bold');
            app.WavDivLbl.Layout.Row = divRow; app.WavDivLbl.Layout.Column = 1;
            app.WavDivLbl.FontSize = 10;

            row = divRow;
            for i = 1:numel(wavChannels)
                row = row + 1;
                ch = char(wavChannels(i));
                app.addChannelCheckbox(ch, ch, row);
                app.DynamicWavKeys{end+1} = ch;
            end
            for i = 1:numel(availableWavCutoffs)
                row = row + 1;
                ch = availableWavCutoffs{i};
                app.addChannelCheckbox(ch, ch, row);
                app.DynamicWavKeys{end+1} = ch;
            end
        end

        function channels = getChannelList(app)
            channels = strings(0,1);
            if ~isfield(app.CurrentData,'spectra') || ~isstruct(app.CurrentData.spectra)
                return
            end
            present = fieldnames(app.CurrentData.spectra);
            % 'f'/'k' are shared axes, not channels; any *_k field is
            % wavenumber-domain (t1_Tg_k, s1_shear_k, ...) and belongs to
            % the wavenumber panel instead - see getWavChannelList.
            present = present(~ismember(present, {'f','k'}));
            present = present(~endsWith(present, '_k'));
            ordered = app.ChannelOrder(ismember(app.ChannelOrder, present));
            rest = setdiff(present, ordered, 'stable');
            channels = string([ordered(:); rest(:)]);
        end

        function channels = getWavChannelList(app)
            % Any spectra field ending in '_k' (other than the shared 'k'
            % axis itself) is a wavenumber-domain channel and gets its own
            % checkbox, built dynamically per file by rebuildWavCheckboxes
            % - t1_Tg_k/t2_Tg_k/s1_shear_k/s2_shear_k today, but this
            % generalizes to whatever *_k field a file actually carries.
            channels = strings(0,1);
            if ~isfield(app.CurrentData,'spectra') || ~isstruct(app.CurrentData.spectra)
                return
            end
            present = fieldnames(app.CurrentData.spectra);
            present = present(endsWith(present, '_k') & ~strcmp(present, 'k'));
            channels = string(present(:));
        end

        function S2 = normalizeLegacyProfile(app, Profile)
            % Normalizes a legacy MOD_fish_lib/EPSILOMETER Profile struct
            % (Profile.pr/.f/.Pt_volt_f.(ch)/.Ps_volt_f.(ch)/.Pa_g_f.(ch),
            % Profile.Meta_Data.PROCESS/.AFE) into this class's own
            % CurrentData shape (dnum/pressure/spectra.f/spectra.(ch)_f/
            % N_epsi/Fs_epsi/nfft/dof), so every other method (getChannelList,
            % plotRow, plotSpectrum, scanWindow, ...) can stay format-agnostic.
            S2 = struct();
            S2.dnum = Profile.dnum(:);
            S2.pressure = Profile.pr(:);
            % Per-scan CTD temperature (Profile.t - already at the same
            % per-scan resolution as dnum/pr, unlike Profile.ctd.T which
            % is the raw full-rate CTD timeseries on its own dnum/time_s -
            % row 1's right axis needs the per-scan one to share row 1's
            % x-axis with pressure directly, no resampling.
            S2.temperature = app.getFieldOr(Profile, 't', []);

            S2.spectra = struct('f', Profile.f(:)');
            groups = {'Pt_volt_f', 'Ps_volt_f', 'Pa_g_f'};
            suffixes = {'_volt_f', '_volt_f', '_g_f'};
            for iG = 1:numel(groups)
                if ~isfield(Profile, groups{iG}) || ~isstruct(Profile.(groups{iG}))
                    continue
                end
                chans = fieldnames(Profile.(groups{iG}));
                for iC = 1:numel(chans)
                    ch = chans{iC};
                    S2.spectra.([ch suffixes{iG}]) = Profile.(groups{iG}).(ch);
                end
            end

            Meta_Data = struct();
            if isfield(Profile, 'Meta_Data') && isstruct(Profile.Meta_Data)
                Meta_Data = Profile.Meta_Data;
            end
            S2.nfft = app.getFieldOr(Profile, 'nfft', NaN);
            dof = NaN;
            Fs_epsi = NaN;
            if isfield(Meta_Data, 'PROCESS') && isstruct(Meta_Data.PROCESS)
                dof = app.getFieldOr(Meta_Data.PROCESS, 'dof', NaN);
                Fs_epsi = app.getFieldOr(Meta_Data.PROCESS, 'Fs_epsi', NaN);
            end
            if isnan(Fs_epsi) && isfield(Meta_Data, 'AFE') && isstruct(Meta_Data.AFE)
                % Real legacy files never carry Meta_Data.PROCESS.Fs_epsi -
                % Meta_Data.AFE.FS is the confirmed fallback (same one
                % SpectraExplorerApp.m already uses).
                Fs_epsi = app.getFieldOr(Meta_Data.AFE, 'FS', NaN);
            end
            S2.dof = dof;
            S2.Fs_epsi = Fs_epsi;
            S2.N_epsi = (dof - 1) * S2.nfft;

            % --- Physical-units frequency-domain spectra + FPO7 noise
            % floor (t1_Tg_f/t2_Tg_f/s1_vel_f/s2_vel_f/fpo7_noise_f
            % checkboxes - see plotSpectrum/getPhysSpectrum). Only ever
            % populated for legacy files - new-format L2/profile files
            % don't reach normalizeLegacyProfile at all, so these fields
            % are simply absent there and the checkboxes stay hidden.
            S2.physUnits = struct('cal', struct(), 'vel_f', struct(), 'noise_coefs', []);
            if isfield(Meta_Data, 'AFE') && isstruct(Meta_Data.AFE)
                tChans = {'t1', 't2'};
                for iT = 1:numel(tChans)
                    ch = tChans{iT};
                    if isfield(Meta_Data.AFE, ch) && isfield(Meta_Data.AFE.(ch), 'cal')
                        S2.physUnits.cal.(ch) = Meta_Data.AFE.(ch).cal;
                    end
                end
            end
            if isfield(Profile, 'Ps_velocity_f') && isstruct(Profile.Ps_velocity_f)
                velChans = fieldnames(Profile.Ps_velocity_f);
                for iV = 1:numel(velChans)
                    ch = velChans{iV};
                    S2.physUnits.vel_f.(ch) = Profile.Ps_velocity_f.(ch);
                end
            end
            if isfield(Meta_Data, 'PROCESS') && isstruct(Meta_Data.PROCESS) && isfield(Meta_Data.PROCESS, 'FPO7noise')
                S2.physUnits.noise_coefs = Meta_Data.PROCESS.FPO7noise;
            end

            % --- Wavenumber-domain spectra, folded into spectra itself
            % (like the _f channels) so getWavChannelList can discover any
            % of them generically by their trailing '_k' - t1_Tg_k,
            % t2_Tg_k, s1_shear_k, s2_shear_k today, but any future
            % *_k field Profile carries picks up a checkbox automatically,
            % no code change needed here. spectra.k is the per-scan
            % wavenumber axis (k = f / fall_speed, unlike the shared
            % frequency axis f) - a full [nbscan x nfreq] matrix like the
            % spectra themselves, not a single vector.
            S2.spectra.k = app.getFieldOr(Profile, 'k', []);
            if isfield(Profile, 'Pt_Tg_k') && isstruct(Profile.Pt_Tg_k)
                tgChans = fieldnames(Profile.Pt_Tg_k);
                for iG = 1:numel(tgChans)
                    ch = tgChans{iG};
                    S2.spectra.([ch '_Tg_k']) = Profile.Pt_Tg_k.(ch);
                end
            end
            if isfield(Profile, 'Ps_shear_k') && isstruct(Profile.Ps_shear_k)
                shChans = fieldnames(Profile.Ps_shear_k);
                for iG = 1:numel(shChans)
                    ch = shChans{iG};
                    S2.spectra.([ch '_shear_k']) = Profile.Ps_shear_k.(ch);
                end
            end

            % --- Scalar-per-scan inputs needed to overlay theoretical
            % Batchelor (temperature channels) / Panchev (shear channels)
            % curves on the wavenumber panel (see plotWavenumberSpectrum).
            % Not spectra themselves, so kept separate from S2.spectra.
            % Profile.chi columns follow Meta_Data.PROCESS.channels' order
            % (t1, t2, s1, s2, a1, a2, a3, ...) - confirmed against real
            % data, chi is [nbscan x 2] for the 2 temperature channels, so
            % column 1 = t1, column 2 = t2.
            S2.chi = struct();
            chi = app.getFieldOr(Profile, 'chi', []);
            if ~isempty(chi) && size(chi,2) >= 2
                S2.chi = struct('t1', chi(:,1), 't2', chi(:,2));
            end
            S2.epsilon_final = app.getFieldOr(Profile, 'epsilon_final', []);
            S2.kvis = app.getFieldOr(Profile, 'kvis', []);
            S2.ktemp = app.getFieldOr(Profile, 'ktemp', []);

            % --- Cutoff frequency/wavenumber, plotted as vertical lines
            % (FreqCutoffOrder on SpecAxes, WavCutoffOrder on WavAxes).
            % Profile.tg_fc/.sh_fc/.tg_kc/.sh_kc are each [nbscan x 2],
            % one column per channel (col 1/2 = t1/t2 for tg_*, s1/s2 for
            % sh_*) - split into 4 per-channel vectors so each channel
            % gets its own checkbox/color/line, same as every other
            % per-channel quantity in this file.
            cutoffPairs = {'tg_fc','t1_fc','t2_fc'; 'sh_fc','s1_fc','s2_fc'; ...
                'tg_kc','t1_kc','t2_kc'; 'sh_kc','s1_kc','s2_kc'};
            for iP = 1:size(cutoffPairs,1)
                src = cutoffPairs{iP,1};
                vals = app.getFieldOr(Profile, src, []);
                if ~isempty(vals) && size(vals,2) >= 2
                    S2.(cutoffPairs{iP,2}) = vals(:,1);
                    S2.(cutoffPairs{iP,3}) = vals(:,2);
                else
                    S2.(cutoffPairs{iP,2}) = [];
                    S2.(cutoffPairs{iP,3}) = [];
                end
            end
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

            % cla() on a yyaxis-enabled axes only clears the currently
            % active side's children, not both - explicitly delete both
            % old line handles first so a stale axis-2 line can't survive
            % switching that dropdown to "(none)" (or a stale axis-1 line
            % survive any redraw).
            if isgraphics(app.TopLine(rowIdx)); delete(app.TopLine(rowIdx)); end
            if isgraphics(app.TopLine2(rowIdx)); delete(app.TopLine2(rowIdx)); end
            cla(ax);

            % ----- Axis 1 (left) -----
            % Not a "required" axis any more (row 1's left dropdown can be
            % "(none)" too) - don't bail out on ok==false, axis 2 might
            % still have data to show.
            if dual
                yyaxis(ax, 'left');
            end
            keyA = string(app.FieldADrop(rowIdx).Value);
            [~, clr1] = app.plotOneSignal(ax, rowIdx, true, keyA, app.YMinField(rowIdx), app.YMaxField(rowIdx));

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

            if isempty(key) || key == "" || key == string(app.NoneItem)
                return
            end

            [dnum, y] = app.getSeries(key);
            if isempty(dnum) || isempty(y)
                return
            end
            dnum = dnum(:); y = y(:);
            n = min(numel(dnum), numel(y));
            dnum = dnum(1:n); y = y(1:n);

            locked = rowIdx <= numel(app.YLockCheck) && isgraphics(app.YLockCheck(rowIdx)) ...
                && app.YLockCheck(rowIdx).Value;
            keepY = locked || strcmp(ax.YLimMode, 'manual');
            if keepY
                if locked && isfinite(yMinField.Value) && isfinite(yMaxField.Value) ...
                        && yMaxField.Value > yMinField.Value
                    ylim0 = [yMinField.Value, yMaxField.Value];
                else
                    ylim0 = ax.YLim;
                end
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
            if isempty(key) || key == "" || key == string(app.NoneItem)
                return
            end
            if key == "pressure"
                if isfield(app.CurrentData,'pressure') && isfield(app.CurrentData,'dnum')
                    dnum = app.CurrentData.dnum(:);
                    y = app.CurrentData.pressure(:);
                end
                return
            end
            if key == "temperature"
                if isfield(app.CurrentData,'temperature') && isfield(app.CurrentData,'dnum')
                    dnum = app.CurrentData.dnum(:);
                    y = app.CurrentData.temperature(:);
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
            key = char(key);
            if strcmp(key, 'pressure')
                clr = [0 0 0];
                return
            end
            if strcmp(key, 'fpo7_noise_f')
                clr = [0 0 0];
                return
            end
            if strcmp(key, 'temperature')
                clr = [193 41 46]./255;
                return
            end
            % SignalColors is keyed by base channel name (t1/t2/s1/s2/
            % a1/a2/a3); every other key variant (t1_volt_f, t1_Tg_f,
            % s1_vel_f, a1_g_f, plain t1/s1/...) starts with one of these
            % tokens - match on that so raw/physical/wavenumber/theory
            % representations of the same channel share one color.
            tokens = {'t1','t2','s1','s2','a1','a2','a3'};
            clr = [0.3 0.3 0.3];
            for i = 1:numel(tokens)
                if startsWith(key, tokens{i})
                    clr = app.SignalColors.(tokens{i});
                    return
                end
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
            app.plotWavenumberSpectrum(idx);
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

            % ----- Physical-units frequency-domain spectra + FPO7 noise floor -----
            if isfield(app.CurrentData, 'physUnits')
                pu = app.CurrentData.physUnits;
                for i = 1:numel(app.PhysChannelOrder)
                    ch = app.PhysChannelOrder{i};
                    if ~isfield(app.ChannelCheck, ch) || strcmp(app.ChannelCheck.(ch).Visible, 'off')
                        continue
                    end
                    Pxx = app.getPhysSpectrum(ch, pu, idx, f);
                    if isempty(Pxx); continue; end
                    clr = app.getSignalColor(ch);
                    style = '-';
                    if strcmp(ch, 'fpo7_noise_f'); style = '--'; end
                    h = loglog(app.SpecAxes, f(keep), Pxx(keep), style, 'Color', clr, 'LineWidth', 1.2);
                    if isfield(app.ChannelOn, ch)
                        h.Visible = app.ChannelOn.(ch);
                    else
                        app.ChannelOn.(ch) = true;
                    end
                    app.SpecLines.(ch) = h;
                end
            end

            for i = 1:numel(app.FreqCutoffOrder)
                ch = app.FreqCutoffOrder{i};
                if ~isfield(app.ChannelCheck, ch) || strcmp(app.ChannelCheck.(ch).Visible, 'off')
                    continue
                end
                h = app.plotCutoffLines(app.SpecAxes, ch, idx);
                if ~isempty(h)
                    app.SpecLines.(ch) = h;
                end
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

        function h = plotCutoffLines(app, ax, ch, idx)
            % Draws CurrentData.(ch)(idx) - one channel's cutoff
            % frequency/wavenumber (t1_fc/t2_fc/s1_fc/s2_fc on SpecAxes,
            % t1_kc/t2_kc/s1_kc/s2_kc on WavAxes) - as a vertical line in
            % that channel's own color. Returns the line handle as a
            % 1-element graphics array (empty if this scan's value is
            % missing/NaN), so callers share the same array-safe
            % Visible-toggling path (setLineVisible) as the spectra lines.
            h = gobjects(1,0);
            if ~isfield(app.CurrentData, ch); return; end
            vals = app.CurrentData.(ch);
            if idx > numel(vals); return; end
            val = vals(idx);
            if ~isfinite(val); return; end
            clr = app.getSignalColor(ch);
            h = xline(ax, val, '-', 'Color', clr, 'LineWidth', 1.2);
            set(h, 'Visible', app.getChannelOnOr(ch, true));
        end

        function Pxx = getPhysSpectrum(app, ch, pu, idx, f)
            % One scan's physical-units frequency-domain spectrum for a
            % PhysChannelOrder entry, same length as f (NaN where
            % undefined) so callers can index it with the same f>0 mask
            % used for the raw channels.
            Pxx = [];
            switch ch
                case {'t1_Tg_f','t2_Tg_f'}
                    base = ch(1:2); % 't1' or 't2'
                    voltField = [base '_volt_f'];
                    if ~isfield(pu.cal, base) || ~isfield(app.CurrentData.spectra, voltField)
                        return
                    end
                    % Pt_T_f = Pt_volt_f * (degC/Volt slope)^2 - step 1 of
                    % mod_scan_fpo7_volts_to_Tg_spectrum.m, without that
                    % function's further thermal-lag deconvolution (that
                    % deconvolved, wavenumber-domain version is what the
                    % wavenumber panel below shows instead, from Profile's
                    % own precomputed Pt_Tg_k).
                    Pxx = app.CurrentData.spectra.(voltField)(idx,:) * pu.cal.(base)^2;
                case {'s1_vel_f','s2_vel_f'}
                    base = ch(1:2); % 's1' or 's2'
                    if ~isfield(pu.vel_f, base)
                        return
                    end
                    Pxx = pu.vel_f.(base)(idx,:);
                case 'fpo7_noise_f'
                    if isempty(pu.noise_coefs)
                        return
                    end
                    Pxx = nan(size(f));
                    valid = f > 0;
                    Pxx(valid) = mod_scan_fpo7_bench_noise_f(f(valid), pu.noise_coefs);
            end
        end

        function plotWavenumberSpectrum(app, idx)
            % Any wavenumber-domain channel this file has (getWavChannelList
            % - t1_Tg_k/t2_Tg_k/s1_shear_k/s2_shear_k today, generalizes to
            % whatever *_k field Profile carries), each gated by its own
            % dynamically-built checkbox (rebuildWavCheckboxes), overlaid
            % with a theoretical Batchelor curve for 't*' channels or
            % Panchev for 's*' channels. Cutoff wavenumbers (tg_kc/sh_kc)
            % are drawn as vertical lines the same way.
            cla(app.WavAxes);
            app.WavLines = struct();
            app.WavTheoryLines = struct();

            if ~isfield(app.CurrentData, 'spectra') || ~isfield(app.CurrentData.spectra, 'k')
                return
            end
            kAxis = app.CurrentData.spectra.k;
            if isempty(kAxis) || idx > size(kAxis,1); return; end
            k = kAxis(idx,:);
            keep = isfinite(k) & k > 0;
            if ~any(keep); return; end

            epsilon = app.scalarOr(app.getFieldOr(app.CurrentData, 'epsilon_final', []), idx);
            kvis    = app.scalarOr(app.getFieldOr(app.CurrentData, 'kvis', []), idx);
            ktemp   = app.scalarOr(app.getFieldOr(app.CurrentData, 'ktemp', []), idx);
            chiS    = app.getFieldOr(app.CurrentData, 'chi', struct());

            hold(app.WavAxes,'on');

            wavChannels = app.getWavChannelList();
            for i = 1:numel(wavChannels)
                ch = char(wavChannels(i));
                if ~isfield(app.ChannelCheck, ch) || strcmp(app.ChannelCheck.(ch).Visible, 'off')
                    continue
                end
                base = ch(1:2); % 't1'/'t2'/'s1'/'s2'
                clr = app.getSignalColor(ch);
                Pxx = app.CurrentData.spectra.(ch)(idx,:);
                h = loglog(app.WavAxes, k(keep), Pxx(keep), '-', 'Color', clr, 'LineWidth', 1.2);
                h.Visible = app.ChannelOn.(ch);
                app.WavLines.(ch) = h;

                if startsWith(base, 't') && isfield(chiS, base)
                    chi = app.scalarOr(chiS.(base), idx);
                    if isfinite(chi) && isfinite(epsilon) && isfinite(kvis) && isfinite(ktemp)
                        Psg = mod_scan_batchelor_spectrum(epsilon, chi, kvis, ktemp, k(keep));
                        ht = loglog(app.WavAxes, k(keep), Psg, '--', 'Color', clr, 'LineWidth', 1);
                        ht.Visible = app.ChannelOn.(ch);
                        app.WavTheoryLines.(ch) = ht;
                    end
                elseif startsWith(base, 's') && isfinite(epsilon) && isfinite(kvis)
                    Pan = mod_scan_panchev_spectrum(epsilon, kvis, k(keep));
                    ht = loglog(app.WavAxes, k(keep), Pan, '--', 'Color', clr, 'LineWidth', 1);
                    ht.Visible = app.ChannelOn.(ch);
                    app.WavTheoryLines.(ch) = ht;
                end
            end

            for i = 1:numel(app.WavCutoffOrder)
                ch = app.WavCutoffOrder{i};
                if ~isfield(app.ChannelCheck, ch) || strcmp(app.ChannelCheck.(ch).Visible, 'off')
                    continue
                end
                h = app.plotCutoffLines(app.WavAxes, ch, idx);
                if ~isempty(h)
                    app.WavLines.(ch) = h;
                end
            end

            hold(app.WavAxes,'off');
            grid(app.WavAxes,'on');
            set(app.WavAxes,'XScale','log','YScale','log');
            xlabel(app.WavAxes,'Wavenumber [cpm]');
            ylabel(app.WavAxes,'Power spectral density');

            if app.WavYLock && isfinite(app.WavYMinField.Value) && isfinite(app.WavYMaxField.Value) ...
                    && app.WavYMaxField.Value > app.WavYMinField.Value
                app.WavAxes.YLim = [app.WavYMinField.Value, app.WavYMaxField.Value];
            else
                app.WavAxes.YLimMode = 'auto';
                yl = app.WavAxes.YLim;
                app.WavYMinField.Value = yl(1);
                app.WavYMaxField.Value = yl(2);
            end

            if isfinite(epsilon)
                title(app.WavAxes, sprintf('\\epsilon_{final} = %.2e W/kg (dashed = Batchelor/Panchev theory)', epsilon));
            else
                title(app.WavAxes, '');
            end
        end

        function v = scalarOr(app, arr, idx) %#ok<INUSL>
            v = NaN;
            if ~isempty(arr) && numel(arr) >= idx
                v = arr(idx);
            end
        end

        function onChannelCheckChanged(app, ch, tf)
            app.ChannelOn.(ch) = tf;
            % Cutoff checkboxes (tg_fc/sh_fc/tg_kc/sh_kc) store a graphics
            % ARRAY of up to 2 line handles per key - isvalid(array) inside
            % && would error ("must be convertible to logical scalar
            % values"), so filter with isgraphics/set() instead, which
            % both handle arrays natively.
            app.setLineVisible('SpecLines', ch, tf);
            app.setLineVisible('WavLines', ch, tf);
            app.setLineVisible('WavTheoryLines', ch, tf);
        end

        function setLineVisible(app, mapName, ch, tf)
            m = app.(mapName);
            if ~isfield(m, ch); return; end
            h = m.(ch);
            h = h(isgraphics(h));
            if ~isempty(h)
                set(h, 'Visible', tf);
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

        function onWavYLimChanged(app)
            ymin = app.WavYMinField.Value;
            ymax = app.WavYMaxField.Value;
            if isfinite(ymin) && isfinite(ymax) && ymax > ymin && ymin > 0
                app.WavAxes.YLim = [ymin ymax];
            end
        end

        function onWavYLockChanged(app, tf)
            app.WavYLock = tf;
            if tf
                app.onWavYLimChanged();
            else
                app.WavAxes.YLimMode = 'auto';
                yl = app.WavAxes.YLim;
                app.WavYMinField.Value = yl(1);
                app.WavYMaxField.Value = yl(2);
            end
        end

        function onWavYReset(app)
            app.WavYLock = false;
            app.WavYLockCheck.Value = false;
            app.WavAxes.YLimMode = 'auto';
            yl = app.WavAxes.YLim;
            app.WavYMinField.Value = yl(1);
            app.WavYMaxField.Value = yl(2);
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
            % Keyed by base channel name only (t1/t2/s1/s2/a1/a2/a3) -
            % getSignalColor strips any unit/domain suffix (_volt_f,
            % _Tg_f, _g_f, ...) before looking up here, so every
            % representation of a given channel (raw volt/g, physical
            % units, wavenumber, theory curve) renders in the same color.
            C = struct();
            C.a1 = [129 27 112]./255;
            C.a2 = [235 64 61]./255;
            C.a3 = [245 199 118]./255;
            C.s1 = [60 134 76]./255;
            C.s2 = [173 215 136]./255;
            C.t1 = [29 78 140]./255;
            C.t2 = [78 173 173]./255;
        end
    end
end
