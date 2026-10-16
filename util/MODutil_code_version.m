function v = MODutil_code_version()
% MODutil_code_version        Part of MOD_fish_processing
%
% v = MODutil_code_version()
%
% DESCRIPTION
%   The git commit of this MOD_fish_processing checkout, for recording
%   which code made a file: 'commit <short sha>', with ' + local changes'
%   when tracked files differ from that commit, or '(not a git checkout)'.
%   Looked up once per Matlab session (the code doesn't change during a
%   run).
%
% INPUTS
%   (none)
%
% OUTPUTS
%   v - char, e.g. 'commit e286ebf' or 'commit e286ebf + local changes'
%
% CALLED BY
%   MODutil_provenance.m, MODutil_write_folder_readme.m
%
% CALLS
%   (none - runs git)
%
% Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

persistent cached
if ~isempty(cached)
    v = cached;
    return
end
repo = fileparts(fileparts(mfilename('fullpath')));
[status, sha] = system(sprintf('git -C "%s" rev-parse --short HEAD', repo));
if status ~= 0
    v = '(not a git checkout)';
    return
end
v = ['commit ' strtrim(sha)];
[~, dirty] = system(sprintf('git -C "%s" status --porcelain --untracked-files=no', repo));
if ~isempty(strtrim(dirty))
    v = [v ' + local changes'];
end
cached = v;
end
