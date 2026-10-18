function [L0_files, problems, processed] = MODprocess_all_modraw_to_L0(raw_dir, L0_dir, raw_file_suffix, metadata, varargin)
% MODprocess_all_modraw_to_L0        Part of MOD_fish_processing
%
% L0_files = MODprocess_all_modraw_to_L0(raw_dir, L0_dir, raw_file_suffix, metadata)
% [L0_files, problems, processed] = MODprocess_all_modraw_to_L0(..., 'newest_min_redo_s', s, 'continue_on_error', tf)
%
% DESCRIPTION
%   Converts every raw file in raw_dir to a .mat file in L0_dir, using
%   MODprocess_single_modraw_to_L0. No calibrations applied - each .mat
%   file contains the fields from MODprocess_single_modraw_to_L0 (raw,
%   except EFE data, which is in volts/g using the standard EFE config)
%   plus a raw_file_info field recording which raw file (name, byte size)
%   created it.
%
%   SBE calibration (ctd_cal, applied at L1): the file's own $DCAL, which
%   the SBE itself reports. A file with SBE49 counts but no $DCAL gets
%   calibrations_root/SBE/<SN>.CAL instead (SN: the one already recorded
%   for this survey, else the header's CTD.SerialNum, else the yml's
%   instrument_manifest.ctd.sn). ctd_cal.source says which; a .CAL file
%   takes TOFFSET/CSLOPE/POFFSET from the survey's $DCAL (a .CAL can't hold
%   them). A $DCAL that can't be read counts as none. The first
%   calibration is recorded in <L0_dir>/../meta/ctd_calibration.mat (for a
%   survey, <survey>/meta); a later file with a different one (another SN,
%   calibration date or coefficient - beyond 1e-6 relative, the last
%   printed digit - e.g. an out-of-date .CAL then a newer $DCAL) stops L0
%   for this survey with
%   MODprocess_all_modraw_to_L0:ctdCalibrationChanged, even with
%   'continue_on_error' - update the .CAL file, then reprocess from raw.
%   A header CTD.SerialNum that differs from the $DCAL one is a warning
%   (MODprocess_all_modraw_to_L0:ctdSerialNumber); the $DCAL one is used.
%
%   Skips files that have already been converted (matched by raw file
%   size against raw_file_info.bytes; an L0 file made before ctd_cal
%   existed is redone), except the most recently modified
%   file in the folder, which is always reconverted in case it's still
%   being written to (e.g. during real-time acquisition) - unless
%   'newest_min_redo_s' is set (see INPUTS).
%
%   If raw filenames end in unpadded numbers (modsom_0, ..., modsom_192),
%   offers to rename them in place with zero-padded numbers (modsom_000,
%   ...) via MODsetup_pad_raw_filenames.m, so raw and L0 listings sort
%   chronologically. Contents are untouched; renames are logged to
%   meta/filename_pad_log.csv.
%
% INPUTS
%   raw_dir         - full path to a folder of raw data files
%   L0_dir          - (optional) full path to save .mat files to. Default:
%                      a sibling 'L0' folder next to raw_dir
%                      (fullfile(fileparts(raw_dir),'L0')), created if missing.
%   raw_file_suffix - (optional) e.g. '.modraw'. Default: auto-detected
%                      from raw_dir by MODsetup_detect_raw_suffix.m.
%   metadata        - (optional) metadata struct from MODsetup_read_yaml.m,
%                      passed to MODprocess_single_modraw_to_L0 for EFE
%                      channel names/config, plus .paths.calibrations_root
%                      and .CTD.SN for a raw file without $DCAL. Default:
%                      [] (standard EFE, MODsetup_default_efe.m; a file
%                      without $DCAL then can't get a calibration and
%                      fails). Files already converted are not redone just
%                      because metadata changed - L1 re-applies setup.yml
%                      anyway.
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
%
% OUTPUTS
%   L0_files  - cell array of full paths to all .mat files in L0_dir
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
%   MODprocess_single_modraw_to_L0.m
%   mod_L0_ctd_calibration.m (.CAL file)
%   MODsetup_detect_raw_suffix.m
%   MODsetup_pad_raw_filenames.m
%   MODutil_needs_redo.m, MODutil_save_atomic.m, MODutil_provenance.m
%   MODutil_short_path.m (console messages only)
%
% NOTES
%   This and MODprocess_single_modraw_to_L0.m are meant to run standalone
%   with no dependency on Meta_Data, YAML setup, or the old mod_class -
%   metadata is optional (needed only for a raw file without $DCAL).
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

