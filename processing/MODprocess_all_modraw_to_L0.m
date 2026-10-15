function [L0_files, problems, processed] = MODprocess_all_modraw_to_L0(raw_dir, L0_dir, raw_file_suffix, metadata, varargin)
% MODprocess_all_modraw_to_L0        Part of MOD_fish_processing
%
% L0_files = MODprocess_all_modraw_to_L0(raw_dir, L0_dir, raw_file_suffix, metadata)
% [L0_files, problems, processed] = MODprocess_all_modraw_to_L0(..., 'newest_min_redo_s', s, 'continue_on_error', tf)
%
% DESCRIPTION
%   Converts every raw file in raw_dir to a .mat file in L0_dir, using
%   MODprocess_single_modraw_to_L0. No calibrations, and no metadata
%   needed - each .mat file contains the fields from
%   MODprocess_single_modraw_to_L0 (raw, except EFE data, which is in
%   volts/g using the standard EFE config) plus a raw_file_info field
%   recording which raw file (name, byte size) created it.
%
%   Skips files that have already been converted (matched by raw file
%   size against raw_file_info.bytes), except the most recently modified
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
%                      channel names/config only. Default: [] (standard
%                      EFE, MODsetup_default_efe.m). Files already
%                      converted are not redone just because metadata
%                      changed - L1 re-applies setup.yml anyway.
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
%   MODsetup_detect_raw_suffix.m
%   MODsetup_pad_raw_filenames.m
%   MODutil_needs_redo.m, MODutil_save_atomic.m
%   MODutil_short_path.m (console messages only)
%
% NOTES
%   This and MODprocess_single_modraw_to_L0.m are meant to run standalone
%   with no dependency on Meta_Data, YAML setup, or the old mod_class -
%   metadata is optional.
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
            S = load(fullfile(myL0file.folder, myL0file.name), 'raw_file_info');
            already_converted = isfield(S, 'raw_file_info') && list_rawfile(i).bytes <= S.raw_file_info.bytes;
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

        L0_data.raw_file_info.bytes    = list_rawfile(i).bytes;
        L0_data.raw_file_info.filename = base;

        % Save data in .mat file
        MODutil_save_atomic(fullfile(L0_dir, [base '.mat']), L0_data)
        processed{end+1} = filename; %#ok<AGROW>
    catch ME
        if ~opts.continue_on_error
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
