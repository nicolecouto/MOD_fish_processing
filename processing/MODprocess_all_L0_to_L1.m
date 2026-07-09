function L1_files = MODprocess_all_L0_to_L1(L0_dir, L1_dir, metadata, reprocess_all)
% MODprocess_all_L0_to_L1        Part of MOD_fish_processing
%
% L1_files = MODprocess_all_L0_to_L1(L0_dir, L1_dir, metadata, reprocess_all)
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
% INPUTS
%   L0_dir        - full path to a folder of L0 .mat files
%   L1_dir        - (optional) full path to save .mat files to. Default:
%                    a sibling 'L1' folder next to L0_dir
%                    (fullfile(fileparts(L0_dir),'L1')), created if missing.
%   metadata      - metadata struct (from MODsetup_read_yaml.m), read once
%                    per session and passed through - see PLAN.md Section 2.
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
%   MODprocess_single_L0_to_L1.m
%
% NOTES
%   metadata is loaded once by the caller (MODsetup_read_yaml.m) and
%   passed in here rather than re-read per file - it does not change
%   file-to-file within a deployment.
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

if nargin < 2 || isempty(L1_dir)
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
    disp(['MODprocess_all_L0_to_L1: No .mat files found in ' L0_dir])
    L1_files = {};
    return
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

    fprintf(1, '%s | %s --> L1/%s | ', datestr(now, 'YYYY.mm.dd HH:MM:SS'), filename, filename);

    L0_data = load(fullfile(list_L0file(i).folder, filename));
    data = MODprocess_single_L0_to_L1(L0_data, metadata);

    save(L1_file, '-struct', 'data')
    fprintf(1, 'done\n');

end %end loop through files

L1_listing = dir(fullfile(L1_dir, '*.mat'));
L1_files = fullfile({L1_listing.folder}, {L1_listing.name})';

end %end function