p = inputParser;
addParameter(p, 'newest_min_redo_s', 0);
addParameter(p, 'continue_on_error', false);
parse(p, varargin{:});
opts = p.Results;
problems = struct('file', {}, 'stage', {}, 'identifier', {}, 'message', {});
processed = {};

if nargin < 2 || isempty(L0_dir)
    L0_dir = fullfile(fileparts(raw_dir), 'L0');
end
if nargin < 4
    metadata = [];
end
if nargin < 3 || isempty(raw_file_suffix)
    raw_file_suffix = MODsetup_detect_raw_suffix(raw_dir);
    fprintf('MODprocess_all_modraw_to_L0: auto-detected raw file suffix "%s" in %s\n', raw_file_suffix, MODutil_short_path(raw_dir));
end
if ~exist(L0_dir, 'dir')
    mkdir(L0_dir);
end

% Zero-pad trailing-number filenames (modsom_1 -> modsom_001) so listings
% sort chronologically. No-op when names are date-based or already padded;
% prompts before renaming (and skips, with a warning, under -batch).
MODsetup_pad_raw_filenames(raw_dir, 'raw_file_suffix', raw_file_suffix, 'L0_dir', L0_dir);

% Get list of raw files in the data path
list_rawfile = dir(fullfile(raw_dir, ['*', raw_file_suffix]));
% a symlink whose file is gone is still listed by dir (with the link's own
% size and time) - leave it out, it isn't data
list_rawfile = list_rawfile(arrayfun(@(f) isfile(fullfile(raw_dir, f.name)), list_rawfile));
nfiles = length(list_rawfile);

% Stop if no raw files are found
if nfiles == 0
    disp(['MODprocess_all_modraw_to_L0: No ' raw_file_suffix ' files found in ' MODutil_short_path(raw_dir)])
    L0_files = {};
    return
end

% The newest file by modification time (NOT the last one alphabetically -
% with unpadded numbered names that would be e.g. modsom_99) is always
% reconverted in case it is still being written to.
[~, i_newest] = max([list_rawfile.datenum]);

% the survey's SBE calibration so far (see DESCRIPTION) - kept next to the
% L0 it describes, <L0_dir>/../meta (for a survey, <survey>/meta)
survey_dir = fileparts(regexprep(char(L0_dir), '[\\/]+$', ''));
cal_record_file = fullfile(survey_dir, 'meta', 'ctd_calibration.mat');
cal_record = [];
if isfile(cal_record_file)
    cal_record = load(cal_record_file);
end
sn_warned = false;

