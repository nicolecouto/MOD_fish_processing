function n_renamed = MODsetup_pad_raw_filenames(raw_dir, raw_file_suffix, L0_dir, force)
% MODsetup_pad_raw_filenames        Part of MOD_fish_processing
%
% n_renamed = MODsetup_pad_raw_filenames(raw_dir, raw_file_suffix, L0_dir, force)
%
% DESCRIPTION
%   Renames raw files whose names end in an unpadded number (modsom_0,
%   modsom_1, ..., modsom_192) to zero-padded names (modsom_000,
%   modsom_001, ...) so that alphabetical file listings sort in
%   chronological order. Files are renamed in place with movefile - the
%   contents are never read or written, only the directory entry changes -
%   and every rename is verified (same byte count) and recorded in
%   meta/FilenamePadLog.csv next to raw_dir.
%
%   If a sibling L0 folder already holds converted .mat files under the
%   old names, those are renamed to match and the raw_file_info.filename
%   field inside each is updated, so MODprocess_new_modraw_to_L0 still
%   recognizes them as already converted.
%
%   Does nothing (and says so) when names are date-based or already
%   padded, so it is safe to call on every processing run.
%
% INPUTS
%   raw_dir         - full path to a folder of raw data files
%   raw_file_suffix - (optional) e.g. '.modraw'. Default: auto-detected
%                      by MODsetup_detect_raw_suffix.m.
%   L0_dir          - (optional) folder of converted .mat files to rename
%                      in step with the raw files. Default: a sibling 'L0'
%                      folder next to raw_dir, if it exists.
%   force           - (optional) true to skip the confirmation prompt.
%                      Default: false.
%
% OUTPUTS
%   n_renamed - number of raw files renamed (0 if nothing needed doing,
%               the user declined, or MATLAB is running with -batch and
%               force was not set)
%
% CALLED BY
%   MODprocess_new_modraw_to_L0.m
%
% CALLS
%   MODsetup_detect_raw_suffix.m
%
% NOTES
%   Pad width is max(3, widest number already present), per numeric
%   prefix. If a deployment could grow past 999 files, run this once up
%   front so the width is settled before processing starts.
%
%   In non-interactive MATLAB (-batch) the confirmation prompt cannot be
%   answered, so without force=true the function warns and does nothing
%   rather than renaming files unprompted.
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

if nargin < 2 || isempty(raw_file_suffix)
    raw_file_suffix = MODsetup_detect_raw_suffix(raw_dir);
end
if nargin < 3 || isempty(L0_dir)
    L0_dir = fullfile(fileparts(raw_dir), 'L0');
end
if nargin < 4 || isempty(force)
    force = false;
end

n_renamed = 0;

listing = dir(fullfile(raw_dir, ['*', raw_file_suffix]));
listing = listing(~startsWith({listing.name}, '.'));
if isempty(listing)
    fprintf('MODsetup_pad_raw_filenames: no %s files in %s\n', raw_file_suffix, raw_dir);
    return
end

% Split each base name into prefix + trailing number (empty if no number)
nf = numel(listing);
old_base = cell(nf,1);
prefix   = cell(nf,1);
idx      = nan(nf,1);
width    = nan(nf,1);
for k = 1:nf
    old_base{k} = listing(k).name(1:end-numel(raw_file_suffix));
    t = regexp(old_base{k}, '^(.*?)(\d+)$', 'tokens', 'once');
    if ~isempty(t)
        prefix{k} = t{1};
        idx(k)    = str2double(t{2});
        width(k)  = numel(t{2});
    end
end

isnum = ~isnan(idx);
if ~any(isnum)
    fprintf('MODsetup_pad_raw_filenames: no trailing-number filenames in %s - nothing to pad\n', raw_dir);
    return
end

% Padded name per file, width chosen per prefix
new_base = old_base;
for p = unique(prefix(isnum))'
    m = isnum & strcmp(prefix, p{1});
    pad = max(3, max(width(m)));
    for k = find(m)'
        new_base{k} = sprintf('%s%0*d', p{1}, pad, idx(k));
    end
end

% Two old names must never map to one new name (e.g. modsom_1 + modsom_001)
[uniq_new, ~, ic] = unique(new_base);
counts = accumarray(ic, 1);
if any(counts > 1)
    dupes = strjoin(uniq_new(counts > 1), ', ');
    error('MODsetup_pad_raw_filenames:duplicateTarget', ...
        ['Cannot pad filenames in %s - multiple files would collapse onto ' ...
         'the same padded name (%s). Resolve the duplicates by hand first.'], ...
        raw_dir, dupes);
end

