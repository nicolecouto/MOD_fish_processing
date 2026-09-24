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
        SpecShade struct = struct()     % PhysChannelOrder name -> noise-floor-to-3x shade patch handle
        ChannelOn struct = struct()     % channel name -> logical, persists across files
        SpecCheckPanel   % 2-column checkbox panel next to SpecAxes (raw | physical+cutoffs)
        ChannelCheck struct = struct()  % channel name -> uicheckbox handle
        ChannelOrder cell = {'t1_volt_f','t2_volt_f','s1_volt_f','s2_volt_f','a1_g_f','a2_g_f','a3_g_f'}
        SpecTitle matlab.ui.control.Label

        % FPO7 noise-floor curves, in physical (volts^2/Hz) units
        % (legacy Profile files only - see normalizeLegacyProfile). Share
        % the same SpecCheckPanel/ChannelOn/ChannelCheck maps as
        % ChannelOrder above, just a second group of rows ("Noise floors"
        % divider) appended below.
        PhysChannelOrder cell = {'fpo7_noise_f','t1_noise_shifted_f','t2_noise_shifted_f','fpo7_noise_modeled_f'}

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

        % Live-computed alternative to t1_fc/t2_fc above: same noise-floor-
        % crossing search (mod_scan_fpo7_cutoff_search.m - the shared core
        % behind mod_scan_fpo7_cutoff.m), run per scan against the
        % theoretical/modeled noise floor (mod_scan_fpo7_modeled_noise_f.m)
        % instead of the bench-measured one, so the two noise-floor choices
        % can be compared line-for-line on an otherwise identical
        % algorithm. Unlike t1_fc/t2_fc (a direct read of Profile.tg_fc,
        % computed once by whatever produced the Profile file, using the
        % legacy MOD_fish_lib algorithm), these are computed fresh here -
        % see computeModeledFreqCutoff. Populated into CurrentData the same
        % shape as t1_fc/t2_fc so plotCutoffLines needs no special-casing.
        ModeledFreqCutoffOrder cell = {'t1_fc_modeled','t2_fc_modeled'}

        % Wavenumber-domain companion to ModeledFreqCutoffOrder above -
        % same cutoff, converted to wavenumber via this scan's own
        % spectra.k (computeModeledFreqCutoff looks up spectra.k at the
        % same frequency bin the crossing search landed on, rather than
        % re-deriving a fall speed), so it can be drawn on WavAxes next to
        % t1_kc/t2_kc the same way t1_fc_modeled/t2_fc_modeled are drawn on
        % SpecAxes next to t1_fc/t2_fc. Only populated when this file
        % carries a per-scan spectra.k matrix (legacy Profile files) - see
        % computeModeledFreqCutoff.
        ModeledWavCutoffOrder cell = {'t1_kc_modeled','t2_kc_modeled'}

        % Batchelor theory overlay checkboxes - t1/t2 only (Batchelor is a
        % temperature-gradient spectrum; shear channels keep their existing
        % Panchev overlay, still tied to the observed s1_shear_k/s2_shear_k
        % checkbox, untouched by this pair). Decoupled from the observed
        % *_Tg_k spectrum checkbox so the theory curve can be shown/hidden
        % independently. "Obs" pairs Profile.chi (mod_scan_calc_chi_obs.m,
        % fit directly against the data) with epsilon_final; "Mle" pairs
        % Profile.chi_mle (mod_scan_calc_chi_mle.m) with the same
        % epsilon_final - Profile carries no separate "final" MLE epsilon,
        % and epsilon (dissipation) is a property of the flow, not of which
        % chi-estimation method produced the temperature-gradient variance.
        BatchelorObsOrder cell = {'t1_batchelor_obs','t2_batchelor_obs'}
        BatchelorMleOrder cell = {'t1_batchelor_mle','t2_batchelor_mle'}

        % Panchev theory overlay checkboxes - s1/s2 only, decoupled from
        % the observed s1_shear_co_k/s2_shear_co_k checkbox the same way
        % Batchelor is decoupled from t1_Tg_k/t2_Tg_k. "Co" pairs
        % epsilon_co (eps1_mmp direct fit against Ps_shear_co_k) with that
        % same coherence-corrected spectrum; "Mle" pairs epsilon_mle (fit
        % the same way, by maximum likelihood instead) with it too. The
        % raw s1_shear_k/s2_shear_k channel keeps its own separate,
        % checkbox-tied Panchev(epsilon) curve, untouched by this pair.
        PanchevCoOrder cell = {'s1_panchev_co','s2_panchev_co'}
        PanchevMleOrder cell = {'s1_panchev_mle','s2_panchev_mle'}

        WavAxes                          % wavenumber-domain panel, below SpecAxes
        WavLines struct = struct()       % _k channel name -> observed line handle
        WavTheoryLines struct = struct() % Batchelor/Panchev theory line handle, keyed by
                                          % its own checkbox name (_k channel name for the
                                          % raw-Panchev/s1_shear_k pairing, t{1,2}_batchelor_
                                          % {obs,mle}/s{1,2}_panchev_{co,mle} for the
                                          % decoupled overlays)
        WavCheckPanel    % 2-column checkbox panel next to WavAxes (_k channels+cutoffs | Batchelor obs+MLE | Panchev co+MLE)
        WavDivLbl        % "Wavenumber" divider label, rebuilt per file
        BatchelorObsDivLbl  % "Batchelor (from data)" divider label, rebuilt per file
        BatchelorMleDivLbl  % "Batchelor (MLE)" divider label, rebuilt per file
        PanchevCoDivLbl     % "Panchev (co)" divider label, rebuilt per file
        PanchevMleDivLbl    % "Panchev (MLE)" divider label, rebuilt per file
        DynamicWavKeys cell = {}  % currently-built _k/cutoff/Batchelor checkbox field
                                  % names, so they can be torn down before the
                                  % next file's rebuild (see rebuildWavCheckboxes)

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

        % Legacy Profile files carry no setup.yml, so the shifted-noise-
        % floor checkboxes (t1/t2_noise_shifted_f) use this repo's own
        % historical defaults for mod_scan_fpo7_noise_adjust.m's inputs
        % (MODsetup_metadata_field_registry.m) - confirmed identical to
        % what the legacy MOD_fish_lib FPO7_cutoff.m actually used
        % (hardcoded 0.7/15 there too), so these are a faithful default,
        % not a guess.
        NoiseAdjustedToF = 0.7
        NSmoothFSpectrum = 15

        % Same "legacy Profile files carry no setup.yml" situation for
        % ModeledFreqCutoffOrder's live noise-floor-crossing search
        % (mod_scan_fpo7_cutoff_search.m) - SN_min/n_skip match the same
        % MODsetup_metadata_field_registry.m historical defaults as above.
        % contam_freq_hz is different: production defaults it to Inf (no
        % deployment-specific value has been set), but this app has only
        % ever been pointed at ASTRAL data, whose own contamination line
        % was found (docs/workflow/L2_calc_chi.md, "Contamination-frequency
        % cap") at ~59 Hz - 55 Hz here is a deliberately conservative round
        % value below that line, not a re-derivation of it.
        ModeledCutoffSNmin = 3
        ModeledCutoffNskip = 2
        ModeledCutoffContamFreqHz = 55

        % A single channel's noise floor, noise-floor shading, and cutoff
        % line used to all render in that channel's own color (t1 blue,
        % t2 teal, ...) distinguished only by line style - hard to tell a
        % noise floor from a cutoff at a glance. These two colors instead
        % encode which noise floor a curve/cutoff is based on (bench-
        % measured vs. theoretical/modeled); channel identity (t1 vs t2)
        % is carried by line style instead (see plotCutoffLines) for the
        % curves/cutoffs this applies to - see getSignalColor.
        BenchNoiseColor = [0 0 0]        % black: fpo7_noise_f, t1/t2_noise_shifted_f, t1_fc, t2_fc
        ModeledNoiseColor = [0.80 0.10 0.10]  % red: fpo7_noise_modeled_f, t1_fc_modeled, t2_fc_modeled

        % SN_min multiplier for the noise-floor shading band (noise floor
        % up to NoiseFloorShadeSNmin x noise floor) - matches the SN_min
        % default (MODsetup_metadata_field_registry.m's sn_min, and this
        % app's own ModeledCutoffSNmin) that mod_scan_fpo7_cutoff_search.m
        % actually thresholds against, so the shaded band is the real
        % "still trustworthy" zone, not an arbitrary illustration.
        NoiseFloorShadeSNmin = 3

        % Default floor for the wavenumber (bottom) spectrum panel's
        % y-axis minimum, applied whenever it's not manually locked -
        % several theory curves (Batchelor/Panchev) decay toward zero at
        % high wavenumber, so a bare auto-scale often floors many orders
        % of magnitude below where any real data lives, squashing the
        % part of the log-scale axis anyone actually wants to see.
        WavYMinDefault = 1e-11
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
            for i = 1:numel(app.ModeledFreqCutoffOrder)
                app.ChannelOn.(app.ModeledFreqCutoffOrder{i}) = true;
            end
            for i = 1:numel(app.WavCutoffOrder)
                app.ChannelOn.(app.WavCutoffOrder{i}) = true;
            end
            for i = 1:numel(app.ModeledWavCutoffOrder)
                app.ChannelOn.(app.ModeledWavCutoffOrder{i}) = true;
            end
            for i = 1:numel(app.BatchelorObsOrder)
                app.ChannelOn.(app.BatchelorObsOrder{i}) = true;
            end
            for i = 1:numel(app.BatchelorMleOrder)
                app.ChannelOn.(app.BatchelorMleOrder{i}) = true;
            end
            for i = 1:numel(app.PanchevCoOrder)
                app.ChannelOn.(app.PanchevCoOrder{i}) = true;
            end
            for i = 1:numel(app.PanchevMleOrder)
                app.ChannelOn.(app.PanchevMleOrder{i}) = true;
            end
            app.YTickTextHandles = cell(app.NRows,1);
            app.YTickTextHandles2 = cell(app.NRows,1);
            app.Axis1Color = repmat({[0.15 0.15 0.15]}, app.NRows, 1);
            app.Axis2Color = repmat({[0.15 0.15 0.15]}, app.NRows, 1);

            app.buildUI();
            app.loadFolder(app.Folder);
        end

        function buildUI(app)
            app.Fig = uifigure('Name','Spectra Explorer','Position',[100 100 1490 1300]);

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
            % spans both rows. Each axis gets its own 2-column checkbox
            % panel (SpecCheckPanel/WavCheckPanel) rather than one long
            % shared list, to keep the growing checkbox count from
            % outrunning the window height.
            % Left padding (68) matches the top 3 rows' own left margin
            % (reserved there for their custom axis-1 tick text - see the
            % row-building loop above) purely so SpecAxes/WavAxes line up
            % under TopAxes, not because these axes need that margin
            % themselves. The checkbox-column width (403) is sized so the
            % axes column comes out exactly as wide as TopAxes - measured
            % empirically (TopAxes 723px vs SpecAxes 914px before this
            % fix, at this class's current Fig/GL/left-panel dimensions);
            % revisit this number if those change.
            combinedRow = uigridlayout(specSection, [2 2]);
            combinedRow.Layout.Row = 2; combinedRow.Layout.Column = 1;
            combinedRow.RowHeight = {'1x','1x'};
            combinedRow.ColumnWidth = {'1x', 403};
            combinedRow.ColumnSpacing = 6;
            combinedRow.RowSpacing = 6;
            combinedRow.Padding = [68 0 0 0];

            app.SpecAxes = uiaxes(combinedRow);
            app.SpecAxes.Layout.Row = 1; app.SpecAxes.Layout.Column = 1;
            % uiaxes defaults to FontSize 20 (with tick/label/title all at
            % that size, since Label/TitleFontSizeMultiplier both default
            % to 1) - TopAxes above explicitly pins FontSize to
            % AxesTickFontSize (10); match that here so the spectra panel's
            % axis labels/title aren't visibly larger than the timeseries
            % panel's.
            app.SpecAxes.FontSize = app.AxesTickFontSize;
            grid(app.SpecAxes,'on');
            xlabel(app.SpecAxes,'Frequency [Hz]');
            ylabel(app.SpecAxes,'Power spectral density');

            app.WavAxes = uiaxes(combinedRow);
            app.WavAxes.Layout.Row = 2; app.WavAxes.Layout.Column = 1;
            app.WavAxes.FontSize = app.AxesTickFontSize;
            grid(app.WavAxes,'on');
            xlabel(app.WavAxes,'Wavenumber [cpm]');
            ylabel(app.WavAxes,'Power spectral density');

            % Spec checkbox panel (static, built once here, visibility
            % toggled per file): column 1 = raw channels, column 2 =
            % noise floors + freq cutoffs.
            nRawCb = numel(app.ChannelOrder);
            nPhysCb = numel(app.PhysChannelOrder);
            nFreqCutoffCb = numel(app.FreqCutoffOrder) + numel(app.ModeledFreqCutoffOrder);
            col1Rows = 1 + nRawCb;                        % "Raw channels" + entries
            col2Rows = 1 + nPhysCb + 1 + nFreqCutoffCb;    % "Physical units" + entries + "Cutoffs" + entries
            specRows = max(col1Rows, col2Rows);

            app.SpecCheckPanel = uigridlayout(combinedRow, [specRows 2]);
            app.SpecCheckPanel.Layout.Row = 1; app.SpecCheckPanel.Layout.Column = 2;
            app.SpecCheckPanel.RowHeight = repmat({'fit'},1,specRows);
            app.SpecCheckPanel.ColumnWidth = {'1x','1x'};
            app.SpecCheckPanel.RowSpacing = 6;
            app.SpecCheckPanel.ColumnSpacing = 8;
            app.SpecCheckPanel.Padding = [4 20 0 0];

            rawDivLbl = uilabel(app.SpecCheckPanel, 'Text', 'Raw channels', 'FontWeight', 'bold');
            rawDivLbl.Layout.Row = 1; rawDivLbl.Layout.Column = 1;
            rawDivLbl.FontSize = 10;
            for i = 1:nRawCb
                ch = app.ChannelOrder{i};
                app.addChannelCheckbox(ch, ch, app.SpecCheckPanel, 1 + i, 1);
            end

            row = 1;
            divLbl = uilabel(app.SpecCheckPanel, 'Text', 'Noise floors', 'FontWeight', 'bold');
            divLbl.Layout.Row = row; divLbl.Layout.Column = 2;
            divLbl.FontSize = 10;
            for i = 1:nPhysCb
                row = row + 1;
                ch = app.PhysChannelOrder{i};
                lbl = ch;
                switch ch
                    case 'fpo7_noise_f'
                        lbl = 'FPO7 noise floor';
                    case 't1_noise_shifted_f'
                        lbl = 't1 noise floor (shifted)';
                    case 't2_noise_shifted_f'
                        lbl = 't2 noise floor (shifted)';
                    case 'fpo7_noise_modeled_f'
                        lbl = 'FPO7 noise floor (modeled)';
                end
                app.addChannelCheckbox(ch, lbl, app.SpecCheckPanel, row, 2);
            end

            row = row + 1;
            divLbl2 = uilabel(app.SpecCheckPanel, 'Text', 'Cutoffs (vertical lines)', 'FontWeight', 'bold');
            divLbl2.Layout.Row = row; divLbl2.Layout.Column = 2;
            divLbl2.FontSize = 10;
            for i = 1:numel(app.FreqCutoffOrder)
                row = row + 1;
                ch = app.FreqCutoffOrder{i};
                app.addChannelCheckbox(ch, ch, app.SpecCheckPanel, row, 2);
            end
            for i = 1:numel(app.ModeledFreqCutoffOrder)
                row = row + 1;
                ch = app.ModeledFreqCutoffOrder{i};
                lbl = strrep(ch, '_fc_modeled', ' cutoff (modeled)');
                app.addChannelCheckbox(ch, lbl, app.SpecCheckPanel, row, 2);
            end

            % Wav checkbox panel: dynamic, torn down/rebuilt per file (row
            % count varies) - see rebuildWavCheckboxes. Built empty here so
            % the layout exists before the first file loads.
            app.WavCheckPanel = uigridlayout(combinedRow, [1 2]);
            app.WavCheckPanel.Layout.Row = 2; app.WavCheckPanel.Layout.Column = 2;
            app.WavCheckPanel.RowHeight = {'fit'};
            app.WavCheckPanel.ColumnWidth = {'1x','1x'};
            app.WavCheckPanel.RowSpacing = 6;
            app.WavCheckPanel.ColumnSpacing = 8;
            app.WavCheckPanel.Padding = [4 20 0 0];

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
            % One "Field / Y-limits / Reset" control panel for either axis -
            % both left and right include NoneItem as a selectable entry
            % (Items populated per file in onFileSelected/clearAll).
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

            % Carry the selection across profiles by depth rather than by
            % index - profiles have different scan counts, so the same
            % index would land at an unrelated depth. Capture the old
            % profile's pressure at the current selection before it (and
            % CurrentData) get overwritten below.
            prevPressure = [];
            if ~isempty(app.SelectedScanIdx) && isfield(app.CurrentData,'pressure') ...
                    && numel(app.CurrentData.pressure) >= app.SelectedScanIdx
                prevPressure = app.CurrentData.pressure(app.SelectedScanIdx);
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

            % Row 1: pressure/temperature plus every other per-scan
            % Profile field this file happens to carry (row1FieldRegistry/
            % availableRow1Extras) - both selectable including "(none)".
            % Left and right offer the identical item list (same symmetric
            % pattern rows 2-3 already use for raw epsi channels below), so
            % any of these can go on either axis.
            hasTemp = isfield(app.CurrentData, 'temperature') && ~isempty(app.CurrentData.temperature);
            row1Items = {'pressure'};
            if hasTemp
                row1Items{end+1} = 'temperature';
            end
            row1Items = [row1Items, app.availableRow1Extras()];

            app.FieldADrop(1).Items = [{app.NoneItem}; row1Items(:)];
            app.FieldADrop(1).Enable = 'on';
            app.LastFieldA(1) = app.restoreOrDefault(app.FieldADrop(1), app.LastFieldA(1));

            app.FieldBDrop(1).Items = [{app.NoneItem}; row1Items(:)];
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
                app.FieldADrop(i).Items = [{app.NoneItem}; cellstr(channels)];
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

            % Noise-floor checkboxes - only legacy Profile files carry
            % this data (normalizeLegacyProfile); new-format L2/profile
            % files have no physUnits/wavenumber fields, so these stay
            % hidden for them.
            pu = struct('noise_coefs', []);
            if isfield(app.CurrentData, 'physUnits')
                pu = app.CurrentData.physUnits;
            end
            app.ChannelCheck.fpo7_noise_f.Visible = ~isempty(pu.noise_coefs);
            app.ChannelCheck.t1_noise_shifted_f.Visible = ~isempty(pu.noise_coefs) && any(strcmp(l2_channels, 't1_volt_f'));
            app.ChannelCheck.t2_noise_shifted_f.Visible = ~isempty(pu.noise_coefs) && any(strcmp(l2_channels, 't2_volt_f'));
            hasTempFs = isfield(app.CurrentData,'temperature') && ~isempty(app.CurrentData.temperature) ...
                && isfield(app.CurrentData,'Fs_epsi') && isfinite(app.CurrentData.Fs_epsi);
            app.ChannelCheck.fpo7_noise_modeled_f.Visible = ~isempty(pu.noise_coefs) && hasTempFs;

            % Frequency-domain cutoff checkboxes (vertical lines on SpecAxes).
            for i = 1:numel(app.FreqCutoffOrder)
                ch = app.FreqCutoffOrder{i};
                app.ChannelCheck.(ch).Visible = isfield(app.CurrentData,ch) && ~isempty(app.CurrentData.(ch));
            end

            % Live modeled-noise-floor cutoff (t1_fc_modeled/t2_fc_modeled)
            % - computed fresh per file (needs pu.noise_coefs/hasTempFs,
            % both just resolved above), same visibility-sync pattern as
            % FreqCutoffOrder just above.
            app.computeModeledFreqCutoff(pu, hasTempFs);
            for i = 1:numel(app.ModeledFreqCutoffOrder)
                ch = app.ModeledFreqCutoffOrder{i};
                app.ChannelCheck.(ch).Visible = isfield(app.CurrentData,ch) && ~isempty(app.CurrentData.(ch));
            end

            % Dynamic wavenumber group (any spectra.*_k channel this file
            % has, plus tg_kc/sh_kc if present) - rebuilt every file since
            % its row count varies (see rebuildWavCheckboxes).
            app.rebuildWavCheckboxes();

            % Re-select the scan at the closest depth to the one that was
            % selected in the previous profile, so a selection survives
            % moving between profiles instead of always being dropped.
            if ~isempty(prevPressure) && isfield(app.CurrentData,'pressure') ...
                    && ~isempty(app.CurrentData.pressure)
                [~, idx] = min(abs(app.CurrentData.pressure(:) - prevPressure));
                app.SelectedScanIdx = idx;
                for i = 1:app.NRows
                    app.redrawShade(i);
                end
                app.plotSpectrum(idx);
                app.plotWavenumberSpectrum(idx);
            else
                cla(app.SpecAxes);
                cla(app.WavAxes);
                app.SpecTitle.Text = 'Click a point above to show its spectrum';
            end

            if app.UseXWindow
                app.centerXWindowOnSelectedScan();
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

        function cb = addChannelCheckbox(app, ch, lbl, panel, row, col, clr)
            % Shared checkbox-creation helper for every group (raw,
            % noise floors, cutoffs, dynamic wavenumber, Batchelor
            % obs/MLE) - keeps the checkbox's initial Value in sync with
            % any persisted ChannelOn preference (relevant for the dynamic
            % groups, whose checkboxes are torn down and rebuilt every file
            % load - see rebuildWavCheckboxes).
            if nargin < 7
                clr = app.getSignalColor(ch);
            end
            if ~isfield(app.ChannelOn, ch)
                app.ChannelOn.(ch) = true;
            end
            cb = uicheckbox(panel, 'Text', lbl, ...
                'Value', app.ChannelOn.(ch), ...
                'FontColor', clr, ...
                'ValueChangedFcn', @(src,~)app.onChannelCheckChanged(ch, src.Value));
            cb.Layout.Row = row; cb.Layout.Column = col;
            cb.FontSize = 11;
            app.ChannelCheck.(ch) = cb;
        end

        function rebuildWavCheckboxes(app)
            % Rebuilds WavCheckPanel's two columns - column 1: any
            % spectra.*_k channel this file has (getWavChannelList) plus
            % the wavenumber cutoffs (WavCutoffOrder) when this file
            % carries them; column 2: Batchelor theory-overlay checkboxes
            % (BatchelorObsOrder/BatchelorMleOrder) and Panchev theory-
            % overlay checkboxes (PanchevCoOrder/PanchevMleOrder), each
            % only offered when this file actually carries the
            % corresponding chi/chi_mle or epsilon_co/epsilon_mle
            % channel. Row count varies file to file (legacy Profile files
            % only; new-format files have none), so it's torn down and
            % rebuilt on every onFileSelected rather than built once.
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
            if isgraphics(app.WavDivLbl); delete(app.WavDivLbl); end
            if isgraphics(app.BatchelorObsDivLbl); delete(app.BatchelorObsDivLbl); end
            if isgraphics(app.BatchelorMleDivLbl); delete(app.BatchelorMleDivLbl); end
            if isgraphics(app.PanchevCoDivLbl); delete(app.PanchevCoDivLbl); end
            if isgraphics(app.PanchevMleDivLbl); delete(app.PanchevMleDivLbl); end

            wavChannels = app.getWavChannelList();
            availableWavCutoffs = {};
            for i = 1:numel(app.WavCutoffOrder)
                ch = app.WavCutoffOrder{i};
                if isfield(app.CurrentData, ch) && ~isempty(app.CurrentData.(ch))
                    availableWavCutoffs{end+1} = ch; %#ok<AGROW>
                end
            end
            availableModeledWavCutoffs = {};
            for i = 1:numel(app.ModeledWavCutoffOrder)
                ch = app.ModeledWavCutoffOrder{i};
                if isfield(app.CurrentData, ch) && ~isempty(app.CurrentData.(ch))
                    availableModeledWavCutoffs{end+1} = ch; %#ok<AGROW>
                end
            end

            chiObs = app.getFieldOr(app.CurrentData, 'chi', struct());
            chiMle = app.getFieldOr(app.CurrentData, 'chi_mle', struct());
            availableBatchelorObs = {};
            for i = 1:numel(app.BatchelorObsOrder)
                ch = app.BatchelorObsOrder{i};
                base = ch(1:2); % 't1'/'t2'
                if isfield(chiObs, base) && ~isempty(chiObs.(base))
                    availableBatchelorObs{end+1} = ch; %#ok<AGROW>
                end
            end
            availableBatchelorMle = {};
            for i = 1:numel(app.BatchelorMleOrder)
                ch = app.BatchelorMleOrder{i};
                base = ch(1:2);
                if isfield(chiMle, base) && ~isempty(chiMle.(base))
                    availableBatchelorMle{end+1} = ch; %#ok<AGROW>
                end
            end

            epsilonCo  = app.getFieldOr(app.CurrentData, 'epsilonCo', struct());
            epsilonMle = app.getFieldOr(app.CurrentData, 'epsilonMle', struct());
            availablePanchevCo = {};
            for i = 1:numel(app.PanchevCoOrder)
                ch = app.PanchevCoOrder{i};
                base = ch(1:2); % 's1'/'s2'
                if isfield(epsilonCo, base) && ~isempty(epsilonCo.(base))
                    availablePanchevCo{end+1} = ch; %#ok<AGROW>
                end
            end
            availablePanchevMle = {};
            for i = 1:numel(app.PanchevMleOrder)
                ch = app.PanchevMleOrder{i};
                base = ch(1:2);
                if isfield(epsilonMle, base) && ~isempty(epsilonMle.(base))
                    availablePanchevMle{end+1} = ch; %#ok<AGROW>
                end
            end

            col1Rows = 0;
            if ~isempty(wavChannels) || ~isempty(availableWavCutoffs) || ~isempty(availableModeledWavCutoffs)
                col1Rows = 1 + numel(wavChannels) + numel(availableWavCutoffs) ...
                    + numel(availableModeledWavCutoffs); % +1 for "Wavenumber (_k)"
            end
            col2Rows = 0;
            if ~isempty(availableBatchelorObs)
                col2Rows = col2Rows + 1 + numel(availableBatchelorObs); % +1 for "Batchelor (from data)"
            end
            if ~isempty(availableBatchelorMle)
                col2Rows = col2Rows + 1 + numel(availableBatchelorMle); % +1 for "Batchelor (MLE)"
            end
            if ~isempty(availablePanchevCo)
                col2Rows = col2Rows + 1 + numel(availablePanchevCo); % +1 for "Panchev (co)"
            end
            if ~isempty(availablePanchevMle)
                col2Rows = col2Rows + 1 + numel(availablePanchevMle); % +1 for "Panchev (MLE)"
            end

            if col1Rows == 0 && col2Rows == 0
                app.WavCheckPanel.RowHeight = {'fit'};
                return
            end
            totalRows = max([col1Rows, col2Rows, 1]);
            app.WavCheckPanel.RowHeight = repmat({'fit'}, 1, totalRows);

            row = 0;
            if col1Rows > 0
                row = row + 1;
                app.WavDivLbl = uilabel(app.WavCheckPanel, 'Text', 'Wavenumber (_k)', 'FontWeight', 'bold');
                app.WavDivLbl.Layout.Row = row; app.WavDivLbl.Layout.Column = 1;
                app.WavDivLbl.FontSize = 10;
                for i = 1:numel(wavChannels)
                    row = row + 1;
                    ch = char(wavChannels(i));
                    app.addChannelCheckbox(ch, ch, app.WavCheckPanel, row, 1);
                    app.DynamicWavKeys{end+1} = ch;
                end
                for i = 1:numel(availableWavCutoffs)
                    row = row + 1;
                    ch = availableWavCutoffs{i};
                    app.addChannelCheckbox(ch, ch, app.WavCheckPanel, row, 1);
                    app.DynamicWavKeys{end+1} = ch;
                end
                for i = 1:numel(availableModeledWavCutoffs)
                    row = row + 1;
                    ch = availableModeledWavCutoffs{i};
                    lbl = strrep(ch, '_kc_modeled', ' cutoff (modeled)');
                    app.addChannelCheckbox(ch, lbl, app.WavCheckPanel, row, 1);
                    app.DynamicWavKeys{end+1} = ch;
                end
            end

            row = 0;
            if ~isempty(availableBatchelorObs)
                row = row + 1;
                app.BatchelorObsDivLbl = uilabel(app.WavCheckPanel, 'Text', 'Batchelor (from data)', 'FontWeight', 'bold');
                app.BatchelorObsDivLbl.Layout.Row = row; app.BatchelorObsDivLbl.Layout.Column = 2;
                app.BatchelorObsDivLbl.FontSize = 10;
                for i = 1:numel(availableBatchelorObs)
                    row = row + 1;
                    ch = availableBatchelorObs{i};
                    app.addChannelCheckbox(ch, ch(1:2), app.WavCheckPanel, row, 2);
                    app.DynamicWavKeys{end+1} = ch;
                end
            end
            if ~isempty(availableBatchelorMle)
                row = row + 1;
                app.BatchelorMleDivLbl = uilabel(app.WavCheckPanel, 'Text', 'Batchelor (MLE)', 'FontWeight', 'bold');
                app.BatchelorMleDivLbl.Layout.Row = row; app.BatchelorMleDivLbl.Layout.Column = 2;
                app.BatchelorMleDivLbl.FontSize = 10;
                for i = 1:numel(availableBatchelorMle)
                    row = row + 1;
                    ch = availableBatchelorMle{i};
                    app.addChannelCheckbox(ch, ch(1:2), app.WavCheckPanel, row, 2);
                    app.DynamicWavKeys{end+1} = ch;
                end
            end
            if ~isempty(availablePanchevCo)
                row = row + 1;
                app.PanchevCoDivLbl = uilabel(app.WavCheckPanel, 'Text', 'Panchev (co)', 'FontWeight', 'bold');
                app.PanchevCoDivLbl.Layout.Row = row; app.PanchevCoDivLbl.Layout.Column = 2;
                app.PanchevCoDivLbl.FontSize = 10;
                for i = 1:numel(availablePanchevCo)
                    row = row + 1;
                    ch = availablePanchevCo{i};
                    app.addChannelCheckbox(ch, ch(1:2), app.WavCheckPanel, row, 2);
                    app.DynamicWavKeys{end+1} = ch;
                end
            end
            if ~isempty(availablePanchevMle)
                row = row + 1;
                app.PanchevMleDivLbl = uilabel(app.WavCheckPanel, 'Text', 'Panchev (MLE)', 'FontWeight', 'bold');
                app.PanchevMleDivLbl.Layout.Row = row; app.PanchevMleDivLbl.Layout.Column = 2;
                app.PanchevMleDivLbl.FontSize = 10;
                for i = 1:numel(availablePanchevMle)
                    row = row + 1;
                    ch = availablePanchevMle{i};
                    app.addChannelCheckbox(ch, ch(1:2), app.WavCheckPanel, row, 2);
                    app.DynamicWavKeys{end+1} = ch;
                end
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

            % --- FPO7 noise-floor checkboxes (fpo7_noise_f/
            % t1_noise_shifted_f/t2_noise_shifted_f/fpo7_noise_modeled_f -
            % see plotSpectrum/getPhysSpectrum). Only ever populated for
            % legacy files - new-format L2/profile files don't reach
            % normalizeLegacyProfile at all, so this field is simply
            % absent there and the checkboxes stay hidden.
            S2.physUnits = struct('noise_coefs', []);
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
            % Coherence-corrected shear wavenumber spectrum (vibration/
            % acceleration contamination removed via Cs1a/Cs2a) - same
            % shape as Ps_shear_k, ends in '_k' so it's picked up by the
            % same generic *_k checkbox/plotting machinery for free (see
            % getWavChannelList).
            if isfield(Profile, 'Ps_shear_co_k') && isstruct(Profile.Ps_shear_co_k)
                coChans = fieldnames(Profile.Ps_shear_co_k);
                for iG = 1:numel(coChans)
                    ch = coChans{iG};
                    S2.spectra.([ch '_shear_co_k']) = Profile.Ps_shear_co_k.(ch);
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
            % Profile.chi_mle - same shape/column order as chi, from the
            % MLE chi estimator (mod_scan_calc_chi_mle.m) rather than the
            % direct-fit-to-data one (mod_scan_calc_chi_obs.m) - feeds the
            % second ("Batchelor MLE") theory overlay.
            S2.chi_mle = struct();
            chi_mle = app.getFieldOr(Profile, 'chi_mle', []);
            if ~isempty(chi_mle) && size(chi_mle,2) >= 2
                S2.chi_mle = struct('t1', chi_mle(:,1), 't2', chi_mle(:,2));
            end
            % epsilon_co/epsilon_mle - Panchev's analogue of chi/chi_mle:
            % both are fit against Ps_shear_co_k (eps1_mmp direct fit vs.
            % maximum likelihood - see mod_efe_scan_epsilon.m), not the raw
            % Ps_shear_k plain 'epsilon' already used by the Panchev curve
            % tied to s1_shear_k/s2_shear_k. Same column order as sh_fc/
            % sh_kc (column 1 = s1, column 2 = s2 - see cutoffPairs below).
            % Named distinctly from row1FieldRegistry's raw 'epsilon_co'/
            % 'epsilon_mle' (that dropdown's scalar-per-scan copies), same
            % as chi/chi_raw above.
            S2.epsilonCo = struct();
            epsilon_co = app.getFieldOr(Profile, 'epsilon_co', []);
            if ~isempty(epsilon_co) && size(epsilon_co,2) >= 2
                S2.epsilonCo = struct('s1', epsilon_co(:,1), 's2', epsilon_co(:,2));
            end
            S2.epsilonMle = struct();
            epsilon_mle = app.getFieldOr(Profile, 'epsilon_mle', []);
            if ~isempty(epsilon_mle) && size(epsilon_mle,2) >= 2
                S2.epsilonMle = struct('s1', epsilon_mle(:,1), 's2', epsilon_mle(:,2));
            end
            S2.kvis = app.getFieldOr(Profile, 'kvis', []);
            S2.ktemp = app.getFieldOr(Profile, 'ktemp', []);

            % --- Extra per-scan Profile fields offered on row 1's
            % timeseries dropdowns (see row1FieldRegistry/
            % availableRow1Extras/getSeries) - copied straight from
            % Profile under each entry's own field name (including
            % epsilon_final, which plotWavenumberSpectrum also reads
            % directly off CurrentData); simply left absent from
            % CurrentData - and therefore off the dropdown - when this
            % file doesn't carry a given one (most don't carry
            % epsi_fom/chi_fom/epsi_fom_mle/chi_fom_mle/epsilon_mle/
            % chi_mle/flag_tg_kc; only newer processing runs do). chi/
            % chi_mle store their raw 2-column form under 'chi_raw'/
            % 'chi_mle_raw' rather than 'chi'/'chi_mle', since those names
            % are already used just above for the per-channel struct form
            % (chi.t1/.t2) the Batchelor overlay needs.
            reg = app.row1FieldRegistry();
            for iR = 1:size(reg,1)
                srcField = reg{iR,2};
                dstField = reg{iR,3};
                S2.(dstField) = app.getFieldOr(Profile, srcField, []);
            end

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
            % Thin wrapper around resolveSeries: strips a "log10(...)"
            % dropdown-value wrapper (see availableRow1Extras) before
            % resolving, then log10-transforms the result - non-positive
            % values go to NaN first so chi/epsilon values that happen to
            % be <= 0 (a bad fit, not a real physical value) plot as a gap
            % rather than a complex/-Inf point.
            keyStr = string(key);
            isLogKey = false;
            tok = regexp(char(keyStr), '^log10\((.+)\)$', 'tokens', 'once');
            if ~isempty(tok)
                isLogKey = true;
                keyStr = string(tok{1});
            end
            [dnum, y] = app.resolveSeries(keyStr);
            if isLogKey && ~isempty(y)
                y(y <= 0) = NaN;
                y = log10(y);
            end
        end

        function [dnum, y] = resolveSeries(app, key)
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
            % row1FieldRegistry entry (w/s/th/sgth/epsilon_final/pitch/
            % roll/epsi_qc/.../epsilon_co(1)/epsilon_co(2)/chi(1)/chi(2)/
            % .../flag_tg_kc - see availableRow1Extras for how these reach
            % the dropdown). 2-column entries arrive here as "name(col)" -
            % parseIndexedKey splits that back into a base name + column.
            [baseKey, colIdx] = app.parseIndexedKey(key);
            reg = app.row1FieldRegistry();
            regRow = reg(strcmp(reg(:,1), baseKey), :);
            if ~isempty(regRow) && isfield(app.CurrentData, 'dnum')
                storageField = regRow{1,3};
                nCols = regRow{1,4};
                if isfield(app.CurrentData, storageField) && ~isempty(app.CurrentData.(storageField))
                    v = app.CurrentData.(storageField);
                    if nCols == 1
                        dnum = app.CurrentData.dnum(:);
                        y = v(:);
                    elseif ~isempty(colIdx) && colIdx >= 1 && colIdx <= size(v,2)
                        dnum = app.CurrentData.dnum(:);
                        y = v(:,colIdx);
                    end
                end
                return
            end
            % L1 raw epsi channel
            if isfield(app.CurrentL1Data,'epsi') && isfield(app.CurrentL1Data.epsi, key)
                dnum = app.CurrentL1Data.epsi.dnum(:);
                y = app.CurrentL1Data.epsi.(key)(:);
            end
        end

        function reg = row1FieldRegistry(~)
            % Registry of extra per-scan Profile fields offered on row 1's
            % timeseries dropdowns, beyond pressure/temperature (see
            % availableRow1Extras, getSeries, normalizeLegacyProfile).
            % Each row is {display base name, Profile source field,
            % CurrentData storage field, number of columns, plot in log10}.
            % A 2-column field is offered as two dropdown entries,
            % "name(1)"/"name(2)" (column 1/2 = t1/t2, matching every
            % other 2-column Profile field this app already splits that
            % way - see normalizeLegacyProfile's cutoffPairs). chi/chi_mle
            % use a different storage field ('chi_raw'/'chi_mle_raw') than
            % their display name, since 'chi'/'chi_mle' already name the
            % per-channel struct form (chi.t1/.t2) the Batchelor overlay
            % on WavAxes needs - see normalizeLegacyProfile. epsilon_final/
            % epsilon_co/epsilon_mle/chi/chi_mle span too many decades to
            % read as a linear-scale timeseries, so those are only offered
            % in log10 form ("log10(name)"/"log10(name(col))" - see
            % availableRow1Extras/getSeries), not also as a raw linear
            % option.
            reg = { ...
                'w',             'w',             'w',             1, false; ...
                's',             's',             's',             1, false; ...
                'th',            'th',            'th',            1, false; ...
                'sgth',          'sgth',          'sgth',          1, false; ...
                'epsilon_final', 'epsilon_final', 'epsilon_final', 1, true;  ...
                'pitch',         'pitch',         'pitch',         1, false; ...
                'roll',          'roll',          'roll',          1, false; ...
                'epsi_qc',       'epsi_qc',       'epsi_qc',       1, false; ...
                'epsi_fom',      'epsi_fom',      'epsi_fom',      1, false; ...
                'chi_fom',       'chi_fom',       'chi_fom',       1, false; ...
                'epsi_fom_mle',  'epsi_fom_mle',  'epsi_fom_mle',  1, false; ...
                'chi_fom_mle',   'chi_fom_mle',   'chi_fom_mle',   1, false; ...
                'epsilon_co',    'epsilon_co',    'epsilon_co',    2, true;  ...
                'epsilon_mle',   'epsilon_mle',   'epsilon_mle',   2, true;  ...
                'chi',           'chi',           'chi_raw',       2, true;  ...
                'chi_mle',       'chi_mle',       'chi_mle_raw',   2, true;  ...
                'flag_tg_kc',    'flag_tg_kc',    'flag_tg_kc',    1, false; ...
            };
        end

        function items = availableRow1Extras(app)
            % Row1FieldRegistry entries actually present in the currently
            % loaded file, expanded into dropdown item strings - scalar
            % (1-column) entries as their bare name, 2-column entries as
            % "name(1)"/"name(2)", each wrapped as "log10(...)" when the
            % registry marks that entry log-scale (see getSeries for where
            % the log10 is actually applied). Only entries this file's
            % normalizeLegacyProfile call actually populated are offered,
            % same pattern as the existing hasTemp check for 'temperature'.
            items = {};
            reg = app.row1FieldRegistry();
            for i = 1:size(reg,1)
                dispName = reg{i,1};
                storageField = reg{i,3};
                nCols = reg{i,4};
                isLog = reg{i,5};
                if ~isfield(app.CurrentData, storageField) || isempty(app.CurrentData.(storageField))
                    continue
                end
                if nCols == 1
                    label = dispName;
                    if isLog; label = sprintf('log10(%s)', label); end
                    items{end+1} = label; %#ok<AGROW>
                else
                    v = app.CurrentData.(storageField);
                    for c = 1:min(nCols, size(v,2))
                        label = sprintf('%s(%d)', dispName, c);
                        if isLog; label = sprintf('log10(%s)', label); end
                        items{end+1} = label; %#ok<AGROW>
                    end
                end
            end
        end

        function [base, idx] = parseIndexedKey(~, key)
            % Splits a "name(col)" dropdown value (see availableRow1Extras)
            % back into its base name and column index; a plain "name"
            % (no parens) returns idx = [] and base = key unchanged.
            base = char(key);
            idx = [];
            tok = regexp(base, '^(\w+)\((\d+)\)$', 'tokens', 'once');
            if ~isempty(tok)
                base = tok{1};
                idx = str2double(tok{2});
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
            if strcmp(key, 'temperature')
                clr = [193 41 46]./255;
                return
            end
            % Bench-measured noise floor curves (raw + per-channel-shifted)
            % and the cutoffs derived from them, in both frequency
            % (t1_fc/t2_fc) and wavenumber (t1_kc/t2_kc), all share one
            % color (black) regardless of channel; the theoretical/modeled
            % noise floor and its cutoffs (t1_fc_modeled/t2_fc_modeled,
            % t1_kc_modeled/t2_kc_modeled) share a second color (red) - so
            % bench vs. modeled reads as a color at a glance on either
            % panel. Channel identity (t1 vs t2) for these is carried by
            % line style instead - see plotCutoffLines. s1_fc/s2_fc/
            % s1_kc/s2_kc (shear) have no modeled counterpart and no noise
            % floor is ever plotted for them, so they fall through to the
            % channel-color token match below, unchanged.
            if any(strcmp(key, {'fpo7_noise_f','t1_noise_shifted_f','t2_noise_shifted_f', ...
                    't1_fc','t2_fc','t1_kc','t2_kc'}))
                clr = app.BenchNoiseColor;
                return
            end
            if any(strcmp(key, {'fpo7_noise_modeled_f','t1_fc_modeled','t2_fc_modeled', ...
                    't1_kc_modeled','t2_kc_modeled'}))
                clr = app.ModeledNoiseColor;
                return
            end
            % SignalColors is keyed by base channel name (t1/t2/s1/s2/
            % a1/a2/a3); every other key variant (t1_volt_f, t1_Tg_k,
            % a1_g_f, plain t1/s1/..., s1_fc/s2_fc/s1_kc/s2_kc) starts with
            % one of these tokens - match on that so raw/wavenumber/theory
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
                % Left axis's YLim just changed - the scan shade is sized
                % to match it (see redrawShade), so it must be redrawn or
                % it goes stale.
                app.redrawShade(rowIdx);
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
                % Left axis's YLim just changed - the scan shade is sized
                % to match it (see redrawShade), so it must be redrawn or
                % it goes stale.
                app.redrawShade(rowIdx);
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

            % Matches the axes' current YLim (left side, when dual) rather
            % than some oversized stand-in: an earlier version drew the
            % patch far beyond YLim and relied on axes Clipping to trim it,
            % so it wouldn't go stale after a later YLim change - but on a
            % yyaxis-enabled uiaxes that made the patch fail to render at
            % all (confirmed empirically: a patch with Y data around 1e8+
            % on an axis with data around 1e1 silently disappears, most
            % likely single-precision loss somewhere in the render
            % pipeline; the failure threshold is data-range-dependent, so
            % there's no fixed "big enough" constant that's safe for every
            % channel this app can plot). Every call site that changes the
            % left axis's YLim after this point must call redrawShade
            % again to keep the patch in sync - see plotRow (end of
            % function), onYLimitChanged, onYLimitReset.
            yl = ax.YLim;

            hold(ax,'on');
            app.ShadePatch(rowIdx) = patch(ax, [t0 t1 t1 t0], [yl(1) yl(1) yl(2) yl(2)], ...
                [1 0.85 0.2], 'FaceAlpha', 0.3, 'EdgeColor', 'none', ...
                'HitTest', 'off', 'PickableParts', 'none');
            hold(ax,'off');

            % The patch just above is the newest object in the left
            % y-axis's z-stack, so - left unaddressed - it paints in FRONT
            % of the axis-1 line (the axis-2/right line's z-order relative
            % to the patch is unaffected either way - confirmed empirically
            % it already renders above regardless). uistack(...,'bottom')
            % is the normal fix, but it throws on a yyaxis-enabled uiaxes
            % ("Children may only be set to a permutation of itself" - a
            % real MATLAB limitation, not a typo/logic bug), so it can
            % never actually move the patch back. Recreating the axis-1
            % line here instead makes IT the newest object, which puts it
            % back on top with no z-order API needed at all.
            app.restackAxis1Line(rowIdx);
        end

        function restackAxis1Line(app, rowIdx)
            % Deletes and immediately recreates TopLine(rowIdx) with
            % identical data/appearance - see redrawShade for why: it's
            % the only reliable way to get the axis-1 line to paint above
            % a just-added scan-shade patch on a yyaxis-enabled uiaxes.
            ax = app.TopAxes(rowIdx);
            h = app.TopLine(rowIdx);
            if ~isgraphics(h); return; end

            xdata = h.XData; ydata = h.YData;
            lineStyle = h.LineStyle; marker = h.Marker;
            clr = h.Color; lw = h.LineWidth; ms = h.MarkerSize;
            bdf = h.ButtonDownFcn;
            delete(h);

            if numel(ax.YAxis) > 1
                yyaxis(ax, 'left');
            end
            hold(ax,'on');
            hNew = plot(ax, xdata, ydata, 'LineStyle', lineStyle, 'Marker', marker, ...
                'Color', clr, 'LineWidth', lw, 'MarkerSize', ms);
            hold(ax,'off');
            hNew.ButtonDownFcn = bdf;
            app.TopLine(rowIdx) = hNew;
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
            app.SpecShade = struct();

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
                    switch ch
                        case 'fpo7_noise_f';           style = '--';  % unshifted bench, black
                        case {'t1_noise_shifted_f','t2_noise_shifted_f'}
                                                        style = ':';   % shifted bench, black
                        case 'fpo7_noise_modeled_f';   style = '-.';  % theoretical/modeled, red
                    end

                    % Shade the noise floor up to NoiseFloorShadeSNmin x
                    % itself - the actual "still trustworthy" zone each
                    % cutoff search thresholds against - using this curve's
                    % own color at low alpha, so it reads as gray for the
                    % bench curve and light red for the modeled one without
                    % needing separate shade colors. Only the per-channel
                    % curves an actual cutoff search compares against are
                    % shaded: t1/t2_noise_shifted_f (what
                    % mod_scan_fpo7_cutoff.m's SN_min comparison actually
                    % runs against - see mod_scan_fpo7_noise_adjust.m) and
                    % fpo7_noise_modeled_f (what the live modeled-cutoff
                    % checkbox compares against). fpo7_noise_f is the raw,
                    % unshifted bench reference curve - not itself a
                    % decision boundary for any cutoff - so it's left
                    % unshaded.
                    hs = gobjects(1,0);
                    if ~strcmp(ch, 'fpo7_noise_f')
                        fmask = keep & isfinite(Pxx) & Pxx > 0;
                        if any(fmask)
                            fShade  = f(fmask);
                            loBound = Pxx(fmask);
                            hiBound = app.NoiseFloorShadeSNmin * loBound;
                            hs = fill(app.SpecAxes, [fShade, fliplr(fShade)], [loBound, fliplr(hiBound)], ...
                                clr, 'FaceAlpha', 0.15, 'EdgeColor', 'none');
                            hs.Visible = app.ChannelOn.(ch);
                        end
                    end
                    app.SpecShade.(ch) = hs;

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

            for i = 1:numel(app.ModeledFreqCutoffOrder)
                ch = app.ModeledFreqCutoffOrder{i};
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
            % Switching XScale/YScale to log auto-enables minor gridlines
            % here (2/3/4/.../9-per-decade) even though MinorGrid was never
            % turned on explicitly - force them back off so only the major
            % decade lines (10^-1, 10^0, 10^1, ...) show.
            set(app.SpecAxes,'XMinorGrid','off','YMinorGrid','off');
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
            % frequency/wavenumber (t1_fc/t2_fc/s1_fc/s2_fc,
            % t1_fc_modeled/t2_fc_modeled on SpecAxes, t1_kc/t2_kc/s1_kc/s2_kc,
            % t1_kc_modeled/t2_kc_modeled on WavAxes) - as a vertical line.
            % For the FP07 cutoffs that have a bench/modeled pair (t1_fc/
            % t2_fc/t1_fc_modeled/t2_fc_modeled on SpecAxes, t1_kc/t2_kc/
            % t1_kc_modeled/t2_kc_modeled on WavAxes), color encodes
            % bench-vs-modeled (getSignalColor: black/red) and line style
            % encodes t1-vs-t2 (solid/dashed) instead - so, next to the
            % correspondingly-colored/shaded noise floor curves on
            % SpecAxes, "which noise floor" and "which channel" and
            % "cutoff vs. floor" all read at a glance instead of colliding
            % on one channel-color axis, and the same convention carries
            % over to WavAxes for a direct visual match. s1_fc/s2_fc/
            % s1_kc/s2_kc have no modeled counterpart to disambiguate from,
            % so they keep the original channel-colored solid-line
            % treatment (getSignalColor falls through to the t1/t2/s1/s2
            % token match for those). Returns the line handle as a
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
            style = '-';
            if startsWith(ch, 't2_fc') || startsWith(ch, 't2_kc')
                style = '--';
            end
            h = xline(ax, val, style, 'Color', clr, 'LineWidth', 2.5);
            set(h, 'Visible', app.getChannelOnOr(ch, true));
        end

        function computeModeledFreqCutoff(app, pu, hasTempFs)
            % Populates CurrentData.t1_fc_modeled/t2_fc_modeled: per-scan
            % cutoff frequency from the same noise-floor-crossing search
            % mod_scan_fpo7_cutoff.m runs in production
            % (mod_scan_fpo7_cutoff_search.m, the shared core), run against
            % the theoretical modeled noise floor
            % (mod_scan_fpo7_modeled_noise_f.m) instead of the bench-
            % measured one - see docs/workflow/L2_calc_chi.md,
            % "Contamination-frequency cap", for why the two are worth
            % comparing directly. Same shape/contract as t1_fc/t2_fc (a
            % per-scan array in CurrentData) so plotCutoffLines needs no
            % special-casing - only getPhysSpectrum's noise-floor-curve
            % overlays get that treatment, this is a cutoff line like
            % FreqCutoffOrder's entries.
            %
            % Also populates CurrentData.t1_kc_modeled/t2_kc_modeled
            % (ModeledWavCutoffOrder) when this file carries a per-scan
            % spectra.k matrix - the same cutoff bin's wavenumber, read
            % directly out of spectra.k rather than re-deriving a fall
            % speed, exactly as t1_kc/t2_kc are Profile.tg_kc's own
            % already-converted companion to Profile.tg_fc.
            %
            % pu/hasTempFs are the same values onFileSelected already
            % resolved for the fpo7_noise_modeled_f checkbox - passed in
            % rather than re-derived, since the guard conditions are
            % identical (needs bench noise_coefs for context even though
            % the modeled floor itself doesn't use them directly, plus
            % local temperature and Fs_epsi).
            for i = 1:numel(app.ModeledFreqCutoffOrder)
                app.CurrentData.(app.ModeledFreqCutoffOrder{i}) = [];
            end
            for i = 1:numel(app.ModeledWavCutoffOrder)
                app.CurrentData.(app.ModeledWavCutoffOrder{i}) = [];
            end
            if isempty(pu.noise_coefs) || ~hasTempFs ...
                    || ~isfield(app.CurrentData, 'spectra') || ~isfield(app.CurrentData.spectra, 'f')
                return
            end

            f = app.CurrentData.spectra.f(:);
            valid = f > 0;
            if ~any(valid); return; end
            vidx = find(valid); % index positions, not the logical mask itself -
            % f(vidx(fc_idx)) below maps a local (f(valid)-space) index back
            % to the original array; f(valid(fc_idx)) would be a bug (valid
            % is logical, so valid(fc_idx) evaluates to true/false, and
            % f(true) silently reads f(1), not the intended bin)
            fs = app.CurrentData.Fs_epsi;
            electronics_filter = mod_scan_adc_filter(f(valid), 'sinc4').^2;

            hasK = isfield(app.CurrentData.spectra, 'k') && ~isempty(app.CurrentData.spectra.k) ...
                && size(app.CurrentData.spectra.k, 2) == numel(f);
            if hasK
                kAxis = app.CurrentData.spectra.k;
            end

            for i = 1:numel(app.ModeledFreqCutoffOrder)
                outField = app.ModeledFreqCutoffOrder{i};
                kcField = app.ModeledWavCutoffOrder{i}; % same t1/t2 order as ModeledFreqCutoffOrder
                base = outField(1:2); % 't1' or 't2'
                voltField = [base '_volt_f'];
                if ~isfield(app.CurrentData.spectra, voltField)
                    continue
                end
                Pt_volt_f = app.CurrentData.spectra.(voltField);
                nScan = size(Pt_volt_f, 1);
                fc = nan(nScan, 1);
                kc = nan(nScan, 1);
                for iScan = 1:nScan
                    if iScan > numel(app.CurrentData.temperature); break; end
                    T = app.CurrentData.temperature(iScan);
                    if ~isfinite(T); continue; end
                    noise_f = mod_scan_fpo7_modeled_noise_f(f(valid), T, fs, electronics_filter);
                    medspec = smoothdata(Pt_volt_f(iScan, valid)', 'movmean', app.NSmoothFSpectrum);
                    fc_idx = mod_scan_fpo7_cutoff_search(f(valid), medspec, noise_f, ...
                        app.ModeledCutoffSNmin, app.ModeledCutoffNskip, app.ModeledCutoffContamFreqHz);
                    fc(iScan) = f(vidx(fc_idx));
                    if hasK && iScan <= size(kAxis, 1)
                        kval = kAxis(iScan, vidx(fc_idx));
                        if isfinite(kval)
                            kc(iScan) = kval;
                        end
                    end
                end
                app.CurrentData.(outField) = fc;
                if hasK
                    app.CurrentData.(kcField) = kc;
                end
            end
        end

        function Pxx = getPhysSpectrum(app, ch, pu, idx, f)
            % One scan's physical-units frequency-domain spectrum for a
            % PhysChannelOrder entry, same length as f (NaN where
            % undefined) so callers can index it with the same f>0 mask
            % used for the raw channels.
            Pxx = [];
            switch ch
                case 'fpo7_noise_f'
                    if isempty(pu.noise_coefs)
                        return
                    end
                    Pxx = nan(size(f));
                    valid = f > 0;
                    Pxx(valid) = mod_scan_fpo7_bench_noise_f(f(valid), pu.noise_coefs);
                case {'t1_noise_shifted_f','t2_noise_shifted_f'}
                    % Bench noise floor, scaled onto this scan's own
                    % observed spectrum (mod_scan_fpo7_noise_adjust.m) -
                    % same normalization mod_scan_fpo7_cutoff.m applies
                    % before comparing, so this is what the noise-floor
                    % cutoff decision actually sees, not the raw bench
                    % curve.
                    base = ch(1:2); % 't1' or 't2'
                    voltField = [base '_volt_f'];
                    if isempty(pu.noise_coefs) || ~isfield(app.CurrentData.spectra, voltField)
                        return
                    end
                    Pxx = nan(size(f));
                    valid = f > 0;
                    noise_f = mod_scan_fpo7_bench_noise_f(f(valid), pu.noise_coefs);
                    Pt_volt_f = app.CurrentData.spectra.(voltField)(idx,:);
                    adjust_spec = mod_scan_fpo7_noise_adjust(f(valid), Pt_volt_f(valid), pu.noise_coefs, ...
                        app.NoiseAdjustedToF, app.NSmoothFSpectrum);
                    Pxx(valid) = noise_f * adjust_spec;
                case 'fpo7_noise_modeled_f'
                    % Theoretical Johnson+amplifier noise floor
                    % (mod_scan_fpo7_modeled_noise_f.m), at this scan's own
                    % local water temperature - the "not yet wired into
                    % anything" alternative to the bench-measured floor
                    % (see PLAN.md's 2026-08-25/26 session log). Visualized
                    % here only; production chi still uses bench noise.
                    if isempty(pu.noise_coefs) || ~isfield(app.CurrentData,'temperature') ...
                            || idx > numel(app.CurrentData.temperature)
                        return
                    end
                    T  = app.CurrentData.temperature(idx);
                    fs = app.getFieldOr(app.CurrentData, 'Fs_epsi', NaN);
                    if ~isfinite(T) || ~isfinite(fs)
                        return
                    end
                    Pxx = nan(size(f));
                    valid = f > 0;
                    % Only ADCfilter type any real setup.yml or legacy
                    % metadata this repo has seen actually uses (see
                    % mod_scan_adc_filter.m) - legacy Profile files carry
                    % no metadata.AFE.(ch).ADCfilter to read this from.
                    electronics_filter = mod_scan_adc_filter(f(valid), 'sinc4').^2;
                    Pxx(valid) = mod_scan_fpo7_modeled_noise_f(f(valid), T, fs, electronics_filter);
            end
        end

        function plotWavenumberSpectrum(app, idx)
            % Any wavenumber-domain channel this file has (getWavChannelList
            % - t1_Tg_k/t2_Tg_k/s1_shear_k/s2_shear_k/s1_shear_co_k/
            % s2_shear_co_k today, generalizes to whatever *_k field
            % Profile carries), each gated by its own dynamically-built
            % checkbox (rebuildWavCheckboxes). The raw shear channels
            % (s1_shear_k/s2_shear_k only) are overlaid with a theoretical
            % Panchev(epsilon) curve tied to that same checkbox. Temperature
            % channels ('t*') get their Batchelor theory curves separately
            % below, gated by their own BatchelorObsOrder/BatchelorMleOrder
            % checkboxes instead - independent of whether the observed
            % *_Tg_k spectrum itself is shown; the coherence-corrected
            % shear channels get the same treatment via PanchevCoOrder/
            % PanchevMleOrder (epsilon_co/epsilon_mle, both fit against
            % Ps_shear_co_k - see normalizeLegacyProfile). Cutoff
            % wavenumbers (tg_kc/sh_kc) are drawn as vertical lines the
            % same way as the observed channels.
            cla(app.WavAxes);
            app.WavLines = struct();
            app.WavTheoryLines = struct();

            if ~isfield(app.CurrentData, 'spectra') || ~isfield(app.CurrentData.spectra, 'k')
                return
            end
            kAxis = app.CurrentData.spectra.k;
            if isempty(kAxis) || idx > size(kAxis,1); return; end
            k = kAxis(idx,:);

            % Some deployments (e.g. wirewalker upcasts) save Profile.k = f./w
            % with a signed, negative fall speed w, so k comes out uniformly
            % negative and nothing would pass the k>0 filter below - recompute
            % from f and |w| instead of dropping the whole scan. Epsilon/chi
            % are unaffected upstream (MOD_fish_lib already fits those against
            % f./abs(w) internally); only the k array saved for plotting keeps
            % the sign of w.
            if ~any(isfinite(k) & k > 0) && isfield(app.CurrentData.spectra, 'f')
                wScan = NaN;
                if isfield(app.CurrentData,'w') && numel(app.CurrentData.w) >= idx
                    wScan = app.CurrentData.w(idx);
                end
                if isfinite(wScan) && wScan ~= 0
                    k = app.CurrentData.spectra.f(:)' ./ abs(wScan);
                else
                    k = abs(k);
                end
            end

            keep = isfinite(k) & k > 0;
            if ~any(keep); return; end

            epsilon = app.scalarOr(app.getFieldOr(app.CurrentData, 'epsilon_final', []), idx);
            kvis    = app.scalarOr(app.getFieldOr(app.CurrentData, 'kvis', []), idx);
            ktemp   = app.scalarOr(app.getFieldOr(app.CurrentData, 'ktemp', []), idx);
            chiObs  = app.getFieldOr(app.CurrentData, 'chi', struct());
            chiMle  = app.getFieldOr(app.CurrentData, 'chi_mle', struct());
            epsilonCo  = app.getFieldOr(app.CurrentData, 'epsilonCo', struct());
            epsilonMle = app.getFieldOr(app.CurrentData, 'epsilonMle', struct());

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

                if startsWith(base, 's') && endsWith(ch, '_shear_k') && isfinite(epsilon) && isfinite(kvis)
                    Pan = mod_scan_panchev_spectrum(epsilon, kvis, k(keep));
                    ht = loglog(app.WavAxes, k(keep), Pan, '--', 'Color', clr, 'LineWidth', 1);
                    ht.Visible = app.ChannelOn.(ch);
                    app.WavTheoryLines.(ch) = ht;
                end
            end

            % ----- Batchelor theory overlays (t1/t2) and Panchev theory
            % overlays for the coherence-corrected shear channels (s1/s2),
            % each on its own checkbox - drawn regardless of whether the
            % corresponding observed t{1,2}_Tg_k/s{1,2}_shear_co_k spectrum
            % checkbox is on.
            app.plotBatchelorOverlay(app.BatchelorObsOrder, chiObs, epsilon, kvis, ktemp, k, keep, idx, '--');
            app.plotBatchelorOverlay(app.BatchelorMleOrder, chiMle, epsilon, kvis, ktemp, k, keep, idx, ':');
            app.plotPanchevOverlay(app.PanchevCoOrder,  epsilonCo,  kvis, k, keep, idx, '--');
            app.plotPanchevOverlay(app.PanchevMleOrder, epsilonMle, kvis, k, keep, idx, ':');

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

            for i = 1:numel(app.ModeledWavCutoffOrder)
                ch = app.ModeledWavCutoffOrder{i};
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
            % See plotSpectrum's matching comment - log XScale/YScale
            % auto-enables minor gridlines here too; force back off.
            set(app.WavAxes,'XMinorGrid','off','YMinorGrid','off');
            xlabel(app.WavAxes,'Wavenumber [cpm]');
            ylabel(app.WavAxes,'Power spectral density');

            if app.WavYLock && isfinite(app.WavYMinField.Value) && isfinite(app.WavYMaxField.Value) ...
                    && app.WavYMaxField.Value > app.WavYMinField.Value
                app.WavAxes.YLim = [app.WavYMinField.Value, app.WavYMaxField.Value];
            else
                app.applyWavYAutoDefault();
            end

            if isfinite(epsilon)
                title(app.WavAxes, sprintf('\\epsilon_{final} = %.2e W/kg (dashed = Panchev/Batchelor-data theory, dotted = Batchelor-MLE)', epsilon));
            else
                title(app.WavAxes, '');
            end
        end

        function plotBatchelorOverlay(app, order, chiStruct, epsilon, kvis, ktemp, k, keep, idx, style)
            % Draws one Batchelor theory curve per checkbox in `order`
            % (BatchelorObsOrder or BatchelorMleOrder) using chiStruct.t1/
            % .t2 (Profile.chi or Profile.chi_mle) - shared by both, only
            % `chiStruct` and `style` (line style, so the two variants stay
            % visually distinct) differ between the two call sites in
            % plotWavenumberSpectrum.
            for i = 1:numel(order)
                ch = order{i};
                if ~isfield(app.ChannelCheck, ch) || strcmp(app.ChannelCheck.(ch).Visible, 'off')
                    continue
                end
                base = ch(1:2); % 't1'/'t2'
                if ~isfield(chiStruct, base); continue; end
                chi = app.scalarOr(chiStruct.(base), idx);
                if ~(isfinite(chi) && isfinite(epsilon) && isfinite(kvis) && isfinite(ktemp))
                    continue
                end
                clr = app.getSignalColor(base);
                Psg = mod_scan_batchelor_spectrum(epsilon, chi, kvis, ktemp, k(keep));
                ht = loglog(app.WavAxes, k(keep), Psg, style, 'Color', clr, 'LineWidth', 1);
                ht.Visible = app.ChannelOn.(ch);
                app.WavTheoryLines.(ch) = ht;
            end
        end

        function plotPanchevOverlay(app, order, epsilonStruct, kvis, k, keep, idx, style)
            % Draws one Panchev theory curve per checkbox in `order`
            % (PanchevCoOrder or PanchevMleOrder) using epsilonStruct.s1/
            % .s2 (Profile.epsilon_co or .epsilon_mle, both fit against
            % Ps_shear_co_k - see normalizeLegacyProfile) - shared by both,
            % only `epsilonStruct` and `style` differ between the two call
            % sites in plotWavenumberSpectrum, same pattern as
            % plotBatchelorOverlay.
            for i = 1:numel(order)
                ch = order{i};
                if ~isfield(app.ChannelCheck, ch) || strcmp(app.ChannelCheck.(ch).Visible, 'off')
                    continue
                end
                base = ch(1:2); % 's1'/'s2'
                if ~isfield(epsilonStruct, base); continue; end
                epsilonVal = app.scalarOr(epsilonStruct.(base), idx);
                if ~(isfinite(epsilonVal) && isfinite(kvis))
                    continue
                end
                clr = app.getSignalColor(base);
                Pan = mod_scan_panchev_spectrum(epsilonVal, kvis, k(keep));
                ht = loglog(app.WavAxes, k(keep), Pan, style, 'Color', clr, 'LineWidth', 1);
                ht.Visible = app.ChannelOn.(ch);
                app.WavTheoryLines.(ch) = ht;
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
            app.setLineVisible('SpecShade', ch, tf);
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
                app.applyWavYAutoDefault();
            end
        end

        function onWavYReset(app)
            app.WavYLock = false;
            app.WavYLockCheck.Value = false;
            app.applyWavYAutoDefault();
        end

        function applyWavYAutoDefault(app)
            % Auto-scales WavAxes, then floors the minimum at
            % WavYMinDefault (see that property's comment for why) -
            % shared by plotWavenumberSpectrum, onWavYLockChanged (unlock),
            % and onWavYReset, so the floor applies everywhere the axis
            % falls back to "default" rather than a user-set/locked range.
            app.WavAxes.YLimMode = 'auto';
            yl = app.WavAxes.YLim;
            if yl(2) > app.WavYMinDefault
                yl(1) = app.WavYMinDefault;
                app.WavAxes.YLim = yl;
            end
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
            app.centerXWindowOnSelectedScan();
            app.applyXWindow();
        end

        function centerXWindowOnSelectedScan(app)
            if isempty(app.SelectedScanIdx) || isempty(app.GlobalDnum) || ...
                    ~isfinite(app.ProfileTmin) || app.ProfileTmax <= app.ProfileTmin
                return;
            end
            centerT    = app.GlobalDnum(app.SelectedScanIdx);
            winDays    = app.XWindowLen / 86400;
            profileDur = app.ProfileTmax - app.ProfileTmin;
            maxFrac    = 1 - winDays / profileDur;
            frac       = (centerT - winDays/2 - app.ProfileTmin) / profileDur;
            app.XWinFraction = min(max(frac, 0), max(maxFrac, 0));
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
