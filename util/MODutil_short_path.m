function short_path = MODutil_short_path(full_path)
% MODutil_short_path        Part of MOD_fish_processing
%
% short_path = MODutil_short_path(full_path)
%
% DESCRIPTION
%   Shortens a deployment-tree path for console messages by dropping
%   everything above the deployment directory's parent (see PLAN.md
%   Section 3 for the deployment_root/{raw,L0,L1,meta,...} layout), e.g.
%
%     /Users/ncouto/.../data_for_reorg/epsi_deepsolo/26_0520_ljc/raw
%
%   becomes
%
%     epsi_deepsolo/26_0520_ljc/raw
%
%   Absolute paths into a shared Dropbox/data tree are long and mostly
%   boilerplate - only the last couple of segments actually distinguish
%   one deployment from another - so the full path just adds noise to
%   routine status messages. Error messages are a different case (the
%   full path is worth keeping there, for actually locating a problem
%   file) - this is only meant for informational fprintf/disp output.
%
%   Finds the deployment directory by locating the last occurrence of a
%   known deployment subfolder name (raw, L0, L1, L2, L3, meta, ctd,
%   grid, figures) as a path segment, then keeps from one level above it
%   (the deployment directory's parent) onward. If none of those names
%   appear anywhere in full_path, it's returned unchanged - safer than
%   guessing how many segments to keep for a path this function doesn't
%   recognize.
%
% INPUTS
%   full_path  - any path inside or at a deployment folder (data_root
%                itself, one of its known subfolders, or a file within
%                one of those subfolders)
%
% OUTPUTS
%   short_path - full_path with everything above the deployment
%                directory's parent removed, rejoined with the
%                platform's file separator
%
% CALLED BY
%   MODprocess_all_modraw_to_L0.m, MODprocess_all_L0_to_L1.m,
%   MODsetup_pad_raw_filenames.m (informational messages only)
%
% CALLS
%   (none)
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

known_subfolders = {'raw', 'L0', 'L1', 'L2', 'L3', 'meta', 'ctd', 'grid', 'figures'};

parts = strsplit(full_path, filesep);
i = find(ismember(parts, known_subfolders), 1, 'last');
if isempty(i)
    short_path = full_path;
    return
end

start = max(1, i - 2);
short_path = strjoin(parts(start:end), filesep);

end
