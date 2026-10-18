function [L1_files, problems, processed] = MODprocess_all_L0_to_L1(L0_dir, metadata, L1_dir, reprocess_all, varargin)
% MODprocess_all_L0_to_L1        Part of MOD_fish_processing
%
% L1_files = MODprocess_all_L0_to_L1(L0_dir, metadata, L1_dir, reprocess_all)
% [L1_files, problems, processed] = MODprocess_all_L0_to_L1(..., 'newest_min_redo_s', s, 'continue_on_error', tf)
%
% DESCRIPTION
%   Converts every L0 .mat file in L0_dir to a physical-units .mat file in
%   L1_dir, using MODprocess_single_L0_to_L1.
%
%   Also resolves each AFE channel's deployment-constant electronics/ADC
%   transfer function (MODsetup_define_filters.m ->
%   metadata.AFE.(ch).electronics_filter, saved back via
%   MODsetup_save_metadata.m) unconditionally, before the per-file loop -
%   needs only metadata.PROCESS/.AFE, no L0/L1 data or CTD, unlike the
%   fpo7 calibration step below. This is what lets mod_scan_calc_chi_obs.m
%   deconvolve the AFE's sinc^4 ADC rolloff, not just the FP07 thermal
%   rolloff - see docs/workflow/L2_calc_chi.md.
%
%   Skips files that already have an up-to-date L1 .mat (L1 file modified
%   at or after its source L0 file), except the most recently modified L0
%   file, which is always reprocessed in case the raw file behind it was
%   still being written when L0 last ran on it (mirrors
%   MODprocess_all_modraw_to_L0.m's same rule one level up). Pass
%   reprocess_all = true to force every file to be redone regardless.
%
%   Whenever any L1 file has twist (its raw file had VNAV data - the yml
%   isn't asked), also re-chains every L1 file's
%   per-file twist count into a deployment-level meta/twist_time_series.mat
%   (via MODprocess_L1_accumulate_twist_timeseries.m) at the end of every
%   call - cheap, since it only concatenates fields already computed
%   per-file, and keeps the deployment-level twist count always current.
%
%   If any L1 file has CTD pressure (onboard SBE, or an external-CTD
%   vehicle's file - the data decide, not the yml), also builds/updates
%   meta/pressure_time_series.mat - the deployment-length pressure record,
%   with a smoothed dPdt and an is_down (descending) classification per
%   sample (MODprocess_L1_make_pressure_timeseries.m +
%   mod_L1_detect_profiling_direction.m). This is what
%   MODprocess_single_L1_to_L2.m gates spectra-computation scans against -
%   see PLAN.md Section 4. Also builds meta/time_index.mat (per-L1-file
%   dnum start/end, via MODprocess_L1_make_time_index.m), so
%   modProcess_extract_profile.m can find which L1 file(s) overlap a given
%   profile's time range without loading every file's full contents - see
%   PLAN.md Section 6.3.
%
%   If that CTD is the onboard one specifically (no external-CTD file -
%   an external-CTD vehicle like DeepSolo never has real temperature),
%   also fits and persists each FP07 channel's in-situ volts->degC calibration
%   (MODprocess_L1_apply_fpo7_calibration.m -> metadata.AFE.(ch).volts_to_C),
%   saved to meta/fpo7_calibration.mat with each probe's SN (and recorded in
%   meta/metadata.mat via MODsetup_save_metadata.m). This is the calibration
%   mod_scan_calc_chi_obs.m needs; MODsetup_add_derived_metadata.m loads it
%   back for later steps. Deployments without a real CTD never get it.
%
% INPUTS
%   L0_dir        - full path to a folder of L0 .mat files
%   metadata      - metadata struct (from MODsetup_read_yaml.m), read once
%                    per session and passed through - see PLAN.md Section 2.
%   L1_dir        - (optional) full path to save .mat files to. Default:
%                    a sibling 'L1' folder next to L0_dir
%                    (fullfile(fileparts(L0_dir),'L1')), created if missing.
%   reprocess_all - (optional) logical, default false. If true, ignores
%                    the up-to-date check and reconverts every L0 file.
%   Name-value options (same for MODprocess_all_modraw_to_L0.m,
%   MODprocess_all_L0_to_L1.m and MODprocess_all_L1_to_L2.m):
%     'newest_min_redo_s' - default 0: the newest file is always redone (in
%                      case it's still being written). > 0 (the realtime
%                      worker): the newest file is redone only when it's
%                      out of date, at most once per this many seconds -
%                      see MODutil_needs_redo.m.
%     'continue_on_error' - default false: a file that fails stops the run
%                      with its error. true (the realtime worker): the file
%                      is recorded in problems and the next file is done.
%     'fpo7_refit_new_files' (this driver only) - default 0: the FP07
%                      volts->degC fit is redone on every call. N > 0 (the
%                      realtime worker): redone only once N more L1 files
%                      exist than at the last fit (or if there's no fit
%                      yet), since it reads every L1 file.
%
% OUTPUTS
%   L1_files  - cell array of full paths to all .mat files in L1_dir
%               after this call (both newly converted and pre-existing)
%   problems  - struct array (.file, .stage, .identifier, .message), one
%               per file that failed with 'continue_on_error' true; empty
%               otherwise
%   processed - cellstr of the input files (re)processed by this call
%
% CALLED BY
%   MODprocess_deployment.m, top-level scripts
%
% CALLS
%   MODsetup_add_derived_metadata.m, MODsetup_save_metadata.m (unconditional)
%   MODprocess_single_L0_to_L1.m, MODprocess_read_external_ctd.m (only for
%   vehicles with an independent CTD file - see NOTES)
%   MODprocess_L1_accumulate_twist_timeseries.m (writes nothing when no L1 file has twist)
%   MODprocess_L1_make_pressure_timeseries.m, mod_L1_detect_profiling_direction.m
%   (only when this deployment has CTD data)
%   MODprocess_L1_make_time_index.m (unconditional - see below)
%   MODprocess_L1_apply_fpo7_calibration.m, MODsetup_save_metadata.m
%   (only when the CTD data are from the onboard CTD)
%   MODsetup_read_yaml.m (only to reread the yml after a prompted value is
%   saved to it - MODsetup_validate_metadata.m's yamlUpdated)
%   MODutil_needs_redo.m, MODutil_save_atomic.m, MODprocess_L1_update_file_cache.m,
%   MODutil_provenance.m
%   MODutil_short_path.m (console messages only)
%
% NOTES
%   The in-memory metadata passed in as an argument is NOT updated with a
%   newly-fit volts_to_C. A later step doesn't need it to be:
%   MODprocess_all_L1_to_L2.m calls MODsetup_add_derived_metadata.m, which
%   loads the fit from meta/fpo7_calibration.mat. (meta/metadata.mat is a
%   record only - the next MODsetup_read_yaml.m call rewrites it without
%   the fit.)
%
%   A value prompted for and saved to the yml (MODsetup_validate_metadata.m
%   throws yamlUpdated) is handled here: metadata is reread and the step
%   retried, the same way MODprocess_all_L1_to_L2.m does it.
%   metadata is loaded once by the caller (MODsetup_read_yaml.m) and
%   passed in here rather than re-read per file - it does not change
%   file-to-file within a deployment.
%
%   DeepSolo/Wirewalker (metadata.vehicle_name) get their CTD data from an
%   independent file rather than $SB49/$SB41 blocks in the L0 stream. If
%   metadata.paths.ctd exists on disk, it's read once here (via
%   MODprocess_read_external_ctd.m) and sliced per L0 file by dnum, mirroring
%   how metadata itself is read once per session rather than per file. If
%   the folder doesn't exist yet, that's treated as "no CTD for this
%   deployment yet" (not an error) - common today, since
%   MODprocess_read_external_ctd.m has no real parser implemented for any
%   instrument yet.
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

p = inputParser;
addParameter(p, 'newest_min_redo_s', 0);
addParameter(p, 'continue_on_error', false);
addParameter(p, 'fpo7_refit_new_files', 0);
parse(p, varargin{:});
opts = p.Results;
problems = struct('file', {}, 'stage', {}, 'identifier', {}, 'message', {});
processed = {};

if nargin < 3 || isempty(L1_dir)
    L1_dir = fullfile(fileparts(L0_dir), 'L1');
end
if nargin < 4 || isempty(reprocess_all)
    reprocess_all = false;
end
if ~exist(L1_dir, 'dir')
    mkdir(L1_dir);
end

% Deployment-constant electronics/ADC transfer functions
% (metadata.AFE.(ch).electronics_filter) - needs only metadata.PROCESS/
% .AFE, no L0/L1 data, so resolved unconditionally here rather than gated
% on CTD presence like fpo7_calibration below - plus the last FP07 fit, if
% there is one. See MODsetup_add_derived_metadata.m (it handles a prompted
% value being saved to the yml itself).
metadata = MODsetup_add_derived_metadata(metadata);
MODsetup_save_metadata(metadata, metadata.paths.meta, ...
    'define_filters', mfilename('fullpath'));

list_L0file = dir(fullfile(L0_dir, '*.mat'));
nfiles = length(list_L0file);

if nfiles == 0
    disp(['MODprocess_all_L0_to_L1: No .mat files found in ' MODutil_short_path(L0_dir)])
    L1_files = {};
    return
end

% Vehicles whose CTD data arrives via an independent file rather than
% embedded $SB49/$SB41 blocks in the .modraw/L0 stream.
external_ctd_vehicles = {'deepsolo', 'wirewalker'};
external_ctd_full = [];
if ismember(lower(metadata.vehicle_name), external_ctd_vehicles)
    if exist(metadata.paths.ctd, 'dir')
        external_ctd_full = MODprocess_read_external_ctd(metadata);
    else
        fprintf(1, ['MODprocess_all_L0_to_L1: vehicle "%s" expects an independent CTD file, ' ...
            'but %s does not exist yet - proceeding without CTD.\n'], ...
            metadata.vehicle_name, MODutil_short_path(metadata.paths.ctd));
    end
end

% The newest L0 file (by modification time) is always reprocessed, in
% case the raw file behind it was still being written when L0 last ran.
[~, i_newest] = max([list_L0file.datenum]);

for i = 1:nfiles

    filename = list_L0file(i).name;
    L1_file = fullfile(L1_dir, filename);

    already_converted = false;
    if exist(L1_file, 'file')
        L1_info = dir(L1_file);
        already_converted = L1_info.datenum >= list_L0file(i).datenum;
    end

    if ~MODutil_needs_redo(already_converted, i == i_newest, L1_file, opts.newest_min_redo_s, reprocess_all)
        continue
    end

    fprintf(1, '%s | L0/%s --> L1/%s | ', datestr(now, 'YYYY.mm.dd HH:MM:SS'), filename, filename);

    try
        L0_data = load(fullfile(list_L0file(i).folder, filename));
        ctd_chunk = slice_external_ctd(external_ctd_full, L0_data);
        data = MODprocess_single_L0_to_L1(L0_data, metadata, ctd_chunk);
        data.provenance = MODutil_provenance(fullfile(list_L0file(i).folder, filename), metadata);

        MODutil_save_atomic(L1_file, data)
        processed{end+1} = filename; %#ok<AGROW>
        fprintf(1, '\n');
    catch ME
        if ~opts.continue_on_error
            rethrow(ME)
        end
        fprintf(1, 'FAILED: %s\n', ME.message);
        problems(end+1) = struct('file', fullfile(L0_dir, filename), 'stage', 'L0_to_L1', ...
            'identifier', ME.identifier, 'message', ME.message); %#ok<AGROW>
    end

end %end loop through files

L1_listing = dir(fullfile(L1_dir, '*.mat'));
L1_files = fullfile({L1_listing.folder}, {L1_listing.name})';

% Deployment-level file time index: per-L1-file epsi.dnum start/end, so
% modProcess_extract_profile.m (PLAN.md Section 6.3) can find which L1
% file(s) overlap a profile's time range without loading every file's full
% contents. Unconditional (unlike the pressure-record/twist blocks below) -
% it only needs epsi.dnum, not CTD or vnav, so every deployment with any L1
% files gets one, even before profile-cutting is wired up to consume it.
% Per-L1-file summaries, reloading only new or changed L1 files - the
% deployment-wide files below are rebuilt from these, not from every L1 file
L1_cache = MODprocess_L1_update_file_cache(L1_dir, metadata.paths.L1_meta);
TimeIndex = MODprocess_L1_make_time_index(L1_cache);
save(fullfile(metadata.paths.L1_meta, 'time_index.mat'), '-struct', 'TimeIndex');

% Deployment-level twist count: re-chain every L1 file's per-file twist
% field (added inside MODprocess_single_L0_to_L1) into meta/twist_time_series.mat.
% The data decide: any L1 file with twist (its raw file had VNAV) makes it.
MODprocess_L1_accumulate_twist_timeseries(L1_cache, metadata.paths.L1_meta);

% Deployment-level pressure record + profiling-direction classification:
% only when some L1 file has CTD pressure (the data decide - onboard SBE
% counts calibrated at L1, or an external-CTD vehicle's file sliced in).
has_ctd = any(arrayfun(@(c) ~isempty(c.ctd_P), L1_cache));
has_onboard_ctd = has_ctd && isempty(external_ctd_full);
if has_ctd
    PressureTimeseries = MODprocess_L1_make_pressure_timeseries(L1_cache);
    if ~isempty(PressureTimeseries.dnum)
        while true
            try
                PressureTimeseries = mod_L1_detect_profiling_direction(PressureTimeseries, metadata);
                break
            catch ME
                % A prompted value was saved to the yml - reread it and retry
                if ~strcmp(ME.identifier, 'MODsetup_validate_metadata:yamlUpdated')
                    rethrow(ME)
                end
                metadata = MODsetup_add_derived_metadata(MODsetup_read_yaml(metadata.paths.setup_yml));
            end
        end
        save(fullfile(metadata.paths.L1_meta, 'pressure_time_series.mat'), '-struct', 'PressureTimeseries');

        % FP07 in-situ volts->degC calibration: needs real CTD temperature,
        % which only the onboard CTD provides - an external-CTD vehicle
        % like DeepSolo (P-only fallrise data) never qualifies here even
        % though it passed the has_ctd check above.
        % Gated on PressureTimeseries.dnum being non-empty too since the
        % fit needs is_down, just computed above.
        if has_onboard_ctd && fpo7_refit_due(metadata.paths.L1_meta, numel(L1_cache), opts.fpo7_refit_new_files)
            % Refit from scratch: the fit loaded by MODsetup_add_derived_metadata
            % is set aside, so a channel that can't be refit isn't saved again
            % as if it were new (save_fpo7_calibration keeps it, with its old time)
            [metadata, previous_fit] = set_aside_fpo7_fits(metadata);
            metadata = MODprocess_L1_apply_fpo7_calibration(L1_dir, metadata, PressureTimeseries);
            metadata = save_fpo7_calibration(metadata, previous_fit, numel(L1_cache));
            MODsetup_save_metadata(metadata, metadata.paths.meta, ...
                'fpo7_calibration', mfilename('fullpath'));
        end
    end
end

end %end function

%% Is an FP07 refit due? Always when every_n is 0 or there's no saved fit;
% otherwise once n_L1_files has grown by every_n since the saved fit.
function tf = fpo7_refit_due(meta_dir, n_L1_files, every_n)
tf = true;
cal_file = fullfile(meta_dir, 'fpo7_calibration.mat');
if every_n <= 0 || ~isfile(cal_file)
    return
end
saved = load(cal_file);
if isfield(saved, 'n_L1_files')
    tf = n_L1_files >= saved.n_L1_files + every_n;
end
end

%% Remove every fpo7 channel's volts_to_C before a refit; return what was
% removed (volts_to_C.(ch)) so save_fpo7_calibration can keep it for a
% channel that can't be refit
function [metadata, previous] = set_aside_fpo7_fits(metadata)
previous = struct();
for iC = 1:numel(metadata.PROCESS.channels)
    ch = metadata.PROCESS.channels{iC};
    if strcmpi(metadata.AFE.(ch).type, 'fpo7') && isfield(metadata.AFE.(ch), 'volts_to_C')
        previous.(ch) = metadata.AFE.(ch).volts_to_C;
        metadata.AFE.(ch) = rmfield(metadata.AFE.(ch), 'volts_to_C');
    end
end
end

%% Save every fpo7 channel's volts_to_C fit, with its probe SN, to
% meta/fpo7_calibration.mat - where MODsetup_add_derived_metadata.m loads
% it from in any later session or after a yml reread. Fields:
% volts_to_C.(ch) = [slope, intercept], sn.(ch) = probe SN as char ('' if
% none), fitted.(ch) = UTC time of that channel's fit, n_L1_files = how many
% L1 files there were (for 'fpo7_refit_new_files'). A channel that
% couldn't be refit this time keeps its previous fit and fit time (with a
% warning). Written to a temp file and moved into place, so a reader never
% sees half a file.
function metadata = save_fpo7_calibration(metadata, previous, n_L1_files)
cal_file = fullfile(metadata.paths.L1_meta, 'fpo7_calibration.mat');
old_fitted = struct();
if isfile(cal_file)
    old = load(cal_file);
    if isfield(old, 'fitted') && isstruct(old.fitted)
        old_fitted = old.fitted;
    end
end
now_utc = char(datetime('now', 'TimeZone', 'UTC', 'Format', 'yyyy-MM-dd HH:mm:ss'));
volts_to_C = struct();
sn = struct();
fitted = struct();
for iC = 1:numel(metadata.PROCESS.channels)
    ch = metadata.PROCESS.channels{iC};
    a = metadata.AFE.(ch);
    if ~strcmpi(a.type, 'fpo7')
        continue
    end
    if isfield(a, 'volts_to_C')
        fitted.(ch) = now_utc;
    elseif isfield(previous, ch)
        metadata.AFE.(ch).volts_to_C = previous.(ch);
        fitted.(ch) = '';
        if isfield(old_fitted, ch)
            fitted.(ch) = old_fitted.(ch);
        end
        warning('MODprocess_all_L0_to_L1:fpo7NotRefit', ...
            '%s: FP07 fit could not be redone this time - keeping the previous fit (from %s).', ch, fitted.(ch));
    else
        continue
    end
    volts_to_C.(ch) = metadata.AFE.(ch).volts_to_C;
    sn.(ch) = '';
    if isfield(a, 'SN')
        sn.(ch) = char(string(a.SN));
    end
end
if ~isempty(fieldnames(volts_to_C))
    tmp_file = [tempname(metadata.paths.L1_meta) '.mat'];
    save(tmp_file, 'volts_to_C', 'sn', 'fitted', 'n_L1_files');
    movefile(tmp_file, cal_file, 'f');
end
end

%% Slice a deployment-length external CTD struct down to one L0 file's
% time range, by the min/max dnum found in that file's epsi/vnav data
% (whichever are present - both are always in-file timebases for the
% vehicles that use external CTD). Returns [] if there's no full_ctd, no
% usable time bounds, or no overlap.
function ctd_chunk = slice_external_ctd(full_ctd, L0_data)
ctd_chunk = [];
if isempty(full_ctd)
    return
end

t_bounds = [];
for fn = {'epsi', 'vnav'}
    field = fn{1};
    if isfield(L0_data, field) && ~isempty(L0_data.(field)) && isfield(L0_data.(field), 'dnum')
        t_bounds = [t_bounds; L0_data.(field).dnum(:)]; %#ok<AGROW>
    end
end
if isempty(t_bounds)
    return
end

in_range = full_ctd.dnum >= min(t_bounds) & full_ctd.dnum <= max(t_bounds);
if ~any(in_range)
    return
end

fn = fieldnames(full_ctd);
for iF = 1:numel(fn)
    ctd_chunk.(fn{iF}) = full_ctd.(fn{iF})(in_range);
end
end
