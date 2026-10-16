function cache = MODprocess_L1_update_file_cache(L1_dir, meta_dir)
% MODprocess_L1_update_file_cache        Part of MOD_fish_processing
%
% cache = MODprocess_L1_update_file_cache(L1_dir, meta_dir)
%
% DESCRIPTION
%   Keeps meta/l1_file_cache.mat: the few things the deployment-wide files
%   need from each L1 file, so they can be rebuilt without reloading every
%   L1 file on every pass (realtime processing calls this every loop, and
%   the deployment keeps growing). Only L1 files that are new, or whose
%   modification time or size changed, are loaded; entries for L1 files
%   that no longer exist are dropped. L1 files themselves are only read.
%   An L1 file that can't be read gets an empty entry (with a warning) and
%   is tried again on the next call.
%
%   Per L1 file it keeps:
%     - the time span (epsi.dnum, else ctd.dnum) - for time_index.mat
%     - ctd.dnum and ctd.P - for pressure_time_series.mat
%     - the twist field and the first vnav.dnum - for twist_time_series.mat
%
% INPUTS
%   L1_dir   - folder of L1 .mat files
%   meta_dir - where the cache is saved: the meta/ of the processing run
%              that made the L1 (metadata.paths.L1_meta)
%
% OUTPUTS
%   cache - struct array, one element per L1 file, sorted by file name:
%     .name, .mtime (datenum), .bytes - which version of the file this is
%     .dnum_start, .dnum_end - epsi time span (ctd if no epsi); NaN if neither
%     .ctd_dnum, .ctd_P      - column vectors; [] if no ctd.P
%     .twist                 - the L1 file's twist struct; [] if no vnav/twist
%     .twist_sort_key        - min(vnav.dnum); NaN if no twist
%
% CALLED BY
%   MODprocess_all_L0_to_L1.m
%
% CALLS
%   (none)
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

cache_file = fullfile(meta_dir, 'l1_file_cache.mat');
empty_entry = struct('name', '', 'mtime', NaN, 'bytes', NaN, 'dnum_start', NaN, 'dnum_end', NaN, ...
    'ctd_dnum', [], 'ctd_P', [], 'twist', [], 'twist_sort_key', NaN);
cache = repmat(empty_entry, 0, 1);
if isfile(cache_file)
    saved = load(cache_file, 'cache');
    if isfield(saved, 'cache') && isstruct(saved.cache) && isequal(sort(fieldnames(saved.cache)), sort(fieldnames(empty_entry)))
        cache = saved.cache(:);
    end
end

files = dir(fullfile(L1_dir, '*.mat'));
files = files(~startsWith({files.name}, '.'));
cached_names = {cache.name};
new_cache = repmat(empty_entry, numel(files), 1);
changed = false(numel(files), 1);
for i = 1:numel(files)
    k = find(strcmp(cached_names, files(i).name), 1);
    if ~isempty(k) && cache(k).mtime == files(i).datenum && cache(k).bytes == files(i).bytes
        new_cache(i) = cache(k);
        continue
    end
    try
        new_cache(i) = summarize(fullfile(L1_dir, files(i).name), empty_entry);
        new_cache(i).mtime = files(i).datenum;
    catch ME
        % unreadable (e.g. half-written) - an empty entry, tried again next call
        warning('MODprocess_L1_update_file_cache:unreadable', 'Could not read %s (%s) - left out for now.', ...
            files(i).name, ME.message);
        new_cache(i) = empty_entry;
    end
    new_cache(i).name = files(i).name;
    new_cache(i).bytes = files(i).bytes;
    changed(i) = true;
end
cache = new_cache;

if any(changed) || numel(cache) ~= numel(cached_names) || ~isfile(cache_file)
    tmp = [tempname(meta_dir) '.mat'];
    save(tmp, 'cache');
    movefile(tmp, cache_file, 'f');
end
end %end function

%% What the deployment-wide files need from one L1 file
function e = summarize(fpath, e)
warnState = warning('off', 'MATLAB:load:variableNotFound');
S = load(fpath, 'epsi', 'ctd', 'vnav', 'twist');
warning(warnState);

if isfield(S, 'epsi') && ~isempty(S.epsi) && isfield(S.epsi, 'dnum') && ~isempty(S.epsi.dnum)
    e.dnum_start = min(S.epsi.dnum);
    e.dnum_end = max(S.epsi.dnum);
elseif isfield(S, 'ctd') && ~isempty(S.ctd) && isfield(S.ctd, 'dnum') && ~isempty(S.ctd.dnum)
    e.dnum_start = min(S.ctd.dnum);
    e.dnum_end = max(S.ctd.dnum);
end

if isfield(S, 'ctd') && ~isempty(S.ctd) && isfield(S.ctd, 'P') && ~isempty(S.ctd.P) ...
        && isfield(S.ctd, 'dnum') && ~isempty(S.ctd.dnum)
    e.ctd_dnum = S.ctd.dnum(:);
    e.ctd_P = S.ctd.P(:);
end

if isfield(S, 'vnav') && ~isempty(S.vnav) && isfield(S.vnav, 'dnum') && ~isempty(S.vnav.dnum) ...
        && isfield(S, 'twist') && ~isempty(S.twist)
    e.twist = S.twist;
    e.twist_sort_key = min(S.vnav.dnum);
end
end
