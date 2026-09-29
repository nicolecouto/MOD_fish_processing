classdef MODvis_spectra_L0 < handle
    % MODvis_spectra_L0        Part of MOD_fish_processing
    %
    % app = MODvis_spectra_L0(target, Name, Value, ...)
    %
    % Quick-look EFE spectra straight from L0 files, compared against ADC
    % bit noise - the MODSOM_liveplot use case, with no setup.yml needed.
    % L0 epsi is already in volts/g with channel names
    % (MODprocess_single_modraw_to_L0.m, standard EFE board -
    % MODsetup_default_efe.m), so this only needs the L0 file itself.
    % Laid out like MODvis_spectra: timeseries rows on top, one frequency
    % spectrum below.
    %
    %   - Pick a file (the newest one in the folder is selected on open,
    %     "Newest" re-lists and jumps to it again).
    %   - Top: 3 timeseries rows, each with a left and an optional right
    %     field (any epsi or ctd vector in the file), sharing one time axis.
    %     Defaults: t1/t2, s1/s2, a1/a2 (a missing channel falls back to
    %     the first epsi field / no right axis).
    %   - Click any timeseries row to center the spectrum window there;
    %     the window is shaded on every row. On load, the window is the
    %     last window_s seconds of the file.
    %   - "Timeseries view": show the full file, or zoom to the spectrum
    %     window +/- a buffer [s] (follows each click). Neither checked
    %     leaves your own zoom/pan alone.
    %   - Each row has min/max y-limit boxes and a Reset button for each
    %     side (left and right axis), always showing that side's current
    %     limits. Typing sets that side only; Reset returns it to auto.
    %     (MATLAB's zoom/pan tools act on one side of a yyaxis pair at a
    %     time, so these are the reliable way to set both.) Limits go back
    %     to auto when the file or that row's field changes.
    %   - "Lock spectrum limits" keeps the spectrum's current x/y limits
    %     (including a manual zoom) across redraws. Grid and ticks are at
    %     whole decades only.
    %   - Bottom: Welch spectrum of every checked channel over that window
    %     (mod_scan_welch_psd.m, each segment detrended on its own).
    %   - Every spectral setting is editable in the left panel - nfft,
    %     window length, overlap, taper, detrend - and changing one
    %     recomputes and redraws. The active settings, Fs, segments, dof
    %     and df are printed above the spectrum, so every screenshot
    %     records them.
    %   - Bit-noise lines for 24/20/16-bit ADCs, using the ADC LSB of the
    %     channel picked in the "Bit noise" dropdown (channels differ:
    %     t1/t2 unipolar 2.5 V, s1/s2 bipolar 2.5 V, a1-a3 in g via
    %     0.4 V/g). Per bit depth N: solid = delta^2/12/(Fs/2), dashed =
    %     delta^2/(Fs/2), with delta = LSB*2^(24-N) - same conventions and
    %     colors as MODvis_spectra. Plus the ADXL accelerometer sensor
    %     noise, (20e-6)^2 g^2/Hz, a property of the sensor, not the ADC.
    %
    % INPUTS
    %   target - (optional) an L0 .mat file or a folder of them. Default:
    %            pwd.
    %   Name-Value (starting values only - all editable in the viewer):
    %     'nfft'        - segment length [samples], default 1024
    %     'window_s'    - spectrum window length [s], default 10
    %     'overlap_pct' - segment overlap [%], default 50
    %     'taper'       - 'hann' (default) or 'hamming'
    %     'detrend'     - per-segment 'linear' (default), 'constant' or 'none'
    %     'metadata'    - metadata struct (MODsetup_read_yaml.m). If given,
    %                     its fft_length sets the starting nfft, and its
    %                     EFE names/config are re-applied to each file
    %                     (the same way MODprocess_single_L0_to_L1.m does)
    %   Defaults for nfft/window/overlap/taper match MODSOM_liveplot
    %   (scipy welch, nfft = nperseg = 1024 on the last 10 s).
    %
    % CALLS
    %   mod_scan_welch_psd.m, mod_scan_dof.m, mod_efe_conversion.m,
    %   mod_efe_counts_to_volts_g.m, mod_efe_volts_g_to_counts.m
    %
    % Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

    properties
        Fig matlab.ui.Figure
        GL matlab.ui.container.GridLayout

        FolderBtn matlab.ui.control.Button
        FolderLbl matlab.ui.control.Label
        FileList matlab.ui.control.ListBox
        RefreshBtn matlab.ui.control.Button
        NewestBtn matlab.ui.control.Button

        NfftField matlab.ui.control.NumericEditField
        WindowField matlab.ui.control.NumericEditField
        OverlapField matlab.ui.control.NumericEditField
        TaperDrop matlab.ui.control.DropDown
        DetrendDrop matlab.ui.control.DropDown

        NRows double = 3
        TopAxes          % one uiaxes per timeseries row
        ShadePatch       % window-shade xregion per row
        FieldADrop       % left-axis field per row
        FieldBDrop       % right-axis field per row ('(none)' allowed)
        YMinField        % [NRows x 2] y-limit min box per row, per side (1 left, 2 right)
        YMaxField        % [NRows x 2] y-limit max box
        YResetBtn        % [NRows x 2] back to auto limits
        LastFieldA string = ["epsi.t1_volt", "epsi.s1_volt", "epsi.a1_g"]
        LastFieldB string = ["epsi.t2_volt", "epsi.s2_volt", "epsi.a2_g"]

        SpecTitle matlab.ui.control.Label
        SpecAxes
        SpecCheckPanel matlab.ui.container.GridLayout
        ChannelCheck struct = struct()   % field name -> uicheckbox
        ChannelOn struct = struct()      % field name -> logical, persists across files
        NoiseCheck struct = struct()     % bit24/bit20/bit16/accel -> uicheckbox
        BitNoiseLsbDrop matlab.ui.control.DropDown
        SpecLockCheck                    % keep the spectrum's x/y limits across redraws
        SpecLockOn logical = false       % persists across files

        FullViewCheck matlab.ui.control.CheckBox     % timeseries: whole file
        WindowViewCheck matlab.ui.control.CheckBox   % timeseries: spectrum window +/- buffer
        BufferField matlab.ui.control.NumericEditField

        Folder string = ""
        Files string = strings(0,1)
        CurrentFile string = ""
        Data struct = struct()           % loaded file: epsi (volts/g), ctd
        Conversion struct = struct()     % epsi_conversion record
        Metadata = []
        WindowCenter double = NaN        % dnum the spectrum window is centered on

        BitNoiseBits = [24 20 16]
        BitNoiseColors = [90 90 90; 180 60 60; 60 140 60]./255   % same as MODvis_spectra
        AccelNoisePSD = (20e-6)^2        % ADXL sensor noise [g^2/Hz], accelerometer datasheet
        AccelNoiseColor = [110 50 160]./255
        ShadeColor = [0.85 0.2 0.2]
        SignalColors struct = struct()
        AxesFontSize double = 10
        CtrlColWidth double = 330        % right-hand control column (rows and spectrum share it)
    end

    methods
        function app = MODvis_spectra_L0(target, varargin)
            p = inputParser;
            p.addParameter('nfft', 1024);
            p.addParameter('window_s', 10);
            p.addParameter('overlap_pct', 50);
            p.addParameter('taper', 'hann');
            p.addParameter('detrend', 'linear');
            p.addParameter('metadata', []);
            p.parse(varargin{:});
            opts = p.Results;
            app.Metadata = opts.metadata;
            if isstruct(opts.metadata) && isfield(opts.metadata, 'PROCESS') ...
                    && isfield(opts.metadata.PROCESS, 'fft_length') && ~isempty(opts.metadata.PROCESS.fft_length)
                opts.nfft = opts.metadata.PROCESS.fft_length;
            end

            % Same per-channel colors as MODvis_spectra
            app.SignalColors = struct( ...
                't1', [29 78 140]./255, 't2', [78 173 173]./255, ...
                's1', [60 134 76]./255, 's2', [173 215 136]./255, ...
                'a1', [129 27 112]./255, 'a2', [235 64 61]./255, 'a3', [245 199 118]./255);

            app.buildUI(opts);

            file = "";
            if nargin < 1 || isempty(target)
                folder = string(pwd);
            elseif isfolder(target)
                folder = string(target);
            else
                [folder, name, ext] = fileparts(string(target));
                file = name + ext;
            end
            app.loadFolder(folder, file);
        end

        %% ---------------- UI ----------------
        function buildUI(app, opts)
            app.Fig = uifigure('Name', 'L0 Spectra', 'Position', [100 100 1500 1050]);
            app.GL = uigridlayout(app.Fig, [1 2]);
            app.GL.ColumnWidth = {250, '1x'};
            app.GL.Padding = [10 10 10 10];
            app.GL.ColumnSpacing = 10;

            %% LEFT: folder, files, spectral settings
            left = uigridlayout(app.GL, [15 2]);
            left.Layout.Row = 1; left.Layout.Column = 1;
            left.RowHeight = {30, 44, 22, '1x', 30, 26, 28, 28, 28, 28, 28, 26, 24, 24, 28};
            left.ColumnWidth = {'1x', '1x'};
            left.RowSpacing = 5;

            app.FolderBtn = uibutton(left, 'Text', 'Choose L0 folder...', ...
                'ButtonPushedFcn', @(~,~) app.chooseFolder());
            app.FolderBtn.Layout.Row = 1; app.FolderBtn.Layout.Column = [1 2];
            app.FolderLbl = uilabel(left, 'Text', '', 'WordWrap', 'on', 'FontSize', 10, ...
                'VerticalAlignment', 'top');
            app.FolderLbl.Layout.Row = 2; app.FolderLbl.Layout.Column = [1 2];

            lbl = uilabel(left, 'Text', 'L0 files (*.mat):', 'FontWeight', 'bold');
            lbl.Layout.Row = 3; lbl.Layout.Column = [1 2];
            app.FileList = uilistbox(left, 'Items', {}, 'FontSize', 12, ...
                'ValueChangedFcn', @(~,~) app.onFileSelected());
            app.FileList.Layout.Row = 4; app.FileList.Layout.Column = [1 2];

            app.RefreshBtn = uibutton(left, 'Text', 'Refresh', ...
                'ButtonPushedFcn', @(~,~) app.loadFolder(app.Folder, app.CurrentFile));
            app.RefreshBtn.Layout.Row = 5; app.RefreshBtn.Layout.Column = 1;
            app.NewestBtn = uibutton(left, 'Text', 'Newest', ...
                'ButtonPushedFcn', @(~,~) app.loadFolder(app.Folder, ""));
            app.NewestBtn.Layout.Row = 5; app.NewestBtn.Layout.Column = 2;

            lbl = uilabel(left, 'Text', 'Spectral settings', 'FontWeight', 'bold');
            lbl.Layout.Row = 6; lbl.Layout.Column = [1 2];

            app.NfftField = app.addNumericRow(left, 7, 'nfft [samples]', opts.nfft, [8 Inf], '%d');
            app.WindowField = app.addNumericRow(left, 8, 'window [s]', opts.window_s, [0 Inf], '%g');
            app.WindowField.Tooltip = 'Length of the spectrum window, centered where you click';
            app.OverlapField = app.addNumericRow(left, 9, 'overlap [%]', opts.overlap_pct, [0 95], '%g');

            lbl = uilabel(left, 'Text', 'taper');
            lbl.Layout.Row = 10; lbl.Layout.Column = 1;
            app.TaperDrop = uidropdown(left, 'Items', {'hann', 'hamming'}, 'Value', lower(opts.taper), ...
                'ValueChangedFcn', @(~,~) app.plotSpectrum());
            app.TaperDrop.Layout.Row = 10; app.TaperDrop.Layout.Column = 2;

            lbl = uilabel(left, 'Text', 'detrend', 'Tooltip', 'Applied to each segment before its taper/FFT');
            lbl.Layout.Row = 11; lbl.Layout.Column = 1;
            app.DetrendDrop = uidropdown(left, 'Items', {'linear', 'constant', 'none'}, 'Value', lower(opts.detrend), ...
                'ValueChangedFcn', @(~,~) app.plotSpectrum());
            app.DetrendDrop.Layout.Row = 11; app.DetrendDrop.Layout.Column = 2;

            % Timeseries x-range: two mutually exclusive checkboxes;
            % neither checked leaves your own zoom/pan alone
            lbl = uilabel(left, 'Text', 'Timeseries view', 'FontWeight', 'bold');
            lbl.Layout.Row = 12; lbl.Layout.Column = [1 2];
            app.FullViewCheck = uicheckbox(left, 'Text', 'Full file', 'Value', true, ...
                'ValueChangedFcn', @(src,~) app.onViewModeChanged('full', src.Value));
            app.FullViewCheck.Layout.Row = 13; app.FullViewCheck.Layout.Column = [1 2];
            app.WindowViewCheck = uicheckbox(left, 'Text', 'Zoom to window ± buffer', 'Value', false, ...
                'ValueChangedFcn', @(src,~) app.onViewModeChanged('window', src.Value));
            app.WindowViewCheck.Layout.Row = 14; app.WindowViewCheck.Layout.Column = [1 2];
            lbl = uilabel(left, 'Text', 'buffer [s]', 'Tooltip', 'Extra time shown on each side of the spectrum window');
            lbl.Layout.Row = 15; lbl.Layout.Column = 1;
            app.BufferField = uieditfield(left, 'numeric', 'Value', 5, 'Limits', [0 Inf], ...
                'ValueDisplayFormat', '%g', 'ValueChangedFcn', @(~,~) app.applyView());
            app.BufferField.Layout.Row = 15; app.BufferField.Layout.Column = 2;

            %% RIGHT: timeseries rows + spectrum section
            right = uigridlayout(app.GL, [app.NRows+1 1]);
            right.Layout.Row = 1; right.Layout.Column = 2;
            right.RowHeight = [repmat({'1x'}, 1, app.NRows), {'2.4x'}];
            right.RowSpacing = 8;

            app.TopAxes = gobjects(app.NRows, 1);
            app.ShadePatch = gobjects(app.NRows, 1);
            app.FieldADrop = gobjects(app.NRows, 1);
            app.FieldBDrop = gobjects(app.NRows, 1);
            app.YMinField = gobjects(app.NRows, 2);
            app.YMaxField = gobjects(app.NRows, 2);
            app.YResetBtn = gobjects(app.NRows, 2);
            for i = 1:app.NRows
                row = uigridlayout(right, [1 2]);
                row.Layout.Row = i;
                row.ColumnWidth = {'1x', app.CtrlColWidth};
                row.ColumnSpacing = 6;
                row.Padding = [0 0 0 0];

                % Each axes sits in a plain panel whose resize callback sets
                % the plot box to fixed pixel margins (room for tick labels
                % and ylabels) - every row's time axis then spans exactly
                % the same pixels whether or not it has a right axis, so
                % the shaded windows line up
                holder = uipanel(row, 'BorderType', 'none', 'AutoResizeChildren', 'off');
                holder.Layout.Row = 1; holder.Layout.Column = 1;
                ax = uiaxes(holder);
                ax.PositionConstraint = 'innerposition';
                ax.FontSize = app.AxesFontSize;
                holder.SizeChangedFcn = @(src,~) app.placeRowAxes(src, ax);
                app.placeRowAxes(holder, ax);
                ax.ButtonDownFcn = @(~,evt) app.onTimeseriesClicked(evt);
                app.TopAxes(i) = ax;

                % Controls: one column per y-axis side - field, min/max
                % limits, reset
                ctrl = uigridlayout(row, [4 2]);
                ctrl.Layout.Row = 1; ctrl.Layout.Column = 2;
                ctrl.RowHeight = {18, 24, 24, 24};
                ctrl.ColumnWidth = {'1x', '1x'};
                ctrl.RowSpacing = 4; ctrl.ColumnSpacing = 8;
                ctrl.Padding = [0 0 0 0];
                ii = i;
                sideNames = {'Left axis', 'Right axis (optional)'};
                for k = 1:2
                    lbl = uilabel(ctrl, 'Text', sideNames{k}, 'FontWeight', 'bold', 'FontSize', 11);
                    lbl.Layout.Row = 1; lbl.Layout.Column = k;
                    dd = uidropdown(ctrl, 'Items', {'(none)'}, 'FontSize', 11, ...
                        'ValueChangedFcn', @(~,~) app.onFieldChanged(ii));
                    dd.Layout.Row = 2; dd.Layout.Column = k;
                    if k == 1
                        app.FieldADrop(i) = dd;
                    else
                        app.FieldBDrop(i) = dd;
                    end
                    lim = uigridlayout(ctrl, [1 2]);
                    lim.Layout.Row = 3; lim.Layout.Column = k;
                    lim.ColumnWidth = {'1x', '1x'}; lim.ColumnSpacing = 4; lim.Padding = [0 0 0 0];
                    kk = k;
                    app.YMinField(i,k) = uieditfield(lim, 'numeric', 'ValueDisplayFormat', '%.4g', ...
                        'FontSize', 11, 'Tooltip', 'y min', ...
                        'ValueChangedFcn', @(~,~) app.onYLimitTyped(ii, kk));
                    app.YMaxField(i,k) = uieditfield(lim, 'numeric', 'ValueDisplayFormat', '%.4g', ...
                        'FontSize', 11, 'Tooltip', 'y max', ...
                        'ValueChangedFcn', @(~,~) app.onYLimitTyped(ii, kk));
                    app.YResetBtn(i,k) = uibutton(ctrl, 'Text', 'Reset y', 'FontSize', 11, ...
                        'ButtonPushedFcn', @(~,~) app.onYLimitReset(ii, kk));
                    app.YResetBtn(i,k).Layout.Row = 4; app.YResetBtn(i,k).Layout.Column = k;
                end
            end
            linkaxes(app.TopAxes, 'x');
            z = zoom(app.Fig);
            z.ActionPostCallback = @(~,evt) app.onUserZoomPan(evt);
            pn = pan(app.Fig);
            pn.ActionPostCallback = @(~,evt) app.onUserZoomPan(evt);

            spec = uigridlayout(right, [2 2]);
            spec.Layout.Row = app.NRows + 1;
            spec.RowHeight = {44, '1x'};
            spec.ColumnWidth = {'1x', app.CtrlColWidth};
            spec.ColumnSpacing = 6;
            spec.RowSpacing = 4;
            spec.Padding = [0 0 0 0];

            app.SpecTitle = uilabel(spec, 'Text', 'Click a timeseries above to move the spectrum window', ...
                'Interpreter', 'html', 'WordWrap', 'on', 'VerticalAlignment', 'top');
            app.SpecTitle.Layout.Row = 1; app.SpecTitle.Layout.Column = [1 2];

            app.SpecAxes = uiaxes(spec);
            app.SpecAxes.Layout.Row = 2; app.SpecAxes.Layout.Column = 1;
            app.SpecAxes.FontSize = app.AxesFontSize;

            app.SpecCheckPanel = uigridlayout(spec, [1 1]);
            app.SpecCheckPanel.Layout.Row = 2; app.SpecCheckPanel.Layout.Column = 2;
            app.SpecCheckPanel.Padding = [0 0 0 0];
        end

        function placeRowAxes(~, holder, ax)
            % Plot box = panel minus fixed margins [left bottom right top]
            m = [80 22 80 16];
            pos = holder.Position;
            ax.InnerPosition = [m(1), m(2), max(pos(3) - m(1) - m(3), 10), max(pos(4) - m(2) - m(4), 10)];
        end

        function fld = addNumericRow(app, parent, row, label, value, limits, fmt)
            lbl = uilabel(parent, 'Text', label);
            lbl.Layout.Row = row; lbl.Layout.Column = 1;
            fld = uieditfield(parent, 'numeric', 'Value', value, 'Limits', limits, ...
                'ValueDisplayFormat', fmt, 'ValueChangedFcn', @(~,~) app.onSettingsChanged());
            fld.Layout.Row = row; fld.Layout.Column = 2;
        end

        function buildCheckPanel(app)
            % Channels, then bit noise (LSB dropdown + 24/20/16 + accel)
            delete(app.SpecCheckPanel.Children);
            app.ChannelCheck = struct();
            app.NoiseCheck = struct();
            names = app.Conversion.channels;
            nRows = 1 + numel(names) + 1 + 1 + numel(app.BitNoiseBits) + 1 + 2;
            g = app.SpecCheckPanel;
            g.RowHeight = repmat({20}, 1, nRows);
            g.ColumnWidth = {'1x'};
            g.RowSpacing = 3;

            r = 1;
            lbl = uilabel(g, 'Text', 'Channels', 'FontWeight', 'bold', 'FontSize', 11);
            lbl.Layout.Row = r;
            for i = 1:numel(names)
                c = app.Conversion.channel.(names{i});
                if ~isfield(app.Data.epsi, c.field); continue; end
                if ~isfield(app.ChannelOn, c.field)
                    app.ChannelOn.(c.field) = true;
                end
                r = r + 1;
                cb = uicheckbox(g, 'Text', c.field, 'Value', app.ChannelOn.(c.field), 'FontSize', 11, ...
                    'FontColor', app.channelColor(names{i}), ...
                    'ValueChangedFcn', @(src,~) app.onChannelToggled(c.field, src.Value));
                cb.Layout.Row = r;
                app.ChannelCheck.(c.field) = cb;
            end

            r = r + 1;
            lbl = uilabel(g, 'Interpreter', 'html', 'FontSize', 11, ...
                'Text', '<b>Bit noise</b> (solid &Delta;&sup2;/12, dashed &Delta;&sup2;)');
            lbl.Layout.Row = r;
            r = r + 1;
            prev = 't1';
            if ~isempty(app.BitNoiseLsbDrop) && isvalid(app.BitNoiseLsbDrop)
                prev = app.BitNoiseLsbDrop.Value;
            end
            if ~any(strcmp(prev, names)); prev = names{1}; end
            app.BitNoiseLsbDrop = uidropdown(g, 'Items', names, 'Value', prev, 'FontSize', 11, ...
                'ValueChangedFcn', @(~,~) app.plotSpectrum());
            app.BitNoiseLsbDrop.Layout.Row = r;
            keys = {'bit24', 'bit20', 'bit16'};
            for i = 1:numel(app.BitNoiseBits)
                r = r + 1;
                cb = uicheckbox(g, 'Text', sprintf('%d-bit ADC', app.BitNoiseBits(i)), 'Value', true, ...
                    'FontSize', 11, 'FontColor', app.BitNoiseColors(i,:), ...
                    'ValueChangedFcn', @(~,~) app.plotSpectrum());
                cb.Layout.Row = r;
                app.NoiseCheck.(keys{i}) = cb;
            end
            r = r + 1;
            cb = uicheckbox(g, 'Text', 'ADXL accel noise', 'Value', true, 'FontSize', 11, ...
                'FontColor', app.AccelNoiseColor, 'ValueChangedFcn', @(~,~) app.plotSpectrum());
            cb.Layout.Row = r;
            app.NoiseCheck.accel = cb;
            r = r + 2;
            app.SpecLockCheck = uicheckbox(g, 'Text', 'Lock spectrum limits', 'Value', app.SpecLockOn, ...
                'FontSize', 11, 'FontWeight', 'bold', ...
                'Tooltip', 'Keep the current x/y limits (including your zoom) when the spectrum is redrawn', ...
                'ValueChangedFcn', @(src,~) app.onSpecLockChanged(src.Value));
            app.SpecLockCheck.Layout.Row = r;
        end

        %% ---------------- files ----------------
        function chooseFolder(app)
            p = uigetdir(char(app.Folder), 'Select L0 folder');
            if isequal(p, 0); return; end
            app.loadFolder(string(p), "");
        end

        function loadFolder(app, folder, file)
            % file = "" selects the newest file (by modification time)
            app.Folder = string(folder);
            app.FolderLbl.Text = char(app.Folder);
            listing = dir(fullfile(app.Folder, '*.mat'));
            listing = listing(~startsWith({listing.name}, '.'));
            if isempty(listing)
                app.Files = strings(0,1);
                app.FileList.Items = {};
                app.SpecTitle.Text = 'No .mat files in this folder.';
                return
            end
            [~, order] = sort({listing.name});
            listing = listing(order);
            app.Files = string({listing.name})';
            app.FileList.Items = cellstr(app.Files);
            if file == "" || ~any(app.Files == file)
                [~, iNew] = max([listing.datenum]);
                file = app.Files(iNew);
            end
            app.FileList.Value = char(file);
            app.onFileSelected();
        end

        function onFileSelected(app)
            file = string(app.FileList.Value);
            if file == ""; return; end
            app.CurrentFile = file;
            app.Fig.Name = "L0 Spectra - " + file;
            S = load(fullfile(app.Folder, file));
            if ~isfield(S, 'epsi') || isempty(S.epsi) || ~isstruct(S.epsi) || ~isfield(S.epsi, 'dnum')
                app.Data = struct();
                app.SpecTitle.Text = sprintf('<b>%s</b>: no EFE (epsi) data in this file.', file);
                for i = 1:app.NRows; cla(app.TopAxes(i)); end
                cla(app.SpecAxes);
                return
            end
            conversion = [];
            if isfield(S, 'epsi_conversion')
                conversion = S.epsi_conversion;
            end
            [epsi, app.Conversion] = app.toVoltsG(S.epsi, conversion);
            app.Data = struct('epsi', epsi, 'ctd', []);
            if isfield(S, 'ctd') && isstruct(S.ctd) && isfield(S.ctd, 'dnum')
                app.Data.ctd = S.ctd;
            end

            % Default window: the last window_s of the file
            win_d = app.WindowField.Value / 86400;
            app.WindowCenter = epsi.dnum(end) - win_d/2;

            app.buildCheckPanel();
            app.populateFieldDrops();
            for i = 1:app.NRows
                app.plotRow(i);
            end
            xlim(app.TopAxes(1), [epsi.dnum(1) epsi.dnum(end)]);
            app.applyView();
            app.plotSpectrum();
            % Auto y-limits are only final once everything is drawn
            for i = 1:app.NRows
                app.syncYFields(i);
            end
        end

        function [epsi, conversion] = toVoltsG(app, epsi, conversion)
            % Older L0 files hold raw channel1..N counts; newer ones are
            % already volts/g. If metadata was given, re-apply its names/
            % config from the exact counts (same as L0->L1). Also opens
            % L1 files, which carry the same epsi/epsi_conversion.
            if isfield(epsi, 'channel1')
                [epsi, conversion] = mod_efe_counts_to_volts_g(epsi, app.Metadata);
            elseif isempty(conversion)
                % volts/g but no record (e.g. an L1 file from before
                % epsi_conversion existed) - assume the standard EFE
                conversion = mod_efe_conversion(7, app.Metadata);
                conversion.source = ['ASSUMED, file has no epsi_conversion: ' conversion.source];
            elseif ~isempty(app.Metadata)
                epsi = mod_efe_volts_g_to_counts(epsi, conversion);
                [epsi, conversion] = mod_efe_counts_to_volts_g(epsi, app.Metadata);
            end
        end

        %% ---------------- timeseries rows ----------------
        function items = signalList(app)
            % 'struct.field' for every numeric vector the same length as
            % that struct's dnum, epsi first
            items = {};
            for s = {'epsi', 'ctd'}
                S = app.Data.(s{1});
                if ~isstruct(S) || ~isfield(S, 'dnum'); continue; end
                fn = fieldnames(S);
                for k = 1:numel(fn)
                    v = S.(fn{k});
                    if ~any(strcmp(fn{k}, {'dnum', 'time_s'})) && isnumeric(v) && isvector(v) ...
                            && numel(v) == numel(S.dnum)
                        items{end+1} = [s{1} '.' fn{k}]; %#ok<AGROW>
                    end
                end
            end
        end

        function populateFieldDrops(app)
            items = app.signalList();
            % Missing default (e.g. s2 renamed c1): first epsi field
            firstEpsi = items(startsWith(items, 'epsi.'));
            if isempty(firstEpsi); firstEpsi = items(1); end
            for i = 1:app.NRows
                app.FieldADrop(i).Items = items;
                app.FieldADrop(i).Value = app.pickItem(items, app.LastFieldA(i), string(firstEpsi{1}));
                app.FieldBDrop(i).Items = [{'(none)'}, items];
                app.FieldBDrop(i).Value = app.pickItem([{'(none)'}, items], app.LastFieldB(i), "(none)");
            end
        end

        function v = pickItem(~, items, preferred, fallbacks)
            for cand = [preferred, fallbacks]
                if any(strcmp(items, cand))
                    v = char(cand);
                    return
                end
            end
            v = items{1};
        end

        function onFieldChanged(app, i)
            app.LastFieldA(i) = string(app.FieldADrop(i).Value);
            app.LastFieldB(i) = string(app.FieldBDrop(i).Value);
            app.plotRow(i);
        end

        function [t, y] = getSeries(app, key)
            parts = split(string(key), '.');
            S = app.Data.(parts(1));
            t = S.dnum(:);
            y = double(S.(parts(2))(:));
        end

        function plotRow(app, i)
            ax = app.TopAxes(i);
            keepX = ax.XLim;
            keyA = app.FieldADrop(i).Value;
            keyB = app.FieldBDrop(i).Value;
            hasB = ~strcmp(keyB, '(none)');

            yyaxis(ax, 'right'); cla(ax); ylabel(ax, ''); ax.YLimMode = 'auto';
            yyaxis(ax, 'left'); cla(ax); ax.YLimMode = 'auto';
            [t, y] = app.getSeries(keyA);
            plot(ax, t, y, '-', 'Color', app.signalColor(keyA), 'LineWidth', 0.5, 'HitTest', 'off');
            ylabel(ax, keyA, 'Interpreter', 'none');
            ax.YAxis(1).Color = app.signalColor(keyA);
            if contains(keyA, '.P')
                ax.YAxis(1).Direction = 'reverse';
            else
                ax.YAxis(1).Direction = 'normal';
            end
            if hasB
                yyaxis(ax, 'right');
                [t2, y2] = app.getSeries(keyB);
                plot(ax, t2, y2, '-', 'Color', app.signalColor(keyB), 'LineWidth', 0.5, 'HitTest', 'off');
                ylabel(ax, keyB, 'Interpreter', 'none');
                ax.YAxis(2).Color = app.signalColor(keyB);
                yyaxis(ax, 'left');
            end
            ax.YAxis(2).Visible = hasB;
            set([app.YMinField(i,2), app.YMaxField(i,2), app.YResetBtn(i,2)], 'Enable', hasB);
            grid(ax, 'on');
            if keepX(2) > keepX(1) && keepX(1) > 1
                xlim(ax, keepX);
                app.applyTimeTicks();
            end
            app.drawShade(i);
            app.syncYFields(i);
        end

        function syncYFields(app, i)
            % The min/max boxes always show each side's current limits
            drawnow;   % make sure auto limits are computed before reading them
            ax = app.TopAxes(i);
            for k = 1:2
                yl = ax.YAxis(k).Limits;
                app.YMinField(i,k).Value = yl(1);
                app.YMaxField(i,k).Value = yl(2);
            end
        end

        function onYLimitTyped(app, i, k)
            % Set one side's limits; a min >= max is rejected and the boxes
            % go back to the current limits
            lo = app.YMinField(i,k).Value;
            hi = app.YMaxField(i,k).Value;
            if isfinite(lo) && isfinite(hi) && hi > lo
                app.TopAxes(i).YAxis(k).Limits = [lo hi];
            end
            app.syncYFields(i);
        end

        function onYLimitReset(app, i, k)
            app.TopAxes(i).YAxis(k).LimitsMode = 'auto';
            app.syncYFields(i);
        end

        function applyTimeTicks(app)
            % HH:MM:SS ticks on every row, labels on the bottom row only
            for i = 1:app.NRows
                datetick(app.TopAxes(i), 'x', 'HH:MM:SS', 'keeplimits');
                if i < app.NRows
                    app.TopAxes(i).XTickLabel = {};
                end
            end
        end

        function clr = signalColor(app, key)
            parts = split(string(key), '.');
            name = char(parts(end));
            if contains(key, '.P')
                clr = [0 0 0];
                return
            end
            clr = [0.3 0.3 0.3];
            for tok = fieldnames(app.SignalColors)'
                if startsWith(name, tok{1})
                    clr = app.SignalColors.(tok{1});
                    return
                end
            end
        end

        function clr = channelColor(app, name)
            if isfield(app.SignalColors, name)
                clr = app.SignalColors.(name);
            else
                clr = [0.3 0.3 0.3];
            end
        end

        function [i0, i1] = windowIndices(app)
            % Sample range of the spectrum window, centered on
            % WindowCenter and clamped to the file
            t = app.Data.epsi.dnum;
            n = min(numel(t), max(1, round(app.WindowField.Value * app.Conversion.Fs_epsi)));
            [~, ic] = min(abs(t - app.WindowCenter));
            i0 = ic - floor(n/2);
            i0 = max(1, min(i0, numel(t) - n + 1));
            i1 = i0 + n - 1;
        end

        function drawShade(app, i)
            ax = app.TopAxes(i);
            if isgraphics(app.ShadePatch(i)); delete(app.ShadePatch(i)); end
            if isempty(fieldnames(app.Data)) || ~isfinite(app.WindowCenter); return; end
            [i0, i1] = app.windowIndices();
            t = app.Data.epsi.dnum;
            % xregion spans the full height without touching the y-limits
            yyaxis(ax, 'left');
            app.ShadePatch(i) = xregion(ax, t(i0), t(i1), 'FaceColor', app.ShadeColor, ...
                'FaceAlpha', 0.2, 'HitTest', 'off');
        end

        function onTimeseriesClicked(app, evt)
            if isempty(fieldnames(app.Data)); return; end
            app.WindowCenter = evt.IntersectionPoint(1);
            for i = 1:app.NRows
                app.drawShade(i);
            end
            app.applyView();
            app.plotSpectrum();
        end

        function onSettingsChanged(app)
            % Window length changes the shade (and the zoomed view) too
            for i = 1:app.NRows
                app.drawShade(i);
            end
            app.applyView();
            app.plotSpectrum();
        end

        function onViewModeChanged(app, which, tf)
            % Mutually exclusive; unchecking both leaves the view as is
            if tf
                if strcmp(which, 'full')
                    app.WindowViewCheck.Value = false;
                else
                    app.FullViewCheck.Value = false;
                end
            end
            app.applyView();
        end

        function applyView(app)
            % Set the shared timeseries x-range from the view checkboxes;
            % with neither checked, keep the current view
            if isempty(fieldnames(app.Data)); return; end
            t = app.Data.epsi.dnum;
            if app.FullViewCheck.Value
                xlim(app.TopAxes(1), [t(1) t(end)]);
            elseif app.WindowViewCheck.Value
                [i0, i1] = app.windowIndices();
                buf = app.BufferField.Value / 86400;
                xlim(app.TopAxes(1), [max(t(1), t(i0) - buf), min(t(end), t(i1) + buf)]);
            end
            app.applyTimeTicks();
        end

        function onUserZoomPan(app, evt)
            % A manual zoom/pan on a timeseries row takes over the view
            if any(evt.Axes == app.TopAxes)
                app.FullViewCheck.Value = false;
                app.WindowViewCheck.Value = false;
                app.applyTimeTicks();
                for i = 1:app.NRows
                    app.syncYFields(i);
                end
            end
        end

        function onSpecLockChanged(app, tf)
            app.SpecLockOn = tf;
            if ~tf
                app.plotSpectrum();   % back to auto limits
            end
        end

        function onChannelToggled(app, field, tf)
            app.ChannelOn.(field) = tf;
            app.plotSpectrum();
        end

        %% ---------------- spectrum ----------------
        function plotSpectrum(app)
            if isempty(fieldnames(app.Data)); return; end
            ax = app.SpecAxes;
            Fs = app.Conversion.Fs_epsi;
            nfft = round(app.NfftField.Value);
            overlap_pct = app.OverlapField.Value;
            taper = app.TaperDrop.Value;
            detrend_type = app.DetrendDrop.Value;

            [i0, i1] = app.windowIndices();
            n = i1 - i0 + 1;
            step = nfft - round(overlap_pct/100 * nfft);
            t = app.Data.epsi.dnum;
            nTotal = numel(t);
            Fs_meas = NaN;
            if nTotal > 1
                % Timestamps are ms-quantized, so use the whole span
                % rather than a median sample spacing
                Fs_meas = (nTotal - 1) / ((t(end) - t(1)) * 86400);
            end

            % No legend - the checkbox column is color-keyed to every curve
            lockedLims = {};
            if app.SpecLockOn && ~isempty(ax.Children)
                lockedLims = {ax.XLim, ax.YLim};
            end
            cla(ax);
            hold(ax, 'on');
            nsegUsed = 0;
            nsegSkipped = 0;
            f = [];
            names = app.Conversion.channels;
            for iC = 1:numel(names)
                c = app.Conversion.channel.(names{iC});
                if ~isfield(app.Data.epsi, c.field) || ~app.ChannelOn.(c.field); continue; end
                x = app.Data.epsi.(c.field)(i0:i1);
                starts = 1:step:(numel(x) - nfft + 1);
                ok = arrayfun(@(s) all(isfinite(x(s:s+nfft-1))), starts);
                nsegSkipped = max(nsegSkipped, sum(~ok));
                starts = starts(ok);
                if isempty(starts); continue; end
                [Pxx, f] = mod_scan_welch_psd(x, nfft, starts, Fs, taper, detrend_type);
                nsegUsed = max(nsegUsed, numel(starts));
                plot(ax, f(2:end), Pxx(2:end), '-', ...
                    'Color', app.channelColor(names{iC}), 'LineWidth', 1.2);
            end
            if isempty(f)
                fEnds = [Fs/nfft Fs/2];
            else
                fEnds = [f(2) f(end)];
            end

            lsb = app.Conversion.channel.(app.BitNoiseLsbDrop.Value);
            keys = {'bit24', 'bit20', 'bit16'};
            for iB = 1:numel(app.BitNoiseBits)
                if ~app.NoiseCheck.(keys{iB}).Value; continue; end
                delta = lsb.scale * 2^(app.Conversion.bit_counts - app.BitNoiseBits(iB));
                clr = app.BitNoiseColors(iB,:);
                plot(ax, fEnds, delta^2/12/(Fs/2) * [1 1], '-', 'Color', clr, 'LineWidth', 1);
                plot(ax, fEnds, delta^2/(Fs/2) * [1 1], '--', 'Color', clr, 'LineWidth', 1);
            end
            if app.NoiseCheck.accel.Value
                plot(ax, fEnds, app.AccelNoisePSD * [1 1], '-.', ...
                    'Color', app.AccelNoiseColor, 'LineWidth', 1);
            end
            hold(ax, 'off');
            set(ax, 'XScale', 'log', 'YScale', 'log');
            if ~isempty(lockedLims)
                xlim(ax, lockedLims{1});
                ylim(ax, lockedLims{2});
            else
                xlim(ax, fEnds);
                % Explicit limits padded by half a decade - with tight
                % limits the lowest noise line sits on the axes edge and
                % disappears
                yAll = get(findobj(ax, 'Type', 'line'), 'YData');
                if iscell(yAll); yAll = [yAll{:}]; end
                yAll = yAll(isfinite(yAll) & yAll > 0);
                if ~isempty(yAll)
                    ylim(ax, [min(yAll) max(yAll)] .* [10^-0.5 10^0.5]);
                end
            end
            % Grid and ticks at whole decades only
            ax.XTick = 10.^(floor(log10(ax.XLim(1))):ceil(log10(ax.XLim(2))));
            ax.YTick = 10.^(floor(log10(ax.YLim(1))):ceil(log10(ax.YLim(2))));
            grid(ax, 'on');
            ax.XMinorGrid = 'off'; ax.YMinorGrid = 'off';
            ax.XMinorTick = 'off'; ax.YMinorTick = 'off';
            xlabel(ax, 'Frequency [Hz]');
            ylabel(ax, 'PSD [V^2/Hz, g^2/Hz]');
            app.BitNoiseLsbDrop.Tooltip = sprintf(['Bit-noise lines use this channel''s ADC LSB: ' ...
                '%s %g V, LSB = %.3g %s. Source: %s'], lsb.ADCconf, lsb.full_range, lsb.scale, lsb.unit, ...
                app.Conversion.source);

            if overlap_pct == 50 && nsegUsed > 0
                dofTxt = sprintf('%.3g', mod_scan_dof(nsegUsed));
            else
                dofTxt = 'n/a (1.9&times;segments needs 50% overlap)';
            end
            warnTxt = '';
            if nsegUsed == 0
                warnTxt = sprintf(' <font color="#b00">Window has fewer than nfft = %d finite samples.</font>', nfft);
            elseif nsegSkipped > 0
                warnTxt = sprintf(' <font color="#b00">%d segment(s) skipped (NaN).</font>', nsegSkipped);
            end
            app.SpecTitle.Text = sprintf([ ...
                '<b>%s</b> &nbsp; %s-%s (%.3g s, %d samples) &nbsp; <font color="#666">(%s)</font><br>' ...
                'nfft %d (df %.3g Hz) &middot; overlap %g%% &middot; %s taper &middot; detrend %s &middot; ' ...
                'Fs %g Hz nominal (%.4g measured) &middot; segments %d &middot; dof %s%s'], ...
                app.CurrentFile, datestr(t(i0), 'HH:MM:SS'), datestr(t(i1), 'HH:MM:SS'), n/Fs, n, ...
                app.Conversion.source, nfft, Fs/nfft, overlap_pct, taper, detrend_type, ...
                Fs, Fs_meas, nsegUsed, dofTxt, warnTxt);
        end
    end
end
