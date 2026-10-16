function [L2_files, problems, processed] = MODprocess_all_L1_to_L2(L1_dir, metadata, L2_dir, reprocess_all, varargin)
% MODprocess_all_L1_to_L2        Part of MOD_fish_processing
%
% L2_files = MODprocess_all_L1_to_L2(L1_dir, metadata, L2_dir, reprocess_all)
% [L2_files, problems, processed] = MODprocess_all_L1_to_L2(..., 'newest_min_redo_s', s, 'continue_on_error', tf)
%
% DESCRIPTION
%   Converts every .mat file in L1_dir to a per-scan-spectra .mat file in
%   L2_dir, using MODprocess_single_L1_to_L2.m. This is the ONE driver for
%   both processing modes - it doesn't care whether L1_dir holds raw L1
%   files (realtime mode - one file per .modraw, possibly spanning both
%   profiling directions) or already-extracted Profile####.mat files
%   (post-processing mode - built first by MODprocess_all_extract_profiles.m,
%   each one direction-pure by construction). Both shapes carry epsi/ctd;
%   MODprocess_single_L1_to_L2.m processes whichever it's handed
%   identically and just carries through whatever extra bookkeeping fields
%   (profile_number, direction, filenames, ...) happen to be present - see
%   that function's DESCRIPTION. Mirrors MODprocess_all_L0_to_L1.m's shape
%   exactly: skips files that already have an up-to-date L2 .mat, except
%   the most recently modified input file (always redone, in case it was
%   still being written), with a reprocess_all override.
%
%   Loads pressure_time_series.mat (metadata.paths.L1_meta) once (built by
%   MODprocess_all_L0_to_L1.m via MODprocess_L1_make_pressure_timeseries.m
%   + mod_L1_detect_profiling_direction.m) and passes it into every
%   MODprocess_single_L1_to_L2.m call, so the per-file work stays a pure
%   function while the file-I/O cost is paid once per batch run rather than
%   once per file. Passing it even for an already direction-pure profile
%   is harmless - per-scan direction gating just becomes a no-op confirm
%   in that case (mod_L2_tile_scans.m).
%
%   Each file's MODprocess_single_L1_to_L2.m call is wrapped in a
%   retry-on-metadata-update loop: since metadata is constant across every
%   scan/channel in a file, a chi field missing from metadata
%   (MODsetup_validate_metadata.m, called from deep inside the chi
%   functions) fails deterministically on the very first chi call, never
%   partway through a file with some scans already processed on stale
%   metadata. If the operator resolves it and saves to setup.yml, this
%   loop catches the specific 'MODsetup_validate_metadata:yamlUpdated'
%   identifier, reloads metadata fresh (MODsetup_read_yaml.m), and retries
%   just that one file - not the whole batch, and not by resuming mid-file
%   with two different metadata structs in play. Any other error
%   propagates normally.
%
% INPUTS
%   L1_dir        - full path to a folder of .mat files: either raw L1
%                    files (realtime mode) or extracted Profile####.mat
%                    files (post-processing mode, from
%                    MODprocess_all_extract_profiles.m) - see DESCRIPTION.
%   metadata      - metadata struct (from MODsetup_read_yaml.m), read once
%                    per session and passed through - see PLAN.md Section 2.
%                    Uses metadata.paths.L1_meta to find pressure_time_series.mat.
%   L2_dir        - (optional) full path to save .mat files to, created if
%                    missing. Default: metadata.paths.L2 when L1_dir is
%                    metadata.paths.L1 (this run's L2 - also for a run
%                    whose L1 is another run's), metadata.paths.profiles_L2
%                    when L1_dir is .profiles_L1, otherwise a sibling 'L2'
%                    folder next to L1_dir.
%   reprocess_all - (optional) logical, default false. If true, ignores
%                    the up-to-date check and reconverts every input file.
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
%   L2_files  - cell array of full paths to all .mat files in L2_dir
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
%   MODprocess_single_L1_to_L2.m
%   MODsetup_add_derived_metadata.m (at the start, and on the retry path)
%   MODsetup_read_yaml.m (only on the retry path - see NOTES/DESCRIPTION)
%   MODutil_needs_redo.m, MODutil_save_atomic.m, MODutil_provenance.m
%   MODutil_short_path.m (console messages only)
%
% NOTES
%   Errors clearly (rather than silently producing empty L2 files) if
%   pressure_time_series.mat doesn't exist yet - it's built by
%   MODprocess_all_L0_to_L1.m, so that must have run (with CTD data
%   present) before this function can do anything useful.
%
%   Does NOT skip a deployment with metadata.manifest.has_epsi false
%   (no AFE/epsi board): MODprocess_single_L1_to_L2.m still returns the
%   profile-bookkeeping fields and empty scans for a CTD-only deployment
%   (no epsi to tile), so this driver still writes one L2 file per input
%   file rather than producing nothing.
%
%   The derived values not in the yml - the AFE electronics filters and
%   the FP07 volts_to_C fit from meta/fpo7_calibration.mat - are added here
%   (MODsetup_add_derived_metadata.m), so metadata straight from
%   MODsetup_read_yaml.m, in any session, gets FP07 chi and the
%   electronics correction.
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

p = inputParser;
addParameter(p, 'newest_min_redo_s', 0);
addParameter(p, 'continue_on_error', false);
parse(p, varargin{:});
opts = p.Results;
problems = struct('file', {}, 'stage', {}, 'identifier', {}, 'message', {});
processed = {};

if nargin < 3 || isempty(L2_dir)
    % this run's L2 (or profiles_L2) - not a folder next to L1_dir, which
    % for a run with L1_from is the other run's
    if isfield(metadata.paths, 'L1') && strcmp(L1_dir, metadata.paths.L1)
        L2_dir = metadata.paths.L2;
    elseif isfield(metadata.paths, 'profiles_L1') && strcmp(L1_dir, metadata.paths.profiles_L1)
        L2_dir = metadata.paths.profiles_L2;
    else
        L2_dir = fullfile(fileparts(L1_dir), 'L2');
    end
end
if nargin < 4 || isempty(reprocess_all)
    reprocess_all = false;
end

if ~exist(L2_dir, 'dir')
    mkdir(L2_dir);
end

metadata = MODsetup_add_derived_metadata(metadata);

pressure_timeseries_file = fullfile(metadata.paths.L1_meta, 'pressure_time_series.mat');
if ~exist(pressure_timeseries_file, 'file')
    error('MODprocess_all_L1_to_L2:noPressureTimeseries', ...
        ['%s does not exist yet. It is built by MODprocess_all_L0_to_L1.m ' ...
         '(via MODprocess_L1_make_pressure_timeseries.m and ' ...
         'mod_L1_detect_profiling_direction.m) once this deployment has ' ...
         'CTD data in its L1 files - run that first.'], pressure_timeseries_file);
end
PressureTimeseries = load(pressure_timeseries_file);

list_L1file = dir(fullfile(L1_dir, '*.mat'));
nfiles = length(list_L1file);

if nfiles == 0
    disp(['MODprocess_all_L1_to_L2: No .mat files found in ' MODutil_short_path(L1_dir)])
    L2_files = {};
    return
end

% The newest L1 file (by modification time) is always reprocessed, in
% case L0->L1 was still running on it.
[~, i_newest] = max([list_L1file.datenum]);

for i = 1:nfiles

    filename = list_L1file(i).name;
    L2_file = fullfile(L2_dir, filename);

    already_converted = false;
    if exist(L2_file, 'file')
        L2_info = dir(L2_file);
        already_converted = L2_info.datenum >= list_L1file(i).datenum;
    end

    if ~MODutil_needs_redo(already_converted, i == i_newest, L2_file, opts.newest_min_redo_s, reprocess_all)
        continue
    end

    fprintf(1, '%s | L1/%s --> L2/%s | ', datestr(now, 'YYYY.mm.dd HH:MM:SS'), filename, filename);

    try
        data = load(fullfile(list_L1file(i).folder, filename));
        while true
            try
                L2data = MODprocess_single_L1_to_L2(data, metadata, PressureTimeseries);
                break
            catch ME
                if strcmp(ME.identifier, 'MODsetup_validate_metadata:yamlUpdated')
                    metadata = MODsetup_add_derived_metadata(MODsetup_read_yaml(metadata.paths.setup_yml));
                    continue % retry this same file with fresh, complete metadata
                end
                rethrow(ME)
            end
        end

        L2data.provenance = MODutil_provenance(fullfile(list_L1file(i).folder, filename), metadata);
        MODutil_save_atomic(L2_file, L2data)
        processed{end+1} = filename; %#ok<AGROW>
        fprintf(1, '%d scans\n', numel(L2data.dnum));
    catch ME
        if ~opts.continue_on_error
            rethrow(ME)
        end
        fprintf(1, 'FAILED: %s\n', ME.message);
        problems(end+1) = struct('file', fullfile(L1_dir, filename), 'stage', 'L1_to_L2', ...
            'identifier', ME.identifier, 'message', ME.message); %#ok<AGROW>
    end

end %end loop through files

L2_listing = dir(fullfile(L2_dir, '*.mat'));
L2_files = fullfile({L2_listing.folder}, {L2_listing.name})';

end %end function