% Loop through files and convert to L0 .mat files
for i = 1:nfiles

    filename = list_rawfile(i).name;

    if strcmp(filename(1), '.')
        % Sometimes you end up with hidden files that begin with '.'
        % Don't include those in list_rawfile
        continue
    end

    % Get the base name of the file (without suffix)
    indSuffix = strfind(filename, raw_file_suffix);
    base = filename(1:indSuffix-1);

    % Define the L0 file with the same base name
    myL0file = dir(fullfile(L0_dir, [base '.mat']));

    already_converted = false;
    if ~isempty(myL0file)
        try
            L0_path = fullfile(myL0file.folder, myL0file.name);
            S = load(L0_path, 'raw_file_info');
            already_converted = isfield(S, 'raw_file_info') && list_rawfile(i).bytes <= S.raw_file_info.bytes ...
                && ismember('ctd_cal', who('-file', L0_path)); % made before ctd_cal: redo
        catch
            already_converted = false; % unreadable L0 (e.g. half-written by an older version) - redo it
        end
    end

    % Convert to .mat if:
    %   (1) there is no .mat file to match the current raw file, or
    %   (2) the current raw file is larger than what is saved in raw_file_info, or
    %   (3) this is the most recently modified file in the folder, in case
    %       it's still being written to
    if ~MODutil_needs_redo(already_converted, i == i_newest, fullfile(L0_dir, [base '.mat']), ...
            opts.newest_min_redo_s, false)
        continue
    end

    fprintf(1, '%s | %s --> %s.mat | ', datestr(now, 'YYYY.mm.dd HH:MM:SS'), filename, base);

    try
        L0_data = MODprocess_single_modraw_to_L0(fullfile(raw_dir, filename), metadata);
        [L0_data.ctd_cal, cal_record, sn_warned] = file_ctd_calibration(L0_data, filename, metadata, ...
            cal_record, cal_record_file, survey_dir, sn_warned);

        L0_data.raw_file_info.bytes    = list_rawfile(i).bytes;
        L0_data.raw_file_info.filename = base;
        % the raw file and yml this came from (MODutil_provenance.m); the
        % survey is the folder holding raw/
        L0_data.provenance = MODutil_provenance(fullfile(raw_dir, filename), metadata, ...
            fileparts(regexprep(char(raw_dir), '[\\/]+$', '')));

        % Save data in .mat file
        MODutil_save_atomic(fullfile(L0_dir, [base '.mat']), L0_data)
        processed{end+1} = filename; %#ok<AGROW>
    catch ME
        if ~opts.continue_on_error || strcmp(ME.identifier, 'MODprocess_all_modraw_to_L0:ctdCalibrationChanged')
            rethrow(ME)
        end
        fprintf(1, 'FAILED: %s\n', ME.message);
        problems(end+1) = struct('file', fullfile(raw_dir, filename), 'stage', 'modraw_to_L0', ...
            'identifier', ME.identifier, 'message', ME.message); %#ok<AGROW>
    end

end %end loop through files

L0_listing = dir(fullfile(L0_dir, '*.mat'));
L0_files = fullfile({L0_listing.folder}, {L0_listing.name})';

end %end function

%% This file's SBE calibration: its own $DCAL, else the .CAL file; checked
% against (or, for the first one, saved as) the survey's record
function [cal, record, sn_warned] = file_ctd_calibration(L0_data, filename, metadata, record, record_file, survey_dir, sn_warned)
cal = L0_data.ctd_cal;
has_counts = isstruct(L0_data.ctd) && isfield(L0_data.ctd, 'T_raw');
if isempty(cal) && ~has_counts
    return % no SBE49 counts to convert, and no $DCAL
