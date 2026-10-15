function TimeIndex = MODprocess_L1_make_time_index(cache)
% MODprocess_L1_make_time_index        Part of MOD_fish_processing
%
% TimeIndex = MODprocess_L1_make_time_index(cache)
%
% DESCRIPTION
%   Builds a lightweight per-L1-file time index - filename plus start/end
%   dnum - so modProcess_extract_profile.m can find which L1 file(s)
%   overlap a profile's time range without loading every file's full
%   epsi/ctd contents. Built from the per-file L1 cache
%   (MODprocess_L1_update_file_cache.m), so no L1 file is loaded here.
%
%   epsi.dnum is preferred when present (the higher-rate, uniformly-clocked
%   record - the same one modProcess_extract_profile.m stitches across
%   files), falling back to ctd.dnum for a file/deployment with no epsi
%   record at all (a CTD-only vehicle, metadata.manifest.has_epsi false -
%   see MODsetup_read_yaml.m) - otherwise time_index.mat, and everything
%   built on it, would be silently empty for such a deployment even though
%   its CTD data is exactly what modProcess_extract_profile.m should still
%   be able to find and extract into a profile.
%
%   Pure - no file reading or writing. The caller
%   (MODprocess_all_L0_to_L1.m) saves the result to meta/time_index.mat.
%
% INPUTS
%   cache - from MODprocess_L1_update_file_cache.m (one element per L1
%           file, with .name/.dnum_start/.dnum_end). Files with no usable
%           epsi.dnum or ctd.dnum (NaN dnum_start) are skipped, not an error.
%
% OUTPUTS
%   TimeIndex - struct with fields, sorted by dnum_start:
%     filename   - Nx1 cellstr, filename only (e.g. 'modsom_007.mat') - no
%                  directory. Paths are never persisted (same rule as
%                  metadata.mat) - a caller re-derives the full path by
%                  joining this against metadata.paths.L1.
%     dnum_start - Nx1, min(dnum) for that file (epsi.dnum, or ctd.dnum if
%                  epsi.dnum isn't usable)
%     dnum_end   - Nx1, max(dnum) for that file, same source as dnum_start
%   Empty (all fields 0x1) if no L1 file has usable epsi.dnum or ctd.dnum
%   data.
%
% CALLED BY
%   MODprocess_all_L0_to_L1.m
%
% CALLS
%   (none - the cache comes from MODprocess_L1_update_file_cache.m)
%
% NOTES
%   Deliberately does not carry everything the old MOD_fish_lib
%   TimeIndex.mat did (timeStart/timeEnd in seconds, per-file Meta_Data) -
%   modProcess_extract_profile.m only ever needs a file-overlap lookup by
%   dnum, so this stays minimal; extend it the moment a second consumer
%   needs more, per this repo's incremental-scope convention.
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

valid = ~isnan([cache.dnum_start]);
if ~any(valid)
    TimeIndex = struct('filename', {{}}, 'dnum_start', [], 'dnum_end', []);
    return
end
cache = cache(valid);
[~, sortIdx] = sort([cache.dnum_start]);
cache = cache(sortIdx);
TimeIndex.filename   = {cache.name}';
TimeIndex.dnum_start = [cache.dnum_start]';
TimeIndex.dnum_end   = [cache.dnum_end]';

end %end function
