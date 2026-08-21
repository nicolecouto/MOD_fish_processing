function L2_files = MODprocess_all_L1_to_L2(L1_dir, metadata, L2_dir, reprocess_all)
% MODprocess_all_L1_to_L2        Part of MOD_fish_processing
%
% L2_files = MODprocess_all_L1_to_L2(L1_dir, metadata, L2_dir, reprocess_all)
%
% DESCRIPTION
%   Converts every L1 .mat file in L1_dir to a per-scan-spectra .mat file
%   in L2_dir, using MODprocess_single_L1_to_L2.m. Mirrors
%   MODprocess_all_L0_to_L1.m's shape exactly: skips files that already
%   have an up-to-date L2 .mat, except the most recently modified L1 file
%   (always redone, in case it was still being written), with a
%   reprocess_all override.
%
%   Loads meta/PressureTimeseries.mat once (built by
%   MODprocess_all_L0_to_L1.m via MODprocess_L1_make_pressure_timeseries.m
%   + mod_L1_detect_profiling_direction.m) and passes it into every
%   MODprocess_single_L1_to_L2.m call, so the per-file work stays a pure
%   function while the file-I/O cost is paid once per batch run rather than
%   once per file.
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
%   L1_dir        - full path to a folder of L1 .mat files
%   metadata      - metadata struct (from MODsetup_read_yaml.m), read once
%                    per session and passed through - see PLAN.md Section 2.
%                    Uses metadata.paths.meta to find PressureTimeseries.mat.
%   L2_dir        - (optional) full path to save .mat files to. Default:
%                    a sibling 'L2' folder next to L1_dir
%                    (fullfile(fileparts(L1_dir),'L2')), created if missing.
%   reprocess_all - (optional) logical, default false. If true, ignores
%                    the up-to-date check and reconverts every L1 file.
%
% OUTPUTS
%   L2_files  - cell array of full paths to all .mat files in L2_dir
%               after this call (both newly converted and pre-existing)
%
% CALLED BY
%   (top-level scripts / notebooks)
%
% CALLS
%   MODprocess_single_L1_to_L2.m
%   MODsetup_read_yaml.m (only on the retry path - see NOTES/DESCRIPTION)
%   MODutil_short_path.m (console messages only)
%
% NOTES
%   Errors clearly (rather than silently producing empty L2 files) if
%   meta/PressureTimeseries.mat doesn't exist yet - it's built by
%   MODprocess_all_L0_to_L1.m, so that must have run (with CTD data
%   present) before this function can do anything useful.
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

if nargin < 3 || isempty(L2_dir)
    L2_dir = fullfile(fileparts(L1_dir), 'L2');
end
if nargin < 4 || isempty(reprocess_all)
    reprocess_all = false;
end
if ~exist(L2_dir, 'dir')
    mkdir(L2_dir);
end

pressure_timeseries_file = fullfile(metadata.paths.meta, 'PressureTimeseries.mat');
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

    if ~reprocess_all && already_converted && i ~= i_newest
        continue
    end

    fprintf(1, '%s | L1/%s --> L2/%s | ', datestr(now, 'YYYY.mm.dd HH:MM:SS'), filename, filename);

    data = load(fullfile(list_L1file(i).folder, filename));
    while true
        try
            L2data = MODprocess_single_L1_to_L2(data, metadata, PressureTimeseries);
            break
        catch ME
            if strcmp(ME.identifier, 'MODsetup_validate_metadata:yamlUpdated')
                metadata = MODsetup_read_yaml(metadata.paths.setup_yml);
                continue % retry this same file with fresh, complete metadata
            end
            rethrow(ME)
        end
    end

    save(L2_file, '-struct', 'L2data')
    fprintf(1, '%d scans\n', numel(L2data.dnum));

end %end loop through files

L2_listing = dir(fullfile(L2_dir, '*.mat'));
L2_files = fullfile({L2_listing.folder}, {L2_listing.name})';

end %end function