end
if isempty(cal)
    why = 'no $DCAL';
    if isfield(L0_data, 'ctd_cal_error') && ~isempty(L0_data.ctd_cal_error)
        why = sprintf('an unreadable $DCAL (%s)', L0_data.ctd_cal_error);
    end
    % SN: the survey's CTD as the fish reported it, else the header's, else the yml's
    candidates = {'', 'the survey''s calibration'; L0_data.ctd_header_sn, 'the header''s CTD.SerialNum'; '', 'the yml'};
    if ~isempty(record)
        candidates{1, 1} = record.cal.SN;
    end
    if isstruct(metadata) && isfield(metadata, 'CTD') && isfield(metadata.CTD, 'SN')
        candidates{3, 1} = metadata.CTD.SN;
    end
    k = find(cellfun(@(c) isfinite(str2double(c)), candidates(:, 1)), 1);
    if isempty(k) || ~isstruct(metadata) || ~isfield(metadata, 'paths') ...
            || ~isfield(metadata.paths, 'calibrations_root') || isempty(metadata.paths.calibrations_root)
        error('MODprocess_all_modraw_to_L0:noCtdCalibration', ['%s has SBE49 data but %s, and no ' ...
            'calibrations_root and CTD serial number to find a .CAL file.'], filename, why);
    end
    SN = sprintf('%04d', str2double(candidates{k, 1}));
    cal_file = fullfile(metadata.paths.calibrations_root, 'SBE', [SN '.CAL']);
    if ~isfile(cal_file)
        error('MODprocess_all_modraw_to_L0:calFileNotFound', '%s has SBE49 data but %s, and there is no %s (SN from %s).', ...
            filename, why, cal_file, candidates{k, 2});
    end
    cal = mod_L0_ctd_calibration(fileread(cal_file), ['calibrations folder: ' cal_file]);
    if ~isempty(record) && strcmp(record.cal.SN, cal.SN)
        % a .CAL file can't hold $DCAL's offsets: the survey's are used
        cal.toffset = record.cal.toffset; cal.cslope = record.cal.cslope; cal.poffset = record.cal.poffset;
    end
end
header_sn = L0_data.ctd_header_sn;
if ~sn_warned && strcmp(cal.source, '.modraw $DCAL') && ~isempty(header_sn) ...
        && str2double(header_sn) ~= str2double(cal.SN)
    warning('MODprocess_all_modraw_to_L0:ctdSerialNumber', ['%s: the header says CTD %s, but the SBE ' ...
        'reports %s ($DCAL). Using %s - fix the CTD serial number in Start New Deployment.'], ...
        filename, header_sn, cal.SN, cal.SN);
    sn_warned = true;
end
if isempty(record)
    record = struct('cal', cal, 'file', filename);
    folder = fileparts(record_file);
    if ~isfolder(folder)
        mkdir(folder);
    end
    MODutil_save_atomic(record_file, record)
    return
end
r = record.cal;
what = cal_differences(r, cal);
if ~isempty(what)
    describe = @(f, c) sprintf('  %s: SBE %s from %s, calibrated T %s, C %s, P %s', f, c.SN, c.source, ...
        char(c.TempCal_date, 'dd-MMM-yy'), char(c.CondCal_date, 'dd-MMM-yy'), char(c.PresCal_date, 'dd-MMM-yy'));
    error('MODprocess_all_modraw_to_L0:ctdCalibrationChanged', ['CTD calibration changed within this ' ...
        'survey (%s) - processing paused.\n%s\n%s\nUpdate the .CAL file in calibrations_root/SBE to match the ' ...
        'fish (Start New Deployment: Check CTD calibration), then reprocess from raw: delete %s, %s and %s, ' ...
        'and run MODprocess_deployment(''%s'') again.'], strjoin(what, ', '), describe(record.file, r), ...
        describe(filename, cal), fullfile(survey_dir, 'L0'), fullfile(survey_dir, 'processed'), record_file, survey_dir);
end
end

%% What differs between two SBE calibrations: SN, calibration dates, or a
% coefficient by more than 1e-6 (relative) - $DCAL and .CAL round the last
% printed digit differently, which doesn't count
function what = cal_differences(a, b)
what = {};
if ~strcmp(a.SN, b.SN)
    what{end+1} = 'serial number';
end
for d = {'TempCal_date', 'CondCal_date', 'PresCal_date'}
    if a.(d{1}) ~= b.(d{1})
        what{end+1} = d{1}; %#ok<AGROW>
    end
end
f = setdiff(fieldnames(a), {'SN', 'TempCal_date', 'CondCal_date', 'PresCal_date', 'source', 'text'});
for k = 1:numel(f)
    x = a.(f{k}); y = b.(f{k});
    if abs(x - y) > 1e-6 * max(abs(x), abs(y))
        what{end+1} = f{k}; %#ok<AGROW>
    end
end
end
