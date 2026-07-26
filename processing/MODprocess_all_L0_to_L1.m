function L1_files = MODprocess_all_L0_to_L1(L0_dir, metadata, L1_dir, reprocess_all)
% MODprocess_all_L0_to_L1        Part of MOD_fish_processing
%
% L1_files = MODprocess_all_L0_to_L1(L0_dir, metadata, L1_dir, reprocess_all)
%
% DESCRIPTION
%   Converts every L0 .mat file in L0_dir to a physical-units .mat file in
%   L1_dir, using MODprocess_single_L0_to_L1.
%
%   Skips files that already have an up-to-date L1 .mat (L1 file modified
%   at or after its source L0 file), except the most recently modified L0
%   file, which is always reprocessed in case the raw file behind it was
%   still being written when L0 last ran on it (mirrors
%   MODprocess_all_modraw_to_L0.m's same rule one level up). Pass
%   reprocess_all = true to force every file to be redone regardless.
%
%   If metadata.manifest.has_vnav is true, also re-chains every L1 file's
%   per-file twist count into a deployment-level meta/TwistTimeseries.mat
%   (via MODprocess_L1_accumulate_twist_timeseries.m) at the end of every
%   call - cheap, since it only concatenates fields already computed
%   per-file, and keeps the deployment-level twist count always current.
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
%
% OUTPUTS
%   L1_files  - cell array of full paths to all .mat files in L1_dir
%               after this call (both newly converted and pre-existing)
%
% CALLED BY
%   (top-level scripts / notebooks)
%
% CALLS
%   MODprocess_single_L0_to_L1.m, MODprocess_read_external_ctd.m (only for
%   vehicles with an independent CTD file - see NOTES)
%   MODprocess_L1_accumulate_twist_timeseries.m (only when metadata.manifest.has_vnav)
%   MODutil_short_path.m (console messages only)
%
% NOTES
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

if nargin < 3 || isempty(L1_dir)
    L1_dir = fullfile(fileparts(L0_dir), 'L1');
end
if nargin < 4 || isempty(reprocess_all)
    reprocess_all = false;
end
if ~exist(L1_dir, 'dir')
    mkdir(L1_dir);
end

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

    if ~reprocess_all && already_converted && i ~= i_newest
        continue
    end

    fprintf(1, '%s | L0/%s --> L1/%s | ', datestr(now, 'YYYY.mm.dd HH:MM:SS'), filename, filename);

    L0_data = load(fullfile(list_L0file(i).folder, filename));
    ctd_chunk = slice_external_ctd(external_ctd_full, L0_data);
    data = MODprocess_single_L0_to_L1(L0_data, metadata, ctd_chunk);

    save(L1_file, '-struct', 'data')
    fprintf(1, '\n');

end %end loop through files

L1_listing = dir(fullfile(L1_dir, '*.mat'));
L1_files = fullfile({L1_listing.folder}, {L1_listing.name})';

% Deployment-level twist count: re-chain every L1 file's per-file twist
% field (added inside MODprocess_single_L0_to_L1) into meta/TwistTimeseries.mat.
% Only meaningful when this deployment actually has a vnav - skip
% otherwise rather than let it churn through every L1 file logging
% "missing vnav" for nothing.
if isfield(metadata, 'manifest') && isfield(metadata.manifest, 'has_vnav') && metadata.manifest.has_vnav
    MODprocess_L1_accumulate_twist_timeseries(L1_dir, metadata.paths.meta);
end

end %end function

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