changed = find(~strcmp(old_base, new_base));
if isempty(changed)
    fprintf('MODsetup_pad_raw_filenames: filenames in %s already padded\n', raw_dir);
    return
end

% A padded target must not already exist as some file we are not renaming
for k = changed'
    target = fullfile(raw_dir, [new_base{k}, raw_file_suffix]);
    if isfile(target) && ~ismember(new_base{k}, old_base)
        error('MODsetup_pad_raw_filenames:targetExists', ...
            '%s already exists - will not overwrite it with a renamed %s%s', ...
            target, old_base{k}, raw_file_suffix);
    end
end

% Confirm before touching anything
fprintf('MODsetup_pad_raw_filenames: %d of %d %s files in %s need zero-padding, e.g.\n', ...
    numel(changed), nf, raw_file_suffix, raw_dir);
nshow = min(3, numel(changed));
for k = changed(1:nshow)'
    fprintf('    %s%s -> %s%s\n', old_base{k}, raw_file_suffix, new_base{k}, raw_file_suffix);
end
if numel(changed) > nshow
    fprintf('    ... and %d more\n', numel(changed) - nshow);
end

if ~force
    if batchStartupOptionUsed
        warning('MODsetup_pad_raw_filenames:batchSkip', ...
            ['MATLAB is running non-interactively, so no confirmation prompt is possible. ' ...
             'Files were NOT renamed. Call MODsetup_pad_raw_filenames(raw_dir, [], [], true) to rename.']);
        return
    end
    resp = input('Rename these files in place? (contents untouched, log written to meta/FilenamePadLog.csv) y/n: ', 's');
    if ~strcmpi(strtrim(resp), 'y')
        fprintf('MODsetup_pad_raw_filenames: no files renamed\n');
        return
    end
end

% Open the log (append mode; header only when the file is new)
meta_dir = fullfile(fileparts(raw_dir), 'meta');
if ~exist(meta_dir, 'dir')
    mkdir(meta_dir);
end
log_path = fullfile(meta_dir, 'FilenamePadLog.csv');
new_log = ~isfile(log_path);
fid = fopen(log_path, 'a');
if fid == -1
    error('MODsetup_pad_raw_filenames:logOpenFailed', 'Cannot open %s for writing', log_path);
end
if new_log
    fprintf(fid, '# MODsetup_pad_raw_filenames rename log - files renamed in place, contents untouched\n');
    fprintf(fid, 'datetime_utc,folder,old_name,new_name\n');
end
tstamp = char(datetime('now', 'TimeZone', 'UTC', 'Format', 'yyyy-MM-dd''T''HH:mm:ss''Z'''));

% Rename raw files, verifying byte count after each move
for k = changed'
    old_path = fullfile(raw_dir, [old_base{k}, raw_file_suffix]);
    new_path = fullfile(raw_dir, [new_base{k}, raw_file_suffix]);
    movefile(old_path, new_path);
    d = dir(new_path);
    if isempty(d) || d.bytes ~= listing(k).bytes
        fclose(fid);
        error('MODsetup_pad_raw_filenames:verifyFailed', ...
            'Byte count changed renaming %s -> %s (expected %d). Check meta/FilenamePadLog.csv.', ...
            old_path, new_path, listing(k).bytes);
    end
    fprintf(fid, '%s,raw,%s%s,%s%s\n', tstamp, old_base{k}, raw_file_suffix, new_base{k}, raw_file_suffix);
    n_renamed = n_renamed + 1;
end

% Rename any matching L0 .mat files and update raw_file_info.filename so
% the already-converted check in MODprocess_new_modraw_to_L0 still matches
n_L0 = 0;
if isfolder(L0_dir)
    for k = changed'
        old_mat = fullfile(L0_dir, [old_base{k}, '.mat']);
        new_mat = fullfile(L0_dir, [new_base{k}, '.mat']);
        if ~isfile(old_mat)
            continue
        end
        movefile(old_mat, new_mat);
        S = load(new_mat, 'raw_file_info');
        if isfield(S, 'raw_file_info')
            raw_file_info = S.raw_file_info;
            raw_file_info.filename = new_base{k};
            save(new_mat, 'raw_file_info', '-append');
        end
        fprintf(fid, '%s,L0,%s.mat,%s.mat\n', tstamp, old_base{k}, new_base{k});
        n_L0 = n_L0 + 1;
    end
end

fclose(fid);
fprintf('MODsetup_pad_raw_filenames: renamed %d raw files', n_renamed);
if n_L0 > 0
    fprintf(' and %d L0 .mat files', n_L0);
end
fprintf(' - log: %s\n', log_path);

end
