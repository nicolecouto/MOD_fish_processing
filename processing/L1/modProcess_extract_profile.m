function profile_data = modProcess_extract_profile(profile, TimeIndex, metadata)
% modProcess_extract_profile        Part of MOD_fish_processing
%
% profile_data = modProcess_extract_profile(profile, TimeIndex, metadata)
%
% DESCRIPTION
%   Given one profile's time range, finds every L1 file overlapping
%   [profile.dnum_start, profile.dnum_end] via TimeIndex, loads their
%   epsi/ctd fields, concatenates across the file boundary (sorted by
%   file start time), and crops to the exact time range. This is what
%   makes profile-cut spectra computed on a stitched, continuous raw
%   record rather than per-L1-file, unlike MODprocess_single_L1_to_L2.m's
%   realtime mode - a profile spanning two L1 files gets no coverage gap
%   at the seam, as long as the underlying sampling really was continuous
%   there (see GAP HANDLING below for when it wasn't).
%
%   File-lookup logic (last file starting at/before the profile, first
%   file ending at/after it) is ported in spirit from MOD_fish_lib/
%   EPSILOMETER/epsilib/epsiProcess_crop_timeseries.m. The merge itself is
%   a clean re-implementation, not a port of that file's
%   epsiProcess_merge_mat_files.m (a generic recursive struct-merger with
%   legacy AFE.SN patch hacks and, critically, no gap detection at all -
%   see GAP HANDLING). Scoped to epsi+ctd only (no alt/isap/vnav/gps/ttv -
%   add later if a real consumer needs them, matching this repo's
%   incremental-scope precedent, e.g. temperature/salinity added to
%   MODprocess_single_L1_to_L2.m only once chi_obs needed them).
%
%   epsi and ctd are extracted independently: a contributing L1 file that
%   has ctd but no epsi (a CTD-only deployment, metadata.manifest.has_epsi
%   false - see MODsetup_read_yaml.m; or, on an epsi-equipped deployment,
%   simply a file that happened to log no epsi samples) still contributes
%   its ctd data - CTD/pressure coverage is never dropped just because
%   epsi wasn't recorded. This is what lets
%   MODprocess_single_L1_to_L2_profile.m save every profile's CTD record
%   regardless of instrument_manifest/direction, while only computing
%   epsi spectra when there's real epsi data and the profile's direction
%   is one the deployment trusts for it (metadata.PROFILES.profile_dir).
%
%   GAP HANDLING (explicit, not hand-waved): after concatenating every
%   overlapping file's epsi (sorted, deduplicated by exact-duplicate
%   dnum at a file seam) and cropping to the profile's time range, this
%   function computes dt = diff(epsi.dnum)*86400 across the WHOLE stitched
%   record - not just at file seams, since a real discontinuity can also
%   occur mid-file (PLAN.md Section 9's known block-drop artifact) - and
%   flags dt > metadata.PROCESS.epsi_gap_factor * (1/metadata.PROCESS.Fs_epsi)
%   as a genuine gap. Unlike mod_L1_detect_profiling_direction.m's
%   segment-median-relative threshold (appropriate for sparse, irregular
%   pressure data), the denominator here is the deployment's NOMINAL epsi
%   sample interval (1/Fs_epsi), because epsi is uniformly clocked
%   hardware and a local 2-sample "median" at a seam has no meaning.
%   metadata.PROCESS.epsi_gap_factor is deliberately a separate field from
%   metadata.PROFILES.ctd_gap_factor - different timebase, different
%   consequence (a dropped FFT window vs. a misclassified direction
%   sample) - see MODsetup_metadata_field_registry.m.
%
%   Every epsi sample gets a segment_id (1, 2, 3, ... - incrementing at
%   each detected gap). This is NOT resolved into two separate profiles
%   here: a profile is never split into two output files, and never
%   dropped outright just because one internal gap exists - one profile
%   in, one profile_data out. mod_L2_tile_scans.m is what actually acts on
%   segment_id: it skips only the candidate scan window(s) that would
%   straddle a segment boundary, exactly generalizing the "trailing
%   partial window dropped, not padded" behavior MODprocess_single_L1_to_L2.m
%   already accepts at every file end - now triggered by any real gap
%   location inside a profile, not just its outer file boundaries.
%
% INPUTS
%   profile   - one element of modProcess_detect_profiles.m's output
%               struct array. Uses: .dnum_start, .dnum_end,
%               .profile_number, .direction (passthrough only)
%   TimeIndex - struct from MODprocess_L1_make_time_index.m
%               (meta/time_index.mat). Uses: .filename, .dnum_start, .dnum_end
%   metadata  - metadata struct (from MODsetup_read_yaml.m). Uses:
%               metadata.paths.L1 (directory TimeIndex.filename lives in -
%               TimeIndex itself carries no path, same "paths never
%               persisted" rule as metadata.mat), metadata.PROCESS.Fs_epsi,
%               metadata.PROCESS.epsi_gap_factor. epsi_gap_factor is
%               validated via MODsetup_validate_metadata.m as the first
%               executable line (same point-of-use pattern
%               mod_scan_get_spectra.m uses); Fs_epsi is read directly,
%               unconditionally, matching mod_scan_get_spectra.m's own
%               not-yet-validated Fs_epsi read (PLAN.md Section 2,
%               "Deferred" note).
%
% OUTPUTS
%   profile_data - struct:
%     epsi.*          - every numeric-vector data.epsi.* field,
%                        concatenated across overlapping files and cropped
%                        to [profile.dnum_start, profile.dnum_end]
%     epsi.segment_id - Nx1 integer, one gap-free run ID per epsi sample
%                        (see GAP HANDLING above)
%     ctd.*           - every numeric-vector data.ctd.* field, same
%                        concatenate+crop (no segment_id - see NOTES)
%     filenames       - cell array of contributing L1 filenames, in time
%                        order (provenance; length 1 if the profile fit
%                        inside one L1 file)
%     profile_number, direction, dnum_start, dnum_end - passthrough from
%                        the input `profile` struct
%   epsi is empty (dnum = [], segment_id = []) on its own, independent of
%   ctd, if no overlapping file has usable epsi data in range (a CTD-only
%   deployment, or an epsi-equipped one whose contributing files just
%   didn't log epsi) - not an error; ctd is populated as usual in that
%   case. Symmetrically, ctd can be empty while epsi is not. Both empty
%   only if no overlapping file had usable epsi or ctd data at all -
%   filenames is still populated with whichever files were tried.
%
% CALLED BY
%   MODprocess_single_L1_to_L2_profile.m
%
% CALLS
%   MODsetup_validate_metadata.m
%
% NOTES
%   ctd does NOT get its own segment_id: ctd is only ever used for
%   scan-center interpolation (pressure/w/T/S), never windowed into an
%   FFT directly, so a gap inside ctd just means interp1 linearly bridges
%   it at scan-center resolution - a much lower-stakes approximation than
%   letting an FFT window itself span a gap.
%
%   Exact-duplicate epsi.dnum values at a file seam (e.g. if a raw stream
%   were ever re-recorded overlapping the end of a prior file) are
%   collapsed to their first occurrence via a stable unique() pass, right
%   after concatenation - this is a real-data assumption, not something
%   confirmed against every deployment; worth checking directly the first
%   time this runs against a real multi-file profile (see
%   docs/workflow/profile_detection.md's verification notes).
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

yaml_file = '';
if isfield(metadata, 'paths') && isfield(metadata.paths, 'setup_yml')
    yaml_file = metadata.paths.setup_yml;
end
metadata = MODsetup_validate_metadata(metadata, yaml_file, {'epsi_gap_factor'});

profile_data.profile_number = profile.profile_number;
profile_data.direction = profile.direction;
profile_data.dnum_start = profile.dnum_start;
profile_data.dnum_end = profile.dnum_end;

%% Find overlapping L1 files - last file starting at/before this profile,
% first file ending at/after it (ported in spirit from
% epsiProcess_crop_timeseries.m's TimeIndex lookup).
startFile = find(profile.dnum_start >= TimeIndex.dnum_start, 1, 'last');
endFile = find(profile.dnum_end <= TimeIndex.dnum_end, 1, 'first');
if isempty(startFile)
    startFile = 1;
end
if isempty(endFile)
    endFile = numel(TimeIndex.dnum_end);
end
if isempty(TimeIndex.dnum_start) || endFile < startFile
    profile_data.filenames = {};
    profile_data.epsi = empty_epsi_ctd(true);
    profile_data.ctd = empty_epsi_ctd(false);
    return
end
fileIdx = startFile:endFile;

%% Load epsi+ctd from every candidate file, in time order
nFiles = numel(fileIdx);
epsi_cell = cell(nFiles, 1);
ctd_cell = cell(nFiles, 1);
filenames = cell(nFiles, 1);
validFile = false(nFiles, 1);
for iF = 1:nFiles
    fname = TimeIndex.filename{fileIdx(iF)};
    fpath = fullfile(metadata.paths.L1, fname);
    warnState = warning('off', 'MATLAB:load:variableNotFound');
    S = load(fpath, 'epsi', 'ctd');
    warning(warnState);

    has_epsi = isfield(S, 'epsi') && ~isempty(S.epsi) && isfield(S.epsi, 'dnum') && ~isempty(S.epsi.dnum);
    has_ctd = isfield(S, 'ctd') && ~isempty(S.ctd) && isfield(S.ctd, 'dnum') && ~isempty(S.ctd.dnum);
    if ~has_epsi && ~has_ctd
        continue
    end
    if has_epsi
        epsi_cell{iF} = S.epsi;
    end
    if has_ctd
        ctd_cell{iF} = S.ctd;
    end
    filenames{iF} = fname;
    validFile(iF) = true;
end

filenames = filenames(validFile);
profile_data.filenames = filenames;

% A file can be valid (has_epsi || has_ctd above) yet contribute nothing
% to one of these two cells - e.g. a CTD-only deployment (no AFE board,
% metadata.manifest.has_epsi false) leaves every epsi_cell{iF} empty.
% Filtering by ~cellfun(@isempty, ...) here (rather than by validFile,
% which only tells you the file was valid for *something*) keeps epsi and
% ctd concatenation independent, so CTD data is never dropped just because
% the file it came from had no epsi record.
epsi_cell = epsi_cell(~cellfun(@isempty, epsi_cell));
ctd_cell = ctd_cell(~cellfun(@isempty, ctd_cell));

if isempty(epsi_cell) && isempty(ctd_cell)
    profile_data.epsi = empty_epsi_ctd(true);
    profile_data.ctd = empty_epsi_ctd(false);
    return
end

%% Concatenate, then crop to the exact profile time range - epsi and ctd
% independently, since one can be present without the other (see above).
if isempty(epsi_cell)
    epsi = empty_epsi_ctd(true);
else
    epsi = concat_numeric_fields(epsi_cell);
    epsi = dedupe_by_dnum(epsi);
    inRangeEpsi = epsi.dnum >= profile.dnum_start & epsi.dnum <= profile.dnum_end;
    epsi = crop_struct_fields(epsi, inRangeEpsi);
end

if isempty(ctd_cell)
    ctd = empty_epsi_ctd(false);
else
    ctd = concat_numeric_fields(ctd_cell);
    ctd = dedupe_by_dnum(ctd);
    inRangeCtd = ctd.dnum >= profile.dnum_start & ctd.dnum <= profile.dnum_end;
    ctd = crop_struct_fields(ctd, inRangeCtd);
end

%% Gap detection + segment_id on the final, cropped epsi record - see
% GAP HANDLING above.
n = numel(epsi.dnum);
segment_id = ones(n, 1);
if n > 1
    dt = diff(epsi.dnum) * 86400; % seconds
    nominal_dt = 1 / metadata.PROCESS.Fs_epsi;
    gap_after = dt > metadata.PROCESS.epsi_gap_factor * nominal_dt;
    segment_id = 1 + [0; cumsum(gap_after)];
end
epsi.segment_id = segment_id;

profile_data.epsi = epsi;
profile_data.ctd = ctd;

end %end function

%% Empty epsi/ctd shape - dnum always present so downstream numel(...)
% checks work uniformly; is_epsi adds segment_id (always empty here, never
% populated with actual samples).
function s = empty_epsi_ctd(is_epsi)
s.dnum = [];
if is_epsi
    s.segment_id = [];
end
end

%% Vertically concatenate every numeric-vector field common to every
% struct in struct_cell (already in time order). A field not present, or
% not a numeric vector, in every file is skipped rather than erroring -
% same "epsi/ctd already share a field set" assumption
% MODprocess_L1_apply_fpo7_calibration.m's concat_L1_epsi_ctd makes.
function merged = concat_numeric_fields(struct_cell)
merged = struct();
if isempty(struct_cell)
    return
end
fn = fieldnames(struct_cell{1});
for iF = 1:numel(fn)
    field = fn{iF};
    if ~isnumeric(struct_cell{1}.(field)) || ~isvector(struct_cell{1}.(field))
        continue
    end
    if ~all(cellfun(@(s) isfield(s, field) && isnumeric(s.(field)) && isvector(s.(field)), struct_cell))
        continue
    end
    parts = cellfun(@(s) s.(field)(:), struct_cell, 'UniformOutput', false);
    merged.(field) = vertcat(parts{:});
end
end

%% Collapse exact-duplicate dnum values (e.g. at a file seam) to their
% first occurrence, keeping every other field in step.
function s = dedupe_by_dnum(s)
if ~isfield(s, 'dnum') || numel(s.dnum) < 2
    return
end
[~, keepIdx] = unique(s.dnum, 'stable');
if numel(keepIdx) == numel(s.dnum)
    return % nothing duplicated - common case, skip the per-field rebuild
end
s = crop_struct_fields(s, keepIdx);
end

%% Restrict every numeric-vector field whose length matches the reference
% field count to the given logical mask or index vector.
function s = crop_struct_fields(s, mask_or_idx)
if islogical(mask_or_idx)
    n_ref = numel(mask_or_idx);
else
    n_ref = numel(s.dnum);
end
fn = fieldnames(s);
for iF = 1:numel(fn)
    field = fn{iF};
    v = s.(field);
    if isnumeric(v) && isvector(v) && numel(v) == n_ref
        s.(field) = v(mask_or_idx);
    end
end
end
