function TimeIndex = MODprocess_L1_make_time_index(L1_dir)
% MODprocess_L1_make_time_index        Part of MOD_fish_processing
%
% TimeIndex = MODprocess_L1_make_time_index(L1_dir)
%
% DESCRIPTION
%   Builds a lightweight per-L1-file time index - filename plus start/end
%   dnum - so modProcess_extract_profile.m can find which L1 file(s)
%   overlap a profile's time range without loading every file's full
%   epsi/ctd contents. Loads only data.epsi/data.ctd's dnum fields per
%   file (for their min/max), not the whole file - same "load only the
%   field you need" pattern as MODprocess_L1_make_pressure_timeseries.m's
%   ctd-only load.
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
%   Pure - reads files, does no file writing itself. The caller
%   (MODprocess_all_L0_to_L1.m) saves the result to meta/time_index.mat.
%
% INPUTS
%   L1_dir - directory containing L1 .mat files, each with top-level
%            'epsi'/'ctd' variables (as saved by
%            MODprocess_all_L0_to_L1.m's save(L1_file, '-struct', 'data')).
%            Files with no usable epsi.dnum or ctd.dnum are skipped, not
%            an error.
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
%   (none)
%
% NOTES
%   Deliberately does not carry everything the old MOD_fish_lib
%   TimeIndex.mat did (timeStart/timeEnd in seconds, per-file Meta_Data) -
%   modProcess_extract_profile.m only ever needs a file-overlap lookup by
%   dnum, so this stays minimal; extend it the moment a second consumer
%   needs more, per this repo's incremental-scope convention.
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

files = dir(fullfile(L1_dir, '*.mat'));
nFiles = numel(files);

filename_all  = cell(nFiles, 1);
dnum_start_all = nan(nFiles, 1);
dnum_end_all   = nan(nFiles, 1);
validFile      = false(nFiles, 1);

for i = 1:nFiles
    fpath = fullfile(L1_dir, files(i).name);
    warnState = warning('off', 'MATLAB:load:variableNotFound');
    S = load(fpath, 'epsi', 'ctd');
    warning(warnState);

    if isfield(S, 'epsi') && ~isempty(S.epsi) && isfield(S.epsi, 'dnum') && ~isempty(S.epsi.dnum)
        dnum = S.epsi.dnum;
    elseif isfield(S, 'ctd') && ~isempty(S.ctd) && isfield(S.ctd, 'dnum') && ~isempty(S.ctd.dnum)
        dnum = S.ctd.dnum;
    else
        continue
    end

    filename_all{i}   = files(i).name;
    dnum_start_all(i) = min(dnum);
    dnum_end_all(i)   = max(dnum);
    validFile(i)      = true;
end

filename_all   = filename_all(validFile);
dnum_start_all = dnum_start_all(validFile);
dnum_end_all   = dnum_end_all(validFile);

if isempty(filename_all)
    TimeIndex = struct('filename', {{}}, 'dnum_start', [], 'dnum_end', []);
    return
end

[~, sortIdx] = sort(dnum_start_all);
TimeIndex.filename   = filename_all(sortIdx);
TimeIndex.dnum_start = dnum_start_all(sortIdx);
TimeIndex.dnum_end   = dnum_end_all(sortIdx);

end %end function
